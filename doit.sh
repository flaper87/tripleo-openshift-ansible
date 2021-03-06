#!/usr/bin/env bash
set -x

git submodule update --init --recursive

sudo setenforce permissive

sudo yum -y install curl vim-enhanced telnet epel-release
sudo yum install -y centos-release-openshift-origin.noarch
sudo yum install -y openshift-ansible-playbooks openshift-ansible-roles
sudo yum install -y https://dprince.fedorapeople.org/tmate-2.2.1-1.el7.centos.x86_64.rpm

# these avoid warning for the cherry-picks below ATM
if [ ! -f $HOME/.gitconfig ]; then
  git config --global user.email "theboss@foo.bar"
  git config --global user.name "TheBoss"
fi

#sudo yum install -y \
cd

# HEAT
cd
git clone git://git.openstack.org/openstack/heat
cd heat
sudo python setup.py install
sudo systemctl restart openstack-heat-*

# TRIPLEO VALIDATIONS
cd
git clone git://git.openstack.org/openstack/tripleo-validations
cd tripleo-validations
sudo python setup.py install

# TRIPLEO HEAT TEMPLATES
cd
git clone git://git.openstack.org/openstack/tripleo-heat-templates
cd tripleo-heat-templates
ln -sf $HOME/tripleo-openshift-ansible/tht/coe .
cd environments
ln -sf $HOME/tripleo-openshift-ansible/tht/environments/openshift.yaml openshift.yaml
ln -sf $HOME/tripleo-openshift-ansible/tht/environments/kubernetes.yaml kubernetes.yaml

cd
git clone git://git.openstack.org/openstack/tripleo-common
cd tripleo-common
sudo python setup.py install

# MISTRAL ANSIBLE ACTION (NO NEED, EVERYTHING MOVED INTO TRIPLEO COMMON)
# cd
# sudo rm -Rf /usr/lib/python2.7/site-packages/mistral_ansible*
# ln -sf tripleo-openshift-ansible/mistral-ansible-actions .
sudo mistral-db-manage populate

# OPENSHIFT ANSIBLE
cd
ln -sf tripleo-openshift-ansible/openshift-ansible .
cd openshift-ansible
sudo python setup.py install

# OPENSHIFT ANSIBLE
cd
ln -sf tripleo-openshift-ansible/kargo .

# UPLOAD WORKFLOW (NO NEED, WORKFLOW CREATED DYNAMICALLY)
# cd
# source ~/stackrc
# mistral workflow-create --public tripleo-openshift-ansible/workflow-openshift-ansible.yaml

# this is how you inject an admin password
cat > $HOME/tripleo-undercloud-passwords.yaml <<-EOF_CAT
parameter_defaults:
  AdminPassword: HnTzjCGP6HyXmWs9FzrdHRxMs
EOF_CAT

# Custom settings can go here
cat > $HOME/custom.yaml <<-EOF_CAT
parameter_defaults:
  UndercloudNameserver: 8.8.8.8
  NeutronServicePlugins: ""
EOF_CAT

cat > $HOME/stack-openshift-ansible.yaml <<-EOF_CAT
heat_template_version: ocata

resources:
  execution:
    type: OS::Mistral::ExternalResource
    properties:
      actions:
        CREATE:
          workflow: openshift-ansible
      input:
        inventory: $HOME/ansible-inventory
        playbook: $HOME/openshift-ansible/playbooks/byo/config.yml
EOF_CAT

#cat > $HOME/tripleo-heat-templates/environments/openshift.yaml <<-EOF_CAT
#resource_registry:
#  OS::TripleO::Services::Docker: ../puppet/services/docker.yaml
#EOF_CAT

cat > $HOME/openshift_roles_data.yaml <<-EOF_CAT
- name: Controller
  CountDefault: 1
  tags:
    - primary
    - controller
  ServicesDefault:
    - OS::TripleO::Services::Docker
    - OS::TripleO::Services::OpenShift::Master
- name: Compute
  CountDefault: 1
  HostnameFormatDefault: '%stackname%-novacompute-%index%'
  disable_upgrade_deployment: True
  ServicesDefault:
    - OS::TripleO::Services::Docker
    - OS::TripleO::Services::OpenShift::Worker
EOF_CAT

cat > $HOME/kubernetes_roles_data.yaml <<-EOF_CAT
- name: Controller
  CountDefault: 1
  tags:
    - primary
    - controller
  ServicesDefault:
    - OS::TripleO::Services::Docker
    - OS::TripleO::Services::Kubernetes::Master
- name: Compute
  CountDefault: 1
  HostnameFormatDefault: '%stackname%-novacompute-%index%'
  disable_upgrade_deployment: True
  ServicesDefault:
    - OS::TripleO::Services::Docker
    - OS::TripleO::Services::Kubernetes::Worker
EOF_CAT

LOCAL_IP=${LOCAL_IP:-`/usr/sbin/ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n'`}

cat > $HOME/install-openshift.sh <<-EOF_CAT
#!/bin/bash

set -ux


### --start_docs
## Deploying the overcloud
## =======================

## Prepare Your Environment
## ------------------------

## * Source in the undercloud credentials.
## ::

source /home/stack/stackrc

### --stop_docs
# Wait until there are hypervisors available.
while true; do
    count=\$(openstack hypervisor stats show -c count -f value)
    if [ \$count -gt 0 ]; then
        break
    fi
done

### --start_docs


## * Deploy the overcloud!
## ::
time openstack overcloud deploy \
    --templates $HOME/tripleo-heat-templates \
    --libvirt-type qemu \
    --control-flavor oooq_control \
    --compute-flavor oooq_compute \
    --ceph-storage-flavor oooq_ceph \
    --block-storage-flavor oooq_blockstorage \
    --swift-storage-flavor oooq_objectstorage \
    --timeout 90 \
    -e $HOME/cloud-names.yaml \
    -e $HOME/tripleo-heat-templates/environments/openshift.yaml \
    -e $HOME/tripleo-heat-templates/environments/network-isolation.yaml \
    -e $HOME/tripleo-heat-templates/environments/net-single-nic-with-vlans.yaml \
    -e $HOME/network-environment.yaml  \
    -e $HOME/tripleo-heat-templates/environments/low-memory-usage.yaml \
    -e $HOME/enable-tls.yaml \
    -e $HOME/tripleo-heat-templates/environments/tls-endpoints-public-ip.yaml \
    -e $HOME/inject-trust-anchor.yaml \
    -r $HOME/openshift_roles_data.yaml \
    --validation-warnings-fatal \
    --ntp-server pool.ntp.org \
    \${DEPLOY_ENV_YAML:+-e \$DEPLOY_ENV_YAML} "\$@" && status_code=0 || status_code=\$?

### --stop_docs
# We don't always get a useful error code from the openstack deploy command,
# so check openstack stack list for a CREATE_COMPLETE status.
if ! openstack stack list | grep -q 'CREATE_COMPLETE'; then
        # get the failures list
    openstack stack failures list overcloud --long > /home/stack/failed_deployment_list.log || true

    # get any puppet related errors
    for failed in \$(openstack stack resource list \
        --nested-depth 5 overcloud | grep FAILED |
        grep 'StructuredDeployment ' | cut -d '|' -f3)
    do
    echo "heat deployment-show out put for deployment: \$failed" >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    heat deployment-show \$failed >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    echo "puppet standard error for deployment: \$failed" >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    # the sed part removes color codes from the text
    heat deployment-show \$failed |
        jq -r .output_values.deploy_stderr |
        sed -r "s:\x1B\[[0-9;]*[mK]::g" >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    # We need to exit with 1 because of the above || true
    done
    exit 1
fi
exit $status_code
EOF_CAT
chmod 755 $HOME/install-openshift.sh

cat > $HOME/install-kubernetes.sh <<-EOF_CAT
#!/bin/bash

set -ux


### --start_docs
## Deploying the overcloud
## =======================

## Prepare Your Environment
## ------------------------

## * Source in the undercloud credentials.
## ::

source /home/stack/stackrc

### --stop_docs
# Wait until there are hypervisors available.
while true; do
    count=\$(openstack hypervisor stats show -c count -f value)
    if [ \$count -gt 0 ]; then
        break
    fi
done

### --start_docs


## * Deploy the overcloud!
## ::
time openstack overcloud deploy \
    --templates $HOME/tripleo-heat-templates \
    --libvirt-type qemu \
    --control-flavor oooq_control \
    --compute-flavor oooq_compute \
    --ceph-storage-flavor oooq_ceph \
    --block-storage-flavor oooq_blockstorage \
    --swift-storage-flavor oooq_objectstorage \
    --timeout 90 \
    -e $HOME/cloud-names.yaml \
    -e $HOME/tripleo-heat-templates/environments/kubernetes.yaml \
    -e $HOME/tripleo-heat-templates/environments/network-isolation.yaml \
    -e $HOME/tripleo-heat-templates/environments/net-single-nic-with-vlans.yaml \
    -e $HOME/network-environment.yaml  \
    -e $HOME/tripleo-heat-templates/environments/low-memory-usage.yaml \
    -e $HOME/enable-tls.yaml \
    -e $HOME/tripleo-heat-templates/environments/tls-endpoints-public-ip.yaml \
    -e $HOME/inject-trust-anchor.yaml \
    -r $HOME/kubernetes_roles_data.yaml \
    --validation-warnings-fatal \
    --ntp-server pool.ntp.org \
    \${DEPLOY_ENV_YAML:+-e \$DEPLOY_ENV_YAML} "\$@" && status_code=0 || status_code=\$?

### --stop_docs
# We don't always get a useful error code from the openstack deploy command,
# so check openstack stack list for a CREATE_COMPLETE status.
if ! openstack stack list | grep -q 'CREATE_COMPLETE'; then
        # get the failures list
    openstack stack failures list overcloud --long > /home/stack/failed_deployment_list.log || true

    # get any puppet related errors
    for failed in \$(openstack stack resource list \
        --nested-depth 5 overcloud | grep FAILED |
        grep 'StructuredDeployment ' | cut -d '|' -f3)
    do
    echo "heat deployment-show out put for deployment: \$failed" >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    heat deployment-show \$failed >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    echo "puppet standard error for deployment: \$failed" >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    # the sed part removes color codes from the text
    heat deployment-show \$failed |
        jq -r .output_values.deploy_stderr |
        sed -r "s:\x1B\[[0-9;]*[mK]::g" >> /home/stack/failed_deployments.log
    echo "######################################################" >> /home/stack/failed_deployments.log
    # We need to exit with 1 because of the above || true
    done
    exit 1
fi
exit $status_code
EOF_CAT
chmod 755 $HOME/install-kubernetes.sh
