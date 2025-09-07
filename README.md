# Proxmox VM/CT Management Tool

![Proxmox Console Screenshot](docs/screenshots/proxmox-console.png)

A lightweight terminal user interface (TUI) tool to manage Proxmox VMs and containers via `qm` and `pct`.

---

## ✨ Features

- Clean overview with colored status icons (🟢 running, 🔴 stopped, 🟠 paused)  
- Start / Stop / Restart / Status management  
- Console access (`pct enter`, `qm terminal`, fallback `qm monitor`)  
- Snapshot management: list, create, rollback, delete  
- SPICE integration: show connection info, generate `.vv` viewer files, enable SPICE  
- Built-in permission checks and root validation  
- Works directly on a Proxmox host without extra dependencies  

---

## ⚡ Quick Start

Run as **root** on a Proxmox host:

```bash
apt update && apt install -y git
cd /root
git clone https://github.com/TimInTech/proxmox-manager.git
cd proxmox-manager
chmod +x proxmox-manager.sh install_dependencies.sh
./install_dependencies.sh    # optional: helper tools (e.g. shellcheck, remote-viewer)
./proxmox-manager.sh
````

Optional: make it globally available:

```bash
cp proxmox-manager.sh /usr/local/sbin/proxmox-manager
chmod +x /usr/local/sbin/proxmox-manager
proxmox-manager
```

---

## 📦 Requirements

* Run as `root` on a Proxmox host
* Proxmox CLI tools `qm` and/or `pct` must be available
* For SPICE support: `remote-viewer` (Virt-Viewer) is recommended

---

## 🛠️ How It Works

* Detects VMs and containers via `qm list` and `pct list`
* Resolves container names reliably (handles missing/empty fields)
* Status detection: `running`, `stopped`, `paused`, with fallback handling
* SPICE: automatically provides connection URI (`spice://host:port`) and writes `.vv` files under `/tmp/`

---

## 📌 Roadmap

* Optional JSON/YAML output for automation
* Batch actions (start/stop multiple VMs/CTs)
* Improved error logging
* Packaging for Debian/Proxmox hosts

---

## 🤝 Contributing

Contributions are welcome!
Open an [issue](https://github.com/TimInTech/proxmox-manager/issues) for bug reports or feature requests, or submit a pull request.

---

## 📄 License

MIT License – see [LICENSE](LICENSE).
