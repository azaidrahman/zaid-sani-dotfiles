# Turbo-loaded plugins (deferred via wait ice)
zinit ice wait lucid
zinit light zsh-users/zsh-syntax-highlighting
zinit ice wait lucid
zinit light zsh-users/zsh-autosuggestions
zinit ice wait lucid
zinit light zsh-users/zsh-completions
zinit ice wait lucid
zinit light Aloxaf/fzf-tab
zinit light jeffreytse/zsh-vi-mode
# NVM is disabled (see exports.zsh), no need for lazy-load wrapper
# zinit light undg/zsh-nvm-lazy-load

# Add in plugins
# zinit snippet OMZP::sudo
# added this lib thing for git_current_branch and other functions
zinit snippet OMZ::lib/git.zsh
zinit snippet OMZP::command-not-found
zinit snippet OMZP::git
# `als [word]` prints your aliases grouped and explained. OMZ ships this as a
# single file, but the command shells out to a sibling cheatsheet.py (not fetched
# by a one-file snippet) and needs the python `termcolor` module — so grab both
# on (re)clone. atclone/atpull run in the snippet dir, where cheatsheet.py belongs.
zinit ice lucid \
  atclone'curl -sSfL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/plugins/aliases/cheatsheet.py -o cheatsheet.py; python3 -m pip install -q termcolor' \
  atpull'%atclone'
zinit snippet OMZP::aliases

# Completion-heavy OMZ plugins — turbo-deferred (wait lucid) to keep startup fast.
# Their compdefs are queued and applied by `zinit cdreplay` below.
zinit ice wait lucid
zinit snippet OMZP::kubectl
zinit ice wait lucid
zinit snippet OMZP::gcloud

# fzf + zoxide init scripts cached (each subprocess costs ~15-20ms);
# rebuilt when the binary is newer than its cache.
_init_cached() {  # _init_cached <cmd> <cache-name> <gen-cmd...>
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/$2"
  if [[ ! -f "$cache" ]] || [[ "${commands[$1]:A}" -nt "$cache" ]]; then
    mkdir -p "${cache:h}"
    "${@:3}" > "$cache"
  fi
  source "$cache"
}
_init_cached fzf fzf-init.zsh fzf --zsh
# zoxide: --cmd cd variant deliberately not used (see git history)
_init_cached zoxide zoxide-init.zsh zoxide init zsh

# Atuin keeps the shell history in a SQLite database, with search and sync.
# run_once_after_install-atuin.sh installs the binary in ~/.atuin/bin. Atuin is
# not in the Brewfile, because the project ships its own installer and updater.
# Source the env file first, because it puts ~/.atuin/bin on PATH.
[[ -r "$HOME/.atuin/bin/env" ]] && source "$HOME/.atuin/bin/env"
if (( $+commands[atuin] )); then
  # --disable-up-arrow keeps the Up key on the normal zsh history. Ctrl+R is
  # the only key that opens the atuin search.
  _init_cached atuin atuin-init.zsh atuin init zsh --disable-up-arrow

  # Atuin binds Ctrl+R in the viins and emacs keymaps only. In vicmd it binds
  # `/` instead. Bind Ctrl+R in vicmd too, so that the key opens atuin in every
  # vi mode. fzf does not compete here: FZF_CTRL_R_COMMAND is empty in
  # exports.zsh, which stops the fzf Ctrl+R binding.
  _atuin_bind_ctrl_r() {
    bindkey -M emacs '^R' atuin-search
    bindkey -M viins '^R' atuin-search-viins
    bindkey -M vicmd '^R' atuin-search-vicmd
  }
  _atuin_bind_ctrl_r

  # zsh-vi-mode rebuilds the keymaps in zvm_init, and it delays zvm_init until
  # the first prompt. Bind Ctrl+R again after that step, so that the order of
  # the plugins cannot take Ctrl+R away.
  zvm_after_init_commands+=(_atuin_bind_ctrl_r)
fi

unfunction _init_cached

# Google cloud completion (hardcoded brew prefix to avoid slow brew --prefix call)
source "/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc"

# Kubectl completion — cached to avoid slow `kubectl completion zsh` on every shell start.
# Regenerate with: rm ~/.cache/kubectl-completion.zsh
if command -v kubectl >/dev/null 2>&1; then
  _kubectl_cache="${XDG_CACHE_HOME:-$HOME/.cache}/kubectl-completion.zsh"
  if [[ ! -f "$_kubectl_cache" ]] || [[ "$(command -v kubectl)" -nt "$_kubectl_cache" ]]; then
    mkdir -p "${_kubectl_cache:h}"
    kubectl completion zsh > "$_kubectl_cache"
  fi
  source "$_kubectl_cache"
  unset _kubectl_cache
fi

# Replay compdefs captured from turbo-deferred plugins (zsh-completions,
# fzf-tab). They call `compdef` AFTER the early compinit in launch.zsh, so
# zinit queues those calls; cdreplay applies them in one pass.
zinit cdreplay -q

#
# zinit ice wait"2" as"command" from"gh-r" lucid \
#   mv"zoxide*/zoxide -> zoxide" \
#   atclone"./zoxide init zsh > init.zsh" \
#   atpull"%atclone" src"init.zsh" nocompile'!'
# zinit light ajeetdsouza/zoxide

# enable help in zsh
# unalias run-help 2>/dev/null
# autoload -Uz run-help
