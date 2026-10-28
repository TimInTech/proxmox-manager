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

REPOSITORY = 'community-scripts/ProxmoxVE'
REVIEWED_COMMIT = '28fd647e6aed3db6d771cade4fb7c8c5deb48af3'
CORE_REPOSITORY = 'community-scripts/core'
CORE_COMMIT = 'af0fe772dd02bed10fd0124e3aacc86f2bc900d7'
CORE_SHA = '0e18236d58a4aec4b200c231c8a4a2387e378bbb'

# These are host tools selected from the Host Management category.
TOOLS = (
    {'id': 'disk-health', 'title': 'PVE Disk Health Tool',
     'path': 'tools/pve/disk-health.sh', 'sha': 'fa12746aedce484fe760bcccf4d1bcb3de58501b',
     'summary': 'SMART-Übersicht; bietet optional einen kurzen SMART-Selbsttest an.',
     'impact': 'Nur Diagnose bis auf Nachfrage. Kann smartmontools und nvme-cli per APT installieren.'},
    {'id': 'fstrim', 'title': 'PVE LXC Filesystem Trim',
     'path': 'tools/pve/fstrim.sh', 'sha': 'b63b4267c97ce3c62df4ad26c5e85131562f5950',
     'summary': 'TRIM für LXC-Dateisysteme auf SSD- und Thin-Provisioning-Speichern.',
     'impact': 'Ändert keine Gastdateien; meldet freie Blöcke an Storage. Betrifft ausgewählte CTs gemäß Helper-Menü.'},
    {'id': 'clean-lxcs', 'title': 'PVE LXC Cleaner',
     'path': 'tools/pve/clean-lxcs.sh', 'sha': 'e54a307a980130c43134c68d28a8c7cfcdf6b260',
     'summary': 'Bereinigt Paketcache und auf Wunsch Logs in ausgewählten LXC-Gästen.',
     'impact': 'Löscht gewählte Cache-/Log-Dateien in den bestätigten CTs; Logs sind danach nicht mehr verfügbar.'},
    {'id': 'kernel-clean', 'title': 'PVE Kernel Clean',
     'path': 'tools/pve/kernel-clean.sh', 'sha': '98351a487f14ed77df99f8945a9f45bf0b1870c0',
     'summary': 'Entfernt nicht mehr benötigte Kernelpakete vom Proxmox-Host.',
     'impact': 'Paketentfernung auf dem Host. Vor Bestätigung installierte und aktive Kernel prüfen.'},
    {'id': 'clean-orphaned-lvm', 'title': 'PVE Clean Orphaned LVM',
     'path': 'tools/pve/clean-orphaned-lvm.sh', 'sha': '18548a37a27a74a0bd7510b58efc0205618b2f64',
     'summary': 'Findet nicht zugeordnete LVM-Volumes und bietet interaktives Entfernen an.',
     'impact': 'Kann LVM-Volumes dauerhaft löschen. Helper-Auswahl sorgfältig prüfen; kein Papierkorb.'},
    {'id': 'host-backup', 'title': 'PVE Host Backup',
     'path': 'tools/pve/host-backup.sh', 'sha': '4a579cd1cb14dbe0623608bd238ea92e3bc84b07',
     'summary': 'Erstellt ein benutzerdefiniertes Backup ausgewählter Host-Dateien und Verzeichnisse.',
     'impact': 'Schreibt ein Archiv am gewählten Ort. Ein Backup auf demselben Host schützt nicht gegen Host-Ausfall.'},
    {'id': 'scaling-governor', 'title': 'PVE CPU Scaling Governor',
     'path': 'tools/pve/scaling-governor.sh', 'sha': '79622844c5051349a05acdd46490a5242cfb656c',
     'summary': 'Konfiguriert den CPU-Frequenz-Governor des Hosts.',
     'impact': 'Ändert Host-Energie-/Leistungsverhalten und möglicherweise Startkonfiguration.'},
    {'id': 'update-lxcs', 'title': 'PVE LXC Updater',
     'path': 'tools/pve/update-lxcs.sh', 'sha': 'ec3dd34f2ff1b1df3c4ce7e664aab5958f9dfca5',
     'summary': 'Aktualisiert Betriebssystempakete in ausgewählten LXC-Gästen.',
     'impact': 'Installiert Updates in bestätigten CTs; kann Dienste oder Gäste beeinflussen.'},
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


def _check_current(repository, path, expected):
    reference = _reference(repository, path)
    if not reference or reference['blob_sha'] != expected:
        raise RuntimeError('Werkzeug fehlt in der geprüften Quellenliste.')
    result = sources.check_reference(reference)
    if result.get('status') != 'geprüfter Stand':
        raise RuntimeError('Upstream ist nicht als geprüfter Stand bestätigt ({}). Start abgebrochen.'.format(
            result.get('status', 'Prüfung fehlgeschlagen')))


def _download_pinned(repository, commit, path, expected):
    url = 'https://raw.githubusercontent.com/{}/{}/{}'.format(repository, commit, path)
    data = _fetch(url)
    if git_blob_sha(data) != expected:
        raise RuntimeError('Prüfsumme von {} passt nicht zum geprüften Stand.'.format(path))
    return data


def preflight(tool_id):
    tool = next((item for item in TOOLS if item['id'] == tool_id), None)
    if not tool:
        raise ValueError('Unbekanntes Community-Werkzeug.')
    _check_current(REPOSITORY, tool['path'], tool['sha'])
    _check_current(CORE_REPOSITORY, 'core/core.func', CORE_SHA)
    return tool


def run_tool(tool_id):
    # Recheck immediately before fetching and executing pinned bytes.
    tool = preflight(tool_id)
    core_path = 'core/core.func'
    script = _download_pinned(REPOSITORY, REVIEWED_COMMIT, tool['path'], tool['sha'])
    core = _download_pinned(CORE_REPOSITORY, CORE_COMMIT, core_path, CORE_SHA)
    with tempfile.TemporaryDirectory(prefix='pman-community-') as directory:
        root = Path(directory)
        (root / 'core').mkdir(mode=0o700)
        script_path = root / 'tool.sh'
        script_path.write_bytes(script)
        script_path.chmod(0o700)
        (root / 'core' / 'core.func').write_bytes(core)
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
