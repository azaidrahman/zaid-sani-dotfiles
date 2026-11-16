#!/usr/bin/env bash
# Unit tests for the notification tiers in notify-tmux.sh.
#
# The hook dispatches on $1 and exits, so it cannot be sourced — these tests run it
# as a subprocess with a stub `terminal-notifier` first on PATH and assert the exact
# argv it builds. Nothing is ever delivered and no sound is played, which is the
# point: the tier/sound/DnD matrix is verifiable without making noise.
#
# Isolation: TMUX/TMUX_PANE are unset so the hook cannot mutate live tmux window
# state, and HOME points at a temp dir so alert_tmux finds no log-alert.sh to run.
set -u

# Resolve the hook from either tree: the chezmoi source keeps the `executable_` prefix,
# the applied target does not. Without both names this only runs from the source dir.
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for cand in "$BASE/hooks/executable_notify-tmux.sh" "$BASE/hooks/notify-tmux.sh"; do
  [ -f "$cand" ] && { HOOK="$cand"; break; }
done
HOOK="${HOOK:-$BASE/hooks/notify-tmux.sh}"
fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

[ -f "$HOOK" ] || { echo "FAIL - hook not found at $HOOK"; exit 1; }
bash -n "$HOOK" || { echo "FAIL - hook has a syntax error"; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
STUB="$TMPD/bin"; ARGS="$TMPD/argv"; PLAYED="$TMPD/played"
mkdir -p "$STUB" "$TMPD/home/Library/DoNotDisturb/DB"

# afplay stub: records which sound file play_sound tried to play. The attn tier plays
# its cue this way rather than via -sound, because Focus does not gate afplay.
cat > "$STUB/afplay" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$PLAYED"
EOF
chmod +x "$STUB/afplay"

# Write a fake Focus assertion into the isolated HOME so the Focus-suppression logic
# is testable without touching the real one. focus_off clears it.
focus_on()  { cat > "$TMPD/home/Library/DoNotDisturb/DB/Assertions.json" <<EOF
{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"$1"}}]}]}
EOF
}
focus_off() { printf '%s' '{"data":[{}]}' > "$TMPD/home/Library/DoNotDisturb/DB/Assertions.json"; }
focus_off

# Stub writes one arg per line, so flag lookup needs no quoting-aware parsing.
cat > "$STUB/terminal-notifier" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$ARGS"
EOF
chmod +x "$STUB/terminal-notifier"

# A tmux stub that always fails. Unsetting \$TMUX is NOT enough to isolate: the tmux
# CLI happily connects to the default server anyway, so tq() would resolve to the
# attached client's *active* window — making assertions depend on whatever window the
# user is looking at, and letting window_status() write @claude_state into it. Forcing
# every tmux call to fail pins the no-tmux code path and guarantees zero side effects.
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUB/tmux"

# run <event> <stdin-json> [VAR=val ...] — capture the argv of one notify() call.
# Every CLAUDE_* variable in the caller's environment, as `env -u` arguments.
#
# The real settings live in ~/.config/zsh/exports.zsh, so a developer shell exports
# CLAUDE_NOTIFY_LOCAL=0 and friends. Without this, those leak into the hook and the
# suite asserts against the developer's preferences instead of the hook's defaults —
# it passed on a machine that had not applied the exports yet and failed on one that
# had. Strip the whole prefix rather than a hand-written list, so a variable added
# later cannot reintroduce the same failure.
CLEAN_ENV=()
while IFS='=' read -r k _; do
  case "$k" in CLAUDE_*) CLEAN_ENV+=(-u "$k") ;; esac
done < <(env)

run() {
  local event="$1" json="$2"; shift 2
  : > "$ARGS"; : > "$PLAYED"
  printf '%s' "$json" | env -u TMUX -u TMUX_PANE \
    ${CLEAN_ENV[@]+"${CLEAN_ENV[@]}"} \
    HOME="$TMPD/home" \
    PATH="$STUB:$(dirname "$(command -v bash)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@" bash "$HOOK" "$event" >/dev/null 2>&1
  # play_sound backgrounds afplay, so give the detached child a moment to record.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$PLAYED" ] && break; sleep 0.1; done
}

val()  { awk -v f="$1" '$0==f{getline; print; exit}' "$ARGS"; }        # value after a flag
has()  { grep -qxF -- "$1" "$ARGS" && echo yes || echo no; }           # flag present?
calls(){ grep -cxF -- '-title' "$ARGS"; }                              # notify() invocations
# Basename of the sound afplay was handed, or "(none)".
played(){ [ -s "$PLAYED" ] && basename "$(head -n1 "$PLAYED")" .aiff || echo "(none)"; }

# A transcript whose last assistant text ends in a question, incl. trailing markdown
# punctuation — ends_with_question must see through the trailing '**'.
QT="$TMPD/q.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}' >  "$QT"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Which one?**"}]}}' >> "$QT"
ST="$TMPD/s.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"All finished."}]}}' > "$ST"

# --- attn tier: permission_prompt -------------------------------------------
# attn plays its cue through afplay, NOT through -sound: Focus suppresses notification
# sound but does not gate plain audio playback. -sound must stay absent so a
# Focus-free moment does not chime twice.
run permission_prompt '{"message":"Bash wants to run rm"}'
check "permission: attn title"        "Claude Code · needs you" "$(val -title)"
check "permission: Hero via afplay"   "Hero"                    "$(played)"
check "permission: no -sound flag"    "no"                      "$(has -sound)"
check "permission: attn group"        "claude-unknown-attn"     "$(val -group)"
check "permission: message passed"    "Bash wants to run rm"    "$(val -message)"
# -ignoreDnD is a dead pre-Focus private API on macOS 12+; it must not reappear.
check "permission: no -ignoreDnD"     "no"                      "$(has -ignoreDnD)"

# --- attn tier: idle_prompt --------------------------------------------------
run idle_prompt '{"message":"waiting on you"}'
check "idle: attn title"              "Claude Code · needs you" "$(val -title)"
check "idle: Hero via afplay"         "Hero"                    "$(played)"
check "idle: no -sound flag"          "no"                      "$(has -sound)"

# --- done tier: plain stop ---------------------------------------------------
# done hands its sound to macOS precisely so Focus CAN suppress it, and must never
# route through afplay — that would let a finished turn interrupt you.
run stop "{\"transcript_path\":\"$ST\"}"
check "stop: done title"              "Claude Code"             "$(val -title)"
check "stop: Tink via -sound"         "Tink"                    "$(val -sound)"
check "stop: does NOT use afplay"     "(none)"                  "$(played)"
check "stop: done group"              "claude-unknown-done"     "$(val -group)"
check "stop: default message"         "Claude finished"         "$(val -message)"
check "stop: no -ignoreDnD"           "no"                      "$(has -ignoreDnD)"

# --- attn tier: a stop that ends by asking something -------------------------
run stop "{\"transcript_path\":\"$QT\"}"
check "question stop: attn title"     "Claude Code · needs you" "$(val -title)"
check "question stop: Hero via afplay" "Hero"                   "$(played)"
check "question stop: no -sound flag" "no"                      "$(has -sound)"
check "question stop: attn group"     "claude-unknown-attn"     "$(val -group)"

# --- group keys must differ per tier ----------------------------------------
# Regression guard: a single "claude-$SESSION" key made terminal-notifier REPLACE a
# pending permission prompt with the following "finished", silently losing the one
# that actually needed input.
run permission_prompt '{"message":"x"}'; a=$(val -group)
run stop "{\"transcript_path\":\"$ST\"}"; b=$(val -group)
check "attn and done groups differ"   "differ" "$([ "$a" != "$b" ] && echo differ || echo same)"

# --- per-tier sound overrides -----------------------------------------------
run permission_prompt '{"message":"x"}' CLAUDE_NOTIFY_SOUND=Submarine
check "attn sound override"           "Submarine" "$(played)"
run stop "{\"transcript_path\":\"$ST\"}" CLAUDE_NOTIFY_SOUND_DONE=Bottle
check "done sound override"           "Bottle"    "$(val -sound)"
# Overrides must not bleed across tiers.
run stop "{\"transcript_path\":\"$ST\"}" CLAUDE_NOTIFY_SOUND=Submarine
check "attn override leaves done"     "Tink"      "$(val -sound)"
run permission_prompt '{"message":"x"}' CLAUDE_NOTIFY_SOUND_DONE=Bottle
check "done override leaves attn"     "Hero"      "$(played)"
# A nonexistent sound must degrade to silence, not to a broken afplay call.
run permission_prompt '{"message":"x"}' CLAUDE_NOTIFY_SOUND=NoSuchSound
check "bogus attn sound -> silent"    "(none)"    "$(played)"
check "bogus attn sound still notifies" "1"       "$(calls)"

# --- Focus mode gating of the attn cue --------------------------------------
# Work/Personal/DND must still get the audible cue — the whole point is reaching you
# while you are working. Sleep and Movie must not.
for m in com.apple.focus.work com.apple.focus.personal-time \
         com.apple.donotdisturb.mode.default com.apple.focus.reduce-interruptions; do
  focus_on "$m"
  run permission_prompt '{"message":"x"}'
  check "attn sounds under ${m##*.}" "Hero" "$(played)"
done
for m in com.apple.sleep.sleep-mode com.apple.donotdisturb.mode.paintpalettefill; do
  focus_on "$m"
  run permission_prompt '{"message":"x"}'
  check "attn silent under ${m##*.}"  "(none)" "$(played)"
  # Suppressing the sound must not suppress the notification itself.
  check "…but still notifies (${m##*.})" "1"   "$(calls)"
done
# The silent-mode list is overridable.
focus_on com.apple.focus.work
run permission_prompt '{"message":"x"}' CLAUDE_NOTIFY_SILENT_MODES=com.apple.focus.work
check "silent-mode list override"     "(none)" "$(played)"
# A malformed Focus DB must fail open (sound plays), never crash the hook.
printf '%s' 'not json' > "$TMPD/home/Library/DoNotDisturb/DB/Assertions.json"
run permission_prompt '{"message":"x"}'
check "malformed focus db -> plays"   "Hero"   "$(played)"
rm -f "$TMPD/home/Library/DoNotDisturb/DB/Assertions.json"
run permission_prompt '{"message":"x"}'
check "absent focus db -> plays"      "Hero"   "$(played)"
focus_off

# --- defaults when the payload carries no message ---------------------------
run permission_prompt '{}'
check "permission: fallback message"  "Permission requested" "$(val -message)"
run idle_prompt '{}'
check "idle: fallback message"        "Claude is idle"       "$(val -message)"

# --- every chosen sound must actually exist on any macOS --------------------
for s in Hero Tink; do
  check "$s ships with macOS" "yes" \
    "$([ -f "/System/Library/Sounds/$s.aiff" ] && echo yes || echo no)"
done

# --- events that must not notify at all -------------------------------------
run working '{}'
check "working: no notification"      "0" "$(calls)"
run exit '{}'
check "exit: no notification"         "0" "$(calls)"
run bogus-event '{}'
check "unknown event: no notification" "0" "$(calls)"

# --- robustness: malformed / empty payloads must still notify, not crash ----
run stop 'not json at all'
check "stop: survives bad json"       "1"               "$(calls)"
check "stop: bad json -> done tier"   "Claude Code"     "$(val -title)"
run permission_prompt ''
check "permission: survives empty stdin" "1"            "$(calls)"
run stop '{"transcript_path":"/nonexistent/path.jsonl"}'
check "stop: missing transcript -> done" "Claude Code"  "$(val -title)"

# --- the local Mac notification can be switched off --------------------------
# In Rex, Claude Code reports its own state, and Rex shows a notification for it.
# Thus, the Mac banner and its cue are a second alert for the same event.
# CLAUDE_NOTIFY_LOCAL=0 drops both. The tmux tab colour is unaffected.
run permission_prompt '{"message":"x"}' CLAUDE_NOTIFY_LOCAL=0
check "local off: no terminal-notifier" "0"      "$(calls)"
check "local off: no sound"             "(none)" "$(played)"
run stop "{\"transcript_path\":\"$ST\"}" CLAUDE_NOTIFY_LOCAL=0
check "local off: done is silent too"   "(none)" "$(played)"
check "local off: done no banner"       "0"      "$(calls)"
# Default must stay ON, so clearing the export restores the old behaviour.
run permission_prompt '{"message":"x"}'
check "local on by default"             "1"      "$(calls)"

echo
[ "$fail" -eq 0 ] && echo "All notify-tmux tests passed." || echo "Some notify-tmux tests FAILED."
exit "$fail"
