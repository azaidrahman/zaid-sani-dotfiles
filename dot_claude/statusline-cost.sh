#!/usr/bin/env bash
# LiteLLM per-session cost helper for the Claude Code statusline.
# Sourced by ~/.claude/statusline.sh; never executed directly. All functions
# are pure or self-contained so the file is safe to source in tests.
#
# Cost source: the proxy tags every request with Claude Code's session id (via
# extra_spend_tag_headers in config.yaml), stored as the tag
# "x-claude-code-session-id: <id>". We read this session's spend from the
# proxy's /tag/daily/activity endpoint, which filters server-side by tag and
# returns a tiny per-tag aggregate — unlike /spend/logs, which returns the whole
# proxy's logs (tens of MB) and would time out over Tailscale.

# tag_total_spend <activity_json> : extract .metadata.total_spend from a
# /tag/daily/activity response. Pure (no network). Prints the total rounded to
# 2dp as jq's natural number string, or "0" on empty/invalid input.
tag_total_spend() {
  local resp=$1
  [ -n "$resp" ] || { printf '0'; return; }
  printf '%s' "$resp" | jq -r '(.metadata.total_spend // 0) | (. * 100 | round) / 100' 2>/dev/null || printf '0'
}

LITELLM_COST_TTL=30          # seconds: refresh when the cache is older than this
LITELLM_COST_LOCK_STALE=60   # seconds: break a lock left by a crashed refresh

# _dir_age <path> : seconds since the path's mtime (BSD stat, then GNU). Empty on
# failure (e.g. path missing). Used on both the lock dir and the cache file.
_dir_age() {
  local m now
  m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || return 1
  now=$(date +%s)
  printf '%s' $(( now - m ))
}

# _litellm_fetch_tag_activity <base> <key> <tag> <start> <end> : per-tag daily
# activity JSON for the window. Thin authenticated GET; overridden in tests.
# The tag is URL-encoded with jq's @uri (it contains a space and a colon).
# Empty on failure.
_litellm_fetch_tag_activity() {
  local base=$1 key=$2 tag=$3 start=$4 end=$5 enc
  enc=$(jq -rn --arg s "$tag" '$s|@uri' 2>/dev/null) || return
  curl -fsS -m 6 -H "Authorization: Bearer $key" \
    "$base/tag/daily/activity?tags=$enc&start_date=$start&end_date=$end" 2>/dev/null
}

# _litellm_cost_refresh <base> <key> <session_id> <cache_file> : fetch this
# session's per-tag spend for the recent window and write it atomically.
# Lock-guarded so rapid repaints collapse to one in-flight refresh; a stale lock
# is broken first. On an unreachable proxy the old cache is left untouched.
_litellm_cost_refresh() {
  local base=$1 key=$2 sid=$3 cache=$4 lock="$4.lock"
  if [ -d "$lock" ]; then
    local age; age=$(_dir_age "$lock")
    [ "${age:-0}" -gt "$LITELLM_COST_LOCK_STALE" ] && rmdir "$lock" 2>/dev/null
  fi
  mkdir "$lock" 2>/dev/null || return     # another refresh already in flight
  trap 'rmdir "$lock" 2>/dev/null' RETURN
  local start end tag resp total
  start=$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F)
  end=$(date -v+1d +%F 2>/dev/null || date -d 'tomorrow' +%F)
  tag="x-claude-code-session-id: $sid"
  resp=$(_litellm_fetch_tag_activity "$base" "$key" "$tag" "$start" "$end")
  [ -n "$resp" ] || return                # unreachable -> keep the old cache
  total=$(tag_total_spend "$resp")
  printf '%s' "$total" > "$cache.tmp" && mv "$cache.tmp" "$cache"
}

# litellm_session_cost <base> <key> <session_id> : echo this session's cached
# spend (USD number, or nothing if never fetched). Spawns a DETACHED refresh when
# the cache is missing or older than the TTL — never blocks the statusline.
litellm_session_cost() {
  local base=$1 key=$2 sid=$3
  [ -n "$sid" ] || return
  # The id becomes part of a file path. Accept only the characters of a session
  # id (UUID form), so that no "/" or ".." can lead the path out of TMPDIR.
  case $sid in *[!A-Za-z0-9_-]*) return ;; esac
  local cache="${TMPDIR:-/tmp}/claude-cc-cost.$sid" need=1
  if [ -f "$cache" ]; then
    local age; age=$(_dir_age "$cache")
    [ "${age:-9999}" -le "$LITELLM_COST_TTL" ] && need=0
  fi
  if [ "$need" -eq 1 ]; then
    ( _litellm_cost_refresh "$base" "$key" "$sid" "$cache" >/dev/null 2>&1 & )
  fi
  [ -f "$cache" ] && cat "$cache"
}
