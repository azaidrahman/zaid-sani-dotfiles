#!/usr/bin/env bash
# Unit tests for the LiteLLM per-session cost helper (statusline-cost.sh).
set -u
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/statusline-cost.sh"
fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Sourcing must be side-effect free (defines functions, prints nothing).
out=$( source "$LIB" 2>/dev/null; echo "SOURCED_OK" )
check "source is side-effect free" "SOURCED_OK" "${out##*$'\n'}"

source "$LIB" 2>/dev/null

# --- tag_total_spend: extract .metadata.total_spend, rounded 2dp ------------
# Shape mirrors a real /tag/daily/activity response (filtered server-side to one
# tag), so the client only reads the aggregate.
ACT='{"results":[{"date":"2026-06-25","metrics":{"spend":0.42}}],"metadata":{"total_spend":0.42}}'
check "extracts total_spend"        "0.42" "$(tag_total_spend "$ACT")"
check "rounds to 2dp"               "0.07" "$(tag_total_spend '{"metadata":{"total_spend":0.067}}')"
check "sub-cent rounds to 0"        "0"    "$(tag_total_spend '{"metadata":{"total_spend":0.000048}}')"
check "empty results -> 0"          "0"    "$(tag_total_spend '{"results":[],"metadata":{"total_spend":0}}')"
check "missing metadata -> 0"       "0"    "$(tag_total_spend '{}')"
check "empty json -> 0"             "0"    "$(tag_total_spend '')"
check "malformed json -> 0"         "0"    "$(tag_total_spend 'not json')"

# --- cache + refresh -------------------------------------------------------
TMPDIR_T=$(mktemp -d)
CACHE="$TMPDIR_T/claude-cc-cost.sess-AAA"

# refresh writes the per-tag total, via the (stubbed) fetch.
_litellm_fetch_tag_activity() { printf '%s' "$ACT"; }   # stub: return the fixture
_litellm_cost_refresh "http://x" "k" "sess-AAA" "$CACHE"
check "refresh writes tag total" "0.42" "$(cat "$CACHE" 2>/dev/null)"
check "refresh clears its lock"  "1"    "$([ -d "$CACHE.lock" ]; echo $?)"

# a held lock blocks a concurrent refresh (no overwrite).
printf '5.55' > "$CACHE"; mkdir "$CACHE.lock"
_litellm_cost_refresh "http://x" "k" "sess-AAA" "$CACHE"
check "held lock blocks refresh" "5.55" "$(cat "$CACHE")"
rmdir "$CACHE.lock"

# a stale lock (older than 60s) is broken, refresh proceeds.
printf '5.55' > "$CACHE"; mkdir "$CACHE.lock"
touch -t "$(date -v-2M +%Y%m%d%H%M 2>/dev/null || date -d '2 minutes ago' +%Y%m%d%H%M)" "$CACHE.lock"
_litellm_cost_refresh "http://x" "k" "sess-AAA" "$CACHE"
check "stale lock broken, refresh runs" "0.42" "$(cat "$CACHE")"

# unreachable proxy (empty fetch) leaves the old cache untouched.
_litellm_fetch_tag_activity() { printf ''; }
printf '7.77' > "$CACHE"
_litellm_cost_refresh "http://x" "k" "sess-AAA" "$CACHE"
check "empty fetch keeps old cache" "7.77" "$(cat "$CACHE")"

# litellm_session_cost echoes a fresh cache and does NOT refresh.
_litellm_fetch_tag_activity() { printf '%s' "$ACT"; }   # would write 0.42 if it ran
printf '1.23' > "$CACHE"
check "fresh cache echoed as-is" "1.23" \
  "$(TMPDIR="$TMPDIR_T" litellm_session_cost http://x k sess-AAA)"

# missing cache -> empty output (blank until first refresh lands).
rm -f "$CACHE"
check "missing cache -> empty" "" \
  "$(TMPDIR="$TMPDIR_T" litellm_session_cost http://x k sess-AAA 2>/dev/null; true)"
rm -rf "$TMPDIR_T"

# --- integration: statusline renders the ledger cost on the LiteLLM path ----
STATUS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/executable_statusline.sh"
TMPDIR_I=$(mktemp -d)
printf '1.23' > "$TMPDIR_I/claude-cc-cost.test-sess"     # fresh cache, no refresh
strip() { sed $'s/\033\\[[0-9;]*m//g'; }
# COLUMNS wide enough that right-aligned wt/br never folds the cost segment inline
render=$(printf '{"session_id":"test-sess","model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":10}}' \
  | TMPDIR="$TMPDIR_I" ANTHROPIC_BASE_URL="http://x" ANTHROPIC_AUTH_TOKEN="k" COLUMNS=200 \
    bash "$STATUS" | strip)
check "statusline shows ledger cost" "1" "$(printf '%s' "$render" | grep -c '\$1\.23')"
rm -rf "$TMPDIR_I"

# A session id with a path step must not read a file outside TMPDIR. The file
# "target" holds a cost, and the id reaches it only through "d/../../target".
TMPDIR_T=$(mktemp -d)
mkdir "$TMPDIR_T/tmp" "$TMPDIR_T/tmp/claude-cc-cost.d"
printf '5.00' > "$TMPDIR_T/target"
check "session id with a path step reads nothing" "" \
  "$(TMPDIR="$TMPDIR_T/tmp" litellm_session_cost http://x k 'd/../../target' 2>/dev/null; true)"
rm -rf "$TMPDIR_T"

# --- integration: the workbench pill is built here, from git ----------------
# A fake git is a linked worktree whose top level holds an escape, a bell, and
# the UTF-8 form of the C1 character CSI (\xc2\x9b). The status line runs in the
# C locale, where [[:cntrl:]] does not match the C1 character.
TMPDIR_N=$(mktemp -d)
mkdir "$TMPDIR_N/bin"
cat > "$TMPDIR_N/bin/git" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" --show-toplevel "*) printf '/w/a\033]0;x\007b\xc2\x9b[2Jc\n' ;;
  *" --git-common-dir "*) printf '/r/.git\n' ;;
  *" --git-dir "*) printf '/r/.git/worktrees/a\n' ;;
  *" --abbrev-ref "*) printf 'feat\n' ;;
  *) printf '## feat...origin/feat [ahead 2]\n M b\n' ;;
esac
FAKE
chmod +x "$TMPDIR_N/bin/git"
render=$(printf '{"session_id":"test-names","workspace":{"current_dir":"/w/a"}}' \
  | PATH="$TMPDIR_N/bin:$PATH" LC_ALL=C COLUMNS=200 bash "$STATUS" | strip)
check "pill names the repository and worktree" "1" "$(printf '%s' "$render" | grep -c 'r/a\]0;xb\[2Jc 2 unpushed · 0/1 staged')"
check "pill drops control characters"          "0" "$(printf '%s' "$render" | grep -c $'[\001-\037\177]')"
check "pill drops the C1 character CSI"        "0" "$(printf '%s' "$render" | LC_ALL=C grep -c $'\xc2\x9b')"
rm -rf "$TMPDIR_N"

# Outside git, the pill shows the name of the directory.
render=$(printf '{"session_id":"test-nogit","workspace":{"current_dir":"/w/proj-nogit"}}' \
  | COLUMNS=200 bash "$STATUS" | strip)
check "pill outside git shows the directory" "1" "$(printf '%s' "$render" | grep -c 'proj-nogit no git')"

# --- integration: a JSON text value with control characters stays text ------
# The model name holds an OSC title sequence, a \x01 field separator, and a C1
# character. The status line prints the name as text: no OSC sequence reaches
# the output, the name keeps its letters, and the fields after it keep their place.
raw=$(printf '%s' '{"model":{"display_name":"\u001b]0;pwned\u0007Foo\u0001Bar\u009b"},"context_window":{"used_percentage":10}}' \
  | COLUMNS=200 bash "$STATUS")
check "model name sends no OSC sequence"   "0" "$(printf '%s' "$raw" | grep -c $'\033]0;')"
check "model name keeps its letters"        "1" "$(printf '%s' "$raw" | grep -c 'pwnedFooBar')"
check "fields after the name keep their place" "1" "$(printf '%s' "$raw" | strip | grep -c '10%')"

exit $fail
