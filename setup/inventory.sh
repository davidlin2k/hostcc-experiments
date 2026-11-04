#!/bin/bash
# Record what this node actually is (CPU/NUMA/NPS, DIMMs, NIC + PCIe link, IOMMU, boot args).
# Raw dumps go to /local/inventory/, a one-screen summary to /local/inventory/summary.txt.
set -u
. /local/hostcc.env 2>/dev/null || true
OUT=/local/inventory
mkdir -p "$OUT"
IF=${EXP_IF:-}

run() { local f=$1; shift; "$@" > "$OUT/$f" 2>&1; }

run lscpu.txt        lscpu
run numa.txt         numactl -H
run dimms.txt        dmidecode -t 17
run cmdline.txt      cat /proc/cmdline
run uname.txt        uname -a
run lspci.txt        lspci -nn
run dmesg-iommu.txt  sh -c "dmesg | grep -iE 'iommu|amd-vi|dmar'"
run cpuidle.txt      sh -c "command -v cpupower >/dev/null && cpupower idle-info"
if [ -n "$IF" ]; then
    run nic-ethtool.txt  sh -c "ethtool $IF; ethtool -i $IF; ethtool -g $IF; ethtool -l $IF; ethtool -c $IF; ethtool -k $IF"
    run nic-stats-boot.txt ethtool -S "$IF"
    run nic-pci.txt      lspci -vvv -s "$EXP_PCI"
    run nic-qos.txt      sh -c "command -v mlnx_qos >/dev/null && mlnx_qos -i $IF"
fi

sockets=$(lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')
numa=$(lscpu | awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2); print $2}')
dimms_total=$(grep -c "^Memory Device" "$OUT/dimms.txt")
dimms_used=$(grep -E "^\s+Size: [0-9]+" "$OUT/dimms.txt" | wc -l)
dimm_locs=$(awk '/^Memory Device/{s=""} /^\s+Size: [0-9]/{s=1} /^\s+Locator:/{if(s) printf "%s ", $2}' "$OUT/dimms.txt")
dimm_speed=$(grep -m1 -E "^\s+Configured Memory Speed: [0-9]" "$OUT/dimms.txt" | sed 's/.*: //')
iommu_types=$(cat /sys/kernel/iommu_groups/*/type 2>/dev/null | sort | uniq -c | tr -s ' ' | paste -sd, -)
boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null | sed 's/^/no_turbo=/')

{
    echo "host:        $(hostname -s)  role=${ROLE:-?}  kernel=$(uname -r)"
    echo "cpu:         $(lscpu | sed -n 's/^Model name: *//p')"
    echo "topology:    sockets=$sockets numa_nodes=$numa ($([ -n "$sockets" ] && [ "$sockets" -gt 0 ] && echo "$((numa / sockets)) per socket, i.e. NPS$((numa / sockets)) on AMD"))  smt=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null)"
    echo "dimms:       $dimms_used of $dimms_total slots populated @ ${dimm_speed:-?}"
    echo "dimm slots:  $dimm_locs"
    echo "boost:       ${boost:-?}  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    echo "cmdline:     $(cat /proc/cmdline)"
    echo "iommu:       groups by default-domain type: ${iommu_types:-none (IOMMU off or no groups)}"
    if [ -n "$IF" ]; then
        echo "nic:         $IF ($EXP_PCI, numa $EXP_NUMA, rdma ${EXP_RDMA:-none}) $(lspci -s "$EXP_PCI" | cut -d: -f3-)"
        echo "nic fw/drv:  $(ethtool -i "$IF" | awk -F': ' '/^driver|^version|^firmware-version/{printf "%s=%s ", $1, $2}')"
        echo "nic link:    $(ethtool "$IF" | sed -n 's/^\s*Speed: //p')  mtu=$(cat /sys/class/net/$IF/mtu)"
        echo "nic pcie:    $(grep -m1 'LnkCap:' "$OUT/nic-pci.txt" | sed 's/^\s*//')"
        echo "             $(grep -m1 'LnkSta:' "$OUT/nic-pci.txt" | sed 's/^\s*//')"
        echo "nic rings:   $(ethtool -g "$IF" 2>/dev/null | awk '/Current/{c=1} c&&/^RX:/{printf "rx=%s ", $2} c&&/^TX:/{printf "tx=%s", $2}')"
    fi
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
