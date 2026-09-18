#!/bin/sh
# One-time guest provisioning, run as root inside the Debian guest by
# scripts/provision.py. Idempotent.
set -eux
export DEBIAN_FRONTEND=noninteractive

hostnamectl set-hostname cbqri-guest 2>/dev/null || echo cbqri-guest > /etc/hostname

# Background activity (apt timers, man-db, etc.) issues its own DMA and would
# show up as unattributed noise in every measurement. Kill it.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer \
    man-db.timer e2scrub_all.timer fstrim.timer 2>/dev/null || true

apt-get -q update
apt-get -q install -y --no-install-recommends \
    openssh-server rsync fio nvme-cli pciutils fdisk jq python3 \
    bpftrace bpftool trace-cmd

# Key-only root login over ssh (key installed by provision.py).
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/cbqri.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
UseDNS no
EOF
systemctl enable ssh

# Experiments use cgroup v2 io + memory controllers.
grep -q cgroup2 /proc/mounts
echo "+io +memory +cpu" > /sys/fs/cgroup/cgroup.subtree_control || true

mkdir -p /root/cbqri
echo "setup.sh: done"
