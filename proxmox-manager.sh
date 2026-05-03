#!/usr/bin/env bash
# Proxmox VM/CT Management Tool
# Version 2.9.0 — 2026-04-09
# - feat: --filter STATUS flag for --list/--json (running|stopped|paused)
# - feat: --timeout SECS flag for stop operations; exit-124 fallback with --overrule-shutdown
# - feat: --force flag to skip all confirm() prompts
# - fix: restart uses native pct reboot / qm reboot (atomic, no sleep)
# - fix: replace indirect SYM_ expansion in action_menu (set -u safe)
# - perf: type_of_id() uses _type_cache; populated as side-effect of main_menu loop
# - perf: collect_instances() replaces awk subshells with IFS read + parameter expansion
# - infra: CHANGELOG.md, GitHub issue templates, PR template, release.yml, FUNDING.yml
# - infra: Bash and Zsh completion scripts in completions/
# - tests: 29 tests (was 8); unit tests for validate_vmid, validate_snapshot_name, --filter
# - ui:    TUI redesign – ASCII banner, Unicode icons, box-drawing, extended colors

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
LOG_FILE="${LOG_FILE:-}"           # Set LOG_FILE=/path/to/file to enable file logging
FILTER_STATUS=""                   # Filter output by status: running|stopped|paused (empty = no filter)
STOP_TIMEOUT="${STOP_TIMEOUT:-60}" # Timeout in seconds for stop operations; env-overridable
FORCE_MODE=0                       # Set to 1 via --force to skip all confirm() prompts
declare -A _type_cache=()          # ID→type cache populated by main_menu; used by type_of_id()

# =============================================================================
# COLORS  (active only on a real TTY, or when NO_COLOR is unset)
# =============================================================================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'
  DIM=$'\e[2m'
  YELLOW=$'\e[33m'
  CYAN=$'\e[36m'
  WHITE=$'\e[37m'
  RED_BRIGHT=$'\e[91m'
  GREEN_BRIGHT=$'\e[92m'
  YELLOW_BRIGHT=$'\e[93m'
  BLUE_BRIGHT=$'\e[94m'
  MAGENTA_BRIGHT=$'\e[95m'
  CYAN_BRIGHT=$'\e[96m'
  NC=$'\e[0m'
else
  BOLD=''
  DIM=''
  YELLOW=''
  CYAN=''
  WHITE=''
  RED_BRIGHT=''
  GREEN_BRIGHT=''
  YELLOW_BRIGHT=''
  BLUE_BRIGHT=''
  MAGENTA_BRIGHT=''
  CYAN_BRIGHT=''
  NC=''
fi

# Status symbols (Unicode on UTF-8 terminals, ASCII fallback)
if [[ "${LANG:-}${LC_ALL:-}" =~ [Uu][Tt][Ff]-?8 || "${TERM:-}" == *256color* ]]; then
  SYM_RUNNING='●'
  SYM_STOPPED='○'
  SYM_PAUSED='◐'
  SYM_UNKNOWN='?'
  BOX_TL='╔'
  BOX_TR='╗'
  BOX_BL='╚'
  BOX_BR='╝'
  BOX_H='═'
  BOX_V='║'
  BOX_ML='╠'
  BOX_MR='╣'
  LINE_H='─'
  LINE_TL='┌'
  LINE_TR='┐'
  LINE_BL='└'
  LINE_BR='┘'
  LINE_V='│'
  LINE_ML='├'
  LINE_MR='┤'
else
  SYM_RUNNING='[+]'
  SYM_STOPPED='[-]'
  SYM_PAUSED='[~]'
  SYM_UNKNOWN='[?]'
  BOX_TL='+'
  BOX_TR='+'
  BOX_BL='+'
  BOX_BR='+'
  BOX_H='='
  BOX_V='|'
  BOX_ML='+'
  BOX_MR='+'
  LINE_H='-'
  LINE_TL='+'
  LINE_TR='+'
  LINE_BL='+'
  LINE_BR='+'
  LINE_V='|'
  LINE_ML='+'
  LINE_MR='+'
fi

# =============================================================================
# SIGNAL HANDLING
# =============================================================================
trap 'printf "\n%s\n" "Exiting."; exit 0' INT TERM

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

have() { command -v "$1" >/dev/null 2>&1; }
err() {
  printf '%b\n' "  ${RED_BRIGHT}✖  Error:${NC} $*" >&2
  log "ERROR" "$*"
}
ok() {
  printf '%b\n' "  ${GREEN_BRIGHT}✔  ${NC}$*"
  log "OK" "$*"
}
note() {
  printf '%b\n' "  ${CYAN_BRIGHT}→  ${NC}$*"
  log "NOTE" "$*"
}
warn() {
  printf '%b\n' "  ${YELLOW_BRIGHT}⚠  Warning:${NC} $*"
  log "WARN" "$*"
}

# log() — structured timestamped logging; writes to LOG_FILE when set.
# Usage: log LEVEL message…
log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE" 2>/dev/null || true
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

# _repeat CHAR N — print CHAR repeated N times.
_repeat() {
  local char="$1" n="$2" out=''
  local i
  for ((i = 0; i < n; i++)); do out+="$char"; done
  printf '%s' "$out"
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
  done <"${BASH_SOURCE[0]}"
  printf 'unknown\n'
}

usage() {
  cat <<'EOF'
Usage: proxmox-manager.sh [options]

Options:
  --list            Print a plain-text overview of all VMs/CTs (no TUI)
  --json            Print machine-readable JSON with VM/CT information
  --filter STATUS   Filter --list/--json output (running|stopped|paused)
  --no-clear        Do not clear the screen in interactive mode
  --once            Run a single interactive refresh (useful for TTY recording)
  --timeout SECS    Timeout for stop operations in seconds (default: 60)
  --force           Skip all confirmation prompts (use with care)
  --version         Print version and exit
  -h, --help        Show this help
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
    --filter)
      if [[ $# -lt 2 ]]; then
        err "--filter requires a value: running, stopped, or paused."
        exit 1
      fi
      FILTER_STATUS="$2"
      case "$FILTER_STATUS" in
      running | stopped | paused) ;;
      *)
        err "Invalid --filter value '$FILTER_STATUS'. Valid: running, stopped, paused."
        exit 1
        ;;
      esac
      shift # consume the STATUS value; outer shift consumes --filter
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        err "--timeout requires a value in seconds (e.g., --timeout 30)."
        exit 1
      fi
      STOP_TIMEOUT="$2"
      if [[ ! "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || ((STOP_TIMEOUT < 1)); then
        err "--timeout requires a positive integer (seconds), got '$STOP_TIMEOUT'."
        exit 1
      fi
      shift # consume the SECS value; outer shift consumes --timeout
      ;;
    --force)
      FORCE_MODE=1
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
# Checks _type_cache first; falls back to pct/qm list on a cache miss and stores the result.
type_of_id() {
  local id="$1"
  if [[ -n "${_type_cache[$id]:-}" ]]; then
    printf '%s' "${_type_cache[$id]}"
    return
  fi
  local result=''
  if have pct && pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then
    result='CT'
  elif have qm && qm list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then
    result='VM'
  fi
  _type_cache["$id"]="$result"
  printf '%s' "$result"
}

# status_of ID [TYPE] — prints the current status string.
status_of() {
  local id="$1" t="${2:-}"
  [[ -z "$t" ]] && t="$(type_of_id "$id")"
  case "$t" in
  CT) pct status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
  VM) qm status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
  *) printf 'unknown' ;;
  esac
}

ct_name_from_config() { pct config "$1" 2>/dev/null | awk -F': *' '/^hostname:/ {print $2; exit}'; }
vm_name_from_config() { qm config "$1" 2>/dev/null | awk -F': *' '/^name:/     {print $2; exit}'; }

# collect_instances — emit TAB-separated rows: ID TYPE STATUS SYMBOL NAME
collect_instances() {
  if have pct; then
    while IFS= read -r line; do
      [[ -z "${line// /}" ]] && continue
      is_data_line "$line" || continue
      local id status name sym _t _rest
      _t="${line#"${line%%[![:space:]]*}"}"
      IFS=' ' read -r id status _rest <<<"$_t"
      name="${_rest##* }"
      [[ -z "$name" || "$name" == "-" ]] && name="$(ct_name_from_config "$id")"
      [[ -z "$name" ]] && name="CT-${id}"
      sym="$SYM_UNKNOWN"
      [[ "$status" == "running" ]] && sym="$SYM_RUNNING"
      [[ "$status" == "stopped" ]] && sym="$SYM_STOPPED"
      [[ "$status" == "paused" ]] && sym="$SYM_PAUSED"
      printf "%s\tCT\t%s\t%s\t%s\n" "$id" "$status" "$sym" "$name"
    done < <(pct list 2>/dev/null || true)
  fi

  if have qm; then
    while IFS= read -r line; do
      [[ -z "${line// /}" ]] && continue
      is_data_line "$line" || continue
      local id name status sym _t _rest
      _t="${line#"${line%%[![:space:]]*}"}"
      IFS=' ' read -r id name status _rest <<<"$_t"
      [[ -z "$name" || "$name" == "-" ]] && name="$(vm_name_from_config "$id")"
      [[ -z "$name" ]] && name="VM-${id}"
      sym="$SYM_UNKNOWN"
      [[ "$status" == "running" ]] && sym="$SYM_RUNNING"
      [[ "$status" == "stopped" ]] && sym="$SYM_STOPPED"
      [[ "$status" == "paused" ]] && sym="$SYM_PAUSED"
      printf "%s\tVM\t%s\t%s\t%s\n" "$id" "$status" "$sym" "$name"
    done < <(qm list 2>/dev/null || true)
  fi
}

# filtered_instances — wraps collect_instances; when FILTER_STATUS is set,
# emits only rows whose status field matches. Used by print_table and print_json.
filtered_instances() {
  if [[ -z "$FILTER_STATUS" ]]; then
    collect_instances
    return
  fi
  local id ty st sym nm
  while IFS=$'\t' read -r id ty st sym nm; do
    [[ "$st" == "$FILTER_STATUS" ]] && printf "%s\t%s\t%s\t%s\t%s\n" "$id" "$ty" "$st" "$sym" "$nm"
  done < <(collect_instances)
}

print_json() {
  mapfile -t rows < <(filtered_instances | sort -n -t$'\t' -k1,1)
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

# _draw_box_top WIDTH — top border of a double-line box.
_draw_box_top() {
  local w="$1"
  printf '%b%s%s%s%b\n' "${BLUE_BRIGHT}" "${BOX_TL}" "$(_repeat "$BOX_H" $((w - 2)))" "${BOX_TR}" "${NC}"
}

# _draw_box_mid WIDTH — middle separator of a double-line box.
_draw_box_mid() {
  local w="$1"
  printf '%b%s%s%s%b\n' "${BLUE_BRIGHT}" "${BOX_ML}" "$(_repeat "$BOX_H" $((w - 2)))" "${BOX_MR}" "${NC}"
}

# _draw_box_bot WIDTH — bottom border of a double-line box.
_draw_box_bot() {
  local w="$1"
  printf '%b%s%s%s%b\n' "${BLUE_BRIGHT}" "${BOX_BL}" "$(_repeat "$BOX_H" $((w - 2)))" "${BOX_BR}" "${NC}"
}

# _draw_box_row WIDTH TEXT COLOR — one padded row inside a double-line box.
_draw_box_row() {
  local w="$1" text="$2" color="${3:-}"
  local inner=$((w - 4))
  printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
    "${color}" "$inner" "$text" "${NC}" \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
}

# _draw_line_top WIDTH — top border of a single-line box.
_draw_line_top() {
  local w="$1"
  printf '%b%s%s%s%b\n' "${CYAN}" "${LINE_TL}" "$(_repeat "$LINE_H" $((w - 2)))" "${LINE_TR}" "${NC}"
}

# _draw_line_mid WIDTH — middle separator of a single-line box.
_draw_line_mid() {
  local w="$1"
  printf '%b%s%s%s%b\n' "${CYAN}" "${LINE_ML}" "$(_repeat "$LINE_H" $((w - 2)))" "${LINE_MR}" "${NC}"
}

# _draw_line_bot WIDTH — bottom border of a single-line box.
_draw_line_bot() {
  local w="$1"
  printf '%b%s%s%s%b\n' "${CYAN}" "${LINE_BL}" "$(_repeat "$LINE_H" $((w - 2)))" "${LINE_BR}" "${NC}"
}

# _draw_line_row WIDTH TEXT COLOR — one padded row inside a single-line box.
_draw_line_row() {
  local w="$1" text="$2" color="${3:-}"
  local inner=$((w - 4))
  printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "${color}" "$inner" "$text" "${NC}" \
    "${CYAN}" "${LINE_V}" "${NC}"
}

# header — clears screen (if enabled) and prints the tool banner.
# When running on a Proxmox host, also shows node name and PVE version.
header() {
  if ((CLEAR_SCREEN == 1)) && [[ -t 1 ]]; then
    clear
  fi

  local version
  version="$(_script_version)"

  # Gather optional host info
  local node_name pve_ver uptime_str
  node_name="$(hostname -s 2>/dev/null || true)"
  pve_ver="$(pveversion 2>/dev/null | awk '{print $2}' || true)"
  uptime_str="$(uptime -p 2>/dev/null | sed 's/^up //' || true)"

  local W=53

  _draw_box_top $W
  # ASCII art banner
  printf '%b%s%b  %b%s%b  %b%s%b\n' \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
    "${CYAN_BRIGHT}${BOLD}" "██████╗ ███╗   ███╗ █████╗ ███╗  ██╗" "${NC}" \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
  printf '%b%s%b  %b%s%b  %b%s%b\n' \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
    "${CYAN_BRIGHT}${BOLD}" "██╔══██╗████╗ ████║██╔══██╗████╗ ██║" "${NC}" \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
  printf '%b%s%b  %b%s%b  %b%s%b\n' \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
    "${CYAN_BRIGHT}${BOLD}" "██████╔╝██╔████╔██║███████║██╔██╗██║" "${NC}" \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
  printf '%b%s%b  %b%s%b  %b%s%b\n' \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
    "${CYAN_BRIGHT}${BOLD}" "██╔═══╝ ██║╚██╔╝██║██╔══██║██║╚████║" "${NC}" \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
  printf '%b%s%b  %b%s%b  %b%s%b\n' \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
    "${CYAN_BRIGHT}${BOLD}" "██║     ██║ ╚═╝ ██║██║  ██║██║  ███║" "${NC}" \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
  _draw_box_mid $W
  # Version badge
  local ver_line
  printf -v ver_line "  Proxmox VM/CT Manager  %bv%s%b" "${MAGENTA_BRIGHT}${BOLD}" "$version" "${NC}"
  printf '%b%s%b%s  %b%s%b\n' \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
    "$ver_line" \
    "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
  # Node info badges
  if [[ -n "$node_name" ]]; then
    local info_line="  ${BOLD}Node:${NC} ${WHITE}${node_name}${NC}"
    [[ -n "$pve_ver" ]] && info_line+="  ${DIM}|${NC}  ${BOLD}PVE:${NC} ${WHITE}${pve_ver}${NC}"
    [[ -n "$uptime_str" ]] && info_line+="  ${DIM}|${NC}  ${BOLD}up${NC} ${WHITE}${uptime_str}${NC}"
    printf '%b%s%b%b%s%b  %b%s%b\n' \
      "${BLUE_BRIGHT}" "${BOX_V}" "${NC}" \
      "" "$info_line" "${NC}" \
      "${BLUE_BRIGHT}" "${BOX_V}" "${NC}"
  fi
  _draw_box_bot $W
  echo
}

# _status_color STATUS TEXT — print TEXT in colour matching status.
_status_color() {
  local st="$1" txt="$2"
  case "$st" in
  running) printf '%b' "${GREEN_BRIGHT}${txt}${NC}" ;;
  stopped) printf '%b' "${RED_BRIGHT}${txt}${NC}" ;;
  paused) printf '%b' "${YELLOW_BRIGHT}${txt}${NC}" ;;
  *) printf '%b' "${DIM}${txt}${NC}" ;;
  esac
}

# _status_sym_color STATUS SYM — print symbol in colour matching status.
_status_sym_color() {
  local st="$1" sym="$2"
  case "$st" in
  running) printf '%b' "${GREEN_BRIGHT}${sym}${NC}" ;;
  stopped) printf '%b' "${RED_BRIGHT}${sym}${NC}" ;;
  paused) printf '%b' "${YELLOW_BRIGHT}${sym}${NC}" ;;
  *) printf '%b' "${DIM}${sym}${NC}" ;;
  esac
}

# _sym_for_status STATUS — return the correct SYM_* variable value for STATUS.
_sym_for_status() {
  local st="$1"
  case "$st" in
  running) printf '%s' "$SYM_RUNNING" ;;
  stopped) printf '%s' "$SYM_STOPPED" ;;
  paused)  printf '%s' "$SYM_PAUSED"  ;;
  *)       printf '%s' "$SYM_UNKNOWN" ;;
  esac
}

print_table() {
  local W=63
  _draw_line_top $W
  # Header row
  printf '%b%s%b  %b%-6s %-5s %-10s %-3s %-28s%b  %b%s%b\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "${BOLD}${WHITE}" "ID" "TYPE" "STATUS" "" "NAME" "${NC}" \
    "${CYAN}" "${LINE_V}" "${NC}"
  _draw_line_mid $W

  local any=0 count_run=0 count_stop=0 count_other=0
  while IFS=$'\t' read -r id ty st sym nm; do
    [[ -z "$id" ]] && continue
    any=1
    [[ "$st" == "running" ]] && count_run=$((count_run + 1))
    [[ "$st" == "stopped" ]] && count_stop=$((count_stop + 1))
    [[ "$st" != "running" && "$st" != "stopped" ]] && count_other=$((count_other + 1))

    # Colored type label
    local ty_col
    case "$ty" in
    CT) printf -v ty_col '%b%s%b' "${MAGENTA_BRIGHT}" "$ty" "${NC}" ;;
    VM) printf -v ty_col '%b%s%b' "${BLUE_BRIGHT}" "$ty" "${NC}" ;;
    *) ty_col="$ty" ;;
    esac

    printf '%b%s%b  ' "${CYAN}" "${LINE_V}" "${NC}"
    printf '%-6s ' "$id"
    printf '%s ' "$ty_col"
    printf '     ' # pad after colored ty (color codes don't count as width)
    _status_color "$st" "$(printf '%-10s' "$st")"
    printf ' '
    _status_sym_color "$st" "$sym"
    printf '  %-28s' "$nm"
    printf '  %b%s%b\n' "${CYAN}" "${LINE_V}" "${NC}"
  done < <(filtered_instances | sort -n -t$'\t' -k1,1)

  if ((any == 0)); then
    _draw_line_mid $W
    if [[ -n "$FILTER_STATUS" ]]; then
      printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
        "${CYAN}" "${LINE_V}" "${NC}" \
        "${RED_BRIGHT}" $((W - 6)) "No ${FILTER_STATUS} VMs or containers found." "${NC}" \
        "${CYAN}" "${LINE_V}" "${NC}"
    else
      printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
        "${CYAN}" "${LINE_V}" "${NC}" \
        "${RED_BRIGHT}" $((W - 6)) "No VMs or containers found." "${NC}" \
        "${CYAN}" "${LINE_V}" "${NC}"
      printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
        "${CYAN}" "${LINE_V}" "${NC}" \
        "${DIM}" $((W - 6)) "Run directly on the Proxmox host as root." "${NC}" \
        "${CYAN}" "${LINE_V}" "${NC}"
    fi
    _draw_line_bot $W
    return 1
  fi

  _draw_line_mid $W
  # Legend row
  printf '%b%s%b  ' "${CYAN}" "${LINE_V}" "${NC}"
  _status_sym_color "running" "$SYM_RUNNING"
  printf ' running   '
  _status_sym_color "stopped" "$SYM_STOPPED"
  printf ' stopped   '
  _status_sym_color "paused" "$SYM_PAUSED"
  printf ' paused   '
  printf '%b%s%b\n' "${CYAN}" "${LINE_V}" "${NC}"

  # Count row
  printf '%b%s%b  ' "${CYAN}" "${LINE_V}" "${NC}"
  printf '%bCount:%b  %b%s running%b  %b%s stopped%b' \
    "${BOLD}" "${NC}" \
    "${GREEN_BRIGHT}" "$count_run" "${NC}" \
    "${RED_BRIGHT}" "$count_stop" "${NC}"
  if ((count_other > 0)); then printf '  %s other' "$count_other"; fi
  printf '%b%s%b\n' "${CYAN}" "${LINE_V}" "${NC}" # note: no padding; cosmetic only
  _draw_line_bot $W
  return 0
}

# =============================================================================
# INTERACTIVE MENUS
# =============================================================================

# confirm PROMPT — ask user for y/N; return 0 on yes, 1 on no/empty.
# When FORCE_MODE=1, automatically returns 0 and prints a note instead of prompting.
confirm() {
  local prompt="$1"
  if ((FORCE_MODE == 1)); then
    printf '%b\n' "  ${YELLOW_BRIGHT}[--force]${NC} Skipping confirmation: ${prompt}"
    return 0
  fi
  local ans
  printf '%b' "  ${YELLOW}${prompt} [y/N]:${NC} "
  read_line ans
  [[ "$ans" =~ ^[yY]$ ]]
}

main_menu() {
  header
  if ! print_table; then return 1; fi
  echo
  printf '  %b%s%b  %s\n' "${BOLD}" "Keys:" "${NC}" \
    "<VMID> = open action menu   ${BOLD}r${NC} = refresh   ${BOLD}q${NC} = quit"
  printf '  %b→%b ' "${CYAN_BRIGHT}" "${NC}"
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
      local sel_type='' sel_name='' found=0
      while IFS=$'\t' read -r id ty _ _ nm; do
        _type_cache["$id"]="$ty" # warm the cache for all listed instances
        if [[ "$id" == "$choice" ]]; then
          sel_type="$ty"
          sel_name="$nm"
          found=1
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

  local W=45
  echo
  _draw_line_top $W

  # Title row
  local ty_col
  case "$ty" in
  CT) printf -v ty_col '%b%s%b' "${MAGENTA_BRIGHT}${BOLD}" "$ty" "${NC}" ;;
  VM) printf -v ty_col '%b%s%b' "${BLUE_BRIGHT}${BOLD}" "$ty" "${NC}" ;;
  *) ty_col="${BOLD}${ty}${NC}" ;;
  esac
  printf '%b%s%b  %s %s  %b(%s)%b\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "$ty_col" \
    "${BOLD}${id}${NC}" \
    "${DIM}" "$name" "${NC}"

  # Status row — use _sym_for_status to avoid indirect expansion under set -u
  local st_sym
  st_sym="$(_sym_for_status "$st")"
  printf '%b%s%b  Status: ' "${CYAN}" "${LINE_V}" "${NC}"
  _status_sym_color "$st" "$st_sym"
  printf ' '
  _status_color "$st" "$st"
  printf '\n'

  _draw_line_mid $W

  # Actions
  printf '%b%s%b  %b1%b) Start        %b2%b) Stop         %b3%b) Restart\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "${GREEN_BRIGHT}" "${NC}" \
    "${RED_BRIGHT}" "${NC}" \
    "${YELLOW_BRIGHT}" "${NC}"
  printf '%b%s%b  %b4%b) Status       %b5%b) Console      %b6%b) Snapshots\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "${CYAN_BRIGHT}" "${NC}" \
    "${CYAN_BRIGHT}" "${NC}" \
    "${CYAN_BRIGHT}" "${NC}"
  if [[ "$ty" == "VM" ]]; then
    printf '%b%s%b  %b7%b) SPICE info   %b8%b) Enable SPICE\n' \
      "${CYAN}" "${LINE_V}" "${NC}" \
      "${CYAN_BRIGHT}" "${NC}" \
      "${CYAN_BRIGHT}" "${NC}"
  fi
  printf '%b%s%b  %b9%b) Back\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "${DIM}" "${NC}"

  _draw_line_bot $W
  echo
  printf '  %b→%b Selection [1-9]: ' "${CYAN_BRIGHT}" "${NC}"
  local opt
  read_line opt
  case "$opt" in
  1) do_action "$id" "$ty" start "$name" ;;
  2) do_action "$id" "$ty" stop "$name" ;;
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
  printf '\n  %bPress Enter to continue...%b ' "${DIM}" "${NC}"
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
    confirm "Stop $ty $id ($name)?" || {
      note "Aborted."
      return
    }
    note "Stopping $ty $id ($name) (timeout: ${STOP_TIMEOUT}s)..."
    local _timeout_out='' _timeout_exit=0 _force_out='' _force_exit=0
    if [[ "$ty" == "CT" ]]; then
      _timeout_out=$(timeout "${STOP_TIMEOUT}" pct stop "$id" 2>&1) || _timeout_exit=$?
      if ((_timeout_exit == 0)); then
        ok "$ty $id stopped."
      elif ((_timeout_exit == 124)); then
        note "Timeout after ${STOP_TIMEOUT}s. Forcing stop with --overrule-shutdown..."
        _force_out=$(pct stop "$id" --overrule-shutdown 1 2>&1) || _force_exit=$?
        if ((_force_exit == 0)); then
          ok "$ty $id force-stopped."
        else
          err "Force stop failed for CT $id."
          [[ -n "$_force_out" ]] && note "Proxmox: $(printf '%s' "$_force_out" | head -3)"
        fi
      else
        err "Failed to stop CT $id."
        [[ -n "$_timeout_out" ]] && note "Proxmox: $(printf '%s' "$_timeout_out" | head -3)"
      fi
    else
      _timeout_out=$(timeout "${STOP_TIMEOUT}" qm stop "$id" 2>&1) || _timeout_exit=$?
      if ((_timeout_exit == 0)); then
        ok "$ty $id stopped."
      elif ((_timeout_exit == 124)); then
        note "Timeout after ${STOP_TIMEOUT}s. Forcing stop with --overrule-shutdown..."
        _force_out=$(qm stop "$id" --overrule-shutdown 1 2>&1) || _force_exit=$?
        if ((_force_exit == 0)); then
          ok "$ty $id force-stopped."
        else
          err "Force stop failed for VM $id."
          [[ -n "$_force_out" ]] && note "Proxmox: $(printf '%s' "$_force_out" | head -3)"
        fi
      else
        err "Failed to stop VM $id."
        [[ -n "$_timeout_out" ]] && note "Proxmox: $(printf '%s' "$_timeout_out" | head -3)"
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
    confirm "Restart $ty $id ($name)?" || {
      note "Aborted."
      return
    }
    note "Restarting $ty $id ($name)..."
    local _pve_out
    if [[ "$ty" == "CT" ]]; then
      if _pve_out=$(pct reboot "$id" 2>&1); then
        ok "$ty $id restarted."
      else
        err "Failed to restart CT $id."
        [[ -n "$_pve_out" ]] && note "Proxmox: $(printf '%s' "$_pve_out" | head -3)"
      fi
    else
      if _pve_out=$(qm reboot "$id" 2>&1); then
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
      echo "  Press CTRL+D to exit the console."
      pct enter "$id"
    else
      err "'pct' not found."
    fi
  else
    if [[ "$(status_of "$id" VM)" != "running" ]]; then
      err "VM $id is not running. Start it first."
      return
    fi
    note "Press Ctrl+] to exit the VM terminal."
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
  printf '%b  Snapshots for %s %s:%b\n' "${BOLD}${CYAN_BRIGHT}" "$ty" "$id" "${NC}"
  printf '%s\n' "$out"
  return 0
}

snapshots_menu() {
  local id="$1" ty="$2" name="$3"
  local W=45
  echo
  _draw_line_top $W
  printf '%b%s%b  %bSnapshot menu%b — %s %s (%s)\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "${BOLD}${CYAN_BRIGHT}" "${NC}" "$ty" "$id" "$name"
  _draw_line_mid $W
  printf '%b%s%b  %b1%b) List snapshots\n' "${CYAN}" "${LINE_V}" "${NC}" "${CYAN_BRIGHT}" "${NC}"
  printf '%b%s%b  %b2%b) Create snapshot\n' "${CYAN}" "${LINE_V}" "${NC}" "${GREEN_BRIGHT}" "${NC}"
  printf '%b%s%b  %b3%b) Rollback to snapshot\n' "${CYAN}" "${LINE_V}" "${NC}" "${YELLOW_BRIGHT}" "${NC}"
  printf '%b%s%b  %b4%b) Delete snapshot\n' "${CYAN}" "${LINE_V}" "${NC}" "${RED_BRIGHT}" "${NC}"
  printf '%b%s%b  %b5%b) Back\n' "${CYAN}" "${LINE_V}" "${NC}" "${DIM}" "${NC}"
  _draw_line_bot $W
  echo
  printf '  %b→%b Selection [1-5]: ' "${CYAN_BRIGHT}" "${NC}"
  local s
  read_line s
  case "$s" in
  1)
    _list_snapshots "$id" "$ty" || true
    ;;

  2)
    printf '  %bSnapshot name:%b ' "${BOLD}" "${NC}"
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
    _list_snapshots "$id" "$ty" || true
    echo
    printf '  %bRoll back to snapshot name:%b ' "${BOLD}" "${NC}"
    local sn
    read_line sn
    sn="$(trim "$sn")"
    if [[ -z "$sn" ]]; then
      note "Aborted — no name given."
      return
    fi
    validate_snapshot_name "$sn" || return
    confirm "Roll back $ty $id to snapshot '$sn'? This cannot be undone." || {
      note "Aborted."
      return
    }
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
    _list_snapshots "$id" "$ty" || true
    echo
    printf '  %bSnapshot to delete:%b ' "${BOLD}" "${NC}"
    local sn
    read_line sn
    sn="$(trim "$sn")"
    if [[ -z "$sn" ]]; then
      note "Aborted — no name given."
      return
    fi
    validate_snapshot_name "$sn" || return
    confirm "Delete snapshot '$sn' from $ty $id?" || {
      note "Aborted."
      return
    }
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
  *) err "Invalid selection. Enter 1-5." ;;
  esac
}

# =============================================================================
# SPICE
# =============================================================================

spice_info() {
  local id="$1" name="$2"
  local host port
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  port="$(qm monitor "$id" <<<"info spice" 2>/dev/null |
    awk '/port/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}')"
  [[ -z "$port" ]] && port="$(grep -E "(spice).*port" "/var/log/qemu-server/${id}.log" 2>/dev/null |
    tail -1 | sed -n 's/.*port=\([0-9]\+\).*/\1/p' || true)"
  local id_int
  id_int=$((10#$id))
  [[ -z "$port" ]] && port="$((61000 + id_int))"

  printf '  %bSPICE:%b spice://%s:%s\n' "${BOLD}${CYAN_BRIGHT}" "${NC}" "$host" "$port"
  umask 077
  local vv
  vv="$(mktemp -p "${TMPDIR:-/tmp}" "vm-${id}.XXXXXX.vv")" || {
    err "mktemp failed"
    return 1
  }
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
  local id_int port
  id_int=$((10#$id))
  port=$((61000 + id_int))
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
  if ((FORCE_MODE == 1)); then
    warn "--force active: all confirmation prompts will be skipped automatically."
  fi
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
