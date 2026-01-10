#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_BIN="$ROOT_DIR/tests/mock-bin"

export PATH="$MOCK_BIN:$PATH"
export PROXMOX_MANAGER_ALLOW_NONROOT=1
export NO_COLOR=1

cd "$ROOT_DIR"

list_out="$(./proxmox-manager.sh --list)"

if ! printf '%s\n' "$list_out" | rg -q "\bCT\b"; then
  echo "list output missing CT" >&2
  exit 1
fi
if ! printf '%s\n' "$list_out" | rg -q "\bVM\b"; then
  echo "list output missing VM" >&2
  exit 1
fi

json_out="$(./proxmox-manager.sh --json)"
if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$json_out" | python3 -m json.tool >/dev/null
else
  if ! printf '%s\n' "$json_out" | rg -q '^\['; then
    echo "json output is not an array" >&2
    exit 1
  fi
fi

echo "tests/run.sh OK"
