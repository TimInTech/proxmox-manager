# Proxmox Manager

**Sprache: [English](README.md) | Deutsch**

Proxmox Manager verwaltet Proxmox-VMs und -Container mit einem eigenständigen
Bash-Skript. Die optionale Speicher- und Wartungsoberfläche verwendet Python 3
und die Standardbibliothek; der Bash-Kern kann ohne sie installiert werden. Die
vollständige Befehls- und Konfigurationsreferenz steht im [englischen README](README.md).

<p align="center">
  <img src="docs/demo/out/proxmox-manager-demo.gif" alt="Proxmox Manager Live Demo" width="820">
</p>

<p align="center">
  <em>Deterministische, lesende Konsolen-Demo: VM/CT-Übersicht, Health-Diagnose, Host-Wartung & Helper-Scripts (Community).</em><br>
  <small>Headless PTY-Pipeline mit In-Stream-Pseudonymisierung · <a href="docs/demo/index.html">Interaktiver Web-Vektor-Player ▶</a> · <a href="docs/demo/README.md">Pipeline-Details →</a></small>
</p>

## Installation

Auf einem Proxmox-Host als Administrator aus einem passenden Checkout:

```bash
git clone https://github.com/TimInTech/proxmox-manager.git
cd proxmox-manager
./install_dependencies.sh
```

Der Installer fragt interaktiv nach dem optionalen Modul und installiert ohne
Terminal standardmäßig nur den Kern. Zur ausdrücklichen Installation des Moduls:

```bash
./install_dependencies.sh --with-maintenance
pman --maintenance
```

Der Installer installiert keine zusätzlichen APT-Pakete. Für die Oberfläche ist
Python 3.9 oder neuer mit `curses` sowie ein UTF-8-Terminal erforderlich.

## Wartungsoberfläche

`M` oder `m` öffnet im Hauptmenü die Host-Wartung; im Aktionsmenü eines Gastes
öffnet dieselbe Taste die Wartung für genau den gewählten CT oder die VM.
Pfeiltasten wählen eine Aktion, Enter startet eine Diagnose oder öffnet Details.
Bild auf/ab blättert die Ausgabe, Esc führt zurück oder bricht eine Bestätigung
ab, und `q` beendet die
Ansicht. `Tab` wechselt beim CT den Scanpfad. Die Anzeige passt sich dem Terminal
an und berücksichtigt `NO_COLOR`.

**Host-Wartungsmenü**

<p align="center">
  <img src="docs/screenshots/screenshot-maintenance-menu.png"
       alt="Host-Wartungsmenü des Proxmox Managers mit Speicher-, SMART- und TRIM-Diagnosen"
       width="720">
</p>

Die eigenen Adapter zeigen unter anderem Storage, Dateisysteme und SMART-Daten.
CT und VM bieten ausschließlich auf den gewählten Gast bezogene Diagnosen und
bestätigungspflichtiges TRIM; für Debian-/Ubuntu-CTs ist auch eine Bereinigung
des APT-Paketcache verfügbar. Gestoppte Gäste werden nicht automatisch gestartet.
Jede Änderung verlangt eine eigene Bestätigung; `--force` umgeht sie nicht.
Ein Abbruch laufender Änderungen ist kein Rollback.

Das Host-Menü enthält außerdem die **Proxmox VE Helper-Scripts (Community)**
(<https://community-scripts.org>, MIT-Lizenz, Repository
`community-scripts/ProxmoxVE`). Acht ausgewählte Werkzeuge laufen als fremder
Code, der weder von pman noch von Proxmox stammt, mit eigenen interaktiven
Dialogen; sie können Host-Einstellungen oder dort ausgewählte Gäste ändern. Die
Werkzeuge sind nach Absicht gruppiert, und jedes trägt seine Gefahrenstufe als
Text: `[LESEN]` (Diagnose; Disk Health installiert nur auf Nachfrage Pakete), `[ÄNDERT]` (verändert Host oder Gäste) oder
`[LÖSCHT]` (entfernt Daten oder Pakete, kein Papierkorb); Farbe ist nur ein
zusätzlicher Hinweis. Vor dem Bestätigungsschirm prüft das Modul den aktuellen
Upstream und lädt die festgelegte Revision herunter. Der Schirm zeigt die genaue
Quell-URL, den Befehl, den Hinweis „läuft als root auf diesem Host“ sowie
Revision und Prüfsumme. Mit `v` lässt sich das geprüfte Skript ansehen; nach `j`
werden genau diese Bytes gestartet. Die Prüfung wird unmittelbar vor dem Start
wiederholt. Geänderte, fehlende oder nicht erreichbare Quellen verhindern den
Start; die Meldung nennt dann die Datei sowie geprüfte und aktuelle Revision.
Die Prüfung und die Downloads können bei Zeitlimits im ungünstigsten Fall etwa
eine Minute dauern; die Oberfläche ist währenddessen blockiert. Die optionale
Upstream-Telemetrie wird nicht bereitgestellt. Auswirkungen vor der Bestätigung
sorgfältig prüfen.

Darstellung: `NO_COLOR=1` schaltet jede Farbe ab, `PMAN_ASCII=1` ersetzt Linien-
und Pfeilzeichen durch ASCII (automatisch auch bei `TERM=linux`), und
`PMAN_HYPERLINKS=1|0` erzwingt klickbare OSC-8-Links oder schaltet sie ab (die
URL steht immer auch als Klartext da).

Bekannte Grenzen: Ein UTF-8-Terminal wird benötigt. Ein laufender CT-Scan kann
bis zu 55 Sekunden weiterlaufen, auch wenn die Oberfläche den Abbruch angefordert
hat. Community-Helper zeigen eigene Dialoge und ihre erneute Live-Quellprüfung
kann während der Netzwerkanfrage kurzzeitig die Oberfläche blockieren. Ein
Abbruch ist kein Rollback. Details stehen in [docs/maintenance.md](docs/maintenance.md).

## Deinstallation des Moduls

```bash
./install_dependencies.sh --uninstall-maintenance
```

Der Bash-Kern bleibt installiert; private Diagnosezustände bleiben erhalten. Für
den Rückweg auf die vorherige Modulversion nutze im passenden Checkout:

```bash
./install_dependencies.sh --rollback-maintenance
```

## Tests

Auf einem Entwicklungsrechner ohne Proxmox-Host laufen die Mock- und TUI-Tests
mit:

```bash
python3 -B -m unittest discover -s tests/maintenance
bash tests/run.sh
```

Die echten Proxmox-Aktionen brauchen einen Testhost. Siehe [Wartungsdokumentation](docs/maintenance.md).

## Weitere Nutzung

`pman` öffnet die VM-/CT-Tabelle, `pman --list` und `pman --json` geben den
Bestand aus. `pman --health` zeigt den Zustand und `pman --check` führt den
optionalen Alarm-Check aus. Konfiguration, Befehle und Beispiele erläutert das
[englische README](README.md). Lizenz: [MIT](LICENSE).
