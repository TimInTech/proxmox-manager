"""Bounded, cancellable process execution without a command shell."""
import os
import signal
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass


class CommandError(RuntimeError):
    pass


@dataclass
class Result:
    argv: list
    returncode: int
    text: str


class Runner:
    def __init__(self, cancel=None):
        self.cancel = cancel or threading.Event()

    def run(self, argv, timeout=30, allowed=(0,)):
        argv = [str(a) for a in argv]
        if self.cancel.is_set():
            raise CommandError('Abgebrochen.')
        env = dict(os.environ, LC_ALL='C', LANG='C', PATH='/usr/sbin:/usr/bin:/sbin:/bin')
        with tempfile.TemporaryFile() as output:
            try:
                process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True, env=env)
            except OSError as exc:
                raise CommandError('{}: {}'.format(argv[0], exc)) from exc
            deadline = time.monotonic() + timeout
            reason = ''
            try:
                while process.poll() is None:
                    if self.cancel.wait(.05):
                        reason = 'Abgebrochen; bereits ausgeführte Änderungen werden nicht rückgängig gemacht.'
                    elif time.monotonic() > deadline:
                        reason = 'Zeitlimit erreicht.'
                    elif os.fstat(output.fileno()).st_size > 2 * 1024 * 1024:
                        reason = 'Ausgabelimit erreicht.'
                    if reason:
                        break
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(2)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
            output.seek(0)
            text = output.read(2 * 1024 * 1024).decode('utf-8', 'replace')
        if reason:
            raise CommandError(reason)
        if allowed is not None and process.returncode not in allowed:
            raise CommandError('{} (Exit {}): {}'.format(argv[0], process.returncode, text[:4000]))
        return Result(argv, process.returncode, text)
