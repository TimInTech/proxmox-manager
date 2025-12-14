<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

# 🧰 Proxmox Manager

## **Simple CLI Helper for Proxmox VE**

[![CI](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/ci.yml?branch=main&style=for-the-badge&logo=github)](https://github.com/TimInTech/proxmox-manager/actions)
[![Gitleaks](https://img.shields.io/github/actions/workflow/status/TimInTech/proxmox-manager/gitleaks.yml?branch=main&style=for-the-badge&logo=security)](https://github.com/TimInTech/proxmox-manager/actions)
[![License](https://img.shields.io/github/license/TimInTech/proxmox-manager?style=for-the-badge&color=blue)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![Proxmox VE](https://img.shields.io/badge/Proxmox-VE-orange?style=for-the-badge)](https://www.proxmox.com/)

<img src="https://skillicons.dev/icons?i=linux,bash,debian" alt="Tech Stack" />

</div>
<!-- markdownlint-enable MD033 MD041 -->

---

## ✨ Features

✅ **Single Bash Script** – no daemon, no agents, no dependencies beyond standard CLI tools  
✅ **Proxmox VE Native** – wraps `qm`, `pct`, and Proxmox APIs where useful  
✅ **Interactive & Scriptable** – usable via menu or flags  
✅ **Safe Defaults** – avoids destructive actions unless explicitly requested  
✅ **CI-Linted** – ShellCheck enforced, secrets scanning enabled  
✅ **Lean by Design** – no generated artifacts, no committed reports  

---

## 📦 Requirements

- **Proxmox VE** (host or management node)
- **Bash** (POSIX-compatible, tested with modern GNU Bash)
- Standard utilities:
  - `pvesh`, `qm`, `pct`
  - `awk`, `sed`, `grep`, `curl`

> No Python, no Docker, no external services required.

---

## ⚡ Quickstart

```bash
git clone https://github.com/TimInTech/proxmox-manager.git
cd proxmox-manager
chmod +x proxmox-manager.sh
sudo ./proxmox-manager.sh
```

That's it. 🎉
The script will guide you interactively.

---

## 🧭 Usage

### Interactive Mode (default)

```bash
sudo ./proxmox-manager.sh
```

Displays a menu for common VM / container management tasks.

### Non-interactive / Scripted

```bash
sudo ./proxmox-manager.sh <command> [options]
```

Run `--help` to see available commands and flags.

---

## 🧩 What This Tool Is (and Is Not)

### ✅ Is

* A **helper** around Proxmox tooling
* Focused on **daily admin tasks**
* Designed to be **readable, auditable Bash**

### ❌ Is Not

* A replacement for Proxmox UI
* A long-running service
* A configuration management system

---

## 🛡️ Security Notes

* Must be run as **root** (or via sudo) to access Proxmox tooling
* No credentials stored
* No outbound network traffic unless explicitly triggered by user actions
* Repository enforces:

  * **ShellCheck** on all shell scripts
  * **Gitleaks** to prevent secret leaks
* Vulnerabilities must be reported **privately** (see `SECURITY.md`)

---

## 🧪 CI & Quality

* **CI**: ShellCheck on all `*.sh`
* **Security**: Gitleaks scan, reports uploaded as artifacts only
* **No committed artifacts** (reports, audit dumps, generated files)

The repository is intentionally kept minimal and clean.

---

## 🤝 Contributing

Contributions are welcome if they keep the project **simple and focused**.

1. Fork the repository
2. Create a branch:

   ```bash
   git checkout -b feature/your-change
   ```
3. Make changes (keep Bash readable!)
4. Run ShellCheck locally if possible
5. Commit and open a Pull Request

Please **do not** commit generated files, reports, or scan outputs.

---

## 📜 License

This project is licensed under the **MIT License**.
See [LICENSE](LICENSE) for details.

---

<!-- markdownlint-disable MD033 MD036 -->

<div align="center">

### Built to keep Proxmox administration boring ✨

[🐛 Report Bug](https://github.com/TimInTech/proxmox-manager/issues) •
[✨ Request Feature](https://github.com/TimInTech/proxmox-manager/issues)

</div>
<!-- markdownlint-enable MD033 MD036 -->
