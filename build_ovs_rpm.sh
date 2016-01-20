#!/bin/bash
set -e
declare -i CNT

HOME=`pwd`
TOPDIR=$HOME
TMPDIR=$TOPDIR/ovsrpm

if [ -d $TMPDIR ]
then
    rm -rf $TMPDIR
fi

sudo yum -y install gcc make python-devel openssl-devel kernel-devel graphviz \
       kernel-debug-devel autoconf automake rpm-build redhat-rpm-config \
       libtool

TAG=nsh-v8
VERSION=2.3.90
os_type=rhel6
kernel_version=$(uname -a | awk '{print $3}')

mkdir -p $TMPDIR

cd $TMPDIR

mkdir -p $HOME/rpmbuild/RPMS
mkdir -p $HOME/rpmbuild/SOURCES
mkdir -p $HOME/rpmbuild/SPECS
mkdir -p $HOME/rpmbuild/SRPMS

RPMDIR=$HOME/rpmbuild


echo "---------------------"
echo "Clone git repo $TAG"
echo
git clone https://github.com/pritesh/ovs

cd ovs
echo "--------------------"
echo "Checkout OVS $TAG"
echo
if [[ ! "$TAG" =~ "master" ]]; then
    git checkout $TAG
fi
./boot.sh
#./configure
./configure --with-linux=/lib/modules/`uname -r`/build
echo "--------------------"
echo "Make OVS $TAG"
echo
make
make dist

echo cp openvswitch-$VERSION.tar.gz $HOME/rpmbuild/SOURCES
cp openvswitch-$VERSION.tar.gz $HOME/rpmbuild/SOURCES

echo "Building kernel module..."
rpmbuild -bb -D "kversion $kernel_version" -D "kflavors default" --define "_unpackaged_files_terminate_build 0" --define "_topdir `echo $RPMDIR`" --without check rhel/openvswitch-kmod-${os_type}.spec
echo " Kernel RPM built!"

echo "Building User Space..."
rpmbuild -bb --define "_topdir `echo $RPMDIR`" --without check rhel/openvswitch.spec


