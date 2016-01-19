#!/bin/sh
set -e
declare -i CNT

rdo_images_uri=https://ci.centos.org/artifacts/rdo/images/liberty/delorean/stable

vm_index=4
RDO_RELEASE=liberty
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null)
OPNFV_NETWORK_TYPES="admin_network private_network public_network storage_network"

# check for dependancy packages
for i in rpm-build createrepo libguestfs-tools python-docutils bsdtar; do
    if ! rpm -q $i > /dev/null; then
        sudo yum install -y $i
    fi
done

#
# Special kernel version if any are required.
#
kernel_major=3
kernel_minor=13.11

# RDO Manager expects a stack user to exist, this checks for one
# and creates it if you are root
if ! id stack > /dev/null; then
    sudo useradd stack;
    sudo echo 'stack ALL=(root) NOPASSWD:ALL' | sudo tee -a /etc/sudoers.d/stack
    sudo echo 'Defaults:stack !requiretty' | sudo tee -a /etc/sudoers.d/stack
    sudo chmod 0440 /etc/sudoers.d/stack
    echo 'Added user stack'
fi

# ensure that I can ssh as the stack user
if ! sudo grep "$(cat ~/.ssh/id_rsa.pub)" /home/stack/.ssh/authorized_keys; then
    if ! sudo ls -d /home/stack/.ssh/ ; then
        sudo mkdir /home/stack/.ssh
        sudo chown stack:stack /home/stack/.ssh
        sudo chmod 700 /home/stack/.ssh
    fi
    USER=$(whoami) sudo sh -c "cat ~$USER/.ssh/id_rsa.pub >> /home/stack/.ssh/authorized_keys"
    sudo chown stack:stack /home/stack/.ssh/authorized_keys
fi

# clean up stack user previously build instack disk images
ssh -T ${SSH_OPTIONS[@]} stack@localhost "rm -f instack*.qcow2"

# Yum repo setup for building the undercloud
if ! rpm -q rdo-release > /dev/null && [ "$1" != "-master" ]; then
    #pulling from current-passed-ci instead of release repos
    #sudo yum install -y https://rdoproject.org/repos/openstack-${RDO_RELEASE}/rdo-release-${RDO_RELEASE}.rpm
    sudo yum -y install yum-plugin-priorities
    sudo yum-config-manager --disable openstack-${RDO_RELEASE}
    sudo curl -o /etc/yum.repos.d/delorean.repo http://trunk.rdoproject.org/centos7-liberty/current-passed-ci/delorean.repo
    sudo curl -o /etc/yum.repos.d/delorean-deps.repo http://trunk.rdoproject.org/centos7-liberty/delorean-deps.repo
    sudo rm -f /etc/yum.repos.d/delorean-current.repo
elif [ "$1" == "-master" ]; then
    sudo yum -y install yum-plugin-priorities
    sudo yum-config-manager --disable openstack-${RDO_RELEASE}
    sudo curl -o /etc/yum.repos.d/delorean.repo http://trunk.rdoproject.org/centos7/current-passed-ci/delorean.repo
    sudo curl -o /etc/yum.repos.d/delorean-deps.repo http://trunk.rdoproject.org/centos7-liberty/delorean-deps.repo
    sudo rm -f /etc/yum.repos.d/delorean-current.repo
fi

# install the opendaylight yum repo definition
cat << 'EOF' | sudo tee /etc/yum.repos.d/opendaylight.repo
[opendaylight]
name=OpenDaylight $releasever - $basearch
baseurl=http://cbs.centos.org/repos/nfv7-opendaylight-3-candidate/$basearch/os/
enabled=1
gpgcheck=0
EOF

# ensure the undercloud package is installed so we can build the undercloud
if ! rpm -q instack-undercloud > /dev/null; then
    sudo yum install -y python-tripleoclient
fi

# ensure openvswitch is installed
if ! rpm -q openvswitch > /dev/null; then
    sudo yum install -y openvswitch
fi

# ensure libvirt is installed
if ! rpm -q libvirt-daemon-kvm > /dev/null; then
    sudo yum install -y libvirt-daemon-kvm
fi

# clean this up incase it's there
sudo rm -f /tmp/instack.answers

# ensure that no previous undercloud VMs are running
sudo ./clean.sh
# and rebuild the bare undercloud VMs
ssh -T ${SSH_OPTIONS[@]} stack@localhost <<EOI
set -e
NODE_COUNT=5 NODE_CPU=2 NODE_MEM=8192 TESTENV_ARGS="--baremetal-bridge-names 'brbm brbm1 brbm2 brbm3'" instack-virt-setup
EOI

# let dhcp happen so we can get the ip
# just wait instead of checking until we see an address
# because there may be a previous lease that needs
# to be cleaned up
sleep 5

# get the undercloud ip address
UNDERCLOUD=$(grep instack /var/lib/libvirt/dnsmasq/default.leases | awk '{print $3}' | head -n 1)
if [ -z "$UNDERCLOUD" ]; then
  #if not found then dnsmasq may be using leasefile-ro
  instack_mac=$(ssh -T ${SSH_OPTIONS[@]} stack@localhost "virsh domiflist instack" | grep default | \
                grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
  UNDERCLOUD=$(arp -e | grep ${instack_mac} | awk {'print $1'})

  if [ -z "$UNDERCLOUD" ]; then
    echo "\n\nNever got IP for Instack. Can Not Continue."
    exit 1
  fi
else
   echo -e "${blue}\rInstack VM has IP $UNDERCLOUD${reset}"
fi

# ensure that we can ssh to the undercloud
CNT=10
while ! ssh -T ${SSH_OPTIONS[@]}  "root@$UNDERCLOUD" "echo ''" > /dev/null && [ $CNT -gt 0 ]; do
    echo -n "."
    sleep 3
    CNT=CNT-1
done
# TODO fail if CNT=0

# yum repo, triple-o package and ssh key setup for the undercloud
ssh -T ${SSH_OPTIONS[@]} "root@$UNDERCLOUD" <<EOI
set -e

if ! rpm -q epel-release > /dev/null; then
    yum install http://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
fi

yum -y install yum-plugin-priorities
curl -o /etc/yum.repos.d/delorean.repo http://trunk.rdoproject.org/centos7-liberty/current-passed-ci/delorean.repo
curl -o /etc/yum.repos.d/delorean-deps.repo http://trunk.rdoproject.org/centos7-liberty/delorean-deps.repo

cp /root/.ssh/authorized_keys /home/stack/.ssh/authorized_keys
chown stack:stack /home/stack/.ssh/authorized_keys
EOI

ssh -T ${SSH_OPTIONS[@]} "root@$UNDERCLOUD" <<EOI
set -e
yum -y install gcc ncurses ncurses-devel bc xz rpm-build
echo mkdir Linux_$kernel_major.$kernel_minor.x86_64
mkdir Linux_$kernel_major.$kernel_minor.x86_64
echo cd Linux_$kernel_major.$kernel_minor.x86_64
cd Linux_$kernel_major.$kernel_minor.x86_64
echo wget --quiet https://www.kernel.org/pub/linux/kernel/v$kernel_major.0/linux-$kernel_major.$kernel_minor.tar.xz
wget --quiet https://www.kernel.org/pub/linux/kernel/v$kernel_major.0/linux-$kernel_major.$kernel_minor.tar.xz
echo xz -d linux-$kernel_major.$kernel_minor.tar.xz
xz -d linux-$kernel_major.$kernel_minor.tar.xz
echo tar -xf linux-$kernel_major.$kernel_minor.tar
tar -xf linux-$kernel_major.$kernel_minor.tar
echo cd linux-$kernel_major.$kernel_minor
cd linux-$kernel_major.$kernel_minor
echo yes "" | make oldconfig
yes "" | make oldconfig
echo sed -i -e 's/CONFIG_BT_HCIVHCI=m/CONFIG_BT_HCIVHCI=n/' .config
sed -i -e 's/CONFIG_BT_HCIVHCI=m/CONFIG_BT_HCIVHCI=n/' .config
echo make rpm
make rpm
echo cd /root/rpmbuild/RPMS/x86_64/
cd /root/rpmbuild/RPMS/x86_64/
echo rpm -i kernel-$kernel_major.$kernel_minor*.rpm
rpm -i kernel-$kernel_major.$kernel_minor*.rpm
echo rpm -i kernel-devel-$kernel_major.$kernel_minor*.rpm
rpm -i kernel-devel-$kernel_major.$kernel_minor*.rpm
EOI

virsh reboot instack

# copy instackenv file for future virt deployments
if [ ! -d stack ]; then mkdir stack; fi
scp ${SSH_OPTIONS[@]} stack@$UNDERCLOUD:instackenv.json stack/instackenv.json
