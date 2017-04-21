#!/usr/bin/env bash
set -x

git submodule update

sudo setenforce permissive

sudo yum -y update
sudo yum -y install curl vim-enhanced telnet
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
git fetch git://git.openstack.org/openstack/heat refs/changes/64/420664/9 && git cherry-pick FETCH_HEAD
sudo python setup.py install
sudo systemctl restart openstack-heat

# TRIPLEO HEAT TEMPLATES
cd
git clone git://git.openstack.org/openstack/tripleo-heat-templates
cd tripleo-heat-templates

# MISTRAL ANSIBLE ACTION
sudo rm -Rf /usr/lib/python2.7/site-packages/mistral_ansible*
ln -sf tripleo-openshift-ansible/mistral-ansible-actions .
cd mistral-ansible-actions
sudo python setup.py develop
sudo mistral-db-manage populate
cd

# OPENSHIFT ANSIBLE
ln -sf tripleo-openshift-ansible/openshift-ansible .
cd openshift-ansible
sudo python setup.py develop
cd

# UPLOAD WORKFLOW
mistral workflow-create --public tripleo-openshift-ansible/workflow-openshift-ansible.yaml

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

LOCAL_IP=${LOCAL_IP:-`/usr/sbin/ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n'`}

cat > $HOME/run.sh <<-EOF_CAT
time sudo openstack overcloud deploy 
EOF_CAT
chmod 755 $HOME/run.sh
