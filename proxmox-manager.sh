#!/usr/bin/env bash
set -Eeuo pipefail

# Farben
BOLD="\033[1m"; BLUE="\033[1;34m"; CYAN="\033[1;36m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"

# Graceful exit
trap 'echo -e "\n\nScript beendet."; exit 0' INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Hilfsfunktionen
# ─────────────────────────────────────────────────────────────────────────────

err() { echo -e "${RED}Fehler:${NC} $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# Prüft, ob ID CT oder VM ist
get_instance_type() {
  local id="${1:-}"
  [[ -z "${id}" ]] && { echo ""; return; }

  if pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "${id}"; then
    echo "CT"
  elif qm list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "${id}"; then
    echo "VM"
  else
    echo ""
  fi
}

# Einfache Status-Extraktion ("running"/"stopped"/"unknown")
check_status() {
  local id="$1" type="$2"
  if [[ "$type" == "CT" ]]; then
    pct status "$id" 2>/dev/null | awk '{print $2}' || echo "unknown"
  else
    qm status "$id" 2>/dev/null | awk '{print $2}' || echo "unknown"
  fi
}

# Listet alle Instanzen (VMs & CTs) und gibt eine flache Liste (je 5 Felder) aus:
# VMID, TYP, SYMBOL, NAME, STATUS
collect_all_instances() {
  local -a instance_info=()

  # CTs
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*VMID ]] && continue
    [[ "$line" =~ ^[[:space:]]*[0-9] ]] || continue

    local vmid status name
    vmid="$(awk '{print $1}' <<<"$line")"
    status="$(awk '{print $2}' <<<"$line")"
    name="$(awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}' <<<"$line")"
    [[ -z "$name" ]] && name="CT-${vmid}"

    local symbol="🟡"
    [[ "$status" == "running" ]] && symbol="🟢"
    [[ "$status" == "stopped" ]] && symbol="🔴"

    instance_info+=("$vmid" "CT" "$symbol" "$name" "$status")
  done < <(pct list 2>/dev/null || true)

  # VMs
  # qm list: VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*VMID ]] && continue
    [[ "$line" =~ ^[[:space:]]*[0-9] ]] || continue

    local vmid name status
    vmid="$(awk '{print $1}' <<<"$line")"
    name="$(awk '{print $2}' <<<"$line")"
    status="$(awk '{print $3}' <<<"$line")"
    [[ -z "$name" ]] && name="VM-${vmid}"

    local symbol="🟡"
    [[ "$status" == "running" ]] && symbol="🟢"
    [[ "$status" == "stopped" ]] && symbol="🔴"

    instance_info+=("$vmid" "VM" "$symbol" "$name" "$status")
  done < <(qm list 2>/dev/null || true)

  # Sortierung nach VMID
  if ((${#instance_info[@]}==0)); then
    return 0
  fi

  local -a map=() sorted_info=()
  for ((i=0; i<${#instance_info[@]}; i+=5)); do
    map+=("${instance_info[i]}:$i")
  done

  IFS=$'\n' map=($(sort -n -t: -k1 <<<"${map[*]}"))
  unset IFS
  for entry in "${map[@]}"; do
    local idx="${entry#*:}"
    sorted_info+=("${instance_info[idx]}" "${instance_info[idx+1]}" "${instance_info[idx+2]}" "${instance_info[idx+3]}" "${instance_info[idx+4]}")
  done

  printf '%s\n' "${sorted_info[@]}"
}

# Menüanzeige
show_main_menu() {
  clear
  echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}          Proxmox VM/CT Management Tool             ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

  local -a all
  readarray -t all < <(collect_all_instances)

  if ((${#all[@]}==0)); then
    echo -e "${RED}Keine VMs oder Container gefunden!${NC}"
    echo "Prüfen Sie Berechtigungen oder Host."
    return 1
  fi

  echo
  printf "%-6s %-4s %-8s %-6s %s\n" "ID" "Typ" "Status" "Symb." "Name"
  echo "─────────────────────────────────────────────────────────────"
  for ((i=0; i<${#all[@]}; i+=5)); do
    printf "%-6s %-4s %-8s %-6s %s\n" \
      "${all[i]}" "${all[i+1]}" "${all[i+4]}" "${all[i+2]}" "${all[i+3]}"
  done
  echo "─────────────────────────────────────────────────────────────"
  echo -e "${GREEN}Gesamt: $((${#all[@]}/5)) Instanzen gefunden${NC}"
  echo
}

select_instance() {
  local -a all
  readarray -t all < <(collect_all_instances)
  if ((${#all[@]}==0)); then
    echo "Keine Instanzen verfügbar!"
    return 1
  fi

  echo "Verfügbare Aktionen:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "• VMID eingeben (z.B. 100)"
  echo "• 'r' für Aktualisieren"
  echo "• 'q' für Beenden"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  while true; do
    read -r -p "Ihre Auswahl: " choice
    case "$choice" in
      q|Q) echo "Auf Wiedersehen!"; exit 0 ;;
      r|R) return 0 ;;
      "")
        echo "Bitte eine VMID eingeben."
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local found=0 type="" name=""
          for ((i=0; i<${#all[@]}; i+=5)); do
            if [[ "${all[i]}" == "$choice" ]]; then
              type="${all[i+1]}"; name="${all[i+3]}"; found=1; break
            fi
          done
          if ((found==1)); then
            select_action "$choice" "$type" "$name"
            return 0
          else
            echo "VMID $choice nicht gefunden! Verfügbar:"
            for ((i=0; i<${#all[@]}; i+=5)); do printf "%s " "${all[i]}"; done
            echo
          fi
        else
          echo "Ungültige Eingabe. Zahl, 'r' oder 'q'."
        fi
        ;;
    esac
  done
}

select_action() {
  local id="$1" type="$2" name="$3"
  local current_status
  current_status="$(check_status "$id" "$type")"

  echo
  echo -e "${CYAN}=== Aktionen für $type $id ($name) ===${NC}"
  echo -e "Aktueller Status: ${YELLOW}${current_status}${NC}"
  echo

  local -a actions=("Starten" "Stoppen" "Neustarten" "Status prüfen")
  if [[ "$type" == "VM" ]]; then
    actions+=("SPICE Viewer Info" "SPICE aktivieren")
  fi
  actions+=("Zurück zum Hauptmenü")

  PS3="Bitte wählen Sie eine Aktion: "
  select opt in "${actions[@]}"; do
    case "${opt:-}" in
      "Starten")        perform_action "$id" "$type" "start"   "$name" ;;
      "Stoppen")        perform_action "$id" "$type" "stop"    "$name" ;;
      "Neustarten")     perform_action "$id" "$type" "restart" "$name" ;;
      "Status prüfen")  perform_action "$id" "$type" "status"  "$name" ;;
      "SPICE Viewer Info")
                        perform_action "$id" "$type" "spice"   "$name" ;;
      "SPICE aktivieren")
                        perform_action "$id" "$type" "enable_spice" "$name" ;;
      "Zurück zum Hauptmenü") return 0 ;;
      *) echo "Ungültige Auswahl.";;
    esac
  done
}

perform_action() {
  local id="$1" type="$2" action="$3" name="$4"
  local current_status
  current_status="$(check_status "$id" "$type")"

  echo
  echo -e "${YELLOW}=== Aktion '${action}' für $type $id ($name) ===${NC}"

  case "$action" in
    start)
      if [[ "$current_status" == "running" ]]; then
        echo -e "${GREEN}$type $id ist bereits gestartet.${NC}"
      else
        echo "Starte $type $id..."
        if [[ "$type" == "CT" ]]; then
          if pct start "$id" 2>/dev/null; then
            echo -e "${GREEN}Container $id erfolgreich gestartet.${NC}"
          else
            err "Start von Container $id fehlgeschlagen."
          fi
        else
          if qm start "$id" 2>/dev/null; then
            echo -e "${GREEN}VM $id erfolgreich gestartet.${NC}"
          else
            err "Start von VM $id fehlgeschlagen."
          fi
        fi
      fi
      ;;
    stop)
      if [[ "$current_status" != "running" ]]; then
        echo -e "${GREEN}$type $id ist bereits gestoppt.${NC}"
      else
        echo "Stoppe $type $id..."
        if [[ "$type" == "CT" ]]; then
          if pct stop "$id" 2>/dev/null; then
            echo -e "${GREEN}Container $id erfolgreich gestoppt.${NC}"
          else
            err "Stopp von Container $id fehlgeschlagen."
          fi
        else
          if qm stop "$id" 2>/dev/null; then
            echo -e "${GREEN}VM $id erfolgreich gestoppt.${NC}"
          else
            err "Stopp von VM $id fehlgeschlagen."
          fi
        fi
      fi
      ;;
    restart)
      if [[ "$current_status" != "running" ]]; then
        echo -e "${YELLOW}$type $id ist nicht gestartet. Starte stattdessen...${NC}"
        perform_action "$id" "$type" "start" "$name"
      else
        echo "Starte $type $id neu..."
        if [[ "$type" == "CT" ]]; then
          if pct stop "$id" 2>/dev/null && sleep 2 && pct start "$id" 2>/dev/null; then
            echo -e "${GREEN}Container $id erfolgreich neu gestartet.${NC}"
          else
            err "Neustart von Container $id fehlgeschlagen."
          fi
        else
          if qm stop "$id" 2>/dev/null && sleep 2 && qm start "$id" 2>/dev/null; then
            echo -e "${GREEN}VM $id erfolgreich neu gestartet.${NC}"
          else
            err "Neustart von VM $id fehlgeschlagen."
          fi
        fi
      fi
      ;;
    status)
      if [[ "$type" == "CT" ]]; then
        pct status "$id" 2>/dev/null || echo "Status konnte nicht abgerufen werden"
      else
        qm status "$id" 2>/dev/null || echo "Status konnte nicht abgerufen werden"
      fi
      ;;
    spice)
      if [[ "$type" != "VM" ]]; then
        err "SPICE ist nur für VMs verfügbar."
      elif [[ "$current_status" != "running" ]]; then
        err "VM muss für SPICE gestartet sein."
      else
        show_spice_info "$id" "$name"
      fi
      ;;
    enable_spice)
      if [[ "$type" != "VM" ]]; then
        err "SPICE ist nur für VMs verfügbar."
      else
        enable_spice "$id"
      fi
      ;;
    *)
      err "Unbekannte Aktion: $action"
      ;;
  esac

  echo
  read -r -p "Enter zum Fortfahren..." _
}

# SPICE-Infos anzeigen
show_spice_info() {
  local id="$1" name="$2"

  local spice_host spice_port=""
  spice_host="$(hostname -I | awk '{print $1}')"

  # 1) qm monitor → "info spice"
  spice_port="$(qm monitor "$id" <<< "info spice" 2>/dev/null | awk '/port/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' || true)"

  # 2) qemu-server Log
  if [[ -z "$spice_port" ]]; then
    spice_port="$(grep -E "(spice).*port" "/var/log/qemu-server/${id}.log" 2>/dev/null | tail -1 | sed -n 's/.*port=\([0-9]\+\).*/\1/p' || true)"
  fi

  # 3) Fallback: aus config lesen (wenn explizit gesetzt)
  if [[ -z "$spice_port" ]]; then
    spice_port="$(qm config "$id" 2>/dev/null | awk -F'[,= ]' '/^spice:/ {for(i=1;i<=NF;i++){if($i=="port"){print $(i+1); exit}}}')" || true
  fi

  # 4) Notnagel: deterministischer Port (Hinweis ausgeben)
  if [[ -z "$spice_port" ]]; then
    spice_port="$((61000 + id))"
    echo -e "${YELLOW}Konnte SPICE-Port nicht ermitteln. Verwende Schätzung: ${spice_port}${NC}"
  fi

  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}         SPICE-Verbindungsinformationen            ${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}VM ID:${NC}      ${id}"
  echo -e "${CYAN}Host:${NC}       ${spice_host}"
  echo -e "${CYAN}Port:${NC}       ${spice_port}"
  echo -e "${CYAN}SPICE URI:${NC}  spice://${spice_host}:${spice_port}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo
  echo -e "${YELLOW}Auf Ihrem lokalen PC:${NC}"
  echo "1) SPICE Client installieren:"
  echo "   Windows: virt-viewer"
  echo "   Linux:   sudo apt install virt-viewer"
  echo "   macOS:   brew install virt-viewer"
  echo
  echo "2) Starten:"
  echo -e "   ${GREEN}remote-viewer spice://${spice_host}:${spice_port}${NC}"
  echo
  echo "3) .vv-Datei (lokal auf dem Host erstellt):"

  local vv_file="/tmp/vm-${id}.vv"
  cat > "$vv_file" <<EOF
[virt-viewer]
type=spice
host=${spice_host}
port=${spice_port}
title=VM ${id} (${name})
delete-this-file=1
fullscreen=0
EOF
  echo -e "   ${GREEN}Datei erstellt: ${vv_file}${NC}"
  echo "   (Diese Datei auf den Client kopieren und öffnen.)"
}

# SPICE aktivieren (konservativ)
enable_spice() {
  local id="$1"
  local port="$((61000 + id))"

  qm set "$id" --vga qxl       >/dev/null 2>&1 || true
  if qm set "$id" --spice "port=${port},addr=0.0.0.0" >/dev/null 2>&1; then
    echo -e "${GREEN}SPICE für VM ${id} aktiviert.${NC}"
    echo -e "${YELLOW}SPICE Port: ${port}${NC}"
    echo -e "${YELLOW}VM-Neustart erforderlich, damit SPICE aktiv wird.${NC}"
    echo
    read -r -p "VM jetzt neu starten? (j/N): " restart_vm
    if [[ "${restart_vm:-N}" =~ ^[jJyY]$ ]]; then
      perform_action "$id" "VM" "restart" "VM-${id}"
    fi
  else
    err "SPICE konnte nicht aktiviert werden. Prüfe Berechtigungen/Konfiguration."
  fi
}

# Berechtigungen prüfen
check_permissions() {
  if ! have pct || ! have qm; then
    err "Proxmox-Befehle (pct/qm) nicht verfügbar. Bitte auf einem Proxmox-Host ausführen."
    exit 1
  fi
  if ! pct list >/dev/null 2>&1 && ! qm list >/dev/null 2>&1; then
    err "Keine Berechtigung für Proxmox-Befehle. Script als root ausführen."
    exit 1
  fi
}

main() {
  check_permissions
  while true; do
    if ! show_main_menu; then
      err "Menü konnte nicht angezeigt werden."
      exit 1
    fi
    if ! select_instance; then
      echo "Kehre zum Hauptmenü zurück..."
      sleep 1
    fi
  done
}

main
