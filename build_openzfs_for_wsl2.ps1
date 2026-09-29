<#
.SYNOPSIS
    Automated build script for ZFS kernel modules and packages (DEB/RPM) targeting WSL2 environments.

.DESCRIPTION
    This script automatically generates ZFS kernel modules and related packages (.deb / .rpm)
    tailored to the running kernel in a WSL2 (Windows Subsystem for Linux) environment.

    [Design Philosophy & Architecture]
    1. Cross-Container IPC Architecture
       When building ZFS Debian packages (.deb), Ubuntu toolchains handle packaging metadata while
       Azure Linux (Mariner) toolchains compile the kernel modules (.ko). This script bridges two
       containers via a shared host directory (`wslc_bridge`) and a PowerShell background job
       (Bridge Watcher) to transfer sources and build artifacts in real-time, enabling seamless
       cross-distribution builds.

    2. Toolchain Consistency & Reproducibility
       The script detects the host's active WSL2 kernel version, builds/extracts `kernel-devel` RPMs
       from matching kernel sources, and compiles ZFS against them. This avoids module loading errors
       caused by BTF/symbol mismatches or GCC version discrepancies.

    3. Idempotency & Skip Logic
       If target build artifacts (RPM/DEB) already exist in the output directory (`pkg_output`),
       the corresponding build steps are automatically skipped to minimize build times.

    [Execution Steps]
    - Pre-checks: Verify `wslc.exe`, container images, and detect active WSL kernel version.
    - STEP 1 [Kernel Build / Azure Linux]:
      Build `kernel-devel` and `kernel-debuginfo` RPMs from WSL2 kernel sources.
    - STEP 2 [ZFS RPM Build / Azure Linux] (Only when -BuildRpm switch is set):
      Build ZFS RPM packages for Azure Linux using kernel-devel RPMs from STEP 1.
    - STEP 3 [ZFS DEB Build / Ubuntu Trigger -> Azure Linux Build]:
      - 3.1: Start the Bridge Watcher job and persistent Azure Linux container on the host.
      - 3.2: Trigger Debian package build in Ubuntu. Module compilation requests are offloaded to
             Azure Linux via `wslc_bridge`, and compiled artifacts (.ko) are returned to finalize the DEB.

.PARAMETER ZFS_TARGET
    ZFS source directory name or version tag to build. (Default: "zfs-2.4.4")

.PARAMETER BuildRpm
    Switch to enable building ZFS RPM packages (for Azure Linux / RHEL).
    If omitted, RPM building is skipped and only DEB packages are generated.

.EXAMPLE
    .\build_openzfs_for_wsl2.ps1
    Standard execution. Builds only ZFS 2.4.4 DEB packages.

.EXAMPLE
    .\build_openzfs_for_wsl2.ps1 -BuildRpm
    Builds both ZFS 2.4.4 DEB and RPM packages.

.EXAMPLE
    .\build_openzfs_for_wsl2.ps1 -ZFS_TARGET "zfs-2.5.0" -BuildRpm
    Specifies ZFS version as zfs-2.5.0 and builds both DEB and RPM packages.
#>
param(
    [string]$ZFS_TARGET = "zfs-2.4.4",
    [switch]$BuildRpm
)

$ErrorActionPreference = "Stop"

# Check for the existence of wslc.exe
if (-not (Get-Command "wslc.exe" -ErrorAction SilentlyContinue)) {
    Write-Error "Error: wslc.exe was not found."
    exit 1
}

$IMAGE_AZURE_NAME = "wslkernelbuilder:3.0"
$AZURE_CONTAINER   = "Azure"

$IMAGE_UBUNTU_NAME = "ubuntubuilder:26.0"
$UBUNTU_CONTAINER  = "Ubuntu"

# Check for the existence of the container image
$imageExists = wslc.exe images -f "reference=$IMAGE_AZURE_NAME" -q 2>$null
if ([string]::IsNullOrWhiteSpace($imageExists)) {
    Write-Error "Error: Build container image '$IMAGE_AZURE_NAME' was not found. Please create the image and try again."
    exit 1
}

# Check Ubuntu image existence
$ubuntuImageExists = wslc.exe images -f "reference=$IMAGE_UBUNTU_NAME" -q 2>$null
if ([string]::IsNullOrWhiteSpace($ubuntuImageExists)) {
    Write-Error "Error: Build container image '$IMAGE_UBUNTU_NAME' not found. Please create the image and try again."
    exit 1
}

# Get running WSL kernel version (e.g., 6.18.40.1-microsoft-standard-WSL2 -> 6.18.40.1)
$wslKernelRelease = (wsl.exe --system uname -r 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($wslKernelRelease)) {
    Write-Error "Error: Failed to retrieve WSL kernel version via 'wsl --system uname -r'."
    exit 1
}
$K_VERSION = ($wslKernelRelease -split '-')[0]
$KERNEL_SRC_DIR = "WSL2-Linux-Kernel-linux-msft-wsl-$K_VERSION"
$ZFS_SRC_DIR = $ZFS_TARGET

$HOST_WORK_DIR = Get-Location
$HOST_PKG_DIR = Join-Path $HOST_WORK_DIR "pkg_output"
$HOST_RPM_DIR = Join-Path $HOST_PKG_DIR "rpm"
$HOST_DEB_DIR = Join-Path $HOST_PKG_DIR "deb"
$HOST_BRIDGE = Join-Path $HOST_WORK_DIR "wslc_bridge"

# Create directories
New-Item -ItemType Directory -Force -Path $HOST_RPM_DIR, $HOST_DEB_DIR, $HOST_BRIDGE | Out-Null

# Set default UID / GID to general 1000:1000 in Windows environment instead of Linux UID / GID
# Please adjust according to your environment as needed
$CURRENT_UID = 1000
$CURRENT_GID = 1000

# Common shell snippet: Extract kernel RPMs and setup /tmp/k-src_build structure
$extractKernelSrcSnippet = @"
# 1. Identify kernel RPM files in /host_rpm
DEVEL_RPM=`$(ls /host_rpm/kernel-devel-*.rpm 2>/dev/null | head -n1)
DEBUGINFO_RPM=`$(ls /host_rpm/kernel-debuginfo-*.rpm 2>/dev/null | head -n1)

if [ -z "`${DEVEL_RPM}" ] || [ -z "`${DEBUGINFO_RPM}" ]; then
	echo "Error: Required kernel RPMs were not found in /host_rpm."
	exit 1
fi

# 2. Extract cpio locally in container (/tmp)
TMP_EXTRACT=/tmp/k-src_extract
rm -rf "`${TMP_EXTRACT}"
mkdir -p "`${TMP_EXTRACT}"

cd "`${TMP_EXTRACT}"
rpm2cpio "`${DEVEL_RPM}" | cpio -idmv > /dev/null 2>&1
rpm2cpio "`${DEBUGINFO_RPM}" | cpio -idmv > /dev/null 2>&1

KSRC_TMP=`$(ls -d "`${TMP_EXTRACT}"/usr/src/kernels/* 2>/dev/null | head -n1)
KVER=`$(basename "`${KSRC_TMP}")
echo "Detected Kernel Version from RPM: `${KVER}"

# 3. Copy kernel source into /tmp
LOCAL_KSRC=/tmp/k-src_build
rm -rf "`${LOCAL_KSRC}"
mkdir -p "`${LOCAL_KSRC}"
cp -rf "`${KSRC_TMP}"/* "`${LOCAL_KSRC}/"
find "`${TMP_EXTRACT}" -name vmlinux -exec cp -f {} "`${LOCAL_KSRC}/" \;
export KSRC="`${LOCAL_KSRC}"
export KOBJ="`${LOCAL_KSRC}"

# 4. Create build and source structure in /tmp/lib/modules/`${KVER}/
TMP_MODULES_DIR="/tmp/lib/modules/`${KVER}"
rm -rf "`${TMP_MODULES_DIR}"
mkdir -p "`${TMP_MODULES_DIR}"
ln -snf "`${LOCAL_KSRC}" "`${TMP_MODULES_DIR}/build"
ln -snf "`${LOCAL_KSRC}" "`${TMP_MODULES_DIR}/source"

# Remove temporary extraction directory
rm -rf "`${TMP_EXTRACT}"
"@

Write-Host "=========================================="
Write-Host " STEP 1: Kernel Build (wslc session 1)"
Write-Host "=========================================="

# Extract version string from KERNEL_SRC_DIR (e.g., WSL2-Linux-Kernel-linux-msft-wsl-6.18.40.1 -> 6.18.40.1)
$K_VER_STRING =$KERNEL_SRC_DIR -split '-' | Select-Object -Last 1

# Check for existing kernel-devel RPM files
$develRpm = Get-ChildItem -Path $HOST_RPM_DIR -Filter "kernel-devel-*.rpm" -ErrorAction SilentlyContinue
$debugInfoRpm = Get-ChildItem -Path $HOST_RPM_DIR -Filter "kernel-debuginfo-*.rpm" -ErrorAction SilentlyContinue

if ($develRpm -and $debugInfoRpm) {
    Write-Host "Skipping Kernel build because matching kernel-devel RPM already exists in $HOST_RPM_DIR."
} else {
    $step1Script = @"
set -xe

rm -rf /tmp/build_kernel
mkdir -p /tmp/build_kernel
tar xvfz /host_src/${KERNEL_SRC_DIR}.tar.gz -C /tmp/build_kernel

cd /tmp/build_kernel/${KERNEL_SRC_DIR}
zcat /proc/config.gz > .config
make -j`$(nproc) binrpm-pkg LOCALVERSION=

cp rpmbuild/RPMS/x86_64/*.rpm /host_rpm/
"@

    wslc.exe run --rm -u "${CURRENT_UID}:${CURRENT_GID}" `
        --volume="${HOST_WORK_DIR}:/host_src" `
        --volume="${HOST_RPM_DIR}:/host_rpm" `
        -w /tmp `
        $IMAGE_AZURE_NAME `
        sh -c $step1Script
}

Write-Host "=========================================="
Write-Host " STEP 2: ZFS RPM Build (wslc session 2)"
Write-Host "=========================================="

# Extract version string from ZFS_SRC_DIR (e.g., zfs-2.4.4 -> 2.4.4)
$Z_VER_STRING =$ZFS_SRC_DIR -split '-' | Select-Object -Last 1

# Check for existing zfs RPM files
$existingZfsRpm = Get-ChildItem -Path $HOST_RPM_DIR -Filter "zfs-*$Z_VER_STRING*.rpm" -ErrorAction SilentlyContinue

if (-not $BuildRpm) {
    Write-Host "Skipping ZFS RPM build because -BuildRpm switch was not specified."
} elseif ($existingZfsRpm) {
    Write-Host "Skipping ZFS RPM build because matching zfs RPM already exists in $HOST_RPM_DIR."
} else {
    $step2Script = @"

$extractKernelSrcSnippet

# 5. Extract ZFS source and configure
rm -rf /tmp/build_zfs
mkdir -p /tmp/build_zfs
tar xvfz /host_src/${ZFS_SRC_DIR}.tar.gz -C /tmp/build_zfs

cd /tmp/build_zfs/${ZFS_SRC_DIR}

# Rewrite prefix path check to /tmp/lib/modules/...
sed -i 's|`${prefix}/lib/modules/`${kernel}/|/tmp/lib/modules/`${kernel}/|g' scripts/kmodtool

# Replace hyphens with underscores in kernel release strings across RPM spec directives to prevent RPM naming and syntax errors.
sed -i '/^\s*\(Provides\|Requires\|BuildRequires\|%package\|%post\|%description\|%files\)/s/`${kernel_uname_r}/`${kernel_uname_r\/\/-\/_}/g' scripts/kmodtool

# Additional adjustments such as Mariner support
sed -i 's/\(alpine|arch|artix|debian|gentoo|ubuntu\))/\1|azurelinux)/' configure

./configure \
	--prefix=/usr \
	--sysconfdir=/etc \
	--libdir=/lib \
	--includedir=/usr/include \
	--datarootdir=/usr/share \
	--enable-linux-builtin=no \
	--with-linux="`${LOCAL_KSRC}" \
	--with-linux-obj="`${LOCAL_KSRC}" \
	--with-vendor=azurelinux

# 6. Build RPM
make -j1 rpm-utils rpm-kmod

cp -f *.rpm /host_rpm/

"@

    wslc.exe run --rm -u "${CURRENT_UID}:${CURRENT_GID}" `
        --volume="${HOST_WORK_DIR}:/host_src" `
        --volume="${HOST_RPM_DIR}:/host_rpm" `
        -w /tmp `
        $IMAGE_AZURE_NAME `
        sh -c $step2Script
}

Write-Host "=========================================="
Write-Host " STEP 3: ZFS DEB Build (wslc session 3)"
Write-Host "=========================================="

$Z_VER_STRING = ($ZFS_SRC_DIR -split '-')[-1]
$existingDeb  = Get-ChildItem -Path $HOST_DEB_DIR -Filter "*zfs-*$Z_VER_STRING*.deb" -ErrorAction SilentlyContinue

if ($existingDeb) {
    Write-Host "Skipping ZFS DEB build because matching DEB already exists in $HOST_DEB_DIR."
} else {
    # Clean up previous bridge temporary files
    Remove-Item -Path "$HOST_BRIDGE\*" -Recurse -Force -ErrorAction SilentlyContinue

    # ==========================================
    # Launch & Prepare Azure3 Persistent Container
    # ==========================================
    Write-Host "=========================================="
    Write-Host " [Host] Starting build container ($AZURE_CONTAINER)..."
    Write-Host "=========================================="
    wslc.exe rm -f $AZURE_CONTAINER 2>$null
    wslc.exe run -d --name $AZURE_CONTAINER $IMAGE_AZURE_NAME tail -f /dev/null

    # ==========================================
    # STEP 3.1: Define & Start Background Watcher Job
    # ==========================================
    Write-Host "=========================================="
    Write-Host " [Host] Starting bridge watcher job in background..."
    Write-Host "  Trigger side: $UBUNTU_CONTAINER ($IMAGE_UBUNTU_NAME)"
    Write-Host "  Build side  : $AZURE_CONTAINER ($IMAGE_AZURE_NAME)"
    Write-Host "=========================================="

    $bridgeScript = {
        param($bridgeDir,$azureContainer,$zfsSrcDir)

        $jobFile  = Join-Path $bridgeDir "build.job"
        $doneFile = Join-Path $bridgeDir "build.done"
        $failFile = Join-Path $bridgeDir "build.failed"
        $srcTar   = Join-Path $bridgeDir "zfs_src.tar"
        $kSrcTar  = Join-Path $bridgeDir "k_src.tar"
        $artTar   = Join-Path $bridgeDir "artifacts.tar"

        while ($true) {
            if (Test-Path $jobFile) {
                Remove-Item -Force -ErrorAction SilentlyContinue $doneFile, $failFile,$artTar
                try {
                    # 1. Transfer shared source from Ubuntu container to Azure3
                    $cmdSrc = "wslc.exe exec -i $azureContainer sh -c `"rm -rf /tmp/$zfsSrcDir && mkdir -p /tmp/$zfsSrcDir && tar -xf - -C /tmp/$zfsSrcDir`" < `"$srcTar`""
                    cmd.exe /c $cmdSrc

                    # 2. Transfer kernel headers (/tmp/k-src_build) to Azure3
                    if (Test-Path $kSrcTar) {$cmdKSrc = "wslc.exe exec -i $azureContainer sh -c `"rm -rf /tmp/k-src_build && mkdir -p /tmp/k-src_build && tar -xf - -C /tmp/k-src_build`" < `"$kSrcTar`""
                        cmd.exe /c $cmdKSrc
                    }

                    # 3. Run make modules in Azure3 container (GCC + BTF generation)
                    $cmdMake = "wslc.exe exec -w /tmp/$zfsSrcDir $azureContainer sh -c `"stdbuf -oL -eL /usr/bin/make -j`$(nproc) -C /tmp/$zfsSrcDir/module modules`" > `"$bridgeDir/make_modules.log`" 2>&1"
                    cmd.exe /c $cmdMake
                    if ($LASTEXITCODE -ne 0) { throw "Failed to execute make modules on Azure3." }
                    # 4. Extract artifacts (.ko, Module.symvers, modules.order) to shared area
                    $cmdArt = "wslc.exe exec -w /tmp/$zfsSrcDir $azureContainer sh -c `"find module -type f \( -name '*.ko' -o -name 'Module.symvers' -o -name 'modules.order' \) | tar -cf - -T -`" > `"$artTar`""
                    cmd.exe /c $cmdArt
                    if ($LASTEXITCODE -ne 0) { throw "Failed to create artifacts.tar." }

                    # x. Debug: Output entire build directory in Azure3 to host
                    #$cmdAzureDebug = "wslc.exe exec $azureContainer sh -c `"tar -czf - -C /tmp/$zfsSrcDir .`" > `"$bridgeDir/azure3_debug.tar.gz`""
                    #cmd.exe /c $cmdAzureDebug

                    # 5. Signal success AFTER artifacts.tar is fully created
                    Remove-Item -Force $jobFile
                    New-Item -ItemType File -Force -Path $doneFile | Out-Null
                } catch {
                    # Output internal state of Azure3 even on error
                    #$cmdAzureDebug = "wslc.exe exec $azureContainer sh -c `"tar -czf - -C /tmp/$zfsSrcDir .`" > `"$bridgeDir/azure3_debug.tar.gz`""
                    #cmd.exe /c $cmdAzureDebug 2>$null

                    Remove-Item -Force -ErrorAction SilentlyContinue $jobFile
                    New-Item -ItemType File -Force -Path $failFile | Out-Null
                }
            }
            Start-Sleep -Seconds 1
        }
    }

    # Start background job
    $watcherJob = Start-Job -ScriptBlock $bridgeScript -ArgumentList $HOST_BRIDGE,$AZURE_CONTAINER,$ZFS_SRC_DIR
    Start-Sleep -Milliseconds 500
    if ($watcherJob.State -ne "Running") {
        $jobErr = Receive-Job -Job $watcherJob -ErrorAction SilentlyContinue
        Write-Error "Error: Failed to start bridge watcher job (State: $($watcherJob.State))`n$jobErr"
        exit 1
    }

    try {
        Write-Host "=========================================="
        Write-Host " STEP 3.2: Running ZFS DEB Build ($UBUNTU_CONTAINER Trigger -> $AZURE_CONTAINER Build)"
        Write-Host "=========================================="

        $stepDebScript = @"

$extractKernelSrcSnippet

# 2. Extract ZFS source and run configure
rm -rf /tmp/`${ZFS_SRC_DIR} && mkdir -p /tmp/`${ZFS_SRC_DIR}
tar xvfz /host_src/`${ZFS_SRC_DIR}.tar.gz -C /tmp/`${ZFS_SRC_DIR} --strip-components=1
cd /tmp/`${ZFS_SRC_DIR}

# Apply patch (lowercase KVERS in contrib/debian/rules.in)
#
# WHY THIS PATCH IS NEEDED:
# 1. Debian packaging rules strictly require package names and version fields to be in lowercase.
#    Since WSL2 kernel release strings contain uppercase letters (e.g., "microsoft-standard-WSL2"),
#    they must be lowercased during package generation to avoid dpkg validation errors.
# 2. In this cross-container build architecture, actual kernel module compilation must be offloaded
#    from the Ubuntu container to the Azure container.
#
# WHAT THIS PATCH DOES:
# 1. Introduces KVERS_LOWER to ensure all generated Debian control and package filenames use lowercase kernel versions.
# 2. Replaces the local 'make modules' invocation with an IPC bridge process:
#    - Archives ZFS/kernel sources to the shared /host_bridge directory.
#    - Signals the host watcher job by creating 'build.job'.
#    - Polls for completion ('build.done') from the Azure build container.
#    - Extracts the compiled artifacts (.ko files) back into the working directory upon completion.
patch -p0 << 'EOF'
--- contrib/debian/rules.in
+++ contrib/debian/rules.in
@@ -13,8 +13,9 @@
 ifndef KVERS
 KVERS=`$(shell uname -r)
 endif
+KVERS_LOWER=`$(shell echo `$(KVERS) | tr '[:upper:]' '[:lower:]')
 
-non_epoch_version=`$(shell echo `$(KVERS) | perl -pe 's/^\d+://')
+non_epoch_version=`$(shell echo `$(KVERS) | perl -pe 's/^\d+://; `$`$_ = lc')
 PACKAGE=openzfs-zfs
 pmodules = `$(PACKAGE)-modules-`$(non_epoch_version)
 
@@ -172,9 +173,10 @@
 override_dh_prep-deb-files:
 	for templ in `$(wildcard `$(CURDIR)/debian/*_KVERS_*.in); do \
 		sed -e 's/##KVERS##/`$(KVERS)/g ; s/#KVERS#/`$(KVERS)/g ; s/_KVERS_/`$(KVERS)/g ; s/##KDREV##/`$(KDREV)/g ; s/#KDREV#/`$(KDREV)/g ; s/_KDREV_/`$(KDREV)/g ; s/_ARCH_/`$(DEB_HOST_ARCH)/' \
-		< `$`$templ > ``echo `$`$templ | sed -e 's/_KVERS_/`$(KVERS)/g ; s/_ARCH_/`$(DEB_HOST_ARCH)/g ; s/\.in`$$//'`` ; \
+		< `$`$templ > ``echo `$`$templ | sed -e 's/_KVERS_/`$(KVERS_LOWER)/g ; s/_ARCH_/`$(DEB_HOST_ARCH)/g ; s/\.in`$`$//'`` ; \
 	done
-	sed -e 's/##KVERS##/`$(KVERS)/g ; s/#KVERS#/`$(KVERS)/g ; s/_KVERS_/`$(KVERS)/g ; s/##KDREV##/`$(KDREV)/g ; s/#KDREV#/`$(KDREV)/g ; s/_KDREV_/`$(KDREV)/g ; s/_ARCH_/`$(DEB_HOST_ARCH)/g' \
+	sed -e 's/##KVERS##/`$(KVERS)/g ; s/#KVERS#/`$(KVERS)/g ; s/_KVERS_/`$(KVERS_LOWER)/g ; s/##KDREV##/`$(KDREV)/g ; s/#KDREV#/`$(KDREV)/g ; s/_KDREV_/`$(KDREV)/g ; s/_ARCH_/`$(DEB_HOST_ARCH)/g' \
 	< debian/control.modules.in > debian/control
+	sed -i -E 's/linux-image-[^,]+(\s*\|\s*raspberrypi-kernel)?\s*,?//g' debian/control

 override_dh_configure_modules: override_dh_configure_modules_stamp
@@ -190,7 +192,28 @@
        dh_testroot
        dh_prep

-	`$(MAKE) `$(NJOBS) -C `$(CURDIR)/module modules
+	@echo "[Trigger] Exporting source archives to shared area..."
+	tar -cf /host_bridge/zfs_src.tar -C `$(CURDIR) .
+	tar -cf /host_bridge/k_src.tar -C /tmp/k-src_build .
+	@echo "[Trigger] Issuing build request (build.job) to host..."
+	touch /host_bridge/build.job
+	while true; do \
+		if [ -f /host_bridge/build.done ]; then \
+			echo '#' ; \
+			echo "[Trigger] Module build completed on Azure3."; \
+			break; \
+		fi; \
+		if [ -f /host_bridge/build.failed ]; then \
+			echo '#' ; \
+			echo "[ERROR] Build on Azure3 failed." >&2; \
+			exit 1; \
+		fi; \
+		echo -n '#' ; \
+		sleep 1; \
+	done
+	cat /host_bridge/make_modules.log
+	@echo "[Trigger] Extracting build artifacts..."
+	tar -xf /host_bridge/artifacts.tar -C `$(CURDIR)
EOF

./configure \
	--prefix=/usr \
	--sysconfdir=/etc \
	--libdir=/lib \
	--includedir=/usr/include \
	--datarootdir=/usr/share \
	--enable-linux-builtin=no \
	--with-linux="`${LOCAL_KSRC}" \
	--with-linux-obj="`${LOCAL_KSRC}" \
	--with-vendor=ubuntu

# 3. Create packages (Azure3 module build is automatically triggered via rules.in)
#trap 'echo "[Debug] Archiving current directory to /host_bridge/debug_zfs.tar.gz..."; tar -czf /host_bridge/debug_zfs.tar.gz -C /tmp/`${ZFS_SRC_DIR} . 2>/dev/null || true' EXIT

make -j`$(nproc) KSRC=/tmp/k-src_build KOBJ=/tmp/k-src_build native-deb-utils native-deb-kmod
cp -f ../*.deb /host_deb/

"@

        $currentJob = Get-Job -Id $watcherJob.Id
        Write-Host " [Host] Current watcher job state: $($currentJob.State)"

        wslc.exe run --rm -i -u "${CURRENT_UID}:${CURRENT_GID}" `
            -e ZFS_SRC_DIR="$ZFS_SRC_DIR" `
            --volume="${HOST_WORK_DIR}:/host_src" `
            --volume="${HOST_RPM_DIR}:/host_rpm" `
            --volume="${HOST_DEB_DIR}:/host_deb" `
            --volume="${HOST_BRIDGE}:/host_bridge" `
            -w /tmp `
            $IMAGE_UBUNTU_NAME sh -c $stepDebScript

    } finally {
        # ==========================================
        # Post-processing: Stop Background Watcher Job
        # ==========================================
        Write-Host "=========================================="
        Write-Host " Cleanup: Stopping watcher job and containers..."
        Write-Host "=========================================="
        Stop-Job $watcherJob -ErrorAction SilentlyContinue
        Remove-Job $watcherJob -ErrorAction SilentlyContinue
        Remove-Item -Path "$HOST_BRIDGE\*" -Recurse -Force -ErrorAction SilentlyContinue
        wslc.exe rm -f $AZURE_CONTAINER 2>$null
    }
}

Write-Host "=========================================="
Write-Host " All build processes completed successfully!"
Write-Host " Output packages are saved in:"
Write-Host "   RPMs: $HOST_RPM_DIR"
Write-Host "   DEBs: $HOST_DEB_DIR"
Write-Host "=========================================="
