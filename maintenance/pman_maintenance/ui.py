"""Small curses frontend; workers never access terminal state."""
import curses
import fcntl
import os
import locale
import queue
import socket
import sys
import threading
from .actions import Context, execute, prepare, registry
from .runner import Runner
from .sources import source_report
from .state import STATE, private_dir
from . import community, view
from .view import clean_text, wrap_output  # noqa: F401  (re-exported for callers and tests)


def navigate(index, direction, count):
    return (index + direction) % count if count else 0


def page_offset(offset, direction, page_size, line_count):
    last = max(0, line_count - max(1, page_size))
    target = offset + (1 if direction > 0 else -1) * max(1, page_size)
    return min(last, max(0, target))


def terminal_usable(height, width):
    return height >= 12 and width >= 45


def action_description(action):
    descriptions = {
        'storage': 'Zeigt Speicher, Dateisysteme und Inodes des Hosts.',
        'smart': 'Liest SMART-Zustand und speichert einen lokalen Vergleichsstand.',
        'maintenance': 'Zeigt TRIM-Zeitplanung, Kernel und Backup-Speicher.',
        'volumes': 'Zeigt die konfigurierten Volumes des ausgewählten Gastes.',
        'filesystems': 'Zeigt die Dateisystembelegung des ausgewählten Gastes.',
        'scan': 'Untersucht große Verzeichnisse im ausgewählten CT-Pfad.',
        'trim': 'Meldet freie Blöcke des ausgewählten Gastes an den Speicher.',
        'cache-clean': 'Entfernt heruntergeladene APT-Paketarchive im ausgewählten CT.',
    }
    return '{}: {}'.format('Änderung mit Bestätigung' if action.mutation else 'Diagnose',
                          descriptions.get(action.id, action.title))


def mutate(key, ctx, runner):
    private_dir(STATE)
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    fd = os.open(str(STATE / 'actions.lock'), flags, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise RuntimeError('Unsichere Wartungssperre.')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return execute(key, ctx, runner, confirmed=True)
    finally:
        os.close(fd)


def run_tui(ctx):
    # pman uses LC_ALL=C for parsing. The optional Unicode UI needs UTF-8.
    try:
        locale.setlocale(locale.LC_ALL, 'C.UTF-8')
    except locale.Error:
        locale.setlocale(locale.LC_ALL, '')
    if not locale.getpreferredencoding(False).lower().replace('-', '').startswith('utf8'):
        raise RuntimeError('Für die Oberfläche ist eine UTF-8-Locale erforderlich.')
    try:
        curses.wrapper(_screen, ctx)
    except curses.error as exc:
        raise RuntimeError('Terminal unterstützt die Oberfläche nicht; TERM und Fenstergröße prüfen.') from exc
    finally:
        # curses restores terminal mode but leaves the cursor at the last status row.
        print()


def ascii_mode(env=os.environ):
    return env.get('PMAN_ASCII') == '1' or env.get('TERM', '') in ('linux', 'vt100', 'vt220')


def hyperlinks_supported(env=os.environ):
    """OSC 8 links only where support is known; the URL stays readable text either way."""
    forced = env.get('PMAN_HYPERLINKS')
    if forced in ('0', '1'):
        return forced == '1'
    term = env.get('TERM', '')
    if env.get('TMUX') or env.get('STY') or term.startswith(('screen', 'linux', 'vt', 'dumb')):
        return False
    if env.get('WT_SESSION') or env.get('KITTY_WINDOW_ID') or 'kitty' in term or 'foot' in term:
        return True
    if env.get('TERM_PROGRAM') in ('iTerm.app', 'WezTerm', 'vscode', 'ghostty'):
        return True
    vte = env.get('VTE_VERSION', '')
    return vte.isdigit() and int(vte) >= 5000


def emit_links(frame):
    """Re-print link text wrapped in OSC 8 after curses drew it (curses cannot do this itself).

    The visible text is the URL itself, so nothing is hidden behind a label.
    """
    out = []
    for seg in frame.segs:
        if seg.link and seg.text:
            out.append('\x1b7\x1b[0m\x1b[{};{}H\x1b]8;;{}\x1b\\{}\x1b]8;;\x1b\\\x1b8'.format(
                seg.y + 1, seg.x + 1, seg.link, seg.text))
    if out:
        os.write(sys.stdout.fileno(), ''.join(out).encode('utf-8'))


def _stored_status():
    try:
        return community.stored_status()
    except (OSError, RuntimeError, ValueError):
        return {'checked_at': '', 'total': 0, 'deviating': 0, 'unknown': 0,
                'tools': {t['id']: {'flagged': False, 'reason': ''} for t in community.TOOLS}}


def _attrs(color):
    """Curses attributes per flag letter; a badge pair is only set with fixed 256 colours."""
    attrs = {'B': curses.A_BOLD, 'R': curses.A_REVERSE}
    if color == '256':
        for number, (style, (fg, bg)) in enumerate(view.BADGE_PAIRS.items(), 1):
            curses.init_pair(number, fg, bg)
            attrs[view.BADGE_LETTER[style]] = curses.color_pair(number)
    return attrs


def _screen(screen, ctx):
    curses.curs_set(0)
    screen.keypad(True)
    screen.timeout(100)
    color = ''
    if curses.has_colors() and 'NO_COLOR' not in os.environ:
        curses.start_color()
        if getattr(curses, 'COLORS', 0) >= 256:
            color = '256'
    attrs = _attrs(color)
    ascii_only = ascii_mode()
    links = hyperlinks_supported()
    last_links = None
    host = socket.gethostname()
    selected = 0
    scroll = 0
    output = [action_description(registry(ctx)[0]), '', 'Enter startet die Diagnose.']
    pending = None
    pending_community = None
    previewing = False
    saved_view = None
    flush_confirmation = False
    community_mode = False
    detail_mode = False
    community_selected = 0
    stored = _stored_status()
    busy = False
    busy_kind = None
    cancel = threading.Event()
    messages = queue.Queue()
    worker = None
    status = 'Bereit'
    page = 1
    total = 0

    def start(kind, action=None):
        nonlocal busy, busy_kind, status, worker
        busy_kind = kind
        cancel.clear()
        busy = True
        status = 'Prüfung läuft – Esc bricht ab'
        def job():
            try:
                runner = Runner(cancel)
                if kind == 'prepare':
                    value = prepare(action.id, ctx, runner)
                elif kind == 'sources':
                    value = source_report()
                elif kind == 'community-check':
                    value = community.prepare_launch(action['id'])
                elif kind == 'mutate':
                    value = mutate(action.id, ctx, runner)
                else:
                    value = execute(action.id, ctx, runner)
                messages.put((kind, value, action))
            except Exception as exc:
                messages.put(('error', exc, action))
        worker = threading.Thread(target=job, daemon=True)
        worker.start()

    def show_selection():
        nonlocal output, scroll
        scroll = 0
        actions = registry(ctx)
        if community_mode:
            output = (view.community_detail(community.TOOLS[community_selected], stored)
                      if community_selected < len(community.TOOLS) else ['Zurück zum Wartungsmenü.'])
        elif selected < len(actions):
            output = [action_description(actions[selected]), '', 'Quelle: ' + actions[selected].source]
        elif ctx.scope == 'host' and selected == len(actions):
            output = view.community_intro()
        else:
            output = ['Herkunft und Aktualitätsstatus', 'Enter öffnet diese Ansicht.']

    def help_text(page, total):
        if busy:
            return 'Esc/q Abbruch | danach q Ende'
        if previewing:
            return '↑↓ PgUp/PgDn blättern | Esc zurück zur Bestätigung'
        if pending_community:
            return ('PgDn: alle Details lesen | Esc/n Abbruch' if scroll + page < total
                    else 'v Quellcode | j Starten | Esc/n Abbruch | PgUp/PgDn')
        if pending:
            return ('PgDn: alle Details lesen | Esc/n Abbruch' if scroll + page < total
                    else 'j Bestätigen | Esc/n Abbruch | PgUp/PgDn')
        if detail_mode:
            return 'PgUp/PgDn Blättern | Esc Zurück | q Ende'
        if community_mode:
            return '↑↓ Auswahl | Enter prüfen & bestätigen | Esc zurück | q Ende'
        if ctx.scope == 'ct':
            return '↑↓ Auswahl | Enter | Tab Pfad | Esc | q Ende'
        return '↑↓ Auswahl | Enter | PgUp/PgDn | Esc | q Ende'

    def build_model(height):
        actions = registry(ctx)
        modal = bool(detail_mode or pending or pending_community or busy)
        crumb = ''
        if community_mode:
            crumb = 'Community-Skript starten?' if pending_community else 'Community-Skripte'
        elif ctx.scope == 'ct':
            crumb = 'Scan: ' + ctx.mount
        title = ' | '.join(part for part in (
            'pman Wartung', '{} {}'.format(ctx.scope.upper(), ctx.id or '').strip(), crumb) if part)
        if community_mode:
            rows = view.community_rows(stored)
            active = community_selected
        else:
            rows = view.main_rows(actions, ctx.scope)
            active = selected
        selected_title = (community.TOOLS[community_selected]['title']
                          if community_mode and community_selected < len(community.TOOLS)
                          else [r for r in rows if r.kind != 'header'][active].label)
        return view.Model(
            title=title, rows=rows, selected=active, detail=output, modal=modal,
            modal_title='Auswahl: ' + selected_title,
            prov=view.provenance(view.status_line(stored)) if community_mode else None,
            scroll=scroll, help=help_text, status=status,
            small=('Terminal mindestens 45 Spalten und 12 Zeilen.',
                   'Esc/q: Abbruch; danach q beendet.' if busy else 'Vergrößern oder q zum Beenden.'),
            details_heading=not community_mode)

    try:
        while True:
            try:
                kind, value, action = messages.get_nowait()
                busy = False
                scroll = 0
                flush_confirmation = True
                if cancel.is_set():
                    output = (['Abbruch angefordert. Die Änderung kann teilweise oder vollständig',
                               'ausgeführt worden sein; dies ist kein Rollback. Zustand prüfen.']
                              if busy_kind == 'mutate' else
                              ['Abgebrochen; keine bestätigte Änderung wurde gestartet.'])
                    detail_mode = True
                    status = 'Abgebrochen'
                elif kind == 'community-check':
                    pending_community = value
                    output = view.confirm_blocks(value, host)
                    status = 'Wartet auf Bestätigung'
                elif kind == 'prepare':
                    pending = action
                    output = ['Ziel: ' + value['target'], 'Befehl: ' + value['display'], value['impact'],
                              '', 'Änderung ausführen? j = bestätigen, Esc = abbrechen',
                              'Abbruch eines laufenden Befehls ist kein Rollback.']
                    status = 'Bestätigung erforderlich'
                elif kind == 'error' and isinstance(value, community.SourceBlocked):
                    output = value.lines()
                    detail_mode = True
                    status = 'Start blockiert'
                else:
                    text = value if kind != 'error' else str(value)
                    output = clean_text(text).expandtabs(4).splitlines() or ['Keine Ausgabe.']
                    detail_mode = True
                    status = ('Abgebrochen' if cancel.is_set() else 'Fehlgeschlagen') if kind == 'error' else 'Erfolgreich'
            except queue.Empty:
                pass
            screen.erase()
            height, width = screen.getmaxyx()
            frame = view.render(build_model(height), height, width, ascii_only)
            page, total = frame.page, frame.total
            for seg in frame.segs:
                flags = view.attr_flags(seg.style, color)
                attr = 0
                for letter in flags:
                    attr |= attrs.get(letter, 0)
                try:
                    screen.addnstr(seg.y, seg.x, seg.text, len(seg.text), attr)
                except curses.error:
                    pass
            screen.refresh()
            if links:
                signature = tuple((s.y, s.x, s.text, s.link) for s in frame.segs if s.link)
                if signature != last_links:
                    last_links = signature
                    emit_links(frame)
            if flush_confirmation:
                flush_confirmation = False
                try:
                    curses.flushinp()
                except curses.error:
                    confirming = bool(pending or pending_community)
                    pending = None
                    pending_community = None
                    detail_mode = True
                    if confirming:
                        output = ['Eingabepuffer konnte nicht geleert werden; Bestätigung abgebrochen.']
                    else:
                        output += ['', 'Eingabepuffer konnte nicht geleert werden. Ergebnis oben beachten.']
                    status = 'Eingabefehler'
                    continue
            key = screen.getch()
            if key == -1:
                continue
            if not terminal_usable(height, width):
                if busy and key in (27, ord('q')):
                    cancel.set()
                    status = 'Abbruch angefordert.'
                elif key == ord('q'):
                    return
                continue
            if busy:
                if key in (27, ord('q')):
                    cancel.set()
                    status = 'Abbruch angefordert; CT-Scan kann bis zum Gast-Zeitlimit (55 s) weiterlaufen.'
                continue
            if previewing:
                if key in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                    scroll = page_offset(scroll, -1 if key == curses.KEY_PPAGE else 1, page, total)
                elif key == curses.KEY_UP:
                    scroll = max(0, scroll - 1)
                elif key == curses.KEY_DOWN:
                    scroll = min(max(0, total - page), scroll + 1)
                elif key in (27, ord('n'), ord('N')):
                    previewing = False
                    output, scroll = saved_view
                    status = 'Wartet auf Bestätigung'
                elif key == ord('q'):
                    return
                continue
            if (pending or pending_community) and key in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                scroll = page_offset(scroll, -1 if key == curses.KEY_PPAGE else 1, page, total)
                continue
            if (pending or pending_community) and key in (ord('j'), ord('J')) and scroll + page < total:
                status = 'Bitte zuerst alle Details mit Bild ab lesen.'
                continue
            if pending_community:
                if key in (ord('v'), ord('V')):
                    saved_view = (output, scroll)
                    previewing = True
                    output = view.preview_blocks(pending_community)
                    scroll = 0
                    status = 'Quellcode-Vorschau – es wird nichts ausgeführt'
                    continue
                if key in (ord('j'), ord('J')):
                    launch = pending_community
                    pending_community = None
                    status = 'Prüfe Quellstand und starte Helper Script …'
                    screen.addnstr(height - 1, 0, ' ' * (width - 1), width - 1)
                    screen.addnstr(height - 1, 0, status, width - 1, curses.A_BOLD)
                    screen.refresh()
                    try:
                        curses.endwin()
                        exit_code = community.run_launch(launch)
                        detail_mode = True
                        output = view.result_blocks(launch, exit_code)
                        status = 'Abgeschlossen' if exit_code == 0 else 'Helper Script mit Fehler beendet'
                    except community.SourceBlocked as exc:
                        detail_mode = True
                        output = exc.lines()
                        status = 'Start blockiert'
                    except Exception as exc:
                        detail_mode = True
                        output = ['Start abgebrochen:', clean_text(exc)]
                        status = 'Quelle geändert, nicht verfügbar oder Start fehlgeschlagen'
                    finally:
                        last_links = None
                        try:
                            curses.reset_prog_mode()
                            screen.keypad(True)
                            screen.refresh()
                        except curses.error:
                            pass
                    continue
                if key in (27, ord('n'), ord('N'), ord('q')):
                    pending_community = None
                    output = ['Start abgebrochen; es wurde kein Helper Script ausgeführt.']
                    status = 'Abgebrochen'
                    if key == ord('q'):
                        return
                continue
            if pending:
                if key in (ord('j'), ord('J')):
                    action = pending
                    pending = None
                    start('mutate', action)
                elif key in (27, ord('n'), ord('N'), ord('q')):
                    pending = None
                    output = ['Änderung abgebrochen.']
                    status = 'Abgebrochen'
                    if key == ord('q'):
                        return
                continue
            if key == ord('q'):
                return
            if key == 27:
                if detail_mode:
                    detail_mode = False
                    show_selection()
                    status = 'Bereit'
                    continue
                if community_mode:
                    community_mode = False
                    selected = len(registry(ctx))
                    show_selection()
                    status = 'Bereit'
                    continue
                return
            if detail_mode and key not in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                continue
            if key in (curses.KEY_UP, curses.KEY_DOWN):
                step = -1 if key == curses.KEY_UP else 1
                if community_mode:
                    community_selected = navigate(community_selected, step, len(community.TOOLS) + 1)
                    status = 'Bereit – es wurde noch nichts gestartet'
                else:
                    selected = navigate(selected, step, len(registry(ctx)) + (2 if ctx.scope == 'host' else 1))
                show_selection()
            elif key in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                scroll = page_offset(scroll, -1 if key == curses.KEY_PPAGE else 1, page, total)
            elif key == 9 and ctx.scope == 'ct':
                mounts = ['/var', '/home', '/opt', '/srv']
                ctx = Context(ctx.scope, ctx.id, mounts[(mounts.index(ctx.mount) + 1) % len(mounts)])
            elif key in (10, 13, curses.KEY_ENTER):
                actions = registry(ctx)
                if community_mode:
                    if community_selected == len(community.TOOLS):
                        community_mode = False
                        selected = len(actions)
                        show_selection()
                        status = 'Bereit'
                    else:
                        output = ['Prüfe den aktuellen Upstream-Stand und lade die Datei …',
                                  'Das kann bis zu einer Minute dauern; Esc bricht ab.']
                        start('community-check', community.TOOLS[community_selected])
                elif ctx.scope == 'host' and selected == len(actions):
                    community_mode = True
                    community_selected = 0
                    stored = _stored_status()
                    show_selection()
                    status = 'Bereit – es wurde noch nichts gestartet'
                elif selected == len(actions) + (1 if ctx.scope == 'host' else 0):
                    start('sources')
                else:
                    action = actions[selected]
                    start('prepare' if action.mutation else 'execute', action)
    finally:
        cancel.set()
        if worker and worker.is_alive():
            worker.join(4)
