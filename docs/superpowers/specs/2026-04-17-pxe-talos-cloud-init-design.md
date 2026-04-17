# PXE Server for Talos Linux via cloud-init on Raspberry Pi

**Date:** 2026-04-17
**Status:** Approved for implementation planning

## Goal

Provision a Raspberry Pi 4/5 as a self-contained PXE server that boots amd64 UEFI nodes into Talos Linux. The server provides DHCP, TFTP, DNS, an iPXE role-selection menu (controlplane / worker), and Matchbox for profile matching and asset serving. The actual Kubernetes cluster bootstrap (secrets, machine configs) is out of scope — this spec delivers the infrastructure that makes node provisioning a single PXE boot + menu choice away.

Everything is produced by a single pair of files (`user-data` + `network-config`) on the SD card's boot partition. No two-stage bootstrap, no external config management.

## Network context

The Pi lives in a multi-VLAN home lab:

```
Internet ── Fritzbox ── MikroTik RB5009 ── managed switch ── Pi (trunk) + Talos nodes
```

Three VLANs are relevant, but the Pi only touches two:

| VLAN | Purpose | Who runs DHCP | Pi presence |
|---|---|---|---|
| Untagged (home LAN) | Internet uplink for the Pi | Fritzbox/RB5009 | `eth0`, DHCP client |
| VLAN 10 (default, overridable) | Management / PXE — where nodes boot | **the Pi** (dnsmasq) | `eth0.10`, static `10.10.0.1/24` |
| VLAN 20 (example; user-defined) | Talos internal / cluster traffic | none — **static IPs** from machine config | none |

The Talos-internal VLAN is purely node-side (configured in `machine.network.interfaces` with `vlans:` blocks). The Pi never has an interface on it; nothing in cloud-init references it.

## Scope

**In scope**

- cloud-init user-data + network-config bringing the Pi up end-to-end on first boot.
- VLAN split on the single onboard Ethernet: untagged uplink + tagged PXE VLAN.
- dnsmasq as authoritative DHCP + TFTP + caching DNS on the PXE VLAN.
- Matchbox (native binary) serving HTTP profiles/assets (`:8080`) and gRPC with mTLS (`:8081`).
- iPXE boot menu for role selection (controlplane / worker / local disk).
- Factory-based Talos assets (kernel + initramfs) with dynamically resolved "latest stable" version and a KubeVirt-suitable schematic.
- PKI bootstrap on first boot (CA + server cert + client cert bundle).
- NAT from the PXE VLAN out the uplink (so Talos nodes reach the internet through the Pi during boot).
- Placeholder Matchbox profiles/groups and dummy machine configs so the boot flow is testable end-to-end.
- README with flashing instructions, switch/VLAN prerequisites, variable overview, and client-bundle retrieval.

**Out of scope**

- `talosctl gen config`, cluster secrets, real machine configs, including the Talos-internal VLAN config on each node.
- `talosctl bootstrap` of the first controlplane.
- Terraform-provider-matchbox code (we only prepare the mTLS endpoint it needs).
- HA / multi-Pi setups.
- IPv6.

## Target environment

- Raspberry Pi 4 or 5, 64-bit, single onboard Ethernet.
- Ubuntu Server 24.04 LTS for Raspberry Pi (arm64).
- Flashed via `rpi-imager` or `dd`. `user-data` + `network-config` dropped into `/boot/firmware/` on the SD card before first boot.
- Managed switch with 802.1Q. Pi's port is a trunk carrying the home VLAN untagged and VLAN 10 tagged. PXE client ports are access ports on VLAN 10.

## Architecture

### Components on the Pi

| Service | Port | Bind | Role |
|---|---|---|---|
| dnsmasq | 67/udp, 69/udp, 53 | `eth0.10` only | DHCP, TFTP, caching DNS for PXE VLAN |
| Matchbox HTTP | 8080/tcp | `0.0.0.0` | iPXE scripts, profile matching, assets, machine-config delivery |
| Matchbox gRPC | 8081/tcp | `0.0.0.0` | mTLS API for `terraform-provider-matchbox` |

No nginx. Matchbox serves its own HTTP. `systemd-resolved` is reconfigured (drop-in `DNSStubListener=no`) so `dnsmasq` can bind :53 on `eth0.10`.

### Filesystem layout

```
/etc/matchbox/
  ca.crt             # mode 0644
  ca.key             # mode 0600
  server.crt         # SANs: 10.10.0.1, pxe.lab.local, <hostname>
  server.key         # mode 0600
  .pki-done          # idempotency sentinel

/etc/dnsmasq.d/
  pxe.conf           # DHCP + TFTP + iPXE handoff + DNS, bound to eth0.10

/etc/pxe/
  talos.env          # TALOS_VERSION, TALOS_SCHEMATIC — persisted once resolved

/etc/systemd/system/
  matchbox.service
  talos-assets.service     # oneshot, after network-online.target

/srv/tftp/
  ipxe.efi
  snponly.efi              # fallback for some UEFI firmware
  undionly.kpxe            # legacy BIOS fallback, unused by default

/var/lib/matchbox/
  profiles/
    talos-controlplane.json
    talos-worker.json
  groups/
    controlplane.json     # selector {"role": "controlplane"} -> talos-controlplane
    worker.json           # selector {"role": "worker"} -> talos-worker
  assets/
    menu.ipxe
    talos/<schematic>/<version>/
      vmlinuz-amd64
      initramfs-amd64.xz
      .done
    configs/
      controlplane.yaml   # placeholder
      worker.yaml         # placeholder

/root/
  matchbox-client-bundle.tar.gz   # client.crt, client.key, ca.crt — scp once, then delete
```

### Network defaults (variables in user-data)

| Parameter | Default | Notes |
|---|---|---|
| Uplink iface | `eth0` | onboard Ethernet, DHCP from RB5009/Fritzbox |
| PXE VLAN ID | `10` | tagged on `eth0` |
| PXE iface | `eth0.10` | created by netplan |
| Pi PXE IP | `10.10.0.1/24` | gateway + DNS for PXE VLAN |
| DHCP range | `10.10.0.100 – 10.10.0.200` | 12h lease |
| Upstream DNS | `1.1.1.1, 9.9.9.9` | dnsmasq forwarders |
| Local domain | `lab.local` | `dhcp-fqdn`, leases → A records |
| NAT | enabled | MASQUERADE `10.10.0.0/24` out `eth0` |

All configurable at the top of `user-data`.

### Boot flow (amd64 UEFI client)

1. Client UEFI sends DHCPDISCOVER on VLAN 10.
2. dnsmasq (listening on `eth0.10`) offers a lease plus `next-server=10.10.0.1`, `filename=ipxe.efi` (matched by DHCP option 93 = `00:07`, user-class ≠ `iPXE`).
3. Client TFTP-downloads `ipxe.efi` and executes it.
4. iPXE sends a second DHCP request; user-class is now `iPXE`, so dnsmasq replies with `filename=http://10.10.0.1:8080/assets/menu.ipxe`.
5. iPXE renders the menu:
   - `1) Talos Controlplane` → `chain http://10.10.0.1:8080/boot.ipxe?role=controlplane&mac=${mac:hexhyp}`
   - `2) Talos Worker` → `chain http://10.10.0.1:8080/boot.ipxe?role=worker&mac=${mac:hexhyp}`
   - `3) Boot from local disk` → `exit`
6. Matchbox matches the group by `role` selector and renders the profile's iPXE snippet:
   ```
   kernel http://10.10.0.1:8080/assets/talos/<schematic>/<version>/vmlinuz-amd64 \
          talos.platform=metal \
          talos.config=http://10.10.0.1:8080/assets/configs/<role>.yaml \
          console=tty0 console=ttyS0
   initrd http://10.10.0.1:8080/assets/talos/<schematic>/<version>/initramfs-amd64.xz
   boot
   ```
7. Talos boots, fetches its machine config from the URL, proceeds with install.

**Chainloading loop avoidance:** `dhcp-match` distinguishes "UEFI without iPXE" (arch 00:07) from "iPXE" (user-class `iPXE`). First path → TFTP `ipxe.efi`. Second → HTTP menu URL.

## Talos assets

`talos-assets.service` is a systemd oneshot running after `network-online.target`:

1. If `/etc/pxe/talos.env` is missing:
   - Resolve latest stable: `curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r .tag_name`.
   - POST the schematic YAML below to `https://factory.talos.dev/schematics`; capture returned `id`.
   - Write both to `/etc/pxe/talos.env`.
2. For `kernel-amd64`, `initramfs-amd64.xz`:
   - `curl -fL --retry 5 --retry-delay 3 https://factory.talos.dev/image/${TALOS_SCHEMATIC}/${TALOS_VERSION}/<file>` → `/var/lib/matchbox/assets/talos/${TALOS_SCHEMATIC}/${TALOS_VERSION}/`.
   - Verify non-empty.
3. Substitute `__SCHEMATIC__` / `__VERSION__` placeholders in Matchbox profiles with real values (in-place `sed`).
4. Write `.done` sentinel in the version directory. Re-runs are no-ops.

**Schematic YAML for KubeVirt hosts:**
```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

To upgrade Talos later: `rm /etc/pxe/talos.env /var/lib/matchbox/assets/talos/*/*/.done && systemctl restart talos-assets`. Already-provisioned nodes are unaffected — assets stay under `<schematic>/<version>/` paths.

## PKI bootstrap

One-time `runcmd` script using `openssl`:

1. Self-signed CA (`CN=matchbox-ca`, 10-year validity).
2. `server.crt` with SANs `DNS:pxe.lab.local`, `DNS:<hostname>`, `IP:10.10.0.1`.
3. `client.crt` (`CN=terraform`) for Terraform-provider-matchbox.
4. Pack `client.crt + client.key + ca.crt` → `/root/matchbox-client-bundle.tar.gz`, mode 0600.
5. Write `/etc/matchbox/.pki-done`.

Private keys generated on-device — never embedded in `user-data`. User retrieves the client bundle once via `scp` and deletes it.

## Services

### matchbox.service

```
[Unit]
Description=Matchbox
After=network-online.target
Wants=network-online.target

[Service]
User=matchbox
Group=matchbox
ExecStart=/usr/local/bin/matchbox \
    -address=0.0.0.0:8080 \
    -rpc-address=0.0.0.0:8081 \
    -data-path=/var/lib/matchbox \
    -assets-path=/var/lib/matchbox/assets \
    -cert-file=/etc/matchbox/server.crt \
    -key-file=/etc/matchbox/server.key \
    -ca-file=/etc/matchbox/ca.crt \
    -log-level=info
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

A dedicated `matchbox` system user/group is created by cloud-init and owns `/var/lib/matchbox`.

### talos-assets.service

Oneshot, `After=network-online.target matchbox.service`, `RemainAfterExit=yes`. Body per the Talos-assets section.

### dnsmasq (`/etc/dnsmasq.d/pxe.conf`)

```
# Bind only to the PXE VLAN — never to the home LAN
interface=eth0.10
bind-interfaces
dhcp-authoritative
except-interface=eth0

# DHCP
dhcp-range=10.10.0.100,10.10.0.200,12h
dhcp-option=option:router,10.10.0.1
dhcp-option=option:dns-server,10.10.0.1
domain=lab.local
dhcp-fqdn

# PXE matching
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:ipxe,175
dhcp-userclass=set:ipxe,iPXE

# PXE handoff
dhcp-boot=tag:efi-x86_64,tag:!ipxe,ipxe.efi
dhcp-boot=tag:ipxe,http://10.10.0.1:8080/assets/menu.ipxe

# TFTP
enable-tftp
tftp-root=/srv/tftp

# DNS
server=1.1.1.1
server=9.9.9.9
cache-size=1000
```

`systemd-resolved` is configured via drop-in to `DNSStubListener=no`.

## Matchbox profiles and groups (initial state)

**`profiles/talos-controlplane.json`** (before placeholder substitution):
```json
{
  "id": "talos-controlplane",
  "name": "Talos Controlplane (amd64)",
  "boot": {
    "kernel": "/assets/talos/__SCHEMATIC__/__VERSION__/vmlinuz-amd64",
    "initrd": ["/assets/talos/__SCHEMATIC__/__VERSION__/initramfs-amd64.xz"],
    "args": [
      "talos.platform=metal",
      "talos.config=http://10.10.0.1:8080/assets/configs/controlplane.yaml",
      "console=tty0",
      "console=ttyS0"
    ]
  }
}
```

**`groups/controlplane.json`**:
```json
{
  "id": "controlplane",
  "profile": "talos-controlplane",
  "selector": { "role": "controlplane" }
}
```

Worker profile/group are analogous. Dummy configs in `assets/configs/{controlplane,worker}.yaml` are minimal but syntactically valid — a node boots into maintenance mode during end-to-end testing.

## iPXE menu

`/var/lib/matchbox/assets/menu.ipxe`:
```
#!ipxe
:start
menu Talos PXE — pick a role
item --gap -- Talos Linux
item cp     Talos Controlplane
item worker Talos Worker
item --gap -- Other
item local  Boot from local disk
item reboot Reboot
choose --default cp --timeout 10000 target && goto ${target}

:cp
chain http://10.10.0.1:8080/boot.ipxe?role=controlplane&mac=${mac:hexhyp}

:worker
chain http://10.10.0.1:8080/boot.ipxe?role=worker&mac=${mac:hexhyp}

:local
exit

:reboot
reboot
```

## network-config (Netplan v2)

```yaml
version: 2
ethernets:
  eth0:
    dhcp4: true
    dhcp6: false
vlans:
  eth0.10:
    id: 10
    link: eth0
    addresses: [10.10.0.1/24]
    dhcp4: false
    dhcp6: false
```

No gateway or nameservers on `eth0.10` — those come via `eth0`'s DHCP (from RB5009). The Pi's own default route and resolvers use the home LAN; PXE clients get `10.10.0.1` as their DNS, and dnsmasq forwards to `1.1.1.1 / 9.9.9.9`.

## user-data structure

Top-of-file variables (edited per deployment):
```
HOSTNAME=pxe
TIMEZONE=Europe/Berlin
UPLINK_IFACE=eth0
LAB_VLAN_ID=10
LAB_IFACE=eth0.10
PI_LAB_IP=10.10.0.1
PI_LAB_CIDR=10.10.0.1/24
LAB_SUBNET=10.10.0.0/24
DHCP_START=10.10.0.100
DHCP_END=10.10.0.200
LAB_DOMAIN=lab.local
UPSTREAM_DNS="1.1.1.1 9.9.9.9"
MATCHBOX_VERSION=v0.10.0
```

Sections, in order:

1. `hostname`, `locale`, `timezone`.
2. `users`: `ubuntu` with an SSH public key inlined from a user-provided `.pub` file at user-data generation time. `sudo: ALL=(ALL) NOPASSWD:ALL`, shell `/bin/bash`. The key value and its source path are not stored in the repository.
3. `package_update: true`, `package_upgrade: false`.
4. `packages`: `dnsmasq`, `curl`, `jq`, `xz-utils`, `openssl`, `ca-certificates`, `iptables-persistent`, `netfilter-persistent`, `vlan`.
5. `write_files`:
   - `/etc/systemd/resolved.conf.d/disable-stub.conf` (`DNSStubListener=no`)
   - `/etc/sysctl.d/99-ip-forward.conf` (`net.ipv4.ip_forward=1`)
   - `/etc/modules-load.d/8021q.conf` (`8021q`)
   - `/etc/dnsmasq.d/pxe.conf`
   - `/etc/systemd/system/matchbox.service`
   - `/etc/systemd/system/talos-assets.service`
   - `/usr/local/sbin/pxe-bootstrap-pki.sh`
   - `/usr/local/sbin/pxe-fetch-talos.sh`
   - `/var/lib/matchbox/assets/menu.ipxe`
   - `/var/lib/matchbox/profiles/{talos-controlplane,talos-worker}.json` (with placeholders)
   - `/var/lib/matchbox/groups/{controlplane,worker}.json`
   - `/var/lib/matchbox/assets/configs/{controlplane,worker}.yaml` (placeholders)
6. `runcmd` (sequential, each idempotent):
   1. `modprobe 8021q`
   2. `systemctl restart systemd-resolved`
   3. `sysctl --system`
   4. Create `matchbox` system user/group; `chown -R matchbox:matchbox /var/lib/matchbox /etc/matchbox`
   5. Download iPXE blobs to `/srv/tftp/` (file-exists guard)
   6. Download Matchbox arm64 tarball, extract to `/usr/local/bin/matchbox` (guard)
   7. `bash /usr/local/sbin/pxe-bootstrap-pki.sh` (sentinel)
   8. `bash /usr/local/sbin/pxe-fetch-talos.sh` (sentinel)
   9. NAT + forwarding rules, idempotent with `iptables -C … || iptables -A …`:
      - `nat POSTROUTING -o eth0 -s 10.10.0.0/24 -j MASQUERADE`
      - `FORWARD -i eth0.10 -o eth0 -j ACCEPT`
      - `FORWARD -i eth0 -o eth0.10 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`
      - `netfilter-persistent save`
   10. `systemctl daemon-reload`
   11. `systemctl enable --now dnsmasq matchbox talos-assets`

## Verification (part of the implementation plan)

1. Flash SD, drop `user-data` + `network-config` into `/boot/firmware/`, boot Pi (connected to trunk port on switch), wait 3–5 minutes.
2. From home LAN (or RB5009 DHCP lease list): find Pi's uplink IP, `ssh ubuntu@<uplink-ip>` with `jre_ed25519`.
3. `ip -br a` shows `eth0` with uplink IP and `eth0.10` with `10.10.0.1/24`.
4. `systemctl is-active dnsmasq matchbox talos-assets` → all active.
5. `ss -tlnp` shows Matchbox on 8080/8081 and dnsmasq on 53 bound to `eth0.10`.
6. `curl -fsS http://10.10.0.1:8080/` returns Matchbox index.
7. `openssl s_client -connect <pi>:8081 -cert client.crt -key client.key -CAfile ca.crt < /dev/null` — mTLS OK.
8. `scp ubuntu@<uplink-ip>:/root/matchbox-client-bundle.tar.gz .` — contents correct.
9. `ls /var/lib/matchbox/assets/talos/*/*/` — `vmlinuz-amd64`, `initramfs-amd64.xz`, `.done` present.
10. **End-to-end:** amd64 UEFI VM (qemu/KVM) on an access port of VLAN 10 → iPXE menu → pick Controlplane → Talos kernel loads → maintenance mode.

## Documentation deliverable

A `README.md` at the repo root with:

- Prerequisites: rpi-imager, Ubuntu Server 24.04 Pi image, managed switch with 802.1Q.
- Switch wiring diagram: Pi port = trunk (home VLAN untagged + VLAN 10 tagged); PXE client ports = access VLAN 10.
- RB5009 note: reserve a DHCP lease for the Pi's MAC on the home VLAN for a stable uplink IP.
- Flashing steps and where to put `user-data` / `network-config`.
- Variable reference.
- How to retrieve and delete the client bundle.
- How to bump Talos version / change the schematic.
- Where placeholder machine configs live and how `talosctl gen config` output replaces them.
- **Talos-internal VLAN note:** cluster nodes should receive their internal-VLAN config in the machine config (`machine.network.interfaces` with a `vlans:` entry pinning a static address). Link to Talos networking docs. This is node-side and not handled by the Pi.

## Risks and open questions

- **Switch prerequisite.** Assumes a managed switch delivering VLAN 10 tagged to the Pi. RB5009 supports this cleanly, but it must be configured: trunk port to Pi (home VLAN untagged + VLAN 10 tagged), access ports to PXE clients (VLAN 10 untagged).
- **Home LAN DHCP reliability.** The Pi's uplink IP is dynamic. Readme tells the user to reserve a DHCP lease for the Pi's MAC on the RB5009.
- **`systemd-resolved` vs `dnsmasq`.** The stub listener is disabled via drop-in; a future Ubuntu upgrade that rewrites `resolved.conf` could re-enable it. Documented.
- **Matchbox version pin.** `MATCHBOX_VERSION=v0.10.0`. Releases are rare; pinning is safer than tracking latest.
- **KubeVirt extensions.** `qemu-guest-agent`, `iscsi-tools`, `util-linux-tools` is a reasonable default; may need adjustment (e.g., `siderolabs/drbd` for replicated storage). Regenerate schematic by re-running `talos-assets`.
- **Single trunk port.** If the Pi's port fails, both uplink and PXE go down. Acceptable for a lab.
- **NAT overlap with RB5009.** The Pi NATs PXE VLAN traffic out its uplink; the RB5009/Fritzbox NATs again to WAN. Double NAT is fine for outbound, harmless for PXE traffic (which is intra-VLAN and never leaves the Pi's NAT domain).
