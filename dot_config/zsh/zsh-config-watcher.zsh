# zsh-config-watcher.zsh
# Detects changes to zsh config files and prompts to reload the shell.
# Checks on startup AND periodically via precmd (catches tmux pane switches).
# Source this from your .zshrc

# Cooldown in seconds between checks (avoids hashing on every prompt)
ZSH_CONFIG_WATCH_INTERVAL=${ZSH_CONFIG_WATCH_INTERVAL:-30}
# ZSH_CONFIG_WATCH_INTERVAL=${ZSH_CONFIG_WATCH_INTERVAL:-5}

__zsh_config_watcher_last_check=0
__zsh_config_watcher_prompted=0

__zsh_config_compute_checksum() {
  local checksum_cmd
  if command -v shasum &>/dev/null; then
    checksum_cmd="shasum"
  elif command -v sha256sum &>/dev/null; then
    checksum_cmd="sha256sum"
  else
    return 1
  fi

  (
    {
      [[ -f "$HOME/.zshrc" ]] && $checksum_cmd "$HOME/.zshrc"
      if [[ -d "$HOME/.config/zsh" ]]; then
        find "$HOME/.config/zsh" -type f -not -name '.*' | sort | while read -r f; do
          $checksum_cmd "$f"
        done
      fi
    } 2>/dev/null | $checksum_cmd | awk '{print $1}'
  )
}

__zsh_config_watcher_check() {
  local now=${EPOCHSECONDS:-$(date +%s)}

  # Throttle: skip if checked recently
  if (( now - __zsh_config_watcher_last_check < ZSH_CONFIG_WATCH_INTERVAL )); then
    return
  fi
  __zsh_config_watcher_last_check=$now

  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-config-checksums"
  local current_checksum
  current_checksum=$(__zsh_config_compute_checksum) || return

  # First run — save baseline
  if [[ ! -f "$cache_file" ]]; then
    mkdir -p "$(dirname "$cache_file")"
    echo "$current_checksum" > "$cache_file"
    return
  fi

  local saved_checksum
  saved_checksum=$(<"$cache_file")

  if [[ "$current_checksum" != "$saved_checksum" ]]; then
    # Don't prompt again if already prompted in this shell session
    if (( __zsh_config_watcher_prompted )); then
      return
    fi
    __zsh_config_watcher_prompted=1

    echo "\033[1;33m⚡ Zsh config changes detected in ~/.zshrc or ~/.config/zsh/\033[0m"
    read -q "reply?   Reload shell now? (y/n) " || true
    echo
    if [[ "$reply" == "y" ]]; then
      # Update checksum before reload so the new shell starts clean
      echo "$current_checksum" > "$cache_file"
      exec zsh
    fi
  else
    # Config matches cache — reset prompted flag (user may have reloaded another way)
    __zsh_config_watcher_prompted=0
  fi
}

# Run on initial source (new shell)
__zsh_config_watcher_check

# Register precmd hook for existing shells (tmux pane switches, etc.)
autoload -Uz add-zsh-hook
add-zsh-hook precmd __zsh_config_watcher_check
