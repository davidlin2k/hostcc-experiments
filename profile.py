"""Host-congestion testbed: one receiver and N senders on a single LAN.

Instructions:
Experiment LAN is 10.10.1.0/24: `receiver` = 10.10.1.1, `sender1` = 10.10.1.2, `sender2` = 10.10.1.3, ...
Use these IPs in experiments; short hostnames can resolve to the control network.

Setup runs at every boot. Wait for `setup done` at the end of `/local/logs/setup.log`.
Then run `/local/repository/setup/check-net.sh` on the receiver.

* Per-node environment: `/local/hostcc.env` (EXP_IF, RECEIVER_IP, SENDER_IPS, ...)
* Hardware inventory: `/local/inventory/summary.txt`
* Scratch space: `/mydata`
* hostCC (with kernel-compat patch) is cloned to `~/hostCC`; build with `cd ~/hostCC/src && make`.
"""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab as emulab  # noqa: F401  (registers setJumboFrames / setNoBandwidthShaping)

IMG = "urn:publicid:IDN+emulab.net+image+emulab-ops//"
IMAGES = [
    (IMG + "UBUNTU22-64-STD", "Ubuntu 22.04 (kernel 5.15)"),
    (IMG + "UBUNTU24-64-STD", "Ubuntu 24.04 (kernel 6.8)"),
    (IMG + "UBUNTU20-64-STD", "Ubuntu 20.04 (kernel 5.4; hostCC builds without the compat patch)"),
]
SUBNET = "10.10.1."
NETMASK = "255.255.255.0"

pc = portal.Context()

pc.defineParameter(
    "receiverType", "Receiver node type", portal.ParameterType.NODETYPE, "c6525-100g",
    longDescription="Utah: c6525-100g. Wisconsin: d7525. Clemson: r6525, r6615, r650.")
pc.defineParameter(
    "senderType", "Sender node type", portal.ParameterType.NODETYPE, "c6525-100g",
    longDescription="Utah: c6525-100g. Wisconsin: sm110p. Clemson: r6615.")
pc.defineParameter(
    "numSenders", "Number of senders", portal.ParameterType.INTEGER, 2)

pc.defineParameter(
    "osImage", "OS image", portal.ParameterType.IMAGE, IMAGES[0], IMAGES)

pc.defineParameter(
    "customImage", "Custom image URN (overrides OS image)", portal.ParameterType.STRING, "",
    advanced=True, longDescription="Your own snapshot, once a node is fully set up.")
pc.defineParameter(
    "linkGbps", "Experiment link speed (Gbps)", portal.ParameterType.INTEGER, 100, advanced=True,
    longDescription="Used only to pick the 100G port (not the 25G one). Links are never shaped.")
pc.defineParameter(
    "jumbo", "Jumbo frames (host MTU 9000)", portal.ParameterType.BOOLEAN, True, advanced=True)
pc.defineParameter(
    "scratchGB", "Scratch filesystem at /mydata (GB, 0 = none)", portal.ParameterType.INTEGER, 200,
    advanced=True)

params = pc.bindParameters()

if not 1 <= params.numSenders <= 4:
    pc.reportError(portal.ParameterError("Use 1 to 4 senders.", ["numSenders"]))
if params.linkGbps <= 0:
    pc.reportError(portal.ParameterError("Link speed must be positive.", ["linkGbps"]))
if params.scratchGB < 0:
    pc.reportError(portal.ParameterError("Scratch size cannot be negative.", ["scratchGB"]))
pc.verifyParameters()

request = pc.makeRequestRSpec()

lan = request.LAN("lan")
lan.bandwidth = params.linkGbps * 1000 * 1000  # kbps
lan.setNoBandwidthShaping()  # e.g. d7525's 200G port stays at native speed
if params.jumbo:
    lan.setJumboFrames()

mtu = 9000 if params.jumbo else 1500

nodes = [("receiver", params.receiverType)]
nodes += [("sender%d" % i, params.senderType) for i in range(1, params.numSenders + 1)]

for idx, (name, hwtype) in enumerate(nodes):
    node = request.RawPC(name)
    node.hardware_type = hwtype
    node.disk_image = params.customImage.strip() or params.osImage
    node.installRootKeys(True, True)  # root can ssh between nodes (sudo'd harness scripts)

    iface = node.addInterface("if-" + name)
    iface.addAddress(pg.IPv4Address(SUBNET + str(idx + 1), NETMASK))
    lan.addInterface(iface)

    if params.scratchGB > 0:
        bs = node.Blockstore(name + "-bs", "/mydata")
        bs.size = "%dGB" % params.scratchGB

    role = "receiver" if idx == 0 else "sender"
    node.addService(pg.Execute(
        shell="bash",
        command="sudo bash /local/repository/setup/node-setup.sh %s %d %d"
                % (role, mtu, params.numSenders)))

pc.printRequestRSpec(request)
