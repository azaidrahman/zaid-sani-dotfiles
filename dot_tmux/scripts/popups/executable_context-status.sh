#!/usr/bin/env bash
# The context section of the prefix+u status center: the gcloud account,
# project and login session, and the kube current-context. claude-usage.sh
# sources this file and draws context_section above the usage view. Run alone,
# the file draws the section in its own screen.
#
# The section always shows the global state. A popup cannot read the
# environment of the pane that opened it, and no shell sets KUBECONFIG or a
# gcloud configuration per pane.
#
# Adding a future section (AWS profile, docker context, ...): write a
# parse_* function (pure, takes raw text, prints KEY value lines) and a
# render_* function, then call both from context_section().
#
# claude-usage.sh runs under /bin/bash 3.2, so keep this file 3.2-safe.

set -u

c_reset=$'\033[0m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'
c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_green=$'\033[32m'

# GCLOUD_SESSION_HOURS : how long a gcloud login lasts. Google Cloud session
# control sets this length for the console and the SDK. The org uses the
# default of 16 hours. The Admin console does not show this default, and no API
# reads it, so the value is fixed here. The environment wins.
GCLOUD_SESSION_HOURS=${GCLOUD_SESSION_HOURS:-16}

# SESSION_WARN_SECS : under this much time left, the session line turns yellow.
SESSION_WARN_SECS=7200

# LOGIN_SCAN_DAYS : how many day folders of the gcloud logs to read. gcloud
# makes a folder only on a day that it runs, so 3 folders cover two full
# sessions or more.
LOGIN_SCAN_DAYS=3

# ctx_now : the current time. A test sets FAKE_NOW to get a fixed clock.
ctx_now() { printf '%s' "${FAKE_NOW:-$(date +%s)}"; }

# blob_field <blob> <key> : the value of one "KEY value" line of a blob.
blob_field() {
  printf '%s\n' "$1" | awk -v k="$2" '$1==k{ $1=""; sub(/^ /,""); print; exit }'
}

clock_of() { # epoch -> "2:48AM FRI 30-OCT", the same shape as the usage bars
  date -r "$1" '+%I:%M%p %a %d-%b' 2>/dev/null \
    | tr '[:lower:]' '[:upper:]' | sed -E 's/^0//'
}

left_of() { # seconds -> "13h 10m", or "45m" under an hour
  local h=$(( $1 / 3600 )) m=$(( $1 % 3600 / 60 ))
  if (( h > 0 )); then printf '%dh %dm' "$h" "$m"
  else                 printf '%dm' "$m"
  fi
}

# parse_gcloud_config <ini_text> : extract account + project from a gcloud
# config ini blob. Empty fields when absent.
parse_gcloud_config() {
  local text=$1 account project
  account=$(printf '%s\n' "$text" | awk -F'= ' '/^account = /{print $2; exit}')
  project=$(printf '%s\n' "$text" | awk -F'= ' '/^project = /{print $2; exit}')
  printf 'ACCOUNT %s\nPROJECT %s\n' "$account" "$project"
}

# parse_kube_context <kubeconfig_text> : extract the full current-context
# (no shortening/stopword stripping — the popup has room for the whole name).
parse_kube_context() {
  local text=$1
  printf '%s\n' "$text" | awk -F': ' '/^current-context:/{print $2; exit}'
}

# login_epochs <logs_dir> <account> : the epoch of each completed
# `gcloud auth login` of the account, oldest first. A login is complete when
# gcloud writes "You are now logged in as [account]". The time is the time of
# the log line before it, which is the token exchange.
login_epochs() {
  local dir=$1 account=$2 day f ts
  ls -1d "$dir"/*/ 2>/dev/null | tail -n "$LOGIN_SCAN_DAYS" | while IFS= read -r day; do
    grep -l -F 'Running [gcloud.auth.login]' "$day"*.log 2>/dev/null
  done | while IFS= read -r f; do
    ts=$(awk -v acct="$account" '
      /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / { ts = substr($0, 1, 19) }
      index($0, "You are now logged in as [" acct "]") { print ts; exit }' "$f")
    [ -n "$ts" ] && date -j -f '%Y-%m-%d %H:%M:%S' "$ts" +%s 2>/dev/null
  done
}

# session_from_logins : read login epochs on stdin, oldest first, and print
# "START <epoch>" and "LATEST <epoch>". Only a login after the end of the last
# session starts a new one. The gcloud logs show that a re-login inside a
# session does not extend it: the browser reuses the open Google sign-in.
session_from_logins() {
  local len=$(( GCLOUD_SESSION_HOURS * 3600 )) t start='' latest=''
  while read -r t; do
    [[ $t =~ ^[0-9]+$ ]] || continue
    if [ -z "$start" ] || (( t >= start + len )); then start=$t; fi
    latest=$t
  done
  if [ -n "$start" ]; then printf 'START %s\nLATEST %s\n' "$start" "$latest"; fi
}

# gcloud_session <gcloud_config_dir> <account> : the session of the account.
# gcloud keeps its logs for 30 days. Without a login in them, the time of the
# credential file starts the session. gcloud writes that file on each login.
gcloud_session() {
  local dir=$1 account=$2 blob cred
  [ -n "$account" ] || return 0
  blob=$(login_epochs "$dir/logs" "$account" | session_from_logins)
  cred="$dir/legacy_credentials/$account/adc.json"
  if [ -z "$blob" ] && [ -f "$cred" ]; then
    blob=$(stat -f %m "$cred" | session_from_logins)
  fi
  printf '%s' "$blob"
}

# render_session <gcloud_session output> : the time left in the session, and
# when it started.
render_session() {
  local start latest end left col note=''
  start=$(blob_field "$1" START); latest=$(blob_field "$1" LATEST)
  if [ -z "$start" ]; then
    printf '  %-9s%-9s%sno login found · run gcloud auth login%s\n' '' session "$c_red" "$c_reset"
    return
  fi
  end=$(( start + GCLOUD_SESSION_HOURS * 3600 ))
  left=$(( end - $(ctx_now) ))
  if (( left <= 0 )); then
    printf '  %-9s%-9s%s✗ ended %s · run gcloud auth login%s\n' \
      '' session "$c_red" "$(clock_of "$end")" "$c_reset"
  else
    col=$c_green
    (( left < SESSION_WARN_SECS )) && col=$c_yellow
    printf '  %-9s%-9s%s✓ %s left%s %s· ends %s%s\n' \
      '' session "$col" "$(left_of "$left")" "$c_reset" "$c_dim" "$(clock_of "$end")" "$c_reset"
  fi
  if (( ${latest:-0} > start )); then
    note="  (re-login $(date -r "$latest" '+%I:%M%p' | sed -E 's/^0//') did not extend it)"
  fi
  printf '  %-9s%-9s%s%s%s%s\n' '' authed "$(clock_of "$start")" "$c_dim" "$note" "$c_reset"
}

# render_gcloud <config_name> <parse_gcloud_config output> <gcloud_session
# output> : gcloud section.
render_gcloud() {
  local config_name=$1 blob=$2 session=$3 account project
  account=$(blob_field "$blob" ACCOUNT)
  project=$(blob_field "$blob" PROJECT)
  if [ -z "$account" ]; then
    printf '  %s%-9s%s%snot configured%s\n' "$c_bold" gcloud "$c_reset" "$c_dim" "$c_reset"
    return
  fi
  printf '  %s%-9s%s%s\n' "$c_bold" gcloud "$c_reset" "$account"
  printf '  %-9s%-9s%s  %s(config: %s)%s\n' \
    '' project "${project:-<none>}" "$c_dim" "$config_name" "$c_reset"
  render_session "$session"
}

# render_kube <context> : kube section.
render_kube() {
  if [ -z "$1" ]; then
    printf '  %s%-9s%s%sno current-context%s\n' "$c_bold" kube "$c_reset" "$c_dim" "$c_reset"
  else
    printf '  %s%-9s%s%s\n' "$c_bold" kube "$c_reset" "$1"
  fi
}

# context_section : read the gcloud and kube files, and draw both sections.
context_section() {
  local gconf_dir="${GCLOUD_CONFIG_DIR:-$HOME/.config/gcloud}"
  local active; active=$(cat "$gconf_dir/active_config" 2>/dev/null); active=${active:-default}
  local gblob; gblob=$(parse_gcloud_config "$(cat "$gconf_dir/configurations/config_${active}" 2>/dev/null)")
  render_gcloud "$active" "$gblob" "$(gcloud_session "$gconf_dir" "$(blob_field "$gblob" ACCOUNT)")"

  local kpath="${KUBECONFIG:-$HOME/.kube/config}"
  render_kube "$(parse_kube_context "$(cat "$kpath" 2>/dev/null)")"
}

context_main() {
  clear 2>/dev/null
  echo
  printf '  %sContext status%s\n\n' "$c_bold" "$c_reset"
  context_section
  echo
  printf '  %s[any key to close]%s' "$c_dim" "$c_reset"
  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null
  dd bs=1 count=1 >/dev/null 2>&1
  [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then context_main "$@"; fi
