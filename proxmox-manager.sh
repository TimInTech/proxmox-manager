#!/usr/bin/env bash
# Proxmox VM/CT Management Tool
# Version 2.8.3 — 2026-03-06
# - Refactored: clear section separation, log(), validate_vmid()
# - UX: confirmation prompts for stop/restart, snapshot list before rollback/delete
# - Header shows hostname and PVE version when available
# - Normalized output to English, added --version flag
# - Fixed: spice_enable uses explicit integer cast for port arithmetic
# - UX: print_table shows running/stopped count; header shows uptime
# - Fix: open_console checks CT status before pct enter
# - Fix: do_action shows Proxmox error details on failure
# - Fix: snapshot name validated before Proxmox call
# - UX: VMID-not-found message hints to refresh; action_menu empty=back
# - Fix: _pve_out declared local in stop/restart; rollback/delete show Proxmox errors
# - Fix: open_console checks VM status before qm terminal
# - Added keyboard legend in main menu

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

# =============================================================================
# DEFAULTS
# =============================================================================
CLEAR_SCREEN=1
MODE="interactive"
RUN_ONCE=0
LIST_FLAG=0
JSON_FLAG=0
LOG_FILE="${LOG_FILE:-}"   # Set LOG_FILE=/path/to/file to enable file logging

# =============================================================================
# COLORS  (active only on a real TTY, or when NO_COLOR is unset)
# =============================================================================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'
  RED=$'\e[31m'
  GREEN=$'\e[32m'
  YELLOW=$'\e[33m'
  BLUE=$'\e[34m'
  CYAN=$'\e[36m'
  NC=$'\e[0m'
else
  BOLD=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
fi

# =============================================================================
# SIGNAL HANDLING
# =============================================================================
trap 'printf "\n%s\n" "Exiting."; exit 0' INT TERM

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

have()      { command -v "$1" >/dev/null 2>&1; }
err()       { printf '%b\n' "${RED}Error:${NC} $*" >&2;  log "ERROR" "$*"; }
ok()        { printf '%b\n' "${GREEN}$*${NC}";            log "OK"    "$*"; }
note()      { printf '%b\n' "${CYAN}$*${NC}";             log "NOTE"  "$*"; }
warn()      { printf '%b\n' "${YELLOW}Warning:${NC} $*";  log "WARN"  "$*"; }

# log() — structured timestamped logging; writes to LOG_FILE when set.
# Usage: log LEVEL message…
log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

# read_line NAME — safe single-line read into named variable.
read_line() {
  local __name="$1" __val=''
  if ! IFS= read -r __val; then __val=''; fi
  printf -v "$__name" '%s' "$__val"
}

# trim STRING — strip leading/trailing whitespace.
trim() {
  local v="$*"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# validate_vmid ID — exit 1 and print error if ID is not a valid Proxmox VMID.
# Valid range: positive integer 1–999999.
validate_vmid() {
  local id="$1"
  if [[ ! "$id" =~ ^[0-9]+$ ]] || ((10#$id < 1 || 10#$id > 999999)); then
    err "Invalid VMID '$id'. Must be an integer between 1 and 999999."
    return 1
  fi
  return 0
}

# validate_snapshot_name NAME — reject names Proxmox would refuse.
# Valid: starts with alphanumeric, only [a-zA-Z0-9_-], max 40 chars.
validate_snapshot_name() {
  local sn="$1"
  if [[ ! "$sn" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}$ ]]; then
    err "Invalid snapshot name '$sn'."
    note "Name must start with a letter or digit, contain only [a-zA-Z0-9_-], and be at most 40 characters."
    return 1
  fi
  return 0
}

# =============================================================================
# GUARD FUNCTIONS
# =============================================================================

require_root() {
  # Allow CI or explicit overrides to bypass root check by setting
  # PROXMOX_MANAGER_ALLOW_NONROOT=1 in the environment.
  if [[ "${PROXMOX_MANAGER_ALLOW_NONROOT:-0}" == "1" ]]; then
    return 0
  fi
  ((EUID == 0)) || {
    err "Please run as root."
    exit 1
  }
}

require_tools() {
  { have qm || have pct; } || {
    err "Neither 'qm' nor 'pct' found. Run on a Proxmox VE host."
    exit 1
  }
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

# _script_version — extract version from the header comment of this script.
_script_version() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^#[[:space:]]Version[[:space:]]+([^[:space:]]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return
    fi
  done < "${BASH_SOURCE[0]}"
  printf 'unknown\n'
}

usage() {
  cat <<'EOF'
Usage: proxmox-manager.sh [options]

Options:
  --list       Print a plain-text overview of all VMs/CTs (no TUI)
  --json       Print machine-readable JSON with VM/CT information
  --no-clear   Do not clear the screen in interactive mode
  --once       Run a single interactive refresh (useful for TTY recording)
  --version    Print version and exit
  -h, --help   Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        MODE="list"
        LIST_FLAG=1
        ;;
      --json)
        MODE="json"
        JSON_FLAG=1
        ;;
      --no-clear)
        CLEAR_SCREEN=0
        ;;
      --once)
        RUN_ONCE=1
        ;;
      --version)
        printf 'proxmox-manager.sh %s\n' "$(_script_version)"
        exit 0
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        err "Unexpected argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
  if ((LIST_FLAG == 1 && JSON_FLAG == 1)); then
    err "Options --list and --json are not combinable."
    exit 1
  fi
}

# =============================================================================
# JSON HELPERS
# =============================================================================

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# =============================================================================
# DATA COLLECTION
# =============================================================================

# is_data_line LINE — true when LINE starts with an optional indent then digits.
is_data_line() {
  [[ "$1" =~ ^[[:space:]]*[0-9]+[[:space:]]+ ]]
}

# type_of_id ID — prints "CT", "VM", or empty string.
type_of_id() {
  local id="$1"
  if have pct && pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then
    printf 'CT'
    return
  fi
  if have qm && qm list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then
    printf 'VM'
    return
  fi
  printf ''
}

# status_of ID [TYPE] — prints the current status string.
status_of() {
  local id="$1" t="${2:-}"
  [[ -z "$t" ]] && t="$(type_of_id "$id")"
  case "$t" in
    CT) pct status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
    VM) qm  status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
    *) printf 'unknown' ;;
  esac
}

ct_name_from_config() { pct config "$1" 2>/dev/null | awk -F': *' '/^hostname:/ {print $2; exit}'; }
vm_name_from_config() { qm  config "$1" 2>/dev/null | awk -F': *' '/^name:/     {print $2; exit}'; }

# collect_instances — emit TAB-separated rows: ID TYPE STATUS SYMBOL NAME
collect_instances() {
  if have pct; then
    while IFS= read -r line; do
      [[ -z "${line// /}" ]] && continue
      is_data_line "$line" || continue
      local id status name sym
      id="$(awk '{print $1}' <<<"$line")"
      status="$(awk '{print $2}' <<<"$line")"
      name="$(awk '{print $NF}' <<<"$line")"
      [[ -z "$name" || "$name" == "-" ]] && name="$(ct_name_from_config "$id")"
      [[ -z "$name" ]] && name="CT-${id}"
      sym="[?]"
      [[ "$status" == "running" ]] && sym="[+]"
      [[ "$status" == "stopped" ]] && sym="[-]"
      [[ "$status" == "paused"  ]] && sym="[~]"
      printf "%s\tCT\t%s\t%s\t%s\n" "$id" "$status" "$sym" "$name"
    done < <(pct list 2>/dev/null || true)
  fi

  if have qm; then
    while IFS= read -r line; do
      [[ -z "${line// /}" ]] && continue
      is_data_line "$line" || continue
      local id status name sym
      id="$(awk '{print $1}' <<<"$line")"
      name="$(awk '{print $2}' <<<"$line")"
      status="$(awk '{print $3}' <<<"$line")"
      [[ -z "$name" || "$name" == "-" ]] && name="$(vm_name_from_config "$id")"
      [[ -z "$name" ]] && name="VM-${id}"
      sym="[?]"
      [[ "$status" == "running" ]] && sym="[+]"
      [[ "$status" == "stopped" ]] && sym="[-]"
      [[ "$status" == "paused"  ]] && sym="[~]"
      printf "%s\tVM\t%s\t%s\t%s\n" "$id" "$status" "$sym" "$name"
    done < <(qm list 2>/dev/null || true)
  fi
}

print_json() {
  mapfile -t rows < <(collect_instances | sort -n -t$'\t' -k1,1)
  if ((${#rows[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  printf '['
  local first=1
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id ty st sym nm <<<"$row"
    local sep=","
    if ((first)); then
      sep=''
      first=0
    fi
    local id_json="$id"
    if ! [[ "$id_json" =~ ^[0-9]+$ ]]; then
      id_json="\"$(json_escape "$id_json")\""
    fi
    printf '%s{"id":%s,"type":"%s","status":"%s","symbol":"%s","name":"%s"}' \
      "$sep" "$id_json" "$(json_escape "$ty")" "$(json_escape "$st")" \
      "$(json_escape "$sym")" "$(json_escape "$nm")"
  done
  printf ']\n'
}

# =============================================================================
# UI — HEADER & TABLE
# =============================================================================

# header — clears screen (if enabled) and prints the tool banner.
# When running on a Proxmox host, also shows node name and PVE version.
header() {
  if ((CLEAR_SCREEN == 1)) && [[ -t 1 ]]; then
    clear
  fi

  # Gather optional host info (silently ignored on non-PVE systems)
  local node_info=""
  local node_name pve_ver uptime_str
  node_name="$(hostname -s 2>/dev/null || true)"
  pve_ver="$(pveversion 2>/dev/null | awk '{print $2}' || true)"
  uptime_str="$(uptime -p 2>/dev/null | sed 's/^up //' || true)"
  if [[ -n "$node_name" ]]; then
    node_info=" Node: ${node_name}"
    [[ -n "$pve_ver" ]] && node_info+="  |  PVE: ${pve_ver}"
    [[ -n "$uptime_str" ]] && node_info+="  |  up ${uptime_str}"
  fi

  local version
  version="$(_script_version)"

  printf '%b\n' "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  printf '%b\n' "${BOLD}${BLUE}  Proxmox VM/CT Manager  v${version}${NC}"
  if [[ -n "$node_info" ]]; then
    printf '%b\n' "${BOLD}${BLUE}  ${node_info}${NC}"
  fi
  printf '%b\n' "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  echo
}

# _status_color STATUS TEXT — print TEXT in colour matching status.
_status_color() {
  local st="$1" txt="$2"
  case "$st" in
    running) printf '%b' "${GREEN}${txt}${NC}" ;;
    stopped) printf '%b' "${RED}${txt}${NC}"   ;;
    paused)  printf '%b' "${YELLOW}${txt}${NC}" ;;
    *)       printf '%b' "${txt}"              ;;
  esac
}

print_table() {
  printf '%b' "${BOLD}"
  printf "%-6s %-6s %-10s %-5s %-30s\n" "ID" "Type" "Status" "Sym." "Name"
  printf '%b' "${NC}"
  printf '%s\n' "─────────────────────────────────────────────────────────────"
  local any=0 count_run=0 count_stop=0 count_other=0
  while IFS=$'\t' read -r id ty st sym nm; do
    [[ -z "$id" ]] && continue
    any=1
    [[ "$st" == "running" ]] && count_run=$((count_run + 1))
    [[ "$st" == "stopped" ]] && count_stop=$((count_stop + 1))
    [[ "$st" != "running" && "$st" != "stopped" ]] && count_other=$((count_other + 1))
    # Print status column coloured, rest plain
    printf "%-6s %-6s " "$id" "$ty"
    _status_color "$st" "$(printf "%-10s" "$st")"
    printf " %-5s %-30s\n" "$sym" "$nm"
  done < <(collect_instances | sort -n -t$'\t' -k1,1)
  if ((any == 0)); then
    printf '%b\n' "${RED}No VMs or containers found.${NC}"
    printf '%s\n' "Run directly on the Proxmox host as root."
    return 1
  fi
  printf '%s\n' "─────────────────────────────────────────────────────────────"
  printf '%s\n' "Status: [+] running  [-] stopped  [~] paused  [?] unknown"
  printf "Count:  %b%s running%b  %b%s stopped%b" \
    "$GREEN" "$count_run" "$NC" "$RED" "$count_stop" "$NC"
  if (( count_other > 0 )); then printf "  %s other" "$count_other"; fi
  printf '\n'
  return 0
}

# =============================================================================
# INTERACTIVE MENUS
# =============================================================================

# confirm PROMPT — ask user for y/N; return 0 on yes, 1 on no/empty.
confirm() {
  local prompt="$1"
  local ans
  printf '%b' "${YELLOW}${prompt} [y/N]: ${NC}"
  read_line ans
  [[ "$ans" =~ ^[yY]$ ]]
}

main_menu() {
  header
  if ! print_table; then return 1; fi
  echo
  printf '%b\n' "${BOLD}Keys:${NC}  <VMID> = open action menu   r = refresh   q = quit"
  printf '%s' "Selection: "
  local choice
  read_line choice
  case "$choice" in
    q | Q) exit 0 ;;
    r | R | '') return 0 ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if ! validate_vmid "$choice"; then
          return 0
        fi
        local sel_type sel_name found=0
        while IFS=$'\t' read -r id ty _ _ nm; do
          if [[ "$id" == "$choice" ]]; then
            sel_type="$ty"
            sel_name="$nm"
            found=1
            break
          fi
        done < <(collect_instances)
        if ((found == 1)); then
          action_menu "$choice" "$sel_type" "$sel_name"
        else
          err "VMID $choice not found. Press 'r' to refresh the list."
        fi
      else
        err "Invalid input: '$choice'. Enter a numeric VMID, 'r', or 'q'."
      fi
      ;;
  esac
}

action_menu() {
  local id="$1" ty="$2" name="$3"
  local st
  st="$(status_of "$id" "$ty")"

  echo
  printf '%b\n' "${BOLD}${CYAN}━━━  ${ty} ${id}  (${name})  ━━━${NC}"
  # Status line with colour
  printf "  Status: "
  _status_color "$st" "$st"
  printf '\n\n'

  printf '%b\n' "${BOLD}Actions:${NC}"
  printf '  %b1%b) Start        %b2%b) Stop         %b3%b) Restart\n' \
    "$GREEN" "$NC" "$RED" "$NC" "$YELLOW" "$NC"
  printf '  %b4%b) Status       %b5%b) Console      %b6%b) Snapshots\n' \
    "$CYAN" "$NC" "$CYAN" "$NC" "$CYAN" "$NC"
  if [[ "$ty" == "VM" ]]; then
    printf '  %b7%b) SPICE info   %b8%b) Enable SPICE\n' \
      "$CYAN" "$NC" "$CYAN" "$NC"
  fi
  printf '  %b9%b) Back\n' "$BOLD" "$NC"
  echo
  printf '%s' "Selection [1-9]: "
  local opt
  read_line opt
  case "$opt" in
    1) do_action "$id" "$ty" start "$name" ;;
    2) do_action "$id" "$ty" stop  "$name" ;;
    3) do_action "$id" "$ty" restart "$name" ;;
    4) do_action "$id" "$ty" status "$name" ;;
    5) open_console "$id" "$ty" "$name" ;;
    6) snapshots_menu "$id" "$ty" "$name" ;;
    7)
      if [[ "$ty" == "VM" ]]; then
        spice_info "$id" "$name"
      else
        err "SPICE is only available for VMs."
      fi
      ;;
    8)
      if [[ "$ty" == "VM" ]]; then
        spice_enable "$id"
      else
        err "SPICE is only available for VMs."
      fi
      ;;
    9 | '') : ;;
    *) err "Invalid selection. Enter 1-9." ;;
  esac
  printf '\n%s' "Press Enter to continue... "
  local _dummy
  read_line _dummy
}

# =============================================================================
# ACTIONS
# =============================================================================

do_action() {
  local id="$1" ty="$2" act="$3" name="$4"
  local st
  st="$(status_of "$id" "$ty")"

  case "$act" in
    # ------------------------------------------------------------------
    start)
      if [[ "$st" == "running" ]]; then
        ok "$ty $id ($name) is already running."
        return
      fi
      note "Starting $ty $id ($name)..."
      local _pve_out
      if [[ "$ty" == "CT" ]]; then
        if _pve_out=$(pct start "$id" 2>&1); then
          ok "$ty $id started successfully."
        else
          err "Failed to start CT $id."
          [[ -n "$_pve_out" ]] && note "Proxmox: $(printf '%s' "$_pve_out" | head -3)"
        fi
      else
        if _pve_out=$(qm start "$id" 2>&1); then
          ok "$ty $id started successfully."
        else
          err "Failed to start VM $id."
          [[ -n "$_pve_out" ]] && note "Proxmox: $(printf '%s' "$_pve_out" | head -3)"
        fi
      fi
      ;;

    # ------------------------------------------------------------------
    stop)
      if [[ "$st" != "running" ]]; then
        ok "$ty $id ($name) is not running (status: $st)."
        return
      fi
      confirm "Stop $ty $id ($name)?" || { note "Aborted."; return; }
      note "Stopping $ty $id ($name)..."
      local _pve_out
      if [[ "$ty" == "CT" ]]; then
        if _pve_out=$(pct stop "$id" 2>&1); then
          ok "$ty $id stopped."
        else
          err "Failed to stop CT $id."
          [[ -n "$_pve_out" ]] && note "Proxmox: $(printf '%s' "$_pve_out" | head -3)"
        fi
      else
        if _pve_out=$(qm stop "$id" 2>&1); then
          ok "$ty $id stopped."
        else
          err "Failed to stop VM $id."
          [[ -n "$_pve_out" ]] && note "Proxmox: $(printf '%s' "$_pve_out" | head -3)"
        fi
      fi
      ;;

    # ------------------------------------------------------------------
    restart)
      if [[ "$st" != "running" ]]; then
        note "$ty $id ($name) is not running. Starting instead of restarting."
        do_action "$id" "$ty" start "$name"
        return
      fi
      confirm "Restart $ty $id ($name)?" || { note "Aborted."; return; }
      note "Restarting $ty $id ($name)..."
      local _pve_out
      if [[ "$ty" == "CT" ]]; then
        if _pve_out=$(pct stop "$id" 2>&1) && sleep 1 && _pve_out=$(pct start "$id" 2>&1); then
          ok "$ty $id restarted."
        else
          err "Failed to restart CT $id."
          [[ -n "$_pve_out" ]] && note "Proxmox: $(printf '%s' "$_pve_out" | head -3)"
        fi
      else
        if _pve_out=$(qm stop "$id" 2>&1) && sleep 1 && _pve_out=$(qm start "$id" 2>&1); then
          ok "$ty $id restarted."
        else
          err "Failed to restart VM $id."
          [[ -n "$_pve_out" ]] && note "Proxmox: $(printf '%s' "$_pve_out" | head -3)"
        fi
      fi
      ;;

    # ------------------------------------------------------------------
    status)
      note "Status for $ty $id ($name):"
      if [[ "$ty" == "CT" ]]; then
        if ! pct status "$id" 2>/dev/null; then
          err "Could not retrieve status for CT $id."
        fi
      else
        if ! qm status "$id" 2>/dev/null; then
          err "Could not retrieve status for VM $id."
        fi
      fi
      ;;

    *) err "Unknown action: $act" ;;
  esac
}

# =============================================================================
# CONSOLE
# =============================================================================

open_console() {
  local id="$1" ty="$2" name="$3"
  note "Opening console for $ty $id ($name)..."
  if [[ "$ty" == "CT" ]]; then
    if have pct; then
      if [[ "$(status_of "$id" CT)" != "running" ]]; then
        err "CT $id is not running. Start it first."
        return
      fi
      echo "Press CTRL+D to exit the console."
      pct enter "$id"
    else
      err "'pct' not found."
    fi
  else
    if [[ "$(status_of "$id" VM)" != "running" ]]; then
      err "VM $id is not running. Start it first."
      return
    fi
    if qm terminal "$id" 2>/dev/null; then
      :
    else
      note "'qm terminal' not available. Falling back to 'qm monitor'."
      qm monitor "$id" || err "Console for VM $id failed."
    fi
  fi
}

# =============================================================================
# SNAPSHOTS
# =============================================================================

# _list_snapshots ID TYPE — print snapshot list; returns 1 if none found.
_list_snapshots() {
  local id="$1" ty="$2"
  local out
  if [[ "$ty" == "CT" ]]; then
    out="$(pct listsnapshot "$id" 2>/dev/null || true)"
  else
    out="$(qm listsnapshot "$id" 2>/dev/null || true)"
  fi
  if [[ -z "$out" ]]; then
    note "No snapshots found for $ty $id."
    return 1
  fi
  printf '%b\n' "${BOLD}Snapshots for $ty $id:${NC}"
  printf '%s\n' "$out"
  return 0
}

snapshots_menu() {
  local id="$1" ty="$2" name="$3"
  echo
  printf '%b\n' "${BOLD}Snapshot menu — $ty $id ($name)${NC}"
  echo "  1) List snapshots"
  echo "  2) Create snapshot"
  echo "  3) Rollback to snapshot"
  echo "  4) Delete snapshot"
  echo "  5) Back"
  echo
  printf '%s' "Selection [1-5]: "
  local s
  read_line s
  case "$s" in
    1)
      _list_snapshots "$id" "$ty" || true
      ;;

    2)
      printf '%s' "Snapshot name: "
      local sn
      read_line sn
      sn="$(trim "$sn")"
      if [[ -z "$sn" ]]; then
        note "Aborted — no name given."
        return
      fi
      validate_snapshot_name "$sn" || return
      note "Creating snapshot '$sn' for $ty $id..."
      local _snap_out
      if [[ "$ty" == "CT" ]]; then
        if ! _snap_out=$(pct snapshot "$id" "$sn" 2>&1); then
          err "Snapshot creation failed."
          [[ -n "$_snap_out" ]] && note "Proxmox: $(printf '%s' "$_snap_out" | head -3)"
          return
        fi
      else
        if ! _snap_out=$(qm snapshot "$id" "$sn" 2>&1); then
          err "Snapshot creation failed."
          [[ -n "$_snap_out" ]] && note "Proxmox: $(printf '%s' "$_snap_out" | head -3)"
          return
        fi
      fi
      ok "Snapshot '$sn' created."
      ;;

    3)
      # Show existing snapshots before asking for a name
      _list_snapshots "$id" "$ty" || true
      echo
      printf '%s' "Roll back to snapshot name: "
      local sn
      read_line sn
      sn="$(trim "$sn")"
      if [[ -z "$sn" ]]; then
        note "Aborted — no name given."
        return
      fi
      confirm "Roll back $ty $id to snapshot '$sn'? This cannot be undone." || { note "Aborted."; return; }
      note "Rolling back $ty $id to '$sn'..."
      local _rb_out
      if [[ "$ty" == "CT" ]]; then
        if ! _rb_out=$(pct rollback "$id" "$sn" 2>&1); then
          err "Rollback failed."
          [[ -n "$_rb_out" ]] && note "Proxmox: $(printf '%s' "$_rb_out" | head -3)"
          return
        fi
      else
        if ! _rb_out=$(qm rollback "$id" "$sn" 2>&1); then
          err "Rollback failed."
          [[ -n "$_rb_out" ]] && note "Proxmox: $(printf '%s' "$_rb_out" | head -3)"
          return
        fi
      fi
      ok "Rollback to '$sn' completed."
      ;;

    4)
      # Show existing snapshots before asking for a name
      _list_snapshots "$id" "$ty" || true
      echo
      printf '%s' "Snapshot to delete: "
      local sn
      read_line sn
      sn="$(trim "$sn")"
      if [[ -z "$sn" ]]; then
        note "Aborted — no name given."
        return
      fi
      confirm "Delete snapshot '$sn' from $ty $id?" || { note "Aborted."; return; }
      note "Deleting snapshot '$sn'..."
      local _del_out
      if [[ "$ty" == "CT" ]]; then
        if ! _del_out=$(pct delsnapshot "$id" "$sn" 2>&1); then
          err "Snapshot deletion failed."
          [[ -n "$_del_out" ]] && note "Proxmox: $(printf '%s' "$_del_out" | head -3)"
          return
        fi
      else
        if ! _del_out=$(qm delsnapshot "$id" "$sn" 2>&1); then
          err "Snapshot deletion failed."
          [[ -n "$_del_out" ]] && note "Proxmox: $(printf '%s' "$_del_out" | head -3)"
          return
        fi
      fi
      ok "Snapshot '$sn' deleted."
      ;;

    5) : ;;
    *) err "Invalid selection." ;;
  esac
}

# =============================================================================
# SPICE
# =============================================================================

spice_info() {
  local id="$1" name="$2"
  local host port
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  port="$(qm monitor "$id" <<<"info spice" 2>/dev/null \
    | awk '/port/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}')"
  [[ -z "$port" ]] && port="$(grep -E "(spice).*port" "/var/log/qemu-server/${id}.log" 2>/dev/null \
    | tail -1 | sed -n 's/.*port=\([0-9]\+\).*/\1/p' || true)"
  # Ensure port is a valid integer before arithmetic; use explicit integer cast
  local id_int
  id_int=$(( 10#$id ))
  [[ -z "$port" ]] && port="$(( 61000 + id_int ))"

  printf '%s\n' "SPICE: spice://${host}:${port}"
  umask 077
  local vv
  vv="$(mktemp -p "${TMPDIR:-/tmp}" "vm-${id}.XXXXXX.vv")" || { err "mktemp failed"; return 1; }
  chmod 600 "$vv" || true
  cat >"$vv" <<EOF
[virt-viewer]
type=spice
host=${host}
port=${port}
title=VM ${id} (${name})
delete-this-file=1
fullscreen=0
EOF
  ok "SPICE connection file: ${vv}"
}

spice_enable() {
  local id="$1"
  # Explicit integer cast to prevent arithmetic on a string variable
  local id_int port
  id_int=$(( 10#$id ))
  port=$(( 61000 + id_int ))
  local addr="${PROXMOX_MANAGER_SPICE_ADDR:-127.0.0.1}"
  qm set "$id" --vga qxl >/dev/null 2>&1 || true
  if qm set "$id" --spice "port=${port},addr=${addr}" >/dev/null 2>&1; then
    ok "SPICE enabled for VM ${id}. Port: ${port}. A restart is required."
    confirm "Restart VM ${id} now?" && do_action "$id" "VM" restart "VM-${id}"
  else
    err "Could not enable SPICE for VM ${id}."
  fi
}

# =============================================================================
# ENTRY POINT
# =============================================================================

main() {
  parse_args "$@"
  require_root
  require_tools
  if [[ ! -t 1 ]]; then
    CLEAR_SCREEN=0
  fi
  log "INFO" "Starting proxmox-manager (mode=$MODE)"
  case "$MODE" in
    list)
      if print_table; then
        exit 0
      else
        exit 1
      fi
      ;;
    json)
      print_json
      exit 0
      ;;
    interactive)
      while true; do
        main_menu || true
        ((RUN_ONCE == 1)) && break
      done
      ;;
    *)
      err "Unknown mode: $MODE"
      exit 1
      ;;
  esac
}

main "$@"
