#!/usr/bin/env bash
# Version 1.5.2 – Fehlerbehebung für status-Handling & Menüanzeige
# Updated: 2025-09-07
set -Eeuo pipefail

# Colors (fallback to no color on non-TTY or if NO_COLOR is set)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; CYAN=$'\e[36m'; NC=$'\e[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# Graceful exit
trap 'echo -e "\n\nScript terminated."; exit 0' INT TERM

# ────────────────────────────────────────────────────────────────
# Helper functions
# ────────────────────────────────────────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

err() {
  echo -e "${RED}Error:${NC} $*" >&2
}

# Determine whether ID is a CT or VM
get_instance_type() {
  local id="${1:-}"
  [[ -z "${id}" ]] && { echo ""; return; }

  if have pct && pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "${id}"; then
    echo "CT"
  elif have qm && qm list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "${id}"; then
    echo "VM"
  else
    echo ""
  fi
}

# Simple status extraction ("running"/"stopped"/"paused"/"unknown")
check_status() {
  local id="$1" type="${2:-}"
  local out status

  if [[ -z "$type" ]]; then
    type="$(get_instance_type "$id")"
  fi

  if [[ "$type" == "CT" ]]; then
    if have pct; then
      out="$(pct status "$id" 2>/dev/null || true)"
    else
      echo "unknown"; return
    fi
  elif [[ "$type" == "VM" ]]; then
    if have qm; then
      out="$(qm status "$id" 2>/dev/null || true)"
    else
      echo "unknown"; return
    fi
  else
    echo "unknown"; return
  fi

  # Look for known keywords in the output (robust against different output formats)
  if grep -qE '\brunning\b' <<<"$out"; then
    status="running"
  elif grep -qE '\bstopped\b' <<<"$out"; then
    status="stopped"
  elif grep -qE '\bpaused\b' <<<"$out"; then
    status="paused"
  else
    # Fallback: try to extract last word which sometimes contains status
    status="$(awk '{print tolower($NF)}' <<<"$out" | sed -n 's/[^a-z].*//p' || true)"
    case "$status" in
      running|stopped|paused) ;;
      *) status="unknown" ;;
    esac
  fi

  echo "$status"
}

# List all instances (VMs & CTs) and output a flat list (5 fields each):
# VMID, TYPE, STATUS, SYMBOL, NAME
collect_all_instances() {
  local -a instance_info=()

  # CTs
  if have pct; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[[:space:]]*VMID ]] && continue
      [[ "$line" =~ ^[[:space:]]*[0-9]+ ]] || continue

      local vmid name status symbol
      vmid="$(awk '{print $1}' <<<"$line")"

      # Try to extract name from the listing line; if not present, fallback to CT-<id>
      # Listing lines may include status at the end, so remove it if found
      name="$(sed -E "s/^[[:space:]]*${vmid}[[:space:]]+//; s/[[:space:]]+(running|stopped|paused).*//I" <<<"$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//')"
      [[ -z "$name" ]] && name="CT-${vmid}"

      # Use reliable status lookup
      status="$(check_status "$vmid" "CT")"
      [[ -z "$status" ]] && status="unknown"

      symbol="🟡"
      [[ "$status" == "running" ]] && symbol="🟢"
      [[ "$status" == "stopped" ]] && symbol="🔴"
      [[ "$status" == "paused" ]] && symbol="🟠"

      # Append in canonical order: vmid, type, status, symbol, name
      instance_info+=("$vmid" "CT" "$status" "$symbol" "$name")
    done < <(pct list 2>/dev/null || true)
  fi

  # VMs
  if have qm; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^[[:space:]]*VMID ]] && continue
      [[ "$line" =~ ^[[:space:]]*[0-9]+ ]] || continue

      local vmid name status symbol
      vmid="$(awk '{print $1}' <<<"$line")"

      name="$(sed -E "s/^[[:space:]]*${vmid}[[:space:]]+//; s/[[:space:]]+(running|stopped|paused).*//I" <<<"$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//')"
      [[ -z "$name" ]] && name="VM-${vmid}"

      # Use reliable status lookup
      status="$(check_status "$vmid" "VM")"
      [[ -z "$status" ]] && status="unknown"

      symbol="🟡"
      [[ "$status" == "running" ]] && symbol="🟢"
      [[ "$status" == "stopped" ]] && symbol="🔴"
      [[ "$status" == "paused" ]] && symbol="🟠"

      instance_info+=("$vmid" "VM" "$status" "$symbol" "$name")
    done < <(qm list 2>/dev/null || true)
  fi

  # If no instances, return empty
  if ((${#instance_info[@]}==0)); then
    return 0
  fi

  # Sort by VMID (numerically)
  local -a map=() sorted_info=()
  for ((i=0; i<${#instance_info[@]}; i+=5)); do
    map+=("${instance_info[i]}:$i")
  done

  readarray -t map < <(printf '%s\n' "${map[@]}" | sort -n -t: -k1)
  for entry in "${map[@]}"; do
    local idx="${entry#*:}"
    sorted_info+=("${instance_info[idx]}" "${instance_info[idx+1]}" "${instance_info[idx+2]}" "${instance_info[idx+3]}" "${instance_info[idx+4]}")
  done

  printf '%s\n' "${sorted_info[@]}"
}

# Menu display
show_main_menu() {
  clear
  echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}          Proxmox VM/CT Management Tool             ${NC}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"

  local -a all
  readarray -t all < <(collect_all_instances)

  if ((${#all[@]}==0)); then
    echo -e "${RED}No VMs or containers found!${NC}"
    echo "Check permissions or host."
    return 1
  fi

  echo
  printf "%-6s %-4s %-8s %-6s %s\n" "ID" "Type" "Status" "Symb." "Name"
  echo "─────────────────────────────────────────────────────────────"
  for ((i=0; i<${#all[@]}; i+=5)); do
    printf "%-6s %-4s %-8s %-6s %s\n" \
      "${all[i]}" "${all[i+1]}" "${all[i+2]}" "${all[i+3]}" "${all[i+4]}"
  done
  echo "─────────────────────────────────────────────────────────────"
  echo
}

select_instance() {
  local -a all
  readarray -t all < <(collect_all_instances)
  if ((${#all[@]}==0)); then
    echo "No instances available!"
    return 1
  fi

  echo "Available actions:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "• Enter VMID (e.g., 100)"
  echo "• 'r' to refresh"
  echo "• 'q' to quit"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  while true; do
    read -r -p "Your choice: " choice
    case "$choice" in
      q|Q) echo "Goodbye!"; exit 0 ;;
      r|R) return 0 ;;
      "")
        echo "Please enter a VMID."
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local found=0 type="" name=""
          for ((i=0; i<${#all[@]}; i+=5)); do
            if [[ "${all[i]}" == "$choice" ]]; then
              type="${all[i+1]}"; name="${all[i+4]}"; found=1; break
            fi
          done
          if ((found==1)); then
            select_action "$choice" "$type" "$name"
            return 0
          else
            echo "VMID $choice not found! Available:"
            for ((i=0; i<${#all[@]}; i+=5)); do printf "%s " "${all[i]}"; done
            echo
          fi
        else
          echo "Invalid input. Number, 'r', or 'q'."
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
  echo -e "${CYAN}=== Actions for $type $id ($name) ===${NC}"
  echo -e "Current status: ${YELLOW}${current_status}${NC}"
  echo

  local -a actions=("Start" "Stop" "Restart" "Check status" "Open console" "Manage snapshots")
  if [[ "$type" == "VM" ]]; then
    actions+=("SPICE Viewer Info" "Enable SPICE")
  fi
  actions+=("Back to main menu")

  PS3="Select an action: "
  select opt in "${actions[@]}"; do
    case "${opt:-}" in
      "Start")          perform_action "$id" "$type" "start"   "$name" ;;
      "Stop")           perform_action "$id" "$type" "stop"    "$name" ;;
      "Restart")        perform_action "$id" "$type" "restart" "$name" ;;
      "Check status")   perform_action "$id" "$type" "status"  "$name" ;;
      "Open console")   open_console "$id" "$type" "$name" ;;
      "Manage snapshots") manage_snapshots "$id" "$type" "$name" ;;
      "SPICE Viewer Info")  perform_action "$id" "$type" "spice"        "$name" ;;
      "Enable SPICE")       perform_action "$id" "$type" "enable_spice" "$name" ;;
      "Back to main menu")  return 0 ;;
      *) echo "Invalid choice.";;
    esac
  done
}

perform_action() {
  local id="$1" type="$2" action="$3" name="$4"
  local current_status
  current_status="$(check_status "$id" "$type")"

  echo
  echo -e "${YELLOW}=== Action '${action}' for $type $id ($name) ===${NC}"

  case "$action" in
    start)
      if [[ "$current_status" == "running" ]]; then
        echo -e "${GREEN}$type $id is already running.${NC}"
      else
        echo "Starting $type $id..."
        if [[ "$type" == "CT" ]]; then
          if pct start "$id" 2>/dev/null; then
            echo -e "${GREEN}Container $id started successfully.${NC}"
          else
            err "Start of container $id failed."
          fi
        else
          if qm start "$id" 2>/dev/null; then
            echo -e "${GREEN}VM $id started successfully.${NC}"
          else
            err "Start of VM $id failed."
          fi
        fi
      fi
      ;;
    stop)
      if [[ "$current_status" != "running" ]]; then
        echo -e "${GREEN}$type $id is not running.${NC}"
      else
        echo "Stopping $type $id..."
        if [[ "$type" == "CT" ]]; then
          if pct stop "$id" 2>/dev/null; then
            echo -e "${GREEN}Container $id stopped successfully.${NC}"
          else
            err "Stop of container $id failed."
          fi
        else
          if qm stop "$id" 2>/dev/null; then
            echo -e "${GREEN}VM $id stopped successfully.${NC}"
          else
            err "Stop of VM $id failed."
          fi
        fi
      fi
      ;;
    restart)
      if [[ "$current_status" != "running" ]]; then
        echo -e "${YELLOW}$type $id is not running. Starting instead...${NC}"
        perform_action "$id" "$type" "start" "$name"
      else
        echo "Restarting $type $id..."
        if [[ "$type" == "CT" ]]; then
          if pct stop "$id" 2>/dev/null && sleep 2 && pct start "$id" 2>/dev/null; then
            echo -e "${GREEN}Container $id restarted successfully.${NC}"
          else
            err "Restart of container $id failed."
          fi
        else
          if qm stop "$id" 2>/dev/null && sleep 2 && qm start "$id" 2>/dev/null; then
            echo -e "${GREEN}VM $id restarted successfully.${NC}"
          else
            err "Restart of VM $id failed."
          fi
        fi
      fi
      ;;
    status)
      if [[ "$type" == "CT" ]]; then
        pct status "$id" 2>/dev/null || echo "Status could not be retrieved"
      else
        qm status "$id" 2>/dev/null || echo "Status could not be retrieved"
      fi
      ;;
    spice)
      if [[ "$type" != "VM" ]]; then
        err "SPICE is only available for VMs."
      elif [[ "$current_status" != "running" ]]; then
        err "VM must be running for SPICE."
      else
        show_spice_info "$id" "$name"
      fi
      ;;
    enable_spice)
      if [[ "$type" != "VM" ]]; then
        err "SPICE is only available for VMs."
      else
        enable_spice "$id"
      fi
      ;;
    *)
      err "Unknown action: $action"
      ;;
  esac

  echo
  read -r -p "Press Enter to continue..." _
}

# ──────────────────────────────────────────────────────────────────
# Open console
# CT: pct enter <id>
# VM: qm terminal <id>, fallback to qm monitor (Info)
open_console() {
  local id="$1" type="$2" name="$3"
  echo
  echo -e "${CYAN}Opening console for $type $id (${name})${NC}"
  if [[ "$type" == "CT" ]]; then
    if have pct; then
      echo -e "${YELLOW}Launching 'pct enter' — CTRL+D or exit to quit.${NC}"
      pct enter "$id"
    else
      err "pct not available."
    fi
  else
    if have qm; then
      if qm terminal "$id" 2>/dev/null; then
        true
      else
        echo -e "${YELLOW}'qm terminal' not available or failed. Trying 'qm monitor' (monitor only).${NC}"
        echo -e "${YELLOW}Finish with Ctrl+D or 'quit'.${NC}"
        qm monitor "$id" || err "Could not open console for VM $id."
      fi
    else
      err "qm not available."
    fi
  fi
  echo
  read -r -p "Press Enter to continue..." _
}

# ──────────────────────────────────────────────────────────────────
# Snapshot management (list/create/rollback/delete)
manage_snapshots() {
  local id="$1" type="$2" name="$3"
  local opt snapname

  while true; do
    echo
    echo -e "${CYAN}Snapshots for $type $id (${name})${NC}"
    echo "1) List"
    echo "2) Create snapshot"
    echo "3) Rollback snapshot"
    echo "4) Delete snapshot"
    echo "5) Back"
    read -r -p "Choice [1-5]: " opt
    case "$opt" in
      1)
        echo
        if [[ "$type" == "CT" ]]; then
          if have pct; then
            pct listsnapshot "$id" 2>/dev/null || echo "(no snapshots or error)"
          else
            err "pct not available."
          fi
        else
          if have qm; then
            qm listsnapshot "$id" 2>/dev/null || echo "(no snapshots or error)"
          else
            err "qm not available."
          fi
        fi
        ;;
      2)
        read -r -p "Name for new snapshot: " snapname
        if [[ -z "$snapname" ]]; then
          echo "Cancelled: empty name."
        else
          if [[ "$type" == "CT" ]]; then
            if pct snapshot "$id" "$snapname" 2>/dev/null; then
              echo -e "${GREEN}Snapshot '${snapname}' created for CT ${id}.${NC}"
            else
              err "Snapshot creation failed."
            fi
          else
            if qm snapshot "$id" "$snapname" 2>/dev/null; then
              echo -e "${GREEN}Snapshot '${snapname}' created for VM ${id}.${NC}"
            else
              err "Snapshot creation failed."
            fi
          fi
        fi
        ;;
      3)
        read -r -p "Name of snapshot to rollback: " snapname
        if [[ -z "$snapname" ]]; then
          echo "Cancelled: empty name."
        else
          if [[ "$type" == "CT" ]]; then
            if pct rollback "$id" "$snapname" 2>/dev/null; then
              echo -e "${GREEN}CT ${id} rolled back to snapshot '${snapname}'.${NC}"
            else
              err "Rollback failed."
            fi
          else
            if qm rollback "$id" "$snapname" 2>/dev/null; then
              echo -e "${GREEN}VM ${id} rolled back to snapshot '${snapname}'.${NC}"
            else
              err "Rollback failed."
            fi
          fi
        fi
        ;;
      4)
        read -r -p "Name of snapshot to delete: " snapname
        if [[ -z "$snapname" ]]; then
          echo "Cancelled: empty name."
        else
          if [[ "$type" == "CT" ]]; then
            if pct delsnapshot "$id" "$snapname" 2>/dev/null; then
              echo -e "${GREEN}Snapshot '${snapname}' deleted.${NC}"
            else
              err "Delete failed."
            fi
          else
            if qm delsnapshot "$id" "$snapname" 2>/dev/null; then
              echo -e "${GREEN}Snapshot '${snapname}' deleted.${NC}"
            else
              err "Delete failed."
            fi
          fi
        fi
        ;;
      5) return 0 ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done
}

# Show SPICE info
show_spice_info() {
  local id="$1" name="$2"

  local spice_host spice_port=""
  spice_host="$(hostname -I | awk '{print $1}')"

  # 1) qm monitor → "info spice"
  if have qm; then
    spice_port="$(qm monitor "$id" <<< "info spice" 2>/dev/null | awk '/port/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' || true)"
  fi

  # 2) qemu-server Log
  if [[ -z "$spice_port" ]]; then
    spice_port="$(grep -E "(spice).*port" "/var/log/qemu-server/${id}.log" 2>/dev/null | tail -1 | sed -n 's/.*port=\([0-9]\+\).*/\1/p' || true)"
  fi

  # 3) Fallback: aus config lesen (wenn explizit gesetzt)
  if [[ -z "$spice_port" ]] && have qm; then
    spice_port="$(qm config "$id" 2>/dev/null | awk -F'[,= ]' '/^spice:/ {for(i=1;i<=NF;i++){if($i=="port"){print $(i+1); exit}}}')" || true
  fi

  # 4) Notnagel: deterministischer Port (Hinweis ausgeben)
  if [[ -z "$spice_port" ]]; then
    spice_port="$((61000 + id))"
    echo -e "${YELLOW}Could not determine SPICE port. Using estimate: ${spice_port}${NC}"
  fi

  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}         SPICE connection information            ${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}VM ID:${NC}      ${id}"
  echo -e "${CYAN}Host:${NC}       ${spice_host}"
  echo -e "${CYAN}Port:${NC}       ${spice_port}"
  echo -e "${CYAN}SPICE URI:${NC}  spice://${spice_host}:${spice_port}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo
  echo -e "${YELLOW}On your local PC:${NC}"
  echo "1) Install SPICE client:"
  echo "   Windows: virt-viewer"
  echo "   Linux:   sudo apt install virt-viewer"
  echo "   macOS:   brew install virt-viewer"
  echo
  echo "2) Launch:"
  echo -e "   ${GREEN}remote-viewer spice://${spice_host}:${spice_port}${NC}"
  echo
  echo "3) .vv file (created on the host):"

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
  echo -e "   ${GREEN}File created: ${vv_file}${NC}"
  echo "   (Copy this file to your client and open it.)"
}

# Enable SPICE (conservative)
enable_spice() {
  local id="$1"
  local port="$((61000 + id))"

  qm set "$id" --vga qxl       >/dev/null 2>&1 || true
  if qm set "$id" --spice "port=${port},addr=0.0.0.0" >/dev/null 2>&1; then
    echo -e "${GREEN}SPICE enabled for VM ${id}.${NC}"
    echo -e "${YELLOW}SPICE Port: ${port}${NC}"
    echo -e "${YELLOW}VM restart required for SPICE to take effect.${NC}"
    echo
    read -r -p "Restart VM now? (y/N): " restart_vm
    if [[ "${restart_vm:-N}" =~ ^[jJyY]$ ]]; then
      perform_action "$id" "VM" "restart" "VM-${id}"
    fi
  else
    err "Could not enable SPICE. Check permissions/configuration."
  fi
}

# Check permissions
check_permissions() {
  # Mindestens eines der beiden Tools muss erfolgreich sein
  if ! { (have pct && pct list >/dev/null 2>&1) || (have qm && qm list >/dev/null 2>&1); }; then
    err "Proxmox commands (pct/qm) not available or no permission. Run on a Proxmox host as root."
    exit 1
  fi
}

main() {
  check_permissions
  while true; do
    if ! show_main_menu; then
      err "Could not display menu."
      exit 1
    fi
    if ! select_instance; then
      echo "Returning to main menu..."
      sleep 1
    fi
  done
}

main
