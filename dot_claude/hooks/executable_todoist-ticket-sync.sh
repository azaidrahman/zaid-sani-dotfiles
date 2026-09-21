#!/usr/bin/env bash
# todoist-ticket-sync.sh - tell the session when a ticket starts or ends.
#
# The gtech-skills `start-ticket-worktree` and `finish-branch` skills carry the Jira
# steps. Nothing carries the Todoist steps. This hook closes that gap.
#
# The hook reads each Bash command after it runs. It looks for a git or
# worktree command that carries a ticket key. If it finds one, it writes a note
# back to the session. The note asks the session to run the
# todoist-ticket-sync skill.
#
# The session acts alone when the correct update is clear. The skill holds the
# list of cases that need a question.
#
# The hook detects two events:
#   start   - a branch or a worktree is created for a key
#   finish  - a branch or a worktree is deleted for a key
#
# The hook fires one time for each key and event in each session. It keeps a
# marker file for each pair. A second command for the same pair is quiet.
#
# The hook never blocks the session. On any problem it exits 0 and says
# nothing.
#
# False positives. The hook reads a command, not the text that the command
# writes. Two rules keep data out of the scan:
#   1. The hook drops every heredoc body first. A command that writes a file
#      often carries a ticket key in that file. The key is data there.
#   2. A skill name counts only in command position. Prose that names
#      `finish-branch` is data, not a call.
# Both rules come from one misfire on 2026-09-21. A write of SKILL.md carried
# the key GTI-273 and the word finish-branch in its heredoc, and the hook
# reported that work on GTI-273 had finished.
set -u

MARKER_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/todoist-ticket-sync"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat) || exit 0
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
session=$(printf '%s' "$payload" | jq -r '.session_id // "nosession"' 2>/dev/null) || session="nosession"

[ -n "$command" ] || exit 0

# Drop every heredoc body. What a command writes is data, not a command.
scan=$(printf '%s\n' "$command" | awk '
  {
    if (inbody) {
      stripped = $0
      sub(/^[ \t]+/, "", stripped)
      sub(/[ \t]+$/, "", stripped)
      if (stripped == term) { inbody = 0 }
      next
    }
    line = $0
    if (match(line, /<<-?[ \t]*("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z_][A-Za-z0-9_]*)/)) {
      term = substr(line, RSTART, RLENGTH)
      sub(/^<<-?[ \t]*/, "", term)
      gsub(/["'"'"']/, "", term)
      if (term != "") { inbody = 1 }
    }
    print line
  }
')
[ -n "$scan" ] || exit 0

# The command must carry a ticket key. Read the first key only.
key=$(printf '%s' "$scan" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)
[ -n "$key" ] || exit 0

# A skill name counts only in command position: at the start, or after a
# separator such as ; && || | or (. Prose and quoted text never match.
cmdpos='(^|[;&|(])[[:space:]]*'
word='([[:space:]]|$)'

# Decide the event. A delete wins over a create, because `agent-worktree`
# prints both words in one line when it replaces a worktree.
event=""
if printf '%s' "$scan" | grep -qE "git +branch +-[dD]|git +worktree +remove|${cmdpos}finish-branch${word}"; then
  event="finish"
elif printf '%s' "$scan" | grep -qE "git +checkout +-b|git +switch +-c|git +worktree +add|${cmdpos}(agent-worktree|start-ticket)${word}"; then
  event="start"
fi
[ -n "$event" ] || exit 0

# Fire one time for each key and event in each session.
marker="$MARKER_DIR/$session.$event.$key"
mkdir -p "$MARKER_DIR" 2>/dev/null || exit 0
[ -e "$marker" ] && exit 0
: >"$marker" 2>/dev/null || exit 0

if [ "$event" = "start" ]; then
  note="Work on $key started in this session. Use the todoist-ticket-sync skill to update Todoist for $key. If the correct update is clear, make it and report it in one line. Ask the user only if the skill calls the case unclear."
else
  note="Work on $key finished in this session. Use the todoist-ticket-sync skill to update Todoist for $key. If the correct update is clear, make it and report it in one line. Ask the user only if the skill calls the case unclear."
fi

jq -cn --arg note "$note" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $note
  }
}'

exit 0
