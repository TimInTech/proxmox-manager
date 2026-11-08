import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time
import unittest
from pathlib import Path


class TerminalPTYTest(unittest.TestCase):
    def test_normal_exit_restores_terminal_mode_and_cursor(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        module_dir = Path(__file__).resolve().parents[2] / 'maintenance'
        code = ('import sys; sys.path.insert(0, {!r}); '
                'from pman_maintenance.ui import run_tui; '
                'from pman_maintenance.actions import Context; '
                'run_tui(Context("host"))').format(str(module_dir))
        env = dict(os.environ, TERM='xterm-256color', NO_COLOR='1')
        process = subprocess.Popen([sys.executable, '-c', code], stdin=slave,
                                   stdout=slave, stderr=slave, env=env)
        output = bytearray()
        try:
            deadline = time.monotonic() + 5
            while b'pman Wartung' not in output and time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    output.extend(os.read(master, 65536))
            self.assertIn(b'pman Wartung', output)
            os.write(master, b'q')
            self.assertEqual(process.wait(timeout=5), 0)
            while select.select([master], [], [], 0)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            self.assertEqual(termios.tcgetattr(slave), original)
            self.assertIn(b'\x1b[?25h', output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)

    def test_exception_restores_terminal_mode(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        module_dir = Path(__file__).resolve().parents[2] / 'maintenance'
        code = ("import sys; sys.path.insert(0, {!r}); "
                "from pman_maintenance import ui; "
                "from pman_maintenance.actions import Context; "
                "exec('def fail(screen, ctx):\\n raise RuntimeError(\"test failure\")'); "
                "ui._screen=fail; "
                "exec('try:\\n ui.run_tui(Context(\"host\"))\\nexcept RuntimeError:\\n pass')").format(str(module_dir))
        process = subprocess.Popen([sys.executable, '-c', code], stdin=slave, stdout=slave,
                                   stderr=slave, env=dict(os.environ, TERM='xterm-256color'))
        try:
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(termios.tcgetattr(slave), original)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)

    def test_cancelled_diagnostic_restores_terminal(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        module_dir = Path(__file__).resolve().parents[2] / 'maintenance'
        code = ("import sys; sys.path.insert(0, {!r}); "
                "from pman_maintenance import ui; "
                "from pman_maintenance.actions import Context; "
                "exec('def slow(action, ctx, runner):\\n runner.cancel.wait(5)\\n raise RuntimeError(\"cancelled\")'); "
                "ui.execute=slow; ui.run_tui(Context('host'))").format(str(module_dir))
        process = subprocess.Popen([sys.executable, '-c', code], stdin=slave, stdout=slave,
                                   stderr=slave, env=dict(os.environ, TERM='xterm-256color', NO_COLOR='1'))
        output = bytearray()
        def wait_for(fragment):
            deadline = time.monotonic() + 7
            while fragment not in output and time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    output.extend(os.read(master, 65536))
            self.assertIn(fragment, output)
        try:
            wait_for(b'pman Wartung')
            os.write(master, b'\n')
            wait_for('Prüfung läuft'.encode())
            os.write(master, b'\x1b')
            wait_for(b'Abgebrochen')
            os.write(master, b'q')
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(termios.tcgetattr(slave), original)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)


class ResultInputRaceTest(unittest.TestCase):
    def test_quit_entered_after_result_is_visible_is_not_discarded(self):
        """A terminal reply to the new result must survive stale-input cleanup."""
        from unittest.mock import patch
        module_dir = Path(__file__).resolve().parents[2] / 'maintenance'
        sys.path.insert(0, str(module_dir))
        from pman_maintenance import ui
        from pman_maintenance.actions import Context

        class ImmediateWorker:
            def __init__(self, target, **kwargs): self.target = target
            def start(self): self.target()
            def is_alive(self): return False

        class Screen:
            def __init__(self):
                self.keys = [10]
                self.rows = []
                self.result_visible = False
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): self.rows = []
            def getmaxyx(self): return (24, 80)
            def addnstr(self, row, col, value, *args): self.rows.append(value)
            def refresh(self):
                if not self.result_visible and any('diagnostic complete' in row for row in self.rows):
                    self.result_visible = True
                    self.keys.append(ord('q'))
            def getch(self):
                if not self.keys:
                    raise AssertionError('quit entered after result was displayed was discarded')
                return self.keys.pop(0)

        screen = Screen()
        with patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'flushinp', side_effect=screen.keys.clear), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui.threading, 'Thread', ImmediateWorker), \
             patch.object(ui, 'execute', return_value='diagnostic complete'):
            ui._screen(screen, Context('host'))
        self.assertTrue(screen.result_visible)
