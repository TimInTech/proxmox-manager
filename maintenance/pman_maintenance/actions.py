"""Fixed native adapters. Community sources are references, never executed."""
import json
import re
import shlex
import shutil
from dataclasses import dataclass
from pathlib import PurePosixPath
from .runner import CommandError
from .state import STATE, read_json, write_json


@dataclass(frozen=True)
class Context:
    scope: str
    id: int = None
    mount: str = '/var'

    def __post_init__(self):
        if self.scope not in ('host', 'ct', 'vm'):
            raise ValueError('Ungültiger Zieltyp.')
        if self.scope != 'host' and (type(self.id) is not int or not 100 <= self.id <= 999999999):
            raise ValueError('Ungültige VMID.')
        if self.scope == 'host' and self.id is not None:
            raise ValueError('Host benötigt keine VMID.')
        if self.mount not in ('/var', '/home', '/opt', '/srv'):
            raise ValueError('Nur /var, /home, /opt oder /srv sind als Scan-Ziel erlaubt.')


@dataclass(frozen=True)
class Action:
    id: str
    title: str
    scopes: tuple
    mutation: bool = False
    source: str = 'Eigene Implementierung'


ACTIONS = (
    Action('storage', 'Storage, Dateisysteme, Inodes', ('host',)),
    Action('smart', 'SMART und Fehlerverlauf', ('host',)),
    Action('maintenance', 'TRIM-Zeitplanung, Kernel, Backups', ('host',)),
    Action('volumes', 'Volumes und Storage-Zuordnung', ('ct', 'vm')),
    Action('filesystems', 'Dateisystembelegung', ('ct', 'vm')),
    Action('scan', 'Große Verzeichnisse im gewählten Pfad', ('ct',)),
    Action('trim', 'Ungenutzte Blöcke trimmen', ('ct', 'vm'), True,
           'Eigener Adapter; Community Scripts als Referenz'),
    Action('cache-clean', 'APT-Paketcache bereinigen', ('ct',), True,
           'Eigener Adapter; Community Scripts als Referenz'),
)


def registry(ctx):
    return [action for action in ACTIONS if ctx.scope in action.scopes]


def action_for(key, ctx):
    for action in registry(ctx):
        if action.id == key:
            return action
    raise CommandError('Aktion für dieses Ziel nicht verfügbar.')


def guest_running(ctx, runner):
    tool = 'pct' if ctx.scope == 'ct' else 'qm'
    output = runner.run([tool, 'status', str(ctx.id)]).text
    if not re.search(r'^status:\s+running\s*$', output, re.M):
        raise CommandError('Gast {} läuft nicht; kein automatischer Start.'.format(ctx.id))
    return tool


def qga(ctx, runner, command):
    guest_running(ctx, runner)
    help_text = runner.run(['qm', 'help', 'guest', 'cmd']).text
    if not re.search(r'\b' + re.escape(command) + r'\b', help_text):
        raise CommandError('Guest-Agent-Befehl auf dieser Proxmox-Version nicht verfügbar.')
    runner.run(['qm', 'guest', 'cmd', str(ctx.id), 'ping'])
    return ['qm', 'guest', 'cmd', str(ctx.id), command]


def cache_plan(ctx, runner):
    guest_running(ctx, runner)
    raw = runner.run(['pct', 'exec', str(ctx.id), '--', 'cat', '/etc/os-release']).text
    match = re.search(r'^ID=["\']?([a-z0-9_-]+)', raw, re.M)
    if not match or match.group(1) not in ('debian', 'ubuntu'):
        raise CommandError('Cache-Bereinigung nur für Debian und Ubuntu verfügbar.')
    size = runner.run(['pct', 'exec', str(ctx.id), '--', 'du', '-sxh', '/var/cache/apt/archives']).text
    command = ['pct', 'exec', str(ctx.id), '--', 'apt-get', 'clean']
    return command, 'APT-Cache: ' + size + '\nEntfernt heruntergeladene Paketarchive; keine Pakete oder Nutzdaten.'


def prepare(key, ctx, runner):
    action = action_for(key, ctx)
    if not action.mutation:
        raise CommandError('Aktion benötigt keine Änderungsfreigabe.')
    if key == 'cache-clean':
        command, impact = cache_plan(ctx, runner)
    elif ctx.scope == 'ct':
        guest_running(ctx, runner)
        command = ['pct', 'fstrim', str(ctx.id)]
        impact = 'Meldet freie Blöcke. Gemeldete Menge ist kein garantiert zurückgewonnener Speicherplatz.'
    else:
        command = qga(ctx, runner, 'fstrim')
        info_command = qga(ctx, runner, 'get-osinfo')
        os_info = json.loads(runner.run(info_command).text)
        if os_info.get('id') not in ('debian', 'ubuntu', 'fedora', 'centos', 'rhel', 'rocky', 'almalinux', 'arch', 'opensuse-leap'):
            raise CommandError('TRIM für dieses Gastbetriebssystem nicht freigegeben; nur lesende Diagnose verfügbar.')
        impact = 'TRIM über QEMU Guest Agent; Discard muss im vollständigen Storage-Pfad unterstützt sein.'
    return {'target': '{} {}'.format(ctx.scope.upper(), ctx.id), 'command': command,
            'impact': impact, 'display': shlex.join(command)}


def execute(key, ctx, runner, confirmed=False):
    action = action_for(key, ctx)
    if action.mutation:
        if not confirmed:
            raise CommandError('Explizite Bestätigung erforderlich.')
        if key == 'trim' and ctx.scope == 'ct':
            guest_running(ctx, runner)
            command = ['pct', 'fstrim', str(ctx.id)]
        else:
            command = prepare(key, ctx, runner)['command']
        return runner.run(command, timeout=180).text
    handlers = {'storage': do_storage, 'smart': do_smart, 'maintenance': do_maintenance,
                'volumes': do_volumes, 'filesystems': do_filesystems, 'scan': do_scan}
    return handlers[key](ctx, runner)


def do_storage(ctx, runner):
    sections = [('Proxmox Storage-Pools', ['pvesm', 'status']),
                ('Host-Dateisysteme (nicht Thin-Pool-Belegung)', ['df', '-hT']),
                ('Host-Inodes', ['df', '-hi']),
                ('Blockgeräte', ['lsblk', '-o', 'NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS'])]
    if shutil.which('lvs'):
        sections.append(('LVM: Thin-Pool / Thin-Volume gesondert lesen',
                         ['lvs', '-a', '-o', 'vg_name,lv_name,lv_attr,lv_size,pool_lv,data_percent,metadata_percent']))
    if shutil.which('zpool'):
        sections.extend([('ZFS-Pools', ['zpool', 'list']), ('ZFS-Zustand', ['zpool', 'status', '-x'])])
    return sections_report(sections, runner)


def sections_report(sections, runner):
    output = []
    for title, command in sections:
        try:
            text = runner.run(command).text
        except CommandError as exc:
            if hasattr(runner, 'cancel') and runner.cancel.is_set():
                raise
            text = 'Nicht verfügbar: ' + str(exc)
        output.extend([title, text, ''])
    return '\n'.join(output)


def do_volumes(ctx, runner):
    tool = 'pct' if ctx.scope == 'ct' else 'qm'
    raw = runner.run([tool, 'config', str(ctx.id)]).text
    output = ['Konfigurierte Volumes (keine Zuordnung anhand geratener LV-Namen):']
    for line in raw.splitlines():
        key, sep, value = line.partition(':')
        if not sep or not re.fullmatch(r'rootfs|mp\d+|(?:ide|sata|scsi|virtio)\d+', key):
            continue
        volume = value.strip().split(',')[0]
        output.append(line)
        if re.fullmatch(r'[A-Za-z0-9_-]+:[A-Za-z0-9_./-]+', volume):
            try:
                output.append('  Aufgelöst: ' + runner.run(['pvesm', 'path', volume]).text.strip())
            except CommandError as exc:
                output.append('  Auflösung nicht verfügbar: ' + str(exc))
        else:
            output.append('  Bind-Mount, Gerät oder leeres Laufwerk; kein geratenes Storage-Volume.')
        if ctx.scope == 'vm':
            output.append('  Discard: ' + ('aktiv' if re.search(r',discard=on(?:,|$)', value) else 'nicht als on konfiguriert'))
    return '\n'.join(output)


def do_filesystems(ctx, runner):
    if ctx.scope == 'vm':
        command = qga(ctx, runner, 'get-fsinfo')
        filesystems = json.loads(runner.run(command).text)
        if not isinstance(filesystems, list):
            raise CommandError('Unerwartete Guest-Agent-Dateisystemausgabe.')
        lines = ['Gast-Dateisystem | Typ | Belegt / Gesamt | Anteil',
                 'Nur Diagnose; Image-Dateisysteme mit 100% sind kein Speicherplatzalarm.']
        for entry in filesystems:
            total = entry.get('total-bytes')
            used = entry.get('used-bytes')
            valid = isinstance(total, (int, float)) and total > 0 and isinstance(used, (int, float))
            size = '{:.2f} / {:.2f} GiB'.format(used / 2**30, total / 2**30) if valid else 'nicht verfügbar'
            percent = '{:.1f}%'.format(100 * used / total) if valid else 'n/a'
            image = ' (schreibgeschütztes Image)' if entry.get('type') in ('erofs', 'squashfs', 'iso9660') else ''
            lines.append('{} | {}{} | {} | {}'.format(entry.get('mountpoint', '?'), entry.get('type', '?'), image, size, percent))
        return '\n'.join(lines)
    guest_running(ctx, runner)
    return sections_report([('Gast-Dateisysteme', ['pct', 'exec', str(ctx.id), '--', 'df', '-hT']),
                            ('Gast-Inodes', ['pct', 'exec', str(ctx.id), '--', 'df', '-hi'])], runner)


def do_scan(ctx, runner):
    guest_running(ctx, runner)
    # Resolve the selected directory first; du -x never follows directory symlinks.
    resolved = runner.run(['pct', 'exec', str(ctx.id), '--', 'readlink', '-e', ctx.mount]).text.strip()
    if resolved != ctx.mount or not PurePosixPath(resolved).is_absolute():
        raise CommandError('Scan-Ziel fehlt oder ist ein Symlink; Scan abgelehnt.')
    text = runner.run(['pct', 'exec', str(ctx.id), '--', 'timeout', '-k', '2', '55', 'du', '-x', '-h', '--max-depth=1', '--', ctx.mount],
                      timeout=60).text
    return 'Nur gewählter Pfad {}, keine fremden Dateisysteme; maximal 60 s.\n{}'.format(ctx.mount, text)


def do_smart(ctx, runner):
    if not shutil.which('smartctl'):
        raise CommandError('smartctl fehlt. Optionales Paket smartmontools durch den Administrator installieren.')
    disks = json.loads(runner.run(['lsblk', '-J', '-d', '-o', 'NAME,TYPE,MODEL,SIZE']).text)
    previous = read_json(STATE / 'smart.json', {})
    current = {}
    lines = ['SMART ist herstellerspezifisch; PASSED ist keine Ausfallgarantie.']
    metric_groups = [
        ('Reallocation-Attribut (herstellerspezifisch)', ('Reallocated_Sector_Ct', 'Reallocate_NAND_Blk_Cnt', 'Reallocated_Event_Count')),
        ('Pending-Attribut (herstellerspezifisch)', ('Current_Pending_Sector', 'Current_Pending_ECC_Cnt')),
        ('Nicht korrigierbare Fehler', ('Offline_Uncorrectable', 'Reported_Uncorrect', 'Uncorrectable_Error_Cnt')),
        ('CRC-Fehler', ('UDMA_CRC_Error_Count',)),
        ('Verschleißattribut', ('Wear_Leveling_Count', 'Percent_Lifetime_Remain', 'Percent_Lifetime_Used',
                                'Media_Wearout_Indicator', 'SSD_Life_Left')),
    ]
    for disk in disks.get('blockdevices', []):
        if disk.get('type') != 'disk' or not re.fullmatch(r'[A-Za-z0-9_-]+', disk.get('name', '')):
            continue
        dev = '/dev/' + disk['name']
        data = json.loads(runner.run(['smartctl', '-a', '-j', dev], allowed=None).text)
        # Identify history by serial internally, never display or transmit it.
        identity = data.get('serial_number') or dev
        attributes = {}
        for row in data.get('ata_smart_attributes', {}).get('table', []):
            attributes[row.get('name', str(row.get('id')))] = row.get('raw', {})
        passed = data.get('smart_status', {}).get('passed')
        health = 'PASSED' if passed is True else ('FEHLER' if passed is False else 'nicht verfügbar')
        temperature = data.get('temperature', {}).get('current')
        if temperature is None:
            raw_temperature = attributes.get('Temperature_Celsius', {}).get('string', '')
            match = re.match(r'\s*(-?\d+)', str(raw_temperature))
            temperature = match.group(1) if match else None
        temp_text = '{} °C'.format(temperature) if temperature is not None else 'nicht verfügbar'
        hours = data.get('power_on_time', {}).get('hours')
        hours_text = '{} h'.format(hours) if hours is not None else 'nicht verfügbar'
        lines.extend(['', '{} {} ({})'.format(dev, disk.get('model') or 'unbekanntes Modell', disk.get('size', '?')),
                      'SMART-Status: {} | Temperatur: {} | Betriebsstunden: {}'.format(health, temp_text, hours_text)])
        current_values = {}
        counters = []
        for label, names in metric_groups[:4]:
            found = next(((name, attributes[name]) for name in names if name in attributes), None)
            if found is None:
                counters.append('{}: nicht gemeldet'.format(label))
                continue
            name, raw = found
            value = raw.get('string') or raw.get('value')
            current_values[name] = value
            display = str(value).split(' (', 1)[0] if value is not None else 'nicht verfügbar'
            old = previous.get(identity, {}).get(name)
            try:
                delta = int(display) - int(str(old).split(' (', 1)[0]) if old is not None else 0
            except ValueError:
                delta = 0
            change = ' (+{} seit letzter Messung)'.format(delta) if delta > 0 else ''
            counters.append('{}: {}{}'.format(label, display, change))
        lines.extend(counters)
        wear = next(((name, attributes[name]) for name in metric_groups[4][1] if name in attributes), None)
        if wear:
            name, raw = wear
            value = raw.get('string') or raw.get('value')
            current_values[name] = value
            display = str(value).split(' (', 1)[0] if value is not None else 'nicht verfügbar'
            lines.append('Verschleißattribut {}: {} (herstellerspezifisch)'.format(name, display))
        else:
            lines.append('Verschleißattribut: nicht gemeldet')
        for name, raw in attributes.items():
            if name not in current_values and name in {item for _, names in metric_groups for item in names}:
                current_values[name] = raw.get('string') or raw.get('value')
        nvme = data.get('nvme_smart_health_information_log') or {}
        if nvme:
            lines.append('NVMe-Gesundheit:')
            nvme_fields = (
                ('critical_warning', 'Kritische Warnung'),
                ('temperature', 'Temperatur'),
                ('percentage_used', 'Verschleiß'),
                ('available_spare', 'Reserve'),
                ('media_errors', 'Medienfehler'),
                ('num_err_log_entries', 'Fehlerprotokolleinträge'),
            )
            for key, label in nvme_fields:
                value = nvme.get(key)
                if value is None:
                    continue
                suffix = ' °C' if key == 'temperature' else ('%' if key in ('percentage_used', 'available_spare') else '')
                lines.append('{}: {}{}'.format(label, value, suffix))
            warning = nvme.get('critical_warning')
            if warning is not None and warning != 0:
                lines.append('NVMe meldet kritische Warnungsbits: {}'.format(warning))
            if not any(nvme.get(key) is not None for key, _ in nvme_fields):
                lines.append('Keine bekannten NVMe-Gesundheitswerte gemeldet.')
        current[identity] = current_values
    write_json(STATE / 'smart.json', current)
    return '\n'.join(lines)


def do_maintenance(ctx, runner):
    result = sections_report([
        ('TRIM-Timer', ['systemctl', 'list-timers', '--all', '--no-pager', '*fstrim*']),
        ('fstrim Service/Timer', ['systemctl', 'cat', 'fstrim.timer', 'fstrim.service']),
        ('Letzte TRIM-Meldungen', ['journalctl', '-u', 'fstrim.service', '-n', '30', '--no-pager']),
        ('Kernel-Pakete (nur Anzeige)', ['dpkg-query', '-W', '-f=${Package}\t${Version}\n', 'proxmox-kernel-*', 'pve-kernel-*']),
        ('Storage-Belegung einschließlich Backup-Storage', ['pvesm', 'status', '--content', 'backup']),
    ], runner)
    # Show only scheduler lines mentioning trim; do not dump unrelated cron contents.
    from pathlib import Path
    cron = [Path('/etc/crontab'), Path('/var/spool/cron/crontabs/root')]
    cron.extend(Path('/etc/cron.d').glob('*'))
    for path in cron:
        if path.is_file() and not path.is_symlink():
            for line in path.read_text(errors='replace').splitlines():
                if re.search(r'\b(?:fstrim|pct\s+fstrim)\b', line):
                    result += '\n{}: {}'.format(path, line)
    log = Path('/var/log/fstrim.log')
    if log.is_file() and not log.is_symlink():
        with log.open('rb') as stream:
            stream.seek(max(0, log.stat().st_size - 12000))
            result += '\nLetzter Ausschnitt fstrim.log:\n' + stream.read(12000).decode('utf-8', 'replace')
    return result
