# Top-level build. Run through the container:  ./dev make <target>
#
#   make qemu      build qemu-system-riscv64 into build/qemu
#   make kernel    cross-build Linux into build/linux (Image at arch/riscv/boot/Image)
#   make rootfs    fetch the Debian riscv64 image and build images/guest.qcow2
#   make all       all of the above
#
# Sources live in src/{qemu,linux} (pinned below). Local modifications are kept
# as patch series in patches/{qemu,linux}/ and applied with `make patch`.

ROOT      := $(abspath .)
JOBS      ?= $(shell nproc)

QEMU_TAG  := v11.1.1
LINUX_TAG := v7.2.6
QEMU_SRC  := $(ROOT)/src/qemu
LINUX_SRC := $(ROOT)/src/linux
QEMU_OUT  := $(ROOT)/build/qemu
LINUX_OUT := $(ROOT)/build/linux

QEMU_BIN  := $(QEMU_OUT)/qemu-system-riscv64
KERNEL    := $(LINUX_OUT)/arch/riscv/boot/Image

DEBIAN_IMG_URL := https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-riscv64.qcow2
BASE_IMG  := $(ROOT)/images/debian-13-nocloud-riscv64.qcow2
GUEST_IMG := $(ROOT)/images/guest.qcow2

LINUX_MAKE := $(MAKE) -C $(LINUX_SRC) O=$(LINUX_OUT) ARCH=riscv \
              CROSS_COMPILE=riscv64-linux-gnu- -j$(JOBS)

.PHONY: all src patch qemu kernel kernel-config rootfs clean

all: qemu kernel rootfs

# ---------------------------------------------------------------------------
src: $(QEMU_SRC)/.git $(LINUX_SRC)/.git

$(QEMU_SRC)/.git:
	git clone --depth 1 --branch $(QEMU_TAG) https://gitlab.com/qemu-project/qemu.git $(QEMU_SRC)

$(LINUX_SRC)/.git:
	git clone --depth 1 --branch $(LINUX_TAG) https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git $(LINUX_SRC)

# Apply patches/<tree>/*.patch onto a `cbqri` branch cut from the pinned tag.
# Re-running resets the branch, so the patch files are the source of truth.
patch: src
	scripts/apply-patches.sh $(QEMU_SRC) $(QEMU_TAG) $(ROOT)/patches/qemu
	scripts/apply-patches.sh $(LINUX_SRC) $(LINUX_TAG) $(ROOT)/patches/linux

# ---------------------------------------------------------------------------
# Two trace backends: `log` for eyeballing with -d trace:..., `simple` for the
# high-volume per-translation traces that scripts/ post-process.
$(QEMU_OUT)/build.ninja: | $(QEMU_SRC)/.git
	mkdir -p $(QEMU_OUT)
	cd $(QEMU_OUT) && $(QEMU_SRC)/configure \
		--target-list=riscv64-softmmu \
		--enable-slirp --enable-fdt=system \
		--enable-trace-backends=log,simple \
		--disable-docs --disable-werror

qemu: $(QEMU_OUT)/build.ninja
	ninja -C $(QEMU_OUT) qemu-system-riscv64 qemu-img trace/trace-events-all

# ---------------------------------------------------------------------------
$(LINUX_OUT)/.config: $(ROOT)/configs/guest.config | $(LINUX_SRC)/.git
	mkdir -p $(LINUX_OUT)
	$(LINUX_MAKE) defconfig
	$(LINUX_SRC)/scripts/kconfig/merge_config.sh -m -O $(LINUX_OUT) \
		$(LINUX_OUT)/.config $(ROOT)/configs/guest.config
	$(LINUX_MAKE) olddefconfig
	scripts/check-kconfig.sh $(LINUX_OUT)/.config $(ROOT)/configs/guest.config

kernel-config: $(LINUX_OUT)/.config

kernel: $(LINUX_OUT)/.config
	$(LINUX_MAKE) Image

# ---------------------------------------------------------------------------
$(BASE_IMG):
	mkdir -p $(dir $@)
	curl -L --fail -o $@.part $(DEBIAN_IMG_URL) && mv $@.part $@

rootfs: $(GUEST_IMG)

$(GUEST_IMG): $(BASE_IMG) $(KERNEL) $(QEMU_BIN) scripts/mkimage.sh scripts/guest/setup.sh
	scripts/mkimage.sh

clean:
	rm -rf build
