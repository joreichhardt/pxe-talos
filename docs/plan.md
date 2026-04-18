# Implementation plan

Step-by-step build order for the repo. Each task ends with a lint/render check and a commit. See `docs/design.md` for the overall design.

## Workstation prerequisites

```bash
sudo apt-get install -y gettext-base shellcheck jq cloud-init yamllint dnsmasq xz-utils curl
# plus sudo rights for loop-mounting the Pi image in the build-image step.
```

## File layout

```
pxe-talos/
├── .gitignore
├── README.md
├── build/                          # render output (gitignored)
├── cloud-init/
│   ├── vars.env.defaults           # defaults; vars.env.local overrides (gitignored)
│   ├── network-config.tmpl
│   ├── user-data.tmpl
│   └── parts/
│       ├── dnsmasq/pxe.conf.tmpl
│       ├── modules/8021q.conf
│       ├── resolved/disable-stub.conf
│       ├── sysctl/99-ip-forward.conf
│       ├── systemd/{matchbox,talos-assets}.service
│       ├── scripts/{pxe-bootstrap-pki,pxe-fetch-talos}.sh
│       └── matchbox/
│           ├── profiles/{talos-controlplane,talos-worker}.json.tmpl
│           ├── groups/{controlplane,worker}.json
│           └── assets/
│               ├── menu.ipxe.tmpl
│               └── configs/{controlplane,worker}.yaml
├── docs/
│   ├── design.md
│   ├── plan.md                     # this file
│   └── switch-wiring.md
└── scripts/
    ├── render.sh
    ├── lint.sh
    └── build-image.sh
```

## Variable contract

`cloud-init/vars.env.defaults` holds the defaults; `cloud-init/vars.env.local` (gitignored) overrides. Variables used across templates:

| Variable | Default |
|---|---|
| `HOSTNAME` | `pxe` |
| `TIMEZONE` | `Europe/Berlin` |
| `UPLINK_IFACE` | `eth0` |
| `LAB_VLAN_ID` | `10` |
| `LAB_IFACE` | `eth0.10` |
| `PI_LAB_IP` | `10.10.0.1` |
| `PI_LAB_CIDR` | `10.10.0.1/24` |
| `LAB_SUBNET` | `10.10.0.0/24` |
| `DHCP_START` / `DHCP_END` | `10.10.0.100` / `10.10.0.200` |
| `DHCP_LEASE` | `12h` |
| `LAB_DOMAIN` | `lab.local` |
| `UPSTREAM_DNS_LIST` | `"1.1.1.1 9.9.9.9"` (space-separated) |
| `MATCHBOX_VERSION` | `v0.10.0` (verify current release before running) |
| `SSH_PUBKEY_PATH` | `$HOME/.ssh/id_ed25519.pub` |

`.tmpl` files are rendered with an `envsubst` allowlist so only project variables expand — iPXE `${mac:hexhyp}` and similar survive untouched.

---

## Task 1 — scaffold: vars, render, lint

Files: `cloud-init/vars.env.defaults`, `scripts/render.sh`, `scripts/lint.sh`, `build/.gitkeep`, `.gitignore`.

- [ ] Append to `.gitignore`:

```
build/*
!build/.gitkeep
cloud-init/vars.env.local
```

- [ ] Create `build/.gitkeep` (empty) and `mkdir -p build`.

- [ ] Write `cloud-init/vars.env.defaults`:

```bash
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
DHCP_LEASE=12h

LAB_DOMAIN=lab.local
UPSTREAM_DNS_LIST="1.1.1.1 9.9.9.9"

MATCHBOX_VERSION=v0.10.0

SSH_PUBKEY_PATH="$HOME/.ssh/id_ed25519.pub"
```

- [ ] Write `scripts/render.sh`:

```bash
#!/usr/bin/env bash
# Render cloud-init artefacts into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=/dev/null
source cloud-init/vars.env.defaults
if [[ -f cloud-init/vars.env.local ]]; then
    # shellcheck source=/dev/null
    source cloud-init/vars.env.local
fi

SSH_PUBKEY_PATH_EXPANDED="${SSH_PUBKEY_PATH/#\~/$HOME}"
if [[ ! -f "$SSH_PUBKEY_PATH_EXPANDED" ]]; then
    echo "error: SSH public key not found at $SSH_PUBKEY_PATH_EXPANDED" >&2
    exit 1
fi
SSH_PUBKEY_CONTENT="$(cat "$SSH_PUBKEY_PATH_EXPANDED")"
export SSH_PUBKEY_CONTENT HOSTNAME TIMEZONE UPLINK_IFACE LAB_VLAN_ID LAB_IFACE \
       PI_LAB_IP PI_LAB_CIDR LAB_SUBNET DHCP_START DHCP_END DHCP_LEASE \
       LAB_DOMAIN UPSTREAM_DNS_LIST MATCHBOX_VERSION

render_tmpl() {
    local in="$1" out="$2"
    envsubst '${HOSTNAME} ${TIMEZONE} ${UPLINK_IFACE} ${LAB_VLAN_ID} ${LAB_IFACE} ${PI_LAB_IP} ${PI_LAB_CIDR} ${LAB_SUBNET} ${DHCP_START} ${DHCP_END} ${DHCP_LEASE} ${LAB_DOMAIN} ${UPSTREAM_DNS_LIST} ${MATCHBOX_VERSION} ${SSH_PUBKEY_CONTENT}' < "$in" > "$out"
}

mkdir -p build

# Subsequent tasks append render steps here.

echo "render.sh: done"
```

- [ ] Write `scripts/lint.sh`:

```bash
#!/usr/bin/env bash
# Validate every artefact. Fails on the first error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
check() {
    local name="$1"; shift
    echo "--- $name ---"
    if "$@"; then
        echo "    ok"
    else
        echo "    fail"
        FAIL=1
    fi
}

check "shellcheck" bash -c 'find scripts cloud-init/parts/scripts -type f -name "*.sh" 2>/dev/null | xargs --no-run-if-empty shellcheck'

# Subsequent tasks append checks here.

if [[ $FAIL -ne 0 ]]; then
    echo "LINT FAIL"; exit 1
fi
echo "LINT OK"
```

- [ ] `chmod +x scripts/*.sh && scripts/render.sh && scripts/lint.sh` — both exit 0.

- [ ] Commit: `scaffold render and lint scripts`.

---

## Task 2 — network-config

Files: `cloud-init/network-config.tmpl`, extend `scripts/render.sh` and `scripts/lint.sh`.

- [ ] Create `cloud-init/network-config.tmpl`:

```yaml
version: 2
ethernets:
  ${UPLINK_IFACE}:
    dhcp4: true
    dhcp6: false
vlans:
  ${LAB_IFACE}:
    id: ${LAB_VLAN_ID}
    link: ${UPLINK_IFACE}
    addresses: [${PI_LAB_CIDR}]
    dhcp4: false
    dhcp6: false
```

- [ ] Append to `scripts/render.sh`:

```bash
render_tmpl cloud-init/network-config.tmpl build/network-config
```

- [ ] Append to `scripts/lint.sh`:

```bash
check "yamllint network-config" bash -c '[ -f build/network-config ] && yamllint -d "{rules: {line-length: disable, document-start: disable}}" build/network-config'
```

- [ ] Render + lint. `cat build/network-config` — `eth0` + `eth0.10`, no unexpanded placeholders.

- [ ] Commit: `render network-config from template`.

---

## Task 3 — user-data scaffold

Files: `cloud-init/user-data.tmpl`, extend render + lint.

- [ ] Create `cloud-init/user-data.tmpl`:

```yaml
#cloud-config
hostname: ${HOSTNAME}
preserve_hostname: false
locale: en_US.UTF-8
timezone: ${TIMEZONE}

users:
  - name: ubuntu
    gecos: Default User
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBKEY_CONTENT}

package_update: true
package_upgrade: false
packages:
  - dnsmasq
  - curl
  - jq
  - xz-utils
  - openssl
  - ca-certificates
  - iptables-persistent
  - netfilter-persistent

# write_files and runcmd are appended by scripts/render.sh
```

- [ ] Append to `scripts/render.sh` (after network-config render):

```bash
render_tmpl cloud-init/user-data.tmpl build/user-data
```

- [ ] Append to `scripts/lint.sh`:

```bash
check "cloud-init schema" bash -c '[ -f build/user-data ] && cloud-init schema --config-file build/user-data'
```

- [ ] Render + lint. `head -20 build/user-data` — SSH key expanded, no `${...}` left.

- [ ] Commit: `add user-data scaffold`.

---

## Task 4 — system drop-ins and dnsmasq config

Files: `cloud-init/parts/sysctl/99-ip-forward.conf`, `cloud-init/parts/modules/8021q.conf`, `cloud-init/parts/resolved/disable-stub.conf`, `cloud-init/parts/dnsmasq/pxe.conf.tmpl`, extend render + lint.

- [ ] `cloud-init/parts/sysctl/99-ip-forward.conf`:

```
net.ipv4.ip_forward=1
```

- [ ] `cloud-init/parts/modules/8021q.conf`:

```
8021q
```

- [ ] `cloud-init/parts/resolved/disable-stub.conf`:

```ini
[Resolve]
DNSStubListener=no
```

- [ ] `cloud-init/parts/dnsmasq/pxe.conf.tmpl`:

```
# Bind only to the PXE VLAN.
interface=${LAB_IFACE}
bind-interfaces
dhcp-authoritative
except-interface=${UPLINK_IFACE}

dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
dhcp-option=option:router,${PI_LAB_IP}
dhcp-option=option:dns-server,${PI_LAB_IP}
domain=${LAB_DOMAIN}
dhcp-fqdn

dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:ipxe,175
dhcp-userclass=set:ipxe,iPXE

dhcp-boot=tag:efi-x86_64,tag:!ipxe,ipxe.efi
dhcp-boot=tag:ipxe,http://${PI_LAB_IP}:8080/assets/menu.ipxe

enable-tftp
tftp-root=/srv/tftp
```

DNS forwarders are appended in the render step because `UPSTREAM_DNS_LIST` is space-separated.

- [ ] Append to `scripts/render.sh`:

```bash
mkdir -p build/parts/dnsmasq
render_tmpl cloud-init/parts/dnsmasq/pxe.conf.tmpl build/parts/dnsmasq/pxe.conf
for dns in ${UPSTREAM_DNS_LIST}; do
    echo "server=${dns}" >> build/parts/dnsmasq/pxe.conf
done
echo "cache-size=1000" >> build/parts/dnsmasq/pxe.conf
```

- [ ] Append to `scripts/lint.sh`:

```bash
check "dnsmasq --test" bash -c '[ -f build/parts/dnsmasq/pxe.conf ] && dnsmasq --test -C build/parts/dnsmasq/pxe.conf'
```

- [ ] Render + lint. Expect `dnsmasq: syntax check OK.`

- [ ] Commit: `system drop-ins and dnsmasq config`.

---

## Task 5 — systemd units

Files: `cloud-init/parts/systemd/matchbox.service`, `cloud-init/parts/systemd/talos-assets.service`, extend lint.

- [ ] `cloud-init/parts/systemd/matchbox.service`:

```ini
[Unit]
Description=Matchbox
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
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
RestartSec=3

[Install]
WantedBy=multi-user.target
```

- [ ] `cloud-init/parts/systemd/talos-assets.service`:

```ini
[Unit]
Description=Fetch Talos assets on first boot (idempotent)
After=network-online.target matchbox.service
Wants=network-online.target
ConditionPathExists=!/var/lib/matchbox/assets/.talos-fetched

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pxe-fetch-talos.sh

[Install]
WantedBy=multi-user.target
```

- [ ] Append to `scripts/lint.sh`:

```bash
check "systemd-analyze matchbox"    systemd-analyze verify --no-man cloud-init/parts/systemd/matchbox.service
check "systemd-analyze talos-assets" systemd-analyze verify --no-man cloud-init/parts/systemd/talos-assets.service
```

`systemd-analyze` will warn about the `matchbox` user not existing on the workstation; warnings are not failures.

- [ ] Lint — ok.

- [ ] Commit: `add systemd units`.

---

## Task 6 — helper scripts (PKI, Talos fetch)

Files: `cloud-init/parts/scripts/pxe-bootstrap-pki.sh`, `cloud-init/parts/scripts/pxe-fetch-talos.sh`. Shellcheck from Task 1 covers them.

- [ ] `cloud-init/parts/scripts/pxe-bootstrap-pki.sh`:

```bash
#!/usr/bin/env bash
# Self-signed CA + server cert + client cert for Matchbox mTLS.
# Idempotent via sentinel.
set -euo pipefail

SENTINEL=/etc/matchbox/.pki-done
if [[ -f "$SENTINEL" ]]; then
    echo "pki: already bootstrapped"
    exit 0
fi

DIR=/etc/matchbox
mkdir -p "$DIR"
cd "$DIR"

if [[ -f /etc/pxe/pki.env ]]; then
    # shellcheck source=/dev/null
    source /etc/pxe/pki.env
fi
: "${PI_LAB_IP:?PI_LAB_IP required}"
: "${HOSTNAME:?HOSTNAME required}"
: "${LAB_DOMAIN:?LAB_DOMAIN required}"

openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/CN=matchbox-ca" -out ca.crt

openssl genrsa -out server.key 4096
openssl req -new -key server.key -subj "/CN=pxe.${LAB_DOMAIN}" -out server.csr
cat > server.ext <<EOF
subjectAltName = DNS:pxe.${LAB_DOMAIN},DNS:${HOSTNAME},IP:${PI_LAB_IP}
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 3650 -sha256 -extfile server.ext

openssl genrsa -out client.key 4096
openssl req -new -key client.key -subj "/CN=terraform" -out client.csr
cat > client.ext <<EOF
extendedKeyUsage = clientAuth
EOF
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days 3650 -sha256 -extfile client.ext

chmod 600 ca.key server.key client.key
chmod 644 ca.crt server.crt client.crt
chown -R matchbox:matchbox "$DIR"
chmod 600 "$DIR"/ca.key "$DIR"/server.key

tar czf /root/matchbox-client-bundle.tar.gz -C "$DIR" ca.crt client.crt client.key
chmod 600 /root/matchbox-client-bundle.tar.gz

rm -f "$DIR"/server.csr "$DIR"/server.ext "$DIR"/client.csr "$DIR"/client.ext "$DIR"/ca.srl
touch "$SENTINEL"
echo "pki: client bundle at /root/matchbox-client-bundle.tar.gz"
```

- [ ] `cloud-init/parts/scripts/pxe-fetch-talos.sh`:

```bash
#!/usr/bin/env bash
# Resolve latest stable Talos, create Factory schematic, download assets,
# and substitute __SCHEMATIC__/__VERSION__ in Matchbox profiles. Idempotent.
set -euo pipefail

ENV_FILE=/etc/pxe/talos.env
SENTINEL=/var/lib/matchbox/assets/.talos-fetched

if [[ -f "$SENTINEL" ]]; then
    echo "talos: assets already fetched"
    exit 0
fi

mkdir -p /etc/pxe /var/lib/matchbox/assets

if [[ ! -f "$ENV_FILE" ]]; then
    TALOS_VERSION="$(curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r .tag_name)"
    [[ -n "$TALOS_VERSION" && "$TALOS_VERSION" != "null" ]] || { echo "cannot resolve Talos version" >&2; exit 1; }

    read -r -d '' SCHEMATIC_YAML <<'YAML' || true
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
YAML
    TALOS_SCHEMATIC="$(curl -fsSL -X POST -H 'Content-Type: application/x-yaml' \
        --data-binary "$SCHEMATIC_YAML" \
        https://factory.talos.dev/schematics | jq -r .id)"
    [[ -n "$TALOS_SCHEMATIC" && "$TALOS_SCHEMATIC" != "null" ]] || { echo "cannot create schematic" >&2; exit 1; }

    printf 'TALOS_VERSION=%s\nTALOS_SCHEMATIC=%s\n' "$TALOS_VERSION" "$TALOS_SCHEMATIC" > "$ENV_FILE"
fi

# shellcheck source=/dev/null
source "$ENV_FILE"
: "${TALOS_VERSION:?}"
: "${TALOS_SCHEMATIC:?}"

ASSET_DIR="/var/lib/matchbox/assets/talos/${TALOS_SCHEMATIC}/${TALOS_VERSION}"
mkdir -p "$ASSET_DIR"

for f in kernel-amd64 initramfs-amd64.xz; do
    out="$ASSET_DIR/$f"
    if [[ ! -s "$out" ]]; then
        curl -fL --retry 5 --retry-delay 3 -o "$out" \
            "https://factory.talos.dev/image/${TALOS_SCHEMATIC}/${TALOS_VERSION}/${f}"
    fi
    [[ -s "$out" ]] || { echo "missing $out" >&2; exit 1; }
done

mv -f "$ASSET_DIR/kernel-amd64" "$ASSET_DIR/vmlinuz-amd64"

for profile in /var/lib/matchbox/profiles/*.json; do
    sed -i -e "s|__SCHEMATIC__|${TALOS_SCHEMATIC}|g" -e "s|__VERSION__|${TALOS_VERSION}|g" "$profile"
done

chown -R matchbox:matchbox /var/lib/matchbox
touch "$SENTINEL"
echo "talos: assets at $ASSET_DIR"
```

- [ ] Lint — shellcheck passes.

- [ ] Commit: `add PKI and Talos-fetch scripts`.

---

## Task 7 — Matchbox assets

Files: `menu.ipxe.tmpl`, two profile templates, two group JSON files, two placeholder configs, extend render + lint.

- [ ] `cloud-init/parts/matchbox/assets/menu.ipxe.tmpl`:

```
#!ipxe
:start
menu Talos PXE - pick a role
item --gap -- Talos Linux
item cp     Talos Controlplane
item worker Talos Worker
item --gap -- Other
item local  Boot from local disk
item reboot Reboot
choose --default cp --timeout 10000 target && goto ${target}

:cp
chain http://${PI_LAB_IP}:8080/boot.ipxe?role=controlplane&mac=${mac:hexhyp}

:worker
chain http://${PI_LAB_IP}:8080/boot.ipxe?role=worker&mac=${mac:hexhyp}

:local
exit

:reboot
reboot
```

- [ ] `cloud-init/parts/matchbox/profiles/talos-controlplane.json.tmpl`:

```json
{
  "id": "talos-controlplane",
  "name": "Talos Controlplane (amd64)",
  "boot": {
    "kernel": "/assets/talos/__SCHEMATIC__/__VERSION__/vmlinuz-amd64",
    "initrd": ["/assets/talos/__SCHEMATIC__/__VERSION__/initramfs-amd64.xz"],
    "args": [
      "talos.platform=metal",
      "talos.config=http://${PI_LAB_IP}:8080/assets/configs/controlplane.yaml",
      "console=tty0",
      "console=ttyS0"
    ]
  }
}
```

- [ ] `cloud-init/parts/matchbox/profiles/talos-worker.json.tmpl`: same structure, `id` and `name` say `talos-worker`, `talos.config=` points at `worker.yaml`.

- [ ] `cloud-init/parts/matchbox/groups/controlplane.json`:

```json
{"id":"controlplane","profile":"talos-controlplane","selector":{"role":"controlplane"}}
```

- [ ] `cloud-init/parts/matchbox/groups/worker.json`:

```json
{"id":"worker","profile":"talos-worker","selector":{"role":"worker"}}
```

- [ ] `cloud-init/parts/matchbox/assets/configs/controlplane.yaml`:

```yaml
# Placeholder. Replace with `talosctl gen config` output.
version: v1alpha1
debug: false
persist: true
machine:
  type: controlplane
  install:
    disk: /dev/sda
    wipe: false
cluster:
  clusterName: pxe-talos-placeholder
```

- [ ] `cloud-init/parts/matchbox/assets/configs/worker.yaml`: same as above with `type: worker`.

- [ ] Append to `scripts/render.sh`:

```bash
mkdir -p build/parts/matchbox/profiles build/parts/matchbox/groups build/parts/matchbox/assets/configs
render_tmpl cloud-init/parts/matchbox/profiles/talos-controlplane.json.tmpl build/parts/matchbox/profiles/talos-controlplane.json
render_tmpl cloud-init/parts/matchbox/profiles/talos-worker.json.tmpl      build/parts/matchbox/profiles/talos-worker.json
cp cloud-init/parts/matchbox/groups/controlplane.json         build/parts/matchbox/groups/
cp cloud-init/parts/matchbox/groups/worker.json               build/parts/matchbox/groups/
cp cloud-init/parts/matchbox/assets/configs/controlplane.yaml build/parts/matchbox/assets/configs/
cp cloud-init/parts/matchbox/assets/configs/worker.yaml       build/parts/matchbox/assets/configs/
render_tmpl cloud-init/parts/matchbox/assets/menu.ipxe.tmpl   build/parts/matchbox/assets/menu.ipxe
```

- [ ] Append to `scripts/lint.sh`:

```bash
check "jq matchbox json" bash -c 'for f in build/parts/matchbox/profiles/*.json build/parts/matchbox/groups/*.json; do jq empty "$f" || exit 1; done'
check "yamllint placeholder configs" bash -c 'yamllint -d "{rules: {line-length: disable, document-start: disable, truthy: disable}}" build/parts/matchbox/assets/configs/controlplane.yaml build/parts/matchbox/assets/configs/worker.yaml'
check "ipxe var preserved" bash -c 'grep -q "\${mac:hexhyp}" build/parts/matchbox/assets/menu.ipxe'
```

- [ ] Render + lint — ok. Verify `${PI_LAB_IP}` expanded but `${mac:hexhyp}` intact in `menu.ipxe`; `__SCHEMATIC__`/`__VERSION__` still literal in profiles.

- [ ] Commit: `matchbox profiles, groups, menu, placeholders`.

---

## Task 8 — assemble user-data (write_files + runcmd)

Files: modify `scripts/render.sh` to append `write_files` and `runcmd` to `build/user-data`.

- [ ] Append to `scripts/render.sh`:

```bash
USER_DATA=build/user-data

emit_write_file() {
    local src="$1" dest="$2" perms="$3" owner="$4"
    {
        echo "  - path: $dest"
        echo "    permissions: '$perms'"
        echo "    owner: $owner"
        echo "    content: |"
        sed 's/^/      /' "$src"
        echo ""
    } >> "$USER_DATA"
}

echo "write_files:" >> "$USER_DATA"

emit_write_file cloud-init/parts/resolved/disable-stub.conf   /etc/systemd/resolved.conf.d/disable-stub.conf 0644 root:root
emit_write_file cloud-init/parts/sysctl/99-ip-forward.conf    /etc/sysctl.d/99-ip-forward.conf                0644 root:root
emit_write_file cloud-init/parts/modules/8021q.conf           /etc/modules-load.d/8021q.conf                  0644 root:root
emit_write_file build/parts/dnsmasq/pxe.conf                  /etc/dnsmasq.d/pxe.conf                         0644 root:root

emit_write_file cloud-init/parts/systemd/matchbox.service     /etc/systemd/system/matchbox.service            0644 root:root
emit_write_file cloud-init/parts/systemd/talos-assets.service /etc/systemd/system/talos-assets.service        0644 root:root

emit_write_file cloud-init/parts/scripts/pxe-bootstrap-pki.sh /usr/local/sbin/pxe-bootstrap-pki.sh            0755 root:root
emit_write_file cloud-init/parts/scripts/pxe-fetch-talos.sh   /usr/local/sbin/pxe-fetch-talos.sh              0755 root:root

{
    echo "  - path: /etc/pxe/pki.env"
    echo "    permissions: '0644'"
    echo "    owner: root:root"
    echo "    content: |"
    echo "      PI_LAB_IP=${PI_LAB_IP}"
    echo "      HOSTNAME=${HOSTNAME}"
    echo "      LAB_DOMAIN=${LAB_DOMAIN}"
    echo ""
} >> "$USER_DATA"

emit_write_file build/parts/matchbox/assets/menu.ipxe                 /var/lib/matchbox/assets/menu.ipxe                  0644 root:root
emit_write_file build/parts/matchbox/profiles/talos-controlplane.json /var/lib/matchbox/profiles/talos-controlplane.json  0644 root:root
emit_write_file build/parts/matchbox/profiles/talos-worker.json       /var/lib/matchbox/profiles/talos-worker.json        0644 root:root
emit_write_file build/parts/matchbox/groups/controlplane.json         /var/lib/matchbox/groups/controlplane.json          0644 root:root
emit_write_file build/parts/matchbox/groups/worker.json               /var/lib/matchbox/groups/worker.json                0644 root:root
emit_write_file build/parts/matchbox/assets/configs/controlplane.yaml /var/lib/matchbox/assets/configs/controlplane.yaml  0644 root:root
emit_write_file build/parts/matchbox/assets/configs/worker.yaml       /var/lib/matchbox/assets/configs/worker.yaml        0644 root:root

cat >> "$USER_DATA" <<EOF
runcmd:
  - [ modprobe, 8021q ]
  - [ systemctl, restart, systemd-resolved ]
  - [ sysctl, --system ]
  - [ sh, -c, "getent passwd matchbox >/dev/null || useradd --system --home /var/lib/matchbox --shell /usr/sbin/nologin matchbox" ]
  - [ install, -d, -o, matchbox, -g, matchbox, /var/lib/matchbox, /var/lib/matchbox/assets, /var/lib/matchbox/profiles, /var/lib/matchbox/groups, /etc/matchbox ]
  - [ install, -d, /srv/tftp ]
  - [ sh, -c, "[ -f /srv/tftp/ipxe.efi ] || curl -fLo /srv/tftp/ipxe.efi http://boot.ipxe.org/ipxe.efi" ]
  - [ sh, -c, "[ -f /srv/tftp/snponly.efi ] || curl -fLo /srv/tftp/snponly.efi http://boot.ipxe.org/snponly.efi" ]
  - [ sh, -c, "[ -f /srv/tftp/undionly.kpxe ] || curl -fLo /srv/tftp/undionly.kpxe http://boot.ipxe.org/undionly.kpxe" ]
  - [ sh, -c, "[ -x /usr/local/bin/matchbox ] || ( cd /tmp && curl -fLo matchbox.tgz https://github.com/poseidon/matchbox/releases/download/${MATCHBOX_VERSION}/matchbox-${MATCHBOX_VERSION}-linux-arm64.tar.gz && tar xzf matchbox.tgz && install -m 0755 matchbox-${MATCHBOX_VERSION}-linux-arm64/matchbox /usr/local/bin/matchbox && rm -rf matchbox.tgz matchbox-${MATCHBOX_VERSION}-linux-arm64 )" ]
  - [ bash, /usr/local/sbin/pxe-bootstrap-pki.sh ]
  - [ sh, -c, "iptables -t nat -C POSTROUTING -o ${UPLINK_IFACE} -s ${LAB_SUBNET} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${UPLINK_IFACE} -s ${LAB_SUBNET} -j MASQUERADE" ]
  - [ sh, -c, "iptables -C FORWARD -i ${LAB_IFACE} -o ${UPLINK_IFACE} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${LAB_IFACE} -o ${UPLINK_IFACE} -j ACCEPT" ]
  - [ sh, -c, "iptables -C FORWARD -i ${UPLINK_IFACE} -o ${LAB_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${UPLINK_IFACE} -o ${LAB_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" ]
  - [ netfilter-persistent, save ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, dnsmasq, matchbox, talos-assets ]
EOF
```

`<<EOF` (not `<<'EOF'`) so `${UPLINK_IFACE}`, `${LAB_SUBNET}`, `${LAB_IFACE}`, `${MATCHBOX_VERSION}` expand at render time into literal values in `build/user-data`.

- [ ] Render + lint — `cloud-init schema` validates the full file.

- [ ] Spot-check:

```bash
for p in /etc/dnsmasq.d/pxe.conf /etc/systemd/system/matchbox.service /usr/local/sbin/pxe-bootstrap-pki.sh /var/lib/matchbox/assets/menu.ipxe; do
    grep -q "path: $p" build/user-data && echo "ok $p" || echo "MISSING $p"
done
grep -n '\${' build/user-data | grep -vE 'mac:hexhyp|target' || echo "no unexpanded placeholders"
```

- [ ] Commit: `assemble user-data write_files and runcmd`.

---

## Task 9 — README and switch-wiring doc

Files: `README.md`, `docs/switch-wiring.md`.

- [ ] `README.md` — usage in four sections:
  1. What this repo produces (one paragraph).
  2. Build: `cp cloud-init/vars.env.defaults cloud-init/vars.env.local`, edit, `scripts/render.sh`, `scripts/lint.sh`.
  3. Flash: either `scripts/build-image.sh` → `build/pxe-talos.img`, then `rpi-imager`/`dd`; or flash stock Ubuntu Pi image, copy `build/user-data` + `build/network-config` into the FAT `system-boot` partition manually.
  4. Find the Pi on the home LAN (hostname `pxe`), SSH in, fetch `matchbox-client-bundle.tar.gz` via scp, delete it on the Pi afterwards.
  5. PXE-boot a node, pick role, swap placeholder configs with `talosctl gen config` output, `talosctl bootstrap`.
  6. Talos-internal VLAN note: static IPs, declared in each node's machine config, not handled by this repo.
  7. Upgrade Talos: `rm /etc/pxe/talos.env /var/lib/matchbox/assets/.talos-fetched && systemctl restart talos-assets`.
  8. Variable reference table.
  9. Troubleshooting: no PXE menu → check VLAN; `dnsmasq` port 53 busy → check `disable-stub.conf`; mTLS fails → check cert permissions + SAN; iPXE "no NIC" → try `snponly.efi`.

- [ ] `docs/switch-wiring.md` — RB5009 trunk on Pi port (home VLAN untagged + VLAN 10 tagged), access ports for clients on VLAN 10, reserve DHCP lease for Pi's MAC, optional VLAN 20 tagged on node ports for Talos-internal traffic.

- [ ] Commit: `add README and switch-wiring doc`.

---

## Task 10 — build-image script

File: `scripts/build-image.sh`.

Produces a ready-to-flash `.img` by downloading the Ubuntu Server 24.04 Pi image, cloning it, and injecting `build/user-data` + `build/network-config` into its FAT `system-boot` partition. Optional `--device /dev/sdX` writes the image directly via `dd` (with a confirmation prompt).

- [ ] Write `scripts/build-image.sh`:

```bash
#!/usr/bin/env bash
# Build a ready-to-flash Raspberry Pi image with user-data + network-config injected.
#
# Usage:
#   scripts/build-image.sh                   # writes build/pxe-talos.img
#   scripts/build-image.sh --device /dev/sdX # also dd's the image onto the device
#
# Requires sudo for loop-mounting. Run in a TTY so the confirmation prompt works.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CACHE="build/cache"
OUT="build/pxe-talos.img"
UBUNTU_URL="https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04-preinstalled-server-arm64+raspi.img.xz"
UBUNTU_XZ="$CACHE/$(basename "$UBUNTU_URL")"
UBUNTU_IMG="${UBUNTU_XZ%.xz}"

DEVICE=""
if [[ "${1:-}" == "--device" ]]; then
    DEVICE="${2:?--device requires a path}"
fi

# Ensure render output exists
if [[ ! -f build/user-data || ! -f build/network-config ]]; then
    echo "build-image: running render first"
    scripts/render.sh
fi

mkdir -p "$CACHE"

if [[ ! -f "$UBUNTU_XZ" ]]; then
    echo "build-image: downloading $UBUNTU_URL"
    curl -fL -o "$UBUNTU_XZ" "$UBUNTU_URL"
fi
if [[ ! -f "$UBUNTU_IMG" ]]; then
    echo "build-image: decompressing"
    xz -dk "$UBUNTU_XZ"
fi

echo "build-image: copying base image -> $OUT"
cp -f "$UBUNTU_IMG" "$OUT"

echo "build-image: injecting cloud-init (needs sudo)"
LOOP=$(sudo losetup -f --show -P "$OUT")
trap 'sudo losetup -d "$LOOP" 2>/dev/null || true' EXIT
MNT=$(mktemp -d)
sudo mount "${LOOP}p1" "$MNT"
sudo cp build/user-data build/network-config "$MNT/"
sudo sync
sudo umount "$MNT"
rmdir "$MNT"
sudo losetup -d "$LOOP"
trap - EXIT

echo "build-image: image ready at $OUT"

if [[ -n "$DEVICE" ]]; then
    if [[ ! -b "$DEVICE" ]]; then
        echo "error: $DEVICE is not a block device" >&2
        exit 1
    fi
    echo
    lsblk "$DEVICE"
    echo
    read -r -p "Write $OUT -> $DEVICE? This ERASES $DEVICE. Type 'yes' to confirm: " ans
    [[ "$ans" == "yes" ]] || { echo "aborted"; exit 0; }
    sudo dd if="$OUT" of="$DEVICE" bs=4M status=progress conv=fsync
    sudo sync
    echo "build-image: wrote image to $DEVICE"
fi
```

- [ ] `chmod +x scripts/build-image.sh`.

- [ ] Dry-run validation (do not actually build if you don't want to wait for ~1 GB download): `bash -n scripts/build-image.sh` and `shellcheck scripts/build-image.sh` — both clean.

- [ ] Commit: `add build-image script`.

Real run (manual, not part of lint):

```bash
scripts/build-image.sh
# -> build/pxe-talos.img, flashable with rpi-imager / balenaEtcher / dd

# or direct-write:
scripts/build-image.sh --device /dev/sdX
```

---

## Task 11 — end-to-end verification

Manual checklist against real hardware. Capture the outcomes in the README troubleshooting section if anything needs documenting permanently.

- [ ] Flash `build/pxe-talos.img` to SD card (or run with `--device`).
- [ ] Power on the Pi on the switch trunk port. Wait 3–5 minutes.
- [ ] Find Pi on home LAN (hostname `pxe`), `ssh ubuntu@<ip>`.
- [ ] `ip -br a` → `eth0` home IP + `eth0.10` `10.10.0.1/24`.
- [ ] `systemctl is-active dnsmasq matchbox talos-assets` → three `active`.
- [ ] `ss -tlnp` → matchbox on 8080/8081, dnsmasq :53 on `eth0.10`.
- [ ] `curl -fsS http://10.10.0.1:8080/` → 200.
- [ ] scp the client bundle off, test mTLS: `openssl s_client -connect <pi>:8081 -cert client.crt -key client.key -CAfile ca.crt < /dev/null` → handshake ok.
- [ ] `ls /var/lib/matchbox/assets/talos/*/*/` → `vmlinuz-amd64`, `initramfs-amd64.xz`.
- [ ] Boot an amd64 UEFI node on an access port of VLAN 10 → iPXE menu → pick controlplane → Talos boots into maintenance mode (expected, placeholder configs).
- [ ] Delete the Pi's `/root/matchbox-client-bundle.tar.gz` after retrieval.
