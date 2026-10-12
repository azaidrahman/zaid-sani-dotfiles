# ~/.config/zsh/completions.zsh
#
# Single home for shell completion config that *we* own.
#
# Where completion lives (the whole picture):
#   launch.zsh        the engine — autoload + cached `compinit` (24h rebuild,
#                     `-C` fast path). Do NOT duplicate compinit here.
#   plugins.zsh       plugin-provided completions (zsh-completions, fzf-tab)
#                     plus `zinit cdreplay -q`, which replays the compdefs that
#                     those turbo-deferred plugins register after compinit.
#   completions.zsh   (this file) completion *styling* (zstyle), our own custom
#                     compdefs, and lazily-loaded per-tool completions.
#
# Lazy-load pattern:
#   `_lazy_completion <cmd> '<code>'` defines a thin wrapper for <cmd>. The first
#   time you RUN <cmd>, the wrapper removes itself, runs <code> to load the real
#   completion, then execs <cmd>. Tradeoff: `<cmd> <TAB>` does nothing until
#   you've invoked <cmd> once this session. Worth it — these loaders are slow
#   (they shell out to the tool) and most shells never touch most of them.
#
# Add a new tool completion:
#   zsh-native (tool prints a compdef/_tool script):
#       _lazy_completion mytool 'source <(mytool completion zsh)'
#   bash-style (tool uses `complete -C`): call _ensure_bashcompinit first:
#       _lazy_completion mytool '_ensure_bashcompinit; complete -C /path mytool'

# --- helpers ---------------------------------------------------------------

# Lazy-load a command's completion on first invocation.
#   $1 = command name, $2 = code that loads its completion.
_lazy_completion() { eval "$1() { unfunction $1; $2; $1 \"\$@\"; }"; }

# Run bashcompinit at most once (needed by `complete -C` style completions).
_ensure_bashcompinit() {
    (( ${+_lazy_bashcompinit} )) && return
    autoload -U +X bashcompinit && bashcompinit
    _lazy_bashcompinit=1
}

# --- styles ----------------------------------------------------------------

zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors '${(s.:.)LS_COLORS}'
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'

# --- custom compdefs (cheap, eager) ----------------------------------------

# `git ship` alias (defined in ~/.gitconfig); git auto-discovers _git-<sub>.
_git-ship() { _arguments '1: :__git_branch_names'; }

# gwtcd: complete on git worktree basenames.
_gwtcd() {
    local -a names
    names=(${(f)"$(git worktree list 2>/dev/null | awk '{print $1}' | xargs -n1 basename)"})
    _describe 'worktree' names
}
compdef _gwtcd gwtcd

# bun: static completion file, cheap to source eagerly.
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# chezmoi + cz: static completion file at completions/_chezmoi (see launch.zsh
# fpath), autoloaded by compinit's normal fpath scan. No eager subprocess and
# no lazy-load gap: `chezmoi <TAB>` and `cz <TAB>` both work from a fresh
# shell, since `#compdef chezmoi cz` on that file's first line registers both
# names against the same _chezmoi function.

# --- lazy tool completions -------------------------------------------------

# bkt and jira had entries here. Both CLIs were replaced by twg. twg ships no
# `completion` subcommand, so its completion is a static file at
# completions/_twg that builds itself from `twg --help`. See that file.
_lazy_completion argocd    'source <(argocd completion zsh)'
_lazy_completion jj        'source <(jj util completion zsh)'
_lazy_completion labctl    'source <(labctl completion zsh)'
_lazy_completion exercism  'source <(exercism completion zsh)'
_lazy_completion helm  'source <(helm completion zsh)'
_lazy_completion wacli     'source <(wacli completion zsh)'
_lazy_completion docker    'fpath=("$HOME/.docker/completions" $fpath); autoload -Uz _docker && compdef _docker docker'
_lazy_completion terraform '_ensure_bashcompinit; complete -o nospace -C /opt/homebrew/bin/terraform terraform'
_lazy_completion terramate '_ensure_bashcompinit; complete -o nospace -C /opt/homebrew/bin/terramate terramate'
