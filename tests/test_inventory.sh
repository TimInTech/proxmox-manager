#!/usr/bin/env bash
# Inventory failures must never look like a successful empty/partial listing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/home"
for tool in pct qm; do
  cat >"$TEST_TMP/bin/$tool" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == list ]]; then
  if [[ "${0##*/}" == "${INVENTORY_FAIL_TOOL:-}" ]]; then
    echo '200 partial running 1024 10 1234'
    echo 'inventory unavailable' >&2
    exit 7
  fi
  echo 'VMID NAME STATUS'
  exit 0
fi
exit 0
MOCK
  chmod +x "$TEST_TMP/bin/$tool"
done
export PATH="$TEST_TMP/bin:$ROOT_DIR/tests/mock-bin:$PATH"
export HOME="$TEST_TMP/home" PROXMOX_MANAGER_ALLOW_NONROOT=1 NO_COLOR=1 TERM=dumb
failures=0
for tool in pct qm; do
  for mode in --json --list --once; do
    if INVENTORY_FAIL_TOOL="$tool" bash "$ROOT_DIR/proxmox-manager.sh" "$mode" </dev/null >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
      echo "FAIL $tool $mode: inventory error returned success" >&2
      failures=$((failures + 1))
    elif ! grep -q "$tool" "$TEST_TMP/err"; then
      echo "FAIL $tool $mode: no diagnostic identifying failed tool" >&2
      failures=$((failures + 1))
    elif grep -Eq 'partial|\[\]' "$TEST_TMP/out"; then
      echo "FAIL $tool $mode: misleading successful inventory output" >&2
      failures=$((failures + 1))
    else
      echo "PASS $tool $mode: inventory failure propagated"
    fi
  done
done
if output="$(bash "$ROOT_DIR/proxmox-manager.sh" --json)" && [[ "$output" == '[]' ]]; then
  echo 'PASS successful empty inventory remains valid JSON'
else
  echo 'FAIL successful empty inventory' >&2
  failures=$((failures + 1))
fi
if bash "$ROOT_DIR/proxmox-manager.sh" --once </dev/null >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
  echo 'PASS interactive empty inventory remains a successful refresh'
else
  echo 'FAIL interactive empty inventory refresh' >&2
  failures=$((failures + 1))
fi
exit "$((failures > 0))"
