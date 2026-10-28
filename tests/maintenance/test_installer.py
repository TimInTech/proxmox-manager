import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class InstallerTest(unittest.TestCase):
    def install(self, stage, *flags):
        return subprocess.run(['bash', str(ROOT / 'install_dependencies.sh'), '--destdir', str(stage), *flags],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True)
    def test_default_installs_only_core(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory) / 'stage'
            result = self.install(stage)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((stage / 'usr/local/bin/pman').is_file())
            self.assertFalse((stage / 'usr/local/bin/pman-maintenance').exists())
    def test_optional_install_and_uninstall_preserve_core(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory) / 'stage'
            result = self.install(stage, '--with-maintenance')
            self.assertEqual(result.returncode, 0, result.stderr)
            package = stage / 'usr/local/lib/pman/maintenance/current'
            self.assertTrue(package.is_symlink())
            self.assertTrue((package / 'sources.json').is_file())
            self.assertFalse(list(package.rglob('__pycache__')))
            result = self.install(stage, '--uninstall-maintenance')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((stage / 'usr/local/bin/pman').is_file())
            self.assertFalse(package.exists())
    def test_intermediate_symlink_cannot_escape_staging(self):
        for flag in ('--without-maintenance', '--uninstall-maintenance'):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as directory:
                stage = Path(directory) / 'stage'
                outside = Path(directory) / 'outside'
                stage.mkdir(); outside.mkdir()
                (stage / 'usr').symlink_to(outside, target_is_directory=True)
                result = self.install(stage, flag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(outside.iterdir()), [])
    def test_staging_root_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            outside = Path(directory) / 'outside'; outside.mkdir()
            stage = Path(directory) / 'stage'; stage.symlink_to(outside, target_is_directory=True)
            self.assertNotEqual(self.install(stage).returncode, 0)
            self.assertEqual(list(outside.iterdir()), [])

if __name__ == '__main__': unittest.main()

class RollbackTest(unittest.TestCase):
    def test_updates_switch_atomically_and_rollback(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'; source.mkdir()
            shutil.copy2(ROOT / 'install_dependencies.sh', source)
            shutil.copy2(ROOT / 'proxmox-manager.sh', source)
            shutil.copytree(ROOT / 'maintenance', source / 'maintenance', ignore=shutil.ignore_patterns('__pycache__'))
            stage = root / 'stage'
            def install(*args):
                result = subprocess.run(['bash', str(source/'install_dependencies.sh'), '--destdir', str(stage), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            install('--with-maintenance')
            package = stage / 'usr/local/lib/pman/maintenance'
            old = os.readlink(package/'current')
            version = source/'maintenance/pman_maintenance/__init__.py'
            version.write_text(version.read_text().replace("VERSION = '1.0.3'", "VERSION = '1.0.4'"))
            install('--with-maintenance')
            new = os.readlink(package/'current')
            self.assertNotEqual(new, old)
            self.assertEqual(os.readlink(package/'previous'), old)
            install('--rollback-maintenance')
            self.assertEqual(os.readlink(package/'current'), old)
            self.assertEqual(os.readlink(package/'previous'), new)

class PathAliasTest(unittest.TestCase):
    def test_root_aliases_rejected_before_any_operation(self):
        for alias in ('/tmp/..', '//', '/tmp/../', '/usr/..', '/tmp/a/../b'):
            with self.subTest(alias=alias):
                result = subprocess.run(['bash', str(ROOT/'install_dependencies.sh'), '--destdir', alias], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('normalized absolute',result.stderr)
    def test_masked_timer_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            stage=Path(directory)/'stage'
            units=stage/'etc/systemd/system'; units.mkdir(parents=True)
            timer=units/'pman-maintenance-sources.timer'; timer.symlink_to('/dev/null')
            result=subprocess.run(['bash',str(ROOT/'install_dependencies.sh'),'--destdir',str(stage),'--with-maintenance'],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(os.readlink(timer),'/dev/null')
