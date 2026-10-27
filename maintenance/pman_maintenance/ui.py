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


def clean_text(value):
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(value))
    return ''.join(c for c in value if c in '\n\t' or (c.isprintable() and c != '\x1b'))


def navigate(index, direction, count):
    return (index + direction) % count if count else 0


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
              'Quelle: eigene Adapter; Community Scripts dienen als gekennzeichnete Referenz.',
              'CT-Scanpfad mit Tab umschalten: /var, /home, /opt, /srv.']
    pending = None
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
                menu = [a.title + (' [Änderung]' if a.mutation else '') for a in actions]
                menu.append('Herkunft und Aktualitätsstatus')
                menu_height = min(len(menu), max(3, height // 3))
                first = max(0, selected - menu_height + 1)
                put(0, 'pman Wartung | {} {} | Scan: {}'.format(ctx.scope.upper(), ctx.id or '', ctx.mount), color | curses.A_BOLD)
                for row, index in enumerate(range(first, min(len(menu), first + menu_height)), 2):
                    put(row, ('> ' if index == selected else '  ') + menu[index],
                        curses.A_REVERSE if index == selected else 0)
                start_y = menu_height + 3
                put(start_y, '─' * (width - 1), color)
                page = max(1, height - start_y - 4)
                wrapped = [piece for line in output for piece in (textwrap.wrap(clean_text(line), max(1, width - 2), replace_whitespace=False) or [''])]
                scroll = min(scroll, max(0, len(wrapped) - page))
                for row, line in enumerate(wrapped[scroll:scroll + page], start_y + 1):
                    put(row, line)
                put(height - 2, '↑↓ Menü | Enter öffnen | Bild↑↓ Ausgabe | Tab Scanpfad | Esc zurück/Abbruch | q Ende', color)
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
                return
            if key in (curses.KEY_UP, curses.KEY_DOWN):
                selected = navigate(selected, -1 if key == curses.KEY_UP else 1, len(registry(ctx)) + 1)
            elif key in (curses.KEY_PPAGE, curses.KEY_NPAGE):
                scroll = max(0, scroll + (-5 if key == curses.KEY_PPAGE else 5))
            elif key == 9 and ctx.scope == 'ct':
                mounts = ['/var', '/home', '/opt', '/srv']
                ctx = Context(ctx.scope, ctx.id, mounts[(mounts.index(ctx.mount) + 1) % len(mounts)])
            elif key in (10, 13, curses.KEY_ENTER):
                actions = registry(ctx)
                if selected == len(actions):
                    start('sources')
                else:
                    action = actions[selected]
                    start('prepare' if action.mutation else 'execute', action)
    finally:
        cancel.set()
        if worker and worker.is_alive():
            worker.join(4)
