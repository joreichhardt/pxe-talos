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
    # shellcheck disable=SC2016  # single quotes are deliberate: envsubst reads the allowlist literally
    envsubst '${HOSTNAME} ${TIMEZONE} ${UPLINK_IFACE} ${LAB_VLAN_ID} ${LAB_IFACE} ${PI_LAB_IP} ${PI_LAB_CIDR} ${LAB_SUBNET} ${DHCP_START} ${DHCP_END} ${DHCP_LEASE} ${LAB_DOMAIN} ${UPSTREAM_DNS_LIST} ${MATCHBOX_VERSION} ${SSH_PUBKEY_CONTENT}' < "$in" > "$out"
}

mkdir -p build

render_tmpl cloud-init/network-config.tmpl build/network-config
render_tmpl cloud-init/user-data.tmpl build/user-data

mkdir -p build/parts/dnsmasq
render_tmpl cloud-init/parts/dnsmasq/pxe.conf.tmpl build/parts/dnsmasq/pxe.conf
for dns in ${UPSTREAM_DNS_LIST}; do
    echo "server=${dns}" >> build/parts/dnsmasq/pxe.conf
done
echo "cache-size=1000" >> build/parts/dnsmasq/pxe.conf

mkdir -p build/parts/matchbox/profiles build/parts/matchbox/groups build/parts/matchbox/assets/configs
render_tmpl cloud-init/parts/matchbox/profiles/talos-controlplane.json.tmpl build/parts/matchbox/profiles/talos-controlplane.json
render_tmpl cloud-init/parts/matchbox/profiles/talos-worker.json.tmpl      build/parts/matchbox/profiles/talos-worker.json
cp cloud-init/parts/matchbox/groups/controlplane.json         build/parts/matchbox/groups/
cp cloud-init/parts/matchbox/groups/worker.json               build/parts/matchbox/groups/
cp cloud-init/parts/matchbox/assets/configs/controlplane.yaml build/parts/matchbox/assets/configs/
cp cloud-init/parts/matchbox/assets/configs/worker.yaml       build/parts/matchbox/assets/configs/
render_tmpl cloud-init/parts/matchbox/assets/menu.ipxe.tmpl   build/parts/matchbox/assets/menu.ipxe

# Subsequent tasks append render steps here.

echo "render.sh: done"
