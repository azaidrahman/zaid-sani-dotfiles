#!/usr/bin/env bash
# Unit tests for the quota path and the provider seam in claude-usage.sh
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/executable_claude-usage.sh"
fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

# Sourcing the script must NOT run the popup (no stdout, exit 0).
out=$( source "$SCRIPT" 2>/dev/null; echo "SOURCED_OK" )
check "source is side-effect free" "SOURCED_OK" "${out##*$'\n'}"

source "$SCRIPT" 2>/dev/null

# A fixed clock. Every countdown and pace number below is derived from it.
# 2026-06-22 12:00:00 UTC
export FAKE_NOW=1782129600
SESSION_RESET=$(( FAKE_NOW + 7200 ))    # 2h from now, 5h window -> 60% elapsed
export SRC_PANE=''

# --- the pure clock helpers ------------------------------------------------
check "elapsed_pct of a 5h window with 2h left"  "60" "$(elapsed_pct "$SESSION_RESET" 18000)"
check "elapsed_pct clamps a reset in the past"  "100" "$(elapsed_pct "$(( FAKE_NOW - 99 ))" 18000)"
check "elapsed_pct clamps a reset beyond the window" "0" \
  "$(elapsed_pct "$(( FAKE_NOW + 99999 ))" 18000)"
check "elapsed_pct is empty with no epoch"       ""   "$(elapsed_pct - 18000)"
check "elapsed_pct is empty with no window"      ""   "$(elapsed_pct "$SESSION_RESET" -)"

check "countdown under a day"      "in 2h 0m"  "$(to_countdown "$SESSION_RESET")"
check "countdown over a day"       "in 2d 3h"  "$(to_countdown "$(( FAKE_NOW + 183600 ))")"
check "countdown under an hour"    "in 30m"    "$(to_countdown "$(( FAKE_NOW + 1800 ))")"
check "countdown of a due window"  "now"       "$(to_countdown "$(( FAKE_NOW - 1 ))")"
check "countdown is empty with no epoch" ""    "$(to_countdown -)"

# The clock string is local time, so assert the shape, not one fixed hour.
check "clock reads H:MMPM DDD DD-MON" "1" \
  "$(to_clock "$SESSION_RESET" | grep -cE '^[0-9]{1,2}:[0-9]{2}(AM|PM) [A-Z]{3} [0-9]{2}-[A-Z]{3}$')"

check "window_len of a session label" "18000"  "$(window_len 'Current session')"
check "window_len of a weekly label"  "604800" "$(window_len 'Current week (all models)')"
check "window_len of a strange label" ""       "$(window_len 'Tokens per fortnight')"
check "window_noun falls back"        "window" "$(window_noun 'Tokens per fortnight')"

# --- date dialects ---------------------------------------------------------
# Assert the month, day and time. The year depends on the day the test runs.
e=$(epoch_from_ampm 'Jun 22 at 4pm (Asia/Kuala_Lumpur)')
check "epoch_from_ampm reads a bare hour" "Jun 22 04:00PM" "$(date -r "$e" '+%b %d %I:%M%p')"
e=$(epoch_from_ampm 'Dec 01 at 11:30am (Asia/Kuala_Lumpur)')
check "epoch_from_ampm reads hour and minute" "Dec 01 11:30AM" "$(date -r "$e" '+%b %d %I:%M%p')"
check "epoch_from_ampm is empty on nonsense" "" "$(epoch_from_ampm 'sometime soon')"

e=$(epoch_from_clock '23:45')
check "epoch_from_clock reads HH:MM" "23:45" "$(date -r "$e" '+%H:%M')"
check "epoch_from_clock is in the future" "1" "$(( e > FAKE_NOW ))"
check "epoch_from_iso reads a UTC instant" "1782129600" \
  "$(epoch_from_iso '2026-06-22T12:00:00Z')"

# --- the claude provider : raw CLI text -> canonical blob ------------------
PROVIDER=claude
FIXTURE="Current session: 12% used · resets Jun 22 at 4pm (Asia/Kuala_Lumpur)
Current week (all models): 78% used · resets Jun 26 at 9am (Asia/Kuala_Lumpur)
Current week (Fable): 47% used"

blob=$(printf '%s\n' "$FIXTURE" | p_claude_normalize)
field() { printf '%s\n' "$blob" | sed -n "$1p" | cut -f"$2"; }

check "normalize keeps every metered row" "2" "$(printf '%s\n' "$blob" | grep -c '^QUOTA')"
check "normalize reads the label"        "Current session" "$(field 1 2)"
check "normalize reads the percent"      "12"              "$(field 1 3)"
check "normalize resolves the reset to epoch" "Jun 22 04:00PM" \
  "$(date -r "$(field 1 4)" '+%b %d %I:%M%p')"
check "normalize reads the session window" "18000"  "$(field 1 5)"
check "normalize reads the weekly window"  "604800" "$(field 2 5)"
check "normalize keeps a parenthesized label" "Current week (all models)" "$(field 2 2)"
check "an unmetered row draws no bar" "0" "$(printf '%s\n' "$blob" | grep -c '^QUOTA.*Fable')"

# A percentage with no reset clause is not a limit window, so it becomes a NOTE.
one=$(printf 'Current week (Fable): 5%% used\n' | p_claude_normalize)
check "a row with no reset becomes a NOTE" "1" "$(printf '%s\n' "$one" | grep -c '^NOTE')"

# Anything the format does not cover becomes a NOTE, never a silent drop.
noisy=$(printf 'Please run /login first\n\nnot a metric line\n' | p_claude_normalize)
check "unparsed text becomes NOTE rows" "2" "$(printf '%s\n' "$noisy" | grep -c '^NOTE')"
check "blank lines are dropped"         "0" "$(printf '%s\n' "$noisy" | grep -c '^NOTE'$'\t''$')"

# --- the quota view -------------------------------------------------------
QUOTA_BLOB="QUOTA${TAB}Current session${TAB}12${TAB}${SESSION_RESET}${TAB}18000"
out=$(COLUMNS=149 TERM=dumb render_quota "$QUOTA_BLOB" "" | strip)

check "the bar row shows the label and percent" "1" \
  "$(printf '%s\n' "$out" | grep -c 'Current session .* 12%')"
check "the bar row shows the countdown and clock" "1" \
  "$(printf '%s\n' "$out" | grep -cE 'resets in 2h 0m \([0-9]{1,2}:[0-9]{2}(AM|PM) [A-Z]{3} [0-9]{2}-[A-Z]{3}\)')"
check "the pace delta is behind the clock (12-60)" "1" \
  "$(printf '%s\n' "$out" | grep -c '▼-48')"
check "the note names the window and the elapsed share" "1" \
  "$(printf '%s\n' "$out" | grep -c '↑ 60% of the session elapsed')"
# The tail is the part of the row that ROW_FIXED_W budgets 37 columns for. It
# is pure ASCII, so its byte count is its column count. The bar itself is not
# measurable this way: one block character is three bytes.
tail_len() { printf '%s\n' "$1" | sed -n 's/.*\( resets .*\)$/\1/p' | awk '{print length($0)}'; }
check "the reset tail fits the 37-column budget" "37" "$(tail_len "$out")"

far=$(COLUMNS=149 TERM=dumb render_quota \
  "QUOTA${TAB}Current week (all models)${TAB}78${TAB}$(( FAKE_NOW + 183600 ))${TAB}604800" "" | strip)
check "a multi-day reset tail also fits" "1" \
  "$(( $(tail_len "$far") <= 37 ))"

# A blob of only NOTEs must still tell the reader what happened.
out=$(render_quota "NOTE${TAB}Please run /login first" "" | strip)
check "a note-only blob prints the note" "1" \
  "$(printf '%s\n' "$out" | grep -c 'Please run /login first')"

# A NOTE next to real bars is chatter, so it stays hidden.
out=$(render_quota "$QUOTA_BLOB"$'\n'"NOTE${TAB}chatter" "" | strip)
check "a note beside a bar stays hidden" "0" "$(printf '%s\n' "$out" | grep -c 'chatter')"

check "the cached note reaches the header" "1" \
  "$(render_quota "$QUOTA_BLOB" "(cached — refreshing…)" | strip | grep -c 'cached')"

# --- the provider seam ----------------------------------------------------
# A provider that this script has never heard of. It declares a fetch and a
# normalize only, so it also proves the default blob hook.
p_fake_view()  { printf 'quota'; }
p_fake_title() { printf 'Fake usage'; }
p_fake_tag()   { printf 'Fake Co'; }
p_fake_fetch() { printf 'weekly quota: 90 pct, resets 23:45\n'; }
p_fake_normalize() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^(.+):\ ([0-9]+)\ pct,\ resets\ ([0-9:]+)$ ]]; then
      printf 'QUOTA\t%s\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
        "$(epoch_from_clock "${BASH_REMATCH[3]}")" "$(window_len "${BASH_REMATCH[1]}")"
    fi
  done
}

PROVIDER=fake
check "a provider without p_<id>_blob falls back to fetch|normalize" "1" \
  "$(provider_hook blob | grep -c '^QUOTA'$'\t''weekly quota'$'\t''90')"
check "the fake provider picks the quota view" "quota" "$(provider_hook view)"

TMPDIR=$(mktemp -d) view_main </dev/null >/dev/null 2>&1
check "view_main exits clean for a provider it has never seen" "0" "$?"

tmp=$(mktemp -d)
out=$(TMPDIR="$tmp" bash -c "source '$SCRIPT'
  $(declare -f p_fake_view p_fake_title p_fake_tag p_fake_fetch p_fake_normalize)
  PROVIDER=fake FAKE_NOW=$FAKE_NOW view_main </dev/null" | strip)
# Twice: once on the "Loading…" draw, once on the draw of the fresh blob.
check "the fake provider draws its own title" "2" "$(printf '%s\n' "$out" | grep -c 'Fake usage')"
check "the fake provider draws a bar"         "1" "$(printf '%s\n' "$out" | grep -c 'weekly quota .* 90%')"
check "view_main writes a per-provider cache" "1" \
  "$(grep -c '^QUOTA' "$tmp/claude-usage.fake.cache" 2>/dev/null)"
check "the cache holds an epoch, not a countdown" "1" \
  "$(cut -f4 "$tmp/claude-usage.fake.cache" | grep -cE '^[0-9]{10}$')"
rm -rf "$tmp"

# --- provider resolution ---------------------------------------------------
# The provider comes from the process the pane runs now, so every case below
# feeds a fake process line to the classifier.
PROXY_ENV='ANTHROPIC_BASE_URL=http://onyx:4000 ANTHROPIC_AUTH_TOKEN=sk-x'

check "a plain claude is the subscription" "claude" \
  "$(classify_process 'claude --allow-dangerously-skip-permissions')"
check "a claude pointed at the proxy is litellm" "litellm" \
  "$(classify_process "claude --resume $PROXY_ENV")"
check "an inherited key alone is not the proxy" "claude" \
  "$(classify_process 'claude LITELLM_API_KEY=sk-x')"
check "the pi bundle is the combined view" "agents" \
  "$(classify_process '/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js')"
check "a bare pi is the combined view" "agents" "$(classify_process '/opt/homebrew/bin/pi --resume')"
# Both harnesses switch model inside a session, so the model on the command
# line must not change the answer: every pi and omp pane shows both budgets.
check "omp on a litellm model is the combined view" "agents" \
  "$(classify_process 'omp --model litellm/gemini-3.5-flash')"
check "omp on its own model is also the combined view" "agents" \
  "$(classify_process 'omp --model gpt-5.6')"
check "a codex pane is the codex subscription" "codex" \
  "$(classify_process '/opt/homebrew/bin/codex --resume')"
# The toggle covers pi and omp only. A codex pane spends the subscription
# whatever pi is allowed to do, so it keeps its own view.
check "the toggle leaves a codex pane alone" "codex" \
  "$(CODEX_IN_AGENTS=0 classify_process 'codex')"
check "a shell is not an agent"  "" "$(classify_process '-zsh')"
check "a helper is not an agent" "" "$(classify_process 'bash /Users/x/.tmux/scripts/claude-usage.sh %9')"

# A fake process table: 100 -> 101 -> 102 -> 103, plus an unrelated branch.
FAKE_TABLE='  100     1 -zsh
  101   100 chezmoi cd
  102   101 /bin/zsh
  103   102 claude --resume
  200     1 /bin/zsh
  201   200 pi'
check "the tree starts at its own root" "100" \
  "$(printf '%s\n' "$FAKE_TABLE" | process_tree_pids 100 | head -1)"
check "the tree reaches a grandchild"    "103" \
  "$(printf '%s\n' "$FAKE_TABLE" | process_tree_pids 100 | tail -1)"
check "the tree skips another branch"    "0" \
  "$(printf '%s\n' "$FAKE_TABLE" | process_tree_pids 100 | grep -c '^20')"

# resolve_provider through the three seams, with no tmux and no real ps.
fake_resolve() { # <root-pid> <stale-marker>
  ps_table()      { printf '%s\n' "$FAKE_TABLE"; }
  pane_root_pid() { printf '%s' "$1"; }
  proc_line()     { printf '%s\n' "$FAKE_TABLE" | awk -v p="$1" '$1==p{$1="";$2="";print}'; }
  SRC_PANE=$1 resolve_provider
}
check "a nested claude resolves to the subscription" "claude" "$(fake_resolve 100)"
check "a pi pane resolves to the combined view"      "agents" "$(fake_resolve 200)"

# The escape hatch: one flag drops pi and omp back to the cost view they drew
# before the Codex section existed, for the day the ChatGPT subscription stops
# allowing the Codex models inside pi.
check "the toggle sends a pi pane back to litellm" "litellm" \
  "$(CODEX_IN_AGENTS=0 fake_resolve 200)"
check "the toggle leaves a claude pane alone"      "claude" \
  "$(CODEX_IN_AGENTS=0 fake_resolve 100)"
check "the toggle defaults to on" "1" "$CODEX_IN_AGENTS"

# The regression this replaced: `pi` set a per-pane tmux marker and cleared it
# on exit, but Ctrl-C aborts the zsh function before the cleanup line. The
# marker outlived the agent, so a later plain claude in that pane drew the
# cost view. Nothing may read a marker any more.
check "no marker is read from the pane" "0" \
  "$(grep -c '@claude_provider' "$SCRIPT")"

SRC_PANE=''
check "a pane with no agent means the claude provider" "claude" "$(resolve_provider)"

# --- the codex provider : backend JSON -> canonical blob -------------------
# The real shape of a GET on the usage endpoint, trimmed to what is read.
CODEX_JSON='{"plan_type":"team","rate_limit":{"allowed":true,
  "primary_window":  {"used_percent":22.7,"limit_window_seconds":18000,"reset_at":'"$(( FAKE_NOW + 7200 ))"'},
  "secondary_window":{"used_percent":9,"limit_window_seconds":604800,"reset_at":'"$(( FAKE_NOW + 183600 ))"'}}}'

blob=$(printf '%s' "$CODEX_JSON" | p_codex_normalize)
cfield() { printf '%s\n' "$blob" | sed -n "$1p" | cut -f"$2"; }

check "codex normalize gives one row per window" "2" \
  "$(printf '%s\n' "$blob" | grep -c '^QUOTA')"
check "codex normalize labels the session window" "Codex session" "$(cfield 1 2)"
check "codex normalize labels the weekly window"  "Codex week"    "$(cfield 2 2)"
check "codex normalize floors a fractional percent" "22" "$(cfield 1 3)"
check "codex normalize keeps reset_at as an epoch" "$(( FAKE_NOW + 7200 ))" "$(cfield 1 4)"
check "codex normalize takes the window length from the payload" "18000" "$(cfield 1 5)"
check "codex normalize reads the weekly window length" "604800" "$(cfield 2 5)"

# The window length arrives in the payload, so a label the shared helper does
# not know still gets a pace marker.
check "the codex labels need no window_len lookup" "1" \
  "$(( $(window_len 'Codex session') == 18000 ))"

# A dead endpoint, an expired token or an empty body must say so, never draw
# an empty popup that looks like "no usage".
for bad in '' 'not json' '{}' '{"rate_limit":null}'; do
  check "codex normalize notes a bad payload: ${bad:-<empty>}" "1" \
    "$(printf '%s' "$bad" | p_codex_normalize | grep -c '^NOTE')"
done

check "codex plan falls back when the auth file is missing" "subscription" \
  "$(CODEX_AUTH=/nonexistent/auth.json codex_plan)"

# The token must never be fetched for the tag: the popup draws the tag from
# the cache before any network call returns.
check "the codex tag needs no network call" "1" \
  "$(CODEX_AUTH=/nonexistent/auth.json PROVIDER=codex bash -c "
      source '$SCRIPT'; CODEX_AUTH=/nonexistent/auth.json; p_codex_tag" | strip | grep -c 'ChatGPT')"

# --- the combined view -----------------------------------------------------
# One blob carrying both record kinds, which is what p_agents_blob builds.
BOTH_BLOB="QUOTA${TAB}Codex session${TAB}22${TAB}${SESSION_RESET}${TAB}18000
MODEL${TAB}4.12${TAB}gemini-3.5-flash
TOTAL${TAB}7d${TAB}6.00"

PROVIDER=agents
check "the agents provider picks the combined view" "both" "$(provider_hook view)"

out=$(COLUMNS=149 TERM=dumb render_both "$BOTH_BLOB" "" | strip)
check "the combined view draws the quota bar" "1" \
  "$(printf '%s\n' "$out" | grep -c 'Codex session .* 22%')"
check "the combined view draws the model bar" "1" \
  "$(printf '%s\n' "$out" | grep -c 'gemini-3.5-flash .* \$4.12')"
check "the combined view draws the totals" "1" \
  "$(printf '%s\n' "$out" | grep -c 'Total · last 7 days .* \$6.00')"
check "the combined view draws one header only" "1" \
  "$(printf '%s\n' "$out" | grep -c '^  provider:')"
check "the quota section comes before the cost section" "1" \
  "$(( $(printf '%s\n' "$out" | grep -n 'Codex session' | cut -d: -f1) \
     < $(printf '%s\n' "$out" | grep -n 'gemini-3.5-flash' | cut -d: -f1) ))"

# A failure of one provider must not print under the other section. The blob
# holds one NOTE and the model bars of the section that did work.
half="NOTE${TAB}codex usage unavailable"$'\n'"MODEL${TAB}4.12${TAB}gemini-3.5-flash"
out=$(COLUMNS=149 TERM=dumb render_both "$half" "" | strip)
check "the note prints one time, under its own section only" "1" \
  "$(printf '%s\n' "$out" | grep -c 'codex usage unavailable')"
check "the working section still draws" "1" \
  "$(printf '%s\n' "$out" | grep -c 'gemini-3.5-flash')"

# The refactor must not have changed either view on its own.
check "the quota view alone draws one header" "1" \
  "$(PROVIDER=claude render_quota "$QUOTA_BLOB" "" | strip | grep -c '^  provider:')"
check "the cost view alone draws one header"  "1" \
  "$(PROVIDER=litellm render_cost "$BOTH_BLOB" "" | strip | grep -c '^  provider:')"

check "the header draws the context section above the view" "1" \
  "$(CONTEXT_TEXT='  gcloud   ctx-marker' PROVIDER=claude render_quota "$QUOTA_BLOB" "" \
     | strip | grep -c 'ctx-marker')"

# --- popup sizing ----------------------------------------------------------

tmp=$(mktemp -d)
printf 'QUOTA\ta\t1\t-\t-\nQUOTA\tb\t2\t-\t-\n' > "$tmp/claude-usage.claude.cache"
check "rows come from the cache of that provider" "2" \
  "$(TMPDIR="$tmp" rows_in_cache claude QUOTA 3)"
check "an empty cache uses the fallback count"    "6" \
  "$(TMPDIR="$tmp" rows_in_cache litellm MODEL 6)"
rm -rf "$tmp"

check "the quota popup fits a full-cap row" "149" "$USAGE_POPUP_W"
check "the popup width is derived, not fixed" "149" "$(( ROW_FIXED_W + BAR_CAP + 2 ))"

# The combined popup is as wide as a quota row and as tall as both sections
# and the context section: 2 quota rows * 2 + 3 models + 17 + 10.
tmp=$(mktemp -d)
printf 'QUOTA\ta\t1\t-\t-\nQUOTA\tb\t2\t-\t-\nMODEL\t1\tm1\nMODEL\t2\tm2\nMODEL\t3\tm3\n' \
  > "$tmp/claude-usage.agents.cache"
check "the combined popup sizes from both record kinds" "149x34" \
  "$(resolve_provider() { printf agents; }; TMPDIR="$tmp" size_for '%0')"
rm -rf "$tmp"

# tmux runs the popup command with a shell. A directory name with quotes or
# $(...) must reach the script as one plain argument.
tmp=$(mktemp -d)
evil="$tmp/a\"b \$(touch $tmp/ran)"
cmd=$(tmux() { if [ "$1" = display-popup ]; then for last; do :; done; printf '%s' "$last"; fi; }
      TMPDIR="$tmp" popup_main '%1' "$evil")
eval "set -- $cmd"
check "the popup command keeps the directory as one argument" "$evil" "${3:-}"
rm -rf "$tmp"

exit $fail
