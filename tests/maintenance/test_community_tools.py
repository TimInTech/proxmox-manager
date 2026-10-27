import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))

from pman_maintenance import community
from pman_maintenance import ui
from pman_maintenance.actions import Context


class CommunityToolsTest(unittest.TestCase):
    def test_catalog_is_curated_host_tool_allowlist(self):
        ids = {tool['id'] for tool in community.TOOLS}
        self.assertEqual(len(ids), 8)
        self.assertIn('fstrim', ids)
        self.assertIn('clean-orphaned-lvm', ids)
        self.assertNotIn('execute', ids)

    def test_git_blob_digest_matches_git_format(self):
        self.assertEqual(community.git_blob_sha(b'hello\n'),
                         'ce013625030ba8dba906f756967f9e9ca394464a')

    def test_changed_upstream_blocks_before_download_or_execution(self):
        expected = next(tool['sha'] for tool in community.TOOLS if tool['id'] == 'fstrim')
        with patch.object(community, '_reference', return_value={'blob_sha': expected}), \
             patch.object(community.sources, 'check_reference', return_value={'status': 'Upstream geändert'}), \
             patch.object(community, '_download_pinned') as download, \
             patch.object(community.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Upstream'):
                community.run_tool('fstrim')
        download.assert_not_called()
        run.assert_not_called()

    def test_unknown_helper_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unbekanntes'):
            community.run_tool('arbitrary-shell-command')

    def test_runner_uses_verified_download_and_does_not_provide_telemetry_api(self):
        with patch.object(community, '_check_current'), \
             patch.object(community, '_download_pinned', side_effect=[b'#!/bin/bash\n', b'# core\n']) as download, \
             patch.object(community.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as run:
            self.assertEqual(community.run_tool('fstrim'), 0)
        self.assertEqual(download.call_count, 2)
        args, kwargs = run.call_args
        env = kwargs['env']
        self.assertTrue(env['COMMUNITY_SCRIPTS_CORE_URL'].startswith('file://'))
        self.assertFalse((Path(env['COMMUNITY_SCRIPTS_CORE_URL'].replace('file://', '')) / 'api' / 'api.func').exists())
        self.assertNotIn('BASH_ENV', env)
        self.assertNotIn('LD_PRELOAD', env)
        self.assertEqual(args[0][0:1], ['bash'])

    def test_tui_opens_curated_community_submenu_without_running_a_tool(self):
        class Screen:
            def __init__(self):
                self.keys = [ui.curses.KEY_DOWN] * 3 + [10, ord('q'), ord('q')]
                self.rows = []
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (24, 80)
            def addnstr(self, row, col, value, *args): self.rows.append(value)
            def refresh(self): pass
            def getch(self): return self.keys.pop(0)

        screen = Screen()
        with patch.object(ui.curses, 'wrapper', side_effect=lambda fn, ctx: fn(screen, ctx)), \
             patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui.locale, 'setlocale'), \
             patch.object(ui.locale, 'getpreferredencoding', return_value='UTF-8'), \
             patch.object(community, 'run_tool') as run:
            ui.run_tui(Context('host'))
        self.assertTrue(any('COMMUNITY PVE-WERKZEUGE' in row for row in screen.rows))
        run.assert_not_called()

    def test_declining_helper_start_never_calls_runner(self):
        class Screen:
            def __init__(self):
                self.keys = [ui.curses.KEY_DOWN] * 3 + [10, 10, ord('n'), ord('q'), ord('q')]
                self.rows = []
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (24, 80)
            def addnstr(self, row, col, value, *args): self.rows.append(value)
            def refresh(self): pass
            def getch(self): return self.keys.pop(0)

        screen = Screen()
        with patch.object(ui.curses, 'wrapper', side_effect=lambda fn, ctx: fn(screen, ctx)), \
             patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui.locale, 'setlocale'), \
             patch.object(ui.locale, 'getpreferredencoding', return_value='UTF-8'), \
             patch.object(community, 'run_tool') as run:
            ui.run_tui(Context('host'))
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
