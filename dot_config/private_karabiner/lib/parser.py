"""YAML parsing, entry parsing, QWERTY sorting, and help text formatting."""
import re

# Re-exported from the shared table so existing `from .parser import GOKU_NAMES`
# importers keep working; the canonical definition lives in data/keymap-tables.json.
from .tables import GOKU_NAMES  # noqa: F401

QWERTY = list("qwertyuiop[]\\asdfghjkl;'zxcvbnm,./")


def qwerty_pos(key):
    low = key.lower()
    pos = QWERTY.index(low) if low in QWERTY else 999
    # Final `low` tiebreaker keeps ordering deterministic: digits and symbols
    # not in QWERTY all share pos 999, and without it their order would leak
    # from per-process set/hash iteration (see generate.py workspace merge).
    return (pos, 0 if key.islower() or not key.isalpha() else 1, low)


def parse_yaml(path):
    """Parse YAML into {section: [entries]}. Comments are skipped."""
    sections = {}
    current = None
    with open(path) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if re.match(r'^[a-z][\w-]*:\s*$', stripped):
                current = stripped.rstrip(': ')
                sections[current] = []
            elif current and stripped.startswith('- '):
                val = stripped[2:].strip()
                if not val.startswith('#'):
                    sections[current].append(val)
    return sections


def parse_yaml_grouped(path):
    """Like parse_yaml but comments within a section start a new group.

    Returns {section: [[group1], [group2], ...]}
    """
    sections = {}
    current = None
    group = []
    with open(path) as f:
        for line in f:
            stripped = line.strip()
            if not stripped:
                continue
            if re.match(r'^[a-z][\w-]*:\s*$', stripped):
                if current and group:
                    sections.setdefault(current, []).append(group)
                current = stripped.rstrip(': ')
                group = []
                continue
            if stripped.startswith('#'):
                if current and group:
                    sections.setdefault(current, []).append(group)
                    group = []
                continue
            if current and stripped.startswith('- '):
                val = stripped[2:].strip()
                group.append(val)
    if current and group:
        sections.setdefault(current, []).append(group)
    return sections


def parse_entry(entry):
    """Parse 'key | label | extra' or 'key | label'."""
    parts = [p.strip() for p in entry.split('|')]
    key = parts[0]
    label = parts[1] if len(parts) > 1 else key
    extra = parts[2] if len(parts) > 2 else None
    return key, label, extra


def help_text(entries):
    """Format entries as sorted comma-separated 'key:label' string."""
    items = []
    for entry in entries:
        key, label, _ = parse_entry(entry)
        # Escape backslash for EDN string embedding
        display_key = '\\\\' if key == '\\' else key
        items.append((key, f"{display_key}:{label}"))
    items.sort(key=lambda x: qwerty_pos(x[0]))
    return ', '.join(t for _, t in items)


def help_text_grouped(groups, sort=True):
    r"""Format groups of entries as \\n-separated sections.

    Each group is comma-separated internally. Groups are joined by \\n.
    """
    lines = []
    for group in groups:
        items = []
        for entry in group:
            if '|' in entry:
                key, label, _ = parse_entry(entry)
                items.append((key, f"{key}:{label}"))
            else:
                items.append((entry[0] if entry else '', entry))
        if sort:
            items.sort(key=lambda x: qwerty_pos(x[0]))
        lines.append(', '.join(t for _, t in items))
    return '\\n'.join(lines)
