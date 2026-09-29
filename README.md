# mod_zfs_on_wsl

A toolkit for automatically building and deploying **OpenZFS kernel modules** and related packages (DEB / RPM) tailored for the default WSL2 (Windows Subsystem for Linux) kernel environment.

---

## Overview

In WSL2, toolchain mismatches (such as GCC version disparities or BTF symbol information differences) between the kernel and modules often result in errors when running standard commands like `modprobe zfs`.

This project solves this issue by using a **cross-container IPC architecture** that combines toolchains from the WSL2 base system (Azure Linux / Mariner) and Ubuntu. This ensures that the generated ZFS modules and packages are perfectly aligned with the active WSL2 kernel.

---

## Key Features

1. **Cross-Container IPC Architecture**
   * **Azure Linux 3.0 Container**: Handles the generation of the `kernel-devel` RPM from the official WSL2 kernel source and compiles the ZFS kernel module (`.ko`).
   * **Ubuntu 26.04 Container**: Manages Debian package (DEB) metadata processing and packaging.
   * A background job running on the host (PowerShell) synchronizes build requests and artifacts between containers in real time via a shared directory (`wslc_bridge`).
2. **Automatic Kernel Version Tracking**
   * Dynamically checks the running WSL2 kernel version (`wsl --system uname -r`) and builds modules from the appropriate kernel source.
3. **Skip Logic (Idempotency)**
   * Automatically skips build tasks if output artifacts (RPM/DEB) already exist, significantly reducing build times on subsequent runs.

---

## [Required] OverlayFS Setup for WSL2

In WSL2 v2.1.1 and later environments, `/lib/modules/` may be mounted as read-only (or non-persistently managed by the system).
To successfully install built ZFS modules and ensure `modprobe zfs` works reliably on system boot, **you must configure OverlayFS in `/etc/wsl.conf`**.

### Configuration Steps (Ubuntu / Debian Distribution)

1. Edit `/etc/wsl.conf` inside your distribution (replace `6.18.40.1-microsoft-standard-WSL2` with your actual kernel version from `uname -r`):

```bash
sudo vi /etc/wsl.conf
```

2. Add or update the `command` directive under the `[boot]` section as follows:

```ini
[boot]
command=mount -t overlay overlay -o \
lowerdir=/usr/lib/modules/6.18.40.1-microsoft-standard-WSL2,\
upperdir=/usr/lib/modules_overlay/upper/6.18.40.1-microsoft-standard-WSL2,\
workdir=/usr/lib/modules_overlay/work/6.18.40.1-microsoft-standard-WSL2 \
/usr/lib/modules/6.18.40.1-microsoft-standard-WSL2; \
modprobe zfs
```

3. Restart WSL from Windows PowerShell or Command Prompt:

```powershell
wsl --shutdown
```

---

## Prerequisites

* **Windows 11** (WSL2 environment)
* **wslc.exe** installed and available in path
* Required container images pre-built:
  * `wslkernelbuilder:3.0` (Azure Linux 3.0 base)
  * `ubuntubuilder:26.0` (Ubuntu 26.04 base)

---

## Building Container Images

Build the builder containers using the Dockerfiles located at the root of the repository.

```powershell
# Create build image for Azure Linux
wslc build -f Dockerfile.azure -t wslkernelbuilder:3.0 .

# Create build image for Ubuntu
wslc build -f Dockerfile.ubuntu -t ubuntubuilder:26.0 .
```

---

## Usage

Run `build_openzfs_for_wsl2.ps1` in PowerShell.

### 1. Default Execution (Build DEB packages for ZFS 2.4.4)

```powershell
.\build_openzfs_for_wsl2.ps1
```

### 2. Building Both DEB and RPM Packages (`-BuildRpm`)

```powershell
.\build_openzfs_for_wsl2.ps1 -BuildRpm
```

### 3. Specifying a Target ZFS Version (`-ZFS_TARGET`)

```powershell
.\build_openzfs_for_wsl2.ps1 -ZFS_TARGET "zfs-2.5.0" -BuildRpm
```

---

## Output Artifacts & Installation

When the build completes, packages are output to the `pkg_output` folder in the current directory.

```text
pkg_output/
├── deb/    # Generated .deb packages
└── rpm/    # Generated .rpm packages
```

### Example Package Installation (Ubuntu / Debian)

```bash
# Install essential generated DEB packages
sudo apt install \
  ./pkg_output/deb/openzfs-zfs-modules-6.18.40.1-microsoft-standard-wsl2_2.4.4-1_amd64.deb \
  ./pkg_output/deb/openzfs-zfsutils_2.4.4-1_amd64.deb \
  ./pkg_output/deb/openzfs-libzfs7_2.4.4-1_amd64.deb \
  ./pkg_output/deb/openzfs-libzpool7_2.4.4-1_amd64.deb \
  ./pkg_output/deb/openzfs-libnvpair3_2.4.4-1_amd64.deb \
  ./pkg_output/deb/openzfs-libuutil3_2.4.4-1_amd64.deb

# Manual module loading test
sudo modprobe zfs

# Verify loaded module
lsmod | grep zfs
zpool status
```

---

## License / Disclaimer

These scripts are provided under the MIT License (or the repository's specified license). Source code for ZFS and the Linux Kernel adheres to their respective licenses (CDDL and GPL v2).