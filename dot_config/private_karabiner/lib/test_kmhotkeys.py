"""Tests for lib/kmhotkeys.py. Run from dot_config/private_karabiner:

    python3 -m unittest lib.test_kmhotkeys
"""
import unittest

from lib.kmhotkeys import Hotkey, HotkeyError, check, decode


class DecodeTest(unittest.TestCase):
    def test_decode(self):
        # (key code, modifiers) -> (key, glyphs, kind). The values come from real macros.
        cases = {
            (2, 6912): ('d', '⌃⌥⇧⌘', 'hyper'),     # snapcal
            (42, 2304): ('\\', '⌥⌘', 'extra'),     # arc tab to window
            (64, 2304): ('f17', '⌥⌘', 'fkey'),     # punch, sent by l1
            (122, 6912): ('f1', '⌃⌥⇧⌘', 'hyper'),  # F1 is not a layer F-key
        }
        for (code, mods), want in cases.items():
            with self.subTest(code=code, mods=mods):
                hk = decode('m', 'M', code, mods)
                self.assertEqual((hk.key, hk.mods, hk.kind), want)

    def test_decode_rejects_unknown_values(self):
        for code, mods in [(999, 256), (2, 256 | 1024)]:
            with self.subTest(code=code, mods=mods), self.assertRaises(HotkeyError):
                decode('m', 'M', code, mods)


class CheckTest(unittest.TestCase):
    EDN = '    [:!QWERq           :!QWERq]  ;; freekey\n    [:!QWERslash :x]\n'
    FKEY_ROWS = ['F17\t⌘⌥\tl1\tw\tpunch']

    def test_check(self):
        cases = [
            (Hotkey('snapcal', 'S', 'd', '⌃⌥⇧⌘'), []),
            (Hotkey('clash', 'C', 'q', '⌃⌥⇧⌘'), ['clash: hyper+q is also a Karabiner rule']),
            (Hotkey('clash2', 'C', '/', '⌃⌥⇧⌘'), ['clash2: hyper+/ is also a Karabiner rule']),
            (Hotkey('punch', 'P', 'f17', '⌥⌘'), []),
            (Hotkey('lost', 'L', 'f18', '⌥⌘'), ['lost: no shortcut layer sends ⌥⌘F18']),
            (Hotkey('arc', 'A', '\\', '⌥⌘'), []),
        ]
        for hk, want in cases:
            with self.subTest(macro=hk.macro):
                got = check([hk], self.EDN, self.FKEY_ROWS)
                self.assertEqual(len(got), len(want), got)
                for problem, prefix in zip(got, want):
                    self.assertTrue(problem.startswith(prefix), problem)


if __name__ == '__main__':
    unittest.main()
