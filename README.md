# hostCC-experiments CloudLab profile

One receiver + N senders (default 2) on a single LAN, 10.10.1.0/24. Each node uses one experiment port:

| node | IP |
|---|---|
| receiver | 10.10.1.1 |
| sender*i* | 10.10.1.(*i*+1) |

## Use

1. Push this repo to a **public** git host. CloudLab clones it without credentials.
2. CloudLab → Experiments → Create Experiment Profile → *Git Repo* → paste the URL.
3. Instantiate the profile on the cluster that holds the reservation:

| reservation | receiverType | senderType | cluster |
|---|---|---|---|
| Nov 4–11 | c6525-100g | c6525-100g | Utah |
| Nov 12–19 | d7525 | sm110p | Wisconsin |

4. Wait for `setup done` in `/local/logs/setup.log` (~5–10 min), then run `/local/repository/setup/check-net.sh` on the receiver.

## What setup does

`setup/node-setup.sh` runs on every boot.

- **Once:** installs the measurement and traffic tools and the kernel headers. Builds STREAM. Puts `mlnx_qos`/`tc_wrap.py` from upstream mlnx-tools on the PATH. Clones hostCC and its helper repo into `~`, and applies `setup/patches/hostcc-kernel-compat.patch`.
- **Every boot:** sets MTU, the `performance` governor and perf sysctls. Stops irqbalance (pin IRQs yourself). Sets up passwordless ssh between nodes. Writes `/local/hostcc.env` and the hardware inventory `/local/inventory/summary.txt` (NUMA/NPS, DIMM slots, NIC PCIe link, IOMMU mode).

Opt-in: `sudo /local/repository/setup/install-doca-ofed.sh && sudo reboot` replaces the inbox mlx5 driver with DOCA-OFED (e.g. for `diag_cnt`). Once a node is set up the way you want, snapshot it and pass the image URN as `customImage`.

## hostCC notes

- **Kernel:** upstream `src/` only builds on kernels < 5.9, because it calls `sched_setscheduler()` and reads `task->state`. The bundled patch is version-guarded. It was build-tested on Ubuntu 20.04 (5.4), 22.04 (5.15) and 24.04 (6.8).
- **CPU:** its signal and MBA code uses Intel Cascade Lake uncore MSRs. On the AMD (c6525-100g, d7525) and Ice Lake (sm110p, r650) nodes it builds, but its IIO-occupancy readings and MBA writes are meaningless until ported.
- **Not installed:** Intel MLC (license click-through), the netperf logging patch, and ddio-bench (Intel only).
