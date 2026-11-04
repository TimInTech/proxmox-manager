"""Pinned Community Scripts launchers with fail-closed source verification."""
import hashlib
import json
import os
import pwd
import re
import subprocess
import tempfile
import urllib.request
from pathlib import Path

from . import sources
from .state import STATE, read_json

PROJECT_NAME = 'Proxmox VE Helper-Scripts'
EDITION = '(Community)'
LICENSE = 'MIT'
WEBSITE = 'https://community-scripts.org'  # GitHub homepage field of the repository
REPOSITORY = 'community-scripts/ProxmoxVE'
REPOSITORY_URL = 'https://github.com/' + REPOSITORY
REVIEWED_COMMIT = 'cfa250a79597db9aa8aaadea943c9e029316a2ef'
CORE_REPOSITORY = 'community-scripts/core'
CORE_COMMIT = '2867a755e4d1edd793612ab766c082220b1ac09f'
CORE_SHA = '1dd9d1c82b7e77040903eb3fce832dde80b6a04e'

# Menu groups by intent; a tool's position in TOOLS follows this order.
GROUPS = (
    ('check', 'PRÜFEN & SICHERN'),
    ('update', 'AKTUALISIEREN & OPTIMIEREN'),
    ('clean', 'AUFRÄUMEN – LÖSCHT DATEN'),
)
# Hazard levels are always shown as text; colour is only an extra cue.
LEVELS = {
    'read': ('LESEN', 'ändert nichts'),
    'change': ('ÄNDERT', 'verändert Host oder Gäste'),
    'delete': ('LÖSCHT', 'entfernt Daten oder Pakete, kein Papierkorb'),
}

# These are host tools selected from the Host Management category.
TOOLS = (
    {'id': 'disk-health', 'title': 'PVE Disk Health Tool', 'label': 'Disk Health',
     'group': 'check', 'level': 'read',
     'level_note': 'Diagnose; installiert nur auf Nachfrage Pakete',
     'path': 'tools/pve/disk-health.sh', 'sha': 'fa12746aedce484fe760bcccf4d1bcb3de58501b',
     'summary': 'SMART-Übersicht; bietet optional einen kurzen SMART-Selbsttest an.',
     'impact': 'Nur Diagnose bis auf Nachfrage. Kann smartmontools und nvme-cli per APT installieren.'},
    {'id': 'host-backup', 'title': 'PVE Host Backup', 'label': 'Host Backup',
     'group': 'check', 'level': 'change',
     'path': 'tools/pve/host-backup.sh', 'sha': '4a579cd1cb14dbe0623608bd238ea92e3bc84b07',
     'summary': 'Erstellt ein benutzerdefiniertes Backup ausgewählter Host-Dateien und Verzeichnisse.',
     'impact': 'Schreibt ein Archiv am gewählten Ort. Ein Backup auf demselben Host schützt nicht gegen Host-Ausfall.'},
    {'id': 'update-lxcs', 'title': 'PVE LXC Updater', 'label': 'LXC Updater',
     'group': 'update', 'level': 'change',
     'path': 'tools/pve/update-lxcs.sh', 'sha': '252972051fdd2ccf921111677965a2acb1424cb9',
     'summary': 'Aktualisiert Betriebssystempakete in ausgewählten LXC-Gästen.',
     'impact': 'Installiert Updates in bestätigten CTs; kann Dienste oder Gäste beeinflussen.'},
    {'id': 'fstrim', 'title': 'PVE LXC Filesystem Trim', 'label': 'LXC Filesystem Trim',
     'group': 'update', 'level': 'change',
     'path': 'tools/pve/fstrim.sh', 'sha': 'f2b30020614632dccc9bf2300b218f304661e2cf',
     'summary': 'TRIM für LXC-Dateisysteme auf SSD- und Thin-Provisioning-Speichern.',
     'impact': 'Ändert keine Gastdateien; meldet freie Blöcke an Storage. Betrifft ausgewählte CTs gemäß Helper-Menü.'},
    {'id': 'scaling-governor', 'title': 'PVE CPU Scaling Governor', 'label': 'CPU Scaling Governor',
     'group': 'update', 'level': 'change',
     'path': 'tools/pve/scaling-governor.sh', 'sha': '49ab7189d171b5e982f8a9c46405c614d9fe4f1a',
     'summary': 'Konfiguriert den CPU-Frequenz-Governor des Hosts.',
     'impact': 'Ändert Host-Energie-/Leistungsverhalten und möglicherweise Startkonfiguration.'},
    {'id': 'kernel-clean', 'title': 'PVE Kernel Clean', 'label': 'Kernel Clean',
     'group': 'clean', 'level': 'delete',
     'path': 'tools/pve/kernel-clean.sh', 'sha': '98351a487f14ed77df99f8945a9f45bf0b1870c0',
     'summary': 'Entfernt nicht mehr benötigte Kernelpakete vom Proxmox-Host.',
     'impact': 'Paketentfernung auf dem Host. Vor Bestätigung installierte und aktive Kernel prüfen.'},
    {'id': 'clean-lxcs', 'title': 'PVE LXC Cleaner', 'label': 'LXC Cleaner',
     'group': 'clean', 'level': 'delete',
     'path': 'tools/pve/clean-lxcs.sh', 'sha': '177feea9d1f9f442023d75ebb66a10b2a184ee67',
     'summary': 'Bereinigt Paketcache und auf Wunsch Logs in ausgewählten LXC-Gästen.',
     'impact': 'Löscht gewählte Cache-/Log-Dateien in den bestätigten CTs; Logs sind danach nicht mehr verfügbar.'},
    {'id': 'clean-orphaned-lvm', 'title': 'PVE Clean Orphaned LVM', 'label': 'Clean Orphaned LVM',
     'group': 'clean', 'level': 'delete',
     'path': 'tools/pve/clean-orphaned-lvm.sh', 'sha': '18548a37a27a74a0bd7510b58efc0205618b2f64',
     'summary': 'Findet nicht zugeordnete LVM-Volumes und bietet interaktives Entfernen an.',
     'impact': 'Kann LVM-Volumes dauerhaft löschen. Helper-Auswahl sorgfältig prüfen; kein Papierkorb.'},
)


def git_blob_sha(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()


def _fetch(url, limit=2 * 1024 * 1024):
    request = urllib.request.Request(url, headers={
        'Accept': 'application/vnd.github+json', 'User-Agent': 'pman-maintenance/1',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=12) as response:
        body = response.read(limit + 1)
    if len(body) > limit:
        raise RuntimeError('Upstream-Datei überschreitet die erlaubte Größe.')
    return body


def _reference(repository, path):
    manifest = json.loads(sources.MANIFEST.read_text())
    return next((item for item in manifest['references']
                 if item['repository'] == repository and item['path'] == path), None)


class SourceBlocked(RuntimeError):
    """Upstream is not in the reviewed state; nothing was downloaded or run."""

    def __init__(self, repository, path, reviewed, observed, status):
        self.repository, self.path = repository, path
        self.reviewed, self.observed, self.status = reviewed, observed, status
        super().__init__('Upstream ist nicht als geprüfter Stand bestätigt ({}). Start abgebrochen.'.format(status))

    def lines(self):
        lines = ['Start blockiert - nichts wurde ausgeführt.', '',
                 'Datei: {}/{}'.format(self.repository, self.path)]
        if self.status == 'Upstream geändert' and self.observed:
            lines.append('Geprüft {}  ->  aktuell {}'.format(self.reviewed[:7], self.observed[:7]))
        else:
            lines.append('Status: {}'.format(self.status))
        return lines + ['', 'pman startet nur Stände, die geprüft wurden.',
                        'Nächster Schritt: neuen pman-Release abwarten oder die Datei selbst prüfen.']


def _check_current(repository, path, expected):
    reference = _reference(repository, path)
    if not reference or reference['blob_sha'] != expected:
        raise RuntimeError('Werkzeug fehlt in der geprüften Quellenliste.')
    result = sources.check_reference(reference)
    if result.get('status') != 'geprüfter Stand':
        raise SourceBlocked(repository, path, expected, result.get('observed_sha'),
                            result.get('status', 'Prüfung fehlgeschlagen'))


def _download_pinned(repository, commit, path, expected):
    url = 'https://raw.githubusercontent.com/{}/{}/{}'.format(repository, commit, path)
    data = _fetch(url)
    if git_blob_sha(data) != expected:
        raise RuntimeError('Prüfsumme von {} passt nicht zum geprüften Stand.'.format(path))
    return data


def level_text(tool):
    """'WORD – meaning' for the hazard level, with the tool's own qualification if it has one."""
    word, meaning = LEVELS[tool['level']]
    return '{} – {}'.format(word, tool.get('level_note', meaning))


def find_tool(tool_id):
    tool = next((item for item in TOOLS if item['id'] == tool_id), None)
    if not tool:
        raise ValueError('Unbekanntes Community-Werkzeug.')
    return tool


def source_url(tool):
    """Browsable page of the exact pinned file."""
    return '{}/blob/{}/{}'.format(REPOSITORY_URL, REVIEWED_COMMIT, tool['path'])


def reviewed_at():
    return json.loads(sources.MANIFEST.read_text()).get('reviewed_at', '')


def stored_status():
    """Last stored source check (no network): per-tool findings and a summary."""
    manifest = json.loads(sources.MANIFEST.read_text())
    stored = read_json(STATE / 'source-status.json', {}) or {}
    rows = {(r.get('repository'), r.get('path')): r for r in stored.get('references', [])}
    reviewed = {(r['repository'], r['path']): r for r in manifest['references']}

    def finding(repository, path):
        row = rows.get((repository, path))
        if not row:
            return 'unknown', ''
        name = path.rpartition('/')[2]
        expected = reviewed[(repository, path)]['blob_sha']
        observed = row.get('observed_sha')
        # Compare with the current manifest, not the stored verdict: a re-pin
        # after the last check must not leave the old result standing.
        if observed:
            if observed == expected:
                return 'ok', ''
            return 'bad', '{} geändert ({} → {})'.format(name, expected[:7], observed[:7])
        return 'bad', '{}: {}'.format(name, row.get('status', 'Prüfung fehlgeschlagen'))

    core = finding(CORE_REPOSITORY, 'core/core.func')
    tools = {}
    for tool in TOOLS:
        own = finding(REPOSITORY, tool['path'])
        reasons = [reason for state, reason in (own, core) if state == 'bad']
        tools[tool['id']] = {'flagged': bool(reasons), 'reason': '; '.join(reasons)}
    states = [finding(r['repository'], r['path'])[0] for r in manifest['references']]
    return {'checked_at': stored.get('checked_at', ''), 'total': len(states),
            'deviating': states.count('bad'), 'unknown': states.count('unknown'), 'tools': tools}


class Launch:
    """Verified bytes of one tool and its core library, ready to run unchanged."""

    def __init__(self, tool, script, core):
        self.tool, self.script, self.core = tool, script, core


def preflight(tool_id):
    tool = find_tool(tool_id)
    _check_current(REPOSITORY, tool['path'], tool['sha'])
    _check_current(CORE_REPOSITORY, 'core/core.func', CORE_SHA)
    return tool


def prepare_launch(tool_id):
    """Check upstream, then download and hash-verify exactly what would be run."""
    tool = preflight(tool_id)
    script = _download_pinned(REPOSITORY, REVIEWED_COMMIT, tool['path'], tool['sha'])
    core = _download_pinned(CORE_REPOSITORY, CORE_COMMIT, 'core/core.func', CORE_SHA)
    return Launch(tool, script, core)


def run_launch(launch):
    # Recheck immediately before executing the already verified bytes.
    preflight(launch.tool['id'])
    with tempfile.TemporaryDirectory(prefix='pman-community-') as directory:
        root = Path(directory)
        (root / 'core').mkdir(mode=0o700)
        script_path = root / 'tool.sh'
        script_path.write_bytes(launch.script)
        script_path.chmod(0o700)
        (root / 'core' / 'core.func').write_bytes(launch.core)
        term = os.environ.get('TERM', 'xterm')
        if not re.fullmatch(r'[A-Za-z0-9._+-]{1,64}', term):
            term = 'xterm'
        env = {
            'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'HOME': pwd.getpwuid(0).pw_dir,
            'LANG': 'C.UTF-8',
            'TERM': term,
            'COMMUNITY_SCRIPTS_CORE_URL': root.as_uri(),
        }
        # Deliberately do not supply api/api.func: optional upstream telemetry is disabled.
        return subprocess.run(['bash', str(script_path)], cwd='/', env=env, check=False).returncode


def run_tool(tool_id):
    return run_launch(prepare_launch(tool_id))
