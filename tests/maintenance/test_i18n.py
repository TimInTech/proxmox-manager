"""Language selection and catalog completeness of the maintenance module."""
import ast
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))

from pman_maintenance import actions, community, i18n
from pman_maintenance.catalog_en import EN

PACKAGE = Path(__file__).resolve().parents[2] / 'maintenance' / 'pman_maintenance'


def translated_literals():
    """Every literal passed to _() plus the table texts that are translated on display."""
    found = set()
    for path in PACKAGE.glob('*.py'):
        if path.name == 'catalog_en.py':
            continue
        for node in ast.walk(ast.parse(path.read_text())):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == '_'
                    and node.args and isinstance(node.args[0], ast.Constant)):
                found.add(node.args[0].value)
    for tool in community.TOOLS:
        found.update([tool['summary'], tool['impact']] + ([tool['level_note']] if 'level_note' in tool else []))
    found.update(title for _key, title in community.GROUPS)
    for word, meaning in community.LEVELS.values():
        found.update([word, meaning])
    for action in actions.ACTIONS:
        found.update([action.title, action.source])
    found.update(['geprüfter Stand', 'Upstream geändert', 'Quelle fehlt', 'Prüfung fehlgeschlagen',
                  'Noch nicht geprüft', 'FREMD'])
    return found


class CatalogTest(unittest.TestCase):
    def test_every_translatable_text_has_an_english_entry(self):
        missing = sorted(text for text in translated_literals() if text not in EN)
        self.assertEqual(missing, [])

    def test_catalog_has_no_stale_entries(self):
        used = translated_literals()
        self.assertEqual(sorted(key for key in EN if key not in used), [])

    def test_placeholders_match_between_languages(self):
        for german, english in EN.items():
            self.assertEqual(german.count('{}'), english.count('{}'), german)

    def test_english_text_is_not_left_german(self):
        german_words = ('nicht ', 'Fehler', 'Gast ', 'wird ', ' und ', 'Änder')
        for german, english in EN.items():
            if german == english:
                continue
            self.assertFalse(any(word in english for word in german_words), (german, english))


class ReportTest(unittest.TestCase):
    def setUp(self):
        self.addCleanup(i18n.set_language, None)

    def test_source_report_without_stored_check_in_both_languages(self):
        from pman_maintenance import sources
        for language, expected in (('de', 'Zuletzt geprüft: Noch nicht geprüft'),
                                   ('en', 'Last checked: not checked yet')):
            i18n.set_language(language)
            with patch.object(sources, 'read_json', return_value={}):
                first_line = sources.source_report().splitlines()[0]
            self.assertEqual(first_line, expected)


class LanguageSelectionTest(unittest.TestCase):
    def setUp(self):
        i18n.set_language(None)
        self.addCleanup(i18n.set_language, None)

    def test_default_is_german_and_env_wins_over_config(self):
        with patch.object(i18n, '_from_config', return_value=''):
            self.assertEqual(i18n.language({}), 'de')
            self.assertEqual(i18n.language({'PMAN_LANG': 'EN'}), 'en')
            self.assertEqual(i18n.language({'PMAN_LANG': 'fr'}), 'de')
        with patch.object(i18n, '_from_config', return_value='en'):
            self.assertEqual(i18n.language({}), 'en')
            self.assertEqual(i18n.language({'PMAN_LANG': 'de'}), 'de')

    def test_config_file_must_be_root_owned_and_not_writable_by_others(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'language'
            config.write_text('en\n')
            with patch.object(i18n, 'CONFIG', config):
                self.assertEqual(i18n._from_config(), '' if os.geteuid() != 0 else 'en')
                config.chmod(0o666)
                self.assertEqual(i18n._from_config(), '')

    def test_translation_and_fallback(self):
        i18n.set_language('en')
        self.assertEqual(i18n._('Bereit'), 'Ready')
        self.assertEqual(i18n._('nicht im Katalog'), 'nicht im Katalog')
        i18n.set_language('de')
        self.assertEqual(i18n._('Bereit'), 'Bereit')
        with self.assertRaises(ValueError):
            i18n.set_language('fr')


if __name__ == '__main__':
    unittest.main()
