#!/usr/bin/env bash
# Proxmox VM/CT Management Tool
# Version 2.7.2 — 2025-09-07
# - Fix: Header-Zeilen sicher ignorieren (nur numerische IDs)
# - CT-Namen: $NF + Fallback pct config hostname
# - Root-Prüfung, LC_ALL=C, kein sudo

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

# ===== Defaults =====
CLEAR_SCREEN=1
MODE="interactive"
RUN_ONCE=0
LIST_FLAG=0
JSON_FLAG=0

# ===== Colors (nur TTY) =====
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'
  RED=$'\e[31m'
  GREEN=$'\e[32m'
  BLUE=$'\e[34m'
  CYAN=$'\e[36m'
  NC=$'\e[0m'
else
  BOLD=''
  RED=''
  GREEN=''
  BLUE=''
  CYAN=''
  NC=''
fi

trap 'printf "\n%s\n" "Exiting."; exit 0' INT TERM

have() { command -v "$1" >/dev/null 2>&1; }
err() { printf '%b\n' "${RED}Error:${NC} $*" >&2; }
ok() { printf '%b\n' "${GREEN}$*${NC}"; }
note() { printf '%b\n' "${CYAN}$*${NC}"; }

# ===== Helpers =====
read_line() {
  local -n __o=$1
  if ! IFS= read -r __o; then __o=''; fi
}
trim() {
  local v="$*"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

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
require_tools() { { have qm || have pct; } || {
  err "qm/pct missing. Run on a Proxmox host."
  exit 1
}; }

usage() {
  cat <<'EOF'
Usage: proxmox-manager.sh [options]

Options:
  --list       Print a plain-text overview of all VMs/CTs (no TUI)
  --json       Print machine-readable JSON with VM/CT information
  --no-clear   Do not clear the screen in interactive mode
  --once       Run a single interactive refresh (useful for TTY recording)
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
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        err "Unbekannte Option: $1"
        usage
        exit 1
        ;;
      *)
        err "Unerwartetes Argument: $1"
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

# ===== JSON helpers =====
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Nur Zeilen mit führender numerischer ID zulassen
is_data_line() {
  # erlaubt führende Spaces, dann Ziffern, dann Space/Tab
  [[ "$1" =~ ^[[:space:]]*[0-9]+[[:space:]]+ ]]
}

# ===== Typ/Status =====
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

status_of() {
  local id="$1" t="${2:-}"
  [[ -z "$t" ]] && t="$(type_of_id "$id")"
  case "$t" in
    CT) pct status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
    VM) qm status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
    *) printf 'unknown' ;;
  esac
}

# ===== Namen =====
ct_name_from_config() { pct config "$1" 2>/dev/null | awk -F': *' '/^hostname:/ {print $2; exit}'; }
vm_name_from_config() { qm config "$1" 2>/dev/null | awk -F': *' '/^name:/     {print $2; exit}'; }

# ===== Sammlung: ID<TAB>TYPE<TAB>STATUS<TAB>SYMBOL<TAB>NAME =====
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
      sym="🟡"
      [[ "$status" == "running" ]] && sym="🟢"
      [[ "$status" == "stopped" ]] && sym="🔴"
      [[ "$status" == "paused" ]] && sym="🟠"
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
      sym="🟡"
      [[ "$status" == "running" ]] && sym="🟢"
      [[ "$status" == "stopped" ]] && sym="🔴"
      [[ "$status" == "paused" ]] && sym="🟠"
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
      "$sep" "$id_json" "$(json_escape "$ty")" "$(json_escape "$st")" "$(json_escape "$sym")" "$(json_escape "$nm")"
  done
  printf ']\n'
}

# ===== UI =====
header() {
  if ((CLEAR_SCREEN == 1)) && [[ -t 1 ]]; then
    clear
  fi
  printf '%b\n' "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  printf '%b\n' "${BOLD}${BLUE} Proxmox VM/CT Management Tool ${NC}"
  printf '%b\n' "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  echo
}

print_table() {
  printf "%-6s %-6s %-10s %-6s %-30s\n" "ID" "Type" "Status" "Symb." "Name"
  printf '%s\n' "─────────────────────────────────────────────────────────────"
  local any=0
  while IFS=$'\t' read -r id ty st sym nm; do
    [[ -z "$id" ]] && continue
    any=1
    printf "%-6s %-6s %-10s %-6s %-30s\n" "$id" "$ty" "$st" "$sym" "$nm"
  done < <(collect_instances | sort -n -t$'\t' -k1,1)
  if ((any == 0)); then
    printf '%b\n' "${RED}Keine VMs oder Container gefunden.${NC}"
    printf '%s\n' "Run directly on the Proxmox host as root."
    return 1
  fi
  printf '%s\n' "─────────────────────────────────────────────────────────────"
  printf '%s\n' "Legende: 🟢 running · 🔴 stopped · 🟠 paused · 🟡 unknown"
  return 0
}

main_menu() {
  header
  if ! print_table; then return 1; fi
  echo "Input: enter VMID to open menu | 'r' refresh | 'q' quit"
  printf '%s' "Selection: "
  local choice
  read_line choice
  case "$choice" in
    q | Q) exit 0 ;;
    r | R | '') return 0 ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
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
          err "VMID $choice not found."
        fi
      else
        err "Invalid input."
      fi
      ;;
  esac
}

action_menu() {
  local id="$1" ty="$2" name="$3"
  local st
  st="$(status_of "$id" "$ty")"
  echo
  note "Actions for $ty $id ($name) — Status: $st"
  echo "1) Start   2) Stop    3) Restart   4) Status"
  echo "5) Console 6) Snapshots"
  if [[ "$ty" == "VM" ]]; then
    echo "7) SPICE info  8) Enable SPICE"
  fi
  echo "9) Back"
  printf '%s' "Selection [1-9]: "
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
        err "Nur für VMs."
      fi
      ;;
    8)
      if [[ "$ty" == "VM" ]]; then
        spice_enable "$id"
      else
        err "Nur für VMs."
      fi
      ;;
    9) : ;;
    *) err "Invalid." ;;
  esac
  printf '%s' "Press Enter to continue… "
  local _
  read_line _
}

do_action() {
  local id="$1" ty="$2" act="$3" name="$4"
  local st
  st="$(status_of "$id" "$ty")"
  case "$act" in
    start)
      [[ "$st" == "running" ]] && {
        ok "$ty $id läuft bereits."
        return
      }
      if [[ "$ty" == "CT" ]]; then
        if pct start "$id" >/dev/null 2>&1; then
          ok "$ty $id gestartet."
        else
          err "Start CT $id fehlgeschlagen."
        fi
      else
        if qm start "$id" >/dev/null 2>&1; then
          ok "$ty $id gestartet."
        else
          err "Start VM $id fehlgeschlagen."
        fi
      fi
      ;;
    stop)
      [[ "$st" != "running" ]] && {
        ok "$ty $id ist nicht aktiv."
        return
      }
      if [[ "$ty" == "CT" ]]; then
        if pct stop "$id" >/dev/null 2>&1; then
          ok "$ty $id gestoppt."
        else
          err "Stop CT $id fehlgeschlagen."
        fi
      else
        if qm stop "$id" >/dev/null 2>&1; then
          ok "$ty $id gestoppt."
        else
          err "Stop VM $id fehlgeschlagen."
        fi
      fi
      ;;
    restart)
      if [[ "$st" != "running" ]]; then
        note "$ty $id lief nicht. Starte statt Neustart."
        do_action "$id" "$ty" start "$name"
        return
      fi
      if [[ "$ty" == "CT" ]]; then
        if pct stop "$id" >/dev/null 2>&1 && sleep 1 && pct start "$id" >/dev/null 2>&1; then
          ok "$ty $id neu gestartet."
        else
          err "Restart CT fehlgeschlagen."
        fi
      else
        if qm stop "$id" >/dev/null 2>&1 && sleep 1 && qm start "$id" >/dev/null 2>&1; then
          ok "$ty $id neu gestartet."
        else
          err "Restart VM fehlgeschlagen."
        fi
      fi
      ;;
    status)
      if [[ "$ty" == "CT" ]]; then
        if ! pct status "$id" 2>/dev/null; then
          err "Status CT $id nicht abrufbar."
        fi
      else
        if ! qm status "$id" 2>/dev/null; then
          err "Status VM $id nicht abrufbar."
        fi
      fi
      ;;
    *) err "Unbekannte Aktion: $act" ;;
  esac
}

open_console() {
  local id="$1" ty="$2" name="$3"
  note "Opening console for $ty $id ($name)…"
  if [[ "$ty" == "CT" ]]; then
    if have pct; then
      echo "CTRL+D zum Beenden."
      pct enter "$id"
    else
      err "pct fehlt."
    fi
  else
    if qm terminal "$id" 2>/dev/null; then
      :
    else
      note "'qm terminal' nicht verfügbar. Fallback 'qm monitor'."
  qm monitor "$id" || err "Console for VM $id failed."
    fi
  fi
}

snapshots_menu() {
  local id="$1" ty="$2" name="$3" s
  echo "1) List  2) Create  3) Rollback  4) Delete  5) Back"
  printf '%s' "Auswahl [1-5]: "
  read_line s
  case "$s" in
    1) [[ "$ty" == "CT" ]] && pct listsnapshot "$id" 2>/dev/null || qm listsnapshot "$id" 2>/dev/null || echo "(keine oder Fehler)" ;;
    2)
      printf 'Name: '
      read_line sn
      [[ -z "$sn" ]] && {
        echo "Abbruch."
        return
      }
      if [[ "$ty" == "CT" ]]; then
        pct snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."
      else qm snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."; fi
      ok "Snapshot '$sn' erstellt."
      ;;
    3)
      printf 'Rollback zu Snapshot: '
      read_line sn
      [[ -z "$sn" ]] && {
        echo "Abbruch."
        return
      }
      if [[ "$ty" == "CT" ]]; then
        pct rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."
      else qm rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."; fi
      ok "Rollback auf '$sn' ok."
      ;;
    4)
      printf 'Snapshot löschen: '
      read_line sn
      [[ -z "$sn" ]] && {
        echo "Abbruch."
        return
      }
      if [[ "$ty" == "CT" ]]; then
        pct delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."
      else qm delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."; fi
      ok "Snapshot '$sn' gelöscht."
      ;;
    5) : ;;
    *) err "Ungültig." ;;
  esac
}

spice_info() {
  local id="$1" name="$2"
  local host port
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  port="$(qm monitor "$id" <<<"info spice" 2>/dev/null | awk '/port/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}')"
  [[ -z "$port" ]] && port="$(grep -E "(spice).*port" "/var/log/qemu-server/${id}.log" 2>/dev/null | tail -1 | sed -n 's/.*port=\([0-9]\+\).*/\1/p')"
  [[ -z "$port" ]] && port="$((61000 + id))"
  printf '%s\n' "SPICE: spice://${host}:${port}"
  local vv="/tmp/vm-${id}.vv"
  cat >"$vv" <<EOF
[virt-viewer]
type=spice
host=${host}
port=${port}
title=VM ${id} (${name})
delete-this-file=1
fullscreen=0
EOF
  ok "Datei erstellt: ${vv}"
}

spice_enable() {
  local id="$1"
  local port="$((61000 + id))"
  qm set "$id" --vga qxl >/dev/null 2>&1 || true
  if qm set "$id" --spice "port=${port},addr=0.0.0.0" >/dev/null 2>&1; then
    ok "SPICE für VM ${id} aktiviert. Port: ${port}. Neustart erforderlich."
    printf '%s' "Jetzt neu starten? (y/N): "
    local a
    read_line a
    [[ "$a" =~ ^[yYjJ]$ ]] && do_action "$id" "VM" restart "VM-${id}"
  else
    err "SPICE konnte nicht aktiviert werden."
  fi
}

# ===== Main =====
main() {
  parse_args "$@"
  require_root
  require_tools
  if [[ ! -t 1 ]]; then
    CLEAR_SCREEN=0
  fi
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
      err "Unbekannter Modus: $MODE"
      exit 1
      ;;
  esac
}
main "$@"
