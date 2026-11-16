"""Read the hotkeys of the Keyboard Maestro macros for the key search HUD.

Keyboard Maestro owns these hotkeys, so no YAML file in this directory
declares them. The build reads them from the macro files. Thus a new macro
with a hotkey shows in the help without a second step.

Each hotkey is one of three kinds:

- hyper: all four modifiers (cmd+ctrl+opt+shift). CapsLock held sends these,
  so the key shows in the Hyper layer, with no Karabiner rule.
- fkey: F13 to F20. A shortcut layer sends the F-key, and the layer row
  already shows the key. The build only makes sure that a layer sends it.
- extra: any other combo. It shows in the list of hand-written keys.
"""
import os
import plistlib
import re
from dataclasses import dataclass

from .tables import GOKU_NAMES

# Mac virtual key code -> key name, as the key search HUD writes the key
KEYCODES = {
    0: 'a', 1: 's', 2: 'd', 3: 'f', 4: 'h', 5: 'g', 6: 'z', 7: 'x', 8: 'c',
    9: 'v', 11: 'b', 12: 'q', 13: 'w', 14: 'e', 15: 'r', 16: 'y', 17: 't',
    18: '1', 19: '2', 20: '3', 21: '4', 22: '6', 23: '5', 24: '=', 25: '9',
    26: '7', 27: '-', 28: '8', 29: '0', 30: ']', 31: 'o', 32: 'u', 33: '[',
    34: 'i', 35: 'p', 36: 'return_or_enter', 37: 'l', 38: 'j', 39: "'", 40: 'k',
    41: ';', 42: '\\', 43: ',', 44: '/', 45: 'n', 46: 'm', 47: '.',
    48: 'tab', 49: 'spacebar', 50: '`', 51: 'delete_or_backspace', 53: 'escape',
    122: 'f1', 120: 'f2', 99: 'f3', 118: 'f4', 96: 'f5', 97: 'f6', 98: 'f7',
    100: 'f8', 101: 'f9', 109: 'f10', 103: 'f11', 111: 'f12', 105: 'f13',
    107: 'f14', 113: 'f15', 106: 'f16', 64: 'f17', 79: 'f18', 80: 'f19',
    90: 'f20', 123: 'left_arrow', 124: 'right_arrow', 125: 'down_arrow',
    126: 'up_arrow',
}

# Keyboard Maestro modifier bit -> glyph, in the order that macOS shows them
MODIFIER_BITS = [(4096, '⌃'), (2048, '⌥'), (512, '⇧'), (256, '⌘')]
HYPER = '⌃⌥⇧⌘'
FKEY = re.compile(r'f1[3-9]|f20')


class HotkeyError(ValueError):
    """A macro has a hotkey that the build cannot show in the help."""


@dataclass(frozen=True)
class Hotkey:
    macro: str   # file name without .kmmacros, e.g. 'snapcal'
    name: str    # macro name in Keyboard Maestro, e.g. 'Screenshot to Calendar'
    key: str     # key name, e.g. 'd' or 'f17'
    mods: str    # glyphs in macOS order, e.g. '⌥⌘'

    @property
    def kind(self):
        if self.mods == HYPER:
            return 'hyper'
        if FKEY.fullmatch(self.key):
            return 'fkey'
        return 'extra'


def decode(macro, name, keycode, modifiers):
    """Turn one Keyboard Maestro hotkey trigger into a Hotkey."""
    key = KEYCODES.get(keycode)
    if key is None:
        raise HotkeyError(f'{macro}: unknown key code {keycode}. Add it to KEYCODES in lib/kmhotkeys.py.')
    known = sum(bit for bit, _ in MODIFIER_BITS)
    if modifiers & ~known:
        raise HotkeyError(f'{macro}: unknown modifier bits {modifiers & ~known} in {modifiers}.')
    mods = ''.join(glyph for bit, glyph in MODIFIER_BITS if modifiers & bit)
    return Hotkey(macro, name, key, mods)


def load(macros_dir):
    """Return the Hotkey of each enabled hotkey trigger in the macro files."""
    hotkeys = []
    for fname in sorted(os.listdir(macros_dir)):
        if not fname.endswith('.kmmacros'):
            continue
        macro = fname[:-len('.kmmacros')]
        with open(os.path.join(macros_dir, fname), 'rb') as f:
            data = plistlib.load(f)
        if data.get('IsActive') is False:
            continue
        for trigger in data.get('Triggers', []):
            if trigger.get('MacroTriggerType') != 'HotKey':
                continue
            hotkeys.append(decode(macro, data.get('Name', macro),
                                  trigger['KeyCode'], trigger['Modifiers']))
    return hotkeys


def find_macros_dir(karabiner_dir):
    """Find the macro files next to this directory: the chezmoi source or the deployed copy."""
    for name in ('exact_macros', 'macros'):
        path = os.path.join(karabiner_dir, '..', 'keyboardmaestro', name)
        if os.path.isdir(path):
            return os.path.normpath(path)
    raise HotkeyError(f'no keyboardmaestro/exact_macros or keyboardmaestro/macros next to {karabiner_dir}')


def check(hotkeys, edn_text, fkey_rows):
    """Return the problems that would make a hotkey fail or hide it from the help.

    - A hyper hotkey that a Karabiner rule takes never reaches Keyboard Maestro.
    - An F-key hotkey that no shortcut layer sends has no key in the help.
    """
    taken = set(re.findall(r'\[:!QWER(\S+)\s', edn_text))
    sent = {(fkey.lower(), frozenset(glyphs))
            for fkey, glyphs, *_ in (row.split('\t') for row in fkey_rows)}
    problems = []
    for hk in hotkeys:
        goku_key = GOKU_NAMES.get(hk.key, hk.key)
        if hk.kind == 'hyper' and goku_key in taken:
            problems.append(f'{hk.macro}: hyper+{hk.key} is also a Karabiner rule, so Keyboard Maestro never gets it')
        if hk.kind == 'fkey' and (hk.key, frozenset(hk.mods)) not in sent:
            problems.append(f'{hk.macro}: no shortcut layer sends {hk.mods}{hk.key.upper()}')
    return problems

