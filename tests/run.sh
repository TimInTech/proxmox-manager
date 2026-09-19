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

# Isolate from the caller's ~/.pmanrc and state; everything lives in one temp tree.
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

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

# Config files must be parsed as data and never execute shell content.
config_file="$(mktemp)"
config_probe="$(mktemp)"
rm -f "$config_probe"
printf '%s\n' \
  'STOP_TIMEOUT=90' \
  'LOG_FILE="/var/log/proxmox manager.log"' \
  'PROXMOX_MANAGER_SPICE_ADDR=spice.example.invalid' \
  "UNSUPPORTED=\$(touch $config_probe)" >"$config_file"
STOP_TIMEOUT=60
LOG_FILE=''
PROXMOX_MANAGER_SPICE_ADDR=''
_load_config_file "$config_file" 2>/dev/null
if [[ "$STOP_TIMEOUT" == "90" && "$LOG_FILE" == "/var/log/proxmox manager.log" && "$PROXMOX_MANAGER_SPICE_ADDR" == "spice.example.invalid" && ! -e "$config_probe" ]]; then
  _pass "config parser: allowlisted values parsed without code execution"
else
  _fail "config parser: unsafe execution or incorrect parsing"
fi
# shellcheck disable=SC2016 # Intentional literal command substitution attack string.
printf 'LOG_FILE="$(touch %s)"\n' "$config_probe" >"$config_file"
LOG_FILE=''
_load_config_file "$config_file" 2>/dev/null
# shellcheck disable=SC2016 # Verify that the attack string remained literal data.
if [[ ! -e "$config_probe" && "$LOG_FILE" == *'$('* ]]; then
  _pass "config parser: treats command substitution as literal data"
else
  _fail "config parser: executed command substitution"
fi
rm -f "$config_file" "$config_probe"
STOP_TIMEOUT=60
LOG_FILE=''
PROXMOX_MANAGER_SPICE_ADDR=''

# Log files must be private regular files and symlinks must be rejected.
log_dir="$(mktemp -d)"
chmod 700 "$log_dir"
LOG_FILE="$log_dir/pman.log"
if _prepare_log_file && [[ -f "$LOG_FILE" && ! -L "$LOG_FILE" && "$(stat -c '%a' "$LOG_FILE")" == "600" ]]; then
  _pass "log security: creates a private regular file"
else
  _fail "log security: failed to create a private regular file"
fi
rm -f "$LOG_FILE"
log_target="$log_dir/target"
log_link="$log_dir/link"
: >"$log_target"
ln -s "$log_target" "$log_link"
LOG_FILE="$log_link"
if ! _prepare_log_file 2>/dev/null && [[ -z "$LOG_FILE" && ! -s "$log_target" ]]; then
  _pass "log security: rejects symlink targets"
else
  _fail "log security: accepted a symlink target"
fi
rm -f "$log_link" "$log_target"
rmdir "$log_dir"

# User-controlled messages must not interpret backslash escapes.
LOG_FILE=''
literal_message='message\\cstill-visible'
message_out="$(err "$literal_message" 2>&1)"
if [[ "$message_out" == *"$literal_message"* ]]; then
  _pass "output safety: preserves literal backslash escapes"
else
  _fail "output safety: interpreted backslash escapes"
fi

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
_snap_test "1"         1 "numeric-only name"
_snap_test "a"         1 "single-letter name"
_snap_test "_snap"     1 "starts with underscore"
_snap_test "-bad"      1 "starts with hyphen"
_snap_test "snap name" 1 "contains space"
_snap_test "snap!"     1 "contains special character"
_snap_test "$(printf 'a%.0s' {1..41})" 1 "41 chars (too long)"

# ---------------------------------------------------------------------------
# Unit tests: ip_info()
# ---------------------------------------------------------------------------
_vm_ip_exit=0
_vm_ip_out="$(ip_info 200 VM vm-one 2>&1)" || _vm_ip_exit=$?
if [[ "$_vm_ip_exit" == "0" ]] && printf '%s\n' "$_vm_ip_out" | grep -q '192.168.178.20'; then
  _pass "ip_info: VM returns IPv4 addresses"
else
  _fail "ip_info: VM did not return expected IPv4 address"
fi

_ct_ip_exit=0
_ct_ip_out="$(ip_info 100 CT ct-one 2>&1)" || _ct_ip_exit=$?
if [[ "$_ct_ip_exit" == "0" ]] && printf '%s\n' "$_ct_ip_out" | grep -q '192.168.178.102'; then
  _pass "ip_info: CT returns IPv4 addresses"
else
  _fail "ip_info: CT did not return expected IPv4 address"
fi

# ---------------------------------------------------------------------------
# Unit tests: spice_info()
# ---------------------------------------------------------------------------
rm -f /tmp/hermes-virt-viewer-called
unset DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR
_spice_exit=0
_spice_out="$(spice_info 200 vm-one 2>&1)" || _spice_exit=$?
_spice_vv="$(printf '%s\n' "$_spice_out" | sed -n 's/.*SPICE connection file: //p' | tail -1)"
if [[ "$_spice_exit" == "0" ]] && printf '%s\n' "$_spice_out" | grep -q 'spice://127.0.0.1:61000'; then
  _pass "spice_info: URI uses monitor/config host and port"
else
  _fail "spice_info: URI did not use expected host/port"
fi

if [[ -n "$_spice_vv" ]] && [[ -f "$_spice_vv" ]] && grep -q '^host=127.0.0.1$' "$_spice_vv"; then
  _pass "spice_info: .vv file uses actual SPICE bind host"
else
  _fail "spice_info: .vv file did not use expected host"
fi

if [[ -n "$_spice_vv" ]]; then rm -f "$_spice_vv"; fi
if [[ ! -e /tmp/hermes-virt-viewer-called ]]; then
  _pass "spice_info: does not auto-launch virt-viewer without GUI session"
else
  _fail "spice_info: auto-launched virt-viewer without GUI session"
fi

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
# Health: CLI modes, config validation, helpers
# ---------------------------------------------------------------------------
# _rc CMD... — run CMD with stdout/stderr discarded and print its exit code.
_rc() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# _expect_rc LABEL EXPECTED CMD... — assert the exit code of CMD.
_expect_rc() {
  local label="$1" expected="$2" actual
  shift 2
  actual="$(_rc "$@")"
  if [[ "$actual" == "$expected" ]]; then
    _pass "$label"
  else
    _fail "$label (expected exit $expected, got $actual)"
  fi
}

_new_state_dir() {
  local d
  d="$(mktemp -d "$TEST_TMP/state.XXXXXX")"
  chmod 700 "$d"
  printf '%s' "$d"
}

_expect_rc "health flags: --check with --json exits 3 (UNKNOWN)" 3 "$SCRIPT" --check --json
_expect_rc "health flags: --check with --health exits 3 (UNKNOWN)" 3 "$SCRIPT" --check --health
_expect_rc "health flags: --check with --filter exits 3 (UNKNOWN)" 3 "$SCRIPT" --check --filter running
_expect_rc "health flags: --check with an unknown option exits 3" 3 "$SCRIPT" --check --bogus
_expect_rc "health flags: --dry-run without --check exits 1" 1 "$SCRIPT" --dry-run
_expect_rc "health flags: --test-notify with --list exits 1" 1 "$SCRIPT" --test-notify --list
_expect_rc "test-notify: no channel configured exits 1" 1 "$SCRIPT" --test-notify

# Config validation: bad health settings are fatal (exit 3) only for --check.
printf '%s\n' 'HEALTH_MEM_WARN=96' 'HEALTH_MEM_CRIT=95' >"$HOME/.pmanrc"
_expect_rc "health config: WARN >= CRIT makes --check exit 3" 3 \
  env HEALTH_STATE_DIR="$(_new_state_dir)" "$SCRIPT" --check
_expect_rc "health config: invalid thresholds do not block --list" 0 "$SCRIPT" --list
printf '%s\n' 'NTFY_URL=https://ntfy.example.invalid/topic' 'NTFY_TOKEN=tk_inline' >"$HOME/.pmanrc"
cfg_out="$(HEALTH_STATE_DIR="$(_new_state_dir)" "$SCRIPT" --check 2>&1)" && cfg_rc=0 || cfg_rc=$?
if [[ "$cfg_rc" == "3" && "$cfg_out" == *NTFY_TOKEN_FILE* && "$cfg_out" != *tk_inline* ]]; then
  _pass "health config: inline NTFY_TOKEN rejected without echoing the secret"
else
  _fail "health config: inline NTFY_TOKEN not rejected (exit $cfg_rc)"
fi
token_file="$TEST_TMP/ntfy.token"
printf 'tk_file\n' >"$token_file"
chmod 644 "$token_file"
printf '%s\n' 'NTFY_URL=https://ntfy.example.invalid/topic' "NTFY_TOKEN_FILE=$token_file" >"$HOME/.pmanrc"
_expect_rc "health config: token file with mode 0644 makes --check exit 3" 3 \
  env HEALTH_STATE_DIR="$(_new_state_dir)" "$SCRIPT" --check
printf '%s\n' 'NTFY_URL=ftp://ntfy.example.invalid/topic' >"$HOME/.pmanrc"
_expect_rc "health config: non-http NTFY_URL makes --check exit 3" 3 \
  env HEALTH_STATE_DIR="$(_new_state_dir)" "$SCRIPT" --check
printf '%s\n' 'HEALTH_MAIL_TO="root@localhost,bad address"' >"$HOME/.pmanrc"
_expect_rc "health config: invalid HEALTH_MAIL_TO makes --check exit 3" 3 \
  env HEALTH_STATE_DIR="$(_new_state_dir)" "$SCRIPT" --check
rm -f "$HOME/.pmanrc"

if [[ "$(_fmt_duration 90061)" == "1d 1h 1m" && "$(_fmt_duration 3660)" == "1h 1m" && "$(_fmt_duration 59)" == "0m" && -z "$(_fmt_duration abc)" ]]; then
  _pass "_fmt_duration: formats days, hours and minutes"
else
  _fail "_fmt_duration: unexpected output"
fi

# ---------------------------------------------------------------------------
# Health view: --health, --health --list, --health --json, menu key, status line
# ---------------------------------------------------------------------------
FIXTURES="$ROOT_DIR/tests/fixtures"

health_list_out="$("$SCRIPT" --health --list)"
if grep -qE '^100 +CT +running' <<<"$health_list_out" && grep -qE '^200 +VM +running' <<<"$health_list_out" &&
  ! grep -qE '^(300|9000) ' <<<"$health_list_out"; then
  _pass "--health --list: local guests only, templates and other nodes skipped"
else
  _fail "--health --list: unexpected guest set"
fi

printf '%s\n' 'UNSUPPORTED_KEY=1' >"$HOME/.pmanrc"
health_json_out="$("$SCRIPT" --health --json 2>/dev/null)"
rm -f "$HOME/.pmanrc"
if python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
g = {x["id"]: x for x in d["guests"]}
assert d["node"] == "mock-host"
assert sorted(g) == [100, 101, 200, 201]
assert g[200]["disk"] is None and g[200]["cpu"] == 5 and g[200]["uptime"] == 90061
assert g[101]["cpu"] is None and g[101]["uptime"] is None
assert d["summary"] == {"guests": 4, "ok": 4, "warn": 0, "crit": 0, "ignored": 0}
' <<<"$health_json_out" 2>/dev/null; then
  _pass "--health --json: valid JSON on stdout only, n/a metrics are null"
else
  _fail "--health --json: invalid JSON or unexpected content"
fi

hot_out="$(PMAN_MOCK_RESOURCES="$FIXTURES/resources-hot.json" PMAN_MOCK_ONBOOT_IDS=101 "$SCRIPT" --health --list)"
if grep -q '\[CRIT\] CT 100 (ct-one): memory 96%' <<<"$hot_out" &&
  grep -q '\[WARN\] VM 200 (vm-one): CPU 90%' <<<"$hot_out" &&
  grep -q '\[CRIT\] CT 101 (ct-fallback): stopped although onboot=1' <<<"$hot_out" &&
  grep -q '1 OK  1 WARN  2 CRIT' <<<"$hot_out"; then
  _pass "--health: thresholds and onboot produce findings and totals"
else
  _fail "--health: findings or totals missing"
fi

ign_out="$(PMAN_MOCK_RESOURCES="$FIXTURES/resources-hot.json" HEALTH_IGNORE_IDS=100 "$SCRIPT" --health --list)"
if grep -qE '^100 .* IGN ' <<<"$ign_out" && ! grep -q 'CT 100 (ct-one)' <<<"$ign_out"; then
  _pass "--health: HEALTH_IGNORE_IDS suppresses findings"
else
  _fail "--health: ignored guest still reported"
fi

hfilter_out="$("$SCRIPT" --health --list --filter running --name '^vm')"
if grep -qE '^200 ' <<<"$hfilter_out" && ! grep -qE '^(100|101|201) ' <<<"$hfilter_out"; then
  _pass "--health: --filter and --name apply"
else
  _fail "--health: --filter/--name not applied"
fi

_expect_rc "--health: pvesh failure exits 1" 1 env PMAN_MOCK_PVESH_FAIL=1 "$SCRIPT" --health

if [[ "$(_level_for 84 85 95)" == "0" && "$(_level_for 85 85 95)" == "1" && "$(_level_for 95 85 95)" == "2" &&
  "$(_level_for 99 0 0)" == "0" && "$(_level_for - 85 95)" == "-" ]]; then
  _pass "_level_for: thresholds, disabled levels and n/a"
else
  _fail "_level_for: unexpected level"
fi

parsed_rows="$(pvesh get /cluster/resources | _health_parse_resources mock-host)"
if [[ "$(printf '%s\n' "$parsed_rows" | cut -f1 | tr '\n' ' ')" == "100 101 200 201 " ]] &&
  grep -qP '^200\tVM\trunning\tvm-one\t5\t25\t-\t90061$' <<<"$parsed_rows"; then
  _pass "_health_parse_resources: node/template filter and TSV fields"
else
  _fail "_health_parse_resources: unexpected rows"
fi
if ! printf 'not json' | _health_parse_resources mock-host >/dev/null 2>&1; then
  _pass "_health_parse_resources: invalid JSON fails"
else
  _fail "_health_parse_resources: invalid JSON accepted"
fi

menu_out="$(printf 'h\n\n' | "$SCRIPT" --once --no-clear 2>&1)" && menu_rc=0 || menu_rc=$?
if [[ "$menu_rc" == "0" ]] && grep -q 'HEALTH' <<<"$menu_out" && grep -q 'Total: 4 guests' <<<"$menu_out"; then
  _pass "interactive: key 'h' shows the health overview"
else
  _fail "interactive: key 'h' did not show the health overview (exit $menu_rc)"
fi

status_out="$(do_action 100 CT status ct-one 2>&1)"
if grep -q 'Health: CPU 12%  MEM 25%  DISK 12%  up 1h 0m  \[OK\]' <<<"$status_out"; then
  _pass "status action: prints a health line"
else
  _fail "status action: health line missing"
fi

# ---------------------------------------------------------------------------
# Health check engine: --check / --dry-run (notifications are not sent here)
# ---------------------------------------------------------------------------
# _chk DIR [ENV=VAL...] [-- ARGS] — run --check with HEALTH_STATE_DIR=DIR; sets chk_out/chk_rc.
_chk() {
  local dir="$1"
  shift
  local -a envs=() args=()
  while (($# > 0)) && [[ "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  (($# > 0)) && shift
  args=("$@")
  chk_rc=0
  chk_out="$(env HEALTH_STATE_DIR="$dir" "${envs[@]}" "$SCRIPT" --check "${args[@]}" 2>/dev/null)" || chk_rc=$?
}

# _expect_chk LABEL RC PATTERN — assert last _chk exit code and a fixed-string match.
_expect_chk() {
  local label="$1" rc="$2" pattern="$3"
  if [[ "$chk_rc" == "$rc" ]] && grep -qF -- "$pattern" <<<"$chk_out"; then
    _pass "$label"
  else
    _fail "$label (exit $chk_rc, expected $rc; output: ${chk_out//$'\n'/ | })"
  fi
}

HOT="PMAN_MOCK_RESOURCES=$FIXTURES/resources-hot.json"
CPU_HOT="PMAN_MOCK_RESOURCES=$FIXTURES/resources-cpu-hot.json"
STOPPED_200="PMAN_MOCK_RESOURCES=$FIXTURES/resources-200-stopped.json"

sd="$(_new_state_dir)"
_chk "$sd"
_expect_chk "--check: all OK exits 0 with Nagios summary" 0 "PMAN OK - 0 critical, 0 warning"
if [[ "$(stat -c '%a' "$sd/health.state")" == "600" && "$(stat -c '%a' "$sd/check.lock")" == "600" &&
  "$(head -1 "$sd/health.state")" == "# pman-health-state v1" ]]; then
  _pass "--check: state and lock files are private (0600) and versioned"
else
  _fail "--check: state/lock file mode or header wrong"
fi
_chk "$sd" "$HOT"
_expect_chk "--check: memory CRIT alerts immediately (exit 2)" 2 "[CRIT] CT 100 (ct-one): memory 96% (>= 95%)"
if ! grep -q 'CPU' <<<"$chk_out"; then
  _pass "--check: single CPU spike does not alert"
else
  _fail "--check: CPU alerted on the first high run"
fi
_chk "$sd"
_expect_chk "--check: recovery reports RESOLVED (exit 0)" 0 "[RESOLVED] CT 100 (ct-one): memory back to normal (25%)"

sd="$(_new_state_dir)"
_chk "$sd" "$CPU_HOT"
cpu1="$chk_rc"
_chk "$sd" "$CPU_HOT"
cpu2="$chk_rc"
_chk "$sd" "$CPU_HOT"
if [[ "$cpu1$cpu2" == "00" ]]; then
  _expect_chk "--check: CPU alerts after HEALTH_CPU_RUNS=3 consecutive runs" 1 "[WARN] VM 200 (vm-one): CPU 90% (>= 85%)"
else
  _fail "--check: CPU alerted before 3 runs (exits $cpu1 $cpu2)"
fi

sd="$(_new_state_dir)"
_chk "$sd" PMAN_MOCK_ONBOOT_IDS=101
_expect_chk "--check: stopped guest with onboot=1 is CRIT" 2 "[CRIT] CT 101 (ct-fallback): stopped although onboot=1"

sd="$(_new_state_dir)"
_chk "$sd"
_chk "$sd" "$STOPPED_200"
_expect_chk "--check: running guest stopped without task is WARN" 1 "[WARN] VM 200 (vm-one): stopped unexpectedly"
_chk "$sd" "$STOPPED_200"
_expect_chk "--check: unexpected stop stays latched while stopped" 1 "stopped unexpectedly"
sd="$(_new_state_dir)"
_chk "$sd"
_chk "$sd" "$STOPPED_200" "PMAN_MOCK_TASKS=$FIXTURES/tasks-shutdown-200.json"
_expect_chk "--check: stop with a successful shutdown task is OK" 0 "PMAN OK"

sd="$(_new_state_dir)"
_chk "$sd" "PMAN_MOCK_TASKS=$FIXTURES/tasks-failed-old.json"
_expect_chk "--check: first run is a task baseline (old failures ignored)" 0 "0 task event(s)"
_chk "$sd" "PMAN_MOCK_TASKS=$FIXTURES/tasks-failed-new.json"
if [[ "$chk_rc" == "2" ]] && grep -qF '[CRIT] task qmstart 201 failed: start failed' <<<"$chk_out" &&
  grep -qF '[WARN] task vzdump 100 finished with WARNINGS: 1' <<<"$chk_out" && ! grep -q 'job errors' <<<"$chk_out"; then
  _pass "--check: new failed tasks alert once (CRIT/WARN), old ones stay silent"
else
  _fail "--check: task events wrong (exit $chk_rc)"
fi
_chk "$sd" "PMAN_MOCK_TASKS=$FIXTURES/tasks-failed-new.json"
_expect_chk "--check: task events are deduplicated by watermark" 0 "0 task event(s)"

sd="$(_new_state_dir)"
_chk "$sd" "$HOT" HEALTH_IGNORE_IDS=100
_expect_chk "--check: HEALTH_IGNORE_IDS skips a guest" 0 "PMAN OK"

sd="$(_new_state_dir)"
_chk "$sd" PMAN_MOCK_PVESH_FAIL=1
_expect_chk "--check: pvesh failure exits 3 (UNKNOWN)" 3 "PMAN UNKNOWN"
lock_rc=0
(
  flock -n 9
  HEALTH_STATE_DIR="$sd" "$SCRIPT" --check >/dev/null 2>&1
) 9>"$sd/check.lock" || lock_rc=$?
if [[ "$lock_rc" == "3" ]]; then
  _pass "--check: concurrent run (lock held) exits 3"
else
  _fail "--check: lock not enforced (exit $lock_rc)"
fi
chmod 755 "$sd"
_chk "$sd"
_expect_chk "--check: non-private state directory exits 3" 3 "PMAN UNKNOWN"

sd="$(_new_state_dir)"
_chk "$sd" "$HOT" -- --dry-run
if [[ "$chk_rc" == "2" ]] && grep -qF 'Title: pman mock-host: CRIT (2 new)' <<<"$chk_out" &&
  grep -qF 'Priority: urgent' <<<"$chk_out" && [[ ! -e "$sd/health.state" && ! -e "$sd/check.lock" ]]; then
  _pass "--check --dry-run: prints the message and writes no state"
else
  _fail "--check --dry-run: unexpected output or state written (exit $chk_rc)"
fi

sd="$(_new_state_dir)"
probe="$TEST_TMP/state-probe"
printf '%s\n' '# pman-health-state v1' "W	1	1" "C	mem:100	2	1	0" \
  "X \$(touch $probe)" "C	mem:1;touch $probe	2	1	0" >"$sd/health.state"
chmod 600 "$sd/health.state"
_chk "$sd"
if [[ "$chk_rc" == "0" && ! -e "$probe" ]] && grep -qF '[RESOLVED] CT 100 (ct-one): memory back to normal' <<<"$chk_out" &&
  ! grep -q 'touch' "$sd/health.state"; then
  _pass "--check: state file parsed as data, malformed lines dropped"
else
  _fail "--check: state file handling unsafe or wrong (exit $chk_rc)"
fi

sd="$(_new_state_dir)"
HEALTH_STATE_DIR="$sd" PMAN_MOCK_PVESH_SLEEP=1 "$SCRIPT" --check >/dev/null 2>&1 &
term_pid=$!
sleep 0.3
kill -TERM "$term_pid" 2>/dev/null || true
term_rc=0
wait "$term_pid" || term_rc=$?
if [[ "$term_rc" == "3" ]]; then
  _pass "--check: SIGTERM exits 3 instead of 0"
else
  _fail "--check: SIGTERM exit code $term_rc (expected 3)"
fi

cap_lines=()
for i in $(seq 1 200); do cap_lines+=("[WARN] VM $i (some-guest-name): memory 91% (>= 90%)"); done
_compose_message mock-host 1 200 0 0 "Now: totals" "${cap_lines[@]}"
if ((${#MSG_BODY} <= 3600)) && [[ "$MSG_BODY" == *"more line(s) omitted"* && "$MSG_TITLE" == "pman mock-host: WARN (200 new)" && "$MSG_PRIORITY" == "high" ]]; then
  _pass "_compose_message: title, priority and ~3500 byte cap"
else
  _fail "_compose_message: cap or title wrong (${#MSG_BODY} bytes, '$MSG_TITLE')"
fi

# ---------------------------------------------------------------------------
# Notifications: ntfy (curl mock) and e-mail (sendmail mock); no real network
# ---------------------------------------------------------------------------
if [[ "$(command -v curl)" != "$MOCK_BIN/curl" || "$(command -v sendmail)" != "$MOCK_BIN/sendmail" ]]; then
  _fail "notify: curl/sendmail mocks are not first in PATH; skipping notification tests"
else
  ntfy_tok="$TEST_TMP/ntfy-ok.token"
  printf 'tk_secret123\n' >"$ntfy_tok"
  chmod 600 "$ntfy_tok"
  notify_tmp="$TEST_TMP/notify-tmp"
  mkdir -p "$notify_tmp"

  # _notify_env NAME — fresh curl/sendmail logs; sets NENV for _chk.
  _notify_env() {
    nlog="$TEST_TMP/$1"
    rm -f "$nlog".*
    NENV=("NTFY_URL=https://ntfy.example.invalid/pman-topic" "NTFY_TOKEN_FILE=$ntfy_tok"
      "HEALTH_MAIL_TO=root@localhost" "HEALTH_MAIL_FROM=pman@example.invalid"
      "PMAN_MOCK_CURL_LOG=$nlog.curl" "PMAN_MOCK_SENDMAIL_LOG=$nlog.mail" "TMPDIR=$notify_tmp")
  }
  _count() { if [[ -f "$1" ]]; then grep -c "$2" "$1"; else printf '0'; fi; }

  _notify_env n1
  sd="$(_new_state_dir)"
  _chk "$sd" "${NENV[@]}" "$HOT"
  if [[ "$chk_rc" == "2" && "$(_count "$nlog.curl" .)" == "1" && "$(_count "$nlog.mail" '^ARGV: -t -oi$')" == "1" ]] &&
    grep -qF 'header = "Priority: urgent"' "$nlog.curl.cfg" && grep -qF 'header = "Tags: rotating_light"' "$nlog.curl.cfg" &&
    grep -q '^Subject: pman mock-host: CRIT' "$nlog.mail" && grep -qF '[CRIT] CT 100 (ct-one): memory 96%' "$nlog.curl.body"; then
    _pass "notify: hot run sends one ntfy (urgent) and one mail (CRIT)"
  else
    _fail "notify: hot run did not send exactly one ntfy + one mail (exit $chk_rc)"
  fi
  if grep -q '^-q -fsS --max-time 10 --proto =https -o /dev/null --data-binary @' "$nlog.curl" && ! grep -q -- '--retry' "$nlog.curl"; then
    _pass "notify: curl ignores .curlrc (-q first), https only with a token, no retry"
  else
    _fail "notify: unexpected curl arguments: $(head -1 "$nlog.curl")"
  fi
  if grep -q 'tk_secret123' "$nlog.curl.cfg" && ! grep -q 'tk_secret123' "$nlog.curl" && ! grep -q 'pman-topic' "$nlog.curl"; then
    _pass "notify: token and topic only in curl stdin config, never in argv"
  else
    _fail "notify: token or topic leaked into curl argv"
  fi
  if [[ -z "$(ls -A "$notify_tmp")" ]]; then
    _pass "notify: ntfy body temp file removed"
  else
    _fail "notify: ntfy body temp file left behind"
  fi
  if grep -q '^To: root@localhost$' "$nlog.mail" && grep -q '^From: pman@example.invalid$' "$nlog.mail" &&
    grep -q '^Content-Type: text/plain; charset=UTF-8$' "$nlog.mail" && grep -q '^Auto-Submitted: auto-generated$' "$nlog.mail"; then
    _pass "notify: mail has To/From/Subject/MIME/Auto-Submitted headers"
  else
    _fail "notify: mail headers missing"
  fi
  _chk "$sd" "${NENV[@]}" "$HOT"
  if [[ "$chk_rc" == "2" && "$(_count "$nlog.curl" .)" == "1" && "$(_count "$nlog.mail" '^ARGV')" == "1" ]]; then
    _pass "notify: unchanged state sends nothing"
  else
    _fail "notify: repeated alert on unchanged state"
  fi
  _chk "$sd" "${NENV[@]}"
  if [[ "$chk_rc" == "0" && "$(_count "$nlog.curl" .)" == "2" ]] && tail -6 "$nlog.curl.cfg" | grep -qF 'Priority: low' &&
    grep -qF '[RESOLVED] CT 100 (ct-one)' "$nlog.curl.body" && grep -q '^Subject: pman mock-host: RESOLVED' "$nlog.mail"; then
    _pass "notify: recovery sends RESOLVED with priority low"
  else
    _fail "notify: recovery notification wrong (exit $chk_rc)"
  fi

  _notify_env n2
  sd="$(_new_state_dir)"
  _chk "$sd" "${NENV[@]}" "$HOT" PMAN_MOCK_CURL_RC=22
  if [[ "$chk_rc" == "2" ]] && grep -q $'^C\tmem:100\t2' "$sd/health.state" 2>/dev/null; then
    _pass "notify: ntfy fails, mail works -> state saved"
  else
    _fail "notify: partial failure handling wrong (exit $chk_rc)"
  fi

  _notify_env n3
  sd="$(_new_state_dir)"
  _chk "$sd" "${NENV[@]}" "$HOT" PMAN_MOCK_CURL_RC=7 PMAN_MOCK_SENDMAIL_RC=75
  if [[ "$chk_rc" == "2" && -e "$sd/health.state" ]] && ! grep -q $'^C\tmem:100\t2' "$sd/health.state" &&
    grep -q $'^R\t100$' "$sd/health.state"; then
    _pass "notify: all channels fail -> exit reflects health, state saved, alerts kept pending"
  else
    _fail "notify: all-fail handling wrong (exit $chk_rc)"
  fi
  rm -f "$nlog".*
  _chk "$sd" "${NENV[@]}" "$HOT"
  if [[ "$chk_rc" == "2" && "$(_count "$nlog.curl" .)" == "1" ]] && grep -qF 'Priority: urgent' "$nlog.curl.cfg" &&
    grep -qF '[CRIT] CT 100 (ct-one): memory 96%' "$nlog.curl.body"; then
    _pass "notify: next run resends after a total failure"
  else
    _fail "notify: alert not resent after a total failure"
  fi
  _chk "$sd" "${NENV[@]}" "$HOT"
  if [[ "$(_count "$nlog.curl.body" 'memory 96%')" == "1" ]]; then
    _pass "notify: resent alert is delivered exactly once"
  else
    _fail "notify: resent alert delivered more than once"
  fi

  # CPU counter keeps advancing while delivery fails; the WARN fires once delivery works.
  _notify_env n7
  sd="$(_new_state_dir)"
  _chk "$sd" "${NENV[@]}" "$CPU_HOT"
  _chk "$sd" "${NENV[@]}" "$CPU_HOT"
  _chk "$sd" "${NENV[@]}" "$CPU_HOT" PMAN_MOCK_CURL_RC=7 PMAN_MOCK_SENDMAIL_RC=75
  if [[ "$chk_rc" == "1" ]] && grep -q $'^C\tcpu:200\t0\t0\t3$' "$sd/health.state"; then
    _pass "notify: CPU counter advances although delivery failed"
  else
    _fail "notify: CPU counter not saved after delivery failure (exit $chk_rc)"
  fi
  rm -f "$nlog".*
  _chk "$sd" "${NENV[@]}" "$CPU_HOT"
  if [[ "$(_count "$nlog.curl" .)" == "1" ]] && grep -qF '[WARN] VM 200 (vm-one): CPU 90%' "$nlog.curl.body"; then
    _pass "notify: pending CPU alert delivered on the next run"
  else
    _fail "notify: pending CPU alert not delivered"
  fi

  # Tasks: failed task events are resent after a total delivery failure.
  _notify_env n8
  sd="$(_new_state_dir)"
  _chk "$sd" "${NENV[@]}" "PMAN_MOCK_TASKS=$FIXTURES/tasks-failed-old.json"
  _chk "$sd" "${NENV[@]}" "PMAN_MOCK_TASKS=$FIXTURES/tasks-failed-new.json" PMAN_MOCK_CURL_RC=7 PMAN_MOCK_SENDMAIL_RC=75
  rm -f "$nlog".*
  _chk "$sd" "${NENV[@]}" "PMAN_MOCK_TASKS=$FIXTURES/tasks-failed-new.json"
  if [[ "$chk_rc" == "2" && "$(_count "$nlog.curl" .)" == "1" ]] && grep -qF 'task qmstart 201 failed' "$nlog.curl.body"; then
    _pass "notify: unsent task events are resent on the next run"
  else
    _fail "notify: unsent task events lost (exit $chk_rc)"
  fi

  # The --check lock (fd 9) must not leak into child processes.
  _notify_env n9
  sd="$(_new_state_dir)"
  _chk "$sd" "${NENV[@]}" "$HOT" "PMAN_MOCK_FD_LOG=$nlog.fds"
  if [[ -s "$nlog.fds" ]] && grep -q '^sendmail ' "$nlog.fds" && grep -q '^curl ' "$nlog.fds" &&
    grep -q '^pvesh ' "$nlog.fds" && ! grep -q 'check.lock' "$nlog.fds"; then
    _pass "notify: lock fd is closed for pvesh, curl and sendmail"
  else
    _fail "notify: lock fd inherited by a child process"
  fi

  _notify_env n4
  tn_rc=0
  env "${NENV[@]}" "$SCRIPT" --test-notify >/dev/null 2>&1 || tn_rc=$?
  if [[ "$tn_rc" == "0" && "$(_count "$nlog.curl" .)" == "1" && "$(_count "$nlog.mail" '^ARGV')" == "1" ]] &&
    grep -q '^Subject: pman mock-host: test notification$' "$nlog.mail"; then
    _pass "--test-notify: sends through both channels (exit 0)"
  else
    _fail "--test-notify: expected one ntfy + one mail (exit $tn_rc)"
  fi
  tn_rc=0
  env "${NENV[@]}" PMAN_MOCK_CURL_RC=22 PMAN_MOCK_SENDMAIL_RC=1 "$SCRIPT" --test-notify >/dev/null 2>&1 || tn_rc=$?
  if [[ "$tn_rc" == "1" ]]; then
    _pass "--test-notify: all channels failing exits 1"
  else
    _fail "--test-notify: all channels failing exited $tn_rc"
  fi

  _notify_env n5
  tn_rc=0
  env "PMAN_MOCK_CURL_LOG=$nlog.curl" NTFY_URL=http://ntfy.example.invalid/pman-topic "NTFY_TOKEN_FILE=$ntfy_tok" \
    "$SCRIPT" --test-notify >/dev/null 2>&1 || tn_rc=$?
  if [[ "$tn_rc" == "1" && ! -e "$nlog.curl" ]]; then
    _pass "notify: token with plain http is rejected by --test-notify"
  else
    _fail "notify: token sent over http or wrong exit ($tn_rc)"
  fi
  _chk "$(_new_state_dir)" "PMAN_MOCK_CURL_LOG=$nlog.curl" NTFY_URL=http://ntfy.example.invalid/pman-topic "NTFY_TOKEN_FILE=$ntfy_tok"
  if [[ "$chk_rc" == "3" && ! -e "$nlog.curl" ]]; then
    _pass "notify: token with plain http makes --check exit 3"
  else
    _fail "notify: http + token not rejected by --check (exit $chk_rc)"
  fi

  # Header injection: CR/LF in the title must not create extra headers.
  _notify_env n6
  inj_rc=0
  (
    export PMAN_MOCK_SENDMAIL_LOG="$nlog.mail"
    HEALTH_MAIL_TO="root@localhost"
    HEALTH_MAIL_FROM=""
    MSG_TITLE=$'pman x: CRIT\r\nBcc: evil@example.invalid'
    MSG_BODY="body"
    MSG_PRIORITY="urgent"
    _notify_mail >/dev/null 2>&1
  ) || inj_rc=$?
  if [[ "$inj_rc" == "0" ]] && ! grep -q '^Bcc:' "$nlog.mail" && grep -q '^Subject: pman x: CRIT  Bcc: evil@example.invalid$' "$nlog.mail"; then
    _pass "notify: CR/LF in the title cannot inject mail headers"
  else
    _fail "notify: mail header injection possible (exit $inj_rc)"
  fi
fi

sd="$(_new_state_dir)"
_chk "$sd"
_chk "$sd" "$STOPPED_200" "PMAN_MOCK_TASKS=$FIXTURES/tasks-vzdump-200.json"
_expect_chk "--check: stop during a running vzdump (stop mode) is OK" 0 "PMAN OK"

# Security review regressions ----------------------------------------------
# Token file: directory must be trusted; the open descriptor is verified.
tok_dir="$TEST_TMP/tokdir"
mkdir -p "$tok_dir"
chmod 777 "$tok_dir"
printf 'tk_other\n' >"$tok_dir/t"
chmod 600 "$tok_dir/t"
_chk "$(_new_state_dir)" NTFY_URL=https://ntfy.example.invalid/pman-topic "NTFY_TOKEN_FILE=$tok_dir/t"
_expect_chk "security: token file in a world-writable directory makes --check exit 3" 3 "PMAN UNKNOWN"
chmod 700 "$tok_dir"
saved_tf="$NTFY_TOKEN_FILE"
NTFY_TOKEN_FILE="$tok_dir/t"
tok_ok="$(_read_ntfy_token)" || tok_ok=''
printf 'tk_leak\n' >"$tok_dir/other"
chmod 644 "$tok_dir/other"
NTFY_TOKEN_FILE="$tok_dir/other"
tok_bad=0
_read_ntfy_token >/dev/null 2>&1 || tok_bad=$?
ln -s "$tok_dir/t" "$tok_dir/link"
NTFY_TOKEN_FILE="$tok_dir/link"
tok_link=0
_read_ntfy_token >/dev/null 2>&1 || tok_link=$?
NTFY_TOKEN_FILE="$saved_tf"
if [[ "$tok_ok" == "tk_other" && "$tok_bad" == "1" && "$tok_link" == "1" ]]; then
  _pass "security: token read via a verified descriptor (mode and symlink checked)"
else
  _fail "security: token reader accepted an unsafe file ($tok_ok/$tok_bad/$tok_link)"
fi

# State dir: parent must not be group/world-writable; lock file is never truncated.
open_parent="$TEST_TMP/open-parent"
mkdir -p "$open_parent"
chmod 777 "$open_parent"
_chk "$open_parent/state"
if [[ "$chk_rc" == "3" && ! -e "$open_parent/state" ]]; then
  _pass "security: HEALTH_STATE_DIR below a world-writable parent is refused"
else
  _fail "security: world-writable parent accepted (exit $chk_rc)"
fi
sd="$(_new_state_dir)"
printf 'keep\n' >"$sd/check.lock"
chmod 600 "$sd/check.lock"
_chk "$sd"
if [[ "$chk_rc" == "0" && "$(cat "$sd/check.lock")" == "keep" ]]; then
  _pass "security: lock file is opened for append, not truncated"
else
  _fail "security: lock file truncated (exit $chk_rc)"
fi

if [[ "$(json_escape $'a\x01b\x1fc\n\t"')" == 'a\u0001b\u001fc\n\t\"' ]]; then
  _pass "json_escape: control characters escaped as \\u00XX"
else
  _fail "json_escape: control characters not escaped"
fi
utf_cut="$(_truncate 'aüüüüüüüüü' 5)"
if python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' <<<"$utf_cut" 2>/dev/null &&
  [[ "$(_vis_width "$utf_cut")" == "5" ]]; then
  _pass "_truncate: never cuts inside a UTF-8 character"
else
  _fail "_truncate: produced invalid UTF-8 or wrong width"
fi

# --test-notify removes the ntfy body temp file when interrupted.
tn_tmp="$TEST_TMP/tn-tmp"
mkdir -p "$tn_tmp"
NTFY_URL=https://ntfy.example.invalid/pman-topic PMAN_MOCK_CURL_SLEEP=1 TMPDIR="$tn_tmp" \
  "$SCRIPT" --test-notify >/dev/null 2>&1 &
tn_pid=$!
sleep 0.4
kill -TERM "$tn_pid" 2>/dev/null || true
tn_rc=0
wait "$tn_pid" || tn_rc=$?
if [[ "$tn_rc" != "0" && -z "$(ls -A "$tn_tmp")" ]]; then
  _pass "--test-notify: interrupted run removes its temp file"
else
  _fail "--test-notify: temp file left after SIGTERM (exit $tn_rc)"
fi

# Review regressions -------------------------------------------------------
# Metric alerts of a guest that stops resolve instead of sticking forever.
sd="$(_new_state_dir)"
_chk "$sd" "$HOT"
_chk "$sd" "PMAN_MOCK_RESOURCES=$FIXTURES/resources-100-stopped.json" "PMAN_MOCK_TASKS=$FIXTURES/tasks-vzshutdown-100.json"
_expect_chk "--check: metric alerts resolve when the guest stops" 0 "[RESOLVED] CT 100 (ct-one): mem alert cleared (guest stopped)"
_chk "$sd" "PMAN_MOCK_RESOURCES=$FIXTURES/resources-100-stopped.json" "PMAN_MOCK_TASKS=$FIXTURES/tasks-vzshutdown-100.json"
if [[ "$chk_rc" == "0" && "$(wc -l <<<"$chk_out")" == "1" ]]; then
  _pass "--check: stopped guest stays quiet afterwards"
else
  _fail "--check: stopped guest still reported (exit $chk_rc)"
fi
# A metric that is n/a on a running guest keeps its state but is not reported or counted.
sd="$(_new_state_dir)"
printf '%s\n' '# pman-health-state v1' "W	1	1700000005" "C	disk:200	2	1	0" >"$sd/health.state"
chmod 600 "$sd/health.state"
_chk "$sd"
if [[ "$chk_rc" == "0" ]] && ! grep -q 'disk' <<<"$chk_out" && grep -q $'^C\tdisk:200\t2' "$sd/health.state"; then
  _pass "--check: n/a metric on a running guest is kept silently"
else
  _fail "--check: n/a metric on a running guest reported or dropped (exit $chk_rc)"
fi

# Shutdown task older than the last run (pvestatd lag) still explains the stop.
sd="$(_new_state_dir)"
_chk "$sd" "PMAN_MOCK_TASKS=$FIXTURES/tasks-shutdown-old-200.json"
_chk "$sd" "$STOPPED_200" "PMAN_MOCK_TASKS=$FIXTURES/tasks-shutdown-old-200.json"
_expect_chk "--check: shutdown seen before the stop (status lag) is OK" 0 "PMAN OK"
sd="$(_new_state_dir)"
_chk "$sd" "PMAN_MOCK_TASKS=$FIXTURES/tasks-suspend-200.json"
_chk "$sd" "$STOPPED_200" "PMAN_MOCK_TASKS=$FIXTURES/tasks-suspend-200.json"
_expect_chk "--check: hibernate (qmsuspend, WARNINGS) is not an unexpected stop" 0 "PMAN OK"
sd="$(_new_state_dir)"
_chk "$sd" "PMAN_MOCK_TASKS=$FIXTURES/tasks-restart-after-stop-200.json"
_chk "$sd" "$STOPPED_200" "PMAN_MOCK_TASKS=$FIXTURES/tasks-restart-after-stop-200.json"
_expect_chk "--check: stop after a later start task is unexpected" 1 "stopped unexpectedly"
sd="$(_new_state_dir)"
_chk "$sd"
_chk "$sd" "$STOPPED_200"
_chk "$sd" "$STOPPED_200" "PMAN_MOCK_TASKS=$FIXTURES/tasks-shutdown-old-200.json"
_expect_chk "--check: a stop task found later clears the unexpected-stop latch" 0 "[RESOLVED] VM 200 (vm-one)"

# Tasks are read with --source all (running tasks are not archived yet).
pv_log="$TEST_TMP/pvesh.args"
_chk "$(_new_state_dir)" "PMAN_MOCK_PVESH_LOG=$pv_log"
if grep -q -- '^get /nodes/mock-host/tasks --source all --limit 200 --output-format json$' "$pv_log"; then
  _pass "--check: task list uses --source all"
else
  _fail "--check: task list does not use --source all"
fi

# onboot=1 guest stopped by an admin task is WARN, unexplained it stays CRIT.
sd="$(_new_state_dir)"
_chk "$sd" PMAN_MOCK_ONBOOT_IDS=201 "PMAN_MOCK_TASKS=$FIXTURES/tasks-shutdown-201.json"
_expect_chk "--check: onboot guest stopped by a task is WARN" 1 "[WARN] VM 201 (vm-fallback): stopped by a Proxmox task although onboot=1"

# --force must not break machine-readable output.
force_json="$("$SCRIPT" --health --json --force 2>/dev/null)"
force_list_json="$("$SCRIPT" --json --force 2>/dev/null)"
if python3 -c 'import json,sys; json.loads(sys.argv[1]); json.loads(sys.argv[2])' "$force_json" "$force_list_json" 2>/dev/null; then
  _pass "--force: --json and --health --json stay valid JSON"
else
  _fail "--force: JSON output corrupted by the --force warning"
fi
_chk "$(_new_state_dir)" -- --force
if [[ "$(head -1 <<<"$chk_out")" == "PMAN OK -"* ]]; then
  _pass "--force: --check keeps the Nagios summary as first line"
else
  _fail "--force: --check first line is not the summary"
fi

# Ignored guests are not counted; an empty node is not an error.
_chk "$(_new_state_dir)" HEALTH_IGNORE_IDS=100
_expect_chk "--check: ignored guests are not counted" 0 "; 3 guests on mock-host"
empty_rc=0
empty_out="$(PMAN_MOCK_RESOURCES="$FIXTURES/resources-empty.json" "$SCRIPT" --health 2>&1)" || empty_rc=$?
if [[ "$empty_rc" == "0" && "$empty_out" == *"No guests found on node mock-host."* ]]; then
  _pass "--health: no guests exits 0 with a message"
else
  _fail "--health: no guests exit $empty_rc"
fi

# Narrow terminals: no line wider than COLUMNS, finding text never cut.
narrow_out="$(COLUMNS=50 LANG=C.UTF-8 PMAN_MOCK_RESOURCES="$FIXTURES/resources-hot.json" PMAN_MOCK_ONBOOT_IDS=101 "$SCRIPT" --health)"
if python3 -c 'import sys; assert max(len(l) for l in sys.stdin.read().splitlines()) <= 50' <<<"$narrow_out" 2>/dev/null &&
  grep -qF 'stopped although onboot=1' <<<"$narrow_out" && grep -qF 'memory 96% (>= 95%)' <<<"$narrow_out"; then
  _pass "--health: fits 50 columns without cutting findings"
else
  _fail "--health: narrow layout overflows or cuts findings"
fi

# onboot lookup reads the current section of /etc/pve configs; node name from uname -n.
pve_etc="$TEST_TMP/pve-etc"
mkdir -p "$pve_etc/qemu-server" "$pve_etc/lxc"
printf '%s\n' 'name: a' 'onboot: 1' '[snap1]' 'onboot: 0' >"$pve_etc/qemu-server/555.conf"
printf '%s\n' 'hostname: b' '[snap1]' 'onboot: 1' >"$pve_etc/lxc/556.conf"
saved_etc="$PVE_ETC_DIR"
PVE_ETC_DIR="$pve_etc"
if _guest_onboot 555 VM && ! _guest_onboot 556 CT && PMAN_MOCK_ONBOOT_IDS=557 _guest_onboot 557 VM; then
  _pass "_guest_onboot: reads the current config section, falls back to qm/pct"
else
  _fail "_guest_onboot: wrong onboot detection"
fi
PVE_ETC_DIR="$saved_etc"
if [[ "$(_local_node)" == "mock-host" ]]; then
  _pass "_local_node: uname -n up to the first dot"
else
  _fail "_local_node: unexpected node name"
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
