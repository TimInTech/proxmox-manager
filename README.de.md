# Proxmox Manager

**Sprache: [English](README.md) | Deutsch**

Proxmox Manager verwaltet Proxmox-VMs und -Container mit einem eigenständigen
Bash-Skript. Die optionale Speicher- und Wartungsoberfläche verwendet Python 3
und die Standardbibliothek; der Bash-Kern kann ohne sie installiert werden. Die
vollständige Befehls- und Konfigurationsreferenz steht im [englischen README](README.md).

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

Die eigenen Adapter zeigen unter anderem Storage, Dateisysteme und SMART-Daten.
CT und VM bieten ausschließlich auf den gewählten Gast bezogene Diagnosen und
bestätigungspflichtiges TRIM; für Debian-/Ubuntu-CTs ist auch eine Bereinigung
des APT-Paketcache verfügbar. Gestoppte Gäste werden nicht automatisch gestartet.
Jede Änderung verlangt eine eigene Bestätigung; `--force` umgeht sie nicht.
Ein Abbruch laufender Änderungen ist kein Rollback.

Das Host-Menü enthält außerdem ausgewählte **Community Scripts**. Sie laufen als
Upstream-Code mit eigenen interaktiven Dialogen und können Host-Einstellungen
oder dort ausgewählte Gäste ändern. Vor der Bestätigung prüft das Modul den
aktuellen Upstream; vor dem Start prüft es erneut und kontrolliert die Git-Blob-Prüfsummen der festgelegten
Revisionen. Geänderte, fehlende oder nicht erreichbare
Quellen verhindern den Start. Die erneute Prüfung und Downloads können bei
Zeitlimits im ungünstigsten Fall etwa eine Minute dauern; die Oberfläche ist
währenddessen blockiert. Die optionale Upstream-Telemetrie wird nicht
bereitgestellt. Auswirkungen vor der Bestätigung sorgfältig prüfen.

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
