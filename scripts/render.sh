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

# Subsequent tasks append render steps here.

echo "render.sh: done"
