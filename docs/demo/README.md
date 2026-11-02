# Proxmox Manager GIF-Demo — Deterministische Headless-Pipeline

Dieses Verzeichnis enthält die vollständige, reproduzierbare Headless-Pipeline zur pixelgenauen Erstellung des Demo-GIFs und Rohvideos für **Proxmox Manager**.

Die Demo zeigt ausschließlich aktuell implementierte, lesende Oberflächen auf dem PVE-Host:
1. **Startansicht**: VM-/CT-Instanztabelle mit Status, Typ und Tastenkürzeln.
2. **Health-Übersicht (`h`)**: CPU-, MEM-, DISK-Auslastung, Uptime, OK/CRIT-Bewertung und Findings.
3. **Hauptmenü**: Rückkehr in die Hauptansicht.
4. **Host-Wartungsmenü (`m`)**: Curses-basierte Host-Wartungsoberfläche.
5. **Community PVE-Werkzeuge**: Durchsicht der geprüften PVE-Helper-Skripte ohne Mutation oder Start.

---

## Architektur

Die Pipeline trennt Session-Steuerung, Datenanonymisierung, Rendering und Verifikation sauber voneinander:

```
┌────────────────────────────────┐
│  Xvfb Headless Display (:99)   │
│  (1280×720, 24-bit TrueColor)  │
│                                │
│   ┌──────────────────────────┐ │
│   │  Frameless Kitty Terminal │ │
│   │  (DejaVu Sans Mono 15.5) │ │
│   │                          │ │
│   │  session_driver.py       │ │
│   │  ├── pexpect PTY driver  │ │
│   │  └── StreamAnonymizer    │ │
│   └──────────┬───────────────┘ │
└──────────────┼─────────────────┘
               │
      ffmpeg x11grab (30 fps)
               │
               ▼
┌────────────────────────────────┐
│ docs/demo/out/                 │
│ ├── proxmox-manager-demo-raw   │ (1280×720, H.264, 30 fps)
│ ├── proxmox-manager-demo.gif   │ (1280×720, 12 fps, dither=none)
│ ├── proxmox-manager-demo.cast  │ (Asciinema v2 Event-Stream, 33 KB)
│ └── pty_stream.log             │ (Anonymisierter Stream-Dump)
└────────────────┬───────────────┘
                 │
       build_player.py
        └── index.html (Interaktiver Vektor-Player mit Kapiteln & Textauswahl)
                 │
       verify_demo.py (Automated Validation)
        ├── OCR (tesseract) @ 2s, 8s, 18s
        ├── Privacy regex scanner (0 leaks in OCR, PTY, Cast)
        └── ffprobe stream & size checks
```

### 1. Deterministischer Session-Treiber (`session_driver.py`)
- Steuert die echte `pman`-Konsole über SSH (`ssh -tt pve 'TERM=xterm-256color pman'`) an.
- Verwendet kein blindes `sleep`-Piping: Eine `pexpect`-Zustandsmaschine wartet auf konkrete Text-Buffer vor jeder Aktion (`h`, Enter, `m`, Cursor-Navigation, Esc, `q`).
- Keine schreibenden Aktionen: Es werden keine Installationen, Services, Reboots oder mutierenden Helper gestartet.

### 2. In-Stream-Pseudonymisierung (`StreamAnonymizer`)
- Ersetzt sensible Daten im Bytestrom in Echtzeit, bevor sie auf das Terminal gezeichnet werden:
  - Header-Titel: `Proxmox VM/CT Manager` → `PROXMOX MANAGER      ` (längengleich).
  - Node-Name: `Node: pve` → `Node: pve-node-01` (Ausgleich der Padding-Leerzeichen; kein Verrutschen der `║`-Boxgrenze).
  - Private IP-Adressen: Reale `192.168.*`-Adressen werden durch längengleiche RFC-5737-Dokumentations-IPs (`192.0.2.*`) ersetzt.
  - FQDNs: `pve.fritz.box` wird durch `pve-node-01.lan ` ersetzt.
  - SSH-Disconnect-Banner werden im Bytestrom bereinigt.

### 3. Headless Rendering & Geometrie (`build_demo.py`)
- Rendering läuft isoliert in `Xvfb :99 -screen 0 1280x720x24`.
- Rahmenterminal (Kitty) mit `DejaVu Sans Mono` bei `15.5 pt` und `window_padding_width=24` füllt das Canvas exakt aus.
- Keine Skalierungsunschärfe, keine Fensterrahmen, kein Desktop-Hintergrund, keine Terminal-in-Terminal-Verschachtelung.

### 4. Artefakt-Generierung
- **Rohvideo**: `1280×720`, H.264, 30 fps, ca. 24–27 Sekunden Dauer.
- **GIF**: `1280×720`, 12 fps, optimierte Palette (`palettegen=max_colors=128:stats_mode=diff`, `paletteuse=dither=none`), Dateigröße unter 1 MB (Ziel < 10 MB).
- **Asciinema Cast**: `docs/demo/out/proxmox-manager-demo.cast` (33 KB NDJSON mit exakten Timestamps und Terminal-Events).

### 5. Interaktiver Web-Vektor-Player (`index.html` / `build_player.py`)
- Standalone HTML5-Webplayer mit integriertem Asciinema-Player v3 (Canvas/WASM-Rendering).
- Vollständige Wiedergabesteuerung: Play/Pause, Timeline-Scrubber, 1x/2x Geschwindigkeit, Vollbild.
- Interaktive Kapitelsprungmarken: Direktes Anspringen von Startansicht, Health-Check, Wartungsmenü, Community-Tools und Exit.
- **Freie Textauswahl**: Alle Terminalinhalte können direkt mit der Maus markiert und per Tastatur kopiert werden (`Strg+C`).
- Offline- und Online-fähig: Lädt lokale Vendor-Assets (`vendor/`) oder eingebetteten Cast, funktioniert sowohl via `file://` als auch auf Webservern oder GitHub Pages.

---

## Pipeline ausführen

Die gesamte Generierung inklusive anschließender automatisierter Validierung erfolgt mit einem einzigen Befehl:

```bash
bash docs/demo/build_demo.sh
```

Alternativ direkt per Python:

```bash
python3 docs/demo/build_demo.py
```

---

## Automatisierte Verifikation (`verify_demo.py`)

Das Prüfskript validiert das erzeugte Artefakt objektiv vor Abschluss:

```bash
python3 docs/demo/verify_demo.py
```

### Kriterien & Prüfpunkte:
1. **ffprobe Stream-Validierung**:
   - Rohvideo: Exakt 1280×720, 30 fps, Dauer zwischen 20.0s und 28.0s.
   - GIF: 1100–1280 px Breite, 10–12 fps, Dateigröße < 10 MB.
2. **OCR-Prüfung (`tesseract`)**:
   - Sekunde 2.0: Extrahiert Frame und verifiziert Schlüsselbegriff `"PROXMOX MANAGER"`.
   - Sekunde 8.0: Extrahiert Frame und verifiziert Schlüsselbegriff `"Health"`.
   - Sekunde 18.0: Extrahiert Frame und verifiziert Schlüsselbegriff `"Community PVE"`.
3. **Privacy-Check (Regex)**:
   - Vollständiger Scan der OCR-Texte aller Frames und des gesamten aufgezeichneten PTY-Bytestroms (`pty_stream.log`).
   - Verifiziert 0 Treffer für reale Hostnamen (`Node: pve`, `pve.fritz.box`) und RFC1918-IPs (`192.168.*`, `10.*`, `172.16-31.*`).
