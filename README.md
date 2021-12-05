# zfs-on-wsl-by-module
Script to build zfs module for standard WSL2 kernel.

## Build:
```
$ sh build_wsl_module.sh
```

## Install:

### edit /etc/wsl.conf
```
$ cat /etc/wsl.conf
[boot]
command=modprobe zfs
```

### install deb packages for zfs
```
$ sudo dpkg -i linux-module-5.10.74.3-microsoft-standard-wsl2_5.10.74.3-1_amd64.deb
$ sudo dpkg -i zfs_2.1.1-1_amd64.deb
```

### check zfs
```
$ suzo zfs version
zfs-2.1.1-1
zfs-kmod-2.1.1-1
```
