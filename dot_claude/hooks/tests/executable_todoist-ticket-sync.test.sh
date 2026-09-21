#!/usr/bin/env bash
HOOK=~/.claude/hooks/todoist-ticket-sync.sh
pass=0; fail=0
run() { # name expect command
  local name="$1" expect="$2" cmd="$3"
  export XDG_CACHE_HOME=$(mktemp -d)
  local out
  out=$(jq -cn --arg c "$cmd" '{session_id:"t",tool_input:{command:$c}}' | bash "$HOOK" \
        | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  local got="none"
  case "$out" in
    *"started in this session"*) got="start" ;;
    *"finished in this session"*) got="finish" ;;
  esac
  if [ "$got" = "$expect" ]; then printf 'PASS  %-34s %s\n' "$name" "$got"; pass=$((pass+1))
  else printf 'FAIL  %-34s want=%s got=%s\n' "$name" "$expect" "$got"; fail=$((fail+1)); fi
  rm -rf "$XDG_CACHE_HOME"
}

# 1. the exact misfire from this session
run "heredoc write of SKILL.md" none "$(printf 'cd ~/.claude/skills/x && cat > SKILL.md <<%sEOF%s\ndescription: like GTI-273, the user says\n- `finish-branch` owns the Jira transition\nEOF\nwc -l SKILL.md' "'" "'")"
# 2-3. real git events
run "git worktree add"       start  'git worktree add ../wt-gti780 feat/GTI-780-iam'
run "git branch -d"          finish 'git branch -d feat/GTI-780-iam'
run "git switch -c"          start  'git switch -c fix/GTI-781-bug'
run "git worktree remove"    finish 'git worktree remove ../wt-gti780 # GTI-780'
# 4. skill names in command position
run "finish-branch cmd"      finish 'finish-branch GTI-790'
run "start-ticket after &&"  start  'cd /repo && start-ticket GTI-791'
run "start-ticket-worktree"  start  'start-ticket-worktree GTI-791'
run "start-ticket-branch"    start  'cd /repo && start-ticket-branch GTI-791'
run "start-worktree"         start  'start-worktree GTI-791'
# 5-7. data, not commands
run "skill name in prose"    none   'echo "run `finish-branch` when GTI-792 is done"'
run "skill name in a path"   none   'cat ~/.claude/skills/start-ticket/SKILL.md | grep GTI-793'
run "key in a heredoc only"  none   "$(printf 'cat > n.md <<%sM%s\nfixed GTI-794 via git worktree add\nM' "'" "'")"
# 8. a real command after a heredoc still fires
run "git cmd after heredoc"  start  "$(printf 'cat > n.md <<%sM%s\njust notes\nM\ngit worktree add ../w feat/GTI-795-x' "'" "'")"
echo "---"; echo "pass=$pass fail=$fail"
