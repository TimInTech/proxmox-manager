import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))
from pman_maintenance.ui import clean_text, navigate

class UITest(unittest.TestCase):
    def test_terminal_escape_removed(self):
        self.assertEqual(clean_text('a\x1b[31mred\x1b[0m\x07'), 'ared')
    def test_navigation_wraps(self):
        self.assertEqual(navigate(0, -1, 4), 3)
        self.assertEqual(navigate(3, 1, 4), 0)

if __name__ == '__main__': unittest.main()
