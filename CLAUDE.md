# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Single-file Bash tool (`proxmox-manager.sh`) wrapping Proxmox CLI tools (`qm`, `pct`) into an interactive TUI or scriptable interface. No build step — the script runs directly on a Proxmox VE host as root.

## Commands

```bash
# Run interactive menu (requires root on Proxmox)
pman                            # global shorthand (after install_dependencies.sh)
sudo ./proxmox-manager.sh

# Non-interactive / scriptable modes
sudo ./proxmox-manager.sh --list       # plain-text table
sudo ./proxmox-manager.sh --json       # JSON array output
sudo ./proxmox-manager.sh --version    # print version and exit

# Linting
shellcheck proxmox-manager.sh

# Tests (no real Proxmox needed — 8 tests via mock-bin/ stubs)
tests/run.sh
```

## Architecture

**`proxmox-manager.sh`** — the entire tool in one file (v2.8.3), structured as:

- `parse_args` / `require_root` / `require_tools` — startup validation. Root check bypassed when `PROXMOX_MANAGER_ALLOW_NONROOT=1` (CI/tests).
- `validate_vmid()` — rejects non-numeric or out-of-range (1–999999) VMIDs before any Proxmox call.
- `validate_snapshot_name()` — rejects snapshot names that Proxmox would refuse (must start with `[a-zA-Z0-9]`, only `[a-zA-Z0-9_-]`, max 40 chars); called before any snapshot Proxmox call.
- `collect_instances` — queries `pct list` and `qm list`, filters header rows via `is_data_line`, resolves names via `ct_name_from_config`/`vm_name_from_config` fallbacks, emits TSV rows (`ID\tTYPE\tSTATUS\tSYMBOL\tNAME`). Status symbols are ASCII: `[+]` running, `[-]` stopped, `[~]` paused, `[?]` unknown.
- `print_table` / `print_json` — formatting layers over `collect_instances`. `print_table` appends a colour-coded count line (`Count: N running  M stopped`) after the status legend.
- `_status_color()` — centralises status→colour mapping; used by `print_table` and `action_menu`.
- `confirm()` — y/N prompt (printed in yellow) used before all destructive actions (stop, restart, snapshot rollback/delete).
- `log()` — optional structured logging (`[YYYY-MM-DD HH:MM:SS] [LEVEL] message`) to `$LOG_FILE` when set; called internally by `err()`/`ok()`/`note()`.
- `_script_version()` — reads version from the header comment (single source of truth).
- `main_menu` → `action_menu` → `do_action` / `open_console` / `snapshots_menu` / `spice_info` / `spice_enable` — interactive TUI flow. `open_console` checks that a CT is running before calling `pct enter`; prints a clear error and returns early if not. `do_action` captures Proxmox stderr on start/stop/restart failure and displays up to 3 lines as a `note` instead of silently discarding it.
- `header()` — displays node hostname, PVE version (`pveversion`), and system uptime (`uptime -p`) when available.
- Colors are only emitted on a TTY; `NO_COLOR=1` disables them entirely. `YELLOW` is available in addition to the original palette.
- SPICE bind address defaults to `127.0.0.1`; override via `PROXMOX_MANAGER_SPICE_ADDR`. VMID is cast with `10#$id` before arithmetic to avoid octal misinterpretation.

**`tests/`** — uses `tests/mock-bin/pct` and `tests/mock-bin/qm` stubs prepended to `$PATH`. 8 tests covering `--list`, `--json`, `--help`, `--version`, and `--once`. Uses portable `grep` (not `ripgrep`).

**CI (`.github/workflows/ci.yml`)** — runs `shellcheck -x` on all `.sh` files up to depth 4.

## Conventions

- `set -Eeuo pipefail` and `IFS=$'\n\t'` at top; `export LC_ALL=C` for stable sorting.
- Internal helpers: `have()` for command existence, `err()`/`ok()`/`note()` for colored output, `confirm()` for y/N prompts, `log()` for optional file logging.
- `read_line` is used instead of bare `read` to handle IFS safely.
- Commit messages follow conventional format: `type(scope): summary` (e.g., `fix(ct): handle missing hostname`).
- Do not commit generated files, scan outputs (Gitleaks, ShellCheck results), or binary files.
