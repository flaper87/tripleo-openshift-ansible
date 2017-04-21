#!/bin/bash 
# Filename:                ansible-inventory.sh
# Description:             Builds an Ansible Inventory
# Supported Langauge(s):   GNU Bash 4.2.x
# Time-stamp:              <2017-02-11 20:18:42 jfulton> 
# -------------------------------------------------------
echo "(re)building ansbile inventory"
source ~/stackrc

cat /dev/null > /tmp/inventory

declare -a TYPES
MASTERS=(control)
NODES=(control compute)

cat > /tmp/inventory <<-EOF_CAT
[OSEv3:children]
nodes
masters

[OSEv3:vars]
openshift_use_dnsmasq=False
ansible_ssh_user=heat-admin
ansible_become=true
ansible_become_user=root
openshift_deployment_type=origin
openshift_release=v1.5
openshift_image_tag=v1.5.0
enable_excluders=False

EOF_CAT

echo "[masters]" >> /tmp/inventory
for type in ${MASTERS[@]}; do
    for server in $(nova list | grep ACTIVE | awk {'print $4'}); do
        if [[ $server == *"$type"* ]]; then
            ip=$(nova list | grep $server | awk {'print $12'} | sed s/ctlplane=//g)
            echo "$ip openshift_public_ip=$ip openshift_ip=$ip openshift_public_hostname=$ip openshift_hostname=$ip containerized=True connect_to=$ip openshift_schedulable=True openshift_excluder_on=False" >> /tmp/inventory
        fi
    done
    echo "" >> /tmp/inventory
done

echo "[nodes]" >> /tmp/inventory
for type in ${NODES[@]}; do
    for server in $(nova list | grep ACTIVE | awk {'print $4'}); do
        if [[ $server == *"$type"* ]]; then
            ip=$(nova list | grep $server | awk {'print $12'} | sed s/ctlplane=//g)
            echo "$ip openshift_public_ip=$ip openshift_ip=$ip openshift_public_hostname=$ip openshift_hostname=$ip containerized=True connect_to=$ip openshift_schedulable=True openshift_excluder_on=False" >> /tmp/inventory
        fi
    done
    echo "" >> /tmp/inventory
done

sudo mv /tmp/inventory /etc/ansible/hosts

ansible all -m ping
