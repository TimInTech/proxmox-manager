# Phase 2 - Static Analysis

## Git state
```
$ git status -sb
## audit/20260110-security-correctness
D  .github/workflows/ci.yml
D  .github/workflows/gitleaks.yml
A  REPORT_PROXMOX_RESTORE.md
AD proxmox-manager-test
AD tests/mock-bin/pct
AD tests/mock-bin/qm
?? reports/
```

```
$ git rev-parse --abbrev-ref HEAD
audit/20260110-security-correctness
```

```
$ git diff --stat
 proxmox-manager-test |  1 -
 tests/mock-bin/pct   |  9 ---------
 tests/mock-bin/qm    | 10 ----------
 3 files changed, 20 deletions(-)
```

## bash -n
```
$ find . -name '*.sh' -print
./proxmox-manager.sh
./install_dependencies.sh
```

```
$ bash -n <each .sh>

(exitcode=0)
```

## shellcheck
```
$ shellcheck -S style -f gcc <all .sh>

(exitcode=0)
```

## shfmt (diff only)
```
$ shfmt -d <all .sh>
--- ./proxmox-manager.sh.orig
+++ ./proxmox-manager.sh
@@ -84,38 +84,38 @@
 parse_args() {
   while [[ $# -gt 0 ]]; do
     case "$1" in
-      --list)
-        MODE="list"
-        LIST_FLAG=1
-        ;;
-      --json)
-        MODE="json"
-        JSON_FLAG=1
-        ;;
-      --no-clear)
-        CLEAR_SCREEN=0
-        ;;
-      --once)
-        RUN_ONCE=1
-        ;;
-      -h | --help)
-        usage
-        exit 0
-        ;;
-      --)
-        shift
-        break
-        ;;
-      -*)
-        err "Unbekannte Option: $1"
-        usage
-        exit 1
-        ;;
-      *)
-        err "Unerwartetes Argument: $1"
-        usage
-        exit 1
-        ;;
+    --list)
+      MODE="list"
+      LIST_FLAG=1
+      ;;
+    --json)
+      MODE="json"
+      JSON_FLAG=1
+      ;;
+    --no-clear)
+      CLEAR_SCREEN=0
+      ;;
+    --once)
+      RUN_ONCE=1
+      ;;
+    -h | --help)
+      usage
+      exit 0
+      ;;
+    --)
+      shift
+      break
+      ;;
+    -*)
+      err "Unbekannte Option: $1"
+      usage
+      exit 1
+      ;;
+    *)
+      err "Unerwartetes Argument: $1"
+      usage
+      exit 1
+      ;;
     esac
     shift
   done
@@ -160,9 +160,9 @@
   local id="$1" t="${2:-}"
   [[ -z "$t" ]] && t="$(type_of_id "$id")"
   case "$t" in
-    CT) pct status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
-    VM) qm status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
-    *) printf 'unknown' ;;
+  CT) pct status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
+  VM) qm status "$id" 2>/dev/null | awk '{print tolower($NF)}' || printf 'unknown' ;;
+  *) printf 'unknown' ;;
   esac
 }
 
@@ -272,28 +272,28 @@
   local choice
   read_line choice
   case "$choice" in
-    q | Q) exit 0 ;;
-    r | R | '') return 0 ;;
-    *)
-      if [[ "$choice" =~ ^[0-9]+$ ]]; then
-        local sel_type sel_name found=0
-        while IFS=$'\t' read -r id ty _ _ nm; do
-          if [[ "$id" == "$choice" ]]; then
-            sel_type="$ty"
-            sel_name="$nm"
-            found=1
-            break
-          fi
-        done < <(collect_instances)
-        if ((found == 1)); then
-          action_menu "$choice" "$sel_type" "$sel_name"
-        else
-          err "VMID $choice not found."
+  q | Q) exit 0 ;;
+  r | R | '') return 0 ;;
+  *)
+    if [[ "$choice" =~ ^[0-9]+$ ]]; then
+      local sel_type sel_name found=0
+      while IFS=$'\t' read -r id ty _ _ nm; do
+        if [[ "$id" == "$choice" ]]; then
+          sel_type="$ty"
+          sel_name="$nm"
+          found=1
+          break
         fi
+      done < <(collect_instances)
+      if ((found == 1)); then
+        action_menu "$choice" "$sel_type" "$sel_name"
       else
-        err "Invalid input."
+        err "VMID $choice not found."
       fi
-      ;;
+    else
+      err "Invalid input."
+    fi
+    ;;
   esac
 }
 
@@ -313,28 +313,28 @@
   local opt
   read_line opt
   case "$opt" in
-    1) do_action "$id" "$ty" start "$name" ;;
-    2) do_action "$id" "$ty" stop "$name" ;;
-    3) do_action "$id" "$ty" restart "$name" ;;
-    4) do_action "$id" "$ty" status "$name" ;;
-    5) open_console "$id" "$ty" "$name" ;;
-    6) snapshots_menu "$id" "$ty" "$name" ;;
-    7)
-      if [[ "$ty" == "VM" ]]; then
-        spice_info "$id" "$name"
-      else
-        err "Nur für VMs."
-      fi
-      ;;
-    8)
-      if [[ "$ty" == "VM" ]]; then
-        spice_enable "$id"
-      else
-        err "Nur für VMs."
-      fi
-      ;;
-    9) : ;;
-    *) err "Invalid." ;;
+  1) do_action "$id" "$ty" start "$name" ;;
+  2) do_action "$id" "$ty" stop "$name" ;;
+  3) do_action "$id" "$ty" restart "$name" ;;
+  4) do_action "$id" "$ty" status "$name" ;;
+  5) open_console "$id" "$ty" "$name" ;;
+  6) snapshots_menu "$id" "$ty" "$name" ;;
+  7)
+    if [[ "$ty" == "VM" ]]; then
+      spice_info "$id" "$name"
+    else
+      err "Nur für VMs."
+    fi
+    ;;
+  8)
+    if [[ "$ty" == "VM" ]]; then
+      spice_enable "$id"
+    else
+      err "Nur für VMs."
+    fi
+    ;;
+  9) : ;;
+  *) err "Invalid." ;;
   esac
   printf '%s' "Press Enter to continue… "
   local _
@@ -346,76 +346,76 @@
   local st
   st="$(status_of "$id" "$ty")"
   case "$act" in
-    start)
-      [[ "$st" == "running" ]] && {
-        ok "$ty $id läuft bereits."
-        return
-      }
-      if [[ "$ty" == "CT" ]]; then
-        if pct start "$id" >/dev/null 2>&1; then
-          ok "$ty $id gestartet."
-        else
-          err "Start CT $id fehlgeschlagen."
-        fi
+  start)
+    [[ "$st" == "running" ]] && {
+      ok "$ty $id läuft bereits."
+      return
+    }
+    if [[ "$ty" == "CT" ]]; then
+      if pct start "$id" >/dev/null 2>&1; then
+        ok "$ty $id gestartet."
       else
-        if qm start "$id" >/dev/null 2>&1; then
-          ok "$ty $id gestartet."
-        else
-          err "Start VM $id fehlgeschlagen."
-        fi
+        err "Start CT $id fehlgeschlagen."
       fi
-      ;;
-    stop)
-      [[ "$st" != "running" ]] && {
-        ok "$ty $id ist nicht aktiv."
-        return
-      }
-      if [[ "$ty" == "CT" ]]; then
-        if pct stop "$id" >/dev/null 2>&1; then
-          ok "$ty $id gestoppt."
-        else
-          err "Stop CT $id fehlgeschlagen."
-        fi
+    else
+      if qm start "$id" >/dev/null 2>&1; then
+        ok "$ty $id gestartet."
       else
-        if qm stop "$id" >/dev/null 2>&1; then
-          ok "$ty $id gestoppt."
-        else
-          err "Stop VM $id fehlgeschlagen."
-        fi
+        err "Start VM $id fehlgeschlagen."
       fi
-      ;;
-    restart)
-      if [[ "$st" != "running" ]]; then
-        note "$ty $id lief nicht. Starte statt Neustart."
-        do_action "$id" "$ty" start "$name"
-        return
+    fi
+    ;;
+  stop)
+    [[ "$st" != "running" ]] && {
+      ok "$ty $id ist nicht aktiv."
+      return
+    }
+    if [[ "$ty" == "CT" ]]; then
+      if pct stop "$id" >/dev/null 2>&1; then
+        ok "$ty $id gestoppt."
+      else
+        err "Stop CT $id fehlgeschlagen."
       fi
-      if [[ "$ty" == "CT" ]]; then
-        if pct stop "$id" >/dev/null 2>&1 && sleep 1 && pct start "$id" >/dev/null 2>&1; then
-          ok "$ty $id neu gestartet."
-        else
-          err "Restart CT fehlgeschlagen."
-        fi
+    else
+      if qm stop "$id" >/dev/null 2>&1; then
+        ok "$ty $id gestoppt."
       else
-        if qm stop "$id" >/dev/null 2>&1 && sleep 1 && qm start "$id" >/dev/null 2>&1; then
-          ok "$ty $id neu gestartet."
-        else
-          err "Restart VM fehlgeschlagen."
-        fi
+        err "Stop VM $id fehlgeschlagen."
       fi
-      ;;
-    status)
-      if [[ "$ty" == "CT" ]]; then
-        if ! pct status "$id" 2>/dev/null; then
-          err "Status CT $id nicht abrufbar."
-        fi
+    fi
+    ;;
+  restart)
+    if [[ "$st" != "running" ]]; then
+      note "$ty $id lief nicht. Starte statt Neustart."
+      do_action "$id" "$ty" start "$name"
+      return
+    fi
+    if [[ "$ty" == "CT" ]]; then
+      if pct stop "$id" >/dev/null 2>&1 && sleep 1 && pct start "$id" >/dev/null 2>&1; then
+        ok "$ty $id neu gestartet."
       else
-        if ! qm status "$id" 2>/dev/null; then
-          err "Status VM $id nicht abrufbar."
-        fi
+        err "Restart CT fehlgeschlagen."
       fi
-      ;;
-    *) err "Unbekannte Aktion: $act" ;;
+    else
+      if qm stop "$id" >/dev/null 2>&1 && sleep 1 && qm start "$id" >/dev/null 2>&1; then
+        ok "$ty $id neu gestartet."
+      else
+        err "Restart VM fehlgeschlagen."
+      fi
+    fi
+    ;;
+  status)
+    if [[ "$ty" == "CT" ]]; then
+      if ! pct status "$id" 2>/dev/null; then
+        err "Status CT $id nicht abrufbar."
+      fi
+    else
+      if ! qm status "$id" 2>/dev/null; then
+        err "Status VM $id nicht abrufbar."
+      fi
+    fi
+    ;;
+  *) err "Unbekannte Aktion: $act" ;;
   esac
 }
 
@@ -434,7 +434,7 @@
       :
     else
       note "'qm terminal' nicht verfügbar. Fallback 'qm monitor'."
-  qm monitor "$id" || err "Console for VM $id failed."
+      qm monitor "$id" || err "Console for VM $id failed."
     fi
   fi
 }
@@ -445,45 +445,45 @@
   printf '%s' "Auswahl [1-5]: "
   read_line s
   case "$s" in
-    1) [[ "$ty" == "CT" ]] && pct listsnapshot "$id" 2>/dev/null || qm listsnapshot "$id" 2>/dev/null || echo "(keine oder Fehler)" ;;
-    2)
-      printf 'Name: '
-      read_line sn
-      [[ -z "$sn" ]] && {
-        echo "Abbruch."
-        return
-      }
-      if [[ "$ty" == "CT" ]]; then
-        pct snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."
-      else qm snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."; fi
-      ok "Snapshot '$sn' erstellt."
-      ;;
-    3)
-      printf 'Rollback zu Snapshot: '
-      read_line sn
-      [[ -z "$sn" ]] && {
-        echo "Abbruch."
-        return
-      }
-      if [[ "$ty" == "CT" ]]; then
-        pct rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."
-      else qm rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."; fi
-      ok "Rollback auf '$sn' ok."
-      ;;
-    4)
-      printf 'Snapshot löschen: '
-      read_line sn
-      [[ -z "$sn" ]] && {
-        echo "Abbruch."
-        return
-      }
-      if [[ "$ty" == "CT" ]]; then
-        pct delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."
-      else qm delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."; fi
-      ok "Snapshot '$sn' gelöscht."
-      ;;
-    5) : ;;
-    *) err "Ungültig." ;;
+  1) [[ "$ty" == "CT" ]] && pct listsnapshot "$id" 2>/dev/null || qm listsnapshot "$id" 2>/dev/null || echo "(keine oder Fehler)" ;;
+  2)
+    printf 'Name: '
+    read_line sn
+    [[ -z "$sn" ]] && {
+      echo "Abbruch."
+      return
+    }
+    if [[ "$ty" == "CT" ]]; then
+      pct snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."
+    else qm snapshot "$id" "$sn" >/dev/null 2>&1 || err "Snapshot fehlgeschlagen."; fi
+    ok "Snapshot '$sn' erstellt."
+    ;;
+  3)
+    printf 'Rollback zu Snapshot: '
+    read_line sn
+    [[ -z "$sn" ]] && {
+      echo "Abbruch."
+      return
+    }
+    if [[ "$ty" == "CT" ]]; then
+      pct rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."
+    else qm rollback "$id" "$sn" >/dev/null 2>&1 || err "Rollback fehlgeschlagen."; fi
+    ok "Rollback auf '$sn' ok."
+    ;;
+  4)
+    printf 'Snapshot löschen: '
+    read_line sn
+    [[ -z "$sn" ]] && {
+      echo "Abbruch."
+      return
+    }
+    if [[ "$ty" == "CT" ]]; then
+      pct delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."
+    else qm delsnapshot "$id" "$sn" >/dev/null 2>&1 || err "Löschen fehlgeschlagen."; fi
+    ok "Snapshot '$sn' gelöscht."
+    ;;
+  5) : ;;
+  *) err "Ungültig." ;;
   esac
 }
 
@@ -532,27 +532,27 @@
     CLEAR_SCREEN=0
   fi
   case "$MODE" in
-    list)
-      if print_table; then
-        exit 0
-      else
-        exit 1
-      fi
-      ;;
-    json)
-      print_json
+  list)
+    if print_table; then
       exit 0
-      ;;
-    interactive)
-      while true; do
-        main_menu || true
-        ((RUN_ONCE == 1)) && break
-      done
-      ;;
-    *)
-      err "Unbekannter Modus: $MODE"
+    else
       exit 1
-      ;;
+    fi
+    ;;
+  json)
+    print_json
+    exit 0
+    ;;
+  interactive)
+    while true; do
+      main_menu || true
+      ((RUN_ONCE == 1)) && break
+    done
+    ;;
+  *)
+    err "Unbekannter Modus: $MODE"
+    exit 1
+    ;;
   esac
 }
 main "$@"
(exitcode=123)
```

## Heuristic grep (scripts only)
```
$ rg -n --glob '*.sh' 'eval|source'
```

```
$ rg -n --glob '*.sh' 'mktemp|/tmp'
proxmox-manager.sh:498:  local vv="/tmp/vm-${id}.vv"
```

```
$ rg -n --glob '*.sh' 'chmod\s+[0-9]{3}|umask\s+0'
```

```
$ rg -n --glob '*.sh' 'curl\s+.*\|\s*bash|wget\s+.*\|\s*bash'
```

```
$ rg -n --glob '*.sh' 'ssh\s+.*-o\s+StrictHostKeyChecking=no'
```

```
$ rg -n --glob '*.sh' 'addr=0\.0\.0\.0'
proxmox-manager.sh:515:  if qm set "$id" --spice "port=${port},addr=0.0.0.0" >/dev/null 2>&1; then
```

```
$ rg -n --glob '*.sh' '\bsudo\b'
proxmox-manager.sh:6:# - Root-Prüfung, LC_ALL=C, kein sudo
```

```
$ rg -n --glob '*.sh' 'set -euo pipefail|trap'
install_dependencies.sh:5:set -euo pipefail
proxmox-manager.sh:36:trap 'printf "\n%s\n" "Exiting."; exit 0' INT TERM
```

## CI / Workflows
```
$ rg -n --glob '.github/workflows/*' ''
.github/workflows not present
```

## Secrets scan (heuristic)
```
$ gitleaks detect --redact --source . --baseline-path .gitleaks.baseline
gitleaks not found
```

```
$ rg --count-matches -n '(AKIA|ASIA|-----BEGIN|xox[baprs]-|ghp_|gho_|ghu_|github_pat_)'
```
