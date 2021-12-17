#!/bin/sh
set -xe

ZFS_VERSION="2.1.2"
ZFS_RELEASE="1"

KERNELVER=$(uname -r)
LINUX_VERSION=$(echo ${KERNELVER}|awk -F'[-]' '{print $1}')
LINUX_RELEASE="2"

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
# kernel build prepare
#
cd ${KERNELSRCDIR}
git fetch --tags origin
git checkout linux-msft-wsl-${LINUX_VERSION}
cp Microsoft/config-wsl .config
if [ -f ${SCRIPTDIR}/add_module_config ];then
  cat ${SCRIPTDIR}/add_module_config >> .config
fi
make olddefconfig
make LOCALVERSION= modules -j$(nproc)

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
make -j$(nproc) DESTDIR=${ZFSSRCDIR}/debwork 
make -j$(nproc) DESTDIR=${ZFSSRCDIR}/debwork install
rm -rf ${ZFSSRCDIR}/debwork/lib/modules/

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
make -j$(nproc) DESTDIR=${KERNELSRCDIR}/debwork
make -j$(nproc) DESTDIR=${KERNELSRCDIR}/debwork install
cd ${KERNELSRCDIR}
make -j$(nproc) INSTALL_MOD_PATH=${KERNELSRCDIR}/debwork LOCALVERSION= modules
make -j$(nproc) INSTALL_MOD_PATH=${KERNELSRCDIR}/debwork LOCALVERSION= modules_install

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
