"""Small curses frontend; workers never access terminal state."""
import curses
import fcntl
import os
import locale
import queue
import re
import threading
import textwrap
from .actions import Context, execute, prepare, registry
from .runner import Runner
from .sources import source_report
from .state import STATE, private_dir
from . import community


def clean_text(value):
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(value))
    return ''.join(c for c in value if c in '\n\t' or (c.isprintable() and c != '\x1b'))


def navigate(index, direction, count):
    return (index + direction) % count if count else 0


def page_offset(offset, direction, page_size, line_count):
    last = max(0, line_count - max(1, page_size))
    target = offset + (1 if direction > 0 else -1) * max(1, page_size)
    return min(last, max(0, target))


def terminal_usable(height, width):
    return height >= 12 and width >= 45


def wrap_output(lines, width):
    return [piece for line in lines for piece in
            (textwrap.wrap(clean_text(line).expandtabs(4), max(1, width),
                           replace_whitespace=False) or [''])]


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


def _screen(screen, ctx):
    curses.curs_set(0)
    screen.keypad(True)
    screen.timeout(100)
    color = 0
    if curses.has_colors() and 'NO_COLOR' not in os.environ:
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_CYAN, -1)
        color = curses.color_pair(1)
    selected = 0
    scroll = 0
    output = [action_description(registry(ctx)[0]), '', 'Enter startet die Diagnose.']
    pending = None
    pending_community = None
    flush_confirmation = False
    community_mode = False
    detail_mode = False
    community_selected = 0
    busy = False
    busy_kind = None
    cancel = threading.Event()
    messages = queue.Queue()
    worker = None
    status = 'Bereit'

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
                    value = community.preflight(action['id'])
                elif kind == 'mutate':
                    value = mutate(action.id, ctx, runner)
                else:
                    value = execute(action.id, ctx, runner)
                messages.put((kind, value, action))
            except Exception as exc:
                messages.put(('error', str(exc), action))
        worker = threading.Thread(target=job, daemon=True)
        worker.start()

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
                    output = ['COMMUNITY SCRIPT – Bestätigung', 'Ziel: HOST; Gäste werden im Helper ausgewählt.',
                              'Werkzeug: ' + value['title'], 'Auswirkung: ' + value['impact'],
                              'Quelle: ' + community.REPOSITORY + '/' + value['path'],
                              'Geprüfte Revision: ' + community.REVIEWED_COMMIT,
                              'Prüfergebnis: Live-Upstream und Core stimmen überein.',
                              'Vor Ausführung werden Quelle und Dateiprüfsummen erneut geprüft.',
                              'j = starten | Esc = abbrechen']
                    status = 'Wartet auf Bestätigung'
                elif kind == 'prepare':
                    pending = action
                    output = ['Ziel: ' + value['target'], 'Befehl: ' + value['display'], value['impact'],
                              '', 'Änderung ausführen? j = bestätigen, Esc = abbrechen',
                              'Abbruch eines laufenden Befehls ist kein Rollback.']
                    status = 'Bestätigung erforderlich'
                else:
                    output = clean_text(value).expandtabs(4).splitlines() or ['Keine Ausgabe.']
                    detail_mode = True
                    status = ('Abgebrochen' if cancel.is_set() else 'Fehlgeschlagen') if kind == 'error' else 'Erfolgreich'
            except queue.Empty:
                pass
            screen.erase()
            height, width = screen.getmaxyx()
            def put(y, text, attr=0, x=0, limit=None):
                if 0 <= y < height and width > x + 1:
                    try:
                        screen.addnstr(y, x, clean_text(text), min(width - x - 1, limit or width), attr)
                    except curses.error:
                        pass
            if height < 12 or width < 45:
                put(0, 'Terminal mindestens 45 Spalten und 12 Zeilen.')
                put(1, 'Esc/q: Abbruch; danach q beendet.' if busy else 'Vergrößern oder q zum Beenden.')
            else:
                actions = registry(ctx)
                if community_mode:
                    menu = [tool['title'] for tool in community.TOOLS] + ['← Zurück zum Wartungsmenü']
                    active_selected = community_selected
                else:
                    menu = [a.title + (' [Änderung]' if a.mutation else '') for a in actions]
                    if ctx.scope == 'host':
                        menu.append('Community PVE-Werkzeuge ({})'.format(len(community.TOOLS)))
                    menu.append('Herkunft und Aktualitätsstatus')
                    active_selected = selected
                title = 'pman Wartung | {} {} | {}'.format(
                    ctx.scope.upper(), ctx.id or '',
                    'COMMUNITY PVE-WERKZEUGE' if community_mode else
                    ('Wartung | Scan: ' + ctx.mount if ctx.scope == 'ct' else 'Wartung'))
                put(0, title, color | curses.A_BOLD)
                modal = detail_mode or pending or pending_community or busy
                side_by_side = width >= 76 and not modal
                if modal:
                    selected_title = (community.TOOLS[community_selected]['title']
                                      if community_mode and community_selected < len(community.TOOLS)
                                      else menu[active_selected])
                    put(1, 'Auswahl: ' + selected_title, curses.A_BOLD)
                    start_y, detail_x, detail_width = 3, 0, width - 2
                elif side_by_side:
                    menu_width = min(34, width // 2)
                    menu_height = max(1, height - 5)
                    first = max(0, active_selected - menu_height + 1)
                    for row, index in enumerate(range(first, min(len(menu), first + menu_height)), 2):
                        put(row, ('> ' if index == active_selected else '  ') + menu[index],
                            curses.A_REVERSE if index == active_selected else 0, limit=menu_width - 1)
                    detail_x, detail_width, start_y = menu_width + 1, width - menu_width - 3, 2
                    put(1, 'Details', color | curses.A_BOLD, x=detail_x)
                else:
                    menu_height = min(len(menu), max(2, height // 4))
                    first = max(0, active_selected - menu_height + 1)
                    for row, index in enumerate(range(first, min(len(menu), first + menu_height)), 2):
                        put(row, ('> ' if index == active_selected else '  ') + menu[index],
                            curses.A_REVERSE if index == active_selected else 0)
                    start_y, detail_x, detail_width = menu_height + 3, 0, width - 2
                page = max(1, height - start_y - 3)
                wrapped = wrap_output(output, detail_width)
                scroll = min(scroll, max(0, len(wrapped) - page))
                for row, line in enumerate(wrapped[scroll:scroll + page], start_y):
                    put(row, line, x=detail_x, limit=detail_width)
                first_line = scroll + 1 if wrapped else 0
                last_line = min(len(wrapped), scroll + page)
                put(height - 3, 'Zeilen {}–{} von {}'.format(first_line, last_line, len(wrapped)), color)
                if busy:
                    help_text = 'Esc/q Abbruch | danach q Ende'
                elif pending or pending_community:
                    help_text = ('PgDn: alle Details lesen | Esc/n Abbruch' if scroll + page < len(wrapped)
                                 else 'j Bestätigen | Esc/n Abbruch | PgUp/PgDn')
                elif detail_mode:
                    help_text = 'PgUp/PgDn Blättern | Esc Zurück | q Ende'
                else:
                    help_text = '↑↓ Auswahl | Enter | PgUp/PgDn | Esc | q Ende'
                    if ctx.scope == 'ct':
                        help_text = '↑↓ Auswahl | Enter | Tab Pfad | Esc | q Ende'
                put(height - 2, help_text, color)
                put(height - 1, status, color)
            screen.refresh()
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
            if (pending or pending_community) and key in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                scroll = page_offset(scroll, -1 if key == curses.KEY_PPAGE else 1, page, len(wrapped))
                continue
            if (pending or pending_community) and key in (ord('j'), ord('J')) and scroll + page < len(wrapped):
                status = 'Bitte zuerst alle Details mit Bild ab lesen.'
                continue
            if pending_community:
                if key in (ord('j'), ord('J')):
                    tool = pending_community
                    pending_community = None
                    status = 'Prüfe Quellstand und starte Helper Script …'
                    put(height - 1, status, color)
                    screen.refresh()
                    try:
                        curses.endwin()
                        exit_code = community.run_tool(tool['id'])
                        detail_mode = True
                        output = ['Community Script beendet.', 'Exit-Code: {}'.format(exit_code),
                                  'Quelle: community-scripts/ProxmoxVE @ {}'.format(community.REVIEWED_COMMIT[:12])]
                        status = 'Abgeschlossen' if exit_code == 0 else 'Helper Script mit Fehler beendet'
                    except Exception as exc:
                        detail_mode = True
                        output = ['Start abgebrochen:', clean_text(exc)]
                        status = 'Quelle geändert, nicht verfügbar oder Start fehlgeschlagen'
                    finally:
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
                    scroll = 0
                    if community_mode and community_selected < len(community.TOOLS):
                        tool = community.TOOLS[community_selected]
                        output = [tool['summary'], 'Risiko / Auswirkung: ' + tool['impact']]
                    elif selected < len(registry(ctx)):
                        output = [action_description(registry(ctx)[selected])]
                    else:
                        output = ['Enter öffnet diese Ansicht.']
                    status = 'Bereit'
                    continue
                if community_mode:
                    community_mode = False
                    selected = len(registry(ctx))
                    output = ['Community-Werkzeugmenü geschlossen.']
                    status = 'Bereit'
                    continue
                return
            if detail_mode and key not in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                continue
            if key in (curses.KEY_UP, curses.KEY_DOWN):
                if community_mode:
                    scroll = 0
                    community_selected = navigate(community_selected, -1 if key == curses.KEY_UP else 1,
                                                   len(community.TOOLS) + 1)
                    if community_selected < len(community.TOOLS):
                        tool = community.TOOLS[community_selected]
                        output = [tool['summary'], '', 'Risiko / Auswirkung:', tool['impact'], '',
                                  'Quelle: {} @ {}'.format(tool['path'], community.REVIEWED_COMMIT[:12]),
                                  'Lizenz: MIT; Helper wird als Community-Code ausgeführt.']
                    else:
                        output = ['Community-Menü schließen und zur Wartungsansicht zurückkehren.']
                else:
                    selected = navigate(selected, -1 if key == curses.KEY_UP else 1,
                                        len(registry(ctx)) + (2 if ctx.scope == 'host' else 1))
                    scroll = 0
                    if selected < len(registry(ctx)):
                        action = registry(ctx)[selected]
                        output = [action_description(action), '', 'Quelle: ' + action.source]
                    else:
                        output = ['Community-Werkzeuge' if ctx.scope == 'host' and selected == len(registry(ctx)) else 'Herkunft und Aktualitätsstatus',
                                  'Enter öffnet diese Ansicht.']
            elif key in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                if height >= 12 and width >= 45:
                    scroll = page_offset(scroll, -1 if key == curses.KEY_PPAGE else 1, page, len(wrapped))
            elif key == 9 and ctx.scope == 'ct':
                mounts = ['/var', '/home', '/opt', '/srv']
                ctx = Context(ctx.scope, ctx.id, mounts[(mounts.index(ctx.mount) + 1) % len(mounts)])
            elif key in (10, 13, curses.KEY_ENTER):
                actions = registry(ctx)
                if community_mode:
                    if community_selected == len(community.TOOLS):
                        community_mode = False
                        selected = len(actions)
                        output = ['Zurück im Wartungsmenü.']
                        status = 'Bereit'
                    else:
                        tool = community.TOOLS[community_selected]
                        start('community-check', tool)
                elif ctx.scope == 'host' and selected == len(actions):
                    community_mode = True
                    community_selected = 0
                    tool = community.TOOLS[0]
                    output = [tool['summary'], '', 'Risiko / Auswirkung:', tool['impact'], '',
                              'Jeder Start prüft den aktuellen Upstream und die Skript-Prüfsumme.',
                              'Die optionale Upstream-Telemetrie wird nicht geladen.']
                    status = 'Community Scripts: {} geprüfte Host-Werkzeuge'.format(len(community.TOOLS))
                elif selected == len(actions) + (1 if ctx.scope == 'host' else 0):
                    start('sources')
                else:
                    action = actions[selected]
                    start('prepare' if action.mutation else 'execute', action)
    finally:
        cancel.set()
        if worker and worker.is_alive():
            worker.join(4)
