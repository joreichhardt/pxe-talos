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

# Subsequent tasks append checks here.

if [[ $FAIL -ne 0 ]]; then
    echo "LINT FAIL"; exit 1
fi
echo "LINT OK"
