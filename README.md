# mod_zfs_on_wsl
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
$ sudo dpkg -i linux-module-5.15.90.1-microsoft-standard-wsl2_5.15.90.1-1_amd64.deb
$ sudo dpkg -i zfs_2.1.9-1_amd64.deb
```

### check zfs
```
$ sudo zfs version
zfs-2.1.9-1
zfs-kmod-2.1.9-1
```
