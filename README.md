<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

```
╔══════════════════════════════════════════════════════════╗
║  ██████╗ ███╗   ███╗  █████╗  ███╗   ██╗               ║
║  ██╔══██╗████╗ ███║ ██╔══██╗ ████╗  ██║               ║
║  ██████╔╝██╔████╔██║ ███████║ ██╔██╗ ██║               ║
║  ██╔═══╝ ██║╚██╔╝██║ ██╔══██║ ██║╚██╗██║               ║
║  ██║     ██║ ╚═╝ ██║ ██║  ██║ ██║ ╚████║               ║
║  ╚═╝     ╚═╝     ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═══╝  v2.10.0     ║
║                                                          ║
║  Proxmox VM/CT Manager · Single Bash · No Dependencies  ║
╚══════════════════════════════════════════════════════════╝
```

**Single-file Bash tool for managing Proxmox VMs and containers.**
No daemons. No agents. No dependencies beyond what ships with Proxmox VE.

[![CI](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/ci.yml?branch=main&style=for-the-badge&logo=github&label=CI)](https://github.com/TimInTech/proxmox-manager/actions)
[![Gitleaks](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/gitleaks.yml?branch=main&style=for-the-badge&logo=security&label=Gitleaks)](https://github.com/TimInTech/proxmox-manager/actions)
[![License](https://img.shields.io/github/license/TimInTech/proxmox-manager?style=for-the-badge&color=blue)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![Proxmox VE](https://img.shields.io/badge/Proxmox-VE%207%2F8%2F9-orange?style=for-the-badge)](https://www.proxmox.com/)

![Tech Stack](https://skillicons.dev/icons?i=linux,bash,debian)

<a href="https://buymeacoffee.com/timintech" target="_blank" rel="noopener noreferrer"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="50" width="181"></a>

</div>

---

## 📸 Screenshots

<div align="center">

| Main Menu — VM/CT Table | Action Menu |
|:---:|:---:|
| ![Main menu](docs/screenshots/screenshot-tui.png) | ![Action menu](docs/screenshots/screenshot-action-menu.png) |
| Live status for all VMs & containers | Per-instance controls: start, stop, console, snapshots |

</div>

---

## 🎯 Features

| | Feature | Details |
|---|---|---|
| 📋 | **List & Status** | All VMs and containers with live status — `[+]` running · `[-]` stopped · `[~]` paused · `[?]` unknown |
| ⚡ | **Start / Stop / Restart** | Confirmation prompt for destructive actions. Proxmox error details on failure. Configurable timeout with force-stop fallback |
| 🖥️ | **Console Access** | LXC shell via `pct enter` or QEMU terminal via `qm terminal`. Verifies running state before entering |
| 📦 | **Snapshot Management** | List, create, rollback, delete — with name validation and snapshot preview before destructive actions |
| 🖱️ | **SPICE Integration** | Enable SPICE for VMs and retrieve `.vv` connection files. Auto-launches `virt-viewer` when installed |
| 🤖 | **Automation-Ready** | `--json` output, `--filter` by status, `--name` ERE filter, `--force` mode, structured logging via `LOG_FILE` |
| ⚙️ | **Config File** | Persistent defaults via `/etc/pmanrc` or `~/.pmanrc` — CLI flags always win |

---

## 🏗️ How It Works

A single `proxmox-manager.sh` script — no build step, no service, no config files. Runs on-demand as root directly on the Proxmox VE node.

```
  User / Automation
       │
       ▼
  ┌─────────────────────────────────┐
  │  pman  (proxmox-manager.sh)     │
  │                                 │
  │  ┌──────────┐  ┌─────────────┐  │
  │  │ --list   │  │ interactive │  │
  │  │ --json   │  │    TUI      │  │
  │  │ --filter │  │             │  │
  │  └────┬─────┘  └──────┬──────┘  │
  └───────┼───────────────┼─────────┘
          │               │
          ▼               ▼
  ┌───────────────────────────────┐
  │  qm (VMs)  ·  pct (CTs)      │  ← Proxmox CLI (bundled with PVE)
  └───────────────────────────────┘
          │
          ▼
  ┌───────────────────────────────┐
  │  Proxmox VE Host  (local)     │
  │  QEMU Virtual Machines        │
  │  LXC Containers               │
  └───────────────────────────────┘
```

> ✅ No network calls · ✅ No background process · ✅ Bash ≥ 4.0 · ✅ PVE 7.x / 8.x / 9.x

---

## 🚀 Installation

**Requirements:** Proxmox VE host · Bash ≥ 4.0 · Root privileges · `qm` / `pct` (bundled with PVE)

### Step 1 — Clone

```bash
git clone https://github.com/TimInTech/proxmox-manager.git
cd proxmox-manager
```

### Step 2 — Run directly

```bash
chmod +x proxmox-manager.sh
./proxmox-manager.sh
```

### Step 3 — Or register as `pman` system-wide _(optional, requires root)_

```bash
./install_dependencies.sh
```

Installs a symlink to `/usr/local/bin/pman` so you can call `pman` from anywhere on the host.

---

## 🛠️ Usage

| Command | Description |
|---|---|
| `pman` | Interactive TUI — VM/CT table with full action menus |
| `pman --list` | Plain-text table output — useful for logging or quick checks |
| `pman --json` | Machine-readable JSON array for automation & `jq` |
| `pman --filter running` | Filter output by status: `running` \| `stopped` \| `paused` |
| `pman --name web` | Filter by VM/CT name (ERE substring-match; combinable with `--filter`) |
| `pman --force` | Skip all confirmation prompts (for unattended scripts) |
| `pman --timeout 30` | Custom stop timeout in seconds (default: 60) |
| `pman --no-clear` | Don't clear screen in interactive mode |
| `pman --once` | Run a single interactive refresh cycle (useful for TTY recording) |
| `pman --version` | Print version and exit |
| `pman -h, --help` | Show usage information and exit |

### Interactive mode

```
pman
```

Displays a table of all VMs/containers. Enter a VMID to open the action menu.

```
[+] running   [-] stopped   [~] paused   [?] unknown
```

Press `r` to refresh · `q` to quit

### JSON output

```bash
pman --json | jq '.[] | select(.status == "running")'
```

```json
[
  {"id": 100, "type": "VM", "status": "running", "symbol": "[+]", "name": "web-server"},
  {"id": 101, "type": "CT", "status": "stopped", "symbol": "[-]", "name": "db-container"}
]
```

### SPICE remote desktop

The SPICE integration generates a `.vv` connection file for any VM. If [`virt-viewer`](https://virt-manager.org/) is installed, it is launched automatically:

```bash
# Install virt-viewer (Debian / Proxmox host)
apt install virt-viewer
```

When `virt-viewer` is **not** installed, the path to the generated `.vv` file is printed together with the install hint. The SPICE bind address defaults to `127.0.0.1` and can be overridden via `PROXMOX_MANAGER_SPICE_ADDR` (env var or `~/.pmanrc`).

### Configuration

`proxmox-manager` checks the following files at startup (in this order):

| File | Scope |
|---|---|
| `/etc/pmanrc` | System-wide (all users) |
| `~/.pmanrc` | Per-user (overrides system-wide) |

CLI flags are applied last and always win over config file values.

```bash
# ~/.pmanrc — example
STOP_TIMEOUT=120                          # stop timeout in seconds (default: 60)
LOG_FILE="/var/log/proxmox-manager.log"   # structured log file (empty = disabled)
PROXMOX_MANAGER_SPICE_ADDR="192.168.1.10" # SPICE bind address (default: 127.0.0.1)
```

### Shell Completions

```bash
# Bash (system-wide)
sudo cp completions/pman.bash /etc/bash_completion.d/pman

# Zsh
mkdir -p ~/.zsh/completions
cp completions/pman.zsh ~/.zsh/completions/_pman
```

---

## 🔐 Security

- **Root required:** `qm` and `pct` need elevated privileges — there's no workaround.
- **No credentials stored:** Relies entirely on Proxmox host authentication.
- **No outbound traffic:** All operations are local to the node.
- **CI hardening:** ShellCheck on every push · Gitleaks scan for accidental secrets.

---

## 📋 Changelog

### 🆕 [v2.10.0](CHANGELOG.md) — 2026-05-04

| Issue | Change |
|---|---|
| [#21](https://github.com/TimInTech/proxmox-manager/issues/21) | Full Proxmox stderr written to `LOG_FILE`; only first line shown on stdout |
| [#22](https://github.com/TimInTech/proxmox-manager/issues/22) | Config file support: `/etc/pmanrc` and `~/.pmanrc` loaded before CLI flags |
| [#23](https://github.com/TimInTech/proxmox-manager/issues/23) | Numbered snapshot selection for rollback and delete (free-text fallback) |
| [#24](https://github.com/TimInTech/proxmox-manager/issues/24) | `validate_menu_choice()` helper — unified error format for all menu inputs |
| [#25](https://github.com/TimInTech/proxmox-manager/issues/25) | `--name PATTERN` flag — ERE substring filter on VM/CT name, combinable with `--filter` |
| [#26](https://github.com/TimInTech/proxmox-manager/issues/26) | `virt-viewer` auto-launched from SPICE info; fallback hint when not installed |

### [v2.9.0](CHANGELOG.md) — 2026-04-09

> `--filter STATUS` · `--timeout SECS` with force-stop fallback · `--force` mode · 29 unit tests · Bash & Zsh shell completions

**→ [View full CHANGELOG](CHANGELOG.md)**

---

## 🧪 Testing

```bash
# Lint
shellcheck proxmox-manager.sh

# Unit tests (no real Proxmox needed — uses mock stubs)
tests/run.sh
```

29 tests covering `validate_vmid`, `validate_snapshot_name`, `--filter`, and CLI flags.

---

## 🤝 Contributing

Contributions welcome — keep it simple, keep it Bash.

1. Fork & create a feature branch: `git checkout -b feat/your-change`
2. Keep external dependencies at zero. Run `shellcheck` locally.
3. Commit with conventional format: `feat(vm): add suspend action`
4. Open a Pull Request.

**Do not commit:** generated files, scan outputs, binary files, or large test data.

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for full text.

---

<!-- markdownlint-disable MD033 -->
<div align="center">

### Boring Proxmox administration, automated ✨

[🐛 Report Bug](https://github.com/TimInTech/proxmox-manager/issues) ·
[✨ Request Feature](https://github.com/TimInTech/proxmox-manager/issues) ·
[📋 Changelog](CHANGELOG.md)

</div>
