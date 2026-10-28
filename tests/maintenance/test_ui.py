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


class LayoutTest(unittest.TestCase):
    def test_selection_details_and_small_terminal_guard(self):
        from pman_maintenance.ui import action_description, terminal_usable
        from pman_maintenance.actions import Context, registry
        action = registry(Context('ct', 101))[0]
        self.assertIn('Diagnose', action_description(action))
        self.assertFalse(terminal_usable(8, 30))
        self.assertTrue(terminal_usable(24, 80))

    def test_wrapping_removes_control_sequences_and_bounds_lines(self):
        from pman_maintenance.ui import wrap_output
        lines = wrap_output(['\x1b[2J' + 'x' * 50], 12)
        self.assertTrue(all(len(line) <= 12 for line in lines))
        self.assertFalse(any('\x1b' in line for line in lines))

class SmallTerminalTest(unittest.TestCase):
    def test_enter_cannot_launch_hidden_action(self):
        from unittest.mock import patch
        from pman_maintenance import ui
        from pman_maintenance.actions import Context
        class Screen:
            def __init__(self): self.keys = [10, ord('q')]
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (8, 30)
            def addnstr(self, *args): pass
            def refresh(self): pass
            def getch(self): return self.keys.pop(0)
        with patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'flushinp'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui, 'execute') as execute:
            ui._screen(Screen(), Context('host'))
        execute.assert_not_called()

class ConfirmationTest(unittest.TestCase):
    def test_hidden_confirmation_details_cannot_be_accepted(self):
        import time
        from unittest.mock import patch
        from pman_maintenance import ui
        from pman_maintenance.actions import Context
        class Screen:
            def __init__(self):
                self.keys = [ui.curses.KEY_DOWN] * 3 + [10, ord('j'), ord('n'), ord('q')]
                self.rows = []
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (12, 45)
            def addnstr(self, row, col, value, *args): self.rows.append(value)
            def refresh(self): pass
            def getch(self):
                time.sleep(.02)
                return self.keys.pop(0)
        screen = Screen()
        plan = {'target': 'CT 101', 'display': 'pct fstrim 101',
                'impact': 'Impact: ' + ('long details ' * 30)}
        with patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'flushinp'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui, 'prepare', return_value=plan), \
             patch.object(ui, 'mutate') as mutation:
            ui._screen(screen, Context('ct', 101))
        mutation.assert_not_called()
        self.assertTrue(any('alle Details' in row for row in screen.rows))

    def test_confirmation_after_scrolling_starts_only_selected_action(self):
        import time
        from unittest.mock import patch
        from pman_maintenance import ui
        from pman_maintenance.actions import Context
        class Screen:
            def __init__(self):
                self.keys = ([ui.curses.KEY_DOWN] * 3 + [10] +
                             [ui.curses.KEY_NPAGE] * 20 + [ord('j'), ord('q')])
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (12, 45)
            def addnstr(self, *args): pass
            def refresh(self): pass
            def getch(self):
                time.sleep(.02)
                return self.keys.pop(0)
        plan = {'target': 'CT 101', 'display': 'pct fstrim 101',
                'impact': 'Impact: ' + ('long details ' * 30)}
        with patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'flushinp'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui, 'prepare', return_value=plan), \
             patch.object(ui, 'mutate', return_value='done') as mutation:
            ui._screen(Screen(), Context('ct', 101))
        self.assertEqual(mutation.call_count, 1)
        self.assertEqual(mutation.call_args.args[:2], ('trim', Context('ct', 101)))

    def test_buffered_confirmation_key_is_flushed_before_view(self):
        import time
        from unittest.mock import patch
        from pman_maintenance import ui
        from pman_maintenance.actions import Context
        class Screen:
            def __init__(self): self.keys = [ui.curses.KEY_DOWN] * 3 + [10, ord('j'), ord('n'), ord('q')]
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (24, 80)
            def addnstr(self, *args): pass
            def refresh(self): pass
            def getch(self):
                time.sleep(.02)
                return self.keys.pop(0)
        screen = Screen()
        plan = {'target': 'CT 101', 'display': 'pct fstrim 101', 'impact': 'TRIM'}
        def flush():
            if screen.keys and screen.keys[0] == ord('j'):
                screen.keys.pop(0)
        with patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui.curses, 'flushinp', side_effect=flush) as flush_input, \
             patch.object(ui, 'prepare', return_value=plan), \
             patch.object(ui, 'mutate') as mutation:
            ui._screen(screen, Context('ct', 101))
        flush_input.assert_called_once()
        mutation.assert_not_called()

    def test_flush_failure_rejects_confirmation(self):
        import time
        from unittest.mock import patch
        from pman_maintenance import ui
        from pman_maintenance.actions import Context
        class Screen:
            def __init__(self): self.keys = [ui.curses.KEY_DOWN] * 3 + [10, ord('j'), ord('q')]
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self): return (24, 80)
            def addnstr(self, *args): pass
            def refresh(self): pass
            def getch(self):
                time.sleep(.02)
                return self.keys.pop(0)
        plan = {'target': 'CT 101', 'display': 'pct fstrim 101', 'impact': 'TRIM'}
        with patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'has_colors', return_value=False), \
             patch.object(ui.curses, 'flushinp', side_effect=ui.curses.error), \
             patch.object(ui, 'prepare', return_value=plan), \
             patch.object(ui, 'mutate') as mutation:
            ui._screen(Screen(), Context('ct', 101))
        mutation.assert_not_called()

class ResizeAndColorTest(unittest.TestCase):
    def test_resize_and_no_color_leave_small_view_and_do_not_initialize_colors(self):
        from unittest.mock import patch
        from pman_maintenance import ui
        from pman_maintenance.actions import Context
        class Screen:
            def __init__(self): self.keys = [ui.curses.KEY_RESIZE, ord('q')]; self.count = 0; self.rows = []
            def keypad(self, enabled): pass
            def timeout(self, value): pass
            def erase(self): pass
            def getmaxyx(self):
                self.count += 1
                return (8, 30) if self.count == 1 else (24, 80)
            def addnstr(self, row, col, value, *args): self.rows.append(value)
            def refresh(self): pass
            def getch(self): return self.keys.pop(0)
        screen = Screen()
        with patch.dict(ui.os.environ, {'NO_COLOR': '1'}), \
             patch.object(ui.curses, 'curs_set'), \
             patch.object(ui.curses, 'flushinp'), \
             patch.object(ui.curses, 'has_colors', return_value=True), \
             patch.object(ui.curses, 'start_color') as color:
            ui._screen(screen, Context('host'))
        color.assert_not_called()
        self.assertTrue(any('Terminal mindestens' in row for row in screen.rows))
        self.assertTrue(any('pman Wartung' in row for row in screen.rows))

if __name__ == '__main__':
    unittest.main()
