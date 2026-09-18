# Build + run environment for the cbqri-io experiments.
# Everything (QEMU build, kernel cross-build, running the guest) happens in here,
# so the host needs nothing but docker.
FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git ca-certificates curl wget xz-utils file \
        python3 python3-venv python3-pip \
        ninja-build meson pkg-config \
        libglib2.0-dev libpixman-1-dev libslirp-dev libfdt-dev zlib1g-dev \
        flex bison bc cpio rsync kmod \
        libssl-dev libelf-dev dwarves \
        gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
        qemu-utils openssh-client e2fsprogs fdisk \
    && rm -rf /var/lib/apt/lists/*

# Run as the invoking user (see ./dev) so build outputs aren't root-owned.
ARG UID=1000
ARG GID=1000
RUN (userdel -r ubuntu 2>/dev/null || true) \
    && (getent group ${GID} >/dev/null || groupadd -g ${GID} dev) \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash dev
USER dev
