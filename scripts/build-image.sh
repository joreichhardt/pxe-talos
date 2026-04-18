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
