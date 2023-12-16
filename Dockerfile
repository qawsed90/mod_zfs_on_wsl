FROM mcr.microsoft.com/cbl-mariner/base/core:2.0

RUN tdnf install -y --releasever=2.0 shadow-utils \
  && useradd -U builder --shell /bin/sh --home-dir /home/builder --create-home \
  && tdnf install -y --releasever=2.0 \
    make \
    gcc \
    glibc-devel \
    ncurses-devel \
    binutils \
    kernel-headers \
    flex \
    bison \
    openssl-devel \
    diffutils \
    python3 \
    bc \
    gawk \
    perl \
    dwarves \
    cpio \
    tar \
    xz \
  && tdnf clean all

USER builder
