# Audit Artefacts

Repository checks and automation baselines.

## CI Pipelines

- `Sanity Checks` — runs `shellcheck` and `shfmt` on all tracked shell scripts.
- `Gitleaks Secret Scan` — detects secrets in code and commit history using gitleaks.
- `Link Check` — validates Markdown links with `lychee`.
- `Release Drafter` — prepares changelog drafts for tagged releases.

## Manual Metrics

- Use `gh run list --limit 20 --json databaseId,createdAt,status,durationMs > .audit/ci_runs.json` to snapshot recent CI execution history.
- Gitleaks scan results are stored in `gitleaks-report.json` (empty array indicates no secrets found).
- Add additional JSON or Markdown reports to this directory as new checks are introduced.

## Security Controls

- Security contacts and disclosure process live in `SECURITY.md`.
- Enable GitHub secret scanning, vulnerability alerts, and push protection in repository settings to complete the baseline.
