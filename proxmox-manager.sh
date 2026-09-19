#!/usr/bin/env bash
# Proxmox VM/CT Management Tool
# Version 2.12.0 — 2026-09-19
# - fix: #33 TUI frames aligned by visible width; long guest names fit/truncate; PVE version parsed correctly
# - feat: #28 show current IP addresses for running VMs/CTs
# - security: #31 config files parsed as allowlisted data; private log files; no %b on user text
# - fix: #30 snapshot names validated against pve-configid; SPICE uses the real bind address

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
PROXMOX_MANAGER_SPICE_ADDR="${PROXMOX_MANAGER_SPICE_ADDR:-}"
FORCE_MODE=0              # Set to 1 via --force to skip all confirm() prompts
FILTER_NAME=""            # ERE substring-match against VM/CT name (empty = no filter)
declare -A _type_cache=() # ID→type cache populated by main_menu; used by type_of_id()

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
  TRUNC_MARK='…'
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
  TRUNC_MARK='~'
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
  printf '  %b✖  Error:%b %s\n' "$RED_BRIGHT" "$NC" "$*" >&2
  log "ERROR" "$*"
}
ok() {
  printf '  %b✔  %b%s\n' "$GREEN_BRIGHT" "$NC" "$*"
  log "OK" "$*"
}
note() {
  printf '  %b→  %b%s\n' "$CYAN_BRIGHT" "$NC" "$*"
  log "NOTE" "$*"
}
warn() {
  printf '  %b⚠  Warning:%b %s\n' "$YELLOW_BRIGHT" "$NC" "$*"
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

# _log_pve_err OUTPUT [LABEL] — log full Proxmox stderr to LOG_FILE; show only first line on stdout.
_log_pve_err() {
  local out="$1" label="${2:-Proxmox}"
  [[ -z "$out" ]] && return
  if [[ -n "$LOG_FILE" ]]; then
    local _line
    while IFS= read -r _line; do
      log "PROXMOX" "$_line"
    done <<<"$out"
  fi
  note "${label}: $(printf '%s' "$out" | head -1)"
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

# _config_warn MESSAGE — report config problems without writing to LOG_FILE.
# LOG_FILE is not trusted until _prepare_log_file() has validated it.
_config_warn() {
  printf '  Warning: %s\n' "$*" >&2
}

# _load_config_file FILE — parse allowlisted KEY=VALUE settings as data, never shell code.
_load_config_file() {
  local file="$1" raw line key value
  [[ -f "$file" ]] || return 0

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="$(trim "$raw")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ ! "$line" =~ ^([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      _config_warn "Ignoring invalid config line in $file."
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="$(trim "${BASH_REMATCH[2]}")"

    if [[ "$value" =~ ^\"([^\"]*)\"([[:space:]]*#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'([^\']*)\'([[:space:]]*#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^[:space:]#]*)([[:space:]]+#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      _config_warn "Ignoring malformed value for $key in $file."
      continue
    fi

    case "$key" in
    STOP_TIMEOUT | LOG_FILE | PROXMOX_MANAGER_SPICE_ADDR)
      printf -v "$key" '%s' "$value"
      ;;
    *)
      _config_warn "Ignoring unsupported setting '$key' in $file."
      ;;
    esac
  done <"$file"
}

# _prepare_log_file — require a private regular file in a trusted directory.
_prepare_log_file() {
  [[ -z "$LOG_FILE" ]] && return 0
  if [[ "$LOG_FILE" != /* ]]; then
    _config_warn "LOG_FILE must be an absolute path; logging disabled."
    LOG_FILE=''
    return 1
  fi

  local parent owner mode
  parent="$(dirname -- "$LOG_FILE")"
  if [[ ! -d "$parent" ]]; then
    _config_warn "LOG_FILE parent directory does not exist; logging disabled."
    LOG_FILE=''
    return 1
  fi
  owner="$(stat -Lc '%u' -- "$parent" 2>/dev/null || printf 'invalid')"
  mode="$(stat -Lc '%a' -- "$parent" 2>/dev/null || printf 'invalid')"
  if [[ "$owner" != "$EUID" || ! "$mode" =~ ^[0-7]{3,4}$ ]] || ((8#$mode & 8#022)); then
    _config_warn "LOG_FILE parent directory is not private and owner-controlled; logging disabled."
    LOG_FILE=''
    return 1
  fi

  if [[ -e "$LOG_FILE" || -L "$LOG_FILE" ]]; then
    if [[ -L "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
      _config_warn "LOG_FILE must be a regular file and not a symlink; logging disabled."
      LOG_FILE=''
      return 1
    fi
    owner="$(stat -Lc '%u' -- "$LOG_FILE" 2>/dev/null || printf 'invalid')"
    mode="$(stat -Lc '%a' -- "$LOG_FILE" 2>/dev/null || printf 'invalid')"
    if [[ "$owner" != "$EUID" || ! "$mode" =~ ^[0-7]{3,4}$ ]] || ((8#$mode & 8#077)); then
      _config_warn "LOG_FILE must be owned by the current user with mode 0600; logging disabled."
      LOG_FILE=''
      return 1
    fi
  elif ! (
    umask 077
    set -o noclobber
    : >"$LOG_FILE"
  ) 2>/dev/null; then
    _config_warn "LOG_FILE could not be created safely; logging disabled."
    LOG_FILE=''
    return 1
  fi
  return 0
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
# Proxmox uses the pve-configid format for snapshot names:
# start with a letter, then one or more of [a-zA-Z0-9_-], max 40 chars.
validate_snapshot_name() {
  local sn="$1"
  if [[ ! "$sn" =~ ^[a-zA-Z][a-zA-Z0-9_-]{1,39}$ ]]; then
    err "Invalid snapshot name '$sn'."
    note "Name must start with a letter, contain only [a-zA-Z0-9_-], and be at most 40 characters."
    return 1
  fi
  return 0
}

# validate_menu_choice VAL MIN MAX CONTEXT — print error and return 1 when VAL is out of range.
validate_menu_choice() {
  local val="$1" min="$2" max="$3" context="$4"
  if [[ ! "$val" =~ ^[0-9]+$ ]] || ((10#$val < min || 10#$val > max)); then
    err "Invalid selection '$val' for $context. Enter ${min}–${max}."
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
  --name PATTERN    Filter by VM/CT name (ERE substring-match; combinable with --filter)
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
    --name)
      if [[ $# -lt 2 ]]; then
        err "--name requires an ERE pattern value."
        exit 1
      fi
      FILTER_NAME="$2"
      # Validate ERE: grep exit code ≥2 means invalid pattern
      local _grep_rc=0
      echo '' | grep -E -- "$FILTER_NAME" >/dev/null 2>&1 || _grep_rc=$?
      if ((_grep_rc >= 2)); then
        err "--name pattern '$FILTER_NAME' is not a valid ERE."
        exit 1
      fi
      shift
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

# filtered_instances — wraps collect_instances; applies FILTER_STATUS and FILTER_NAME (AND logic).
filtered_instances() {
  local id ty st sym nm
  while IFS=$'\t' read -r id ty st sym nm; do
    [[ -n "$FILTER_STATUS" && "$st" != "$FILTER_STATUS" ]] && continue
    if [[ -n "$FILTER_NAME" ]]; then
      [[ "$nm" =~ $FILTER_NAME ]] || continue
    fi
    printf "%s\t%s\t%s\t%s\t%s\n" "$id" "$ty" "$st" "$sym" "$nm"
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

# _vis_width TEXT — visible column count of TEXT.
# Strips ANSI SGR sequences and counts UTF-8 characters (the script runs
# with LC_ALL=C, so ${#var} alone would count bytes).
_vis_width() {
  local s="$1" re=$'\e''\[[0-9;]*m'
  while [[ "$s" =~ $re ]]; do s="${s/"${BASH_REMATCH[0]}"/}"; done
  s="${s//[$'\x80'-$'\xbf']/}"
  printf '%s' "${#s}"
}

# _pad_right TEXT WIDTH — print TEXT padded with spaces to WIDTH visible columns.
_pad_right() {
  local text="$1" w="$2" vw
  vw="$(_vis_width "$text")"
  printf '%s' "$text"
  ((vw < w)) && printf '%*s' $((w - vw)) ''
  return 0
}

# _truncate TEXT MAX — shorten plain TEXT to MAX columns, marking the cut.
_truncate() {
  local text="$1" max="$2"
  if (($(_vis_width "$text") <= max)); then
    printf '%s' "$text"
  else
    printf '%s%s' "${text:0:max-1}" "$TRUNC_MARK"
  fi
}

# _term_cols — terminal width (fallback 80).
_term_cols() {
  local c="${COLUMNS:-}"
  if [[ ! "$c" =~ ^[0-9]+$ ]] && [[ -t 1 ]]; then
    c="$(tput cols 2>/dev/null || true)"
  fi
  [[ "$c" =~ ^[0-9]+$ ]] && ((c >= 40)) || c=80
  printf '%s' "$c"
}

# _box_content COLOR V WIDTH CONTENT — CONTENT between two V borders,
# padded so the right border lands at column WIDTH.
_box_content() {
  local color="$1" v="$2" w="$3" content="$4"
  printf '%b%s%b' "$color" "$v" "$NC"
  _pad_right "$content" $((w - 2))
  printf '%b%s%b\n' "$color" "$v" "$NC"
}

# _uptime_short — compact host uptime, e.g. "17d 13h 4m".
_uptime_short() {
  local secs
  secs="$(cut -d. -f1 /proc/uptime 2>/dev/null || true)"
  [[ "$secs" =~ ^[0-9]+$ ]] || return 0
  local d=$((secs / 86400)) h=$((secs % 86400 / 3600)) m=$((secs % 3600 / 60))
  if ((d > 0)); then
    printf '%sd %sh %sm' "$d" "$h" "$m"
  elif ((h > 0)); then
    printf '%sh %sm' "$h" "$m"
  else
    printf '%sm' "$m"
  fi
}

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
  # pveversion prints e.g. "pve-manager/8.4.1/2a5fa54a (running kernel: ...)"
  pve_ver="$(pveversion 2>/dev/null | awk -F/ 'NR == 1 {print $2}' || true)"
  uptime_str="$(_uptime_short)"

  local W=63 inner=59 logo_line
  local -a logo=(
    "██████╗ ███╗   ███╗ █████╗ ███╗  ██╗"
    "██╔══██╗████╗ ████║██╔══██╗████╗ ██║"
    "██████╔╝██╔████╔██║███████║██╔██╗██║"
    "██╔═══╝ ██║╚██╔╝██║██╔══██║██║╚████║"
    "██║     ██║ ╚═╝ ██║██║  ██║██║  ███║"
  )

  _draw_box_top $W
  # ASCII art banner
  for logo_line in "${logo[@]}"; do
    _box_content "${BLUE_BRIGHT}" "${BOX_V}" $W "  ${CYAN_BRIGHT}${BOLD}${logo_line}${NC}"
  done
  _draw_box_mid $W
  # Version badge
  _box_content "${BLUE_BRIGHT}" "${BOX_V}" $W \
    "  Proxmox VM/CT Manager  ${MAGENTA_BRIGHT}${BOLD}v${version}${NC}"
  # Node info badges; drop uptime, then shorten the node name if too wide
  if [[ -n "$node_name" ]]; then
    local sep="  ${DIM}|${NC}  " info_line
    local ver_part="" up_part=""
    [[ -n "$pve_ver" ]] && ver_part="${sep}${BOLD}PVE:${NC} ${WHITE}${pve_ver}${NC}"
    [[ -n "$uptime_str" ]] && up_part="${sep}${BOLD}up${NC} ${WHITE}${uptime_str}${NC}"
    info_line="  ${BOLD}Node:${NC} ${WHITE}${node_name}${NC}${ver_part}${up_part}"
    if (($(_vis_width "$info_line") > inner)); then
      info_line="  ${BOLD}Node:${NC} ${WHITE}${node_name}${NC}${ver_part}"
    fi
    local overflow=$(($(_vis_width "$info_line") - inner))
    if ((overflow > 0)); then
      node_name="$(_truncate "$node_name" $((${#node_name} - overflow)))"
      info_line="  ${BOLD}Node:${NC} ${WHITE}${node_name}${NC}${ver_part}"
    fi
    _box_content "${BLUE_BRIGHT}" "${BOX_V}" $W "$info_line"
  fi
  _draw_box_bot $W
  echo
}

# _status_color STATUS TEXT — print TEXT in colour matching status.
_status_color() {
  local st="$1" txt="$2"
  case "$st" in
  running) printf '%b%s%b' "$GREEN_BRIGHT" "$txt" "$NC" ;;
  stopped) printf '%b%s%b' "$RED_BRIGHT" "$txt" "$NC" ;;
  paused) printf '%b%s%b' "$YELLOW_BRIGHT" "$txt" "$NC" ;;
  *) printf '%b%s%b' "$DIM" "$txt" "$NC" ;;
  esac
}

# _status_sym_color STATUS SYM — print symbol in colour matching status.
_status_sym_color() {
  local st="$1" sym="$2"
  case "$st" in
  running) printf '%b%s%b' "$GREEN_BRIGHT" "$sym" "$NC" ;;
  stopped) printf '%b%s%b' "$RED_BRIGHT" "$sym" "$NC" ;;
  paused) printf '%b%s%b' "$YELLOW_BRIGHT" "$sym" "$NC" ;;
  *) printf '%b%s%b' "$DIM" "$sym" "$NC" ;;
  esac
}

# _sym_for_status STATUS — return the correct SYM_* variable value for STATUS.
_sym_for_status() {
  local st="$1"
  case "$st" in
  running) printf '%s' "$SYM_RUNNING" ;;
  stopped) printf '%s' "$SYM_STOPPED" ;;
  paused) printf '%s' "$SYM_PAUSED" ;;
  *) printf '%s' "$SYM_UNKNOWN" ;;
  esac
}

print_table() {
  # Only draw boxes in interactive mode; in --list/--json, output plain table
  local draw_boxes=0
  [[ "$MODE" == "interactive" ]] && draw_boxes=1

  local -a rows=()
  mapfile -t rows < <(filtered_instances | sort -n -t$'\t' -k1,1)

  # NAME column grows with the longest name; boxed output is capped at the
  # terminal width and longer names are truncated.
  local name_w=29 row id ty st sym nm
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id ty st sym nm <<<"$row"
    (($(_vis_width "$nm") > name_w)) && name_w=$(_vis_width "$nm")
  done
  if ((draw_boxes)); then
    local max_name=$(($(_term_cols) - 34))
    ((name_w > max_name)) && name_w=$max_name
    ((name_w < 29)) && name_w=29
  fi
  # │ + 2 + ID 6 + 1 + TYPE 5 + 1 + STATUS 10 + 1 + SYM 3 + 1 + NAME + 2 + │
  local W=$((34 + name_w))

  if ((draw_boxes)); then
    _draw_line_top $W
    local head
    printf -v head '  %b%-6s %-5s %-10s %-3s %-*s%b' \
      "${BOLD}${WHITE}" "ID" "TYPE" "STATUS" "" "$name_w" "NAME" "${NC}"
    _box_content "${CYAN}" "${LINE_V}" $W "$head"
    _draw_line_mid $W
  else
    printf '%b%-6s %-5s %-10s %-3s %s%b\n' \
      "${BOLD}${WHITE}" "ID" "TYPE" "STATUS" "" "NAME" "${NC}"
  fi

  local any=0 count_run=0 count_stop=0 count_other=0
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id ty st sym nm <<<"$row"
    [[ -z "$id" ]] && continue
    any=1
    [[ "$st" == "running" ]] && count_run=$((count_run + 1))
    [[ "$st" == "stopped" ]] && count_stop=$((count_stop + 1))
    [[ "$st" != "running" && "$st" != "stopped" ]] && count_other=$((count_other + 1))

    local ty_col
    case "$ty" in
    CT) printf -v ty_col '%b%-5s%b' "${MAGENTA_BRIGHT}" "$ty" "${NC}" ;;
    VM) printf -v ty_col '%b%-5s%b' "${BLUE_BRIGHT}" "$ty" "${NC}" ;;
    *) printf -v ty_col '%-5s' "$ty" ;;
    esac

    local line
    printf -v line '%-6s %s %s %s %s' \
      "$id" "$ty_col" \
      "$(_status_color "$st" "$(printf '%-10s' "$st")")" \
      "$(_pad_right "$(_status_sym_color "$st" "$sym")" 3)" \
      "$(_truncate "$nm" "$name_w")"
    if ((draw_boxes)); then
      _box_content "${CYAN}" "${LINE_V}" $W "  ${line}"
    else
      printf '%s\n' "$line"
    fi
  done

  if ((any == 0)); then
    if ((draw_boxes)); then
      _draw_line_mid $W
    fi
    if [[ -n "$FILTER_STATUS" ]]; then
      if ((draw_boxes)); then
        printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
          "${CYAN}" "${LINE_V}" "${NC}" \
          "${RED_BRIGHT}" $((W - 6)) "No ${FILTER_STATUS} VMs or containers found." "${NC}" \
          "${CYAN}" "${LINE_V}" "${NC}"
      else
        printf '%b%s%b\n' "${RED_BRIGHT}" "No ${FILTER_STATUS} VMs or containers found." "${NC}"
      fi
    else
      if ((draw_boxes)); then
        printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
          "${CYAN}" "${LINE_V}" "${NC}" \
          "${RED_BRIGHT}" $((W - 6)) "No VMs or containers found." "${NC}" \
          "${CYAN}" "${LINE_V}" "${NC}"
        printf '%b%s%b  %b%-*s%b  %b%s%b\n' \
          "${CYAN}" "${LINE_V}" "${NC}" \
          "${DIM}" $((W - 6)) "Run directly on the Proxmox host as root." "${NC}" \
          "${CYAN}" "${LINE_V}" "${NC}"
      else
        printf '%b%s%b\n' "${RED_BRIGHT}" "No VMs or containers found." "${NC}"
        printf '%b%s%b\n' "${DIM}" "Run directly on the Proxmox host as root." "${NC}"
      fi
    fi
    if ((draw_boxes)); then
      _draw_line_bot $W
    fi
    return 1
  fi

  if ((draw_boxes)); then
    _draw_line_mid $W
  fi
  # Legend row
  local legend count
  legend="$(_status_sym_color "running" "$SYM_RUNNING") running   "
  legend+="$(_status_sym_color "stopped" "$SYM_STOPPED") stopped   "
  legend+="$(_status_sym_color "paused" "$SYM_PAUSED") paused"
  # Count row
  printf -v count '%bCount:%b  %b%s running%b  %b%s stopped%b' \
    "${BOLD}" "${NC}" \
    "${GREEN_BRIGHT}" "$count_run" "${NC}" \
    "${RED_BRIGHT}" "$count_stop" "${NC}"
  ((count_other > 0)) && count+="  ${count_other} other"
  if ((draw_boxes)); then
    _box_content "${CYAN}" "${LINE_V}" $W "  ${legend}"
    _box_content "${CYAN}" "${LINE_V}" $W "  ${count}"
    _draw_line_bot $W
  else
    printf '%s\n%s\n' "$legend" "$count"
  fi
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
    printf '  %b[--force]%b Skipping confirmation: %s\n' "$YELLOW_BRIGHT" "$NC" "$prompt"
    return 0
  fi
  local ans
  printf '  %b%s [y/N]:%b ' "$YELLOW" "$prompt" "$NC"
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

  local W=52
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
  printf '%b%s%b  %b7%b) IP info\n' \
    "${CYAN}" "${LINE_V}" "${NC}" \
    "${CYAN_BRIGHT}" "${NC}"
  if [[ "$ty" == "VM" ]]; then
    printf '%b%s%b  %b8%b) SPICE info   %b9%b) Enable SPICE\n' \
      "${CYAN}" "${LINE_V}" "${NC}" \
      "${CYAN_BRIGHT}" "${NC}" \
      "${CYAN_BRIGHT}" "${NC}"
    printf '%b%s%b  %b10%b) Back\n' \
      "${CYAN}" "${LINE_V}" "${NC}" \
      "${DIM}" "${NC}"
  else
    printf '%b%s%b  %b8%b) Back\n' \
      "${CYAN}" "${LINE_V}" "${NC}" \
      "${DIM}" "${NC}"
  fi

  _draw_line_bot $W
  echo
  if [[ "$ty" == "VM" ]]; then
    printf '  %b→%b Selection [1-10]: ' "${CYAN_BRIGHT}" "${NC}"
  else
    printf '  %b→%b Selection [1-8]: ' "${CYAN_BRIGHT}" "${NC}"
  fi
  local opt
  read_line opt
  case "$opt" in
  1) do_action "$id" "$ty" start "$name" ;;
  2) do_action "$id" "$ty" stop "$name" ;;
  3) do_action "$id" "$ty" restart "$name" ;;
  4) do_action "$id" "$ty" status "$name" ;;
  5) open_console "$id" "$ty" "$name" ;;
  6) snapshots_menu "$id" "$ty" "$name" ;;
  7) ip_info "$id" "$ty" "$name" ;;
  8)
    if [[ "$ty" == "VM" ]]; then
      spice_info "$id" "$name"
    fi
    ;;
  9)
    if [[ "$ty" == "VM" ]]; then
      spice_enable "$id"
    fi
    ;;
  10) : ;;
  *)
    if [[ "$ty" == "VM" ]]; then
      validate_menu_choice "$opt" 1 10 "action menu" || true
    else
      validate_menu_choice "$opt" 1 8 "action menu" || true
    fi
    ;;
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
        _log_pve_err "$_pve_out"
      fi
    else
      if _pve_out=$(qm start "$id" 2>&1); then
        ok "$ty $id started successfully."
      else
        err "Failed to start VM $id."
        _log_pve_err "$_pve_out"
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
          _log_pve_err "$_force_out"
        fi
      else
        err "Failed to stop CT $id."
        _log_pve_err "$_timeout_out"
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
          _log_pve_err "$_force_out"
        fi
      else
        err "Failed to stop VM $id."
        _log_pve_err "$_timeout_out"
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
        _log_pve_err "$_pve_out"
      fi
    else
      if _pve_out=$(qm reboot "$id" 2>&1); then
        ok "$ty $id restarted."
      else
        err "Failed to restart VM $id."
        _log_pve_err "$_pve_out"
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
    note "If the terminal opens, use the escape hint shown by Proxmox to exit."
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

# _SELECTED_SNAPSHOT — output variable set by _select_snapshot().
_SELECTED_SNAPSHOT=''

# _select_snapshot ID TYPE — display a numbered list of snapshots; set _SELECTED_SNAPSHOT.
# Falls back to free-text entry when no parseable snapshots are found.
# Returns 1 on invalid numeric selection; caller must validate name with validate_snapshot_name.
_select_snapshot() {
  local id="$1" ty="$2"
  _SELECTED_SNAPSHOT=''
  local out
  if [[ "$ty" == "CT" ]]; then
    out="$(pct listsnapshot "$id" 2>/dev/null || true)"
  else
    out="$(qm listsnapshot "$id" 2>/dev/null || true)"
  fi

  local -a snap_names=()
  local line sn
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Strip tree-drawing prefix (` -> ` etc.) then take first word
    sn="${line//['\`>|-']/}"
    sn="${sn#"${sn%%[![:space:]]*}"}" # ltrim
    sn="${sn%% *}"
    [[ -z "$sn" ]] && continue
    # Skip pseudo-snapshots and header words
    [[ "$sn" == "current" || "$sn" == "Name" || "$sn" == "YOU" ]] && continue
    [[ "$sn" =~ ^[a-zA-Z0-9] ]] || continue
    snap_names+=("$sn")
  done <<<"$out"

  if ((${#snap_names[@]} == 0)); then
    note "No snapshots found. Enter name manually."
    printf '  %bSnapshot name:%b ' "${BOLD}" "${NC}"
    local raw
    read_line raw
    _SELECTED_SNAPSHOT="$(trim "$raw")"
    return 0
  fi

  local i
  for ((i = 0; i < ${#snap_names[@]}; i++)); do
    printf '  %b%d%b) %s\n' "${CYAN_BRIGHT}" "$((i + 1))" "${NC}" "${snap_names[$i]}"
  done
  printf '  %b→%b Select [1-%d]: ' "${CYAN_BRIGHT}" "${NC}" "${#snap_names[@]}"
  local sel
  read_line sel

  if [[ ! "$sel" =~ ^[0-9]+$ ]] || ((10#$sel < 1 || 10#$sel > ${#snap_names[@]})); then
    err "Invalid selection '$sel'. Enter 1–${#snap_names[@]}."
    return 1
  fi
  _SELECTED_SNAPSHOT="${snap_names[$((10#$sel - 1))]}"
}

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
        _log_pve_err "$_snap_out"
        return
      fi
    else
      if ! _snap_out=$(qm snapshot "$id" "$sn" 2>&1); then
        err "Snapshot creation failed."
        _log_pve_err "$_snap_out"
        return
      fi
    fi
    ok "Snapshot '$sn' created."
    ;;

  3)
    printf '  %bSelect snapshot to roll back to:%b\n' "${BOLD}" "${NC}"
    _select_snapshot "$id" "$ty" || return
    local sn="$_SELECTED_SNAPSHOT"
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
        _log_pve_err "$_rb_out"
        return
      fi
    else
      if ! _rb_out=$(qm rollback "$id" "$sn" 2>&1); then
        err "Rollback failed."
        _log_pve_err "$_rb_out"
        return
      fi
    fi
    ok "Rollback to '$sn' completed."
    ;;

  4)
    printf '  %bSelect snapshot to delete:%b\n' "${BOLD}" "${NC}"
    _select_snapshot "$id" "$ty" || return
    local sn="$_SELECTED_SNAPSHOT"
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
        _log_pve_err "$_del_out"
        return
      fi
    else
      if ! _del_out=$(qm delsnapshot "$id" "$sn" 2>&1); then
        err "Snapshot deletion failed."
        _log_pve_err "$_del_out"
        return
      fi
    fi
    ok "Snapshot '$sn' deleted."
    ;;

  5) : ;;
  *) validate_menu_choice "$s" 1 5 "snapshot menu" || true ;;
  esac
}

# =============================================================================
# SPICE
# =============================================================================

_spice_has_gui_session() {
  [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]
}

_spice_endpoint() {
  local id="$1"
  local monitor endpoint host='' port='' cfg_spice cfg_addr id_int

  monitor="$(qm monitor "$id" <<<'info spice' 2>/dev/null || true)"
  endpoint="$(sed -n 's/^[[:space:]]*address:[[:space:]]*\([^[:space:]]*\).*/\1/p' <<<"$monitor" | head -1)"
  if [[ -n "$endpoint" ]]; then
    if [[ "$endpoint" == \[*\]:* ]]; then
      host="${endpoint%%]:*}"
      host="${host#[}"
      port="${endpoint##*:}"
    elif [[ "$endpoint" == *:* ]]; then
      host="${endpoint%:*}"
      port="${endpoint##*:}"
    fi
  fi

  cfg_spice="$(qm config "$id" 2>/dev/null | sed -n 's/^spice: .*port=\([0-9]\+\).*/\1/p' | head -1)"
  cfg_addr="$(qm config "$id" 2>/dev/null | sed -n 's/^spice: .*addr=\([^,]*\).*/\1/p' | head -1)"
  [[ -z "$port" && -n "$cfg_spice" ]] && port="$cfg_spice"
  [[ -z "$host" && -n "$cfg_addr" ]] && host="$cfg_addr"

  [[ -z "$host" ]] && host="${PROXMOX_MANAGER_SPICE_ADDR:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  id_int=$((10#$id))
  [[ -z "$port" ]] && port="$((61000 + id_int))"

  printf '%s\t%s\n' "$host" "$port"
}

spice_info() {
  local id="$1" name="$2"
  local host port endpoint
  endpoint="$(_spice_endpoint "$id")"
  host="${endpoint%%$'\t'*}"
  port="${endpoint##*$'\t'}"

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
  if have virt-viewer && _spice_has_gui_session; then
    virt-viewer "$vv" &
    ok "Launching virt-viewer for VM ${id}..."
  else
    ok "SPICE connection file: ${vv}"
    if have virt-viewer; then
      note "No graphical session detected in this shell. Open the .vv file from a desktop session."
    else
      note "Install virt-viewer with: apt install virt-viewer"
    fi
  fi
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
# NETWORK / IP ADDRESS LOOKUP
# =============================================================================

# _extract_ipv4_rows JSON KIND — print TAB-separated "iface<TAB>ip" rows.
# KIND is either "VM" (QEMU guest agent) or "CT" (ip -j addr show).
_extract_ipv4_rows() {
  local json="$1" kind="$2"
  if ! have python3; then
    return 1
  fi

  python3 - "$kind" "$json" <<'PY'
import ipaddress
import json
import sys

kind = sys.argv[1]
raw = sys.argv[2]

try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)

rows = []

def add(iface, ip):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return
    if addr.version != 4:
        return
    if addr.is_loopback or addr.is_link_local:
        return
    rows.append((iface or 'unknown', str(addr)))

if kind == 'VM':
    interfaces = data
    if isinstance(data, dict):
        interfaces = data.get('result', data)
    if not isinstance(interfaces, list):
        interfaces = []
    for iface in interfaces:
        if not isinstance(iface, dict):
            continue
        name = iface.get('name') or iface.get('hardware-address') or 'unknown'
        ips = iface.get('ip-addresses') or []
        if not isinstance(ips, list):
            continue
        for entry in ips:
            if not isinstance(entry, dict):
                continue
            if entry.get('ip-address-type') != 'ipv4':
                continue
            ip = entry.get('ip-address')
            if isinstance(ip, str):
                add(name, ip)
elif kind == 'CT':
    if not isinstance(data, list):
        data = []
    for iface in data:
        if not isinstance(iface, dict):
            continue
        name = iface.get('ifname') or 'unknown'
        infos = iface.get('addr_info') or []
        if not isinstance(infos, list):
            continue
        for entry in infos:
            if not isinstance(entry, dict):
                continue
            if entry.get('family') != 'inet':
                continue
            ip = entry.get('local')
            if isinstance(ip, str):
                add(name, ip)
else:
    sys.exit(1)

seen = set()
for iface, ip in rows:
    key = (iface, ip)
    if key in seen:
        continue
    seen.add(key)
    print(f"{iface}\t{ip}")
PY
}

# ip_info ID TYPE NAME — show current IPv4 addresses for running guests.
ip_info() {
  local id="$1" ty="$2" name="$3"
  local st raw rows
  st="$(status_of "$id" "$ty")"
  if [[ "$st" != "running" ]]; then
    err "$ty $id ($name) is not running (status: $st)."
    return 1
  fi

  note "Fetching IPv4 address(es) for $ty $id ($name)..."
  case "$ty" in
  CT)
    if ! raw=$(pct exec "$id" -- ip -j addr show 2>&1); then
      err "Could not query IP addresses for CT $id."
      _log_pve_err "$raw"
      return 1
    fi
    ;;
  VM)
    if ! raw=$(qm agent "$id" network-get-interfaces 2>&1); then
      err "Could not query IP addresses for VM $id."
      _log_pve_err "$raw"
      note "Tip: ensure the QEMU Guest Agent is installed and enabled inside the VM."
      return 1
    fi
    ;;
  *)
    err "Unknown guest type '$ty'."
    return 1
    ;;
  esac

  if ! rows="$(_extract_ipv4_rows "$raw" "$ty")"; then
    err "Failed to parse IP address output for $ty $id."
    return 1
  fi

  if [[ -z "$rows" ]]; then
    note "No IPv4 address found for $ty $id ($name)."
    return 1
  fi

  printf '  %bIPv4 address(es) for %s %s (%s):%b\n' "${BOLD}${CYAN_BRIGHT}" "$ty" "$id" "$name" "${NC}"
  while IFS=$'\t' read -r iface ip; do
    [[ -z "$iface" || -z "$ip" ]] && continue
    printf '  %b%s%b: %s\n' "${CYAN_BRIGHT}" "$iface" "${NC}" "$ip"
  done <<<"$rows"
}

# =============================================================================
# ENTRY POINT
# =============================================================================

main() {
  # Load config files — CLI flags set by parse_args below will override these values.
  _load_config_file /etc/pmanrc
  _load_config_file "${HOME}/.pmanrc"
  _prepare_log_file || true
  # Validate settings after parsing config as data.
  if [[ ! "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || ((STOP_TIMEOUT < 1)); then
    err "STOP_TIMEOUT must be a positive integer (got '$STOP_TIMEOUT'). Check /etc/pmanrc or ~/.pmanrc."
    exit 1
  fi
  if [[ -n "$PROXMOX_MANAGER_SPICE_ADDR" && ! "$PROXMOX_MANAGER_SPICE_ADDR" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
    err "PROXMOX_MANAGER_SPICE_ADDR contains unsupported characters."
    exit 1
  fi
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
