"""Public GitHub metadata checks. No source downloads, imports or execution."""
import datetime
import json
from collections import Counter
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from .state import STATE, read_json, write_json

MANIFEST = Path(__file__).resolve().parent.parent / 'sources.json'


def fetch_metadata(url, etag=''):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'pman-maintenance/1',
               'X-GitHub-Api-Version': '2022-11-28'}
    if etag:
        headers['If-None-Match'] = etag
    request = urllib.request.Request(url, headers=headers)
    # Proxies are intentionally ignored: only the fixed public API is contacted.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=8) as response:
            body = response.read(1024 * 1024 + 1)
            if len(body) > 1024 * 1024:
                raise ValueError('API-Antwort zu groß.')
            return response.status, json.loads(body), response.headers.get('ETag', '')
    except urllib.error.HTTPError as exc:
        return exc.code, {}, ''


def check_reference(reference, fetch=fetch_metadata, previous=None):
    previous = previous or {}
    result = {'repository': reference['repository'], 'path': reference['path'],
              'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    directory, _, filename = reference['path'].rpartition('/')
    path = urllib.parse.quote(directory, safe='/')
    url = 'https://api.github.com/repos/{}/contents/{}'.format(reference['repository'], path)
    try:
        status, data, etag = fetch(url, previous.get('etag', ''))
        if status == 304 and previous.get('observed_sha'):
            sha = previous['observed_sha']
        elif status == 200 and isinstance(data, list):
            if any(not isinstance(row, dict) for row in data):
                raise ValueError('Ungültige Metadatenliste.')
            entry = next((row for row in data if row.get('name') == filename and row.get('type') == 'file'), None)
            if not entry:
                result['status'] = 'Quelle fehlt'
                return result
            sha = entry.get('sha')
            if not isinstance(sha, str) or not sha:
                raise ValueError('Fehlende Git-Blob-Prüfsumme.')
        elif status == 404:
            result['status'] = 'Quelle fehlt'
            return result
        else:
            raise ValueError('GitHub HTTP {}'.format(status))
        result.update(observed_sha=sha, etag=etag or previous.get('etag', ''),
                      status='geprüfter Stand' if sha == reference['blob_sha'] else 'Upstream geändert')
    except (OSError, ValueError, TimeoutError) as exc:
        result.update(status='Prüfung fehlgeschlagen', error=str(exc)[:200])
    return result


def check_sources(fetch=fetch_metadata):
    manifest = json.loads(MANIFEST.read_text())
    previous = read_json(STATE / 'source-status.json', {}) or {}
    old = {(r['repository'], r['path']): r for r in previous.get('references', [])}
    results = [check_reference(r, fetch, old.get((r['repository'], r['path'])))
               for r in manifest['references']]
    value = {'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'references': results}
    write_json(STATE / 'source-status.json', value)
    return value


def source_report():
    manifest = json.loads(MANIFEST.read_text())
    status = read_json(STATE / 'source-status.json', {}) or {}
    checked = {(r['repository'], r['path']): r for r in status.get('references', [])}
    rows = [checked.get((reference['repository'], reference['path']), {})
            for reference in manifest['references']]
    counts = Counter(row.get('status', 'Noch nicht geprüft') for row in rows)
    lines = ['Zuletzt geprüft: ' + status.get('checked_at', 'Noch nicht geprüft'),
             '{} Quellen | geprüft: {} | geändert: {} | fehlen: {} | Fehler: {} | offen: {}'.format(
                 len(rows), counts['geprüfter Stand'], counts['Upstream geändert'], counts['Quelle fehlt'],
                 counts['Prüfung fehlgeschlagen'], counts['Noch nicht geprüft']),
             'Eigene Adapter; geprüfte Community-Tools nur auf Auswahl und mit Versionsprüfung.',
             '', 'Referenzen:']
    for reference in manifest['references']:
        row = checked.get((reference['repository'], reference['path']), {})
        status_text = row.get('status', 'Noch nicht geprüft')
        reviewed = reference['reviewed_commit'][:8]
        observed = row.get('observed_sha')
        if status_text == 'geprüfter Stand':
            detail = 'geprüft: {}'.format(reviewed)
        elif status_text == 'Upstream geändert' and observed:
            detail = 'Referenz {} → aktuell {}'.format(reviewed, observed[:8])
        else:
            detail = status_text
        lines.append('{} / {} | {}'.format(reference['repository'], reference['path'], detail))
        if row.get('error'):
            lines.append('  Fehler: ' + row['error'])
    return '\n'.join(lines)
