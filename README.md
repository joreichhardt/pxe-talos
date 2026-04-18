# pxe-talos

Cloud-init recipe that turns a Raspberry Pi into a self-contained PXE/iPXE/Matchbox/DNS/DHCP server for bringing up [Talos Linux](https://www.talos.dev/) nodes on a lab VLAN. The Pi does nothing else — no Talos control plane, no nodes; it is only the infrastructure that hands iPXE + Talos assets to nodes that PXE-boot against it.

## What this repo produces

Running `scripts/render.sh` fills `build/` with a pair of cloud-init files (`user-data` + `network-config`) that, when dropped into the FAT `system-boot` partition of an Ubuntu Server 24.04 Pi image, turn the Pi into a lab-only PXE server on first boot. `scripts/build-image.sh` goes one step further: it downloads the Ubuntu image and injects those files so you can flash the result directly.

## 1. Build the cloud-init artefacts

```bash
cp cloud-init/vars.env.defaults cloud-init/vars.env.local   # optional
$EDITOR cloud-init/vars.env.local                           # override anything you need
scripts/render.sh
scripts/lint.sh
```

`vars.env.local` is gitignored. Common overrides: `SSH_PUBKEY_PATH`, VLAN ID, subnet, upstream DNS.

## 2. Flash the Pi

Two options:

**A. Direct image build (recommended).**

```bash
scripts/build-image.sh                     # -> build/pxe-talos.img
scripts/build-image.sh --device /dev/sdX   # also dd's onto the device (asks to confirm)
```

The script downloads `ubuntu-24.04-preinstalled-server-arm64+raspi.img.xz` (cached in `build/cache/`), copies it, and loop-mounts the FAT partition to drop in `build/user-data` and `build/network-config`.

**B. Manual.** Flash a stock Ubuntu Pi image yourself, mount the `system-boot` partition, and copy `build/user-data` and `build/network-config` onto it.

## 3. First boot

Put the Pi on the switch port wired as a trunk (home VLAN untagged, lab VLAN 10 tagged — see `docs/switch-wiring.md`). Power on, wait 3–5 minutes for cloud-init to finish.

1. Find the Pi on the home LAN (hostname `pxe`). `ssh ubuntu@<ip>`.
2. `scp ubuntu@<pi>:/root/matchbox-client-bundle.tar.gz .`
3. `ssh ubuntu@<pi> 'sudo rm /root/matchbox-client-bundle.tar.gz'` — the bundle is for the operator machine only, no need to keep it on the Pi.

The bundle contains `ca.crt`, `client.crt`, `client.key` for mTLS against the Matchbox gRPC port (8081).

## 4. Bring up Talos

1. Generate real Talos machine configs on your workstation:

   ```bash
   talosctl gen config pxe-talos https://<vip-or-first-cp-ip>:6443
   ```

   Replace `cloud-init/parts/matchbox/assets/configs/controlplane.yaml` and `.../worker.yaml` with the generated files (keep the filenames; they are served as-is by Matchbox). Rerun `scripts/render.sh` if you want to update the Pi's copies via cloud-init; on a running Pi, just `scp` them into `/var/lib/matchbox/assets/configs/`.

2. PXE-boot a node on an access port of VLAN 10. iPXE menu appears — pick controlplane or worker. Talos boots, pulls the config, and goes into maintenance mode until you bootstrap.
3. `talosctl bootstrap --nodes <cp-ip>` once the first controlplane is up.

## 5. Talos-internal VLAN

If you want a separate VLAN for Talos pod/service traffic, declare it inside each node's machine config (static IPs on a tagged sub-interface). This repo does not manage it — the Pi only provides PXE/DHCP on VLAN 10.

## 6. Upgrading Talos

```bash
ssh ubuntu@<pi> 'sudo rm /etc/pxe/talos.env /var/lib/matchbox/assets/.talos-fetched && sudo systemctl restart talos-assets'
```

The talos-assets service re-resolves the latest stable release, re-creates the Factory schematic, downloads fresh kernel+initramfs, and rewrites the Matchbox profiles.

## Variable reference

| Variable | Default | Notes |
|---|---|---|
| `HOSTNAME` | `pxe` | cloud-init hostname |
| `TIMEZONE` | `Europe/Berlin` | |
| `UPLINK_IFACE` | `eth0` | home-LAN side |
| `LAB_VLAN_ID` | `10` | |
| `LAB_IFACE` | `eth0.10` | PXE side |
| `PI_LAB_IP` | `10.10.0.1` | |
| `PI_LAB_CIDR` | `10.10.0.1/24` | |
| `LAB_SUBNET` | `10.10.0.0/24` | for MASQUERADE |
| `DHCP_START` / `DHCP_END` | `10.10.0.100` / `10.10.0.200` | |
| `DHCP_LEASE` | `12h` | |
| `LAB_DOMAIN` | `lab.local` | |
| `UPSTREAM_DNS_LIST` | `"1.1.1.1 9.9.9.9"` | space-separated |
| `MATCHBOX_VERSION` | `v0.10.0` | verify current release before flashing |
| `SSH_PUBKEY_PATH` | `$HOME/.ssh/id_ed25519.pub` | |

## Troubleshooting

- **No PXE menu on the node.** Check the node's port is on VLAN 10 (untagged or tagged, depending on NIC). `ssh ubuntu@<pi> 'sudo journalctl -u dnsmasq -n 100'` — look for `DHCPDISCOVER` from the node MAC.
- **dnsmasq fails to start with "port 53 already in use".** `systemd-resolved`'s stub listener is still on; check that `/etc/systemd/resolved.conf.d/disable-stub.conf` exists and `sudo systemctl restart systemd-resolved` was run.
- **Matchbox mTLS handshake fails.** Check cert permissions (`/etc/matchbox/*.key` 0600, owned by `matchbox`) and SANs (the server cert must list the Pi's lab IP and `pxe.lab.local`).
- **iPXE says "no NIC found".** Some NICs need `snponly.efi`. In dnsmasq, swap `ipxe.efi` for `snponly.efi` in the `dhcp-boot` line and reload.
- **Talos node boots but never reaches maintenance mode.** Check it actually pulled its config: `journalctl` on the node — usually a typo in the `talos.config=` URL or the placeholder config is still served.
