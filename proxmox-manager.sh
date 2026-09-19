#!/usr/bin/env bash
# Proxmox VM/CT Management Tool
# Version 2.13.0 — 2026-09-19
# - feat: health view (--health, menu key h) and cron checks (--check) with ntfy/e-mail alerts
# - fix: action and snapshot menus draw a closed frame (right border, padded rows)
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

# Health monitoring (--health / --check). A threshold of 0 disables that level.
HEALTH_CPU_WARN="${HEALTH_CPU_WARN:-85}"
HEALTH_CPU_CRIT="${HEALTH_CPU_CRIT:-95}"
HEALTH_MEM_WARN="${HEALTH_MEM_WARN:-90}"
HEALTH_MEM_CRIT="${HEALTH_MEM_CRIT:-95}"
HEALTH_DISK_WARN="${HEALTH_DISK_WARN:-85}"
HEALTH_DISK_CRIT="${HEALTH_DISK_CRIT:-95}"
HEALTH_CPU_RUNS="${HEALTH_CPU_RUNS:-3}"    # consecutive --check runs before a CPU alert
HEALTH_IGNORE_IDS="${HEALTH_IGNORE_IDS:-}" # VMIDs excluded from health checks (comma/space separated)
HEALTH_STATE_DIR="${HEALTH_STATE_DIR:-/var/lib/pman}"
NTFY_URL="${NTFY_URL:-}"                 # e.g. https://ntfy.sh/my-topic (opt-in)
NTFY_TOKEN_FILE="${NTFY_TOKEN_FILE:-}"   # file with the ntfy access token, mode 0600
HEALTH_MAIL_TO="${HEALTH_MAIL_TO:-}"     # recipient(s), comma separated (opt-in, needs sendmail)
HEALTH_MAIL_FROM="${HEALTH_MAIL_FROM:-}" # optional sender address
HEALTH_FLAG=0
CHECK_FLAG=0
DRY_RUN=0
TEST_NOTIFY_FLAG=0
FATAL_EXIT=1           # exit code for fatal setup errors (3 = UNKNOWN in --check mode)
_CONFIG_INLINE_TOKEN=0 # set when a config file contains an inline NTFY_TOKEN
MSG_TITLE=''           # notification message composed by _compose_message
MSG_BODY=''
MSG_PRIORITY=''
HEALTH_NODE=''          # local node name (set by _health_load)
HEALTH_ERR=''           # reason for the last _health_load/_health_load_tasks failure
HEALTH_ROWS=()          # parsed guest rows (see _health_parse_resources)
declare -A _HV_LEVEL=() # per-guest max health level (see _health_evaluate)
declare -A _HV_FIND=()  # per-guest findings (see _health_evaluate)
HEALTH_TASKS=()         # parsed task rows (see _health_parse_tasks)
HEALTH_STATE_HEADER='# pman-health-state v1'
PVE_ETC_DIR='/etc/pve'                                             # guest configs for the onboot lookup (overridden only by tests)
_CHECK_TMP=''                                                      # temp state file removed by the --check EXIT trap
_CHECK_DONE=0                                                      # set right before --check exits normally
_NOTIFY_TMP=''                                                     # temp body file of _notify_ntfy
declare -A _S_LVL=() _S_SINCE=() _S_STREAK=() _S_RUN=() _S_TASK=() # previous --check state
_S_BASE=0
_S_RUN_TS=0
_S_TASK_TS=0
declare -A _N_LVL=() _N_SINCE=() _N_STREAK=() _N_RUN=() _N_TASK=() # new --check state
_N_RUN_TS=0
_N_TASK_TS=0

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
    STOP_TIMEOUT | LOG_FILE | PROXMOX_MANAGER_SPICE_ADDR | \
      HEALTH_CPU_WARN | HEALTH_CPU_CRIT | HEALTH_MEM_WARN | HEALTH_MEM_CRIT | \
      HEALTH_DISK_WARN | HEALTH_DISK_CRIT | HEALTH_CPU_RUNS | HEALTH_IGNORE_IDS | \
      HEALTH_STATE_DIR | NTFY_URL | NTFY_TOKEN_FILE | HEALTH_MAIL_TO | HEALTH_MAIL_FROM)
      printf -v "$key" '%s' "$value"
      ;;
    NTFY_TOKEN)
      # Secrets never live in the config file itself; see NTFY_TOKEN_FILE.
      _CONFIG_INLINE_TOKEN=1
      _config_warn "Ignoring inline NTFY_TOKEN in $file; store the token in a mode 0600 file and set NTFY_TOKEN_FILE."
      ;;
    *)
      _config_warn "Ignoring unsupported setting '$key' in $file."
      ;;
    esac
  done <"$file"
}

# _owner_mode_ok PATH MASK — true when PATH is owned by the current user and
# none of the octal permission bits in MASK (e.g. 022, 077) are set.
_owner_mode_ok() {
  local path="$1" mask="$2" owner mode
  owner="$(stat -Lc '%u' -- "$path" 2>/dev/null || printf 'invalid')"
  mode="$(stat -Lc '%a' -- "$path" 2>/dev/null || printf 'invalid')"
  if [[ "$owner" != "$EUID" || ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
    return 1
  fi
  if ((8#$mode & 8#$mask)); then
    return 1
  fi
  return 0
}

# _trusted_dir DIR — true when DIR is a directory (no symlink) owned by root or the
# current user and not writable by group or others, so nobody else can swap its entries.
_trusted_dir() {
  local dir="$1" owner mode
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  owner="$(stat -c '%u' -- "$dir" 2>/dev/null || printf 'invalid')"
  mode="$(stat -c '%a' -- "$dir" 2>/dev/null || printf 'invalid')"
  if [[ "$owner" != "0" && "$owner" != "$EUID" ]] || [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
    return 1
  fi
  if ((8#$mode & 8#022)); then
    return 1
  fi
  return 0
}

# _prepare_log_file — require a private regular file in a trusted directory.
_prepare_log_file() {
  [[ -z "$LOG_FILE" ]] && return 0
  if [[ "$LOG_FILE" != /* ]]; then
    _config_warn "LOG_FILE must be an absolute path; logging disabled."
    LOG_FILE=''
    return 1
  fi

  local parent
  parent="$(dirname -- "$LOG_FILE")"
  if [[ ! -d "$parent" ]]; then
    _config_warn "LOG_FILE parent directory does not exist; logging disabled."
    LOG_FILE=''
    return 1
  fi
  if ! _owner_mode_ok "$parent" 022; then
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
    if ! _owner_mode_ok "$LOG_FILE" 077; then
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

# _valid_mail_addr ADDR — conservative e-mail address check (no quoting, no spaces).
_valid_mail_addr() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$ ]]
}

# _validate_health_config [notify] — validate health settings; print errors, return 1 on failure.
# With "notify", the notification channel settings are validated as well.
# Only called in health/check/test-notify modes so bad settings never block the TUI.
_validate_health_config() {
  local scope="${1:-}" rc=0 key val metric w c addr
  local -a addrs=()
  for key in HEALTH_CPU_WARN HEALTH_CPU_CRIT HEALTH_MEM_WARN HEALTH_MEM_CRIT HEALTH_DISK_WARN HEALTH_DISK_CRIT; do
    val="${!key}"
    if [[ ! "$val" =~ ^[0-9]{1,3}$ ]] || ((10#$val > 100)); then
      err "$key must be an integer between 0 and 100 (got '$val')."
      rc=1
    else
      printf -v "$key" '%d' "$((10#$val))"
    fi
  done
  if ((rc == 0)); then
    for metric in CPU MEM DISK; do
      key="HEALTH_${metric}_WARN"
      w="${!key}"
      key="HEALTH_${metric}_CRIT"
      c="${!key}"
      if ((w > 0 && c > 0 && w >= c)); then
        err "HEALTH_${metric}_WARN ($w) must be lower than HEALTH_${metric}_CRIT ($c)."
        rc=1
      fi
    done
  fi
  if [[ ! "$HEALTH_CPU_RUNS" =~ ^[0-9]{1,3}$ ]] || ((10#$HEALTH_CPU_RUNS < 1 || 10#$HEALTH_CPU_RUNS > 100)); then
    err "HEALTH_CPU_RUNS must be an integer between 1 and 100 (got '$HEALTH_CPU_RUNS')."
    rc=1
  else
    HEALTH_CPU_RUNS=$((10#$HEALTH_CPU_RUNS))
  fi
  if [[ ! "$HEALTH_IGNORE_IDS" =~ ^[0-9,\ ]*$ ]]; then
    err "HEALTH_IGNORE_IDS must be a comma or space separated list of VMIDs."
    rc=1
  fi
  if [[ ! "$HEALTH_STATE_DIR" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
    err "HEALTH_STATE_DIR must be an absolute path using only [A-Za-z0-9._/-]."
    rc=1
  fi
  if [[ "$scope" != "notify" ]]; then
    return "$rc"
  fi

  if ((_CONFIG_INLINE_TOKEN == 1)); then
    err "NTFY_TOKEN must not be set in a config file; use NTFY_TOKEN_FILE (mode 0600)."
    rc=1
  fi
  if [[ -n "$NTFY_URL" && ! "$NTFY_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+/?$ ]]; then
    err "NTFY_URL must look like https://host[:port]/topic (got an unsupported value)."
    rc=1
  fi
  if [[ -n "$NTFY_TOKEN_FILE" ]]; then
    if [[ -z "$NTFY_URL" ]]; then
      err "NTFY_TOKEN_FILE is set but NTFY_URL is empty."
      rc=1
    fi
    if [[ "$NTFY_TOKEN_FILE" != /* || -L "$NTFY_TOKEN_FILE" || ! -f "$NTFY_TOKEN_FILE" ]]; then
      err "NTFY_TOKEN_FILE must be an absolute path to a regular file (no symlink)."
      rc=1
    elif ! _owner_mode_ok "$NTFY_TOKEN_FILE" 077; then
      err "NTFY_TOKEN_FILE must be owned by the current user with mode 0600."
      rc=1
    elif ! _trusted_dir "$(dirname -- "$NTFY_TOKEN_FILE")"; then
      err "The directory of NTFY_TOKEN_FILE must be owned by root or the current user and not group/world-writable."
      rc=1
    fi
    if [[ "$NTFY_URL" == http://* ]]; then
      err "NTFY_TOKEN_FILE requires an https:// NTFY_URL; the token is never sent over plain http."
      rc=1
    fi
  fi
  if [[ -n "$HEALTH_MAIL_TO" ]]; then
    IFS=',' read -r -a addrs <<<"$HEALTH_MAIL_TO"
    if ((${#addrs[@]} == 0)); then
      err "HEALTH_MAIL_TO contains no address."
      rc=1
    fi
    for addr in "${addrs[@]}"; do
      if ! _valid_mail_addr "$addr"; then
        err "HEALTH_MAIL_TO contains an invalid address (comma separated, no spaces)."
        rc=1
        break
      fi
    done
  fi
  if [[ -n "$HEALTH_MAIL_FROM" ]] && ! _valid_mail_addr "$HEALTH_MAIL_FROM"; then
    err "HEALTH_MAIL_FROM must be a single plain e-mail address."
    rc=1
  fi
  return "$rc"
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
    exit "$FATAL_EXIT"
  }
}

require_tools() {
  { have qm || have pct; } || {
    err "Neither 'qm' nor 'pct' found. Run on a Proxmox VE host."
    exit "$FATAL_EXIT"
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
  --health          Show CPU/memory/disk health of local VMs/CTs
                    (combine with --list for plain text or --json; --filter/--name apply)
  --check           Run health checks for cron; alert on changes; exit 0/1/2/3
                    (OK/WARN/CRIT/UNKNOWN)
  --dry-run         With --check: print the result and message, send nothing, keep state
  --test-notify     Send a test message through all configured channels
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
        exit "$FATAL_EXIT"
      fi
      FILTER_STATUS="$2"
      case "$FILTER_STATUS" in
      running | stopped | paused) ;;
      *)
        err "Invalid --filter value '$FILTER_STATUS'. Valid: running, stopped, paused."
        exit "$FATAL_EXIT"
        ;;
      esac
      shift # consume the STATUS value; outer shift consumes --filter
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        err "--timeout requires a value in seconds (e.g., --timeout 30)."
        exit "$FATAL_EXIT"
      fi
      STOP_TIMEOUT="$2"
      if [[ ! "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || ((STOP_TIMEOUT < 1)); then
        err "--timeout requires a positive integer (seconds), got '$STOP_TIMEOUT'."
        exit "$FATAL_EXIT"
      fi
      shift # consume the SECS value; outer shift consumes --timeout
      ;;
    --name)
      if [[ $# -lt 2 ]]; then
        err "--name requires an ERE pattern value."
        exit "$FATAL_EXIT"
      fi
      FILTER_NAME="$2"
      # Validate ERE: grep exit code ≥2 means invalid pattern
      local _grep_rc=0
      echo '' | grep -E -- "$FILTER_NAME" >/dev/null 2>&1 || _grep_rc=$?
      if ((_grep_rc >= 2)); then
        err "--name pattern '$FILTER_NAME' is not a valid ERE."
        exit "$FATAL_EXIT"
      fi
      shift
      ;;
    --force)
      FORCE_MODE=1
      ;;
    --health)
      HEALTH_FLAG=1
      ;;
    --check)
      CHECK_FLAG=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --test-notify)
      TEST_NOTIFY_FLAG=1
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
      exit "$FATAL_EXIT"
      ;;
    *)
      err "Unexpected argument: $1"
      usage
      exit "$FATAL_EXIT"
      ;;
    esac
    shift
  done
  if ((LIST_FLAG == 1 && JSON_FLAG == 1)); then
    err "Options --list and --json are not combinable."
    exit "$FATAL_EXIT"
  fi
  _resolve_mode
}

# _resolve_mode — derive MODE from the health flags and reject invalid combinations.
_resolve_mode() {
  if ((DRY_RUN == 1 && CHECK_FLAG == 0)); then
    err "Option --dry-run requires --check."
    exit "$FATAL_EXIT"
  fi
  if ((CHECK_FLAG == 1)); then
    if ((LIST_FLAG == 1 || JSON_FLAG == 1 || HEALTH_FLAG == 1 || TEST_NOTIFY_FLAG == 1)); then
      err "Option --check is not combinable with --list, --json, --health or --test-notify."
      exit "$FATAL_EXIT"
    fi
    if [[ -n "$FILTER_STATUS" || -n "$FILTER_NAME" ]]; then
      err "Option --check always checks all guests; --filter and --name are not supported."
      exit "$FATAL_EXIT"
    fi
    MODE="check"
    return 0
  fi
  if ((TEST_NOTIFY_FLAG == 1)); then
    if ((LIST_FLAG == 1 || JSON_FLAG == 1 || HEALTH_FLAG == 1)); then
      err "Option --test-notify is not combinable with --list, --json or --health."
      exit "$FATAL_EXIT"
    fi
    MODE="test_notify"
    return 0
  fi
  if ((HEALTH_FLAG == 1)); then
    MODE="health"
    ((LIST_FLAG == 1)) && MODE="health_list"
    ((JSON_FLAG == 1)) && MODE="health_json"
  fi
  return 0
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
  # Any other control character becomes \u00XX.
  if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
    local out='' c i
    for ((i = 0; i < ${#s}; i++)); do
      c="${s:i:1}"
      if [[ "$c" == [$'\x01'-$'\x1f'] ]]; then
        printf -v c '\\u%04x' "'$c"
      fi
      out+="$c"
    done
    s="$out"
  fi
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
    return 0
  fi
  # Copy whole UTF-8 characters (lead byte plus continuation bytes) up to max-1 columns.
  local out='' i=0 n=0 len=${#text}
  while ((n < max - 1 && i < len)); do
    out+="${text:i:1}"
    i=$((i + 1))
    while ((i < len)) && [[ "${text:i:1}" == [$'\x80'-$'\xbf'] ]]; do
      out+="${text:i:1}"
      i=$((i + 1))
    done
    n=$((n + 1))
  done
  printf '%s%s' "$out" "$TRUNC_MARK"
}

# _term_cols — terminal width (fallback 80).
_term_cols() {
  local c="${COLUMNS:-}"
  # Callers use $(_term_cols), so stdout is a pipe here; stderr still
  # points at the terminal in interactive use.
  if [[ ! "$c" =~ ^[0-9]+$ ]] && { [[ -t 1 ]] || [[ -t 2 ]]; }; then
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
  _fmt_duration "$secs"
}

# _fmt_duration SECS — compact duration, e.g. "17d 13h 4m"; prints nothing for non-numbers.
_fmt_duration() {
  local secs="$1"
  [[ "$secs" =~ ^[0-9]{1,12}$ ]] || return 0
  secs=$((10#$secs))
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
# HEALTH — DATA LAYER & VIEW
# =============================================================================

# _local_node — print the short name of the local node (validated); return 1 if unknown.
# Uses PVE::INotify::nodename semantics: `uname -n` up to the first dot.
_local_node() {
  local n
  n="$(uname -n 2>/dev/null || true)"
  n="${n%%.*}"
  [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || return 1
  printf '%s' "$n"
}

# _level_name LEVEL — OK / WARN / CRIT for 0 / 1 / 2.
_level_name() {
  case "$1" in
  2) printf 'CRIT' ;;
  1) printf 'WARN' ;;
  0) printf 'OK' ;;
  *) printf 'n/a' ;;
  esac
}

# _level_color LEVEL TEXT — print TEXT in the colour of LEVEL.
_level_color() {
  local lvl="$1" txt="$2"
  case "$lvl" in
  2) printf '%b%s%b' "$RED_BRIGHT" "$txt" "$NC" ;;
  1) printf '%b%s%b' "$YELLOW_BRIGHT" "$txt" "$NC" ;;
  0) printf '%b%s%b' "$GREEN_BRIGHT" "$txt" "$NC" ;;
  *) printf '%b%s%b' "$DIM" "$txt" "$NC" ;;
  esac
}

# _level_for VALUE WARN CRIT — print 0 (OK), 1 (WARN) or 2 (CRIT); "-" when VALUE is n/a.
# A threshold of 0 disables that level.
_level_for() {
  local v="$1" w="$2" c="$3"
  if [[ ! "$v" =~ ^[0-9]{1,6}$ ]]; then
    printf -- '-'
  elif ((c > 0 && 10#$v >= c)); then
    printf '2'
  elif ((w > 0 && 10#$v >= w)); then
    printf '1'
  else
    printf '0'
  fi
}

# _health_ignored ID — true when ID is listed in HEALTH_IGNORE_IDS.
_health_ignored() {
  local id="$1" x
  local -a ids=()
  IFS=' ' read -r -a ids <<<"${HEALTH_IGNORE_IDS//,/ }"
  for x in "${ids[@]}"; do
    if [[ "$x" == "$id" ]]; then
      return 0
    fi
  done
  return 1
}

# _health_fetch resources|tasks [NODE] — raw pvesh JSON on stdout (30 s timeout).
_health_fetch() {
  local kind="$1" node="${2:-}"
  have pvesh || return 1
  case "$kind" in
  resources) timeout 30 pvesh get /cluster/resources --type vm --output-format json 2>/dev/null 9>&- ;;
  tasks) timeout 30 pvesh get "/nodes/${node}/tasks" --source all --limit 200 --output-format json 2>/dev/null 9>&- ;;
  *) return 1 ;;
  esac
}

# _health_parse_resources NODE — read /cluster/resources JSON on stdin and print TSV rows
# for NODE (templates skipped), sorted by VMID:
#   vmid  VM|CT  status  name  cpu%  mem%  disk%  uptime-seconds
# cpu/mem/disk are "-" when not applicable (guest not running, no guest-agent disk data).
_health_parse_resources() {
  python3 -c '
import json, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    data = json.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(1)
if isinstance(data, dict):
    data = data.get("data", [])
if not isinstance(data, list):
    sys.exit(1)
node = sys.argv[1]

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0

rows = []
for r in data:
    if not isinstance(r, dict) or str(r.get("node", "")) != node:
        continue
    if num(r.get("template")) == 1:
        continue
    kind = {"qemu": "VM", "lxc": "CT"}.get(r.get("type"))
    if kind is None:
        continue
    try:
        vmid = int(r.get("vmid"))
    except (TypeError, ValueError):
        continue
    if not 1 <= vmid <= 999999:
        continue
    status = "".join(c for c in str(r.get("status") or "").lower() if c.isalnum() or c in "-_")[:16]
    status = status or "unknown"
    name = "".join(c if c.isprintable() else "?" for c in str(r.get("name") or ""))[:64].strip()
    name = name or "%s-%d" % (kind, vmid)
    running = status == "running"
    cpu = mem = disk = "-"
    if running:
        cpu = str(round(num(r.get("cpu")) * 100))
        maxmem = num(r.get("maxmem"))
        if maxmem > 0:
            mem = str(round(num(r.get("mem")) * 100 / maxmem))
        used, maxdisk = num(r.get("disk")), num(r.get("maxdisk"))
        if used > 0 and maxdisk > 0:
            disk = str(round(used * 100 / maxdisk))
    uptime = int(num(r.get("uptime"))) if running else 0
    rows.append((vmid, kind, status, name, cpu, mem, disk, str(uptime)))
rows.sort()
for row in rows:
    print("\t".join(str(x) for x in row))
' "$1" 9>&-
}

# _health_parse_tasks — read /nodes/<node>/tasks JSON on stdin and print TSV rows sorted
# by end time:  endtime  upid  type  id  status
# Running tasks have endtime 0 and status "running"; missing ids are "-".
_health_parse_tasks() {
  python3 -c '
import json, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    data = json.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(1)
if isinstance(data, dict):
    data = data.get("data", [])
if not isinstance(data, list):
    sys.exit(1)
safe = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

def keep(value, extra, limit):
    return "".join(c if c in safe or c in extra else "_" for c in str(value or ""))[:limit]

rows = []
for t in data:
    if not isinstance(t, dict):
        continue
    upid = keep(t.get("upid"), ":@._!=-", 200)
    if not upid:
        continue
    try:
        end = int(t.get("endtime") or 0)
    except (TypeError, ValueError):
        end = 0
    status = "".join(c if c.isprintable() else "?" for c in str(t.get("status") or ""))[:120].strip()
    if end <= 0:
        end, status = 0, "running"
    status = status or "unknown"
    rows.append((end, upid, keep(t.get("type"), "-_", 32) or "-", keep(t.get("id"), "._-", 64) or "-", status))
rows.sort()
for row in rows:
    print("\t".join(str(x) for x in row))
' 9>&-
}

# _health_load — fetch and parse the local guests into HEALTH_ROWS (sets HEALTH_NODE).
# On failure returns 1 with a reason in HEALTH_ERR; prints nothing.
_health_load() {
  local raw parsed
  HEALTH_ROWS=()
  HEALTH_ERR=''
  if ! have python3; then
    HEALTH_ERR="python3 is required for health checks."
    return 1
  fi
  if ! have pvesh; then
    HEALTH_ERR="'pvesh' not found. Run on a Proxmox VE host."
    return 1
  fi
  if ! HEALTH_NODE="$(_local_node)"; then
    HEALTH_ERR="Could not determine the local node name."
    return 1
  fi
  if ! raw="$(_health_fetch resources)"; then
    HEALTH_ERR="pvesh get /cluster/resources failed or timed out."
    return 1
  fi
  if ! parsed="$(printf '%s' "$raw" | _health_parse_resources "$HEALTH_NODE")"; then
    HEALTH_ERR="Could not parse the pvesh /cluster/resources output."
    return 1
  fi
  if [[ -n "$parsed" ]]; then
    mapfile -t HEALTH_ROWS <<<"$parsed"
  fi
  return 0
}

# _health_load_tasks — fetch and parse recent node tasks into HEALTH_TASKS.
# Requires HEALTH_NODE (set by _health_load). Returns 1 with HEALTH_ERR on failure.
_health_load_tasks() {
  local raw parsed
  HEALTH_TASKS=()
  HEALTH_ERR=''
  if ! raw="$(_health_fetch tasks "$HEALTH_NODE")"; then
    HEALTH_ERR="pvesh get /nodes/${HEALTH_NODE}/tasks failed or timed out."
    return 1
  fi
  if ! parsed="$(printf '%s' "$raw" | _health_parse_tasks)"; then
    HEALTH_ERR="Could not parse the pvesh task list."
    return 1
  fi
  if [[ -n "$parsed" ]]; then
    mapfile -t HEALTH_TASKS <<<"$parsed"
  fi
  return 0
}

# _guest_onboot ID TYPE — true when the guest config has "onboot: 1".
# Reads the current config section of PVE_ETC_DIR/{qemu-server,lxc}/ID.conf (snapshot
# sections start at the first "[" line); falls back to qm/pct config when unreadable.
_guest_onboot() {
  local id="$1" ty="$2" cfg='' conf
  case "$ty" in
  CT) conf="${PVE_ETC_DIR}/lxc/${id}.conf" ;;
  VM) conf="${PVE_ETC_DIR}/qemu-server/${id}.conf" ;;
  *) return 1 ;;
  esac
  if [[ "$id" =~ ^[0-9]+$ && -f "$conf" && -r "$conf" ]]; then
    if awk '/^\[/ { exit } /^onboot:[[:space:]]*1[[:space:]]*$/ { found = 1 } END { exit !found }' "$conf"; then
      return 0
    fi
    return 1
  fi
  case "$ty" in
  CT) cfg="$(timeout 10 pct config "$id" 2>/dev/null 9>&- || true)" ;;
  VM) cfg="$(timeout 10 qm config "$id" 2>/dev/null 9>&- || true)" ;;
  esac
  grep -qE '^onboot:[[:space:]]*1[[:space:]]*$' <<<"$cfg"
}

# _health_checks — single source of truth for --health and --check.
# For every non-ignored guest in HEALTH_ROWS print one TSV row per check:
#   vmid  type  check(cpu|mem|disk|down)  level(0|1|2|-)  value  name
# "down" is CRIT when the guest is stopped although onboot=1; --check adds
# the "stopped unexpectedly" state on top.
_health_checks() {
  local row id ty st nm cpu mem disk up lvl
  for row in "${HEALTH_ROWS[@]}"; do
    IFS=$'\t' read -r id ty st nm cpu mem disk up <<<"$row"
    [[ -z "$id" ]] && continue
    if _health_ignored "$id"; then
      continue
    fi
    printf '%s\t%s\tcpu\t%s\t%s\t%s\n' "$id" "$ty" \
      "$(_level_for "$cpu" "$HEALTH_CPU_WARN" "$HEALTH_CPU_CRIT")" "$cpu" "$nm"
    printf '%s\t%s\tmem\t%s\t%s\t%s\n' "$id" "$ty" \
      "$(_level_for "$mem" "$HEALTH_MEM_WARN" "$HEALTH_MEM_CRIT")" "$mem" "$nm"
    printf '%s\t%s\tdisk\t%s\t%s\t%s\n' "$id" "$ty" \
      "$(_level_for "$disk" "$HEALTH_DISK_WARN" "$HEALTH_DISK_CRIT")" "$disk" "$nm"
    lvl=0
    if [[ "$st" == "stopped" ]] && _guest_onboot "$id" "$ty"; then
      lvl=2
    fi
    printf '%s\t%s\tdown\t%s\t%s\t%s\n' "$id" "$ty" "$lvl" "$st" "$nm"
  done
}

# _health_finding CHECK LEVEL VALUE — human-readable description of a non-OK check.
_health_finding() {
  local check="$1" lvl="$2" val="$3" label warn crit thr
  case "$check" in
  cpu)
    label="CPU"
    warn="$HEALTH_CPU_WARN"
    crit="$HEALTH_CPU_CRIT"
    ;;
  mem)
    label="memory"
    warn="$HEALTH_MEM_WARN"
    crit="$HEALTH_MEM_CRIT"
    ;;
  disk)
    label="disk"
    warn="$HEALTH_DISK_WARN"
    crit="$HEALTH_DISK_CRIT"
    ;;
  down)
    if [[ "$lvl" == "2" ]]; then
      printf 'stopped although onboot=1'
    elif [[ "$val" == "onboot-task" ]]; then
      printf 'stopped by a Proxmox task although onboot=1'
    else
      printf 'stopped unexpectedly'
    fi
    return 0
    ;;
  *)
    printf '%s' "$check"
    return 0
    ;;
  esac
  thr="$warn"
  [[ "$lvl" == "2" ]] && thr="$crit"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s %s%% (>= %s%%)' "$label" "$val" "$thr"
  else
    printf '%s above %s%% (no current value)' "$label" "$thr"
  fi
}

# _pct_text VALUE — "12%" or "n/a".
_pct_text() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    printf '%s%%' "$1"
  else
    printf 'n/a'
  fi
}

# _json_num VALUE — VALUE when it is an integer, otherwise null.
_json_num() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}

# _health_evaluate — run _health_checks for HEALTH_ROWS and fill the caller-visible
# globals _HV_LEVEL[id] (max level) and _HV_FIND[id] (TAB-joined "level|check|value" items).
_health_evaluate() {
  local checks cid chk clvl cval
  _HV_LEVEL=()
  _HV_FIND=()
  checks="$(_health_checks)"
  while IFS=$'\t' read -r cid _ chk clvl cval _; do
    [[ -z "$cid" ]] && continue
    [[ -z "${_HV_LEVEL[$cid]:-}" ]] && _HV_LEVEL[$cid]=0
    [[ "$clvl" =~ ^[0-2]$ ]] || continue
    if ((clvl > _HV_LEVEL[$cid])); then
      _HV_LEVEL[$cid]=$clvl
    fi
    if ((clvl > 0)); then
      _HV_FIND[$cid]+="${clvl}|${chk}|${cval}"$'\t'
    fi
  done <<<"$checks"
  return 0
}

# _health_row_shown STATUS NAME — apply --filter/--name to a health row.
_health_row_shown() {
  local st="$1" nm="$2"
  if [[ -n "$FILTER_STATUS" && "$st" != "$FILTER_STATUS" ]]; then
    return 1
  fi
  if [[ -n "$FILTER_NAME" && ! "$nm" =~ $FILTER_NAME ]]; then
    return 1
  fi
  return 0
}

# _health_finding_line WIDTH ENTRY — render one findings entry ("lvl TAB type id TAB name
# TAB text") within WIDTH columns: the guest name is shortened, the finding text never.
_health_finding_line() {
  local width="$1" entry="$2" f_lvl f_guest f_name f_text tag avail
  IFS=$'\t' read -r f_lvl f_guest f_name f_text <<<"$entry"
  tag="[$(_level_name "$f_lvl")]"
  avail=$((width - ${#tag} - 1 - ${#f_guest} - 4 - $(_vis_width "$f_text")))
  if ((width <= 0 || avail >= $(_vis_width "$f_name"))); then
    printf '%s %s (%s): %s' "$(_level_color "$f_lvl" "$tag")" "$f_guest" "$f_name" "$f_text"
  elif ((avail >= 4)); then
    printf '%s %s (%s): %s' "$(_level_color "$f_lvl" "$tag")" "$f_guest" "$(_truncate "$f_name" "$avail")" "$f_text"
  else
    printf '%s %s: %s' "$(_level_color "$f_lvl" "$tag")" "$f_guest" "$f_text"
  fi
}

# print_health_table — health overview of local guests (boxed for --health and the
# interactive menu, plain for --health --list). Narrow terminals drop UPTIME, DISK% and
# TYPE (in that order) before the NAME column shrinks. Returns 1 only on errors.
print_health_table() {
  local draw_boxes=0
  [[ "$MODE" == "health" || "$MODE" == "interactive" ]] && draw_boxes=1
  if ! _health_load; then
    err "$HEALTH_ERR"
    return 1
  fi
  _health_evaluate

  local -a rows=() findings=()
  local row id ty st nm cpu mem disk up
  for row in "${HEALTH_ROWS[@]}"; do
    IFS=$'\t' read -r id ty st nm cpu mem disk up <<<"$row"
    if _health_row_shown "$st" "$nm"; then
      rows+=("$row")
    fi
  done

  # 2 borders + 4 margin + ID 7 + TYPE 6 + STATUS 9 + CPU% 6 + MEM% 6 + DISK% 6
  #   + UPTIME 12 + HEALTH 8 + NAME
  local name_w=15 fixed=65 show_type=1 show_disk=1 show_up=1 cols
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id ty st nm cpu mem disk up <<<"$row"
    (($(_vis_width "$nm") > name_w)) && name_w=$(_vis_width "$nm")
  done
  if ((draw_boxes)); then
    cols="$(_term_cols)"
    if ((fixed + 10 > cols)); then
      show_up=0
      fixed=$((fixed - 12))
    fi
    if ((fixed + 10 > cols)); then
      show_disk=0
      fixed=$((fixed - 6))
    fi
    if ((fixed + 10 > cols)); then
      show_type=0
      fixed=$((fixed - 6))
    fi
    local max_name=$((cols - fixed))
    ((name_w > max_name)) && name_w=$max_name
    ((name_w < 6)) && name_w=6
  fi
  local W=$((fixed + name_w))

  local head
  printf -v head '%-6s ' "ID"
  ((show_type)) && head+="$(printf '%-5s ' "TYPE")"
  head+="$(printf '%-8s %5s %5s ' "STATUS" "CPU%" "MEM%")"
  ((show_disk)) && head+="$(printf '%5s ' "DISK%")"
  ((show_up)) && head+="$(printf '%-11s ' "UPTIME")"
  head+="$(printf '%-7s %s' "HEALTH" "NAME")"
  if ((draw_boxes)); then
    _draw_line_top $W
    _box_content "${CYAN}" "${LINE_V}" $W "  ${BOLD}${WHITE}${head}${NC}"
    _draw_line_mid $W
  else
    printf '%b%s%b\n' "${BOLD}${WHITE}" "$head" "${NC}"
  fi

  if ((${#rows[@]} == 0)); then
    local msg="No guests found on node ${HEALTH_NODE}."
    [[ -n "$FILTER_STATUS" || -n "$FILTER_NAME" ]] && msg="No guests match the filter."
    if ((draw_boxes)); then
      _box_content "${CYAN}" "${LINE_V}" $W "  ${DIM}$(_truncate "$msg" $((W - 6)))${NC}"
      _draw_line_bot $W
    else
      printf '%s\n' "$msg"
    fi
    return 0
  fi

  local n_ok=0 n_warn=0 n_crit=0 n_ign=0 n_run=0 lvl hname ty_col line upt item f_lvl f_chk f_val
  local -a items=()
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id ty st nm cpu mem disk up <<<"$row"
    [[ "$st" == "running" ]] && n_run=$((n_run + 1))
    if _health_ignored "$id"; then
      lvl='-'
      hname="IGN"
      n_ign=$((n_ign + 1))
    else
      lvl="${_HV_LEVEL[$id]:-0}"
      hname="$(_level_name "$lvl")"
      case "$lvl" in
      2) n_crit=$((n_crit + 1)) ;;
      1) n_warn=$((n_warn + 1)) ;;
      *) n_ok=$((n_ok + 1)) ;;
      esac
      IFS=$'\t' read -r -a items <<<"${_HV_FIND[$id]:-}"
      for item in "${items[@]}"; do
        IFS='|' read -r f_lvl f_chk f_val <<<"$item"
        findings+=("${f_lvl}"$'\t'"${ty} ${id}"$'\t'"${nm}"$'\t'"$(_health_finding "$f_chk" "$f_lvl" "$f_val")")
      done
    fi
    case "$ty" in
    CT) printf -v ty_col '%b%-5s%b ' "${MAGENTA_BRIGHT}" "$ty" "${NC}" ;;
    VM) printf -v ty_col '%b%-5s%b ' "${BLUE_BRIGHT}" "$ty" "${NC}" ;;
    *) printf -v ty_col '%-5s ' "$ty" ;;
    esac
    ((show_type)) || ty_col=''
    upt='-'
    [[ "$st" == "running" ]] && upt="$(_fmt_duration "$up")"
    printf -v line '%-6s %s%s %5s %5s ' "$id" "$ty_col" \
      "$(_status_color "$st" "$(printf '%-8s' "$st")")" "$cpu" "$mem"
    ((show_disk)) && line+="$(printf '%5s ' "$disk")"
    ((show_up)) && line+="$(printf '%-11s ' "$(_truncate "$upt" 11)")"
    line+="$(_level_color "$lvl" "$(printf '%-7s' "$hname")") $(_truncate "$nm" "$name_w")"
    if ((draw_boxes)); then
      _box_content "${CYAN}" "${LINE_V}" $W "  ${line}"
    else
      printf '%s\n' "$line"
    fi
  done

  local totals f
  printf -v totals '%bTotal:%b %s guests, %s running  %b%s OK%b  %b%s WARN%b  %b%s CRIT%b' \
    "${BOLD}" "${NC}" "${#rows[@]}" "$n_run" \
    "${GREEN_BRIGHT}" "$n_ok" "${NC}" "${YELLOW_BRIGHT}" "$n_warn" "${NC}" \
    "${RED_BRIGHT}" "$n_crit" "${NC}"
  ((n_ign > 0)) && totals+="  ${n_ign} ignored"
  if ((draw_boxes && $(_vis_width "$totals") > W - 6)); then
    printf -v totals '%s guests  %b%s OK%b %b%s WARN%b %b%s CRIT%b' "${#rows[@]}" \
      "${GREEN_BRIGHT}" "$n_ok" "${NC}" "${YELLOW_BRIGHT}" "$n_warn" "${NC}" \
      "${RED_BRIGHT}" "$n_crit" "${NC}"
  fi
  if ((draw_boxes)); then
    _draw_line_mid $W
    if ((${#findings[@]} > 0)); then
      _box_content "${CYAN}" "${LINE_V}" $W "  ${BOLD}Findings:${NC}"
      for f in "${findings[@]}"; do
        _box_content "${CYAN}" "${LINE_V}" $W "  $(_health_finding_line $((W - 6)) "$f")"
      done
      _draw_line_mid $W
    fi
    _box_content "${CYAN}" "${LINE_V}" $W "  ${totals}"
    _draw_line_bot $W
  else
    if ((${#findings[@]} > 0)); then
      printf '\nFindings:\n'
      for f in "${findings[@]}"; do
        printf '%s\n' "$(_health_finding_line 0 "$f")"
      done
    fi
    printf '\n%s\n' "$totals"
  fi
  return 0
}

# print_health_json — health data of local guests as JSON (diagnostics on stderr only).
print_health_json() {
  if ! _health_load; then
    err "$HEALTH_ERR"
    return 1
  fi
  _health_evaluate
  local row id ty st nm cpu mem disk up lvl hname ign first=1 ffirst item f_lvl f_chk f_val fval
  local n=0 n_ok=0 n_warn=0 n_crit=0 n_ign=0
  local -a items=()
  printf '{"node":"%s","guests":[' "$(json_escape "$HEALTH_NODE")"
  for row in "${HEALTH_ROWS[@]}"; do
    IFS=$'\t' read -r id ty st nm cpu mem disk up <<<"$row"
    _health_row_shown "$st" "$nm" || continue
    n=$((n + 1))
    ign=false
    if _health_ignored "$id"; then
      ign=true
      hname="IGNORED"
      n_ign=$((n_ign + 1))
    else
      lvl="${_HV_LEVEL[$id]:-0}"
      hname="$(_level_name "$lvl")"
      case "$lvl" in
      2) n_crit=$((n_crit + 1)) ;;
      1) n_warn=$((n_warn + 1)) ;;
      *) n_ok=$((n_ok + 1)) ;;
      esac
    fi
    ((first)) || printf ','
    first=0
    printf '{"id":%s,"type":"%s","status":"%s","name":"%s","cpu":%s,"mem":%s,"disk":%s,"uptime":%s,"health":"%s","ignored":%s,"findings":[' \
      "$id" "$(json_escape "$ty")" "$(json_escape "$st")" "$(json_escape "$nm")" \
      "$(_json_num "$cpu")" "$(_json_num "$mem")" "$(_json_num "$disk")" \
      "$([[ "$st" == "running" ]] && _json_num "$up" || printf 'null')" \
      "$hname" "$ign"
    ffirst=1
    if [[ "$ign" == "false" ]]; then
      IFS=$'\t' read -r -a items <<<"${_HV_FIND[$id]:-}"
      for item in "${items[@]}"; do
        IFS='|' read -r f_lvl f_chk f_val <<<"$item"
        ((ffirst)) || printf ','
        ffirst=0
        fval="$(_json_num "$f_val")"
        [[ "$fval" == "null" ]] && fval="\"$(json_escape "$f_val")\""
        printf '{"check":"%s","level":"%s","value":%s,"text":"%s"}' \
          "$f_chk" "$(_level_name "$f_lvl")" "$fval" \
          "$(json_escape "$(_health_finding "$f_chk" "$f_lvl" "$f_val")")"
      done
    fi
    printf ']}'
  done
  printf '],"summary":{"guests":%s,"ok":%s,"warn":%s,"crit":%s,"ignored":%s}}\n' \
    "$n" "$n_ok" "$n_warn" "$n_crit" "$n_ign"
  return 0
}

# _health_status_line ID — one-line health summary for the status action.
# Fails silently (return 1) when pvesh/python3 are missing or the guest is unknown.
_health_status_line() {
  local want="$1" row id ty st nm cpu mem disk up found='' lvl tag upt
  _validate_health_config >/dev/null 2>&1 || return 1
  _health_load 2>/dev/null || return 1
  for row in "${HEALTH_ROWS[@]}"; do
    IFS=$'\t' read -r id ty st nm cpu mem disk up <<<"$row"
    if [[ "$id" == "$want" ]]; then
      found="$row"
      break
    fi
  done
  [[ -n "$found" ]] || return 1
  if _health_ignored "$want"; then
    lvl='-'
    tag="IGNORED"
  else
    HEALTH_ROWS=("$found")
    _health_evaluate
    lvl="${_HV_LEVEL[$want]:-0}"
    tag="$(_level_name "$lvl")"
  fi
  upt='-'
  [[ "$st" == "running" ]] && upt="$(_fmt_duration "$up")"
  printf '  Health: CPU %s  MEM %s  DISK %s  up %s  [%s]\n' \
    "$(_pct_text "$cpu")" "$(_pct_text "$mem")" "$(_pct_text "$disk")" "$upt" \
    "$(_level_color "$lvl" "$tag")"
  return 0
}

# health_overview — interactive health view (main menu key "h").
health_overview() {
  echo
  if _validate_health_config; then
    print_health_table || true
  fi
  printf '\n  %bPress Enter to continue...%b ' "${DIM}" "${NC}"
  local _dummy
  read_line _dummy
}

# =============================================================================
# HEALTH — CHECK ENGINE (--check)
# =============================================================================

# _check_unknown MESSAGE — report an UNKNOWN result (Nagios style) and exit 3.
_check_unknown() {
  err "$*"
  printf 'PMAN UNKNOWN - %s\n' "$*"
  exit 3
}

# _check_on_exit — EXIT trap of --check: remove the temp file and map any
# unexpected exit (e.g. a set -e abort) to 3 instead of a misleading OK/WARN.
_check_on_exit() {
  local rc=$?
  if [[ -n "$_CHECK_TMP" ]]; then
    rm -f -- "$_CHECK_TMP"
    _CHECK_TMP=''
  fi
  if [[ -n "$_NOTIFY_TMP" ]]; then
    rm -f -- "$_NOTIFY_TMP"
    _NOTIFY_TMP=''
  fi
  if ((_CHECK_DONE == 0 && rc != 3)); then
    exit 3
  fi
}

# _check_state_dir DIR — create DIR (0700) if needed; require a private, owned directory.
_check_state_dir() {
  local dir="$1" parent
  if [[ -L "$dir" ]]; then
    err "HEALTH_STATE_DIR must not be a symlink."
    return 1
  fi
  parent="$(dirname -- "$dir")"
  if [[ -d "$parent" ]] && ! _trusted_dir "$parent"; then
    err "The parent of HEALTH_STATE_DIR (${parent}) must be owned by root or the current user and not group/world-writable."
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    if ! (umask 077 && mkdir -p -- "$dir") 2>/dev/null; then
      err "Could not create HEALTH_STATE_DIR ${dir}."
      return 1
    fi
  fi
  if ! _owner_mode_ok "$dir" 077; then
    err "HEALTH_STATE_DIR ${dir} must be owned by the current user with mode 0700."
    return 1
  fi
  return 0
}

# _state_load FILE — read the versioned TSV state into the _S_* globals.
# The file is parsed as data (never sourced); malformed lines are skipped and an
# unknown header resets to a fresh baseline. Returns 1 when FILE exists but is unsafe
# or unreadable.
#   W  run-epoch  task-watermark   T  upid   R  vmid   C  check:vmid  level  since  streak
_state_load() {
  local file="$1" line first=1 bad=0
  local re_w=$'^W\t([0-9]{1,12})\t([0-9]{1,12})$'
  local re_t=$'^T\t([A-Za-z0-9:@._!=-]{1,200})$'
  local re_r=$'^R\t([0-9]{1,6})$'
  local re_c=$'^C\t((cpu|mem|disk|down):[0-9]{1,6})\t([0-2])\t([0-9]{1,12})\t([0-9]{1,4})$'
  _S_LVL=()
  _S_SINCE=()
  _S_STREAK=()
  _S_RUN=()
  _S_TASK=()
  _S_BASE=0
  _S_RUN_TS=0
  _S_TASK_TS=0
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    return 0
  fi
  if [[ -L "$file" || ! -f "$file" || ! -r "$file" ]]; then
    err "State file ${file} must be a readable regular file (no symlink)."
    return 1
  fi
  if ! _owner_mode_ok "$file" 077; then
    err "State file ${file} must be owned by the current user with mode 0600."
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((first == 1)); then
      first=0
      if [[ "$line" != "$HEALTH_STATE_HEADER" ]]; then
        _config_warn "Unknown state file format in ${file}; starting a new baseline."
        return 0
      fi
      continue
    fi
    if [[ "$line" =~ $re_c ]]; then
      _S_LVL["${BASH_REMATCH[1]}"]="${BASH_REMATCH[3]}"
      _S_SINCE["${BASH_REMATCH[1]}"]=$((10#${BASH_REMATCH[4]}))
      _S_STREAK["${BASH_REMATCH[1]}"]=$((10#${BASH_REMATCH[5]}))
    elif [[ "$line" =~ $re_r ]]; then
      _S_RUN["${BASH_REMATCH[1]}"]=1
    elif [[ "$line" =~ $re_t ]]; then
      _S_TASK["${BASH_REMATCH[1]}"]=1
    elif [[ "$line" =~ $re_w ]]; then
      _S_RUN_TS=$((10#${BASH_REMATCH[1]}))
      _S_TASK_TS=$((10#${BASH_REMATCH[2]}))
      _S_BASE=1
    else
      bad=$((bad + 1))
    fi
  done <"$file"
  if ((bad > 0)); then
    _config_warn "Ignored ${bad} malformed line(s) in ${file}."
  fi
  return 0
}

# _state_save DIR FILE — write the _N_* globals atomically (mktemp + mv, mode 0600).
_state_save() {
  local dir="$1" file="$2" k
  _CHECK_TMP="$(umask 077 && mktemp -p "$dir" health.state.XXXXXX)" || return 1
  {
    printf '%s\n' "$HEALTH_STATE_HEADER"
    printf 'W\t%s\t%s\n' "$_N_RUN_TS" "$_N_TASK_TS"
    for k in "${!_N_TASK[@]}"; do
      printf 'T\t%s\n' "$k"
    done
    for k in "${!_N_RUN[@]}"; do
      printf 'R\t%s\n' "$k"
    done
    for k in "${!_N_LVL[@]}"; do
      printf 'C\t%s\t%s\t%s\t%s\n' "$k" "${_N_LVL[$k]}" "${_N_SINCE[$k]:-0}" "${_N_STREAK[$k]:-0}"
    done
  } >"$_CHECK_TMP" || return 1
  chmod 600 -- "$_CHECK_TMP" || return 1
  mv -f -- "$_CHECK_TMP" "$file" || return 1
  _CHECK_TMP=''
  return 0
}

# _check_process_tasks — scan HEALTH_TASKS (uses run_check's "events" and "excused").
# Advances the task watermark (_N_TASK_TS/_N_TASK) and appends failed tasks that finished
# since the last run to "events" (level TAB text); the first run is a baseline.
# A guest is "excused" (stopped on purpose) when its most recent lifecycle task is a
# running or successful stop/shutdown/suspend/destroy/migrate/backup, or a running
# reboot. No time window: /cluster/resources may lag behind the task list.
_check_process_tasks() {
  local row t_end t_upid t_type t_id t_status is_new lvl k
  local -A lc_type=() lc_status=() lc_end=()
  _N_TASK_TS=$_S_TASK_TS
  _N_TASK=()
  for k in "${!_S_TASK[@]}"; do
    _N_TASK["$k"]=1
  done
  for row in "${HEALTH_TASKS[@]}"; do
    IFS=$'\t' read -r t_end t_upid t_type t_id t_status <<<"$row"
    [[ "$t_end" =~ ^[0-9]{1,12}$ && -n "$t_upid" ]] || continue
    t_end=$((10#$t_end))
    case "$t_type" in
    qmstart | vzstart | qmresume | vzresume | qmreboot | vzreboot | qmstop | qmshutdown | \
      vzstop | vzshutdown | qmsuspend | vzsuspend | qmdestroy | vzdestroy | qmigrate | \
      vzmigrate | vzdump)
      if [[ "$t_id" == "-" ]]; then
        # A running multi-guest backup job (no single id) may stop any guest.
        if [[ "$t_type" == "vzdump" ]] && ((t_end == 0)); then
          excused[all]=1
        fi
      elif [[ -z "${lc_end[$t_id]:-}" ]] || ((lc_end[$t_id] != 0)); then
        # Rows are sorted by end time with running tasks (0) first; a running task
        # stays the most recent one, otherwise later rows replace earlier ones.
        lc_type["$t_id"]="$t_type"
        lc_status["$t_id"]="$t_status"
        lc_end["$t_id"]=$t_end
      fi
      ;;
    esac
    if ((t_end == 0)); then
      continue # still running
    fi
    is_new=0
    if ((t_end > _S_TASK_TS)) || { ((t_end == _S_TASK_TS)) && [[ -z "${_S_TASK[$t_upid]:-}" ]]; }; then
      is_new=1
    fi
    if ((t_end > _N_TASK_TS)); then
      _N_TASK_TS=$t_end
      _N_TASK=()
    fi
    if ((t_end == _N_TASK_TS)); then
      _N_TASK["$t_upid"]=1
    fi
    if ((is_new == 1 && _S_BASE == 1)) && [[ "$t_status" != "OK" ]] && ! _health_ignored "$t_id"; then
      lvl=2
      [[ "$t_status" == WARNINGS* ]] && lvl=1
      k="task ${t_type}"
      [[ "$t_id" != "-" ]] && k+=" ${t_id}"
      if ((lvl == 2)); then
        events+=("${lvl}"$'\t'"${k} failed: ${t_status}")
      else
        events+=("${lvl}"$'\t'"${k} finished with ${t_status}")
      fi
    fi
  done
  for k in "${!lc_type[@]}"; do
    case "${lc_type[$k]}" in
    qmstop | qmshutdown | vzstop | vzshutdown | qmsuspend | vzsuspend | qmdestroy | vzdestroy | \
      qmigrate | vzmigrate | vzdump)
      if ((lc_end[$k] == 0)) || [[ "${lc_status[$k]}" == "OK" || "${lc_status[$k]}" == WARNINGS* ]]; then
        excused["$k"]=1
      fi
      ;;
    qmreboot | vzreboot)
      if ((lc_end[$k] == 0)); then
        excused["$k"]=1
      fi
      ;;
    esac
  done
  return 0
}

# _check_process_states NOW — derive the new check state (_N_LVL/_N_SINCE/_N_STREAK/_N_RUN)
# from _health_checks and the previous state. Uses run_check's "excused" and fills its
# "seen", "vals" and "labels" arrays.
#   cpu: alerts after HEALTH_CPU_RUNS consecutive runs; mem/disk: immediately;
#   metrics of a stopped guest resolve (CPU counter restarts); a metric that is n/a on a
#   running guest keeps its previous state silently (marked in run_check's "stale");
#   down: stopped with onboot=1 is CRIT (WARN when stopped by a task), and a guest that
#   was running last time and stopped without a task is WARN, latched in the streak
#   field until it runs again or a stop task explains it.
_check_process_states() {
  local now="$1" checks row cid chk clvl cval key prev pstreak psince lvl streak
  local id ty st nm cpu mem disk up
  local -A gst=()
  _N_LVL=()
  _N_SINCE=()
  _N_STREAK=()
  _N_RUN=()
  for row in "${HEALTH_ROWS[@]}"; do
    IFS=$'\t' read -r id ty st nm cpu mem disk up <<<"$row"
    [[ -z "$id" ]] && continue
    labels["$id"]="${ty} ${id} (${nm})"
    gst["$id"]="$st"
    if [[ "$st" == "running" ]] && ! _health_ignored "$id"; then
      _N_RUN["$id"]=1
    fi
  done
  checks="$(_health_checks)"
  while IFS=$'\t' read -r cid _ chk clvl cval _; do
    [[ -z "$cid" ]] && continue
    key="${chk}:${cid}"
    seen["$key"]=1
    vals["$key"]="$cval"
    prev="${_S_LVL[$key]:-0}"
    pstreak="${_S_STREAK[$key]:-0}"
    psince="${_S_SINCE[$key]:-0}"
    if [[ "$clvl" == "-" ]]; then
      if [[ "${gst[$cid]:-}" != "running" ]]; then
        # Guest not running: its metric alerts resolve and the CPU counter restarts.
        vals["$key"]="guest-stopped"
        continue
      fi
      # Running, but the metric is n/a (e.g. VM disk without guest agent): keep the
      # previous state without reporting or counting it.
      if [[ -n "${_S_LVL[$key]:-}" ]]; then
        _N_LVL["$key"]=$prev
        _N_SINCE["$key"]=$psince
        _N_STREAK["$key"]=$pstreak
        stale["$key"]=1
      fi
      continue
    fi
    lvl=$clvl
    streak=0
    case "$chk" in
    cpu)
      if ((clvl > 0)); then
        streak=$((pstreak + 1))
        if ((streak > 999)); then
          streak=999
        fi
        if ((streak < HEALTH_CPU_RUNS && prev == 0)); then
          lvl=0
        fi
      fi
      ;;
    down)
      # The streak field latches "stopped unexpectedly" until the guest runs again.
      if [[ "$cval" == "stopped" ]]; then
        if [[ -n "${excused[$cid]:-}${excused[all]:-}" ]]; then
          # Stopped on purpose: no "unexpected" latch; onboot=1 is only a WARN then.
          if ((lvl == 2)); then
            lvl=1
            vals["$key"]="onboot-task"
          fi
        elif ((pstreak > 0)); then
          streak=1
        elif ((_S_BASE == 1)) && [[ -n "${_S_RUN[$cid]:-}" ]]; then
          streak=1
        fi
        if ((streak == 1 && lvl < 1)); then
          lvl=1
        fi
      fi
      ;;
    esac
    if ((lvl > 0 || streak > 0)); then
      _N_LVL["$key"]=$lvl
      _N_STREAK["$key"]=$streak
      _N_SINCE["$key"]=0
      if ((lvl > 0 && prev > 0 && psince > 0)); then
        _N_SINCE["$key"]=$psince
      elif ((lvl > 0)); then
        _N_SINCE["$key"]=$now
      fi
    fi
  done <<<"$checks"
  return 0
}

# _resolved_text CHECK VALUE — description of a check that returned to OK.
_resolved_text() {
  local chk="$1" val="$2"
  if [[ "$val" == "guest-stopped" ]]; then
    printf '%s alert cleared (guest stopped)' "$chk"
    return 0
  fi
  case "$chk" in
  cpu) printf 'CPU back to normal (%s)' "$(_pct_text "$val")" ;;
  mem) printf 'memory back to normal (%s)' "$(_pct_text "$val")" ;;
  disk) printf 'disk back to normal (%s)' "$(_pct_text "$val")" ;;
  down)
    if [[ "$val" == "running" ]]; then
      printf 'running again'
    else
      printf 'down alert cleared (status %s)' "${val:-unknown}"
    fi
    ;;
  *) printf '%s OK' "$chk" ;;
  esac
}

# _compose_message NODE LEVEL N_NEW N_IMPROVED N_RESOLVED TOTALS LINE... — build one
# combined notification in MSG_TITLE (ASCII), MSG_BODY (<= ~3500 bytes) and MSG_PRIORITY.
_compose_message() {
  local node="$1" lvl="$2" n_new="$3" n_imp="$4" n_res="$5" totals="$6"
  shift 6
  local word parts='' line body='' dropped=0 max=3500
  if ((lvl > 0)); then
    word="$(_level_name "$lvl")"
  elif ((n_res > 0 && n_imp == 0)); then
    word="RESOLVED"
  else
    word="IMPROVED"
  fi
  if ((n_new > 0)); then
    parts+="${n_new} new, "
  fi
  if ((n_imp > 0)); then
    parts+="${n_imp} improved, "
  fi
  if ((n_res > 0)); then
    parts+="${n_res} resolved, "
  fi
  parts="${parts%, }"
  MSG_TITLE="pman ${node}: ${word}"
  if [[ -n "$parts" ]]; then
    MSG_TITLE+=" (${parts})"
  fi
  case "$lvl" in
  2) MSG_PRIORITY="urgent" ;;
  1) MSG_PRIORITY="high" ;;
  *) MSG_PRIORITY="low" ;;
  esac
  for line in "$@"; do
    if ((${#body} + ${#line} + 1 > max)); then
      dropped=$((dropped + 1))
      continue
    fi
    body+="${line}"$'\n'
  done
  if ((dropped > 0)); then
    body+="... ${dropped} more line(s) omitted"$'\n'
  fi
  MSG_BODY="${body}"$'\n'"${totals}"
  return 0
}

# _check_keep_unsent — after a total delivery failure keep run_check's "trans_keys" at
# their previous level (counters and latches advance) and keep the old task watermark,
# so exactly these alerts fire again on the next run.
_check_keep_unsent() {
  local key
  for key in "${trans_keys[@]}"; do
    if [[ -n "${_S_LVL[$key]:-}" ]]; then
      _N_STREAK["$key"]="${_N_STREAK[$key]:-${_S_STREAK[$key]:-0}}"
      _N_LVL["$key"]="${_S_LVL[$key]}"
      _N_SINCE["$key"]="${_S_SINCE[$key]:-0}"
    elif ((${_N_STREAK[$key]:-0} > 0)); then
      _N_LVL["$key"]=0
      _N_SINCE["$key"]=0
    else
      unset "_N_LVL[$key]" "_N_SINCE[$key]" "_N_STREAK[$key]"
    fi
  done
  if ((${#events[@]} > 0)); then
    _N_TASK_TS=$_S_TASK_TS
    _N_TASK=()
    for key in "${!_S_TASK[@]}"; do
      _N_TASK["$key"]=1
    done
  fi
  return 0
}

# run_check — --check: evaluate all local guests and recent tasks, alert on changes.
# Exit code: 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN (config, lock, state or pvesh failure).
run_check() {
  local dir="${HEALTH_STATE_DIR%/}" file now old_umask
  local -A excused=() seen=() vals=() labels=() stale=()
  local -a events=() keys=() cur_lines=() new_lines=() imp_lines=() res_lines=() ev_lines=()
  local -a trans_keys=()
  [[ -z "$dir" ]] && dir="/"
  file="${dir%/}/health.state"
  trap 'exit 3' INT TERM
  trap '_check_on_exit' EXIT
  now="$(date +%s)"

  if ((DRY_RUN == 0)); then
    _check_state_dir "$dir" || _check_unknown "State directory ${dir} is not usable."
    have flock || _check_unknown "'flock' not found (util-linux)."
    old_umask="$(umask)"
    umask 077
    # The lock lives on fd 9; child processes get "9>&-" so e.g. a forking MTA
    # cannot keep holding it after this run has finished.
    if ! { exec 9>>"${dir%/}/check.lock"; } 2>/dev/null; then
      _check_unknown "Could not open the lock file in ${dir}."
    fi
    umask "$old_umask"
    flock -n 9 || _check_unknown "Another --check run is still active (lock held)."
  fi
  if ! _state_load "$file"; then
    ((DRY_RUN == 1)) || _check_unknown "Could not read the state file ${file}."
  fi
  _health_load || _check_unknown "$HEALTH_ERR"
  _health_load_tasks || _check_unknown "$HEALTH_ERR"

  _check_process_tasks
  _check_process_states "$now"

  local key chk id prev new label since dur text ev ev_lvl rc=0 lvl_new=0
  local n_new=0 n_imp=0 n_res=0 n_warn=0 n_crit=0 n_guests=0
  for key in "${HEALTH_ROWS[@]}"; do
    if ! _health_ignored "${key%%$'\t'*}"; then
      n_guests=$((n_guests + 1))
    fi
  done
  mapfile -t keys < <(printf '%s\n' "${!seen[@]}" "${!_S_LVL[@]}" | awk 'NF' | sort -t: -k2,2n -k1,1 -u)
  for key in "${keys[@]}"; do
    chk="${key%%:*}"
    id="${key#*:}"
    prev="${_S_LVL[$key]:-0}"
    new="${_N_LVL[$key]:-0}"
    label="${labels[$id]:-guest ${id}}"
    if [[ -n "${stale[$key]:-}" ]]; then
      continue # n/a on a running guest: state kept, not reported
    fi
    if [[ -z "${seen[$key]:-}" ]]; then
      # Guest vanished or is ignored now: resolve (silently when ignored).
      if _health_ignored "$id"; then
        continue
      fi
      new=0
      vals["$key"]="gone"
    fi
    text="${label}: $(_health_finding "$chk" "$new" "${vals[$key]:-}")"
    if ((new > 0)); then
      cur_lines+=("[$(_level_name "$new")] ${text}")
      if ((new == 2)); then
        n_crit=$((n_crit + 1))
      else
        n_warn=$((n_warn + 1))
      fi
      if ((new > rc)); then
        rc=$new
      fi
    fi
    if ((new != prev)); then
      trans_keys+=("$key")
    fi
    if ((new > prev)); then
      new_lines+=("[$(_level_name "$new")] ${text}")
      n_new=$((n_new + 1))
      if ((new > lvl_new)); then
        lvl_new=$new
      fi
    elif ((new > 0 && new < prev)); then
      imp_lines+=("[$(_level_name "$new")] ${text} (improved from $(_level_name "$prev"))")
      n_imp=$((n_imp + 1))
    elif ((new == 0 && prev > 0)); then
      since="${_S_SINCE[$key]:-0}"
      dur=''
      if ((since > 0 && now >= since)); then
        dur=" after $(_fmt_duration $((now - since)))"
      fi
      if [[ "${vals[$key]:-}" == "gone" ]]; then
        res_lines+=("[RESOLVED] ${label}: no longer present${dur}")
      else
        res_lines+=("[RESOLVED] ${label}: $(_resolved_text "$chk" "${vals[$key]:-}")${dur}")
      fi
      n_res=$((n_res + 1))
    fi
  done
  for ev in "${events[@]}"; do
    ev_lvl="${ev%%$'\t'*}"
    ev_lines+=("[$(_level_name "$ev_lvl")] ${ev#*$'\t'}")
    if ((ev_lvl > rc)); then
      rc=$ev_lvl
    fi
    if ((ev_lvl > lvl_new)); then
      lvl_new=$ev_lvl
    fi
  done

  local state_word summary changes
  case "$rc" in
  2) state_word="CRITICAL" ;;
  1) state_word="WARNING" ;;
  *) state_word="OK" ;;
  esac
  printf -v summary '%s critical, %s warning, %s task event(s); %s guests on %s' \
    "$n_crit" "$n_warn" "${#events[@]}" "$n_guests" "$HEALTH_NODE"
  printf 'PMAN %s - %s\n' "$state_word" "$summary"
  for text in "${cur_lines[@]}" "${ev_lines[@]}" "${res_lines[@]}"; do
    printf '%s\n' "$text"
  done
  log "INFO" "health check: ${state_word} - ${summary}"

  changes=$((n_new + n_imp + n_res + ${#events[@]}))
  if ((changes > 0)); then
    _compose_message "$HEALTH_NODE" "$lvl_new" $((n_new + ${#events[@]})) "$n_imp" "$n_res" \
      "Now: ${summary}" "${new_lines[@]}" "${ev_lines[@]}" "${imp_lines[@]}" "${res_lines[@]}"
  fi

  if ((DRY_RUN == 1)); then
    printf '\n--- notification (dry-run: nothing sent, state unchanged) ---\n'
    if ((changes > 0)); then
      printf 'Title: %s\nPriority: %s\n\n%s\n' "$MSG_TITLE" "$MSG_PRIORITY" "$MSG_BODY"
    else
      printf 'No changes since the last run; no notification.\n'
    fi
    _CHECK_DONE=1
    exit "$rc"
  fi

  if ((changes > 0)); then
    log "INFO" "health alert: ${MSG_TITLE}"
    if ! _notify_all; then
      err "All notification channels failed; the changes stay pending for the next run."
      _check_keep_unsent
    fi
  fi
  _N_RUN_TS=$now
  _state_save "$dir" "$file" || _check_unknown "Could not write the state file ${file}."
  _CHECK_DONE=1
  exit "$rc"
}

# =============================================================================
# HEALTH — NOTIFICATIONS
# =============================================================================

# _notify_channels_configured — true when at least one notification channel is set.
_notify_channels_configured() {
  [[ -n "$NTFY_URL" || -n "$HEALTH_MAIL_TO" ]]
}

# _notify_title — MSG_TITLE reduced to one line of printable ASCII (header-safe).
_notify_title() {
  local t="${MSG_TITLE//[$'\r\n\t']/ }"
  t="${t//[^ -~]/?}"
  printf '%s' "${t:0:200}"
}

# _notify_warn MESSAGE — channel failure: warning on stderr (keeps --check stdout clean) and log.
_notify_warn() {
  warn "$*" >&2
}

# _read_ntfy_token — print the token from NTFY_TOKEN_FILE. The file is opened once and
# the open descriptor itself is checked (regular file, owner, mode 0600), so swapping the
# path between validation and use cannot leak another file; its directory must be trusted.
_read_ntfy_token() {
  local fd info line=''
  if [[ -L "$NTFY_TOKEN_FILE" ]] || ! _trusted_dir "$(dirname -- "$NTFY_TOKEN_FILE")"; then
    return 1
  fi
  if ! { exec {fd}<"$NTFY_TOKEN_FILE"; } 2>/dev/null; then
    return 1
  fi
  info="$(stat -L -c '%F|%u|%a' -- "/proc/self/fd/${fd}" 2>/dev/null || true)"
  if [[ "$info" =~ ^regular(\ empty)?\ file\|([0-9]+)\|([0-7]{3,4})$ ]] &&
    [[ "${BASH_REMATCH[2]}" == "$EUID" ]] && ((!(8#${BASH_REMATCH[3]} & 8#077))); then
    IFS= read -r line <&"$fd" || true
  else
    line=''
  fi
  exec {fd}<&-
  [[ "$line" =~ ^[A-Za-z0-9_.-]{1,256}$ ]] || return 1
  printf '%s' "$line"
}

# _notify_ntfy — send the message to NTFY_URL. URL, headers and the optional token are
# passed to curl via its stdin config, never in argv; the body comes from a private temp
# file. Only the host is logged, never the topic path or the token.
_notify_ntfy() {
  local host token='' tag title cfg rc=0 out proto
  host="${NTFY_URL#*://}"
  host="${host%%/*}"
  if ! have curl; then
    _notify_warn "ntfy: 'curl' not found."
    return 1
  fi
  if [[ -n "$NTFY_TOKEN_FILE" ]]; then
    if [[ "$NTFY_URL" != https://* ]]; then
      _notify_warn "ntfy: refusing to send the access token over plain http to ${host}; use https."
      return 1
    fi
    if ! token="$(_read_ntfy_token)"; then
      _notify_warn "ntfy: NTFY_TOKEN_FILE is unsafe, unreadable or has an invalid token."
      return 1
    fi
  fi
  case "$MSG_PRIORITY" in
  urgent) tag="rotating_light" ;;
  high) tag="warning" ;;
  *) tag="white_check_mark" ;;
  esac
  title="$(_notify_title)"
  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  _NOTIFY_TMP="$(umask 077 && mktemp -p "${TMPDIR:-/tmp}" pman-ntfy.XXXXXX)" || {
    _notify_warn "ntfy: could not create a temporary file."
    return 1
  }
  printf '%s\n' "$MSG_BODY" >"$_NOTIFY_TMP"
  cfg="url = \"${NTFY_URL}\""$'\n'
  cfg+="header = \"Title: ${title}\""$'\n'
  cfg+="header = \"Priority: ${MSG_PRIORITY:-default}\""$'\n'
  cfg+="header = \"Tags: ${tag}\""$'\n'
  if [[ -n "$token" ]]; then
    cfg+="header = \"Authorization: Bearer ${token}\""$'\n'
  fi
  # -q first: ignore ~/.curlrc. No --retry: a retried POST can duplicate a push, and
  # unsent changes are resent by the next --check run anyway.
  proto='=http,https'
  [[ -n "$token" ]] && proto='=https'
  out="$(curl -q -fsS --max-time 10 --proto "$proto" -o /dev/null \
    --data-binary "@${_NOTIFY_TMP}" --config - <<<"$cfg" 2>&1 9>&-)" || rc=$?
  rm -f -- "$_NOTIFY_TMP"
  _NOTIFY_TMP=''
  if ((rc != 0)); then
    # curl's message may contain the topic URL; keep it out of the terminal and the log.
    _notify_warn "ntfy: delivery to ${host} failed (curl exit ${rc})."
    return 1
  fi
  log "INFO" "ntfy: sent to ${host}"
  return 0
}

# _notify_mail — send the message to HEALTH_MAIL_TO via the local sendmail (postfix etc.).
# Header values are validated single-line strings, so no header injection is possible.
_notify_mail() {
  local sm addr to='' subject rc=0
  local -a addrs=()
  sm="$(command -v sendmail 2>/dev/null || true)"
  if [[ -z "$sm" && -x /usr/sbin/sendmail ]]; then
    sm="/usr/sbin/sendmail"
  fi
  if [[ -z "$sm" ]]; then
    _notify_warn "mail: 'sendmail' not found (install postfix or another MTA)."
    return 1
  fi
  IFS=',' read -r -a addrs <<<"$HEALTH_MAIL_TO"
  for addr in "${addrs[@]}"; do
    if ! _valid_mail_addr "$addr"; then
      _notify_warn "mail: invalid recipient address in HEALTH_MAIL_TO."
      return 1
    fi
    to+="${to:+, }${addr}"
  done
  if [[ -z "$to" ]] || { [[ -n "$HEALTH_MAIL_FROM" ]] && ! _valid_mail_addr "$HEALTH_MAIL_FROM"; }; then
    _notify_warn "mail: invalid HEALTH_MAIL_TO/HEALTH_MAIL_FROM."
    return 1
  fi
  subject="$(_notify_title)"
  {
    printf 'To: %s\n' "$to"
    if [[ -n "$HEALTH_MAIL_FROM" ]]; then
      printf 'From: %s\n' "$HEALTH_MAIL_FROM"
    fi
    printf 'Subject: %s\n' "$subject"
    printf 'Date: %s\n' "$(date -R)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n'
    printf 'Auto-Submitted: auto-generated\n'
    printf '\n%s\n' "$MSG_BODY"
  } | timeout 30 "$sm" -t -oi >/dev/null 2>&1 9>&- || rc=$?
  if ((rc != 0)); then
    _notify_warn "mail: sendmail failed (exit ${rc})."
    return 1
  fi
  log "INFO" "mail: sent to ${#addrs[@]} recipient(s)"
  return 0
}

# _notify_all — deliver MSG_TITLE/MSG_BODY/MSG_PRIORITY through every configured channel.
# Returns 0 when no channel is configured or at least one succeeded, 1 when all failed.
_notify_all() {
  local configured=0 delivered=0
  if [[ -n "$NTFY_URL" ]]; then
    configured=$((configured + 1))
    if _notify_ntfy; then
      delivered=$((delivered + 1))
    fi
  fi
  if [[ -n "$HEALTH_MAIL_TO" ]]; then
    configured=$((configured + 1))
    if _notify_mail; then
      delivered=$((delivered + 1))
    fi
  fi
  if ((configured > 0 && delivered == 0)); then
    log "WARN" "Notification failed on all ${configured} channel(s): ${MSG_TITLE}"
    return 1
  fi
  return 0
}

# _notify_cleanup — EXIT trap of --test-notify: remove a pending ntfy body file.
_notify_cleanup() {
  if [[ -n "$_NOTIFY_TMP" ]]; then
    rm -f -- "$_NOTIFY_TMP"
    _NOTIFY_TMP=''
  fi
}

# run_test_notify — send a test message through all configured channels.
run_test_notify() {
  if ! _notify_channels_configured; then
    err "No notification channel configured (set NTFY_URL and/or HEALTH_MAIL_TO)."
    exit 1
  fi
  local node
  trap '_notify_cleanup' EXIT
  trap 'exit 1' INT TERM
  node="$(_local_node || printf 'unknown')"
  MSG_TITLE="pman ${node}: test notification"
  MSG_BODY="Test message from proxmox-manager on ${node}. Alerts from --check will arrive here."
  MSG_PRIORITY="low"
  if _notify_all; then
    ok "Test notification sent (at least one channel succeeded)."
    exit 0
  fi
  err "Test notification failed on all channels."
  exit 1
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
    "<VMID> = open action menu   ${BOLD}h${NC} = health   ${BOLD}r${NC} = refresh   ${BOLD}q${NC} = quit"
  printf '  %b→%b ' "${CYAN_BRIGHT}" "${NC}"
  local choice
  read_line choice
  case "$choice" in
  q | Q) exit 0 ;;
  r | R | '') return 0 ;;
  h | H) health_overview ;;
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
      err "Invalid input: '$choice'. Enter a numeric VMID, 'h', 'r', or 'q'."
    fi
    ;;
  esac
}

action_menu() {
  local id="$1" ty="$2" name="$3"
  local st
  st="$(status_of "$id" "$ty")"

  local W=53
  echo
  _draw_line_top $W

  # Title row
  local ty_col
  case "$ty" in
  CT) printf -v ty_col '%b%s%b' "${MAGENTA_BRIGHT}${BOLD}" "$ty" "${NC}" ;;
  VM) printf -v ty_col '%b%s%b' "${BLUE_BRIGHT}${BOLD}" "$ty" "${NC}" ;;
  *) ty_col="${BOLD}${ty}${NC}" ;;
  esac
  # "  TY ID  (" + name + ")" + right margin must fit into W - 2
  local name_max=$((W - 2 - 2 - ${#ty} - 1 - ${#id} - 3 - 1 - 2))
  _box_content "${CYAN}" "${LINE_V}" $W \
    "  ${ty_col} ${BOLD}${id}${NC}  ${DIM}($(_truncate "$name" "$name_max"))${NC}"

  # Status row — use _sym_for_status to avoid indirect expansion under set -u
  local st_sym
  st_sym="$(_sym_for_status "$st")"
  _box_content "${CYAN}" "${LINE_V}" $W \
    "  Status: $(_status_sym_color "$st" "$st_sym") $(_status_color "$st" "$st")"

  _draw_line_mid $W

  # Actions
  local row
  printf -v row '  %b1%b) Start        %b2%b) Stop         %b3%b) Restart' \
    "${GREEN_BRIGHT}" "${NC}" "${RED_BRIGHT}" "${NC}" "${YELLOW_BRIGHT}" "${NC}"
  _box_content "${CYAN}" "${LINE_V}" $W "$row"
  printf -v row '  %b4%b) Status       %b5%b) Console      %b6%b) Snapshots' \
    "${CYAN_BRIGHT}" "${NC}" "${CYAN_BRIGHT}" "${NC}" "${CYAN_BRIGHT}" "${NC}"
  _box_content "${CYAN}" "${LINE_V}" $W "$row"
  if [[ "$ty" == "VM" ]]; then
    printf -v row '  %b7%b) IP info      %b8%b) SPICE info   %b9%b) Enable SPICE' \
      "${CYAN_BRIGHT}" "${NC}" "${CYAN_BRIGHT}" "${NC}" "${CYAN_BRIGHT}" "${NC}"
    _box_content "${CYAN}" "${LINE_V}" $W "$row"
    printf -v row '  %b10%b) Back' "${DIM}" "${NC}"
  else
    printf -v row '  %b7%b) IP info      %b8%b) Back' \
      "${CYAN_BRIGHT}" "${NC}" "${DIM}" "${NC}"
  fi
  _box_content "${CYAN}" "${LINE_V}" $W "$row"

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
    _health_status_line "$id" 2>/dev/null || true
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
  local W=53
  echo
  _draw_line_top $W
  # "  Snapshot menu — TY ID (" + name + ")" + right margin must fit into W - 2
  local name_max=$((W - 2 - 18 - ${#ty} - 1 - ${#id} - 2 - 1 - 2))
  _box_content "${CYAN}" "${LINE_V}" $W \
    "  ${BOLD}${CYAN_BRIGHT}Snapshot menu${NC} — ${ty} ${id} ($(_truncate "$name" "$name_max"))"
  _draw_line_mid $W
  _box_content "${CYAN}" "${LINE_V}" $W "  ${CYAN_BRIGHT}1${NC}) List snapshots"
  _box_content "${CYAN}" "${LINE_V}" $W "  ${GREEN_BRIGHT}2${NC}) Create snapshot"
  _box_content "${CYAN}" "${LINE_V}" $W "  ${YELLOW_BRIGHT}3${NC}) Rollback to snapshot"
  _box_content "${CYAN}" "${LINE_V}" $W "  ${RED_BRIGHT}4${NC}) Delete snapshot"
  _box_content "${CYAN}" "${LINE_V}" $W "  ${DIM}5${NC}) Back"
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
  local arg
  # --check reports UNKNOWN (3) for every setup problem, including signals and usage
  # errors that happen before run_check installs its own traps.
  for arg in "$@"; do
    if [[ "$arg" == "--check" ]]; then
      FATAL_EXIT=3
      trap 'exit 3' INT TERM
    fi
  done
  # Load config files — CLI flags set by parse_args below will override these values.
  _load_config_file /etc/pmanrc
  _load_config_file "${HOME}/.pmanrc"
  _prepare_log_file || true
  parse_args "$@"
  [[ "$MODE" == "check" ]] && FATAL_EXIT=3
  # Validate settings after parsing config as data.
  if [[ ! "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || ((STOP_TIMEOUT < 1)); then
    err "STOP_TIMEOUT must be a positive integer (got '$STOP_TIMEOUT'). Check /etc/pmanrc or ~/.pmanrc."
    exit "$FATAL_EXIT"
  fi
  if [[ -n "$PROXMOX_MANAGER_SPICE_ADDR" && ! "$PROXMOX_MANAGER_SPICE_ADDR" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
    err "PROXMOX_MANAGER_SPICE_ADDR contains unsupported characters."
    exit "$FATAL_EXIT"
  fi
  if ((FORCE_MODE == 1)); then
    case "$MODE" in
    json | health_json | check) warn "--force active: all confirmation prompts will be skipped automatically." >&2 ;;
    *) warn "--force active: all confirmation prompts will be skipped automatically." ;;
    esac
  fi
  require_root
  require_tools
  if [[ ! -t 1 ]]; then
    CLEAR_SCREEN=0
  fi
  log "INFO" "Starting proxmox-manager (mode=$MODE)"
  case "$MODE" in
  health | health_list | health_json | test_notify)
    local scope=''
    [[ "$MODE" == "test_notify" ]] && scope="notify"
    _validate_health_config "$scope" || exit 1
    ;;
  check)
    _validate_health_config notify || _check_unknown "Invalid health configuration."
    ;;
  esac
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
  health | health_list)
    if print_health_table; then
      exit 0
    else
      exit 1
    fi
    ;;
  health_json)
    if print_health_json; then
      exit 0
    else
      exit 1
    fi
    ;;
  check)
    run_check
    ;;
  test_notify)
    run_test_notify
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
