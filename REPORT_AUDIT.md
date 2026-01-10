# Proxmox Manager Audit Report

## Executive Summary
- Scope: security, correctness, consistency, maintainability (local repo state)
- Findings: 7 total (2 high, 3 medium, 2 low)
- Fixes: all findings fixed in this branch
- Tests: bash -n, shellcheck, tests/run.sh (mocked qm/pct)

## Threat Model (concise)
- Attackers: local unprivileged user on Proxmox host; remote user on LAN; CI attacker via PR/CI environment.
- Assets: Proxmox node control (qm/pct), VM/CT lifecycle, SPICE endpoints, logs, /tmp, CI tokens.
- Trust boundaries: user input, qm/pct output parsing, filesystem /tmp, network bind address, GitHub Actions environment.

## Repository Inventory
- Reference: reports/phase1_inventory.md
- Entrypoint: proxmox-manager.sh
- Optional dependencies: jq/virt-viewer/shellcheck via install_dependencies.sh
- CI/workflows: .github/workflows not present in current working tree (cannot audit workflows here).

## Findings (verifiable)

### SEC-001 (P0/High) - Insecure temp file creation for SPICE
- File: proxmox-manager.sh:497-518
- Root cause: fixed /tmp path with predictable filename written as root.
- Risk: symlink overwrite / TOCTOU.
- Fix: mktemp with umask 077 and chmod 600.
- Status: fixed (commit d8fb920).
- Tests: tests/run.sh; bash -n; shellcheck.

### SEC-002 (P1/High) - SPICE binds to all interfaces by default
- File: proxmox-manager.sh:521-526
- Root cause: addr=0.0.0.0 default.
- Risk: unintended exposure on LAN.
- Fix: default 127.0.0.1, override via PROXMOX_MANAGER_SPICE_ADDR.
- Status: fixed (commit d8fb920).
- Tests: tests/run.sh; bash -n; shellcheck.

### BUG-003 (P1/Medium) - Snapshot listing uses &&/|| fallthrough
- File: proxmox-manager.sh:443-455
- Root cause: shell short-circuit allows qm listsnapshot to run on CT failures.
- Risk: confusing output and wrong command invocation.
- Fix: explicit if/else by type.
- Status: fixed (commit 2419a52).
- Tests: tests/run.sh; bash -n; shellcheck.

### BUG-004 (P2/Medium) - Bash version drift (local -n requires >=4.3)
- File: proxmox-manager.sh:44-47
- Root cause: nameref used while README states Bash >=4.0.
- Risk: runtime failure on Bash 4.0/4.1/4.2.
- Fix: replace nameref with printf -v.
- Status: fixed (commit 27cf250).
- Tests: tests/run.sh; bash -n; shellcheck.

### BUG-001 (P1/Medium) - README install chmod typo
- File: README.md:49
- Root cause: stray space in filename.
- Fix: correct filename.
- Status: fixed (commit bfd0c22).
- Tests: N/A (docs).

### BUG-002 (P1/Medium) - README says no package install
- File: README.md:52
- Root cause: statement conflicts with install_dependencies.sh.
- Fix: clarify optional helper packages.
- Status: fixed (commit bfd0c22).
- Tests: N/A (docs).

### DOC-SEC-001 (P3/Low) - Security contact placeholder
- File: SECURITY.md:14
- Root cause: placeholder email.
- Fix: replace with real contact.
- Status: fixed (commit bfd0c22).
- Tests: N/A (docs).

## Tests & Validation
- Static analysis logs: reports/phase2_static.md
- Validation logs: reports/phase6_validation.md
- Results: bash -n (exit 0), shellcheck (exit 0), tests/run.sh (exit 0)

## Rollback Instructions
- Revert tests: git revert 6306648
- Revert read_line fix: git revert 27cf250
- Revert snapshot list fix: git revert 2419a52
- Revert SPICE security changes: git revert d8fb920
- Revert docs updates: git revert bfd0c22

## Notes / Limitations
- Local working tree already had staged deletions of .github/workflows and other artifacts before this audit; no destructive cleanup was performed.
- If CI workflows are expected, restore them from upstream before re-enabling CI enforcement.
