"""EDN rule generation for app-launch, shortcut layers, workspace, and hyper."""
import re, yaml, os
from .parser import parse_entry, qwerty_pos, help_text, help_text_grouped, GOKU_NAMES
from .pool import slot_to_combo, get_or_assign, POOL_SIZE

# layer -> (from_modifier, condition_var, description)
LAYERS = {
    'l1': ('!S', 'shortcut-l1', 'Shortcut Layer 1 (Shift+RightOpt)'),
    # #O = left_option optional, so l2 keys fire from either trigger:
    # LeftCtrl+RightOpt or LeftCtrl+LeftOpt (see karabiner.base.edn).
    'l2': ('!T#O', 'shortcut-l2', 'Shortcut Layer 2 (Ctrl+Opt)'),
    'l3': ('!C', 'shortcut-l3', 'Shortcut Layer 3 (Cmd+RightOpt)'),
}


# -- App-launch rules ---------------------------------------------------------

def make_rule(key, label, app):
    is_shifted = key.isupper() and key.isalpha()
    from_key = f":!S{key.lower()}" if is_shifted else f":{key}"
    if app and app.startswith('!'):
        to_part = f":{app}"
    elif app and app.startswith('sh:'):
        # sh: prefix runs the rest of the field as a shell command
        to_part = f'"{app[3:]}"'
    elif app:
        to_part = f'[:open "{app}"]'
    else:
        to_part = f'[:open "{label}"]'
    inner = f"[{from_key} {to_part}"
    return f"    {inner:<38s}:app-launch]"


def extract_edn_keys(existing_block):
    active = {}
    commented = {}
    if not existing_block:
        return active, commented
    for line in existing_block.split('\n'):
        stripped = line.strip()
        m = re.match(r'\[:(!S)?([a-z])\s', stripped)
        if m:
            key = m.group(2).upper() if m.group(1) == '!S' else m.group(2)
            active[key] = stripped
            continue
        m = re.match(r';+\s*\[:(!S)?([a-z])\s', stripped)
        if m:
            key = m.group(2).upper() if m.group(1) == '!S' else m.group(2)
            commented[key] = stripped.lstrip('; ')
    return active, commented


def generate_app_rules(entries, existing_block):
    warnings = []
    new_keys = set()
    shifted, unshifted = [], []

    for entry in entries:
        key, label, app = parse_entry(entry)
        new_keys.add(key)
        rule = make_rule(key, label, app)
        if key.isupper() and key.isalpha():
            shifted.append((key, rule))
        else:
            unshifted.append((key, rule))

    shifted.sort(key=lambda x: qwerty_pos(x[0]))
    unshifted.sort(key=lambda x: qwerty_pos(x[0]))

    active, commented = extract_edn_keys(existing_block)
    removed_shifted, removed_unshifted = [], []

    for key, rule_line in active.items():
        if key not in new_keys:
            warnings.append(f"  COMMENTING OUT: '{key}' active in EDN but missing from YAML -> {rule_line}")
            entry = (key, f"    ; {rule_line}")
            if key.isupper() and key.isalpha():
                removed_shifted.append(entry)
            else:
                removed_unshifted.append(entry)

    for key, rule_line in commented.items():
        if key not in new_keys:
            entry = (key, f"    ; {rule_line}")
            if key.isupper() and key.isalpha():
                removed_shifted.append(entry)
            else:
                removed_unshifted.append(entry)

    all_edn_keys = set(active) | set(commented)
    for key in sorted(new_keys - all_edn_keys, key=qwerty_pos):
        warnings.append(f"  NEW RULE: '{key}' in YAML but not yet in EDN -> will be added")

    removed_shifted.sort(key=lambda x: qwerty_pos(x[0]))
    removed_unshifted.sort(key=lambda x: qwerty_pos(x[0]))

    lines = ['    ;; Shifted shortcuts']
    lines += [r for _, r in shifted]
    lines += [r for _, r in removed_shifted]
    lines += ['']
    lines += ['    ;; Unshifted shortcuts']
    lines += [r for _, r in unshifted]
    lines += [r for _, r in removed_unshifted]
    return '\n'.join(lines), warnings


# -- Shortcut layer rules -----------------------------------------------------

def direct_to(action):
    """Goku `to` for a direct shortcut action, or None for an F-key pool entry.

    open:App          -> open -a (by app name)
    open-id:bundle.id -> open -b (by bundle id; works when the app name differs per Mac)
    !gokuCombo        -> the combo itself
    """
    if not action:
        return None
    if action.startswith('open:'):
        return f'[:open "{action[len("open:"):]}"]'
    if action.startswith('open-id:'):
        return f'[:open-id "{action[len("open-id:"):]}"]'
    if action.startswith('!'):
        return f':{action}'
    return None


def generate_layer(pool_map, layer_name, entries):
    """Generate a complete Goku rule block for a shortcut layer."""
    from_mod, condition, des = LAYERS[layer_name]
    n = layer_name[-1]

    pool_entries = []   # (key, label, action=None) — go through fkey pool
    direct_rules = []   # (key, label, goku_to) — emit directly without pool

    for entry in entries:
        key, label, action = parse_entry(entry)
        gk = GOKU_NAMES.get(key, key)
        from_str = f":{from_mod}{gk}"
        goku_to = direct_to(action)
        if goku_to:
            direct_rules.append((key, label, from_str, goku_to))
        else:
            pool_entries.append((key, label))

    # Pool-based entries
    parsed = []
    for key, label in pool_entries:
        slot = get_or_assign(pool_map, layer_name, key)
        parsed.append((slot, key, label))
    parsed.sort()

    rule_lines = []
    current_fkey = None
    for slot, key, label in parsed:
        fkey, human_mod, goku_mod = slot_to_combo(slot)

        if fkey != current_fkey:
            if rule_lines:
                rule_lines.append('')
            rule_lines.append(f'    ;; --- {fkey.upper()} ---')
            current_fkey = fkey

        gk = GOKU_NAMES.get(key, key)
        human = f"{human_mod}{fkey.upper()}"
        goku_to = f":{goku_mod}{fkey}" if goku_mod else f":{fkey}"
        from_str = f":{from_mod}{gk}"

        if len(gk) > 1:
            rule = f"    [{from_str:<28s}{goku_to:<15s}:{condition}]   ;; {key} -> {human} ({label})"
        else:
            rule = f"    [{from_str:<10s}{goku_to:<15s}:{condition}]   ;; {key} -> {human} ({label})"
        rule_lines.append(rule)

    # Direct-action entries (appended after pool entries)
    if direct_rules and rule_lines:
        rule_lines.append('')
        rule_lines.append('    ;; --- direct actions ---')
    elif direct_rules:
        rule_lines.append('    ;; --- direct actions ---')
    for key, label, from_str, goku_to in sorted(direct_rules, key=lambda x: qwerty_pos(x[0])):
        gk = GOKU_NAMES.get(key, key)
        if len(gk) > 1:
            rule = f"    [{from_str:<28s}{goku_to:<15s}:{condition}]   ;; {key} (direct: {label})"
        else:
            rule = f"    [{from_str:<10s}{goku_to:<15s}:{condition}]   ;; {key} (direct: {label})"
        rule_lines.append(rule)

    header = f';; BEGIN SHORTCUT-LAYER-{n} (auto-generated from config/shortcuts.yaml)'
    footer = f';; END SHORTCUT-LAYER-{n}'

    if not rule_lines:
        return f'{header}\n{footer}'

    lines = [header]
    lines.append(f'  {{:des "{des}"')
    lines.append('   :rules')
    lines.append(f'   [{rule_lines[0].lstrip()}')
    for rl in rule_lines[1:]:
        lines.append(rl)
    lines.append('   ]}')
    lines.append(footer)
    return '\n'.join(lines)


def print_mapping(pool_map, layer_name, entries):
    """Print a human-readable mapping table for a layer."""
    _, _, des = LAYERS[layer_name]
    parsed = []
    for entry in entries:
        key, label, desc = parse_entry(entry)
        slot = pool_map.get(f"{layer_name}:{key}")
        if slot is None:
            continue
        fkey, human_mod, _ = slot_to_combo(slot)
        human = f"{human_mod}{fkey.upper()}"
        parsed.append((slot, key, human, label, desc or ''))
    parsed.sort()

    if not parsed:
        return

    print(f"\n  {des}:")
    for _, key, human, label, desc in parsed:
        desc_str = f'  ({desc})' if desc else ''
        print(f"    {key:<6s} -> {human:<24s} {label}{desc_str}")


# -- Shortcut layer direct actions --------------------------------------------

def generate_shortcut_direct_rules(shortcut_sections):
    """Generate direct-action rules for shortcut layer entries with open:/! actions.

    These are injected into the Global app shortcut rule block, which appears
    before the static layer blocks in layers.edn — so they take precedence.
    """
    lines = []
    for ln in sorted(LAYERS.keys()):
        from_mod, condition, _ = LAYERS[ln]
        entries = shortcut_sections.get(ln, [])
        for entry in entries:
            key, label, action = parse_entry(entry)
            if not action:
                continue
            gk = GOKU_NAMES.get(key, key)
            from_str = f":{from_mod}{gk}"
            to_str = direct_to(action)
            if not to_str:
                continue
            w = 28 if len(gk) > 1 else 10
            lines.append(f'    [{from_str:<{w}s}{to_str:<20s}:{condition}]   ;; {ln}+{key} → {action}')

    header = ';; BEGIN SHORTCUT-DIRECT (auto-generated from config/shortcuts.yaml)'
    footer = ';; END SHORTCUT-DIRECT'
    if not lines:
        return f'{header}\n{footer}'
    return header + '\n' + '\n'.join(lines) + '\n' + footer


# -- Workspace rules (aerospace CLI) ------------------------------------------

def generate_workspace_rules(ws_entries, ws_shift_entries):
    """Generate workspace rules: opt+key -> aerospace CLI via :aero template."""
    lines = []

    if ws_entries:
        lines.append('    ;; opt+key')
        for entry in ws_entries:
            key, label, command = parse_entry(entry)
            gk = GOKU_NAMES.get(key, key)
            from_str = f":!O{gk}"
            to_str = f'[:aero "{command}"]'
            if len(gk) > 1:
                lines.append(f'    [{from_str:<28s}{to_str}]  ;; {label}')
            else:
                lines.append(f'    [{from_str:<10s}{to_str}]  ;; {label}')

    if ws_shift_entries:
        if lines:
            lines.append('')
        lines.append('    ;; opt+shift+key')
        for entry in ws_shift_entries:
            key, label, command = parse_entry(entry)
            gk = GOKU_NAMES.get(key, key)
            from_str = f":!OS{gk}"
            to_str = f'[:aero "{command}"]'
            if len(gk) > 1:
                lines.append(f'    [{from_str:<28s}{to_str}]  ;; {label}')
            else:
                lines.append(f'    [{from_str:<10s}{to_str}]  ;; {label}')

    return '\n'.join(lines)


# -- Help text block -----------------------------------------------------------

# -- Hyper navigation (declarative from YAML) ---------------------------------

# Modifier name -> goku prefix (added before QWER)
HYPER_MODS = {
    '-':          '',
    'shift':      '!S',
    'cmd':        '!C',
    'opt':        '!O',
    'ctrl':       '!T',
    'opt+cmd':    '!OC',
    'cmd+opt':    '!OC',
    'ctrl+shift': '!TS',
    'shift+ctrl': '!TS',
    'ctrl+cmd':   '!CT',
    'cmd+shift':  '!CS',
    'opt+shift':  '!OS',
}

# Modifier name -> symbol for help overlay
HYPER_MOD_SYMBOLS = {
    '-': '', 'shift': '⇧', 'cmd': '⌘', 'opt': '⌥', 'ctrl': '⌃',
    'opt+cmd': '⌥⌘', 'cmd+opt': '⌥⌘', 'ctrl+shift': '⌃⇧',
    'shift+ctrl': '⌃⇧', 'ctrl+cmd': '⌃⌘', 'cmd+shift': '⌘⇧',
    'opt+shift': '⌥⇧',
}


def load_hyperkeys(path):
    """Load hyperkeys.yaml with full YAML parser (nested structure)."""
    if not os.path.exists(path):
        return {}, {}
    with open(path) as f:
        data = yaml.safe_load(f)
    # Also extract # comments for help labels
    labels = _extract_labels(path)
    return data or {}, labels


def _extract_labels(path):
    """Extract inline # comments as help labels keyed by (section, key, modifier)."""
    labels = {}
    section = None
    current_key = None
    section_indent = None
    key_indent = None
    with open(path) as f:
        for line in f:
            raw = line.rstrip('\n')
            stripped = raw.strip()
            if not stripped or stripped.startswith('#'):
                continue
            indent = len(raw) - len(raw.lstrip())
            m_header = re.match(r'^"?(\w[\w-]*|[^\s":#])"?:\s*$', stripped)
            if m_header:
                if section_indent is None or indent <= section_indent:
                    # Section header (e.g., "hyper:")
                    section = m_header.group(1)
                    section_indent = indent
                    key_indent = None
                    current_key = None
                elif section and (key_indent is None or indent <= key_indent):
                    # Key header (e.g., "  h:" or "    h:")
                    current_key = m_header.group(1)
                    key_indent = indent
                continue
            # Modifier line with comment (e.g., '    -: left_arrow  # ←')
            m = re.match(r'^([\w+\-]+):\s*.+?#\s*(.+)$', stripped)
            if m and section and current_key:
                mod = m.group(1)
                label = m.group(2).strip()
                labels[(section, current_key, mod)] = label
    return labels


def generate_hyper_rules(hyper_data, labels):
    """Generate Goku EDN rules from hyper YAML data."""
    hyper_keys = hyper_data.get('hyper', {})
    if not hyper_keys:
        return ''

    rule_lines = []
    for key, mappings in hyper_keys.items():
        gk = GOKU_NAMES.get(key, key)
        rule_lines.append(f'    ;; {key}')
        for mod, action in mappings.items():
            goku_prefix = HYPER_MODS.get(mod, '')
            from_str = f":{goku_prefix}QWER{gk}" if goku_prefix else f":!QWER{gk}"
            label = labels.get(('hyper', key, mod), '')
            comment = f'  ;; {label}' if label else ''

            if isinstance(action, list):
                to_str = '[' + ' '.join(f':{a}' if not a.startswith(':') else a for a in action) + ']'
            elif action.startswith('!') or action.startswith(':'):
                to_str = f':{action}' if not action.startswith(':') else action
            else:
                to_str = f':{action}'

            rule_lines.append(f'    [{from_str:<18s}{to_str}]{comment}')
        rule_lines.append('')

    # Wrap in EDN block
    header = ';; BEGIN HYPER-RULES (auto-generated from config/hyperkeys.yaml)'
    footer = ';; END HYPER-RULES'
    lines = [header]
    lines.append('  {:des "Hyper Navigation"')
    lines.append('   :rules')
    lines.append(f'   [{rule_lines[0].lstrip()}')
    for rl in rule_lines[1:]:
        lines.append(rl)
    # Add the / help trigger
    lines.append('    ;; / = show hyper help (hold to view, release to dismiss)')
    lines.append('    [:!QWERslash :show-hyper-help nil {:afterup :clear-hyper-help}]')
    lines.append('   ]}')
    lines.append(footer)
    return '\n'.join(lines)


def generate_hyper_help(hyper_data, labels):
    """Generate concise help text: one line per key, modifiers inline."""
    hyper_keys = hyper_data.get('hyper', {})
    misc_keys = hyper_data.get('misc', {})

    key_lines = []
    for key, mappings in hyper_keys.items():
        parts = []
        for mod, _ in mappings.items():
            label = labels.get(('hyper', key, mod), '')
            if not label:
                continue
            sym = HYPER_MOD_SYMBOLS.get(mod, mod)
            # Escape backslash for EDN string embedding
            display_key = '\\\\' if key == '\\' else key
            if mod == '-':
                parts.append(f'{display_key}:{label}')
            else:
                parts.append(f'{sym}{label}')
        if parts:
            key_lines.append(' '.join(parts))

    # Misc keys on one line
    misc_parts = []
    for key, mappings in misc_keys.items():
        for mod, _ in mappings.items():
            label = labels.get(('misc', key, mod), '')
            if not label:
                continue
            sym = HYPER_MOD_SYMBOLS.get(mod, mod)
            short_key = key[:3] if len(key) > 3 else key
            if mod == '-':
                misc_parts.append(f'{short_key}:{label}')
            else:
                misc_parts.append(f'{sym}{short_key}:{label}')
    if misc_parts:
        key_lines.append('  '.join(misc_parts))

    return '\\n'.join(key_lines)


def generate_help_block(app_t, ws_t, layer_help_lines, hyper_help_line):
    """Generate the full HELP-TEXT EDN block."""
    return (
        ';; BEGIN HELP-TEXT (auto-generated from config/help-text.yaml)\n'
        ' :tos {:show-app-help {:noti {:id "org.pqrs.notificaion_message_global_shortcut"\n'
        '                              :text "' + app_t + '"}}\n'
        '       :clear-app-help {:noti {:id "org.pqrs.notificaion_message_global_shortcut"\n'
        '                               :text ""}}\n'
        '       :show-ws-help {:noti {:id "org.pqrs.notificaion_message_workspace"\n'
        '                             :text "' + ws_t + '"}}\n'
        '       :clear-ws-help {:noti {:id "org.pqrs.notificaion_message_workspace"\n'
        '                              :text ""}}\n'
        + '\n'.join(layer_help_lines) + '\n'
        + hyper_help_line
        + '}\n'
        ';; END HELP-TEXT'
    )


# -- Consolidated key index (for the searchable key-search HUD) ---------------

# Layer name -> trigger glyphs shown in the search HUD
INDEX_TRIGGERS = {
    'app': '⌥R',
    'workspace': '⌥L',
    'l1': '⇧⌥R',
    'l2': '⌃⌥R',
    'l3': '⌘⌥R',
    'hyper': '⇪',
}


def generate_key_index(app_entries, ws_entries, ws_shift_entries,
                       shortcut_sections, pool_map, hyper_data, hyper_labels,
                       extras_entries=()):
    """Build the consolidated key index for the search HUD.

    Returns a list of TSV rows: layer, trigger, key, label, action.
    """
    rows = []

    def add(layer, key, label, action):
        rows.append((layer, INDEX_TRIGGERS[layer], key, label or '', action or ''))

    for entry in app_entries:
        key, label, extra = parse_entry(entry)
        disp = f'⇧{key.lower()}' if key.isalpha() and key.isupper() else key
        add('app', disp, label, extra)

    for entry in ws_entries:
        key, label, extra = parse_entry(entry)
        add('workspace', key, label, extra)
    for entry in ws_shift_entries:
        key, label, extra = parse_entry(entry)
        add('workspace', f'⇧{key}', label, extra)

    for ln in sorted(LAYERS.keys()):
        for entry in shortcut_sections.get(ln, []):
            key, label, extra = parse_entry(entry)
            action = extra
            if not action:
                slot = pool_map.get(f'{ln}:{key}')
                if slot is not None:
                    fkey, human_mod, _ = slot_to_combo(slot)
                    action = f'{human_mod}{fkey.upper()} (via KM/Alfred)'
            add(ln, key, label, action)

    for section in ('hyper', 'misc'):
        for key, mappings in (hyper_data.get(section) or {}).items():
            for mod, action in mappings.items():
                label = hyper_labels.get((section, key, mod), '')
                sym = HYPER_MOD_SYMBOLS.get(mod, mod)
                disp = f'{sym}{key}' if mod != '-' else key
                if isinstance(action, list):
                    action = ' '.join(str(a) for a in action)
                add('hyper', disp, label, str(action))

    # Hand-written base.edn bindings, declared in config/extras.yaml
    for entry in extras_entries:
        combo, label, extra = parse_entry(entry)
        rows.append(('extra', '', combo, label or '', extra or ''))

    return ['\t'.join(r) for r in rows]
