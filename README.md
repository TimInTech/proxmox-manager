# Proxmox VM/CT Manager – Version 2.7.2 (updated 2025-09-07)

<p align="center"><em>Terminal tool to manage Proxmox VMs and containers from the host shell</em></p>

<p align="center">
  <a href="https://github.com/TimInTech/timintech-proxmox-manager/stargazers"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/TimInTech/timintech-proxmox-manager?style=flat&color=yellow"></a>
  <a href="https://github.com/TimInTech/timintech-proxmox-manager/network/members"><img alt="GitHub Forks" src="https://img.shields.io/github/forks/TimInTech/timintech-proxmox-manager?style=flat&color=blue"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/TimInTech/timintech-proxmox-manager?style=flat"></a>
  <a href="https://buymeacoffee.com/timintech"><img alt="Buy Me A Coffee" src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?logo=buymeacoffee&logoColor=000&labelColor=555555&style=flat"></a>
</p>

---

## Quick Links
- Main script: [`proxmox-manager.sh`](proxmox-manager.sh)
- Optional helper: [`install_dependencies.sh`](install_dependencies.sh)
- Project overview: [Quickstart](#quickstart) · [Usage](#usage) · [CLI Options](#cli-options) · [Troubleshooting](#troubleshooting)
- Audit artefacts: [`.audit/`](.audit/)
- Issues & feedback: [Create issue](../../issues)

---

## ✅ Requirements
- Proxmox VE 7.4, 8.x, or 9.x host
- Run directly on the Proxmox node as `root`
- `qm` and/or `pct` CLI tools available on the host
- Optional helpers: `remote-viewer` for SPICE, `jq` for utilities, `shellcheck` for linting

---

## Introduction
This repository contains a lightweight terminal UI script that lists and manages both VMs and LXC containers on a Proxmox host. It provides status-aware actions, console access, snapshot helpers, and SPICE integration without depending on external services.

> The script targets interactive use on the Proxmox host itself.

---

## Technologies & Dependencies
![Proxmox VE](https://img.shields.io/badge/Proxmox-VE-EE7F2D?logo=proxmox&logoColor=white&style=flat)
![Debian](https://img.shields.io/badge/Debian-11--13-A81D33?logo=debian&logoColor=white&style=flat)
![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white&style=flat)
![Bash](https://img.shields.io/badge/Bash-✔-4EAA25?logo=gnubash&logoColor=white&style=flat)
![systemd](https://img.shields.io/badge/systemd-✔-FFDD00?logo=linux&logoColor=black&style=flat)
![SPICE](https://img.shields.io/badge/SPICE-✔-CC0000?logo=redhat&logoColor=white&style=flat)
![virt-viewer](https://img.shields.io/badge/Virt--Viewer-✔-555555?style=flat)
![jq](https://img.shields.io/badge/jq-✔-3E6E93?style=flat)
![ShellCheck](https://img.shields.io/badge/ShellCheck-✔-4B9CD3?style=flat)

---

## 📊 Status
Stable for day-to-day VM and LXC management on the host shell.

---

## Quickstart

### Installation

```bash
apt update && apt install -y git
cd /root
git clone https://github.com/TimInTech/timintech-proxmox-manager.git
cd timintech-proxmox-manager
chmod +x proxmox-manager.sh install_dependencies.sh
./install_dependencies.sh   # optional: remote-viewer, jq, shellcheck
```

### Run

```bash
./proxmox-manager.sh
```

Optional system-wide install:

```bash
cp proxmox-manager.sh /usr/local/sbin/proxmox-manager
chmod +x /usr/local/sbin/proxmox-manager
proxmox-manager
```

---

## Features
- Unified VM and CT overview with status symbols: 🟢 running · 🔴 stopped · 🟠 paused · 🟡 unknown
- Actions: start, stop, restart, and status for each ID
- Console helpers: `pct enter`, `qm terminal`, or fallback `qm monitor`
- Snapshot helpers: list, create, rollback, delete snapshots
- SPICE tools: connection details, `.vv` file generation, optional SPICE enablement
- Built-in root check, locale normalization, and resilient ID parsing

---

## Usage
- Launch the script as `root` directly on the Proxmox host.
- Select a VMID/CTID to access action menus for lifecycle operations, console access, and SPICE utilities.
- Use `r` to refresh the overview and `q` to exit at any time.
- To avoid screen clearing in constrained terminals, run with `--no-clear`.

---

## CLI Options
- `--list`: Print a single, plain-text overview of every VM/CT with the emoji legend above the table.
- `--json`: Emit a machine-readable JSON array (`id`, `type`, `status`, `symbol`, `name`) for automation.
- `--no-clear`: Skip terminal clears even in interactive mode; useful for logs or screen sessions.
- `--once`: Run the interactive overview exactly once and exit.
- `--help`: Show usage information and exit.

---

## SPICE Notes
- `remote-viewer` (virt-viewer) offers the best experience for `.vv` files.
- If a VM lacks a SPICE device, the helper can add one; restart the VM afterwards.
- Ports fall back to detected defaults when Proxmox has not yet assigned one.

---

## Troubleshooting
- **No entries listed:** Ensure execution on the Proxmox host as `root` with `qm`/`pct` available.
- **Console unavailable:** `qm terminal` requires a serial console; use the fallback `qm monitor`.
- **Missing SPICE port:** Configure SPICE in the VM or enable it via the built-in helper.
- **JSON tooling missing:** The JSON output is generated without external dependencies; `jq` is optional for consuming it.

---

## Contributing
Pull requests and issues are welcome. Please run `shellcheck` locally to keep lint clean.

---

## License
[MIT](LICENSE)
