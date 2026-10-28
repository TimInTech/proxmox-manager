"""Private, atomic state files; never source stored data as code."""
import json
import os
import stat
import tempfile
from pathlib import Path

STATE = Path('/var/lib/pman-maintenance')


def private_dir(path):
    path = Path(path)
    if not path.exists():
        path.mkdir(mode=0o700, parents=False)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
        raise RuntimeError('Unsicheres Zustandsverzeichnis: {}'.format(path))
    return path


def read_json(path, default=None):
    path = Path(path)
    try:
        if path.parent.exists() or path.parent.is_symlink():
            private_dir(path.parent)
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise RuntimeError('Unsichere Zustandsdatei: {}'.format(path))
        if info.st_size > 2 * 1024 * 1024:
            raise RuntimeError('Zustandsdatei zu groß.')
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_json(path, value):
    path = Path(path)
    private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix='.state-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
