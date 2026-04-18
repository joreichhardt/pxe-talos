# Switch wiring

The Pi is a PXE/DHCP server on a single tagged VLAN. Home-LAN access is kept separate on the untagged (native) VLAN, so the Pi reaches the internet for package / Talos-asset downloads and the operator can SSH to it, while PXE traffic never leaks onto the home network.

Example below uses a MikroTik RB5009 with VLAN 1 as the home LAN (untagged/native) and VLAN 10 as the PXE lab. Adapt the concept to any managed switch.

## Ports

| Port | Mode | Native / untagged | Tagged | Purpose |
|---|---|---|---|---|
| `ether1` | trunk → Pi | VLAN 1 (home) | VLAN 10 | Pi gets both home and lab; `eth0` is home, `eth0.10` is lab |
| `ether2`…`etherN` | access | VLAN 10 | — | Talos nodes that PXE-boot |
| `etherM` | trunk (uplink) | VLAN 1 | VLAN 10 (if PXE must traverse) | to a second switch |
| optional | trunk | — | VLAN 20 | Talos-internal traffic between nodes (declared in each node's machine config, not by this repo) |

## DHCP reservation for the Pi

On the home-LAN DHCP server, reserve a stable lease for the Pi's `eth0` MAC so you always know where to `ssh ubuntu@<pi>` (or just rely on the `pxe` hostname and mDNS/DNS).

## Sanity checks

- VLAN 10 is **not** bridged to the home VLAN anywhere except through the Pi's NAT.
- The Pi's `eth0.10` should be the only DHCP server on VLAN 10 — disable any other DHCP on that VLAN.
- If the switch does IGMP snooping or storm control aggressively on VLAN 10, make sure DHCP broadcasts still flow.

## Optional: node-internal VLAN

For cluster-internal traffic you can add a second VLAN (e.g. VLAN 20) carried tagged on the node access ports. The Pi does **not** participate; the VLAN exists only between nodes and is configured inside each node's Talos machine config. See the Talos docs for `machine.network.interfaces` sub-interface syntax.
