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

echo "render.sh: done"
