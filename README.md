# mod_zfs_on_wsl
Script to build zfs module for standard WSL2 kernel.

## Build:
```
$ sh build_wsl_module.sh
```

## Install:

### setup /lib/modules
```
$ sudo mkdir -p /usr/lib/modules_overlay/work/6.6.87.2-microsoft-standard-WSL2
$ sudo mkdir -p /usr/lib/modules_overlay/upper/6.6.87.2-microsoft-standard-WSL2
$ sudo mount -t overlay overlay -o \
lowerdir=/usr/lib/modules/6.6.87.2-microsoft-standard-WSL2,\
upperdir=/usr/lib/modules_overlay/upper/6.6.87.2-microsoft-standard-WSL2,\
workdir=/usr/lib/modules_overlay/work/6.6.87.2-microsoft-standard-WSL2 \
/usr/lib/modules/6.6.87.2-microsoft-standard-WSL2
```

### edit /etc/wsl.conf
```
$ cat /etc/wsl.conf
[boot]
command=mount -t overlay overlay -o \
lowerdir=/usr/lib/modules/6.6.87.2-microsoft-standard-WSL2,\
upperdir=/usr/lib/modules_overlay/upper/6.6.87.2-microsoft-standard-WSL2,\
workdir=/usr/lib/modules_overlay/work/6.6.87.2-microsoft-standard-WSL2 \
/usr/lib/modules/6.6.87.2-microsoft-standard-WSL2;\
modprobe zfs
```

### install deb packages for zfs
```
$ sudo dpkg -i linux-module-6.6.87.2-microsoft-standard-wsl2_6.6.87.2-1_amd64.deb
$ sudo dpkg -i zfs_2.3.3-1_amd64.deb
```

### check zfs
```
$ sudo zfs version
zfs-2.3.3-1
zfs-kmod-2.3.3-1
```
