# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Single-file Bash tool (`proxmox-manager.sh`) wrapping Proxmox CLI tools (`qm`, `pct`) into an interactive TUI or scriptable interface. No build step — the script runs directly on a Proxmox VE host as root.

## Commands

```bash
# Run interactive menu (requires root on Proxmox)
sudo ./proxmox-manager.sh

# Non-interactive / scriptable modes
sudo ./proxmox-manager.sh --list    # plain-text table
sudo ./proxmox-manager.sh --json    # JSON array output

# Linting
shellcheck proxmox-manager.sh

# Tests (no real Proxmox needed)
tests/run.sh
```

## Architecture

**`proxmox-manager.sh`** — the entire tool in one file, structured as:

- `parse_args` / `require_root` / `require_tools` — startup validation. Root check is bypassed when `PROXMOX_MANAGER_ALLOW_NONROOT=1` is set (used in CI/tests).
- `collect_instances` — queries both `pct list` and `qm list`, filters header rows via `is_data_line` (only lines starting with a numeric ID), resolves names via `ct_name_from_config`/`vm_name_from_config` fallbacks, and emits TSV rows (`ID\tTYPE\tSTATUS\tSYMBOL\tNAME`).
- `print_table` / `print_json` — formatting layers over `collect_instances`.
- `main_menu` → `action_menu` → `do_action` / `open_console` / `snapshots_menu` / `spice_info` / `spice_enable` — interactive TUI flow.
- Colors are only emitted on a TTY; `NO_COLOR=1` disables them entirely.
- SPICE bind address defaults to `127.0.0.1`; override via `PROXMOX_MANAGER_SPICE_ADDR`.

**`tests/`** — uses `tests/mock-bin/pct` and `tests/mock-bin/qm` stubs prepended to `$PATH`. Tests exercise `--list` (checks for CT/VM rows) and `--json` (validates JSON structure via `python3 -m json.tool`).

**CI (`.github/workflows/ci.yml`)** — runs `shellcheck -x` on all `.sh` files up to depth 4.

## Conventions

- `set -Eeuo pipefail` and `IFS=$'\n\t'` at top; `export LC_ALL=C` for stable sorting.
- Internal helpers: `have()` for command existence, `err()`/`ok()`/`note()` for colored output.
- `read_line` is used instead of bare `read` to handle IFS safely.
- Commit messages follow conventional format: `type(scope): summary` (e.g., `fix(ct): handle missing hostname`).
- Do not commit generated files, scan outputs (Gitleaks, ShellCheck results), or binary files.
