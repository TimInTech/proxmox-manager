"""Golden snapshots of the maintenance screens plus accessibility invariants.

Regenerate after an intended layout change: UPDATE_GOLDEN=1 python3 -m unittest
discover -s tests/maintenance -p 'test_view_golden.py'; review the diff.
"""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))

from pman_maintenance import community, i18n, ui, view
from pman_maintenance.i18n import _
from pman_maintenance.actions import Context, registry

GOLDEN = Path(__file__).resolve().parent / 'golden'
FIXED = {'REVIEWED_COMMIT': '0123456789abcdef0123456789abcdef01234567',
         'CORE_COMMIT': 'fedcba9876543210fedcba9876543210fedcba98'}
STORED = {'checked_at': '2026-11-03T23:49:40+00:00', 'total': 9, 'deviating': 5, 'unknown': 0,
          'tools': {t['id']: {'flagged': t['id'] in ('kernel-clean', 'clean-lxcs'),
                              'reason': 'core.func geändert (1111111 → 2222222)'}
                    for t in community.TOOLS}}
SIZES = ((80, 24), (120, 40))


def tool(tool_id):
    return next(t for t in community.TOOLS if t['id'] == tool_id)


def model(name):
    with patch.multiple(community, **FIXED), patch.object(community, 'reviewed_at', return_value='2026-11-04'):
        actions = registry(Context('host'))
        if name == 'host-main':
            rows = view.main_rows(actions, 'host')
            return view.Model(title=_('pman Wartung') + ' | HOST', rows=rows, selected=len(actions),
                              detail=view.community_intro(), details_heading=True,
                              help=_('↑↓ Auswahl | Enter | PgUp/PgDn | Esc | q Ende'), status=_('Bereit'))
        prov = view.provenance(view.status_line(STORED))
        kernel = tool('kernel-clean')
        selected = community.TOOLS.index(kernel)
        if name == 'community-menu':
            return view.Model(
                title=_('pman Wartung') + ' | HOST | ' + _('Community-Skripte'), rows=view.community_rows(STORED),
                selected=selected, detail=view.community_detail(kernel, STORED), prov=prov,
                help=_('↑↓ Auswahl | Enter prüfen & bestätigen | Esc zurück | q Ende'),
                status=_('Bereit – es wurde noch nichts gestartet'))
        launch = community.Launch(kernel, b'#!/usr/bin/env bash\necho one\n\techo two\n', b'# core\n')
        modal = dict(title=_('pman Wartung') + ' | HOST | ' + _('Community-Skript starten?'), modal=True, prov=prov)
        if name == 'community-confirm':
            return view.Model(detail=view.confirm_blocks(launch, 'pve'),
                              help=_('v Quellcode | j Starten | Esc/n Abbruch | PgUp/PgDn'),
                              status=_('Wartet auf Bestätigung'), **modal)
        if name == 'community-blocked':
            blocked = community.SourceBlocked(community.CORE_REPOSITORY, 'core/core.func',
                                              '1111111aaaa', '2222222bbbb', 'Upstream geändert')
            return view.Model(detail=blocked.lines(), help=_('PgUp/PgDn Blättern | Esc Zurück | q Ende'),
                              status=_('Start blockiert'), **modal)
        if name == 'community-preview':
            return view.Model(detail=view.preview_blocks(launch),
                              help=_('↑↓ PgUp/PgDn blättern | Esc zurück zur Bestätigung'),
                              status=_('Quellcode-Vorschau – es wird nichts ausgeführt'), **modal)
    raise KeyError(name)


SCREENS = ('host-main', 'community-menu', 'community-confirm', 'community-blocked', 'community-preview')
VARIANTS = (('', '256', False), ('nocolor', '', False), ('ascii-nocolor', '', True))


def render_text(name, size, color, ascii_only, lang='de'):
    height, width = size[1], size[0]
    i18n.set_language(lang)
    try:
        frame = view.render(model(name), height, width, ascii_only)
    finally:
        i18n.set_language(None)
    text, codes = view.snapshot(frame, height, width, color)
    links = ['{},{} {} {}'.format(s.y, s.x, s.link, s.text) for s in frame.segs if s.link]
    return '{}\n---attrs---\n{}\n---links---\n{}\n'.format(text, codes, '\n'.join(links)), frame


class GoldenTest(unittest.TestCase):
    def test_screens_match_golden_files(self):
        for name in SCREENS:
            for size in SIZES:
                for variant, color, ascii_only in VARIANTS:
                    if size != (80, 24) and variant == 'ascii-nocolor':
                        continue
                    label = '-'.join(filter(None, (name, '{}x{}'.format(*size), variant)))
                    with self.subTest(label):
                        actual, _ = render_text(name, size, color, ascii_only)
                        path = GOLDEN / (label + '.txt')
                        if os.environ.get('UPDATE_GOLDEN'):
                            path.write_text(actual)
                        self.assertTrue(path.exists(), 'missing golden file ' + path.name)
                        self.assertEqual(path.read_text(), actual)


class EnglishGoldenTest(unittest.TestCase):
    def test_english_screens_match_golden_files(self):
        for name in SCREENS:
            for size in SIZES:
                for variant, color, ascii_only in VARIANTS[:2]:
                    label = '-'.join(filter(None, (name, '{}x{}'.format(*size), variant, 'en')))
                    with self.subTest(label):
                        actual, _frame = render_text(name, size, color, ascii_only, 'en')
                        path = GOLDEN / (label + '.txt')
                        if os.environ.get('UPDATE_GOLDEN'):
                            path.write_text(actual)
                        self.assertTrue(path.exists(), 'missing golden file ' + path.name)
                        self.assertEqual(path.read_text(), actual)

    def test_english_screens_fit_and_show_no_german_ui_words(self):
        for name in SCREENS:
            for size in SIZES:
                text, frame = render_text(name, size, '', False, 'en')
                screen = text.split('---attrs---')[0]
                for line in screen.splitlines():
                    self.assertLess(len(line), size[0], (name, line))
                if name in ('community-menu', 'host-main'):
                    self.assertLessEqual(frame.total, frame.page)
                for word in ('Fremder', 'Quelle:', 'Bestätigung', 'LÖSCHT', 'ÄNDERT', 'Zurück'):
                    self.assertNotIn(word, screen, (name, word))


class AccessibilityTest(unittest.TestCase):
    def test_every_line_fits_the_terminal_width(self):
        for name in SCREENS:
            for width, height in SIZES:
                text, _ = render_text(name, (width, height), '256', False)
                for line in text.split('---attrs---')[0].splitlines():
                    self.assertLess(len(line), width, (name, line))

    def test_all_tools_and_hazard_tags_are_visible_at_80x24(self):
        text, frame = render_text('community-menu', (80, 24), '', False)
        screen = text.split('---attrs---')[0]
        for item in community.TOOLS:
            self.assertIn(item['label'], screen)
            self.assertIn(view.tag_text(item['level']), screen)
        self.assertIn('Proxmox VE Helper-Scripts', screen)
        self.assertIn('https://community-scripts.org', screen)
        self.assertLessEqual(frame.total, frame.page, 'detail pane must not hide content')

    def test_no_colour_snapshot_sets_no_colour_attribute(self):
        for name in SCREENS:
            text, _ = render_text(name, (80, 24), '', False)
            codes = text.split('---attrs---')[1].split('---links---')[0]
            self.assertFalse(set('gyre') & set(codes), name)

    def test_colour_snapshot_uses_badges_only_on_hazard_tags(self):
        text, _ = render_text('community-menu', (80, 24), '256', False)
        self.assertTrue(set('gyr') & set(text.split('---attrs---')[1]))

    def test_main_menu_marks_external_code_with_a_text_badge_and_colour(self):
        text, _ = render_text('host-main', (80, 24), '256', False)
        screen, codes = text.split('---attrs---')[0], text.split('---attrs---')[1]
        self.assertIn('[FREMD ]', screen)
        self.assertIn('e', codes.split('---links---')[0])

    def test_ascii_mode_has_no_box_or_arrow_glyphs(self):
        for name in SCREENS:
            text, _ = render_text(name, (80, 24), '', True)
            stray = {c for c in text if ord(c) > 127 and c not in 'ÄÖÜäöüß'}
            self.assertFalse(stray, (name, stray))

    def test_visible_link_text_is_part_of_its_target(self):
        for name in SCREENS:
            _, frame = render_text(name, (80, 24), '', False)
            for seg in frame.segs:
                if seg.link:
                    self.assertTrue(seg.link.startswith('https://'), seg)
                    self.assertIn(seg.text, seg.link, 'a link must not hide its target')

    def test_confirmation_names_source_command_and_privilege(self):
        text, _ = render_text('community-confirm', (80, 24), '', False)
        screen = text.split('---attrs---')[0]
        for needle in ('FREMDER CODE', 'root', 'https://github.com/community-scripts/ProxmoxVE/blob/',
                       'bash kernel-clean.sh', 'SHA-1', 'Quellcode'):
            self.assertIn(needle.replace('Quellcode', 'v Quellcode'), screen)


class ContrastTest(unittest.TestCase):
    def test_badge_pairs_meet_wcag_aa_for_text(self):
        for style, (fg, bg) in view.BADGE_PAIRS.items():
            ratio = view.contrast_ratio(view.xterm256_rgb(fg), view.xterm256_rgb(bg))
            self.assertGreaterEqual(ratio, 4.5, (style, ratio))

    def test_ui_sets_no_other_colours_than_the_badge_pairs(self):
        calls = []
        with patch.object(ui.curses, 'init_pair', side_effect=lambda *a: calls.append(a)), \
             patch.object(ui.curses, 'color_pair', return_value=0):
            ui._attrs('256')
            ui._attrs('')
        self.assertEqual({(fg, bg) for _, fg, bg in calls}, set(view.BADGE_PAIRS.values()))

    def test_contrast_helper_matches_known_values(self):
        self.assertAlmostEqual(view.contrast_ratio((0, 0, 0), (255, 255, 255)), 21.0, places=1)
        self.assertAlmostEqual(view.contrast_ratio((255, 255, 255), (175, 0, 0)), 7.44, places=1)


class EnvironmentTest(unittest.TestCase):
    def test_ascii_and_hyperlink_detection(self):
        self.assertTrue(ui.ascii_mode({'PMAN_ASCII': '1'}))
        self.assertTrue(ui.ascii_mode({'TERM': 'linux'}))
        self.assertFalse(ui.ascii_mode({'TERM': 'xterm-256color'}))
        self.assertFalse(ui.hyperlinks_supported({'TERM': 'xterm-256color'}))
        self.assertFalse(ui.hyperlinks_supported({'TERM': 'xterm', 'TMUX': '/tmp/x', 'VTE_VERSION': '7000'}))
        self.assertTrue(ui.hyperlinks_supported({'TERM': 'xterm-256color', 'VTE_VERSION': '7000'}))
        self.assertTrue(ui.hyperlinks_supported({'TERM': 'xterm', 'PMAN_HYPERLINKS': '1', 'TMUX': 'x'}))
        self.assertFalse(ui.hyperlinks_supported({'TERM': 'xterm', 'PMAN_HYPERLINKS': '0', 'VTE_VERSION': '7000'}))


if __name__ == '__main__':
    unittest.main()
