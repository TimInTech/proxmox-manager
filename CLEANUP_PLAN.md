# Cleanup Plan (Phase 1 — Dry Run)

## Keep / Remove / Move (non-essential items)
- Keep: `proxmox-manager.sh` (core), `install_dependencies.sh` (helper), `README.md` (primary doc), `LICENSE`, `SECURITY.md` (to be hardened), minimal `docs/screenshots/Screenshot.png` (referenced in README).
- Keep (optional but small): `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`; retain unless ultra-minimal footprint is required.
- Remove: `docs/screenshots/proxmox-console.png` (unused), `README.de.md` (duplicate doc likely to drift), `.audit/` references (no folder, avoid committing reports), badge/link clutter in README that points to stale assets.
- Move/Simplify: collapse docs into a single README; keep `docs/` only as container for the single screenshot or replace with a top-level `assets/` if preferred during implementation.

## Proposed minimal repo structure
```
/
├ LICENSE
├ README.md
├ SECURITY.md
├ proxmox-manager.sh
├ install_dependencies.sh
├ .github/
│ └ workflows/
│    ├ ci.yml          # shellcheck (and shfmt if present)
│    └ gitleaks.yml    # secret scan, upload artifacts only
└ docs/
   └ screenshots/
      └ Screenshot.png
```

## Actions inventory (.github/workflows)
- Current: none present.
- Proposal: add `ci.yml` (checkout + shellcheck for `*.sh`, optional shfmt check if formatter exists) and `gitleaks.yml` (run gitleaks, upload JSON/SARIF artifacts instead of committing reports). Remove/avoid any other workflows; keep permissions minimal (`contents: read`; `security-events: write` only if SARIF upload).

## Branch consolidation strategy
- Observed remote branches: `codex/ensure-repo-structure-and-metadata*`, `copilot/run-gitleaks-ci`, `copilot/set-up-vulnerability-scan`, plus `main`.
- Target state: keep `main` (and optionally `dev` for staging); merge valuable changes from other branches into `main` or `dev`, then delete them.
- Deletion criteria: branch fully merged; or no unique commits vs `main`; or superseded automation POCs with no surviving config; or stale (>90 days) without activity and already covered by planned workflows.
- Process: fetch all, diff each branch against `main`, cherry-pick any missing valuable commits, then delete remote/local once integrated.

## Risk check
- Removing `README.de.md` drops German translation (accept if prioritizing lean docs); ensure README stops linking to it.
- Dropping unused screenshot and .audit references requires updating README links to avoid 404s.
- New CI (shellcheck/gitleaks) assumes tools available in workflow runners; ensure installation steps are included in workflow.
- SECURITY.md change to private reporting must keep supported versions table intact (likely “main only”).

## Proposed commits (Phase 2)
1) `chore: repo cleanup (remove stale artifacts)` — delete unused screenshots/translation, prune README links, tidy docs tree.
2) `ci: minimize workflows (shellcheck + gitleaks)` — add lean CI and secret scan workflows with minimal permissions/artifacts only.
3) `docs: update README/security policy` — refresh docs to match slim structure, adjust SECURITY.md for private disclosure.

## Operator checklist (branch cleanup commands — do not run yet)
- Sync main: `git checkout main && git pull origin main`
- Inspect branches: `git branch -r` and for each `b`: `git log --oneline origin/main..origin/$b`
- Integrate needed commits: `git checkout main` then `git cherry-pick <commit>` or `git merge origin/<branch>` if valuable.
- Delete merged/stale remote branches: `git push origin --delete <branch>`
- Clean local tracking refs: `git branch -D <branch>` then `git fetch --prune`
