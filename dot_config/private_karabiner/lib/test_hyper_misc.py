"""Tests for check_hyper_misc in lib/generator.py. Run from dot_config/private_karabiner:

    uv run --with pyyaml python -m unittest lib.test_hyper_misc
"""
import unittest

from lib.generator import check_hyper_misc

BASE = """
;; BEGIN HYPER-RULES (auto-generated)
    [:!QWERh :left_arrow]
;; END HYPER-RULES
  {:des "Hand-written"
   :rules
   [;; hyper+t
    [:!QWERt [:toggle-topbar]]
    [:!QWERSslash [:key-search]]
    [:!QWER#Pescape :!Tcaps_lock]
    [:!CQWERspacebar :!TCspacebar]
    [:##caps_lock :!QWEright_shift nil {:alone :escape}]]}
"""

# The "misc" section that matches BASE
MISC = {'t': {'-': 'x'}, '/': {'shift': 'x'}, 'escape': {'-': 'x'}, 'spacebar': {'cmd': 'x'}}


class CheckHyperMiscTest(unittest.TestCase):
    def test_check(self):
        cases = {
            'match': (MISC, []),
            'rule with no help': ({k: v for k, v in MISC.items() if k != 't'},
                                  ['hyper+t is a rule in karabiner.base.edn']),
            'help with no rule': ({**MISC, 'f1': {'-': 'x'}},
                                  ['hyper+f1 is in config/hyperkeys.yaml']),
            'wrong modifier': ({**MISC, '/': {'cmd': 'x'}},
                               ['hyper+shift+slash is a rule', 'hyper+cmd+slash is in']),
        }
        for name, (misc, want) in cases.items():
            with self.subTest(name):
                got = check_hyper_misc(BASE, {'misc': misc})
                self.assertEqual(len(got), len(want), got)
                for problem, prefix in zip(got, want):
                    self.assertTrue(problem.startswith(prefix), problem)


if __name__ == '__main__':
    unittest.main()
