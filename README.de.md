# proxmox-manager

Languages: 🇬🇧 [English](README.md) • 🇩🇪 Deutsch (diese Datei)

![TUI – Proxmox VM/CT Management Tool](docs/screenshots/Screenshot.png)

*TUI-Übersicht mit VM/CT-Status, Aktionen und JSON-Export.*

## Zweck
Schlankes TUI-Tool zum Auflisten, Steuern und Inspizieren von Proxmox VMs/CTs. JSON-Modus für Automatisierung.

## Installation (mit Git, updatefähig)
```bash
sudo apt update && sudo apt install -y git
cd /root
git clone --depth=1 https://github.com/TimInTech/proxmox-manager.git
cd proxmox-manager
chmod +x proxmox-manager.sh install_dependencies.sh
./install_dependencies.sh    # optional (jq, remote-viewer, shellcheck)
./proxmox-manager.sh         # interaktiv
./proxmox-manager.sh --json  # maschinenlesbar
```

<details><summary>SSH-Variante (falls GitHub-SSH-Keys vorhanden)</summary>
git clone --depth=1 git@github.com:TimInTech/proxmox-manager.git

</details>

Hinweis: Wenn Git nach Zugangsdaten fragt, war meist eine falsche/private URL im Spiel. Obige öffentliche URL nutzen.

Update (Git-Variante)
cd /root/proxmox-manager
git pull

Installation (ohne Git)
cd /root
mkdir -p proxmox-manager && cd proxmox-manager
curl -fsSL -o proxmox-manager.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/proxmox-manager.sh
curl -fsSL -o install_dependencies.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/install_dependencies.sh
chmod +x proxmox-manager.sh install_dependencies.sh
./install_dependencies.sh    # optional
./proxmox-manager.sh

Update (ohne-Git)
cd /root/proxmox-manager
curl -fsSL -o proxmox-manager.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/proxmox-manager.sh
curl -fsSL -o install_dependencies.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/install_dependencies.sh
chmod +x proxmox-manager.sh install_dependencies.sh

Abhängigkeiten

jq empfohlen für --json

remote-viewer (Paket: virt-viewer) optional für VM-Konsole

Ausführung meist als root auf PVE-Hosts

Deinstallieren

Programmpfad entfernen:

rm -rf /root/proxmox-manager


Optionale Abhängigkeiten rückgängig machen:

sudo apt purge -y jq virt-viewer shellcheck
sudo apt autoremove -y

Lizenz

MIT

