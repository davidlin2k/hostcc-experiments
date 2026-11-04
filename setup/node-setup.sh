#!/bin/bash
# Boot-time setup for every node. CloudLab runs it on every boot, so each step
# is idempotent. Package install runs once; tuning is re-applied each boot.
#   usage: node-setup.sh <receiver|sender> <mtu> <num_senders>
set -uo pipefail

ROLE=${1:-sender}
MTU=${2:-9000}
NUM_SENDERS=${3:-2}
SUBNET=10.10.1
REPO=/local/repository
STATE=/var/lib/hostcc-setup

mkdir -p /local/logs "$STATE"
exec > >(tee -a /local/logs/setup.log) 2>&1
echo "=== setup start $(date -Is) role=$ROLE mtu=$MTU senders=$NUM_SENDERS"

log() { echo "[setup] $*"; }

# ---------------------------------------------------------------- packages (once)
if [ ! -f "$STATE/packages.done" ]; then
    export DEBIAN_FRONTEND=noninteractive
    APT="apt-get -y -q -o DPkg::Lock::Timeout=900"
    $APT update

    $APT install \
        build-essential git cmake pkg-config jq tmux htop \
        numactl libnuma-dev hwloc ethtool pciutils dmidecode lshw msr-tools sysstat \
        iperf3 stress-ng \
        rdma-core ibverbs-utils rdmacm-utils perftest infiniband-diags \
        libibverbs-dev librdmacm-dev mstflint \
        linux-tools-common linux-tools-generic \
        python3-pip python3-numpy \
        screen sshpass net-tools python-is-python3
    core_rc=$?

    # hostCC's kernel module needs headers for the running kernel.
    $APT install "linux-headers-$(uname -r)" || log "WARNING: no linux-headers-$(uname -r); hostCC module will not build"

    # Packages that may be missing on some images/kernels; install one by one.
    # intel-cmt-cat = pqos (Intel RDT; also drives AMD L3 CAT / bandwidth enforcement).
    optional="linux-tools-$(uname -r) intel-cmt-cat sockperf netperf cpuid trace-cmd bpftrace"
    grep -q GenuineIntel /proc/cpuinfo && optional="$optional pcm"
    for p in $optional; do
        $APT install "$p" >/dev/null 2>&1 && log "installed $p" || log "skipped $p (not available)"
    done

    # sar history, as hostCC's utils README asks.
    if [ -f /etc/default/sysstat ]; then
        sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
        systemctl restart sysstat >/dev/null 2>&1 || true
    fi

    # mlnx_qos / tc_wrap.py / mlnx_tune / mlnx_perf from upstream mlnx-tools (inbox mlx5 driver is fine).
    # Skipped if DOCA-OFED already provides them.
    if [ ! -d /opt/mlnx-tools ] && ! [ -x /usr/sbin/mlnx_qos ]; then
        git clone -q --depth 1 https://github.com/Mellanox/mlnx-tools /opt/mlnx-tools || log "mlnx-tools clone failed"
    fi
    if [ -d /opt/mlnx-tools/python ] && ! [ -x /usr/sbin/mlnx_qos ]; then
        for t in mlnx_qos tc_wrap.py mlnx_tune mlnx_perf; do
            cat > /usr/local/bin/$t <<EOF
#!/bin/sh
PYTHONPATH=/opt/mlnx-tools/python/Python exec python3 /opt/mlnx-tools/python/$t "\$@"
EOF
            chmod +x /usr/local/bin/$t
        done
    fi

    # STREAM, built for this machine (arrays far larger than L3).
    if [ ! -x /usr/local/bin/stream ]; then
        tmp=$(mktemp -d)
        if curl -fsSL -o "$tmp/stream.c" https://www.cs.virginia.edu/stream/FTP/Code/stream.c; then
            gcc -O3 -march=native -fopenmp -mcmodel=medium \
                -DSTREAM_ARRAY_SIZE=200000000 -DNTIMES=20 \
                "$tmp/stream.c" -o /usr/local/bin/stream && log "built stream"
        fi
        rm -rf "$tmp"
    fi

    if [ "$core_rc" -eq 0 ]; then
        touch "$STATE/packages.done"
    else
        log "WARNING: core package install failed (rc=$core_rc); will retry next boot"
    fi
fi

# ---------------------------------------------------------------- experiment interface
EXP_IF=""
for _ in $(seq 1 30); do
    EXP_IF=$(ip -o -4 addr show | awk -v s="$SUBNET." 'index($4, s) == 1 {print $2; exit}')
    [ -n "$EXP_IF" ] && break
    sleep 2
done
if [ -z "$EXP_IF" ]; then
    log "ERROR: no interface with a $SUBNET.x address"
else
    ip link set dev "$EXP_IF" mtu "$MTU" && log "$EXP_IF mtu $MTU"
fi
EXP_IP=$(ip -o -4 addr show dev "${EXP_IF:-lo}" | awk '{split($4,a,"/"); print a[1]; exit}')
EXP_PCI=$( [ -e "/sys/class/net/${EXP_IF:-none}/device" ] && basename "$(readlink -f /sys/class/net/$EXP_IF/device)" )
EXP_NUMA=$( [ -n "$EXP_IF" ] && cat /sys/class/net/$EXP_IF/device/numa_node 2>/dev/null )
EXP_RDMA=$( [ -n "$EXP_IF" ] && ls /sys/class/net/$EXP_IF/device/infiniband 2>/dev/null | head -1 )

SENDER_IPS=""
for i in $(seq 1 "$NUM_SENDERS"); do SENDER_IPS="$SENDER_IPS $SUBNET.$((i + 1))"; done

cat > /local/hostcc.env <<EOF
ROLE=$ROLE
EXP_IF=$EXP_IF
EXP_IP=$EXP_IP
EXP_PCI=$EXP_PCI
EXP_NUMA=$EXP_NUMA
EXP_RDMA=$EXP_RDMA
MTU=$MTU
RECEIVER_IP=$SUBNET.1
SENDER_IPS="${SENDER_IPS# }"
EOF
chmod 644 /local/hostcc.env

# ---------------------------------------------------------------- host tuning (every boot)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$g" ] && echo performance > "$g"
done
systemctl disable --now irqbalance >/dev/null 2>&1 || true   # pin IRQs explicitly in experiments
modprobe msr 2>/dev/null || true

cat > /etc/sysctl.d/90-hostcc.conf <<EOF
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0
kernel.nmi_watchdog = 0
net.core.rmem_max = 536870912
net.core.wmem_max = 536870912
EOF
sysctl -q -p /etc/sysctl.d/90-hostcc.conf

# ---------------------------------------------------------------- ssh between nodes (experiment creator)
U=$(cat /var/emulab/boot/swapper 2>/dev/null || true)
id "$U" >/dev/null 2>&1 || U=${SUDO_USER:-}
[ "$U" = root ] && U=""
H=$( [ -n "$U" ] && getent passwd "$U" | cut -d: -f6 )
if [ -n "$H" ] && command -v geni-get >/dev/null; then
    if [ ! -f "$H/.ssh/id_rsa" ]; then
        mkdir -p "$H/.ssh" && chmod 700 "$H/.ssh"
        geni-get key > "$H/.ssh/id_rsa" && chmod 600 "$H/.ssh/id_rsa"
        ssh-keygen -y -f "$H/.ssh/id_rsa" > "$H/.ssh/id_rsa.pub"
        grep -qsF -f "$H/.ssh/id_rsa.pub" "$H/.ssh/authorized_keys2" || cat "$H/.ssh/id_rsa.pub" >> "$H/.ssh/authorized_keys2"
        chown -R "$U": "$H/.ssh"
        log "ssh key installed for $U"
    fi
fi

# No host-key prompts between nodes (hostCC's scripts drive peers via sshpass/ssh).
for h in /root ${H:-}; do
    [ -d "$h" ] || continue
    mkdir -p "$h/.ssh" && chmod 700 "$h/.ssh"
    grep -qs "^Host $SUBNET" "$h/.ssh/config" || cat >> "$h/.ssh/config" <<EOF
Host $SUBNET.* receiver sender*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    [ "$h" = /root ] || chown -R "$U": "$h/.ssh"
done

# ---------------------------------------------------------------- hostCC sources (once, in the user's home)
if [ -n "${H:-}" ] && [ -d "$H" ]; then
    as_user() { sudo -u "$U" -H "$@"; }
    clone() { [ -d "$H/$2" ] || as_user git clone -q "$1" "$H/$2" || log "clone of $1 failed"; }
    clone https://github.com/Terabit-Ethernet/hostCC hostCC
    # setup-envir.sh -o 1 runs network_setup.py from this repo
    clone https://github.com/Terabit-Ethernet/Understanding-network-stack-overheads-SIGCOMM-2021 \
          Understanding-network-stack-overheads-SIGCOMM-2021

    # Upstream src/ only builds on kernels < 5.9; the patch is version-guarded, so it is safe on 5.4 too.
    P="$REPO/setup/patches/hostcc-kernel-compat.patch"
    if [ -d "$H/hostCC/.git" ] && ! as_user git -C "$H/hostCC" apply --reverse --check "$P" 2>/dev/null; then
        as_user git -C "$H/hostCC" apply "$P" && log "applied hostCC kernel-compat patch" \
            || log "WARNING: hostCC kernel-compat patch did not apply"
    fi
    [ -n "$EXP_IF" ] && \
        sed -i "s/\"NIC_INTERFACE\": \"[^\"]*\"/\"NIC_INTERFACE\": \"$EXP_IF\"/" "$H/hostCC/src/config.json" 2>/dev/null
    [ -n "$EXP_NUMA" ] && [ "$EXP_NUMA" -ge 0 ] 2>/dev/null && \
        sed -i "s/\"NIC_LOCAL_SOCKET\": [0-9]*/\"NIC_LOCAL_SOCKET\": $EXP_NUMA/" "$H/hostCC/src/config.json" 2>/dev/null
fi

# ---------------------------------------------------------------- inventory (every boot; boot args may change)
bash "$REPO/setup/inventory.sh" || log "inventory failed"

echo "=== setup done $(date -Is)"
