"""Display language of the maintenance module: German (default) or English.

German source text is the catalog key; English comes from catalog_en.EN. A text
without an entry is shown as written, so a missing translation never breaks the UI.
Persisted identifiers (for example source-check statuses) stay German in files
and are translated only where they are displayed.
"""
import os
import stat
from pathlib import Path

from .catalog_en import EN

LANGUAGES = ('de', 'en')
DEFAULT = 'de'
# Written by install_dependencies.sh; only 'de' or 'en' is accepted from it.
CONFIG = Path('/etc/pman/language')
_override = None


def _from_config():
    try:
        info = CONFIG.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            return ''
        return CONFIG.read_text()[:16].strip().lower()
    except OSError:
        return ''


def language(env=None):
    """PMAN_LANG, then the installer's config file, then the German default."""
    if _override:
        return _override
    env = os.environ if env is None else env
    for value in (env.get('PMAN_LANG', ''), _from_config()):
        value = value.strip().lower()[:2]
        if value in LANGUAGES:
            return value
    return DEFAULT


def set_language(code):
    """Force a language (tests); None restores the normal resolution."""
    global _override
    if code is not None and code not in LANGUAGES:
        raise ValueError('Unsupported language: {}'.format(code))
    _override = code


def _(text):
    return EN.get(text, text) if language() == 'en' else text
