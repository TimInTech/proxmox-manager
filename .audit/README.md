# Audit Artefacts

Repository checks and automation baselines.

## CI Pipelines

- `Sanity Checks` — runs `shellcheck` and `shfmt` on all tracked shell scripts.
- `Link Check` — validates Markdown links with `lychee`.
- `Release Drafter` — prepares changelog drafts for tagged releases.
- `Trivy Vulnerability Scan` — scans for vulnerabilities, secrets, and
  misconfigurations using Trivy. Reports are saved to
  `.audit/trivy-report.json` and `.audit/trivy-report.txt`.

## Manual Metrics

- Use `gh run list --limit 20 --json databaseId,createdAt,status,durationMs >
  .audit/ci_runs.json` to snapshot recent CI execution history.
- Add additional JSON or Markdown reports to this directory as new checks are
  introduced.

## Vulnerability Scanning

The repository uses Trivy for automated vulnerability scanning:

- **Scan Scope**: Filesystem scan covering Bash scripts, dependencies,
  secrets, and misconfigurations
- **Severity Levels**: CRITICAL, HIGH, MEDIUM, LOW
- **Scan Types**:
  - Vulnerability detection
  - Secret scanning
  - Misconfiguration detection
- **Schedule**: Runs on every push to main, pull requests, weekly on Mondays,
  and manual workflow dispatch
- **Reports**:
  - `trivy-report.json` — Machine-readable JSON format (workflow artifact)
  - `trivy-report.txt` — Human-readable table format (workflow artifact)
  - SARIF results uploaded to GitHub Security tab

To run Trivy scan locally:

```bash
# Install Trivy (if not already installed)
# See https://aquasecurity.github.io/trivy/latest/getting-started/installation/

# Run scan
trivy fs --severity CRITICAL,HIGH,MEDIUM,LOW --scanners vuln,secret,misconfig .

# Generate JSON report
trivy fs --severity CRITICAL,HIGH,MEDIUM,LOW --scanners vuln,secret,misconfig \
  --format json --output .audit/trivy-report.json .

# Generate text report
trivy fs --severity CRITICAL,HIGH,MEDIUM,LOW --scanners vuln,secret,misconfig \
  --format table --output .audit/trivy-report.txt .
```

## Security Controls

- Security contacts and disclosure process live in `SECURITY.md`.
- Enable GitHub secret scanning, vulnerability alerts, and push protection in
  repository settings to complete the baseline.
