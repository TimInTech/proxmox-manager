import json
import sys
import unittest
from pathlib import Path
from contextlib import redirect_stdout
from io import StringIO
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))

from pman_maintenance.actions import Context, do_smart
from pman_maintenance.runner import Result
from pman_maintenance import ui, sources


class FakeRunner:
    def __init__(self, responses):
        self.responses = responses

    def run(self, argv, **kwargs):
        return Result(argv, 0, self.responses[tuple(argv)])


class SmartReportRegressionTest(unittest.TestCase):
    def run_report(self, smart, previous=None):
        devices = {'blockdevices': [
            {'name': 'sdb', 'type': 'disk', 'model': 'Test SSD', 'size': '1G'}
        ]}
        runner = FakeRunner({
            ('lsblk', '-J', '-d', '-o', 'NAME,TYPE,MODEL,SIZE'): json.dumps(devices),
            ('smartctl', '-a', '-j', '/dev/sdb'): json.dumps(smart),
        })
        with patch('pman_maintenance.actions.shutil.which', return_value='/usr/sbin/smartctl'), \
             patch('pman_maintenance.actions.read_json', return_value=previous or {}), \
             patch('pman_maintenance.actions.write_json'):
            return do_smart(Context('host'), runner)

    def test_crucial_temperature_uses_human_readable_value_and_curated_health(self):
        devices = {'blockdevices': [
            {'name': 'sdb', 'type': 'disk', 'model': 'CT240BX500SSD1', 'size': '223.6G'}
        ]}
        smart = {
            'model_name': 'CT240BX500SSD1',
            'serial_number': 'must-not-be-displayed',
            'smart_status': {'passed': True},
            'temperature': {'current': 40},
            'power_on_time': {'hours': 19517},
            'ata_smart_attributes': {'table': [
                {'id': 5, 'name': 'Reallocate_NAND_Blk_Cnt', 'raw': {
                    'value': 0, 'string': '0'}},
                {'id': 194, 'name': 'Temperature_Celsius', 'raw': {
                    'value': 322123595816, 'string': '40 (Min/Max 16/75)'}},
                {'id': 197, 'name': 'Current_Pending_ECC_Cnt', 'raw': {
                    'value': 0, 'string': '0'}},
                {'id': 198, 'name': 'Offline_Uncorrectable', 'raw': {
                    'value': 0, 'string': '0'}},
                {'id': 199, 'name': 'UDMA_CRC_Error_Count', 'raw': {
                    'value': 5, 'string': '5'}},
            ]},
        }
        runner = FakeRunner({
            ('lsblk', '-J', '-d', '-o', 'NAME,TYPE,MODEL,SIZE'): json.dumps(devices),
            ('smartctl', '-a', '-j', '/dev/sdb'): json.dumps(smart),
        })
        with patch('pman_maintenance.actions.shutil.which', return_value='/usr/sbin/smartctl'), \
             patch('pman_maintenance.actions.read_json', return_value={}), \
             patch('pman_maintenance.actions.write_json'):
            report = do_smart(Context('host'), runner)

        self.assertIn('PASSED', report)
        self.assertIn('40 °C', report)
        self.assertIn('19517', report)
        self.assertIn('5', report)
        self.assertNotIn('322123595816', report)
        self.assertNotIn('Health: True', report)
        self.assertNotIn('erste Messung', report)
        self.assertNotIn('must-not-be-displayed', report)
        self.assertIn('Verschleißattribut', report)

    def test_nvme_health_values_are_curated_and_visible(self):
        report = self.run_report({
            'serial_number': 'private', 'smart_status': {'passed': True},
            'nvme_smart_health_information_log': {
                'critical_warning': 0, 'temperature': 37, 'available_spare': 100,
                'percentage_used': 12, 'media_errors': 2, 'num_err_log_entries': 4,
            },
        })
        self.assertIn('NVMe-Gesundheit', report)
        self.assertIn('Temperatur: 37 °C', report)
        self.assertIn('Verschleiß: 12%', report)
        self.assertIn('Medienfehler: 2', report)
        self.assertNotIn('private', report)

    def test_nvme_nonzero_warning_is_explicit(self):
        report = self.run_report({'nvme_smart_health_information_log': {
            'critical_warning': 2, 'temperature': 40,
        }})
        self.assertIn('NVMe meldet kritische Warnungsbits: 2', report)

    def test_temperature_falls_back_to_smart_attribute_string(self):
        report = self.run_report({'ata_smart_attributes': {'table': [
            {'name': 'Temperature_Celsius', 'raw': {'value': 322123595807, 'string': '40 (Min/Max 16/75)'}}
        ]}})
        self.assertIn('Temperatur: 40 °C', report)
        self.assertNotIn('322123595807', report)

    def test_failed_smart_status_is_not_truthified(self):
        report = self.run_report({'smart_status': {'passed': False}})
        self.assertIn('SMART-Status: FEHLER', report)

    def test_positive_counter_delta_is_reported(self):
        report = self.run_report({'ata_smart_attributes': {'table': [
            {'name': 'UDMA_CRC_Error_Count', 'raw': {'value': 6, 'string': '6'}}
        ]}}, previous={'/dev/sdb': {'UDMA_CRC_Error_Count': '5'}})
        self.assertIn('CRC-Fehler: 6 (+1 seit letzter Messung)', report)


class SourceReportRegressionTest(unittest.TestCase):
    def test_source_report_is_a_compact_status_summary(self):
        manifest = {
            'notice': 'Eigene Adapter; Community-Code wird nicht ausgeführt.',
            'adapters': {'smart': {'origin': 'own'}},
            'references': [
                {'repository': 'community-scripts/ProxmoxVE', 'path': 'tools/pve/fstrim.sh',
                 'reviewed_commit': 'long-commit', 'blob_sha': 'long-blob'},
                {'repository': 'community-scripts/ProxmoxVE', 'path': 'tools/pve/disk-health.sh',
                 'reviewed_commit': 'long-commit', 'blob_sha': 'long-blob'},
            ],
        }
        state = {'checked_at': '2026-10-27T12:00:00Z', 'references': [
            {'repository': 'community-scripts/ProxmoxVE', 'path': 'tools/pve/fstrim.sh', 'status': 'geprüfter Stand'},
            {'repository': 'community-scripts/ProxmoxVE', 'path': 'tools/pve/disk-health.sh', 'status': 'Upstream geändert'},
        ]}
        with patch.object(sources, 'MANIFEST') as manifest_path, \
             patch.object(sources, 'read_json', return_value=state):
            manifest_path.read_text.return_value = json.dumps(manifest)
            report = sources.source_report()

        self.assertIn('2 Quellen', report)
        self.assertIn('geprüft: 1', report)
        self.assertIn('geändert: 1', report)
        self.assertIn('Upstream geändert', report)
        self.assertNotIn('long-commit', report)
        self.assertNotIn('long-blob', report)
        self.assertLessEqual(len(report.splitlines()), 8)


class PageNavigationRegressionTest(unittest.TestCase):
    def test_page_down_moves_one_viewport_and_clamps_to_last_page(self):
        self.assertTrue(hasattr(ui, 'page_offset'), 'missing viewport-based paging helper')
        self.assertEqual(ui.page_offset(0, 1, 12, 100), 12)
        self.assertEqual(ui.page_offset(90, 1, 12, 100), 88)

    def test_page_up_moves_one_viewport_and_never_goes_negative(self):
        self.assertTrue(hasattr(ui, 'page_offset'), 'missing viewport-based paging helper')
        self.assertEqual(ui.page_offset(30, -1, 12, 100), 18)
        self.assertEqual(ui.page_offset(4, -1, 12, 100), 0)

    def test_exit_returns_shell_to_a_fresh_line(self):
        class Screen:
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (24, 80)
            def addnstr(self, *args): pass
            def refresh(self): pass
            def getch(self): return ord('q')

        screen = Screen()
        output = StringIO()
        with patch.object(ui.curses, 'wrapper', side_effect=lambda fn, ctx: fn(screen, ctx)), \
             patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui.locale, 'setlocale'), \
             patch.object(ui.locale, 'getpreferredencoding', return_value='UTF-8'), \
             redirect_stdout(output):
            ui.run_tui(Context('host'))
        self.assertEqual(output.getvalue(), '\n')


if __name__ == '__main__':
    unittest.main()
