#!/usr/bin/env bash
# Claude Code status line: pills for vim mode, model, effort, cost, rate limits,
# ctx and session id   …   workbench pill (right-aligned to the terminal edge)
input=$(cat)

# ── Palette ────────────────────────────────────────────────────────────────────
#
# All colors come from palette.json (sibling file; same dir in source tree and
# in ~/.claude when deployed). The workbench mod reads the same file. Each color
# becomes PAL_<path>, e.g. PAL_mode_insert_hex and PAL_mode_insert_ansi.
eval "$(jq -r 'paths(scalars) as $p | select($p[0] != "_comment")
  | "PAL_\($p | map(tostring) | join("_"))=\(getpath($p))"' \
  "$(dirname -- "${BASH_SOURCE[0]}")/palette.json" 2>/dev/null)"

# ── Vim-mode prompt border (early, so the border changes as soon as possible) ──
#
# Claude Code gives the vim mode only to the status line, and it repaints when a
# file in ~/.claude/themes/ changes. So on each mode change this rewrites the
# custom:vim-mode theme (selected in settings) with the color of the mode. The
# file is generated, not managed by chezmoi.
#
# The check starts no process, and the early return keeps the file quiet between
# mode changes. The rest of the delay is Claude Code's: its status line refresh
# and its theme file watcher.
mode=""
[[ $input =~ \"vim\"[^}]*\"mode\"[[:space:]]*:[[:space:]]*\"([A-Z_]+)\" ]] && mode=${BASH_REMATCH[1]}

# mode_color <mode> <hex|ansi>
mode_color() {
  local name
  case $1 in
    INSERT)          name=insert ;;
    VISUAL*)         name=visual ;;
    REPLACE)         name=replace ;;
    *)               name=normal ;;
  esac
  local var="PAL_mode_${name}_$2"
  printf '%s' "${!var}"
}

vim_border() {
  local dir="$HOME/.claude/themes" color file current=""
  color=$(mode_color "$1" hex)
  [ -n "$color" ] || return
  file="$dir/vim-mode.json"
  [ -f "$file" ] && IFS= read -r current < "$file"
  [[ $current == *"\"promptBorder\": \"$color\""* ]] && return
  [ -d "$dir" ] || mkdir -p "$dir"
  printf '{ "name": "Vim mode", "base": "dark-daltonized", "overrides": { "promptBorder": "%s", "promptBorderShimmer": "%s" } }\n' \
    "$color" "$color" > "$file.tmp" && mv "$file.tmp" "$file"
}
[ -n "$mode" ] && vim_border "$mode"

# LiteLLM per-session cost helper (sibling file; same dir in source tree and in
# ~/.claude when deployed).
source "$(dirname -- "${BASH_SOURCE[0]}")/statusline-cost.sh" 2>/dev/null || true

dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
[ -z "$dir" ] && dir="$PWD"

# Cost segment: only LiteLLM-routed sessions (cv) show the proxy's real
# per-session spend (ledger), overwritten below. Everything else shows no cost.
litellm_routed="false"
[ -n "${ANTHROPIC_BASE_URL:-}" ] && litellm_routed="true"
show_cost="false"

# jq pass: emit fields joined by \x01 (non-whitespace) so IFS read preserves empty fields.
# Tab (\t) collapses consecutive delimiters in bash IFS read; \x01 does not.
out=$(printf '%s' "$input" | jq -r --arg show_cost "$show_cost" --arg litellm "$litellm_routed" '
  [
    (.model.display_name // ""),
    (.effort.level // ""),
    (if $show_cost == "true" and $litellm == "false" and (.cost.total_cost_usd != null) then (.cost.total_cost_usd | tostring) else "" end),
    ((.context_window.used_percentage // 0) | tostring),
    (if .rate_limits.five_hour then (.rate_limits.five_hour.used_percentage | round | tostring) else "" end),
    (if .rate_limits.seven_day then (.rate_limits.seven_day.used_percentage | round | tostring) else "" end),
    (.session_id // "")
  ] | join("\u0001")')

IFS=$'\x01' read -r model effort cost_raw ctx_pct five_h_pct seven_d_pct session_id <<< "$out"

# LiteLLM-routed: replace the (empty) estimate slot with this session's real
# ledger spend, read from the cache (refreshed in the background by the helper).
if [ "$litellm_routed" = "true" ]; then
  cost_raw=$(litellm_session_cost "${ANTHROPIC_BASE_URL:-}" "${ANTHROPIC_AUTH_TOKEN:-}" "$session_id")
fi

# ── Pills ──────────────────────────────────────────────────────────────────────
#
# Color is for state only. The mode pill has the mode color. Every other pill is
# the surface color with light text, except for two cases:
#  - model and effort: the text runs green → red, cheap → expensive;
#  - an alarm (context ≥ 70%, a rate limit over 40%): the pill takes warn or crit.

CAP_L=$'\xee\x82\xb6'   # Nerd Font U+E0B6 and U+E0B4, as UTF-8 bytes so that any bash reads them
CAP_R=$'\xee\x82\xb4'

# pill <bg> <fg> <text>, with 256-color numbers
pill() {
  printf '\033[38;5;%sm%s\033[48;5;%sm\033[38;5;%sm%s\033[0m\033[38;5;%sm%s\033[0m' \
    "$1" "$CAP_L" "$1" "$2" "$3" "$1" "$CAP_R"
}

RAMP=("$PAL_ramp_0" "$PAL_ramp_1" "$PAL_ramp_2" "$PAL_ramp_3")   # green → red

# rank_color <value> <rank…>: place <value> on RAMP by its position in the
# ordered rank list. Each rank arg is a glob (|-separated synonyms ok). The index
# is bucketed onto the ramp via floor(idx * |RAMP| / count), so the same ramp
# stretches over however many ranks exist — append a new model/effort in cost
# order and every color auto-rebalances. Unmatched values fall through to text.
rank_color() {
  local lc; lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); shift
  local ranks=("$@") n=$# i pats pat
  for i in "${!ranks[@]}"; do
    IFS='|' read -ra pats <<< "${ranks[$i]}"   # split synonyms; |-in-case-pattern doesn't alternate from a var
    for pat in "${pats[@]}"; do
      if [[ $lc == $pat ]]; then               # unquoted RHS globs but, inside [[ ]], won't pathname-expand
        printf '%s' "${RAMP[$(( i * ${#RAMP[@]} / n ))]}"
        return
      fi
    done
  done
  printf '%s' "$PAL_text_ansi"
}

# Ordered cheap/low → pricey/high. Models match on family substring, so new
# *versions* (e.g. a future "sonnet 5") already slot in; only a brand-new family
# needs a one-token insert here.
MODEL_RANK=('*haiku*' '*sonnet*' '*opus*' '*fable*')
EFFORT_RANK=('low|minimal' 'medium|normal' 'high' 'xhigh' 'ultra|max|highest')

color_for_model()  { rank_color "$1" "${MODEL_RANK[@]}"; }
color_for_effort() { rank_color "$1" "${EFFORT_RANK[@]}"; }

# Short model label: family initial + version, dropping any "(1M context)" suffix.
# e.g. "Sonnet 4.6" → "S4.6", "Opus 4.8 (1M context)" → "O4.8". Color still comes
# from the full name, so the rank logic above is untouched. Unknown family → as-is.
model_short() {
  local lc letter ver
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    *haiku*)  letter=H ;;
    *sonnet*) letter=S ;;
    *opus*)   letter=O ;;
    *fable*)  letter=F ;;
    *)        printf '%s' "$1"; return ;;
  esac
  ver=$(printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)
  printf '%s%s' "$letter" "$ver"
}

# Effort label: two letters, as LO / ME / HI / XH / MA.
effort_short() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    low|minimal)        printf 'LO' ;;
    medium|normal)      printf 'ME' ;;
    high)               printf 'HI' ;;
    xhigh)              printf 'XH' ;;
    max|ultra|highest)  printf 'MA' ;;
    *)                  printf '%.2s' "$1" | tr '[:lower:]' '[:upper:]' ;;
  esac
}

# alarm_color <pct> <warn at> <crit at>: warn or crit once the value reaches the
# limit, else nothing.
alarm_color() {
  local pct=${1%%.*}
  [ -z "$pct" ] && return
  if   [ "$pct" -ge "$3" ]; then printf '%s' "$PAL_crit_ansi"
  elif [ "$pct" -ge "$2" ]; then printf '%s' "$PAL_warn_ansi"
  fi
}

# ── Build segments ─────────────────────────────────────────────────────────────

sep=" "
segments=()        # left side

[ -n "$mode" ] && segments+=("$(pill "$(mode_color "$mode" ansi)" "$PAL_ink_ansi" "${mode:0:1}")")

[ -n "$model"  ] && segments+=("$(pill "$PAL_surface_ansi" "$(color_for_model "$model")" "$(model_short "$model")")")
[ -n "$effort" ] && segments+=("$(pill "$PAL_surface_ansi" "$(color_for_effort "$effort")" "$(effort_short "$effort")")")

if [ -n "$cost_raw" ]; then
  cost_display=$(awk -v u="$cost_raw" 'BEGIN { printf "$%.2f", u+0 }')
  c=$(alarm_color "$cost_raw" 18 30)
  if [ -n "$c" ]; then segments+=("$(pill "$c" "$PAL_ink_ansi" "$cost_display")")
  else segments+=("$(pill "$PAL_surface_ansi" "$PAL_text_ansi" "$cost_display")"); fi
fi

# Rate-limit pills, right before ctx: S = session (5h), W = weekly (7d). Each
# appears only once its limit passes 40%: warn up to 90%, crit above.
c=$(alarm_color "$five_h_pct" 41 91);  [ -n "$c" ] && segments+=("$(pill "$c" "$PAL_ink_ansi" S)")
c=$(alarm_color "$seven_d_pct" 41 91); [ -n "$c" ] && segments+=("$(pill "$c" "$PAL_ink_ansi" W)")

c=$(alarm_color "$ctx_pct" 70 85)
if [ -n "$c" ]; then segments+=("$(pill "$c" "$PAL_ink_ansi" "${ctx_pct}%")")
else segments+=("$(pill "$PAL_surface_ansi" "$PAL_text_ansi" "${ctx_pct}%")"); fi

# Session ID, last 5 chars — enough to disambiguate panes without the clutter.
[ -n "$session_id" ] && segments+=("$(pill "$PAL_surface_dim_ansi" "$PAL_dim_ansi" "${session_id: -5}")")

# ── Workbench pill (right edge of row 1) ──────────────────────────────────────
#
# The status line builds the pill itself, so the first draw of a session shows
# it. The words and colors are those of the pill of the workbench mod
# (dot_claude/mods/workbench/hooks/pill.ts). The names come from git and from the
# directory, so the control characters are removed from them. A name then cannot
# send codes to the terminal.

wb_fg() { printf '\033[38;5;%sm' "$1"; }
wb_bg() { printf '\033[48;5;%sm' "$1"; }

# wb_hue <color> <text> : the text in a state color, then back to the text color
wb_hue() { printf '%s%s%s' "$(wb_fg "$1")" "$2" "$(wb_fg "$PAL_text_ansi")"; }

# wb_clean <name> : the name without control characters. The C0 and DEL bytes
# go first. Then the UTF-8 form of the C1 characters (U+0080 to U+009F, that is
# \xc2 and a byte from \x80 to \x9f) goes. [[:cntrl:]] does not match them in
# the C locale, so the bytes are matched here directly.
wb_clean() {
  printf '%s' "$1" | LC_ALL=C sed $'s/\xc2[\x80-\x9f]//g' | LC_ALL=C tr -d '\000-\037\177'
}

# wb_render <segment>... : the pill, with a dim dot between the segments
wb_render() {
  local i=0 s body=""
  for s in "$@"; do
    [ "$i" -gt 0 ] && body+="$(wb_fg "$PAL_dim_ansi") · "
    body+="$(wb_bg "$PAL_surface_ansi")$(wb_fg "$PAL_text_ansi")$s"
    i=$((i + 1))
  done
  printf '%s%s%s%s%s%s%s' "$(wb_fg "$PAL_surface_ansi")" "$CAP_L" "$body" $'\033[0m' \
    "$(wb_fg "$PAL_surface_ansi")" "$CAP_R" $'\033[0m'
}

# wb_pill <dir> : the pill of the directory. Outside git it shows the name only.
wb_pill() {
  local dir=$1 info status head line re top gitdir common branch worktree repo where drift=""
  local ahead=0 behind=0 changed=0 staged=0 main=0 hue ok changes text
  local items=()

  # One git call for each value. A path can hold a newline, so the values cannot
  # be split from one output.
  if ! top=$(git -C "$dir" rev-parse --path-format=absolute --show-toplevel 2>/dev/null); then
    wb_render "$(wb_clean "$(basename "$dir")") $(wb_hue "$PAL_dim_ansi" "no git")"
    return
  fi
  gitdir=$(git -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null)
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

  status=$(git -C "$dir" status --porcelain=v1 --branch 2>/dev/null)
  head=$(sed -n 1p <<< "$status")
  re='ahead ([0-9]+)'; [[ $head =~ $re ]] && ahead=${BASH_REMATCH[1]}
  re='behind ([0-9]+)'; [[ $head =~ $re ]] && behind=${BASH_REMATCH[1]}
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    changed=$((changed + 1))
    case ${line:0:1} in ' '|'?') ;; *) staged=$((staged + 1)) ;; esac
  done <<< "$(sed -n '2,$p' <<< "$status")"

  worktree=$(wb_clean "$(basename "$top")")
  repo=$(wb_clean "$(basename "${common%/.git}")")
  case $branch in main|master|develop|HEAD) main=1 ;; esac
  if [ "$gitdir" != "$common" ]; then
    where="$repo/$worktree"
  else
    hue=$PAL_dim_ansi
    [ "$main" -eq 1 ] && [ "$changed" -gt 0 ] && hue=$PAL_warn_ansi
    where="$worktree $(wb_hue "$hue" "main checkout")"
  fi
  [ "$ahead" -gt 0 ] && drift+=" $ahead unpushed"
  [ "$behind" -gt 0 ] && drift+=" $(wb_hue "$PAL_warn_ansi" "$behind behind")"
  text="$where$drift"

  if [ "$changed" -gt 0 ]; then
    ok=$PAL_warn_ansi
    [ "$staged" -eq "$changed" ] && ok=$PAL_ok_ansi
    items+=("$(wb_hue "$ok" "$staged/$changed staged")")
  fi
  [ -f "$gitdir/CLAUDE_COMMIT_MSG" ] && items+=("$(wb_hue "$PAL_ok_ansi" "msg ready")")
  [ -f "$gitdir/CLAUDE_PR_MSG" ] && items+=("$(wb_hue "$PAL_ok_ansi" "PR draft ready")")

  if [ "${#items[@]}" -gt 0 ]; then
    local IFS=' '
    changes="${items[*]}"
    wb_render "$text" "$changes"
  else
    wb_render "$text"
  fi
}

# ── Assemble ───────────────────────────────────────────────────────────────────

# join <sep> <elements…> → joined string
join_segs() {
  local s=$1; shift
  local out="" i
  for i in "$@"; do
    [ -z "$out" ] && out="$i" || out="${out}${s}${i}"
  done
  printf '%s' "$out"
}

# Deliberately 256-color (not 24-bit) and NO trailing newline:
#  - tmux here reports RGB=no, so a truecolor SGR gets re-downsampled every
#    repaint; an explicit 256-color code is tmux-native and stable per frame.
#  - a trailing \n makes Claude Code treat this as a 2-line status and redraw
#    both rows, which flickers/duplicates during generation.
left=$(join_segs "$sep" "${segments[@]}")
right=$(wb_pill "$dir")

# Right-align the workbench pill (repository/worktree and changes) to the
# terminal edge. The PR is on the next row: the mod adds it to the end of the
# hint row of Claude Code. Claude Code exports COLUMNS before running this
# script (tput cols does NOT work here — output is captured, not attached to a
# tty). Visible width ignores ANSI SGR codes. If both sides can't share one
# line, append inline instead so the status never wraps to a second row (a
# wrapped status flickers — same reason we avoid a trailing \n).
visible_len() {
  # A UTF-8 locale makes ${#s} count each Nerd Font glyph of a pill as one.
  local LC_ALL=en_US.UTF-8 s; s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  printf '%s' "${#s}"
}

RMARGIN=6   # columns kept blank at the right edge. Must cover Claude Code's built-in
            # status indent + a wrap-safety column, else the branch truncates. Bump higher
            # if the rightmost text still gets cut; lower it to sit closer to the edge.

if [ -n "$right" ] && [ "${COLUMNS:-0}" -gt 0 ]; then
  pad=$(( COLUMNS - RMARGIN - $(visible_len "$left") - $(visible_len "$right") ))
  if [ "$pad" -ge 1 ]; then
    printf '%s%*s%s' "$left" "$pad" "" "$right"
  else
    printf '%s%s%s' "$left" "$sep" "$right"   # too narrow to right-align; keep inline
  fi
elif [ -n "$right" ]; then
  printf '%s%s%s' "$left" "$sep" "$right"
else
  printf '%s' "$left"
fi
