<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

# 🧰 Proxmox Manager

**Single-file Bash tool for managing Proxmox VMs and containers**

[![CI](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/ci.yml?branch=main&style=for-the-badge&logo=github)](https://github.com/TimInTech/proxmox-manager/actions)
[![Gitleaks](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/gitleaks.yml?branch=main&style=for-the-badge&logo=security)](https://github.com/TimInTech/proxmox-manager/actions)
[![License](https://img.shields.io/github/license/TimInTech/proxmox-manager? style=for-the-badge&color=blue)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![Proxmox VE](https://img.shields.io/badge/Proxmox-VE-orange?style=for-the-badge)](https://www.proxmox.com/)

<img src="https://skillicons.dev/icons?i=linux,bash,debian" alt="Tech Stack" />

</div>
<!-- markdownlint-enable MD033 MD041 -->

---

## 📸 Screenshot

![Proxmox Manager Screenshot](docs/screenshots/Screenshot.png)

---

## 🎯 What It Does

Proxmox Manager is a **single Bash script** that wraps Proxmox CLI tools (`qm`, `pct`) into an interactive menu or scriptable interface. No daemons, no agents, no dependencies beyond what ships with Proxmox VE.

**Core capabilities:**

- List all VMs and containers with status (running, stopped, paused)
- Start, stop, restart instances
- Open console (LXC shell or QEMU terminal)
- Manage snapshots (list, create, rollback, delete)
- Enable and retrieve SPICE connection details for VMs
- Machine-readable JSON output for automation

---

## 🚀 Installation

Run directly on a Proxmox VE host:

```bash
git clone https://github.com/TimInTech/proxmox-manager.git
cd proxmox-manager
chmod +x proxmox-manager. sh
```

No build step.  No package installation. 

---

## 📋 Requirements

**System:**

- Proxmox VE (tested on 7.x and 8.x)
- Bash ≥ 4.0 (included in Proxmox)
- Root privileges (or `PROXMOX_MANAGER_ALLOW_NONROOT=1` for CI overrides)

**CLI tools (bundled with Proxmox):**

- `qm` (VM management)
- `pct` (container management)
- Standard POSIX utilities (`awk`, `sed`, `grep`)

No Python.  No Docker. No external APIs.

---

## 🛠️ Usage

### Interactive mode (default)

```bash
sudo ./proxmox-manager.sh
```

Displays a table of all VMs/containers with status symbols:

- 🟢 running
- 🔴 stopped
- 🟠 paused
- 🟡 unknown

Enter a VMID to open an action menu. Press `r` to refresh, `q` to quit.

### List mode (plain text)

```bash
sudo ./proxmox-manager.sh --list
```

Prints a formatted table.  Useful for logging or quick checks.

### JSON mode (machine-readable)

```bash
sudo ./proxmox-manager.sh --json
```

Outputs VM/CT data as JSON array: 

```json
[
  {"id": 100,"type":"VM","status":"running","symbol":"🟢","name":"web-server"},
  {"id":101,"type":"CT","status":"stopped","symbol":"🔴","name":"db-container"}
]
```

Use with `jq` or automation tools.

### Non-interactive / scripted use

The script is designed for interactive use. For automation, prefer `--list` or `--json` and parse output.

All destructive actions (stop, restart, snapshot rollback) require confirmation in interactive mode.

### Options

```text
--list       Print plain-text table (no TUI)
--json       Print JSON output
--no-clear   Do not clear screen in interactive mode
--once       Run one refresh cycle (useful for recording)
-h, --help   Show usage
```

---

## 🔐 Security

- **Root required:** The script calls `qm`, `pct`, and other Proxmox tools that require elevated privileges. 
- **No credentials stored:** Relies on Proxmox host authentication. 
- **No outbound traffic:** All operations are local.
- **CI hardening:**
  - ShellCheck enforced on all `.sh` files. 
  - Gitleaks scan prevents accidental secret commits.
- **Vulnerability reporting:** See `SECURITY.md` for responsible disclosure.

---

## 🧩 What It Is Not

- **Not a UI replacement:** Use the Proxmox web UI for rich workflows.
- **Not configuration management:** No Terraform/Ansible integration (yet).
- **Not a daemon:** Runs on demand, exits immediately.
- **Not multi-host:** Manages only the local Proxmox node. 

---

## 🧪 CI & Testing

**Automated checks:**

- ShellCheck on every `.sh` file (strict mode:  `SC2086`, `SC2068`, etc.)
- Gitleaks scan for secrets (reports uploaded as artifacts, never committed)
- No generated files or scan outputs in the repository

**Local testing:**

```bash
shellcheck proxmox-manager.sh
```

CI runs on every push and PR. 

---

## 🤝 Contributing

Contributions welcome if they preserve the tool's simplicity. 

**Guidelines:**

1. Fork and create a feature branch: 

   ```bash
   git checkout -b feature/your-change
   ```

2. Keep Bash readable.  Avoid external dependencies.

3. Run ShellCheck locally:

   ```bash
   shellcheck proxmox-manager.sh
   ```

4. Commit with conventional format:

   ```text
   type(scope): summary
   ```

   Examples:  `feat(vm): add suspend action`, `fix(ct): handle missing hostname`

5. Open a Pull Request.

**Do NOT commit:**

- Generated files (logs, reports, artifacts)
- Scan outputs (Gitleaks, ShellCheck results)
- Binary files or large test data

---

## 📜 License

MIT License.  See [LICENSE](LICENSE) for full text.

---

<!-- markdownlint-disable MD033 MD036 -->

<div align="center">

### Boring Proxmox administration, automated ✨

[🐛 Report Bug](https://github.com/TimInTech/proxmox-manager/issues) •
[✨ Request Feature](https://github.com/TimInTech/proxmox-manager/issues)

</div>
<!-- markdownlint-enable MD033 MD036 -->
