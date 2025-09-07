[1mdiff --git a/proxmox-manager.sh b/proxmox-manager.sh[m
[1mindex 0e26a97..5e7d472 100755[m
[1m--- a/proxmox-manager.sh[m
[1m+++ b/proxmox-manager.sh[m
[36m@@ -1,8 +1,8 @@[m
 #!/usr/bin/env bash[m
 # Proxmox VM/CT Management Tool[m
[31m-# Version 2.7.1 — 2025-09-07[m
[31m-# - Fix: sort -k1,1 statt -k1,1,1[m
[31m-# - Stabiles CT-Namen-Parsing: $NF + Fallback pct config hostname[m
[32m+[m[32m# Version 2.7.2 — 2025-09-07[m
[32m+[m[32m# - Fix: Header-Zeilen sicher ignorieren (nur numerische IDs)[m
[32m+[m[32m# - CT-Namen: $NF + Fallback pct config hostname[m
 # - Root-Prüfung, LC_ALL=C, kein sudo[m
 [m
 set -Eeuo pipefail[m
[36m@@ -30,11 +30,17 @@[m [mtrim() { local v="$*"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:][m
 require_root() { (( EUID == 0 )) || { err "Als root ausführen."; exit 1; } }[m
 require_tools() { { have qm || have pct; } || { err "qm/pct fehlen. Auf Proxmox-Host starten."; exit 1; } }[m
 [m
[32m+[m[32m# Nur Zeilen mit führender numerischer ID zulassen[m
[32m+[m[32mis_data_line() {[m
[32m+[m[32m  # erlaubt führende Spaces, dann Ziffern, dann Space/Tab[m
[32m+[m[32m  [[ "$1" =~ ^[[:space:]]*[0-9]+[[:space:]]+ ]][m
[32m+[m[32m}[m
[32m+[m
 # ===== Typ/Status =====[m
 type_of_id() {[m
   local id="$1"[m
[31m-  if have pct && pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx -- "$id"; then printf 'CT'; return; fi[m
[31m-  if have qm  && qm  list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx -- "$id"; then printf 'VM'; return; fi[m
[32m+[m[32m  if have pct && pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then printf 'CT'; return; fi[m
[32m+[m[32m  if have qm  && qm  list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx -- "$id"; then printf 'VM'; return; fi[m
   printf ''[m
 }[m
 [m
[36m@@ -56,8 +62,7 @@[m [mcollect_instances() {[m
   if have pct; then[m
     while IFS= read -r line; do[m
       [[ -z "${line// /}" ]] && continue[m
[31m-      [[ "$line" =~ ^VMID[[:space:]] ]] && continue[m
[31m-      awk 'NF && $1 ~ /^[0-9]+$/' >/dev/null <<<"$line" || continue[m
[32m+[m[32m      is_data_line "$line" || continue[m
       local id status name sym[m
       id="$(awk '{print $1}' <<<"$line")"[m
       status="$(awk '{print $2}' <<<"$line")"[m
[36m@@ -72,8 +77,7 @@[m [mcollect_instances() {[m
   if have qm; then[m
     while IFS= read -r line; do[m
       [[ -z "${line// /}" ]] && continue[m
[31m-      [[ "$line" =~ ^VMID[[:space:]] ]] && continue[m
[31m-      awk 'NF && $1 ~ /^[0-9]+$/' >/dev/null <<<"$line" || continue[m
[32m+[m[32m      is_data_line "$line" || continue[m
       local id status name sym[m
       id="$(awk '{print $1}' <<<"$line")"[m
       name="$(awk '{print $2}' <<<"$line")"[m
