import sys
import threading
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))
from pman_maintenance.runner import Runner, CommandError

class RunnerTest(unittest.TestCase):
    def test_executes_without_shell(self):
        text = Runner().run([sys.executable, '-c', 'import sys; print(sys.argv[1])', '$(echo unsafe)']).text
        self.assertEqual(text.strip(), '$(echo unsafe)')
    def test_failure_reported(self):
        with self.assertRaises(CommandError):
            Runner().run([sys.executable, '-c', 'raise SystemExit(7)'])
    def test_timeout(self):
        with self.assertRaisesRegex(CommandError, 'Zeitlimit'):
            Runner().run([sys.executable, '-c', 'import time; time.sleep(30)'], timeout=.1)
    def test_running_job_can_be_cancelled(self):
        cancel = threading.Event()
        timer = threading.Timer(.1, cancel.set); timer.start()
        try:
            with self.assertRaisesRegex(CommandError, 'Abgebrochen'):
                Runner(cancel).run([sys.executable, '-c', 'import time; time.sleep(30)'])
        finally:
            timer.join()
    def test_missing_executable_reported(self):
        with self.assertRaises(CommandError):
            Runner().run(['/no/such/pman-test-command'])

if __name__ == '__main__': unittest.main()
