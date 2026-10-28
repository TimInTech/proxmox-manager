import json
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

class CoreTest(unittest.TestCase):
    def test_maintenance_mode_conflicts_rejected(self):
        result = subprocess.run(['bash', str(ROOT/'proxmox-manager.sh'), '--maintenance', '--json'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cannot be combined', result.stderr)
    def test_missing_module_has_install_hint(self):
        script = 'source <(sed \'/^main "\\$@"$/d\' '+shlex.quote(str(ROOT/'proxmox-manager.sh'))+'); _MAINTENANCE_EXEC=/nonexistent/pman-maintenance; maintenance_open host'
        result = subprocess.run(['bash','-c',script],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('--with-maintenance',result.stderr)
    def test_selected_guest_passed_without_force(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory)/'module'
            log = Path(directory)/'args'
            executable.write_text('#!/bin/bash\nif [[ "$1" == --interface ]]; then echo \'{"interface":1,"version":"1.0.0"}\'; else printf "%s\\n" "$@" > '+shlex.quote(str(log))+'; fi\n')
            executable.chmod(0o755)
            script = 'source <(sed \'/^main "\\$@"$/d\' '+shlex.quote(str(ROOT/'proxmox-manager.sh'))+'); stat() { case "$2" in %u) echo 0;; %a) echo 755;; esac; }; _MAINTENANCE_EXEC='+shlex.quote(str(executable))+'; FORCE_MODE=1; maintenance_open ct 101'
            result = subprocess.run(['bash','-c',script],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(log.read_text().splitlines(),['--scope','ct','--id','101'])

if __name__ == '__main__': unittest.main()
