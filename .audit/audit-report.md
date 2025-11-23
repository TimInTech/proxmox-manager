# Audit Report

Datum: 2025-11-02

## Kurzfassung

- Repository-Typ: Bash CLI/TUI für Proxmox-Hosts (`proxmox-manager.sh`).
- Lizenz: MIT (vorhanden in `LICENSE`).
- CI: GitHub Actions vorhanden (shellcheck, shfmt, link-check, release-drafter).
- Ergebnis der automatischen Scans auf dem Proxmox-Host:
  - `shfmt`-Formatierung angewendet / empfohlen — Format-Diffs wurden geprüft und
    sind stabil.
  - `shellcheck` ausgeführt — keine kritischen ShellCheck-Fehler für die
    Hauptskripte.
  - Secrets-scan (grep-basiert) — keine privaten Schlüssel oder Klartext-Secrets
    gefunden.
  - Gitleaks-Scan (2025-11-23) — keine Secrets oder kritische Findings gefunden.
    Report verfügbar unter `.audit/gitleaks-report.json`.
  - `ci_runs.json` Snapshot ist leer (keine CI-Lauf-Metadaten wurden in das
    Artefakt geschrieben).

## Wesentliche Befunde (Priorisiert)

1. Betriebs-/Security-Hardening (High priority, operational)
   - Empfehlung: Aktiviere GitHub Secret Scanning und Dependabot Security Alerts
     in den Repository Settings.
   - Empfehlung: Aktiviere Branch Protection und Required Status Checks (mindestens
     ShellCheck / shfmt / gitleaks).

1. Repository-Checks & Automation (Medium)

- `shfmt`-Änderungen wurden vorgeschlagen — diese vereinheitlichen Format und
  verringern CI-Fails.
- Markdownlint ist nun als CI-Workflow aktiv und zentrale Markdown-Dateien
  wurden für MD013 (80 Zeichen) bereinigt.

1. Geheimnisse & Artefakte (Medium)
   - Grep-basierter Scan hat nichts Kritisches gefunden.
   - **Gitleaks-Scan ausgeführt (2025-11-23)**: Keine Secrets gefunden. Der Scan
     wurde erfolgreich durchgeführt und das Ergebnis ist in
     `.audit/gitleaks-report.json` dokumentiert. Die gitleaks CI-Integration ist
     einsatzbereit.

## Empfohlene Sofortmaßnahmen

- In den Repository Settings:
  - Enable Secret Scanning
  - Enable Dependabot security alerts and auto fixes
  - Configure Branch Protection for `main` requiring CI checks

- CI Ergänzungen (bereitgestellt/aktiv):
  - Smoke-Test Workflow (`.github/workflows/smoke.yml`) —
    führt `./proxmox-manager.sh --json` in einer Mock-Umgebung (qm/pct) aus,
    validiert die JSON-Ausgabe mit `jq` und lädt `out.json` als Artefakt hoch.
  - Markdownlint Workflow (`.github/workflows/markdownlint.yml`) —
    lintet alle Markdown-Dateien mit 80-Zeichen-Grenze (MD013) und
    ausgeschlossenen Pfaden (`docs/screenshots`, `.audit`).
  - Gitleaks-Workflow (siehe `.github/workflows/gitleaks.yml`) —
    führt Secret-Scanning in PRs und Pushes aus und kann Reports nach
    `.audit/gitleaks-report.json` schreiben.

- Optional: installiere `markdownlint` in CI oder lokal, und bereinige die README
  Warnungen.

## Reproduktionsbefehle (auf Proxmox-Host als `root` oder lokal im Repo)

<!-- markdownlint-disable MD013 -->
```bash
# Format-Check (zeigt Diff)
shfmt -d -ci -i 2 .

# Lint (ShellCheck)
/usr/bin/shellcheck -x install_dependencies.sh proxmox-manager.sh

# Proxmox-Manager Übersicht (nur auf Proxmox Host als root)
./proxmox-manager.sh --list
./proxmox-manager.sh --json > .audit/instances.json

# Einfacher secrets-scan (grep)
grep -RIn --exclude-dir=.git -E '-----BEGIN (RSA|PRIVATE|OPENSSH) PRIVATE KEY-----' .
grep -RIn --exclude-dir=.git -E '[A-Za-z0-9+/]{40,}={0,2}' .

# Optional, tieferer Scan (falls gitleaks installiert)
gitleaks detect --source . --report-path ./.audit/gitleaks-report.json

# Markdownlint lokal laufen lassen (80-Zeichen-Grenze)
npx --yes markdownlint-cli2 "**/*.md" "!docs/screenshots/**" "!.audit/**"

# Smoke-Test lokal simulieren (Mocks erzeugen und JSON prüfen)
export PROXMOX_MANAGER_ALLOW_NONROOT=1
PATH="$PWD/.bin:$PATH" ./proxmox-manager.sh --json > ./.audit/instances.json || true
jq . ./.audit/instances.json >/dev/null
```
<!-- markdownlint-enable MD013 -->

## Weiteres / Nächste Schritte

- Umgesetzt:
  - Smoke-Workflow und Markdownlint-Workflow hinzugefügt und konfiguriert.
  - Markdown-Dateien (`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`)
    für MD013 bereinigt.
  - Projekt-/Issue-Organisation aktualisiert; erledigte Issues geschlossen
    (#9 Englisch-Umstellung, #10 Board/Spalten-Organisation, #12 Markdownlint,
    #14 Smoke-CI).

- Umgesetzt (2025-11-23):
  - Gitleaks-Run ausgeführt und Findings triagiert (#11).
    - Ergebnis: Keine Secrets oder kritische Findings gefunden.
    - Report verfügbar unter `.audit/gitleaks-report.json`.
    - Gitleaks-Workflow ist konfiguriert und bereit für CI-Nutzung.

- Offen/priorisierbar:
  - Vulnerability Scan (z. B. Trivy) als CI ergänzen und Report nach `.audit/`
    schreiben (#13).

## Abschluss

Die wichtigsten Security-Hardening-Maßnahmen sind administrative Einstellungen im
GitHub-Repo (Secret scanning, Dependabot, Branch protection) und ein einmaliger
Lauf eines auf Signaturen/Heuristics basierenden Secrets-Scanners in CI. Ich kann
das weiter automatisieren, wenn du mir sagst, welche Schritte du priorisierst.
