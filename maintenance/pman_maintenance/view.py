"""Pure screen composition for the maintenance TUI.

Nothing here touches curses or the terminal: the same frame feeds the real
screen and the golden snapshot tests. Hazard levels are always spelled out as
text; colour is only an additional cue.
"""
import re
import textwrap
from collections import namedtuple
from dataclasses import dataclass, field

from . import community

# One drawn run of text. style: see attr_flags(); link: URL the text spells out.
Seg = namedtuple('Seg', 'y x text style link')
# page/total describe the scrollable content area for key handling.
Frame = namedtuple('Frame', 'segs page total')
# A display line; lead is unstyled hanging text in front of the styled text.
L = namedtuple('L', 'text link style lead', defaults=('', None, 'plain', ''))
# A labelled paragraph: the label hangs, the value wraps under itself.
Field = namedtuple('Field', 'label text link style', defaults=(None, 'plain'))
# Menu row. kind: header | item | tool | back; level: hazard level of a tool.
Row = namedtuple('Row', 'kind label tag flag level', defaults=('', False, ''))

FIELD_INDENT = 7
MIN_HEIGHT, MIN_WIDTH = 12, 45

# Badge colours as xterm-256 indices (fixed RGB, so contrast does not depend on
# the terminal theme): (foreground, background). Checked in the contrast test.
BADGE_PAIRS = {'tag_read': (16, 114), 'tag_change': (16, 220), 'tag_delete': (231, 124)}
BADGE_LETTER = {'tag_read': 'g', 'tag_change': 'y', 'tag_delete': 'r'}

_ASCII = {'–': '-', '→': '->', '←': '<-', '▸': '>', '·': '|', '…': '...', '─': '-', '│': '|', '↑': '^', '↓': 'v'}


def clean_text(value):
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(value))
    return ''.join(c for c in value if c in '\n\t' or (c.isprintable() and c != '\x1b'))


def to_ascii(text):
    for char, plain in _ASCII.items():
        text = text.replace(char, plain)
    return text


def _wrap(text, width):
    return textwrap.wrap(clean_text(text).expandtabs(4), max(1, width), replace_whitespace=False,
                         break_on_hyphens=False) or ['']


def wrap_output(lines, width):
    return [piece for line in lines for piece in _wrap(line, width)]


def wrap_blocks(blocks, width):
    """Turn strings, L and Field blocks into display lines (L) no wider than width."""
    out = []
    for block in blocks:
        if isinstance(block, Field):
            pieces = _wrap(block.text, width - FIELD_INDENT)
            for index, piece in enumerate(pieces):
                lead = block.label.ljust(FIELD_INDENT) if index == 0 else ' ' * FIELD_INDENT
                out.append(L(piece, block.link, block.style, lead))
            continue
        if not isinstance(block, L):
            block = L(block)
        for piece in _wrap(block.text, width):
            out.append(L(piece, block.link, block.style))
    return out


def attr_flags(style, color=''):
    """Terminal attribute letters for a style: B bold, R reverse, g/y/r badge colour pair.

    color is '256' only when the terminal has fixed 256 colours and NO_COLOR is
    unset; otherwise no colour is ever set and the text tags carry the meaning.
    """
    base, _, mod = style.partition('+')
    if base.startswith('tag_'):
        if color == '256':
            return 'B' + BADGE_LETTER[base]
        return 'BR' if mod == 'sel' else 'B'
    return {'plain': '', 'title': 'B', 'accent': 'B', 'sel': 'R', 'warn': 'B', 'dim': ''}[base]


def xterm256_rgb(index):
    """RGB of an xterm-256 colour-cube index (16-231) or grey ramp (232-255)."""
    if 16 <= index <= 231:
        levels = (0, 95, 135, 175, 215, 255)
        index -= 16
        return levels[index // 36], levels[index // 6 % 6], levels[index % 6]
    if 232 <= index <= 255:
        value = 8 + (index - 232) * 10
        return value, value, value
    raise ValueError('only the fixed 256-colour range is supported')


def contrast_ratio(first, second):
    def luminance(rgb):
        def channel(value):
            value /= 255
            return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4
        red, green, blue = (channel(v) for v in rgb)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    high, low = sorted((luminance(first), luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)


@dataclass
class Model:
    title: str
    rows: list = field(default_factory=list)
    selected: int = -1            # index among selectable (non-header) rows
    detail: list = field(default_factory=list)
    modal: bool = False
    modal_title: str = ''         # first line of a modal without provenance
    prov: dict = None             # provenance of external scripts, or None
    scroll: int = 0
    help: object = ''             # text, or callable(page, total) -> text
    status: str = ''
    small: tuple = ('', '')       # two lines shown when the terminal is too small
    details_heading: bool = False


def provenance(status_line=''):
    return {'name': '{} {}'.format(community.PROJECT_NAME, community.EDITION),
            'license': community.LICENSE, 'web': community.WEBSITE,
            'repo': community.REPOSITORY_URL, 'status': status_line}


def status_line(stored):
    """One line about the last stored upstream check (no network involved)."""
    if not stored['checked_at']:
        return 'Quellstand: noch nie geprüft - Start prüft live.'
    day = stored['checked_at'][:10]
    if stored['deviating']:
        return 'Quellstand {}: {} von {} weichen ab - betroffene Tools sind blockiert'.format(
            day, stored['deviating'], stored['total'])
    return 'Quellstand {}: alle {} Quellen entsprechen dem geprüften Stand'.format(day, stored['total'])


def _prov_rows(prov, mode, width):
    """Rows of (text, style, link) runs; mode 'full' for the menu, 'short' for modals."""
    name = '{} · {} · '.format(prov['name'], prov['license'])
    if mode == 'short':
        return [[(name, 'accent', None), (prov['web'], 'plain', prov['web'])], 'rule']
    first = [(name + 'Fremder Code, nicht von pman', 'accent', None)]
    status = [(prov['status'], 'plain', None)]
    if mode == 'compact':
        return [first, status, 'rule']
    return [first,
            [('Web:    ', 'plain', None), (prov['web'], 'plain', prov['web'])],
            [('Quelle: ', 'plain', None), (prov['repo'], 'plain', prov['repo'])],
            status, 'rule']


def render(m, height, width, ascii_only=False):
    segs = []

    def put(y, text, style='plain', x=0, limit=None, link=None):
        if 0 <= y < height and width > x + 1:
            text = clean_text(text)
            if ascii_only:
                text = to_ascii(text)
            segs.append(Seg(y, x, text[:min(width - x - 1, limit or width)], style, link))

    if height < MIN_HEIGHT or width < MIN_WIDTH:
        put(0, m.small[0])
        put(1, m.small[1])
        return Frame(segs, 0, 0)

    put(0, m.title, 'accent')
    top = 1
    if m.prov:
        mode = 'short' if m.modal else ('compact' if height < 22 else 'full')
        for row in _prov_rows(m.prov, mode, width):
            if row == 'rule':
                put(top, '─' * (width - 1))
            else:
                x = 0
                for text, style, link in row:
                    put(top, text, style, x=x, link=link)
                    x += len(text)
            top += 1
    elif m.modal:
        put(1, m.modal_title, 'accent')
        top = 3
    side = width >= 76 and not m.modal
    menu_w = 36 if width < 100 else 42
    selectable = [i for i, row in enumerate(m.rows) if row.kind != 'header']
    row_selected = selectable[m.selected] if 0 <= m.selected < len(selectable) else -1
    start_y, detail_x, detail_width = top + 1, 0, width - 3
    if m.modal:
        start_y = top
    elif side:
        list_top = top if m.prov else 2
        list_height = max(1, height - list_top - 3)
        first = max(0, row_selected - list_height + 1)
        for line, index in enumerate(range(first, min(len(m.rows), first + list_height)), list_top):
            _put_row(put, line, m.rows[index], index == row_selected, menu_w - 1, menu_w - 2)
        for line in range(list_top, height - 3):
            put(line, '│', x=menu_w)
        detail_x, detail_width, start_y = menu_w + 2, width - menu_w - 3, list_top
        if m.details_heading:
            put(1, 'Details', 'accent', x=detail_x)
    else:
        list_top = top if m.prov else 2
        list_height = min(len(m.rows), max(2, height // 4))
        first = max(0, row_selected - list_height + 1)
        for line, index in enumerate(range(first, min(len(m.rows), first + list_height)), list_top):
            _put_row(put, line, m.rows[index], index == row_selected, width - 1, width - 3)
        start_y, detail_x, detail_width = list_top + list_height + 1, 0, width - 3
    page = max(1, height - start_y - 3)
    wrapped = wrap_blocks(m.detail, detail_width)
    scroll = min(m.scroll, max(0, len(wrapped) - page))
    for line, display in enumerate(wrapped[scroll:scroll + page], start_y):
        x = detail_x
        if display.lead:
            put(line, display.lead, x=x, limit=detail_width)
            x += len(display.lead)
        put(line, display.text, display.style, x=x, limit=max(1, detail_width - (x - detail_x)),
            link=display.link)
    if len(wrapped) > page:
        put(height - 3, 'Zeilen {}–{} von {}'.format(scroll + 1, min(len(wrapped), scroll + page),
                                                      len(wrapped)))
    put(height - 2, m.help(page, len(wrapped)) if callable(m.help) else m.help)
    put(height - 1, m.status, 'accent')
    return Frame(segs, page, len(wrapped))


def _put_row(put, y, row, selected, limit, flag_x):
    style = 'sel' if selected else 'plain'
    if row.kind == 'header':
        put(y, ' ' + row.label, 'accent', limit=limit)
        return
    mark = '> ' if selected else '  '
    if row.kind == 'tool':
        text = (' > ' if selected else '   ') + row.tag + ' ' + row.label
    elif row.kind == 'back':
        text = mark + '← ' + row.label
    else:
        text = mark + row.label
    put(y, text.ljust(limit) if selected else text, style, limit=limit)
    if row.kind == 'tool':
        put(y, row.tag, 'tag_{}{}'.format(row.level, '+sel' if selected else ''), x=3, limit=limit)
    if row.flag:
        put(y, '!', style if selected else 'warn', x=flag_x)


def snapshot(frame, height, width, color=''):
    """Text grid and attribute grid of a frame, for golden tests and demos.

    Attribute letters: . none, b bold, R reverse, X bold+reverse, g/y/r badge colours.
    """
    chars = [[' '] * width for _ in range(height)]
    attrs = [['.'] * width for _ in range(height)]
    letters = {'': '.', 'B': 'b', 'R': 'R', 'BR': 'X', 'Bg': 'g', 'By': 'y', 'Br': 'r'}
    for seg in frame.segs:
        code = letters[attr_flags(seg.style, color)]
        for offset, char in enumerate(seg.text):
            if seg.x + offset < width:
                chars[seg.y][seg.x + offset] = char
                attrs[seg.y][seg.x + offset] = code
    text = '\n'.join(''.join(row).rstrip() for row in chars)
    codes = '\n'.join(''.join(row).rstrip('.') for row in attrs)
    return text, codes


# --- Content builders for the Helper-Scripts screens -------------------------

def tag_text(level):
    return '[{}]'.format(community.LEVELS[level][0].ljust(6))


def community_rows(stored):
    rows, group = [], None
    titles = dict(community.GROUPS)
    for tool in community.TOOLS:
        if tool['group'] != group:
            group = tool['group']
            rows.append(Row('header', titles[group]))
        rows.append(Row('tool', tool['label'], tag_text(tool['level']),
                        stored['tools'][tool['id']]['flagged'], tool['level']))
    rows.append(Row('back', 'Zurück zum Wartungsmenü'))
    return rows


def community_intro():
    return [L('{} {}'.format(community.PROJECT_NAME, community.EDITION), style='accent'),
            'Fremder Code unter {}-Lizenz - nicht von pman und nicht von Proxmox.'.format(community.LICENSE),
            '',
            L(community.WEBSITE, community.WEBSITE),
            '',
            'Enter öffnet {} ausgewählte Host-Skripte; gestartet wird erst nach Bestätigung.'.format(
                len(community.TOOLS))]


def community_detail(tool, stored):
    word, meaning = community.LEVELS[tool['level']]
    blocks = [L(tool['title'], style='accent'), tool['summary'], '',
              Field('Stufe', '{} – {}'.format(word, meaning), style='accent'),
              Field('Folge', tool['impact']),
              Field('Läuft', 'als root auf dem Host'),
              Field('Stand', 'geprüft {} ({})'.format(community.reviewed_at(), community.REVIEWED_COMMIT[:7])),
              Field('Datei', tool['path'])]
    info = stored['tools'][tool['id']]
    if info['flagged']:
        blocks.append(Field('Start', 'blockiert: ' + info['reason'], style='warn'))
    return blocks


def confirm_blocks(launch, host):
    tool = launch.tool
    url = community.source_url(tool)
    word, meaning = community.LEVELS[tool['level']]
    name = tool['path'].rpartition('/')[2]
    return [L(tool['title'], style='accent'),
            Field('Stufe', '{} – {}'.format(word, meaning), style='accent'),
            '',
            L('FREMDER CODE – läuft als root auf diesem Host ({}).'.format(host), style='accent'),
            'Er stammt weder von pman noch von Proxmox.',
            '',
            Field('Quelle', url, url),
            Field('Befehl', 'bash {}  (pman lädt die Datei, prüft SHA-1 {}… und startet genau diese '
                  'Bytes in einem Temp-Verzeichnis)'.format(name, tool['sha'][:7])),
            Field('Core', 'core/core.func @ {} · Telemetrie (api.func) wird nicht geladen'.format(
                community.CORE_COMMIT[:7])),
            Field('Stand', 'geprüft {} · Upstream live: unverändert'.format(community.reviewed_at())),
            Field('Folge', tool['impact']),
            '',
            'Das Skript läuft danach interaktiv weiter; pman kann es nicht zurückrollen.']


def preview_blocks(launch):
    tool = launch.tool
    text = launch.script.decode('utf-8', 'replace')
    return [L('Quellcode {} - genau diese {} Bytes werden gestartet.'.format(
        tool['path'].rpartition('/')[2], len(launch.script)), style='accent'),
        'SHA-1 (Git-Blob): ' + tool['sha'], ''] + text.splitlines()


def result_blocks(launch, exit_code):
    url = community.source_url(launch.tool)
    return [L('Community-Skript beendet.', style='accent'),
            Field('Skript', launch.tool['title']), Field('Exit', str(exit_code)),
            Field('Quelle', url, url)]
