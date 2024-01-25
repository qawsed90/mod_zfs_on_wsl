#!/bin/sh
set -xe

#ZFS_VERSION="2.1.2"
#ZFS_VERSION="2.1.3"
#ZFS_VERSION="2.1.4"
#ZFS_VERSION="2.1.5"
#ZFS_VERSION="2.1.6"
#ZFS_VERSION="2.1.9"
#ZFS_VERSION="2.1.13"
ZFS_VERSION="2.2.2"
ZFS_RELEASE="1"

KERNELVER=$(uname -r)
#KERNELVER="5.10.43.3-microsoft-standard-WSL2"
#KERNELVER="5.10.60.1-microsoft-standard-WSL2"
#KERNELVER="5.10.93.2-microsoft-standard-WSL2"
#KERNELVER="5.10.102.1-microsoft-standard-WSL2"
#KERNELVER="5.15.57.1-microsoft-standard-WSL2"
#KERNELVER="5.15.68.1-microsoft-standard-WSL2"
#KERNELVER="5.15.74.2-microsoft-standard-WSL2"
#KERNELVER="5.15.79.1-microsoft-standard-WSL2"
#KERNELVER="5.15.90.1-microsoft-standard-WSL2"
#KERNELVER="6.1.21.1-microsoft-standard-WSL2"
#KERNELVER="5.15.133.1-microsoft-standard-WSL2"
#KERNELVER="5.15.146.1-microsoft-standard-WSL2"
LINUX_VERSION=$(echo ${KERNELVER}|awk -F'[-]' '{print $1}')
LINUX_RELEASE="1"

SCRIPTDIR=$(pwd)
KERNELSRCDIR=${SCRIPTDIR}/WSL2-Linux-Kernel
ZFSSRCDIR=${SCRIPTDIR}/zfs

#
# Install pre-requisites
#
sudo apt update && \
sudo apt upgrade -y && \
sudo apt install tzdata
sudo apt install \
  autoconf \
  automake \
  bc \
  binutils \
  bison \
  build-essential \
  curl \
  dwarves \
  fakeroot \
  flex \
  gawk \
  gcc \
  libblkid-dev \
  libelf-dev \
  libffi-dev \
  libssl-dev \
  libtool \
  python3 \
  python3-setuptools \
  uuid-dev \
  wget \
  zlib1g-dev

#
# Download source code
#
if [ ! -d ${KERNELSRCDIR} ];then
  git clone https://github.com/microsoft/WSL2-Linux-Kernel.git
fi
if [ ! -d ${ZFSSRCDIR} ];then
  git clone https://github.com/openzfs/zfs.git 
fi

#
# kernel build with gcc-9 (Ubuntu 9.5.0-3ubuntu1) 9.5.0 by Ubuntu can't load module.
#   (NOTE: No BPF error gcc (GCC) 11.2.0 by CBL-Mariner 2.0)
# dmesg say below:
#[    4.655440] BPF:[134983] FWD
#[    4.655837] BPF:struct
#[    4.656047] BPF:
#[    4.656277] BPF:Invalid name
#[    4.656610] BPF:
#
#[    4.790484] modprobe: ERROR: could not insert 'zfs': Invalid argument
# build CBL-Mariner by docker, disable comment out
#
#make(){
#	docker run -u $(id -u $(whoami)):$(id -g $(whoami)) -ti --rm --volume=${SCRIPTDIR}:${SCRIPTDIR} -w $(pwd) wslkernelbuilder:2.0 make $*
#}

#
# kernel build prepare
#
cd ${KERNELSRCDIR}
git fetch --tags origin
KERNELTAG=$(git tag | grep wsl | grep ${LINUX_VERSION})
git checkout ${KERNELTAG}
make mrproper
cp Microsoft/config-wsl .config
if [ -f ${SCRIPTDIR}/add_module_config ];then
  cat ${SCRIPTDIR}/add_module_config >> .config
fi
make olddefconfig
make LOCALVERSION= modules -j$(nproc)

#
# copy BTF file from /sys/kernel
#
if ! $(type make | grep 'is a shell function' > /dev/null);then
	cp /sys/kernel/btf/vmlinux ${KERNELSRCDIR}
fi

#
# build zfs
#
cd ${ZFSSRCDIR}
git fetch --tags origin
git checkout zfs-${ZFS_VERSION}
sh autogen.sh
./configure \
	--prefix=/usr \
	--sysconfdir=/etc \
	--libdir=/lib \
	--includedir=/usr/include \
	--datarootdir=/usr/share \
	--enable-linux-builtin=no \
	--with-linux=${KERNELSRCDIR} \
	--with-linux-obj=${KERNELSRCDIR}

rm -rf ${ZFSSRCDIR}/debwork
/usr/bin/make -j$(nproc) DESTDIR=${ZFSSRCDIR}/debwork
/usr/bin/make -j$(nproc) DESTDIR=${ZFSSRCDIR}/debwork install
rm -rf ${ZFSSRCDIR}/debwork/lib/modules/
rm -rf ${ZFSSRCDIR}/debwork/usr/src/zfs-${ZFS_VERSION}/${KERNELVER}

INSTALLED_SIZE=$(du -ks debwork|awk '{print $1}')

mkdir -p ${ZFSSRCDIR}/debwork/DEBIAN
cat > ${ZFSSRCDIR}/debwork/DEBIAN/control << EOF
Package: zfs
Priority: extra
Section: kernel
Installed-Size: ${INSTALLED_SIZE}
Maintainer: $(whoami)@$(hostname)
Architecture: amd64
Version: ${ZFS_VERSION}-${ZFS_RELEASE}
Provides: zfs
Description: zfs for WSL linux
EOF

fakeroot dpkg-deb --build debwork ${SCRIPTDIR}

#
# build kernel module
#
rm -rf ${KERNELSRCDIR}/debwork
cd ${ZFSSRCDIR}/module
make clean
make -j$(nproc) DESTDIR=${KERNELSRCDIR}/debwork
make -j$(nproc) DESTDIR=${KERNELSRCDIR}/debwork install
cd ${KERNELSRCDIR}
make -j$(nproc) INSTALL_MOD_PATH=${KERNELSRCDIR}/debwork LOCALVERSION= modules
make -j$(nproc) INSTALL_MOD_PATH=${KERNELSRCDIR}/debwork LOCALVERSION= modules_install

rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/block/nbd.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/net/bonding/bonding.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/net/dummy.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/net/vrf.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/usb/serial/ch341.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/usb/serial/cp210x.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/usb/serial/ftdi_sio.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/drivers/usb/serial/usbserial.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/net/ipv4/ipip.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/net/ipv4/tunnel4.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/net/ipv6/sit.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/net/netfilter/xt_bpf.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/net/netfilter/xt_CT.ko
rm -f ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER}/kernel/net/netfilter/xt_u32.ko
find ${KERNELSRCDIR}/debwork/lib/modules/${KERNELVER} -type d -empty -delete

INSTALLED_SIZE=$(du -ks debwork|awk '{print $1}')

mkdir -p ${KERNELSRCDIR}/debwork/DEBIAN
cat > ${KERNELSRCDIR}/debwork/DEBIAN/control << EOF
Package: linux-module-${KERNELVER}
Priority: extra
Section: kernel
Installed-Size: ${INSTALLED_SIZE}
Maintainer: $(whoami)@$(hostname)
Architecture: amd64
Version: ${LINUX_VERSION}-${LINUX_RELEASE}
Provides: linux-module
Description: module files (zfs-${ZFS_VERSION}) for WSL linux kernel
 Enable modules:
 CONFIG_ZFS=m$(test -f ${SCRIPTDIR}/add_module_config && echo &&
sed 's/^/ /' ${SCRIPTDIR}/add_module_config)
EOF

cat > ${KERNELSRCDIR}/debwork/DEBIAN/postinst << EOF
#!/bin/sh
depmod ${KERNELVER}
EOF
chmod 755 ${KERNELSRCDIR}/debwork/DEBIAN/postinst

fakeroot dpkg-deb --build debwork ${SCRIPTDIR}

set +x
echo '================================================================================================='
echo '# edit /etc/wsl.conf'
echo '$ cat /etc/wsl.conf
[boot]
command=modprobe zfs
'
echo '# install deb packages for zfs'
echo '$ sudo dpkg -i' linux-module-$(echo ${KERNELVER}|tr A-Z a-z)_${LINUX_VERSION}-${LINUX_RELEASE}_amd64.deb
echo '$ sudo dpkg -i' zfs_${ZFS_VERSION}-${ZFS_RELEASE}_amd64.deb
echo ''
echo '# check zfs'
echo '$ sudo zfs version'
echo '================================================================================================='
