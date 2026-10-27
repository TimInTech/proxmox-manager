import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))
from pman_maintenance.actions import Context, execute, prepare, registry
from pman_maintenance.runner import Result, CommandError

class FakeRunner:
    def __init__(self, responses=None):
        self.calls = []
        self.responses = responses or {}
    def run(self, argv, **kwargs):
        self.calls.append(argv)
        value = self.responses.get(tuple(argv), '')
        if isinstance(value, Exception):
            raise value
        return Result(argv, 0, value)

class ActionsTest(unittest.TestCase):
    def test_stopped_ct_cannot_trim(self):
        runner = FakeRunner({('pct', 'status', '101'): 'status: stopped'})
        with self.assertRaises(CommandError):
            execute('trim', Context('ct', 101), runner, confirmed=True)
        self.assertEqual(runner.calls, [['pct', 'status', '101']])
    def test_unconfirmed_mutation_never_runs(self):
        runner = FakeRunner()
        with self.assertRaises(CommandError):
            execute('trim', Context('ct', 101), runner)
        self.assertEqual(runner.calls, [])
    def test_trim_only_selected_running_ct(self):
        runner = FakeRunner({('pct', 'status', '101'): 'status: running'})
        execute('trim', Context('ct', 101), runner, confirmed=True)
        self.assertEqual(runner.calls, [['pct', 'status', '101'], ['pct', 'fstrim', '101']])
    def test_host_actions_not_available_for_vm(self):
        self.assertNotIn('smart', [a.id for a in registry(Context('vm', 100))])
    def test_unknown_guest_id_rejected(self):
        with self.assertRaises(ValueError):
            Context('ct', 0)
    def test_cache_clean_rejects_unknown_os(self):
        runner = FakeRunner({('pct', 'status', '101'): 'status: running',
          ('pct', 'exec', '101', '--', 'cat', '/etc/os-release'): 'ID=alpine'})
        with self.assertRaises(CommandError):
            prepare('cache-clean', Context('ct', 101), runner)
        self.assertFalse(any('clean' in c for c in runner.calls))

if __name__ == '__main__': unittest.main()

class BackendTest(unittest.TestCase):
    def test_storage_has_separate_thin_metadata_and_zfs(self):
        from unittest.mock import patch
        runner = FakeRunner()
        with patch('pman_maintenance.actions.shutil.which', return_value='/usr/sbin/tool'):
            report = execute('storage', Context('host'), runner)
        self.assertIn(['zpool','status','-x'], runner.calls)
        self.assertTrue(any('vg_name,lv_name,lv_attr,lv_size,pool_lv,data_percent,metadata_percent' in call for call in runner.calls))
        self.assertIn('Thin-Pool', report)
    def test_storage_skips_missing_optional_tools(self):
        from unittest.mock import patch
        runner = FakeRunner()
        with patch('pman_maintenance.actions.shutil.which', return_value=None):
            execute('storage', Context('host'), runner)
        self.assertFalse(any(call[0] in ('lvs','zpool') for call in runner.calls))
    def test_backend_error_does_not_hide_other_sections(self):
        runner = FakeRunner({('pvesm','status'): CommandError('offline')})
        report = execute('storage', Context('host'), runner)
        self.assertIn('offline', report)
        self.assertIn(['df','-hi'], runner.calls)
    def test_vm_missing_agent_never_trims(self):
        runner = FakeRunner({('qm','status','100'):'status: running',
          ('qm','help','guest','cmd'): 'ping fstrim get-osinfo',
          ('qm','guest','cmd','100','ping'): CommandError('agent is not running')})
        with self.assertRaises(CommandError):
            execute('trim',Context('vm',100),runner,confirmed=True)
        self.assertNotIn(['qm','guest','cmd','100','fstrim'],runner.calls)
    def test_vm_unknown_os_never_trims(self):
        runner = FakeRunner({('qm','status','100'):'status: running',
          ('qm','help','guest','cmd'): 'ping fstrim get-osinfo',
          ('qm','guest','cmd','100','get-osinfo'): '{"id":"haos"}'})
        with self.assertRaises(CommandError):
            execute('trim',Context('vm',100),runner,confirmed=True)
        self.assertNotIn(['qm','guest','cmd','100','fstrim'],runner.calls)
    def test_vm_image_filesystem_explicitly_labelled(self):
        runner = FakeRunner({('qm','status','100'):'status: running',
          ('qm','help','guest','cmd'): 'ping get-fsinfo',
          ('qm','guest','cmd','100','get-fsinfo'): '[{"mountpoint":"/","type":"erofs","total-bytes":100,"used-bytes":100}]'})
        report = execute('filesystems',Context('vm',100),runner)
        self.assertIn('schreibgeschütztes Image',report)
        self.assertIn('100.0%',report)
    def test_volume_resolves_configured_name(self):
        runner = FakeRunner({('pct','config','101'): 'rootfs: custom:unusual-volume,size=10G\n',
          ('pvesm','path','custom:unusual-volume'): '/dev/custom/real'})
        report = execute('volumes',Context('ct',101),runner)
        self.assertIn('/dev/custom/real',report)
        self.assertNotIn('vm-101-disk-0',report)
    def test_stopped_ct_cache_never_executes_guest_command(self):
        runner = FakeRunner({('pct','status','101'):'status: stopped'})
        with self.assertRaises(CommandError):
            prepare('cache-clean',Context('ct',101),runner)
        self.assertEqual(runner.calls,[['pct','status','101']])
    def test_running_ct_cache_clean_targets_selected_guest(self):
        runner = FakeRunner({('pct','status','101'):'status: running',
          ('pct','exec','101','--','cat','/etc/os-release'):'ID=debian'})
        execute('cache-clean',Context('ct',101),runner,confirmed=True)
        self.assertEqual(runner.calls[-1],['pct','exec','101','--','apt-get','clean'])
