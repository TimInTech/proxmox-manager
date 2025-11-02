# Contributing Guide

Thanks for your interest in improving `proxmox-manager`!

## How to Contribute

1. **Discuss first**  
   Open an issue before starting major work so we can align on scope, approach, and ownership.

2. **Fork and branch**  
   Create a topic branch from `main`. Use descriptive branch names such as `feature/json-output` or `fix/spice-port`.

3. **Style and tooling**  
   - Shell scripts must pass `shellcheck` and `shfmt -w -i 2 -ci -sr`.
   - Markdown should be wrapped at 100 columns when practical.
   - Follow the `.editorconfig` settings.

4. **Testing**  
   - Exercise the script on a Proxmox test host or mock environment when possible.
   - Add automated tests once the project includes test harnesses.
   - Document manual testing steps in the pull request description.

5. **Commit standards**  
   - Keep commits focused and atomic.
   - Reference GitHub issues using `Fixes #123` when applicable.

6. **Pull Request checklist**  
   - [ ] `./install_dependencies.sh` ran successfully (if relevant).
   - [ ] `shellcheck` and `shfmt` pass locally.
   - [ ] Documentation updated for behavior changes (`README.md`, `docs/`).
   - [ ] Added or updated audit artifacts in `.audit/` if new checks were introduced.

## Releasing

Releases are drafted automatically via GitHub Release Drafter. Tagging `vX.Y.Z` on `main` will create a GitHub release. See `.github/release-drafter.yml` for configuration details.
