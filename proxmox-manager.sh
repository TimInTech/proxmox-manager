#!/usr/bin/env bash
# Proxmox VM/CT Management Tool
# Version 2.7.2 — 2025-09-07
# - Fix: Header-Zeilen sicher ignorieren (nur numerische IDs)
# - CT-Namen: $NF + Fallback pct config hostname
# - Root-Prüfung, LC_ALL=C, kein sudo

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

# ===== Colors (nur TTY) =====
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'; NC=$'\e[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

trap 'printf "\n%s\n" "Beendet."; exit 0' INT TERM

have() { command -v "$1" >/dev/null 2>&1; }
err()  { printf '%b\n' "${RED}Error:${NC} $*" >&2; }
ok()   { printf '%b\n' "${GREEN}$*${NC}"; }
note() { printf '%b\n' "${CYAN}$*${NC}"; }

# ===== Helpers =====
read_line() { local -n __o=$1; if ! IFS= read -r __o; then __o=''; fi; }
trim() { local v="$*"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

require_root() { (( EUID == 0 )) || { err "Als root ausführen."; exit 1; } }
require_tools() { { have qm || have pct; } || { err "qm/pct fehlen. Auf Proxmox-Host starten."; exit 1; } }

# Nur Zeilen mit führender numerischer ID zulassen
is_data_line() {
  # erlaubt führende Spaces, dann Ziffern, dann Space/Tab
  [[ "$1" =~ ^[[:space:]]*[0-9]+[[:space:]]+ ]]
}

# ===== Typ/Status =====
type_of_id() {
  local id="$1"
  if have pct && pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then printf 'CT'; return; fi
  if have qm  && qm  list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then printf 'VM'; return; fi
  printf ''
}

status_of() {
  local id="$1" t="${2:-}"; [[ -z "$t" ]] && t="$(type_of_id "$id")"
  case "$t" in
    CT) pct status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
    VM) qm  status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
     *) printf 'unknown' ;;
  esac
}

# ===== Namen =====
ct_name_from_config() { pct config "$1" 2>/dev/null | awk -F': *' '/^hostname:/ {print $2; exit}'; }
vm_name_from_config() { qm  config "$1" 2>/dev/null | awk -F': *' '/^name:/     {print $2; exit}'; }

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
      sym="🟡"; [[ "$status" == "running" ]] && sym="🟢"; [[ "$status" == "stopped" ]] && sym="🔴"; [[ "$status" == "paused" ]] && sym="🟠"
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
      sym="🟡"; [[ "$status" == "running" ]] && sym="🟢"; [[ "$status" == "stopped" ]] && sym="🔴"; [[ "$status" == "paused" ]] && sym="🟠"
      printf "%s\tVM\t%s\t%s\t%s\n" "$id" "$status" "$sym" "$name"
    done < <(qm list 2>/dev/null || true)
  fi
}

# ===== UI =====
header() {
  clear
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
  if (( any == 0 )); then
    printf '%b\n' "${RED}Keine VMs oder Container gefunden.${NC}"
    printf '%s\n' "Direkt auf dem Proxmox-Host als root starten."
    return 1
  fi
  printf '%s\n' "─────────────────────────────────────────────────────────────"
  return 0
}

main_menu() {
  header
  if ! print_table; then return 1; fi
  echo "Eingaben: VMID starten | 'r' neu laden | 'q' beenden"
  printf '%s' "Auswahl: "
  local choice; read_line choice
  case "$choice" in
    q|Q) exit 0 ;;
    r|R|'') return 0 ;;
    *  )
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local sel_type sel_name found=0
        while IFS=$'\t' read -r id ty _ _ nm; do
          if [[ "$id" == "$choice" ]]; then sel_type="$ty"; sel_name="$nm"; found=1; break; fi
        done < <(collect_instances)
        (( found == 1 )) && action_menu "$choice" "$sel_type" "$sel_name" || err "VMID $choice nicht gefunden."
      else
        err "Ungültige Eingabe."
      fi
      ;;
  esac
}

action_menu() {
  local id="$1" ty="$2" name="$3"
  local st; st="$(status_of "$id" "$ty")"
  echo
  note "Aktionen für $ty $id ($name) — Status: $st"
  echo "1) Start   2) Stop    3) Restart   4) Status"
  echo "5) Konsole 6) Snapshots"
  if [[ "$ty" == "VM" ]]; then
    echo "7) SPICE-Info  8) SPICE aktivieren"
  fi
  echo "9) Zurück"
  printf '%s' "Auswahl [1-9]: "
  local opt; read_line opt
  case "$opt" in
    1) do_action "$id" "$ty" start   "$name" ;;
    2) do_action "$id" "$ty" stop    "$name" ;;
    3) do_action "$id" "$ty" restart "$name" ;;
    4) do_action "$id" "$ty" status  "$name" ;;
    5) open_console "$id" "$ty" "$name" ;;
    6) snapshots_menu "$id" "$ty" "$name" ;;
    7) [[ "$ty" == "VM" ]] && spice_info "$id" "$name" || err "Nur für VMs." ;;
    8) [[ "$ty" == "VM" ]] && spice_enable "$id"        || err "Nur für VMs." ;;
    9) : ;;
    *) err "Ungültig." ;;
  esac
  printf '%s' "Weiter mit Enter… "; local _; read_line _
}

do_action() {
  local id="$1" ty="$2" act="$3" name="$4"
  local st; st="$(status_of "$id" "$ty")"
  case "$act" in
    start)
      [[ "$st" == "running" ]] && { ok "$ty $id läuft bereits."; return; }
      if [[ "$ty" == "CT" ]]; then pct start "$id" >/dev/null 2>&1 || err "Start CT $id fehlgeschlagen."
      else qm start "$id"  >/dev/null 2>&1 || err "Start VM $id fehlgeschlagen."; fi
      ok "$ty $id gestartet."
      ;;
    stop)
      [[ "$st" != "running" ]] && { ok "$ty $id ist nicht aktiv."; return; }
      if [[ "$ty" == "CT" ]]; then pct stop "$id" >/dev/null 2>&1 || err "Stop CT $id fehlgeschlagen."
      else qm stop "$id"  >/dev/null 2>&1 || err "Stop VM $id fehlgeschlagen."; fi
      ok "$ty $id gestoppt."
      ;;
    restart)
      if [[ "$st" != "running" ]]; then note "$ty $id lief nicht. Starte statt Neustart."; do_action "$id" "$ty" start "$name"; return; fi
      if [[ "$ty" == "CT" ]]; then pct stop "$id" >/dev/null 2>&1 && sleep 1 && pct start "$id" >/dev/null 2>&1 || err "Restart CT fehlgeschlagen."
      else qm stop "$id"  >/dev/null 2>&1 && sleep 1 && qm start "$id"  >/dev/null 2>&1 || err "Restart VM fehlgeschlagen."; fi
      ok "$ty $id neu gestartet."
      ;;
    status)
      if [[ "$ty" == "CT" ]]; then pct status "$id" 2>/dev/null || err "Status CT $id nicht abrufbar."
      else qm  status "$id" 2>/dev/null || err "Status VM $id nicht abrufbar."; fi
      ;;
    *) err "Unbekannte Aktion: $act" ;;
  esac
}

open_console() {
  local id="$1" ty="$2" name="$3"
  note "Konsole für $ty $id ($name) öffnen…"
  if [[ "$ty" == "CT" ]]; then
    have pct && { echo "CTRL+D zum Beenden."; pct enter "$id"; } || err "pct fehlt."
  else
    if qm terminal "$id" 2>/dev/null; then :
    else
      note "'qm terminal' nicht verfügbar. Fallback 'qm monitor'."
      qm monitor "$id" || err "Konsole für VM $id fehlgeschlagen."
    fi
  fi
}

snapshots_menu() {
  local id="$1" ty="$2" name="$3" s
  echo "1) Auflisten  2) Erstellen  3) Rollback  4) Löschen  5) Zurück"
  printf '%s' "Auswahl [1-5]: "; read_line s
  case "$s" in
    1) [[ "$ty" == "CT" ]] && pct listsnapshot "$id" 2>/dev/null || qm listsnapshot "$id" 2>/dev/null || echo "(keine oder Fehler)";;
    2) printf 'Name: '; read_line sn; [[ -z "$sn" ]] && { echo "Abbruch."; return; }
       if [[ "$ty" == "CT" ]]; then pct snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."
       else qm snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."; fi
       ok "Snapshot '$sn' erstellt." ;;
    3) printf 'Rollback zu Snapshot: '; read_line sn; [[ -z "$sn" ]] && { echo "Abbruch."; return; }
       if [[ "$ty" == "CT" ]]; then pct rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."
       else qm rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."; fi
       ok "Rollback auf '$sn' ok." ;;
    4) printf 'Snapshot löschen: '; read_line sn; [[ -z "$sn" ]] && { echo "Abbruch."; return; }
       if [[ "$ty" == "CT" ]]; then pct delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."
       else qm delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."; fi
       ok "Snapshot '$sn' gelöscht." ;;
    5) : ;;
    *) err "Ungültig." ;;
  esac
}

spice_info() {
  local id="$1" name="$2"
  local host port
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  port="$(qm monitor "$id" <<< "info spice" 2>/dev/null | awk '/port/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}')"
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
  local id="$1" port="$((61000 + id))"
  qm set "$id" --vga qxl >/dev/null 2>&1 || true
  if qm set "$id" --spice "port=${port},addr=0.0.0.0" >/dev/null 2>&1; then
    ok "SPICE für VM ${id} aktiviert. Port: ${port}. Neustart erforderlich."
    printf '%s' "Jetzt neu starten? (y/N): "
    local a; read_line a
    [[ "$a" =~ ^[yYjJ]$ ]] && do_action "$id" "VM" restart "VM-${id}"
  else
    err "SPICE konnte nicht aktiviert werden."
  fi
}

# ===== Main =====
main() {
  require_root
  require_tools
  while true; do main_menu || true; done
}
main
