# Proxmox VM/CT Management Tool

A lightweight TUI helper to list & manage Proxmox VMs/containers via `qm`/`pct`.

## Features
- Robust listing (names with spaces supported)
- Start / Stop / Restart / Status
- Open console (`pct enter`, `qm terminal` → fallback `qm monitor`)
- Snapshot management (list / create / rollback / delete)
- SPICE info + `.vv` file generation, enable SPICE
- Permission checks, clear TUI

## Quick start (on a Proxmox node)
```bash
apt update && apt install -y git
cd /root && git clone git@github.com:TimInTech/proxmox-manager.git
cd proxmox-manager
chmod +x proxmox-manager.sh install_dependencies.sh
./install_dependencies.sh    # optional helpers (shellcheck, remote-viewer, etc.)
./proxmox-manager.sh
```

Notes

Run as root on a Proxmox node (needs qm and/or pct)

SPICE: tool shows spice://HOST:PORT and writes /tmp/vm-<id>.vv

CI: ShellCheck workflow lints the script on push/PR
