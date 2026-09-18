#!/usr/bin/env bash
# Build images/guest.qcow2 from the Debian nocloud image, then provision it.
# Run in the container:  ./dev make rootfs   (or ./dev scripts/mkimage.sh)
#
# The stock image has a locked root account, no sshd and no network config,
# so nothing can log in to it. Instead of scripting the console, edit the ext4
# root partition offline with debugfs (no root, no loop mount needed):
#   - DHCP on en*, static resolv.conf (slirp DNS)
#   - empty root password on the console (for debugging; local VM only)
#   - our ssh public key
#   - cbqri-provision.service: first boot runs /root/setup.sh, then powers off
# then boot it once and wait for QEMU to exit.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/images/work"
base="$root/images/debian-13-nocloud-riscv64.qcow2"
out="$root/images/guest.qcow2"
key="$root/images/ssh/id_ed25519"
qemu_img="$root/build/qemu/qemu-img"

mkdir -p "$work" "$(dirname "$key")"
[[ -f $key ]] || ssh-keygen -q -t ed25519 -N "" -C cbqri-io -f "$key"

echo "mkimage: unpacking $base" >&2
"$qemu_img" convert -O raw "$base" "$work/disk.raw"
read -r start size < <(sfdisk -J "$work/disk.raw" | python3 -c '
import json, sys
parts = json.load(sys.stdin)["partitiontable"]["partitions"]
# Linux root (riscv64) partition type
p = next(p for p in parts if p["type"].upper() == "72EC70A6-CF74-40E6-BD49-4BDA08E8F224")
print(p["start"], p["size"])')
dd if="$work/disk.raw" of="$work/root.ext4" bs=512 skip="$start" count="$size" status=none

# Staged files, written into the fs by debugfs below.
stage="$work/stage"; rm -rf "$stage"; mkdir -p "$stage"
cat > "$stage/10-cbqri.network" <<'EOF'
[Match]
Name=en*

[Network]
DHCP=yes
EOF
echo "nameserver 10.0.2.3" > "$stage/resolv.conf"
cat > "$stage/cbqri-provision.service" <<'EOF'
[Unit]
Description=cbqri-io first-boot provisioning
After=systemd-networkd.service
ConditionPathExists=!/var/lib/cbqri-provisioned

# Log via journald -> /dev/console, not to ttyS0 directly: serial-getty's
# vhangup() on ttyS0 would kill a service that holds the tty open.
# ExecStopPost runs whether or not ExecStart succeeded.
[Service]
Type=oneshot
TimeoutStartSec=infinity
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/bin/sh -c '/root/setup.sh && touch /var/lib/cbqri-provisioned && echo CBQRI-PROVISION-OK || echo CBQRI-PROVISION-FAILED'
ExecStopPost=/bin/systemctl --no-block poweroff

[Install]
WantedBy=multi-user.target
EOF
cp "$root/scripts/guest/setup.sh" "$stage/setup.sh"
cp "$key.pub" "$stage/authorized_keys"
debugfs -R 'cat /etc/shadow' "$work/root.ext4" 2>/dev/null \
    | sed 's/^root:[^:]*:/root::/' > "$stage/shadow"

# debugfs `write` refuses to overwrite (so rm first), and copies the host uid
# (so sif afterwards).
debugfs -w -f - "$work/root.ext4" >"$work/debugfs.log" 2>&1 <<EOF
rm /etc/shadow
write $stage/shadow /etc/shadow
sif /etc/shadow uid 0
sif /etc/shadow gid 42
sif /etc/shadow mode 0100640
rm /etc/resolv.conf
write $stage/resolv.conf /etc/resolv.conf
sif /etc/resolv.conf uid 0
sif /etc/resolv.conf gid 0
rm /etc/systemd/network/10-cbqri.network
write $stage/10-cbqri.network /etc/systemd/network/10-cbqri.network
sif /etc/systemd/network/10-cbqri.network uid 0
sif /etc/systemd/network/10-cbqri.network gid 0
sif /etc/systemd/network/10-cbqri.network mode 0100644
mkdir /root/.ssh
sif /root/.ssh mode 040700
rm /root/.ssh/authorized_keys
write $stage/authorized_keys /root/.ssh/authorized_keys
sif /root/.ssh/authorized_keys uid 0
sif /root/.ssh/authorized_keys gid 0
sif /root/.ssh/authorized_keys mode 0100600
write $stage/setup.sh /root/setup.sh
sif /root/setup.sh uid 0
sif /root/setup.sh gid 0
sif /root/setup.sh mode 0100755
write $stage/cbqri-provision.service /etc/systemd/system/cbqri-provision.service
sif /etc/systemd/system/cbqri-provision.service uid 0
sif /etc/systemd/system/cbqri-provision.service gid 0
sif /etc/systemd/system/cbqri-provision.service mode 0100644
symlink /etc/systemd/system/multi-user.target.wants/cbqri-provision.service /etc/systemd/system/cbqri-provision.service
EOF
# debugfs exits 0 even when a command fails. It echoes each command as
# "debugfs: <cmd>" followed by any error; only rm/mkdir may fail (target
# missing / already there).
if awk '/^debugfs 1\./ || /^Allocated inode/ || /^$/ {next} /^debugfs: / {cmd=$2; next}
        cmd != "rm" && cmd != "mkdir" {bad=1; print "debugfs " cmd ": " $0}
        END {exit !bad}' "$work/debugfs.log" >&2; then
    exit 1
fi
e2fsck -fn "$work/root.ext4" >/dev/null

dd if="$work/root.ext4" of="$work/disk.raw" bs=512 seek="$start" conv=notrunc status=none
"$qemu_img" convert -O qcow2 "$work/disk.raw" "$out.part"
rm -f "$work/disk.raw" "$work/root.ext4"

echo "mkimage: first boot (runs setup.sh; apt under TCG takes a while)" >&2
DISK="$out.part" "$root/scripts/run.sh" </dev/null | tee "$work/provision.log" \
    | grep --line-buffered -E 'CBQRI-|setup.sh|^\+ ' >&2 || true
grep -q CBQRI-PROVISION-OK "$work/provision.log" || {
    echo "mkimage: provisioning failed, see $work/provision.log" >&2; exit 1; }
mv "$out.part" "$out"
echo "mkimage: $out ready" >&2
