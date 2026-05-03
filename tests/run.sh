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
export LANG=C
export TERM=dumb

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
# Unit tests: validate_vmid()
# Source script functions into the current shell without triggering main "$@".
# grep -v '^main ' removes only the "main "$@"" call (the sole line starting
# with "main "); main() and main_menu() definitions are unaffected.
# ---------------------------------------------------------------------------
# shellcheck source=./proxmox-manager.sh disable=SC1091
source <(grep -v '^main ' "$SCRIPT")

_vmid_test() {
  local id="$1" expect_exit="$2" label="$3" actual_exit=0
  validate_vmid "$id" >/dev/null 2>&1 && actual_exit=0 || actual_exit=$?
  if [[ "$actual_exit" == "$expect_exit" ]]; then
    _pass "validate_vmid: $label"
  else
    _fail "validate_vmid: $label (expected exit $expect_exit, got $actual_exit)"
  fi
}

# Valid VMIDs — expect exit 0
_vmid_test "1"       0 "min valid (1)"
_vmid_test "100"     0 "typical (100)"
_vmid_test "999999"  0 "max valid (999999)"

# Invalid VMIDs — expect exit 1
_vmid_test "0"        1 "below minimum (0)"
_vmid_test "1000000"  1 "above maximum (1000000)"
_vmid_test "abc"      1 "non-numeric (abc)"
_vmid_test ""         1 "empty string"

# ---------------------------------------------------------------------------
# Unit tests: validate_snapshot_name()
# (functions already sourced above)
# ---------------------------------------------------------------------------
_snap_test() {
  local name="$1" expect_exit="$2" label="$3" actual_exit=0
  validate_snapshot_name "$name" >/dev/null 2>&1 && actual_exit=0 || actual_exit=$?
  if [[ "$actual_exit" == "$expect_exit" ]]; then
    _pass "validate_snapshot_name: $label"
  else
    _fail "validate_snapshot_name: $label (expected exit $expect_exit, got $actual_exit)"
  fi
}

# Valid names — expect exit 0
_snap_test "snap1"     0 "simple alphanumeric"
_snap_test "my-snap_2" 0 "with hyphen and underscore"
_snap_test "$(printf 'a%.0s' {1..40})" 0 "exactly 40 chars (max valid)"

# Invalid names — expect exit 1
_snap_test "_snap"     1 "starts with underscore"
_snap_test "-bad"      1 "starts with hyphen"
_snap_test "snap name" 1 "contains space"
_snap_test "snap!"     1 "contains special character"
_snap_test "$(printf 'a%.0s' {1..41})" 1 "41 chars (too long)"

# ---------------------------------------------------------------------------
# Tests: --filter flag
# ---------------------------------------------------------------------------
filter_run_out="$("$SCRIPT" --list --filter running)"
filter_stop_out="$("$SCRIPT" --list --filter stopped)"

# Match only data rows (start with VMID = digits), not legend or count lines.
if printf '%s\n' "$filter_run_out" | grep -qE '^[[:space:]]*[0-9]+.*running'; then
  _pass "--filter running output contains running data rows"
else
  _fail "--filter running output missing running data rows"
fi

if ! printf '%s\n' "$filter_run_out" | grep -qE '^[[:space:]]*[0-9]+.*stopped'; then
  _pass "--filter running output excludes stopped data rows"
else
  _fail "--filter running output contains stopped data rows (should be excluded)"
fi

if printf '%s\n' "$filter_stop_out" | grep -qE '^[[:space:]]*[0-9]+.*stopped'; then
  _pass "--filter stopped output contains stopped data rows"
else
  _fail "--filter stopped output missing stopped data rows"
fi

if ! printf '%s\n' "$filter_stop_out" | grep -qE '^[[:space:]]*[0-9]+.*running'; then
  _pass "--filter stopped output excludes running data rows"
else
  _fail "--filter stopped output contains running data rows (should be excluded)"
fi

# --filter paused: mock has no paused entries → no rows → print_table returns 1
"$SCRIPT" --list --filter paused >/dev/null 2>&1 && filter_paused_exit=0 || filter_paused_exit=$?
if [[ "$filter_paused_exit" == "1" ]]; then
  _pass "--filter paused exits 1 when no matching entries"
else
  _fail "--filter paused should exit 1 (no entries), got $filter_paused_exit"
fi

# --filter invalid value → exit 1 from parse_args
"$SCRIPT" --list --filter invalid >/dev/null 2>&1 && filter_inv_exit=0 || filter_inv_exit=$?
if [[ "$filter_inv_exit" == "1" ]]; then
  _pass "--filter invalid value exits 1"
else
  _fail "--filter invalid value should exit 1, got $filter_inv_exit"
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
