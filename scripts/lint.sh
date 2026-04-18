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

check "yamllint network-config" bash -c '[ -f build/network-config ] && yamllint -d "{rules: {line-length: disable, document-start: disable}}" build/network-config'

check "cloud-init schema" bash -c '[ -f build/user-data ] && cloud-init schema --config-file build/user-data'

check "dnsmasq --test" bash -c '[ -f build/parts/dnsmasq/pxe.conf ] && dnsmasq --test -C build/parts/dnsmasq/pxe.conf'

# systemd-analyze verify fails when ExecStart paths don't exist on the
# workstation. Those paths only exist on the target Pi, so we filter the
# known "not executable" lines and fail only on other errors.
verify_unit() {
    local unit="$1"
    local out
    out="$(systemd-analyze verify --man=no "$unit" 2>&1 || true)"
    local filtered
    filtered="$(printf '%s\n' "$out" | grep -v 'is not executable: No such file or directory' | grep -v '^$' || true)"
    if [[ -n "$filtered" ]]; then
        printf '%s\n' "$filtered"
        return 1
    fi
    return 0
}

check "systemd-analyze matchbox"    verify_unit cloud-init/parts/systemd/matchbox.service
check "systemd-analyze talos-assets" verify_unit cloud-init/parts/systemd/talos-assets.service

# Subsequent tasks append checks here.

if [[ $FAIL -ne 0 ]]; then
    echo "LINT FAIL"; exit 1
fi
echo "LINT OK"
