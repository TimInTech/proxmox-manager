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
    output = ['Diagnosen ändern keine Gastdaten. Änderungen erfordern eine eigene Bestätigung.',
              'Community PVE-Werkzeuge sind separat im Host-Menü verfügbar; Start nur nach Bestätigung.',
              'CT-Scanpfad mit Tab umschalten: /var, /home, /opt, /srv.']
    pending = None
    pending_community = None
    community_mode = False
    community_selected = 0
    busy = False
    cancel = threading.Event()
    messages = queue.Queue()
    worker = None
    status = 'Bereit'

    def start(kind, action=None):
        nonlocal busy, status, worker
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
                if kind == 'prepare':
                    pending = action
                    output = ['Ziel: ' + value['target'], 'Befehl: ' + value['display'], value['impact'],
                              '', 'Änderung ausführen? j = bestätigen, Esc = abbrechen',
                              'Abbruch eines laufenden Befehls ist kein Rollback.']
                    status = 'Bestätigung erforderlich'
                else:
                    output = clean_text(value).expandtabs(4).splitlines() or ['Keine Ausgabe.']
                    status = 'Fehler / nicht verfügbar' if kind == 'error' else 'Abgeschlossen'
            except queue.Empty:
                pass
            screen.erase()
            height, width = screen.getmaxyx()
            def put(y, text, attr=0):
                if 0 <= y < height and width > 1:
                    try:
                        screen.addnstr(y, 0, clean_text(text), width - 1, attr)
                    except curses.error:
                        pass
            if height < 12 or width < 45:
                put(0, 'Terminal mindestens 45 Spalten und 12 Zeilen.')
                put(1, 'Vergrößern oder q zum Beenden.')
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
                menu_height = min(len(menu), max(3, height // 3))
                first = max(0, active_selected - menu_height + 1)
                title = 'pman Wartung | COMMUNITY PVE-WERKZEUGE' if community_mode else 'pman Wartung | {} {} | Scan: {}'.format(ctx.scope.upper(), ctx.id or '', ctx.mount)
                put(0, title, color | curses.A_BOLD)
                for row, index in enumerate(range(first, min(len(menu), first + menu_height)), 2):
                    put(row, ('> ' if index == active_selected else '  ') + menu[index],
                        curses.A_REVERSE if index == active_selected else 0)
                start_y = menu_height + 3
                put(start_y, '─' * (width - 1), color)
                page = max(1, height - start_y - 4)
                wrapped = [piece for line in output for piece in (textwrap.wrap(clean_text(line), max(1, width - 2), replace_whitespace=False) or [''])]
                scroll = min(scroll, max(0, len(wrapped) - page))
                for row, line in enumerate(wrapped[scroll:scroll + page], start_y + 1):
                    put(row, line)
                first_line = scroll + 1 if wrapped else 0
                last_line = min(len(wrapped), scroll + page)
                put(height - 3, 'Ausgabe Zeilen {}–{} von {}'.format(first_line, last_line, len(wrapped)), color)
                help_text = '↑↓ Menü | Enter öffnen | Bild↑↓ blättern | Tab Pfad | Esc zurück | q Ende'
                if community_mode:
                    help_text = '↑↓ Werkzeug | Enter Details/Start | Esc zurück | q Ende'
                if width < 74:
                    help_text = '↑↓ Menü | Enter | PgUp/PgDn | Esc | q Ende'
                    if community_mode:
                        help_text = '↑↓ Werkzeug | Enter | Esc zurück | q Ende'
                put(height - 2, help_text, color)
                put(height - 1, status, color)
            screen.refresh()
            key = screen.getch()
            if key == -1:
                continue
            if busy:
                if key in (27, ord('q')):
                    cancel.set()
                    status = 'Abbruch angefordert; CT-Scan kann bis zum Gast-Zeitlimit (55 s) weiterlaufen.'
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
                        output = ['Community Script beendet.', 'Exit-Code: {}'.format(exit_code),
                                  'Quelle: community-scripts/ProxmoxVE @ {}'.format(community.REVIEWED_COMMIT[:12])]
                        status = 'Abgeschlossen' if exit_code == 0 else 'Helper Script mit Fehler beendet'
                    except Exception as exc:
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
                    status = 'Bereit'
                continue
            if pending:
                if key in (ord('j'), ord('J')):
                    action = pending
                    pending = None
                    start('mutate', action)
                elif key in (27, ord('n'), ord('N'), ord('q')):
                    pending = None
                    output = ['Änderung abgebrochen.']
                    status = 'Bereit'
                continue
            if key in (ord('q'), 27):
                if community_mode:
                    community_mode = False
                    selected = len(registry(ctx))
                    output = ['Community-Werkzeugmenü geschlossen.']
                    status = 'Bereit'
                    continue
                return
            if key in (curses.KEY_UP, curses.KEY_DOWN):
                if community_mode:
                    community_selected = navigate(community_selected, -1 if key == curses.KEY_UP else 1,
                                                   len(community.TOOLS) + 1)
                    if community_selected < len(community.TOOLS):
                        tool = community.TOOLS[community_selected]
                        output = [tool['summary'], '', 'Risiko / Auswirkung:', tool['impact'], '',
                                  'Quelle: {} @ {}'.format(tool['path'], community.REVIEWED_COMMIT[:12]),
                                  'Lizenz: MIT; Helper wird als Community-Code ausgeführt.']
                else:
                    selected = navigate(selected, -1 if key == curses.KEY_UP else 1,
                                        len(registry(ctx)) + (2 if ctx.scope == 'host' else 1))
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
                        pending_community = tool
                        output = ['Werkzeug: ' + tool['title'], tool['summary'], '',
                                  'Auswirkung: ' + tool['impact'],
                                  'Geprüfte Quelle: {} @ {}'.format(tool['path'], community.REVIEWED_COMMIT),
                                  'Der Live-Upstream muss weiterhin exakt diesem Stand entsprechen.', '',
                                  'Mit j starten; Esc bricht ab.']
                        status = 'Community-Code ausführen?'
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
