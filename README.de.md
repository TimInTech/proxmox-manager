# proxmox-manager

Proxmox VM/CT Manager – Version 2.7.2 (aktualisiert 2025-09-07)

<!-- markdownlint-disable MD013 -->
<p align="center"><em>Terminal-Tool zur Verwaltung von Proxmox-VMs und -Containern direkt auf dem Host</em></p>

<!-- markdownlint-disable-next-line MD013 -->
Languages: 🇬🇧 [English](README.md) • 🇩🇪 Deutsch (diese Datei)

<p align="center">
  <a href="https://github.com/TimInTech/timintech-proxmox-manager/stargazers"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/TimInTech/timintech-proxmox-manager?style=flat&color=yellow"></a>
  <a href="https://github.com/TimInTech/timintech-proxmox-manager/network/members"><img alt="GitHub Forks" src="https://img.shields.io/github/forks/TimInTech/timintech-proxmox-manager?style=flat&color=blue"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/TimInTech/timintech-proxmox-manager?style=flat"></a>
  <a href="https://buymeacoffee.com/timintech"><img alt="Buy Me A Coffee" src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?logo=buymeacoffee&logoColor=000&labelColor=555555&style=flat"></a>
</p>
<!-- markdownlint-enable MD013 -->

![TUI – Proxmox VM/CT Management Tool](docs/screenshots/Screenshot.png)

---
*TUI-Übersicht mit VM/CT-Status, Aktionen und JSON-Export.*

## Schnellzugriff

- Hauptskript: [`proxmox-manager.sh`](proxmox-manager.sh)
- Optionale Helfer: [`install_dependencies.sh`](install_dependencies.sh)
- Projektüberblick:
  [Schnellstart](#schnellstart) ·
  [Voraussetzungen](#voraussetzungen) ·
  [Einführung](#einführung) ·
  [Technologien & Abhängigkeiten](#technologien--abhängigkeiten) ·
  [Status](#status) ·
  [Abhängigkeiten](#abhängigkeiten) ·
  [Funktionen](#funktionen) ·
  [CLI-Optionen](#cli-optionen) ·
  [Deinstallation](#deinstallation) ·
  [Fehlersuche](#fehlersuche)
- Audit-Artefakte: [`.audit/`](.audit/)
- Issues & Feedback: [Issue erstellen](../../issues)

---

## Was ist das

Kompaktes TUI-Werkzeug zum Auflisten, Steuern und Inspizieren von
Proxmox-VMs/CTs. JSON-Modus für Automatisierung.

---

## Installation (mit Git, aktualisierbar)

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

## Voraussetzungen

- Proxmox VE 7.4, 8.x oder 9.x Host
- Direkter Betrieb auf dem Proxmox-Knoten als `root`
- `qm`- und/oder `pct`-CLI-Werkzeuge müssen verfügbar sein
- Optionale Helfer: `remote-viewer` für SPICE, `jq` für Hilfsfunktionen,
  `shellcheck` zum Linting

<details><summary>SSH-Klon (mit GitHub-SSH-Keys)</summary>

```bash
git clone --depth=1 git@github.com:TimInTech/proxmox-manager.git
```

</details>

---

## Einführung

Dieses Repository enthält ein leichtgewichtiges Terminal-TUI, das VMs und
LXC-Container auf einem Proxmox-Host auflistet und verwaltet. Es bietet
statusabhängige Aktionen, Konsolen-Zugriff, Snapshot-Helfer sowie
SPICE-Integration – ohne zusätzliche Dienste.

*Hinweis:* Wenn Git nach Benutzername/Passwort fragt, wurde meist eine falsche
oder private URL genutzt. Die oben genannte öffentliche URL verwenden.

> Das Skript ist für die interaktive Nutzung direkt auf dem Proxmox-Host konzipiert.

---

### Update (Git-Variante)

```bash
cd /root/proxmox-manager
git pull
```

## Technologien & Abhängigkeiten

<!-- markdownlint-disable MD013 -->
![Proxmox VE](https://img.shields.io/badge/Proxmox-VE-EE7F2D?logo=proxmox&logoColor=white&style=flat)
![Debian](https://img.shields.io/badge/Debian-11--13-A81D33?logo=debian&logoColor=white&style=flat)
![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white&style=flat)
![Bash](https://img.shields.io/badge/Bash-✔-4EAA25?logo=gnubash&logoColor=white&style=flat)
![systemd](https://img.shields.io/badge/systemd-✔-FFDD00?logo=linux&logoColor=black&style=flat)
![SPICE](https://img.shields.io/badge/SPICE-✔-CC0000?logo=redhat&logoColor=white&style=flat)
![virt-viewer](https://img.shields.io/badge/Virt--Viewer-✔-555555?style=flat)
![jq](https://img.shields.io/badge/jq-✔-3E6E93?style=flat)
![ShellCheck](https://img.shields.io/badge/ShellCheck-✔-4B9CD3?style=flat)
<!-- markdownlint-enable MD013 -->

---

## Status

Stabil für die tägliche Verwaltung von VMs und LXC direkt auf dem Host.

---

## Schnellstart

### Installation

```bash
apt update && apt install -y git
```

### Installation (ohne Git)

```bash
cd /root
mkdir -p proxmox-manager && cd proxmox-manager
curl -fsSL -o proxmox-manager.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/proxmox-manager.sh
curl -fsSL -o install_dependencies.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/install_dependencies.sh
chmod +x proxmox-manager.sh install_dependencies.sh
./install_dependencies.sh   # optional: remote-viewer, jq, shellcheck
```

### Ausführen

```bash
./proxmox-manager.sh
```

### Optional systemweiter Einsatz

```bash
cp proxmox-manager.sh /usr/local/sbin/proxmox-manager
chmod +x /usr/local/sbin/proxmox-manager
proxmox-manager
```

### Update (ohne Git)

```bash
cd /root/proxmox-manager
curl -fsSL -o proxmox-manager.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/proxmox-manager.sh
curl -fsSL -o install_dependencies.sh https://raw.githubusercontent.com/TimInTech/proxmox-manager/main/install_dependencies.sh
chmod +x proxmox-manager.sh install_dependencies.sh
```

## Abhängigkeiten

- `jq` empfohlen für `--json`
- `remote-viewer` (Paket: `virt-viewer`) optional für VM-Konsolen
- Üblicherweise als `root` auf Proxmox-Hosts ausführen

## Funktionen

- Einheitliche Übersicht von VMs und CTs mit Status-Symbolen: 🟢 running · 🔴
  stopped · 🟠 paused · 🟡 unknown
- Aktionen: Start, Stop, Restart und Status pro ID
- Konsolen-Helfer: `pct enter`, `qm terminal` oder Fallback `qm monitor`
- Snapshot-Helfer: auflisten, erstellen, Rollback, löschen
- SPICE-Tools: Verbindungsdetails, `.vv`-Datei, optionale Aktivierung
- Eingebaute Root-Prüfung, Locale-Normalisierung und robuste ID-Verarbeitung

---

## CLI-Optionen

- `--list` – gibt eine einfache Tabelle aller VMs/CTs aus
- `--json` – liefert ein JSON-Array (`id`, `type`, `status`, `symbol`, `name`)
- `--no-clear` – deaktiviert das Bildschirm-Löschen
- `--once` – einmalige Ausführung und anschließend Beenden
- `--help` – zeigt die Hilfe an und beendet

---

## Deinstallation

Programmpfad entfernen:

```bash
rm -rf /root/proxmox-manager
```

Optionale Pakete wieder entfernen:

```bash
sudo apt purge -y jq virt-viewer shellcheck
sudo apt autoremove -y
```

---

## SPICE-Hinweise

- `remote-viewer` (virt-viewer) bietet die beste Erfahrung für `.vv`-Dateien.
- Fehlt ein SPICE-Gerät, kann der Helfer eines hinzufügen; anschließend VM neu
  starten.

---

## Fehlersuche

- **Keine Einträge:** als `root` ausführen und sicherstellen, dass `qm`/`pct`
  verfügbar sind
- **Konsole nicht verfügbar:** `qm terminal` benötigt eine serielle Konsole;
  Fallback `qm monitor`
- **SPICE-Port fehlt:** konfigurieren oder über den Helfer aktivieren
- **JSON-Probleme:** Ausgabe ist eigenständig nutzbar, `jq` optional zum
  Auswerten

---

## Mitwirken

Pull Requests und Issues sind willkommen. Vor dem Commit `shellcheck` lokal ausführen.

---

## Lizenz

[MIT](LICENSE)
