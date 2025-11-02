# Audit Report

Datum: 2025-11-02

Kurzfassung
----------

- Repository-Typ: Bash CLI/TUI für Proxmox-Hosts (`proxmox-manager.sh`).
- Lizenz: MIT (vorhanden in `LICENSE`).
- CI: GitHub Actions vorhanden (shellcheck, shfmt, link-check, release-drafter).
- Ergebnis der automatischen Scans auf dem Proxmox-Host:
  - `shfmt`-Formatierung angewendet / empfohlen — Format-Diffs wurden geprüft und sind stabil.
  - `shellcheck` ausgeführt — keine kritischen ShellCheck-Fehler für die Hauptskripte.
  - Secrets-scan (grep-basiert) — keine privaten Schlüssel oder klartext-Secrets gefunden.
  - `ci_runs.json` Snapshot ist leer (keine CI-Lauf-Metadaten wurden in das Artefakt geschrieben).

Wesentliche Befunde (Priorisiert)
--------------------------------

1) Betriebs-/Security-Hardening (High priority, operational)
   - Empfehlung: Aktiviere GitHub Secret Scanning und Dependabot Security Alerts im Repository Settings.
   - Empfehlung: Aktiviere Branch Protection und Required Status Checks (mind. ShellCheck / shfmt / gitleaks).

2) Repository-Checks & Automation (Medium)
   - `shfmt`-Änderungen wurden vorgeschlagen — diese vereinheitlichen Format und verringern CI-Fails.
   - `markdownlint` ist nicht installiert auf dem Host; README enthält mehrere MD-Lint-Warnungen (stilistisch).

3) Geheimnisse & Artefakte (Medium)
   - Grep-basierter Scan hat nichts Kritisches gefunden. Für höhere Sicherheit empfehle ich einen Lauf mit `gitleaks` oder `trufflehog` in CI.

Empfohlene Sofortmaßnahmen
---------------------------

- In den Repository Settings:
  - Enable Secret Scanning
  - Enable Dependabot security alerts and auto fixes
  - Configure Branch Protection for `main` requiring CI checks

- CI Ergänzungen (bereitgestellt):
  - Gitleaks-Workflow (siehe `.github/workflows/gitleaks.yml`) — führt Secret-Scanning in PRs und Pushes aus und schreibt Report nach `.audit/gitleaks-report.json`.

- Optional: installiere `markdownlint` in CI oder lokal, und bereinige die README Warnungen.

Reproduktionsbefehle (auf Proxmox-Host als `root` oder lokal im Repo):

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
```

Weiteres / Nächste Schritte
--------------------------

- Ich habe bereits einen GitHub Actions Workflow hinzugefügt, der `gitleaks` laufen lässt. Wenn du möchtest, kann ich zusätzlich:
  - Markdown-Lint Workflow ergänzen
  - Einen PR vorbereiten, der `shfmt`-Änderungen sauber zusammenführt
  - `gitleaks` konfigurieren, um tolerierbare Ausnahmen (allowlist) zu verwenden

Abschluss
---------

Die wichtigsten Security-Hardening-Maßnahmen sind administrative Einstellungen im GitHub-Repo (Secret scanning, Dependabot, Branch protection) und ein einmaliger Lauf eines auf Signaturen/heuristics basierenden Secrets-Scanners in CI. Ich kann das weiter automatisieren, wenn du mir sagst, welche Schritte du priorisierst.
