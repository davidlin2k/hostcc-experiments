#!/bin/bash
# Opt-in: replace the inbox mlx5 stack with NVIDIA DOCA-OFED (MLNX_OFED driver, mlnx-tools, MFT).
# Needed for OFED-only features such as the mlx5 debugfs diag_cnt counters.
# Builds the driver with DKMS (~10-15 min), then needs a reboot. Run with sudo.
#   usage: sudo install-doca-ofed.sh [doca-repo-version]   (default: latest-2.9-LTS)
set -euo pipefail
VER=${1:-latest-2.9-LTS}
. /etc/os-release
URL="https://linux.mellanox.com/public/repo/doca/$VER/ubuntu$VERSION_ID/x86_64/"

curl -fsSL https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub \
    | gpg --dearmor --yes -o /usr/share/keyrings/mellanox-doca.gpg
echo "deb [signed-by=/usr/share/keyrings/mellanox-doca.gpg] $URL ./" > /etc/apt/sources.list.d/doca.list

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=900 update
apt-get -y -o DPkg::Lock::Timeout=900 install "linux-headers-$(uname -r)" doca-ofed mft

# DOCA ships mlnx_qos & co.; drop the upstream wrappers so they don't shadow it.
rm -f /usr/local/bin/{mlnx_qos,tc_wrap.py,mlnx_tune,mlnx_perf}

echo "DOCA-OFED installed. Reboot to load the new driver: sudo reboot"
echo "(CloudLab re-runs node-setup.sh on boot; the experiment IP and MTU are re-applied.)"
