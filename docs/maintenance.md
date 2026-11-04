# Optional storage and maintenance module

The `pman` core remains a standalone Bash file. The optional module runs on the
Proxmox host using Python 3.9+ and its standard `curses` library. It installs no
software inside guests and uses no pip packages. The existing health cron is
not changed.

## Install and start

From the matching repository checkout or unpacked release bundle:

```bash
./install_dependencies.sh --with-maintenance
pman --maintenance
```

Interactive installation asks about the module, defaulting to **No**. Without a
terminal, installation defaults to the core. `--without-maintenance` installs the
core and leaves an existing module alone. The installer performs no `apt` package
installation. If SMART support is missing, the UI explains that `smartmontools`
is optional and must be installed by the administrator.

From the main menu, press `m` for host maintenance. From a VM/CT action menu,
press `m` to open maintenance for exactly that guest. The module can also run
independently:

```bash
pman-maintenance --scope ct --id 101
pman-maintenance --scope vm --id 100
pman-maintenance --scope host --report storage
pman-maintenance --scope ct --id 101 --report volumes --json
```

Use arrow keys to select, Enter to open, Page Up/Down to move by one visible
page, and Esc to cancel/back. The output pane shows its current line range.
`q` exits on a fresh shell line. CT directory scans use Tab to select `/var`, `/home`,
`/opt`, or `/srv`; the scan stays within the selected filesystem. Resizing and
`NO_COLOR=1` are supported. A UTF-8 terminal is required; the module restores a
UTF-8 locale even when the Bash core runs with `LC_ALL=C`.

## Available actions

| Scope | Diagnostics | Confirmed changes |
| --- | --- | --- |
| Host | Storage/filesystems/inodes, LVM thin pools and metadata, ZFS if installed, SMART history, TRIM schedules/logs, kernel packages, backup storage | None |
| CT | Configured volumes resolved through `pvesm path`, filesystem/inode use, bounded directory scans | `pct fstrim ID`; Debian/Ubuntu `apt-get clean` |
| VM | Configured disks/storage/discard, filesystem information via QEMU Guest Agent | Guest-agent TRIM on recognised Linux distributions |

CT/VM operations verify the selected guest and running state immediately before
execution. Guests are never automatically started. Missing commands, an inactive
QEMU Guest Agent and unsupported guest operating systems are reported as
unavailable. VM filesystem output can include read-only filesystems at 100%; it
is diagnostic information and is not automatically interpreted as an alarm.

SMART output presents the overall health, temperature and power-on hours, plus
common error counters. Vendor-specific raw fields are not presented as
standardized measurements. The provenance view summarizes source status and
shows abbreviated reviewed/upstream commits.

The UI shows the target, exact command and impact before a change. Only `j`
confirms it; the core's `--force` does not bypass this. Cancelling a running
change is not a rollback. A cancelled CT directory scan may continue inside the
guest until its independent 55-second timeout; the outer command is also bounded.
Changes are serialized by a private lock. There is no unattended mutation CLI.

The interface separates the action list from its detail or confirmation view.
At smaller widths the list is stacked; below the minimum size, actions are
blocked until the terminal is resized. While a job runs, Esc or `q` requests
cancellation and other input is ignored; after cancellation, `q` exits.

The host menu also has **Proxmox VE Helper-Scripts (Community)**
(<https://community-scripts.org>; repository `community-scripts/ProxmoxVE`,
MIT licence, "Copyright (c) 2021-2026 tteck | community-scripts ORG"). It offers
eight selected Host Management tools in three groups:

| Group | Tool | Level |
| --- | --- | --- |
| Prüfen & Sichern | Disk Health (installs packages only if you agree) | `[LESEN]` |
| Prüfen & Sichern | Host Backup | `[ÄNDERT]` |
| Aktualisieren & Optimieren | LXC Updater, LXC Filesystem Trim, CPU Scaling Governor | `[ÄNDERT]` |
| Aufräumen – löscht Daten | Kernel Clean, LXC Cleaner, Clean Orphaned LVM | `[LÖSCHT]` |

The level is always written out; colour (fixed 256-colour badge pairs with a
contrast of at least 4.5:1, none under `NO_COLOR`) is only an additional cue.
This is third-party code that runs as root on the host; its own interactive
prompts and target selection remain intact.

Before the confirmation screen, pman checks the live GitHub metadata for the tool
and its core library, downloads only the reviewed commit and verifies the Git
blob SHA-1. The screen shows the exact source URL, the command, the "runs as
root on this host" notice, the pinned revisions and checksum and the impact. `v`
opens the verified script (read only); after `j` exactly these bytes are
executed, following a second metadata check. A changed, missing or unreachable
upstream source blocks the start; the message names the file and the reviewed
and current revision. The menu header shows the last stored source check
(from the daily timer, no network access when opening the menu) and marks
affected tools with `!`. With network timeouts the checks and downloads can block
the interface for up to about one minute. The core runtime library is pinned and
checked as well. Its optional telemetry API is intentionally omitted. A helper
can still install packages, delete selected logs/volumes, change host settings or
update guests as described in its impact text; pman asks for a separate
confirmation before starting it.

Display environment variables: `NO_COLOR=1` (no colour), `PMAN_ASCII=1` (ASCII
glyphs instead of box and arrow characters; automatic for `TERM=linux`,
`vt100`, `vt220`) and `PMAN_HYPERLINKS=1|0` (force OSC 8 links on or off). The
URL is always shown as plain text; links are only added in terminals known to
support them (VTE 0.50+, kitty, iTerm2, WezTerm, Windows Terminal, foot, VS Code)
and never inside tmux or screen unless forced.

TRIM reports unused blocks to lower storage layers. Its reported byte count is
not a guarantee of newly available pool space. Guest filesystem use, thin-volume
allocation and pool data/metadata use are displayed separately. Volume names
are read from the actual guest configuration, not guessed from the VMID.

The native adapters do not offer broad log deletion, kernel removal, backup
deletion or filesystem/partition reconfiguration. Some community helpers do
offer log or kernel removal and other changes, as described above.

## Community Scripts provenance and freshness

The standard maintenance actions are independent local implementations using
native commands. `maintenance/sources.json` records their references and the
reviewed Community tools, commits, Git blob checksums and upstream licence. The
UI's provenance view exposes these details and the last source-check result.
Only the eight tools listed above are launchable; other category entries are not
exposed as arbitrary shell commands.

The installed `pman-maintenance-sources.timer` runs daily with random delay.
It requests public GitHub **directory listings containing file metadata**, not
script contents. It compares file blob hashes with the reviewed manifest,
including launchable tools and their pinned Core dependency. ETag requests reduce traffic.
No credentials, guest data or SMART history are sent. Results include timestamps
and one of: `geprüfter Stand`, `Upstream geändert`, `Quelle fehlt`, or
`Prüfung fehlgeschlagen`. A failed network/API request never means "up to date".
A missing file triggers review, not an automatic search for a replacement URL.

```bash
pman-maintenance --check-sources
pman-maintenance --sources
systemctl disable --now pman-maintenance-sources.timer
```

To install without enabling the timer:

```bash
./install_dependencies.sh --with-maintenance --no-source-timer
```

A manually disabled timer stays disabled on upgrades. To re-enable it explicitly:

```bash
systemctl enable --now pman-maintenance-sources.timer
```

An upstream change is a review signal. Code and reviewed checksums are updated
only in a new module release after compatibility review; checksums are an
integrity identifier, not a security assessment. Ordinary maintenance actions
work offline. The core's existing opt-in notification networking is separate.

## Updates, rollback and removal

Use a reviewed matching checkout/release and rerun the installation command.
Packages are root-owned under `/usr/local/lib/pman/maintenance/releases/`;
`current` switches atomically and `previous` supports rollback. The isolated
Python launcher ignores `PYTHONPATH` and checks ownership and write permissions.
An incompatible interface is rejected by the core.

```bash
./install_dependencies.sh --rollback-maintenance
./install_dependencies.sh --uninstall-maintenance
```

Removal stops/removes only the module and its source-check service/timer. It
retains the core, health configuration and private diagnostic state under
`/var/lib/pman-maintenance` (SMART baseline and source-check cache).

Release assets include the core, installer, optional module bundle and
`SHA256SUMS`. The bundle contains its matching core and installer for deployment.
Verify downloaded assets against the release checksums before installation.
For development, run `python3 -I -B maintenance/launcher.py --interface` or start
the same launcher as root on a Proxmox test host. `--destdir` stages installation
files without touching services; it is intended for packaging/tests.
