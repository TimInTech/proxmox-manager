# Audit Artefacts

Repository checks and automation baselines.

## CI Pipelines

- `Sanity Checks` — runs `shellcheck` and `shfmt` on all tracked shell scripts.
- `Gitleaks Secret Scan` — detects secrets in code and commit history using gitleaks.
- `Link Check` — validates Markdown links with `lychee`.
- `Release Drafter` — prepares changelog drafts for tagged releases.
- `Trivy Vulnerability Scan` — scans for vulnerabilities, secrets, and
  misconfigurations using Trivy. Reports are saved to
  `.audit/trivy-report.json` and `.audit/trivy-report.txt`.

## Manual Metrics


## Security Controls

- Security contacts and disclosure process live in `SECURITY.md`.
- Enable GitHub secret scanning, vulnerability alerts, and push protection in
  repository settings to complete the baseline.
