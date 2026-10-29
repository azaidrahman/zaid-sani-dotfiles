#!/bin/bash
# prefix+u : the status center. A context section (the gcloud session and the
# kube context) sits on top. Under it, bars show how much of an AI
# subscription or budget is gone.
#
# The context section is not a provider. popups/context-status.sh draws it,
# and main reads it one time, before the first draw.
#
# The script has three layers. Keep them separate.
#   1. A provider fetches its own data and prints a canonical blob.
#   2. A view renders one blob shape. There are three views: quota, cost and
#      both, which stacks a quota section over a cost section.
#   3. The popup sizes itself from the blob that is already in the cache.
#
# A provider never draws, and a view never fetches. To add a subscription you
# write the provider only.
#
# CANONICAL BLOB
# Every line is one record. The fields are separated by a tab character.
#   QUOTA <label> <pct> <epoch|-> <window-seconds|->   one bar in the quota view
#   MODEL <usd> <name>                                 one bar in the cost view
#   TOTAL <all|7d|mtd|ytd> <usd>                       one total in the cost view
#   NOTE  <text>                                       a message for the reader
# The blob holds absolute epoch seconds, never a countdown. The countdown is
# recomputed at draw time, so a cached blob stays correct as the clock moves.
#
# HOW TO ADD A PROVIDER
# Write these functions, with the id of the provider as the prefix. Then add
# the id to PROVIDERS and map the pane marker to it in resolve_provider.
#   p_<id>_view       prints "quota" or "cost"
#   p_<id>_title      prints the header of the popup
#   p_<id>_tag        prints the colored name of the provider
#   p_<id>_fetch      prints the raw text of the source
#   p_<id>_normalize  reads the raw text on stdin, prints a canonical blob
# A provider that cannot split the fetch from the parse writes p_<id>_blob
# instead. The default p_<id>_blob is "fetch | normalize".
#
# A fetch is slow (`claude -p /usage` cold-boots the CLI, ~0.9s), so:
#   1. if a cached blob exists, draw it at once and mark it stale,
#   2. if not, show a "Loading…" line,
#   3. then fetch, overwrite the cache, and draw again.

set -u

PROVIDERS='claude litellm codex agents'

# CODEX_IN_AGENTS : 1 adds the Codex subscription quota to a pi or omp pane,
# 0 leaves those panes on the LiteLLM cost view alone. Flip it to 0 if the
# ChatGPT subscription stops allowing the Codex models inside pi — nothing
# else has to change. The environment wins, so you can compare the two
# without an edit:
#   CODEX_IN_AGENTS=0 ~/.tmux/scripts/claude-usage.sh
CODEX_IN_AGENTS=${CODEX_IN_AGENTS:-1}

TAB=$'\t'
c_reset=$'\033[0m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_cyan=$'\033[36m'

# The context section. Chezmoi deploys the file as popups/context-status.sh.
# A test sources this script from the chezmoi source, where the file keeps its
# executable_ prefix. If neither file exists, the popup has no context section.
_ctx_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/popups"
for _ctx in "$_ctx_dir/context-status.sh" "$_ctx_dir/executable_context-status.sh"; do
  if [ -r "$_ctx" ]; then source "$_ctx"; break; fi
done
unset _ctx _ctx_dir

# CONTEXT_TEXT : the drawn context section. main sets it. A test leaves it
# empty, so a view draws without the section.
CONTEXT_TEXT=''
# --- shared helpers ------------------------------------------------------

color_for() { # pct -> green/yellow/red
  local p=$1
  if   (( p >= 90 )); then printf '\033[31m'
  elif (( p >= 70 )); then printf '\033[33m'
  else                     printf '\033[32m'
  fi
}

repeat() { # char count -> char repeated count times (0-safe)
  local ch=$1 n=$2 out=''
  while (( n-- > 0 )); do out+=$ch; done
  printf '%s' "$out"
}

fmt_tokens() { # num -> 500, 1.2k, 1.05M
  local n=${1:-0}
  awk -v n="$n" 'BEGIN {
    if (n >= 1000000) {
      v = sprintf("%.2f", n/1000000);
      sub(/0+$/, "", v); sub(/\.$/, "", v);
      printf "%sM", v;
    } else if (n >= 1000) {
      v = sprintf("%.1f", n/1000);
      sub(/0+$/, "", v); sub(/\.$/, "", v);
      printf "%sk", v;
    } else {
      printf "%d", n;
    }
  }'
}

# term_width : the popup's real column count. `tput cols` first — inside a
# display-popup, $COLUMNS can come in pre-exported as a stale "0" from the
# outer environment, and "${COLUMNS:-default}" only falls back on unset/empty,
# not on a literal 0, so trusting it here silently floors every bar to 10 wide.
# Do NOT redirect tput's stderr: with stdout captured by $(...), tput falls
# back to querying stderr for the controlling tty, and `2>/dev/null` kills
# that path too, silently returning the 80x24 default instead of the real size.
term_width() {
  local c; c=$(tput cols)
  if [[ $c =~ ^[0-9]+$ ]] && (( c > 0 )); then printf '%s' "$c"; return; fi
  if [[ ${COLUMNS:-0} =~ ^[0-9]+$ ]] && (( ${COLUMNS:-0} > 0 )); then printf '%s' "$COLUMNS"; return; fi
  printf '80'
}

# now_epoch : the current time. A test overrides it with FAKE_NOW to get a
# fixed clock, because a countdown that moves cannot be checked.
now_epoch() { printf '%s' "${FAKE_NOW:-$(date +%s)}"; }

# window_len <label> : the full length of a limit window, in seconds. Most
# sources report the reset time but not the length, so the length comes from
# the label: a session window is 5 hours, a weekly window is 7 days. Empty for
# an unknown label. A provider may print its own length instead.
window_len() {
  local l; l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$l" in
    *session*|*5h*) printf '18000'  ;;   # 5h
    *week*)         printf '604800' ;;   # 7d
    *month*)        printf '2592000';;   # 30d
  esac
}

# window_noun <label> : the word for the window, used in the elapsed-time note.
window_noun() {
  local l; l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$l" in
    *session*|*5h*) printf 'session' ;;
    *week*)         printf 'week'    ;;
    *month*)        printf 'month'   ;;
    *)              printf 'window'  ;;
  esac
}

# --- date helpers for normalizers ----------------------------------------
# Each helper turns one dialect of reset time into epoch seconds, and prints
# nothing if it cannot parse the input. A provider picks the helper that fits
# its own source.

# epoch_from_ampm <"Jun 22 at 4pm (Asia/Kuala_Lumpur)"> : the Claude phrasing.
epoch_from_ampm() {
  local s=$1 raw mday t yr epoch now
  raw=${s%% (*}        # drop trailing " (tz)"
  raw=${raw/ at / }    # "Jun 22 4pm"
  mday=${raw% *}       # "Jun 22"
  t=${raw##* }         # "4pm" or "11:30am"
  [[ $t != *:* ]] && t=$(printf '%s' "$t" | sed -E 's/^([0-9]+)(am|pm)$/\1:00\2/')  # 4pm -> 4:00pm
  yr=$(date +%Y)
  epoch=$(date -j -f "%b %d %Y %I:%M%p" "$mday $yr $t" +%s 2>/dev/null) || return
  [ -z "$epoch" ] && return
  now=$(now_epoch)
  (( epoch < now - 86400 )) && epoch=$(date -j -f "%b %d %Y %I:%M%p" "$mday $((yr+1)) $t" +%s 2>/dev/null)  # year wrap
  printf '%s' "$epoch"
}

# epoch_from_clock <"16:30"> : the next time the clock reads HH:MM.
epoch_from_clock() {
  local hm=$1 now today epoch
  now=$(now_epoch)
  today=$(date -r "$now" +%Y-%m-%d 2>/dev/null) || return
  epoch=$(date -j -f "%Y-%m-%d %H:%M" "$today $hm" +%s 2>/dev/null) || return
  [ -z "$epoch" ] && return
  (( epoch < now )) && epoch=$(( epoch + 86400 ))   # already past, so tomorrow
  printf '%s' "$epoch"
}

# epoch_from_iso <"2026-08-25T13:59:00Z"> : an ISO 8601 instant, UTC or local.
epoch_from_iso() {
  local s=$1 epoch
  epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$s" +%s 2>/dev/null) \
    || epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${s%%[+-][0-9][0-9]:[0-9][0-9]}" +%s 2>/dev/null) \
    || return
  printf '%s' "$epoch"
}

# --- the quota view ------------------------------------------------------

LABEL_W=26   # width of the label column; the marker note aligns against it
BAR_CAP=70   # the bar never grows past this, however wide the terminal is

# ROW_FIXED_W : every cell of a quota row except the bar itself. The popup
# width comes from this sum, so a change to the reset format widens the box
# instead of wrapping the last characters onto the next line.
#   2  indent
#  +LABEL_W +1  the label column and the space after it
#  +5  " 100%"
#  +6  " ▲+100"
#  +37 " resets in Xh Xm (H:MMPM DDD DD-MON)"
ROW_FIXED_W=$(( 2 + LABEL_W + 1 + 5 + 6 + 37 ))

# elapsed_pct <epoch> <window> : how much of the window is gone, 0-100. Empty
# if either input is missing.
elapsed_pct() {
  local epoch=$1 len=$2 now left
  [[ $epoch =~ ^[0-9]+$ ]] || return
  [[ $len   =~ ^[0-9]+$ ]] || return
  (( len > 0 )) || return
  now=$(now_epoch)
  left=$(( epoch - now ))
  (( left < 0 )) && left=0
  (( left > len )) && left=$len
  printf '%s' "$(( (len - left) * 100 / len ))"
}

to_countdown() { # epoch -> "in 2h 15m" ("now" once it is due)
  local epoch=$1 now diff d h m
  [[ $epoch =~ ^[0-9]+$ ]] || return
  now=$(now_epoch)
  diff=$(( epoch - now ))
  (( diff <= 0 )) && { printf 'now'; return; }
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   (( d > 0 )); then printf 'in %dd %dh' "$d" "$h"
  elif (( h > 0 )); then printf 'in %dh %dm' "$h" "$m"
  else                   printf 'in %dm' "$m"
  fi
}

to_clock() { # epoch -> "4:00PM SUN 22-JUN"
  local epoch=$1
  [[ $epoch =~ ^[0-9]+$ ]] || return
  date -r "$epoch" '+%I:%M%p %a %d-%b' 2>/dev/null \
    | tr '[:lower:]' '[:upper:]' | sed -E 's/^0//'
}

bar() { # label pct epoch window
  local label=$1 pct=$2 epoch=$3 win=$4
  (( pct > 100 )) && pct=100
  local width; width=$(term_width)
  local bar_w=$(( width - ROW_FIXED_W ))
  (( bar_w < 10 )) && bar_w=10
  (( bar_w > BAR_CAP )) && bar_w=$BAR_CAP
  local fill=$(( pct * bar_w / 100 ))
  local col; col=$(color_for "$pct")

  # elapsed : how much of the window has passed. It marks the "on pace" point —
  # if the fill is past the marker, you burn the budget faster than the clock.
  local elapsed mark=-1
  elapsed=$(elapsed_pct "$epoch" "$win")
  if [ -n "$elapsed" ]; then
    mark=$(( elapsed * bar_w / 100 ))
    (( mark > bar_w - 1 )) && mark=$(( bar_w - 1 ))
    (( mark < 0 )) && mark=0
  fi

  printf '  %-*s ' "$LABEL_W" "$label"
  local i out=''
  for (( i = 0; i < bar_w; i++ )); do
    if   (( i == mark )); then out+="${c_bold}│${c_reset}"
    elif (( i < fill ));  then out+="${col}█${c_reset}"
    else                       out+="${c_dim}░${c_reset}"
    fi
  done
  printf '%s' "$out"
  printf ' %s%3d%%%s' "$c_bold" "$pct" "$c_reset"

  # pace delta : used% minus elapsed%. Positive means ahead of the clock.
  if [ -n "$elapsed" ]; then
    local d=$(( pct - elapsed ))
    if   (( d >= 3 ));  then printf ' \033[31m▲+%d\033[0m' "$d"
    elif (( d <= -3 )); then printf ' \033[32m▼%d\033[0m' "$d"
    else                     printf ' %s≈%s' "$c_dim" "$c_reset"
    fi
  fi

  if [[ $epoch =~ ^[0-9]+$ ]]; then
    local cd clk; cd=$(to_countdown "$epoch"); clk=$(to_clock "$epoch")
    if [ -n "$clk" ]; then printf ' %sresets %s (%s)%s' "$c_dim" "$cd" "$clk" "$c_reset"
    else                   printf ' %sresets %s%s' "$c_dim" "$cd" "$c_reset"
    fi
  fi
  printf '\n'

  # second line : point at the marker and say what it means
  if [ -n "$elapsed" ]; then
    printf '  %*s %*s%s↑ %d%% of the %s elapsed%s\n' \
      "$LABEL_W" "" "$mark" "" "$c_dim" "$elapsed" "$(window_noun "$label")" "$c_reset"
  fi
}

# render_header <note> : the title and the provider tag. Every view starts
# with it, so the combined view draws it one time and not once per section.
render_header() {
  clear 2>/dev/null
  echo
  render_context
  printf '  %s%s%s  %s%s%s\n' "$c_bold" "$(provider_hook title)" "$c_reset" "$c_dim" "$1" "$c_reset"
  printf '  provider: %s\n\n' "$(provider_hook tag)"
}

# section_rule : the divider between the two sections of the combined view.
section_rule() { printf '\n  %s%s%s\n\n' "$c_dim" "$(repeat ─ 60)" "$c_reset"; }

# render_context : the context section and a rule under it. Nothing if main
# did not read the section.
render_context() {
  [ -n "$CONTEXT_TEXT" ] || return 0
  printf '%s\n' "$CONTEXT_TEXT"
  section_rule
}

# quota_body <blob> : one bar per QUOTA record.
#
# Both bodies follow one rule for NOTE records: a note prints only when its
# section drew nothing. A note beside real bars is chatter, and a combined
# blob holds the notes of both providers, so the rule also stops a failure of
# one section from printing again under the other.
quota_body() {
  local blob=$1 kind f2 f3 f4 f5 bars=0 notes=''
  while IFS="$TAB" read -r kind f2 f3 f4 f5; do
    case "$kind" in
      QUOTA) bar "$f2" "$f3" "${f4:--}" "${f5:--}"; bars=$(( bars + 1 )) ;;
      NOTE)  notes+="  $f2"$'\n' ;;
    esac
  done <<< "$blob"
  (( bars )) || printf '%s' "$notes"
}

# render_quota <blob> <note> : the quota view on its own.
render_quota() { render_header "$2"; quota_body "$1"; }

# --- the cost view -------------------------------------------------------

# cost_body <blob> : one bar per model, scaled against total spend,
# then the totals. If SESSION record is present, active session context & tokens
# are rendered first.
cost_body() {
  local blob=$1 kind f2 f3 f4 f5 f6 f7 f8 models='' notes=''
  local t_all=0 t_7d=0 t_mtd=0 t_ytd=0 t_today=0
  local sess_model='' sess_ctx=0 sess_ctx_win=0 sess_in=0 sess_cache=0 sess_out=0 sess_think=0
  while IFS="$TAB" read -r kind f2 f3 f4 f5 f6 f7 f8; do
    case "$kind" in
      MODEL)   models+="$f2$TAB$f3"$'\n' ;;
      NOTE)    notes+="  $f2"$'\n' ;;
      TOTAL)   case "$f2" in
                 all) t_all=$f3 ;; 7d) t_7d=$f3 ;; mtd) t_mtd=$f3 ;; ytd) t_ytd=$f3 ;; today) t_today=$f3 ;;
               esac ;;
      SESSION) sess_model=$f2; sess_ctx=$f3; sess_ctx_win=$f4; sess_in=$f5; sess_cache=$f6; sess_out=$f7; sess_think=${f8:-0} ;;
    esac
  done <<< "$blob"

  local width; width=$(term_width)
  local bar_w=$(( width - 42 )); (( bar_w < 8 )) && bar_w=8; (( bar_w > 45 )) && bar_w=45

  if [ -n "$sess_model" ] && (( sess_in > 0 || sess_cache > 0 || sess_ctx > 0 )); then
    local sess_tot_in=$(( sess_in + sess_cache ))
    local cache_pct=0
    (( sess_tot_in > 0 )) && cache_pct=$(( sess_cache * 100 / sess_tot_in ))

    local ctx_pct=0
    (( sess_ctx_win > 0 )) && ctx_pct=$(( sess_ctx * 100 / sess_ctx_win ))
    (( ctx_pct > 100 )) && ctx_pct=100

    local ctx_fill=$(( ctx_pct * 16 / 100 ))
    local ctx_empty=$(( 16 - ctx_fill ))

    printf '  %sActive session%s · %s%s%s\n' "$c_bold" "$c_reset" "$c_cyan" "$sess_model" "$c_reset"
    printf '  Context  %s%s%s%s%s %s%s / %s (%d%%)%s\n' \
      "$c_cyan" "$(repeat █ "$ctx_fill")" "$c_dim" "$(repeat ░ "$ctx_empty")" "$c_reset" \
      "$c_dim" "$(fmt_tokens "$sess_ctx")" "$(fmt_tokens "$sess_ctx_win")" "$ctx_pct" "$c_reset"

    local cache_col="$c_dim"
    (( cache_pct >= 80 )) && cache_col=$'\033[32m'
    (( cache_pct >= 50 && cache_pct < 80 )) && cache_col=$'\033[33m'

    local think_str=""
    (( sess_think > 0 )) && think_str=" ($(fmt_tokens "$sess_think") think)"

    printf '  Tokens   %s in · %s cached (%s%d%% hit%s) · %s out%s\n\n' \
      "$(fmt_tokens "$sess_in")" "$(fmt_tokens "$sess_cache")" "$cache_col" "$cache_pct" "$c_reset" \
      "$(fmt_tokens "$sess_out")" "$think_str"
  fi

  if [ -z "$models" ]; then
    if [ -n "$notes" ]; then printf '%s' "$notes"
    else printf '  %sno spend recorded%s\n' "$c_dim" "$c_reset"
    fi
    return
  fi

  local total_model_spend; total_model_spend=$(printf '%s' "$models" | awk -F"$TAB" \
    'BEGIN{s=0}{s+=$1+0}END{print s}')

  local spend model pct fill empty share_pct
  while IFS="$TAB" read -r spend model; do
    [ -z "$model" ] && continue
    if (( $(awk -v s="$total_model_spend" 'BEGIN{print (s>0)}') )); then
      pct=$(awk -v v="$spend" -v t="$total_model_spend" 'BEGIN{printf "%d", (v/t)*100}')
      share_pct=$(awk -v v="$spend" -v t="$total_model_spend" 'BEGIN{printf "%d%%", (v/t)*100}')
    else
      pct=0
      share_pct="0%"
    fi
    fill=$(( pct * bar_w / 100 )); (( fill < 0 )) && fill=0; (( fill > bar_w )) && fill=bar_w
    empty=$(( bar_w - fill ))
    printf '  %-24s %s%s%s%s%s %s$%0.2f%s %s(%s)%s\n' \
      "${model:0:24}" "$c_cyan" "$(repeat █ "$fill")" "$c_dim" "$(repeat ░ "$empty")" \
      "$c_reset" "$c_bold" "$spend" "$c_reset" "$c_dim" "$share_pct" "$c_reset"
  done <<< "$models"

  printf '  %s%s%s\n' "$c_dim" "$(repeat ─ $(( bar_w + 33 )))" "$c_reset"
  if (( $(awk -v v="${t_today:-0}" 'BEGIN{print (v>0)}') )); then
    printf '  %-24s %*s%s$%0.2f%s\n'      "Today" "$bar_w" "" "$c_bold" "${t_today:-0}" "$c_reset"
  fi
  printf '  %-24s %*s%s$%0.2f%s\n'      "Total · last 7 days" "$bar_w" "" "$c_bold" "${t_7d:-0}" "$c_reset"
  printf '  %-24s %*s$%0.2f\n'          "month to date" "$bar_w" "" "${t_mtd:-0}"
  printf '  %-24s %*s$%0.2f\n'          "year to date"  "$bar_w" "" "${t_ytd:-0}"
  printf '  %s%-24s %*s$%0.2f%s\n' "$c_dim" "all-time" "$bar_w" "" "${t_all:-0}" "$c_reset"
}

# render_cost <blob> <note> : the cost view on its own.
render_cost() { render_header "$2"; cost_body "$1"; }

# --- the combined view ---------------------------------------------------

# render_both <blob> <note> : the quota section over the cost section, from
# one blob. A pi or omp pane spends against two budgets at the same time — the
# ChatGPT subscription and the LiteLLM ledger — and the model changes inside a
# session, so the pane shows both instead of guessing which one is live.
render_both() {
  render_header "$2"
  quota_body "$1"
  section_rule
  cost_body "$1"
}

# --- provider : claude ---------------------------------------------------

p_claude_view()  { printf 'quota'; }
p_claude_title() { printf 'Claude Code usage'; }
p_claude_tag() {
  if [ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]; then printf '\033[34mVertex AI (direct)\033[0m'
  else                                          printf '\033[36mAnthropic API\033[0m'
  fi
}
# /usage needs auth and nothing else, so the session starts with the two most
# expensive parts of a normal boot turned off: --strict-mcp-config with no
# --mcp-config starts no MCP server, and an empty --setting-sources skips the
# project and local settings, and the plugins that come with them. Both are
# safe here, because no tool runs. This is the difference between 4.5s and
# 0.9s, and it is the whole cost of the popup.
p_claude_fetch() { claude --strict-mcp-config --setting-sources '' -p /usage 2>&1; }

# The CLI prints lines like "Current session: 12% used · resets Jun 22 at 4pm
# (Asia/Kuala_Lumpur)". A bar shows a limit window, so a row becomes a QUOTA
# only when it carries a reset clause. A percentage with no reset is not a
# window that the plan meters any more, so it falls through to a NOTE, which
# the quota view hides while real bars exist. Anything else is a NOTE too.
p_claude_normalize() {
  local line epoch win
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^(.+):\ *([0-9]+)%\ used\ *·\ *resets\ (.*)$ ]]; then
      epoch=$(epoch_from_ampm "${BASH_REMATCH[3]}")
      win=$(window_len "${BASH_REMATCH[1]}")
      printf 'QUOTA\t%s\t%s\t%s\t%s\n' \
        "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${epoch:--}" "${win:--}"
    elif [ -n "${line// /}" ]; then
      printf 'NOTE\t%s\n' "$line"
    fi
  done
}

# --- provider : litellm --------------------------------------------------

p_litellm_view()  { printf 'cost'; }
p_litellm_title() { printf 'Cost · LiteLLM ledger'; }
p_litellm_tag()   { printf '\033[35mLiteLLM\033[0m \033[2m(%s)\033[0m' "$(litellm_base)"; }

litellm_base() {
  if [[ "$(hostname -s)" == onyx* ]]; then
    printf 'http://localhost:4000'
  else
    printf 'http://onyx.tail5d740c.ts.net:4000'
  fi
}

# litellm_key : the proxy master key. Prefer the env var (present when sourced
# from a zsh that read ~/.zshenv); fall back to extracting it from secrets.zsh,
# because this popup runs as a fresh bash shell that never sourced ~/.zshenv.
litellm_key() {
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then printf '%s' "$LITELLM_MASTER_KEY"; return; fi
  local f="$HOME/.config/zsh/secrets.zsh"
  [ -r "$f" ] || return
  grep -E '^export[[:space:]]+LITELLM_MASTER_KEY=' "$f" | head -1 \
    | sed -E 's/^export[[:space:]]+LITELLM_MASTER_KEY=//; s/^["'\'']//; s/["'\'']$//'
}

# litellm_curl <base> <key> <path> : authenticated GET against the proxy.
litellm_curl() {
  curl -fsS -m 5 -H "Authorization: Bearer $2" "$1$3" 2>/dev/null
}

# session_blob : reads the active omp session stats for the current directory/pane.
session_blob() {
  command -v python3 >/dev/null 2>&1 || return
  local target_dir="${SRC_PATH:-}"
  if [ -z "$target_dir" ] && [ -n "${SRC_PANE:-}" ]; then
    target_dir=$(tmux display-message -p -t "$SRC_PANE" '#{pane_current_path}' 2>/dev/null || true)
  fi
  [ -z "$target_dir" ] && target_dir=$(pwd)

  python3 -c '
import os, sys, json, glob, time

def find_session(target_dir):
    base = os.path.expanduser("~/.omp/agent/sessions")
    if not os.path.isdir(base):
        return
    all_jsonls = glob.glob(os.path.join(base, "*", "*.jsonl"))
    if not all_jsonls:
        return
    all_jsonls.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    chosen = None
    if target_dir:
        norm = target_dir.replace(os.path.expanduser("~"), "").replace("/", "-")
        for f in all_jsonls:
            if norm in f:
                chosen = f
                break
    if not chosen:
        chosen = all_jsonls[0]

    if time.time() - os.path.getmtime(chosen) > 7200:
        return

    total_in = 0
    total_out = 0
    total_cache = 0
    total_think = 0
    last_ctx = 0
    model = "unknown"

    try:
        with open(chosen) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") == "model_change":
                    model = d.get("model", model)
                elif d.get("type") == "message" and d.get("message", {}).get("role") == "assistant":
                    msg = d.get("message", {})
                    if "model" in msg:
                        model = msg["model"]
                    usage = msg.get("usage", {})
                    total_in += usage.get("input", 0)
                    total_out += usage.get("output", 0)
                    total_cache += usage.get("cacheRead", 0)
                    total_think += usage.get("reasoningTokens", 0)
                    ctx = msg.get("contextSnapshot", {})
                    if "promptTokens" in ctx:
                        last_ctx = ctx["promptTokens"]
                    elif "totalTokens" in usage:
                        last_ctx = usage["totalTokens"]
    except Exception:
        return

    if total_in == 0 and total_cache == 0 and total_out == 0 and last_ctx == 0:
        return

    ctx_window = 1048576
    if "200k" in model or "haiku" in model:
        ctx_window = 200000
    elif "128k" in model or "gpt-4" in model:
        ctx_window = 128000

    print(f"SESSION\t{model}\t{last_ctx}\t{ctx_window}\t{total_in}\t{total_cache}\t{total_out}\t{total_think}")

target = sys.argv[1] if len(sys.argv) > 1 else ""
find_session(target)
' "$target_dir" 2>/dev/null
}

# litellm_blob <models_json> <spend_json> <logs_json> <cut7d> <cutMTD> <cutYTD> [cutToday] :
# fold the ledger of the proxy into a canonical blob (pure; no network). The
# cutoffs are inclusive YYYY-MM-DD lower bounds summed from the daily
# logs. The model name loses its provider prefix, to save width.
litellm_blob() {
  local mj=$1 sj=$2 lj=$3 cut=$4 cutm=$5 cuty=$6 cutt=${7:-}
  local all
  all=$(printf '%s' "$sj"  | jq -r '.spend // 0' 2>/dev/null); all=${all:-0}
  # sum the daily logs on/after an inclusive YYYY-MM-DD cutoff (0 on failure)
  sum_since() { local s; s=$(printf '%s' "$lj" | jq -r --arg c "$1" \
    '[.[] | select(.date >= $c) | .spend] | add // 0' 2>/dev/null); printf '%s' "${s:-0}"; }

  if [ -z "$cutt" ]; then
    cutt=$(date +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)
  fi

  printf 'TOTAL\tall\t%s\nTOTAL\t7d\t%s\nTOTAL\tmtd\t%s\nTOTAL\tytd\t%s\nTOTAL\ttoday\t%s\n' \
    "$all" "$(sum_since "$cut")" "$(sum_since "$cutm")" "$(sum_since "$cuty")" "$(sum_since "$cutt")"
  printf '%s' "$mj" | jq -r '
    [.[] | select((.total_spend // 0) > 0)] | sort_by(-.total_spend)[]
    | "MODEL\t\(.total_spend)\t\(.model | sub("^[a-z_]+/"; ""))"' 2>/dev/null
}

# The proxy needs three calls and the cutoffs of today, so this provider
# builds the blob in one step instead of a fetch plus a normalize.
p_litellm_blob() {
  local base key cut cutm cuty cutt mj sj lj
  base=$(litellm_base); key=$(litellm_key)
  cut=$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)
  cutm=$(date -u +%Y-%m-01)   # first of this month in UTC
  cuty=$(date -u +%Y-01-01)   # first of this year in UTC
  cutt=$(date -u +%Y-%m-%d)   # today in UTC
  mj=$(litellm_curl "$base" "$key" "/global/spend/models")
  sj=$(litellm_curl "$base" "$key" "/global/spend")
  lj=$(litellm_curl "$base" "$key" "/global/spend/logs")
  session_blob
  if [ -z "$mj" ] && [ -z "$sj" ]; then
    printf 'NOTE\tproxy unreachable — could not fetch spend\n'
    return
  fi
  litellm_blob "$mj" "$sj" "$lj" "$cut" "$cutm" "$cuty" "$cutt"
}

# --- provider : codex ----------------------------------------------------
# The ChatGPT subscription. `codex` uses it, and so do the openai-codex/*
# models of pi, which do not pass through the LiteLLM proxy and so leave no
# trace in its ledger. The backend reports both limit windows in one call, so
# the fetch is a single GET and the normalize is pure jq.

CODEX_AUTH="${CODEX_AUTH:-$HOME/.codex/auth.json}"
CODEX_USAGE_URL="${CODEX_USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"

p_codex_view()  { printf 'quota'; }
p_codex_title() { printf 'Codex usage'; }
p_codex_tag()   { printf '\033[32mChatGPT\033[0m \033[2m(%s)\033[0m' "$(codex_plan)"; }

# codex_field <jq-path> : one value out of the auth file that codex writes.
codex_field() { jq -r "$1 // empty" "$CODEX_AUTH" 2>/dev/null; }

# codex_plan : the plan behind the subscription — "team", "plus", "pro". It is
# a claim inside the access token, so it costs no network call. The tag draws
# before the fetch returns, which is why it cannot come from the response.
codex_plan() {
  local claims plan=''
  claims=$(codex_field '.tokens.access_token' | cut -d. -f2)
  if [ -n "$claims" ]; then
    while (( ${#claims} % 4 )); do claims+='='; done   # a JWT drops the padding
    plan=$(printf '%s' "$claims" | tr '_-' '/+' | base64 -d 2>/dev/null \
      | jq -r '."https://api.openai.com/auth".chatgpt_plan_type // empty' 2>/dev/null)
  fi
  printf '%s' "${plan:-subscription}"
}

# The access token lives ten days and codex refreshes it on every run, so an
# expired token is rare. Report it as a NOTE rather than refresh it here: a
# refresh rewrites the auth file, and this popup must never race codex for it.
p_codex_fetch() {
  local at acc
  at=$(codex_field '.tokens.access_token')
  [ -n "$at" ] || return
  acc=$(codex_field '.tokens.account_id')
  curl -fsS -m 5 -H "Authorization: Bearer $at" -H "chatgpt-account-id: $acc" \
    "$CODEX_USAGE_URL" 2>/dev/null
}

# The backend names the two windows primary and secondary, and gives the
# length of each, so the label does not have to carry the window.
p_codex_normalize() {
  local out
  out=$(jq -r '
    .rate_limit // empty
    | [ {w: .primary_window,   l: "Codex session"},
        {w: .secondary_window, l: "Codex week"} ][]
    | select(.w != null)
    | "QUOTA\t\(.l)\t\(.w.used_percent // 0 | floor)\t\(.w.reset_at // "-")\t\(.w.limit_window_seconds // "-")"
  ' 2>/dev/null)
  if [ -n "$out" ]; then printf '%s\n' "$out"; return; fi
  printf 'NOTE\tcodex usage unavailable — run `codex` one time to refresh the login\n'
}

# --- provider : agents ---------------------------------------------------
# A pi or omp pane. Both harnesses reach the Vertex models through the LiteLLM
# proxy and the GPT-5.6 models through the ChatGPT subscription, and the model
# changes inside a session. So the pane shows both budgets. The canonical
# format already allows this: QUOTA rows and MODEL rows can share one blob.

p_agents_view()  { printf 'both'; }
p_agents_title() { printf 'Coding agents'; }
p_agents_tag()   { printf '%s + %s' "$(p_codex_tag)" "$(p_litellm_tag)"; }
p_agents_blob()  { p_codex_fetch | p_codex_normalize; p_litellm_blob; }

# --- provider dispatch ---------------------------------------------------

# The provider is whatever the pane runs at the moment you press the key. An
# earlier design kept a per-pane tmux marker that `pi`, `cv` and `omp` set on
# entry and cleared on exit, but Ctrl-C aborts a zsh function before its last
# line, so the marker outlived the agent that wrote it. A later plain `claude`
# in that same pane then drew the LiteLLM cost view. Read the live process
# tree instead: it cannot go stale, because it is the truth.

# --- the three seams onto the process table. A test replaces all three. ---
ps_table()      { ps -axo pid=,ppid=,command=; }
pane_root_pid() { tmux display-message -pt "$1" '#{pane_pid}' 2>/dev/null; }
proc_line()     { ps -Eww -p "$1" -o command= 2>/dev/null; }

# process_tree_pids <root> : the root and every pid below it, parents first,
# so the deepest match wins. The table arrives on stdin as "pid ppid command".
process_tree_pids() {
  awk -v root="$1" '
    { pid[NR] = $1; ppid[$1] = $2 }
    END {
      seen[root] = 1; out[++n] = root
      do {
        added = 0
        for (i = 1; i <= NR; i++) {
          p = pid[i]
          if (!seen[p] && seen[ppid[p]]) { seen[p] = 1; out[++n] = p; added = 1 }
        }
      } while (added)
      for (i = 1; i <= n; i++) print out[i]
    }'
}

# classify_process <line> : the provider id of one process, or nothing when
# the process is not an agent. The line is a command line with the
# environment appended, which is what `ps -Eww` prints.
#
# `pi` and `omp` report "agents", whatever model the command line names. Both
# switch model inside a session, so the command line at the moment you press
# the key does not say which budget you are spending. The combined view shows
# both instead of guessing.
#
# `cv` is a plain `claude` binary with ANTHROPIC_BASE_URL pointed at the
# proxy, so the command alone cannot tell the two apart. The proxy always
# listens on port 4000, on localhost, on onyx, or over Tailscale. Do not test
# LITELLM_API_KEY: `_litellm_proxy` exports it into the shell, so a plain
# `claude` started later in that shell inherits it and would read as litellm.
#
# `ps -Eww` shows the environment of your own processes. It hides the
# environment of a binary that SIP protects, but no agent lives in /bin or
# /usr/bin, so this reads them all. An unreadable environment falls back to
# the subscription view, which is the safe answer.
classify_process() {
  local line=$1 bin
  line=${line#"${line%%[![:space:]]*}"}   # drop any leading padding from ps
  bin=${line%% *}; bin=${bin##*/}
  case "$line" in
    *pi-coding-agent*) printf 'agents'; return ;;
  esac
  case "$bin" in
    pi)    printf 'agents' ;;
    omp)   printf 'agents' ;;
    codex) printf 'codex'  ;;
    claude)
      case "$line" in
        *ANTHROPIC_BASE_URL=*:4000*) printf 'litellm' ;;
        *)                           printf 'claude'  ;;
      esac ;;
  esac
}

# resolve_provider : the id of the provider for the invoking pane. A pane that
# runs no agent at all — a bare shell prompt — reports the plain subscription.
resolve_provider() {
  local root='' pid id known found=''
  [ -n "${SRC_PANE:-}" ] && root=$(pane_root_pid "$SRC_PANE")
  if [[ ${root:-} =~ ^[0-9]+$ ]]; then
    while read -r pid; do
      [ -n "$pid" ] || continue
      id=$(classify_process "$(proc_line "$pid")")
      for known in $PROVIDERS; do
        [ "$id" = "$known" ] && found=$id
      done
    done < <(ps_table | process_tree_pids "$root")
    # The toggle drops a pi or omp pane back to the plain cost view, which is
    # what it drew before the Codex section existed.
    if [ -n "$found" ]; then
      if [ "$found" = agents ] && [ "$CODEX_IN_AGENTS" != 1 ]; then found=litellm; fi
      printf '%s' "$found"; return
    fi
  fi
  printf 'claude'
}

# provider_hook <hook> [args] : call the hook of the current provider. PROVIDER
# is set once by main, or by a test. A missing p_<id>_blob falls back to
# "fetch | normalize", which is what a one-command provider wants.
provider_hook() {
  local hook=$1; shift
  local fn="p_${PROVIDER}_${hook}"
  if declare -F "$fn" >/dev/null 2>&1; then "$fn" "$@"; return; fi
  case "$hook" in
    blob) "p_${PROVIDER}_fetch" | "p_${PROVIDER}_normalize" ;;
    view) printf 'quota' ;;
    title) printf '%s usage' "$PROVIDER" ;;
    tag)  printf '%s' "$PROVIDER" ;;
  esac
}

cache_path() { printf '%s/claude-usage.%s.cache' "${TMPDIR:-/tmp}" "$1"; }

# render_view <blob> <note> : hand the blob to the view of the provider.
render_view() {
  case "$(provider_hook view)" in
    cost) render_cost "$1" "$2" ;;
    both) render_both "$1" "$2" ;;
    *)    render_quota "$1" "$2" ;;
  esac
}

# view_main : draw the cache, fetch, then draw again. It knows nothing about
# any single provider.
view_main() {
  local cache; cache=$(cache_path "$PROVIDER")
  if [[ -s $cache ]]; then
    render_view "$(cat "$cache")" "(cached — refreshing…)"
  else
    clear 2>/dev/null
    echo
    render_context
    printf '  %s%s%s\n\n  %sLoading…%s\n' \
      "$c_bold" "$(provider_hook title)" "$c_reset" "$c_dim" "$c_reset"
  fi

  local fresh; fresh=$(provider_hook blob)
  if [ -n "$fresh" ]; then
    printf '%s\n' "$fresh" > "$cache"
    render_view "$fresh" ""
  fi

  echo
  printf '  %s[any key to close]%s' "$c_dim" "$c_reset"
  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null
  dd bs=1 count=1 >/dev/null 2>&1
  if [ -n "$old_stty" ]; then stty "$old_stty" 2>/dev/null; fi
}

# --- popup sizing --------------------------------------------------------
# `prefix+u` opens a popup with fixed content (a few bars), but the -w/-h of
# tmux only understand percentages of the terminal, so a wide terminal used to
# blow the popup far past what the content needs. The size comes from the blob
# in the cache instead. A view that nobody has opened yet uses a guess.

# +2 for the popup border, which eats a column on each side.
USAGE_POPUP_W=$(( ROW_FIXED_W + BAR_CAP + 2 ))   # fits a full-cap bar plus its row
COST_POPUP_W=90      # fits a full-cap 45-char bar (see the -42 offset in render_cost)
# The context section: 4 gcloud rows, 4 kube rows, and 3 rows for the rule.
CONTEXT_POPUP_H=11

# rows_in_cache <provider> <record> <fallback> : how many records of one kind
# the cached blob holds.
rows_in_cache() {
  local f; f=$(cache_path "$1")
  if [[ -s $f ]]; then
    local n; n=$(grep -c "^$2$TAB" "$f" 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] && (( n > 0 )) && { printf '%s' "$n"; return; }
  fi
  printf '%s' "$3"
}

# size_for <pane_id> : "WxH" for the view that this pane is about to draw.
size_for() {
  SRC_PANE=$1
  PROVIDER=$(resolve_provider)
  local has_sess=0
  local cache; cache=$(cache_path "$PROVIDER")
  if [[ -s $cache ]] && grep -q "^SESSION$TAB" "$cache" 2>/dev/null; then
    has_sess=4
  fi
  local ctx=0
  if declare -F context_section >/dev/null; then ctx=$CONTEXT_POPUP_H; fi
  case "$(provider_hook view)" in
    cost) printf '%dx%d' "$COST_POPUP_W" "$(( $(rows_in_cache "$PROVIDER" MODEL 6) + 14 + has_sess + ctx ))" ;;
    both) printf '%dx%d' "$USAGE_POPUP_W" \
            "$(( $(rows_in_cache "$PROVIDER" QUOTA 2) * 2 \
                 + $(rows_in_cache "$PROVIDER" MODEL 6) + 17 + has_sess + ctx ))" ;;
    *)    printf '%dx%d' "$USAGE_POPUP_W" "$(( $(rows_in_cache "$PROVIDER" QUOTA 3) * 2 + 8 + ctx ))" ;;
  esac
}

# popup_main <pane_id> <cwd> : called from the keybinding (outside any popup)
# to open the popup at the size the view needs. tmux runs the popup command
# with a shell, so each argument is quoted with %q. A directory name can hold
# quotes or $(...), and the shell must not run them.
popup_main() {
  local pane=$1 cwd=$2 sz w h
  sz=$(size_for "$pane")
  w=${sz%x*}; h=${sz#*x}
  tmux display-popup -E -w "$w" -h "$h" -d "$cwd" -T ' Status ' \
    "$(printf '%q %q %q' "$0" "$pane" "$cwd")"
}

# Pick the provider from the per-pane marker, NOT from what happens to be
# reachable — the LiteLLM proxy answers over Tailscale at all times, so a test
# of liveness would show cost even for a plain subscription session.
main() {
  SRC_PANE="${1:-}"
  SRC_PATH="${2:-}"
  # display-popup does NOT expand formats in its command string, so the
  # keybinding's #{pane_id} arrives here literally (or empty). When it isn't a
  # real pane id, self-resolve to the session's active pane — which is the pane
  # that triggered the popup.
  case "$SRC_PANE" in
    %[0-9]*) ;;
    *) SRC_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null) ;;
  esac
  PROVIDER=$(resolve_provider)
  if declare -F context_section >/dev/null; then CONTEXT_TEXT=$(context_section); fi
  view_main
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ "${1:-}" = "--popup" ]; then
    popup_main "$2" "$3"
  else
    main "$@"
  fi
fi
