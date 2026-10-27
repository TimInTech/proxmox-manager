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

TRIM reports unused blocks to lower storage layers. Its reported byte count is
not a guarantee of newly available pool space. Guest filesystem use, thin-volume
allocation and pool data/metadata use are displayed separately. Volume names
are read from the actual guest configuration, not guessed from the VMID.

No broad log deletion, kernel removal, backup deletion or filesystem/partition
reconfiguration is provided in this first version.

## Community Scripts provenance and freshness

All adapters are independent local implementations using native commands.
Community Scripts are declared as reviewed functional references where relevant;
no upstream script, runtime library or telemetry is downloaded or executed.
`maintenance/sources.json` records each adapter's origin and reference sources,
reviewed commits, Git blob checksums and upstream licence. The UI's provenance
view exposes these details and the last source-check result.

The installed `pman-maintenance-sources.timer` runs daily with random delay.
It requests public GitHub **directory listings containing file metadata**, not
script contents. It compares relevant file blob hashes with the reviewed
manifest, including referenced Core dependencies. ETag requests reduce traffic.
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
