# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""Generate help text, app-launch rules, and shortcut layer rules from YAML configs.

Reads:  config/*.yaml, data/fkey-pool.json
Writes: karabiner.edn (between BEGIN/END markers), data/fkey-pool.json,
        data/keymap-index.tsv, data/fkey-index.tsv
"""
import re, sys, os

# Add parent dir to path so we can import lib/
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from lib.parser import (parse_yaml, parse_yaml_grouped, parse_entry,
                         help_text, help_text_grouped, qwerty_pos)
from lib.pool import load_pool, save_pool, POOL_SIZE
from lib.generator import (LAYERS, generate_app_rules, generate_layer,
                            generate_shortcut_direct_rules,
                            generate_workspace_rules, generate_help_block,
                            generate_hyper_rules, generate_hyper_help,
                            load_hyperkeys, print_mapping, generate_key_index,
                            generate_fkey_index, live_fkey_actions)

# -- Paths --------------------------------------------------------------------

dir_path = sys.argv[1]
config = os.path.join(dir_path, 'config')
app_path = os.path.join(config, 'app.yaml')
yaml_path = os.path.join(config, 'help-text.yaml')
shortcuts_path = os.path.join(config, 'shortcuts.yaml')
hyperkeys_path = os.path.join(config, 'hyperkeys.yaml')
extras_path = os.path.join(config, 'extras.yaml')
pool_path = os.path.join(dir_path, 'data', 'fkey-pool.json')
edn_path = os.path.join(dir_path, 'karabiner.edn')

# -- Load ---------------------------------------------------------------------

app_sections = parse_yaml(app_path)
app_grouped = parse_yaml_grouped(app_path)
ws_sections = parse_yaml(yaml_path)
shortcut_sections = parse_yaml(shortcuts_path) if os.path.exists(shortcuts_path) else {}
shortcut_grouped = parse_yaml_grouped(shortcuts_path) if os.path.exists(shortcuts_path) else {}
pool_map = load_pool(pool_path)
extras_sections = parse_yaml(extras_path) if os.path.exists(extras_path) else {}

edn = open(edn_path).read()

# -- Help text ----------------------------------------------------------------

app_groups = app_grouped.get('app', [])
app_t = help_text_grouped(app_groups) if len(app_groups) > 1 else help_text(app_sections.get('app', []))

# Workspace help text (merge unshifted + shifted by key)
ws_entries = ws_sections.get('workspace', [])
ws_shift_entries = ws_sections.get('workspace-shift', [])

ws_labels = {}
for entry in ws_entries:
    key, label, _ = parse_entry(entry)
    ws_labels[key] = label

ws_shift_labels = {}
for entry in ws_shift_entries:
    key, label, _ = parse_entry(entry)
    ws_shift_labels[key] = label

all_ws_keys = sorted(set(ws_labels) | set(ws_shift_labels), key=qwerty_pos)
ws_items = []
for key in all_ws_keys:
    base = ws_labels.get(key)
    shift = ws_shift_labels.get(key)
    if base and shift:
        ws_items.append(f"{key}:{base}/{shift}")
    elif base:
        ws_items.append(f"{key}:{base}")
    elif shift:
        ws_items.append(f"⇧{key}:{shift}")
ws_t = ', '.join(ws_items)

layer_help_lines = []
for ln in sorted(LAYERS.keys()):
    entries = shortcut_sections.get(ln, [])
    groups = shortcut_grouped.get(ln, [])
    t = help_text_grouped(groups) if len(groups) > 1 else (help_text(entries) if entries else '')
    n = ln[-1]
    layer_help_lines.append(
        f'       :show-{ln}-help {{:noti {{:id "org.pqrs.notificaion_message_layer{n}"\n'
        f'                             :text "{t}"}}}}\n'
        f'       :clear-{ln}-help {{:noti {{:id "org.pqrs.notificaion_message_layer{n}"\n'
        f'                              :text ""}}}}'
    )

# Hyper (declarative from YAML)
hyper_data, hyper_labels = load_hyperkeys(hyperkeys_path)
hyper_t = generate_hyper_help(hyper_data, hyper_labels)
hyper_help_line = (
    '       :show-hyper-help {:noti {:id "org.pqrs.notificaion_message_hyper"\n'
    '                                :text "' + hyper_t + '"}}\n'
    '       :clear-hyper-help {:noti {:id "org.pqrs.notificaion_message_hyper"\n'
    '                                 :text ""}}\n'
) if hyper_t else ''

# -- Replace EDN blocks -------------------------------------------------------

changed_blocks = []

def replace_block(edn, pattern, new_block, label):
    old_m = re.search(pattern, edn, re.DOTALL)
    if old_m and old_m.group(0) != new_block:
        changed_blocks.append(label)
    return re.sub(pattern, lambda m: new_block, edn, flags=re.DOTALL)

help_block = generate_help_block(app_t, ws_t, layer_help_lines, hyper_help_line)
edn = replace_block(edn, r';; BEGIN HELP-TEXT.*?;; END HELP-TEXT', help_block, 'help-text')

# App rules
existing = ''
m = re.search(r';; BEGIN APP-RULES.*?;; END APP-RULES', edn, re.DOTALL)
if m:
    existing = m.group(0)

rules, warnings = generate_app_rules(app_sections.get('app', []), existing)
rules_block = (
    ';; BEGIN APP-RULES (auto-generated from config/app.yaml)\n'
    + rules + '\n'
    ';; END APP-RULES'
)
edn = replace_block(edn, r';; BEGIN APP-RULES.*?;; END APP-RULES', rules_block, 'app-rules')

# Shortcut direct actions (override static layer F-key rules in karabiner.edn)
direct_block = generate_shortcut_direct_rules(shortcut_sections)
edn = replace_block(edn, r';; BEGIN SHORTCUT-DIRECT.*?;; END SHORTCUT-DIRECT', direct_block, 'shortcut-direct')

# Shortcut layers — inject generated block if BEGIN/END markers exist in EDN
for ln in sorted(LAYERS.keys()):
    entries = shortcut_sections.get(ln, [])
    block = generate_layer(pool_map, ln, entries)
    n = ln[-1]
    edn = replace_block(edn, f';; BEGIN SHORTCUT-LAYER-{n}.*?;; END SHORTCUT-LAYER-{n}', block, f'shortcut-layer-{n}')

# Workspace rules
ws_rules = generate_workspace_rules(ws_entries, ws_shift_entries)
ws_block_header = ';; BEGIN WORKSPACE-RULES (auto-generated from config/help-text.yaml)'
ws_block_footer = ';; END WORKSPACE-RULES'

if ws_rules:
    ws_block = (
        ws_block_header + '\n'
        '  {:des "Workspace shortcuts (Left Option)"\n'
        '   :rules\n'
        '   [' + ws_rules.lstrip() + '\n'
        '   ]}\n'
        + ws_block_footer
    )
else:
    ws_block = ws_block_header + '\n' + ws_block_footer

edn = replace_block(edn, r';; BEGIN WORKSPACE-RULES.*?;; END WORKSPACE-RULES', ws_block, 'workspace-rules')

# Hyper rules
hyper_block = generate_hyper_rules(hyper_data, hyper_labels)
if hyper_block:
    edn = replace_block(edn, r';; BEGIN HYPER-RULES.*?;; END HYPER-RULES', hyper_block, 'hyper-rules')

# -- Write --------------------------------------------------------------------

open(edn_path, 'w').write(edn)
save_pool(pool_path, pool_map)

# Consolidated key index for the search HUD (ctrl+shift+/)
# F-key index for the F-keys tab of the search HUD, read from the rules just written
fkey_rows = generate_fkey_index(edn, shortcut_sections)
fkey_index_path = os.path.join(dir_path, 'data', 'fkey-index.tsv')
open(fkey_index_path, 'w').write('\n'.join(fkey_rows) + '\n')

index_rows = generate_key_index(
    app_sections.get('app', []), ws_entries, ws_shift_entries,
    shortcut_sections, live_fkey_actions(fkey_rows), hyper_data, hyper_labels,
    extras_sections.get('extras', []))
index_path = os.path.join(dir_path, 'data', 'keymap-index.tsv')
open(index_path, 'w').write('\n'.join(index_rows) + '\n')

# -- Summary ------------------------------------------------------------------

if changed_blocks:
    print(f"  updated: {', '.join(changed_blocks)}")
else:
    print("  (no changes)")

if warnings:
    print("\n\033[33m! YAML <-> EDN out of sync:\033[0m")
    for w in warnings:
        print(w)
    print()

print(f"  app: {app_t}")
print(f"  rules: {len(app_sections.get('app', []))} active")
print(f"  pool: {len(pool_map)}/{POOL_SIZE} slots used")
print(f"  ws:  {ws_t}")

for ln in sorted(LAYERS.keys()):
    entries = shortcut_sections.get(ln, [])
    t = help_text(entries) if entries else '(empty)'
    print(f"  {ln}:  {t}")
    print_mapping(pool_map, ln, entries)
