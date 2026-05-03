<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

```
╔══════════════════════════════════════════════════════════╗
║  ██████╗ ███╗   ███╗  █████╗  ███╗   ██╗               ║
║  ██╔══██╗████╗ ███║ ██╔══██╗ ████╗  ██║               ║
║  ██████╔╝██╔████╔██║ ███████║ ██╔██╗ ██║               ║
║  ██╔═══╝ ██║╚██╔╝██║ ██╔══██║ ██║╚██╗██║               ║
║  ██║     ██║ ╚═╝ ██║ ██║  ██║ ██║ ╚████║               ║
║  ╚═╝     ╚═╝     ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═══╝  v2.9.0      ║
║                                                          ║
║  Proxmox VM/CT Manager · Single Bash · No Dependencies  ║
╚══════════════════════════════════════════════════════════╝
```

**Single-file Bash tool for managing Proxmox VMs and containers.**  
No daemons. No agents. No dependencies beyond what ships with Proxmox VE.

<br/>

[![CI](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/ci.yml?branch=main&style=flat-square&logo=github&label=CI)](https://github.com/TimInTech/proxmox-manager/actions)
[![Gitleaks](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/gitleaks.yml?branch=main&style=flat-square&logo=shield&label=Secrets)](https://github.com/TimInTech/proxmox-manager/actions)
[![License](https://img.shields.io/github/license/TimInTech/proxmox-manager?style=flat-square&color=blue)](LICENSE)
[![Release](https://img.shields.io/github/v/release/TimInTech/proxmox-manager?style=flat-square&color=6e40c9)](https://github.com/TimInTech/proxmox-manager/releases)

[![Shell](https://img.shields.io/badge/Bash-4.0%2B-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Proxmox VE](https://img.shields.io/badge/Proxmox-VE%207%2F8%2F9-E57000?style=flat-square&logo=proxmox&logoColor=white)](https://www.proxmox.com/)
[![Platform](https://img.shields.io/badge/platform-Proxmox%20VE-blue?style=flat-square)](https://www.proxmox.com/)

[![Buy Me A Coffee](https://img.shields.io/badge/☕%20Buy%20me%20a%20coffee-ffdd00?style=flat-square&logoColor=black)](https://buymeacoffee.com/timintech)

<br/>

![Tech Stack](https://skillicons.dev/icons?i=linux,bash,debian)

</div>

---

## 📸 Screenshot

![Proxmox Manager Screenshot](docs/screenshots/Screenshot.png)

---

## 🎯 What It Does

Proxmox Manager wraps `qm` and `pct` into an interactive menu or scriptable CLI — no daemons, no agents, no extra packages.

| Feature | Details |
|---|---|
| 📋 **List VMs & CTs** | Status overview: running, stopped, paused |
| ⚡ **Start / Stop / Restart** | Confirmation prompt for destructive actions |
| 🖥️ **Console access** | LXC shell or QEMU terminal |
| 📷 **Snapshot management** | List, create, rollback, delete |
| 🔌 **SPICE support** | Enable and retrieve connection details |
| 📤 **Automation output** | JSON and plain-text modes |
| 📝 **Structured logging** | Via `LOG_FILE` environment variable |

---

## 🚀 Installation

```bash
git clone https://github.com/TimInTech/proxmox-manager.git
cd proxmox-manager
chmod +x proxmox-manager.sh
```

**Optional: install system-wide as `pman`** (requires root):

```bash
./install_dependencies.sh
```

```bash
pman             # interactive menu
pman --list      # plain-text table of all VMs/CTs
pman --json      # machine-readable JSON output
pman --version   # print version and exit
```

---

## 📋 Requirements

**System:** Proxmox VE 7.x / 8.x / 9.x · Bash ≥ 4.0 · Root privileges

**Bundled CLI tools:** `qm` · `pct` · `awk` · `sed` · `grep`

> No Python. No Docker. No external APIs.

---

## 🛠️ Usage

### Interactive mode

```bash
pman
```

Status symbols in the VM/CT table:

```
[+] running   [-] stopped   [~] paused   [?] unknown
```

Enter a VMID to open the action menu. Press `r` to refresh, `q` to quit.

### CLI options

```text
--list                  Plain-text table (no TUI)
--json                  Machine-readable JSON output
--filter <status>       Filter: running | stopped | paused
--timeout <seconds>     Stop timeout in seconds (default: 60)
--force                 Skip confirmation prompts
--no-clear              Do not clear screen
--once                  Single refresh cycle
--version               Print version and exit
-h, --help              Show usage
```

### JSON output

```json
[
  {"id":100,"type":"VM","status":"running","symbol":"[+]","name":"web-server"},
  {"id":101,"type":"CT","status":"stopped","symbol":"[-]","name":"db-container"}
]
```

### Shell completions

<details>
<summary><b>Bash</b></summary>

```bash
# System-wide
sudo cp completions/pman.bash /etc/bash_completion.d/pman

# Per user (~/.bashrc)
source /path/to/proxmox-manager/completions/pman.bash
```

</details>

<details>
<summary><b>Zsh</b></summary>

```bash
mkdir -p ~/.zsh/completions
cp completions/pman.zsh ~/.zsh/completions/_pman
echo 'fpath=(~/.zsh/completions $fpath)' >> ~/.zshrc
echo 'autoload -Uz compinit && compinit' >> ~/.zshrc
```

</details>

---

## 🔐 Security

- **Root required** — calls `qm`, `pct` and other Proxmox tools
- **No credentials stored** — relies on Proxmox host authentication
- **No outbound traffic** — fully local operation
- **CI hardening** — ShellCheck + Gitleaks on every push
- **Vulnerability reporting** — see `SECURITY.md`

---

## 🧪 CI & Testing

```bash
shellcheck proxmox-manager.sh          # lint
tests/run.sh                           # 8 tests via mock-bin/ stubs
```

CI runs on every push and PR via GitHub Actions.

---

## 🤝 Contributing

1. Fork and create a feature branch: `git checkout -b feat/your-change`
2. Keep Bash readable — avoid external dependencies
3. Run `shellcheck proxmox-manager.sh` before committing
4. Use conventional commits: `feat(vm): add suspend action`
5. Open a Pull Request

**Do not commit:** logs, reports, scan outputs, binaries, large test data.

---

## 🧩 Scope & Limitations

| ✅ Does | ❌ Does not |
|---|---|
| Interactive TUI + scriptable CLI | Replace the Proxmox web UI |
| VM & CT lifecycle management | Multi-host / cluster support |
| Snapshot operations | Terraform / Ansible integration |
| JSON output for automation | Run as a daemon |

---

## 📜 License

MIT — see [LICENSE](LICENSE).

---

<!-- markdownlint-disable MD033 MD036 -->
<div align="center">

*Boring Proxmox administration, automated ✨*

[🐛 Report Bug](https://github.com/TimInTech/proxmox-manager/issues) · [✨ Request Feature](https://github.com/TimInTech/proxmox-manager/issues) · [☕ Buy me a coffee](https://buymeacoffee.com/timintech)

</div>
<!-- markdownlint-enable MD033 MD036 -->
