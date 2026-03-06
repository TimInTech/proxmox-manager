#!/usr/bin/env bash
# tests/run.sh — integration tests for proxmox-manager.sh
# Runs against mock-bin/ stubs; no real Proxmox node required.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_BIN="$ROOT_DIR/tests/mock-bin"
SCRIPT="$ROOT_DIR/proxmox-manager.sh"

export PATH="$MOCK_BIN:$PATH"
export PROXMOX_MANAGER_ALLOW_NONROOT=1
export NO_COLOR=1

cd "$ROOT_DIR"

PASS=0
FAIL=0

# Use arithmetic assignment (not (( )) compound) to stay safe under set -e.
_pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '[FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test: --list contains CT and VM entries
# ---------------------------------------------------------------------------
list_out="$("$SCRIPT" --list)"

if printf '%s\n' "$list_out" | grep -q "\bCT\b"; then
  _pass "--list output contains CT"
else
  _fail "--list output missing CT"
fi

if printf '%s\n' "$list_out" | grep -q "\bVM\b"; then
  _pass "--list output contains VM"
else
  _fail "--list output missing VM"
fi

# ---------------------------------------------------------------------------
# Test: --json produces valid JSON array
# ---------------------------------------------------------------------------
json_out="$("$SCRIPT" --json)"

if command -v python3 >/dev/null 2>&1; then
  if printf '%s\n' "$json_out" | python3 -m json.tool >/dev/null 2>&1; then
    _pass "--json output is valid JSON"
  else
    _fail "--json output is not valid JSON"
  fi
else
  if printf '%s\n' "$json_out" | grep -q '^\['; then
    _pass "--json output starts with '['"
  else
    _fail "--json output does not start with '['"
  fi
fi

# ---------------------------------------------------------------------------
# Test: --help exits 0 and produces non-empty output
# ---------------------------------------------------------------------------
help_out="$("$SCRIPT" --help 2>&1)" || true
help_exit="${PIPESTATUS[0]:-0}"
# Re-run to capture actual exit code cleanly
"$SCRIPT" --help >/dev/null 2>&1 && help_exit=0 || help_exit=$?
if [[ "$help_exit" == "0" ]]; then
  _pass "--help exits with code 0"
else
  _fail "--help exited with code $help_exit (expected 0)"
fi
if [[ -n "$help_out" ]]; then
  _pass "--help output is non-empty"
else
  _fail "--help produced no output"
fi

# ---------------------------------------------------------------------------
# Test: --version exits 0 and contains a version string
# ---------------------------------------------------------------------------
ver_out="$("$SCRIPT" --version 2>&1)" || true
"$SCRIPT" --version >/dev/null 2>&1 && ver_exit=0 || ver_exit=$?
if [[ "$ver_exit" == "0" ]]; then
  _pass "--version exits with code 0"
else
  _fail "--version exited with code $ver_exit (expected 0)"
fi
if printf '%s\n' "$ver_out" | grep -qE '[0-9]+\.[0-9]+'; then
  _pass "--version output contains a version number"
else
  _fail "--version output does not contain a version number"
fi

# ---------------------------------------------------------------------------
# Test: --once runs one interactive cycle without hanging
# (send 'q' immediately so it exits cleanly)
# ---------------------------------------------------------------------------
echo 'q' | "$SCRIPT" --once --no-clear >/dev/null 2>&1 && once_exit=0 || once_exit=$?
if [[ "$once_exit" == "0" ]]; then
  _pass "--once exits cleanly (exit 0)"
else
  _fail "--once exited with code $once_exit (expected 0)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "tests/run.sh FAILED" >&2
  exit 1
fi
echo "tests/run.sh OK"
