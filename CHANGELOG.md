# Changelog

All notable changes to proxmox-manager / pman are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

## [2.13.0] - 2026-09-19

### Added

- `--health` (boxed), `--health --list` and `--health --json`: CPU, memory and
  disk usage, uptime and a health level per local VM/CT, read from `pvesh get
  /cluster/resources`; templates and guests on other cluster nodes are skipped.
  `--filter` and `--name` apply.
- Main menu key `h` opens the health overview; the status action prints an extra
  `Health:` line.
- `--check` for cron: alerts only on changes (new, escalated, improved,
  resolved) for resource thresholds (CPU after `HEALTH_CPU_RUNS` consecutive
  runs; resolved when the guest stops), guests stopped with `onboot=1`, guests
  whose latest lifecycle task does not explain a stop (stop, shutdown, suspend,
  migrate, destroy, backup), and failed node tasks (read with `--source all`).
  Nagios-style summary and exit codes 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN (also for
  usage errors).
- `--dry-run` (with `--check`) prints the result and the composed message
  without sending or writing state; `--test-notify` sends a test message.
- Notifications via ntfy (`NTFY_URL`, optional `NTFY_TOKEN_FILE`) and e-mail
  through the local `sendmail` (`HEALTH_MAIL_TO`, `HEALTH_MAIL_FROM`); one
  combined message per run.
- New config keys `HEALTH_{CPU,MEM,DISK}_{WARN,CRIT}` (`0` disables a level),
  `HEALTH_CPU_RUNS`, `HEALTH_IGNORE_IDS`, `HEALTH_STATE_DIR` (default
  `/var/lib/pman`) and the notification keys above.
- CI runs the test suite (`tests/run.sh`); shell completions gained `--name`,
  `--health`, `--check`, `--dry-run` and `--test-notify`.

### Changed

- `STOP_TIMEOUT` and `PROXMOX_MANAGER_SPICE_ADDR` are validated after the
  command line is parsed.
- With `--json` the `--force` warning goes to stderr, so the JSON output stays
  valid.
- Outbound traffic is now possible, but only when notifications are configured
  (opt-in).

### Security

- The ntfy access token is read from a `0600` file owned by the caller in a
  directory nobody else can write; the open descriptor is verified before
  reading (no swap between check and use). An inline `NTFY_TOKEN` in a config
  file and a token with an `http://` URL are configuration errors.
- The token, URL and headers reach `curl` only via its stdin config, never argv;
  `curl -q` ignores `~/.curlrc`, redirects are not followed, a token forces
  `https` only, and requests are not retried.
- Logs name only the ntfy host, never the topic path or the token.
- Mail headers are built from validated single-line values (no header
  injection).
- JSON output escapes all control characters; `_truncate` never cuts inside a
  UTF-8 character.
- `qm`/`pct` config fallbacks run with a timeout; the `--check` lock descriptor
  is not inherited by child processes and the lock file is never truncated; the
  state directory's parent must not be group/world-writable.
- The `--check` state lives in a `0700` directory, is written atomically with
  mode `0600`, is parsed as validated data (never sourced), and parallel runs
  are prevented with `flock`.

## [2.12.1] - 2026-09-19

### Fixed

- Action and snapshot menus now draw a closed frame: every row is padded to the
  box width and gets a right border; long guest names in the menu titles are
  truncated instead of overflowing.

### Changed

- README screenshots regenerated from v2.12.1 on a real PVE 9.2 host; the
  obsolete, unreferenced `docs/screenshots/Screenshot.png` (pre-2.8 UI) was
  removed.

## [2.12.0] - 2026-09-19

### Security

- Configuration files are now parsed as allowlisted data instead of being
  executed with `source`.
- Log files must be private, owner-controlled regular files; unsafe paths and
  symlinks are rejected.
- The system-wide `pman` command is installed as an atomic root-owned copy
  instead of a symlink to a potentially user-writable checkout.
- GitHub Actions are commit-SHA pinned, remote tool downloads are
  checksum-verified, workflow permissions are minimized, and checkout
  credentials are not persisted.
- User-controlled status and message text is no longer interpreted as `printf
  %b` escape sequences.

### Fixed

- Broken TUI frames (#33): header and table rows are now padded by visible
  width, so right borders line up; the table gained a closing border, the NAME
  column grows with long guest names (capped at the terminal width, then
  truncated), and header/data columns are aligned in `--list` output too.
- The header showed `PVE: (running` instead of the version; it now parses
  `pveversion` correctly and shows a compact uptime (e.g. `12d 1h 25m`).
- VM IP lookup now accepts the native QEMU Guest Agent list payload from `qm
  agent ... network-get-interfaces` as well as the earlier wrapped shape,
  preventing parser errors on hosts that return a bare JSON array.
- Snapshot name validation now matches Proxmox `pve-configid` rules before
  calling `pct` / `qm`; numeric-only and single-letter names are rejected
  locally with a clearer message.
- SPICE `.vv` files now prefer the actual SPICE bind address/port from Proxmox
  instead of always using the host LAN IP, preventing mismatched connection
  targets on loopback-bound SPICE setups.
- `spice_info()` no longer claims success launching `virt-viewer` from a
  non-graphical shell; it falls back to the `.vv` file with a clear
  desktop-session hint.
- VM console guidance now tells the user to follow the escape hint printed by
  Proxmox instead of hardcoding a potentially wrong key sequence.

### Added

- New **IP info** menu item: shows current IPv4 addresses for running VMs and
  CTs. VMs use the QEMU Guest Agent, CTs use `pct exec ... ip -j addr show`,
  with clear fallback messages when no address is available.

## [2.9.0 – 2.11.1] - 2026-04-09 – 2026-05-04

Consolidated notes for the releases between 2.8.4 and 2.11.1 (tagged `v2.9.0`
and `v2026.05.04`).

### Added

- `--filter STATUS` flag: filter `--list` / `--json` output to `running`,
  `stopped`, or `paused` instances; invalid values exit 1 with a clear error
  message.
- `--timeout SECS` flag: set a timeout (default 60 s) for stop operations; on
  exit code 124 (timeout fired) automatically retries with `--overrule-shutdown
  1` as a force-stop fallback.
- `--force` flag: skip all `confirm()` prompts automatically; prints a warning
  at startup and logs each bypassed prompt in yellow so the action is always
  visible.
- `filtered_instances()` wrapper around `collect_instances()`; used by
  `print_table` and `print_json` so filter logic is in one place.
- Bash completion script: `completions/pman.bash` — tab-completes all flags;
  suggests `running|stopped|paused` after `--filter` and common timeout values
  after `--timeout`.
- Zsh completion script: `completions/pman.zsh` — `_arguments`-based with value
  specs for `--filter` and `--timeout`.
- GitHub issue templates (YAML form format): `bug_report.yml`,
  `feature_request.yml`.
- GitHub `ISSUE_TEMPLATE/config.yml`: blank issues disabled, link to
  Discussions.
- GitHub `PULL_REQUEST_TEMPLATE.md` with ShellCheck / test / changelog
  checklist.
- GitHub `workflows/release.yml`: auto-creates a GitHub Release with
  `proxmox-manager.sh` as an asset on every `v*` tag push.
- GitHub `FUNDING.yml`: GitHub Sponsors link for TimInTech.

### Fixed

- `do_action restart`: replaced manual `stop → sleep 1 → start` sequence with
  native `pct reboot` / `qm reboot` — atomic, no unnecessary 1-second delay,
  cleaner error output.

### Changed

- `type_of_id()` now checks a global `_type_cache` associative array before
  querying `pct list` / `qm list`; cache is populated as a zero-cost side-effect
  of the existing `main_menu` instance loop (no extra Proxmox call required).
- `collect_instances()`: replaced three `awk '{print $N}' <<<` subshells per
  VM/CT with a single parameter-expansion trim + `IFS=' ' read -r` — eliminates
  6 subshells per iteration.
- `print_table` "no results" message is context-aware: when `--filter` is active
  it shows "No \<status\> VMs or containers found." rather than the generic
  root-hint message.

---

## [2.8.4] - 2026-03-06

### Fixed

- `validate_snapshot_name()` now applied to rollback and delete operations
  (previously only enforced on create).
- `snapshots_menu`: rollback and delete show Proxmox error details via `_rb_out`
  / `_del_out` variables, consistent with create.
- `open_console`: guard added for VM terminal — checks `qm status` before
  calling `qm terminal`; prints `Ctrl+]` exit hint before entering.
- `_pve_out` correctly declared `local` in stop and restart branches of
  `do_action()`; fixes potential variable bleed between branches.

### Added

- Keyboard legend in the main menu (`<VMID>`, `r`, `q`).

---

## [2.8.3] - 2026-03-06

### Added

- `pman` global command: `install_dependencies.sh` now installs a symlink at
  `/usr/local/bin/pman`; idempotent.

### Fixed

- `_pve_out` declared `local` in all do_action() branches.
- Rollback and delete snapshot errors now captured and displayed.
- VM console guard: `open_console` checks VM running status before `qm
  terminal`.

---

## [2.8.2] - 2026-03-06

### Fixed

- Proxmox error details surfaced on start / stop / restart failure via stderr
  capture.
- Snapshot name validated before any Proxmox call (create path).
- UX polish: VMID-not-found message hints to press `r` to refresh; empty Enter
  in action menu treated as "Back".

---

## [2.8.1] - 2026-03-06

### Fixed

- `open_console`: CT status checked before `pct enter`; clear error if not
  running.

### Added

- `print_table` appends colour-coded count line: `Count: N running  M stopped`.
- `header()` shows system uptime via `uptime -p`.

---

## [2.8.0] - 2026-03-06

### Changed

- Full modular rewrite: `collect_instances`, `print_table`, `print_json`,
  `do_action`, `snapshots_menu`, `spice_info`, `spice_enable` separated into
  distinct functions.
- Status symbols changed to ASCII: `[+]` running, `[-]` stopped, `[~]` paused,
  `[?]` unknown.
- Output normalised to English throughout.
- `set -Eeuo pipefail` + `IFS=$'\n\t'` + `LC_ALL=C` hardened at the top.
- `confirm()` added before all destructive actions (stop, restart, rollback,
  delete).
- `log()` added for optional structured file logging via `$LOG_FILE`.
- `validate_vmid()` added — rejects non-numeric or out-of-range VMIDs.
- `header()` shows node hostname and PVE version when available.
- SPICE bind address configurable via `PROXMOX_MANAGER_SPICE_ADDR`.
- `--version` flag added.
- `PROXMOX_MANAGER_ALLOW_NONROOT=1` env var for CI / test environments.

---

## [1.5.0] - (pre-rewrite)

Early version with basic console and snapshot management. Replaced by the v2.8.0
rewrite.

---

[Unreleased]: https://github.com/TimInTech/proxmox-manager/compare/v2.12.1...HEAD
[2.12.1]: https://github.com/TimInTech/proxmox-manager/compare/v2.12.0...v2.12.1
[2.12.0]: https://github.com/TimInTech/proxmox-manager/compare/v2026.05.04...v2.12.0
[2.8.4]: https://github.com/TimInTech/proxmox-manager/compare/v2.8.3...v2.8.4
[2.8.3]: https://github.com/TimInTech/proxmox-manager/compare/v2.8.2...v2.8.3
[2.8.2]: https://github.com/TimInTech/proxmox-manager/compare/v2.8.1...v2.8.2
[2.8.1]: https://github.com/TimInTech/proxmox-manager/compare/v2.8.0...v2.8.1
[2.8.0]: https://github.com/TimInTech/proxmox-manager/compare/v1.5.0...v2.8.0
