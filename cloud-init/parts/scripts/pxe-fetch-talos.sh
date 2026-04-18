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
