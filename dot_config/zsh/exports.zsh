export PATH="/opt/homebrew/bin:$PATH"
# export PATH="$HOME/.npm-global/bin:$PATH"
export XDG_CONFIG_HOME="$HOME/.config"

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$HOME/.local/bin:$PATH"
[[ -d $PYENV_ROOT/bin ]] && export PATH="PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh)"

if [ -n "$NVIM_LISTEN_ADDRESS" ]; then
    export VISUAL="nvr -cc split --remote-wait +'set bufhidden=wipe'"
    export EDITOR="nvr -cc split --remote-wait +'set bufhidden=wipe'"
else
    export VISUAL="nvim"
    export EDITOR="nvim"
fi

# export NVM_DIR="$HOME/.nvm"
# [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"  # This loads nvm
# [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"  # This loads nvm bash_completion

# The next line updates PATH for the Google Cloud SDK.
if [ -f '/Users/zaid/Downloads/google-cloud-sdk/path.zsh.inc' ]; then . '/Users/zaid/Downloads/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '/Users/zaid/Downloads/google-cloud-sdk/completion.zsh.inc' ]; then . '/Users/zaid/Downloads/google-cloud-sdk/completion.zsh.inc'; fi

## COMMON VARIABLES
export EDITOR="nvim"
export VISUAL="nvim"
export SUDO_EDITOR="nvim"
export FCEDITOR="nvim"
export TERMINAL="Ghostty"
# export ZUNO="/Users/zaid/Library/Mobile Documents/com~apple~CloudDocs/ZUNO/"
# export BROWSER="app.zen-browser.zen"
#
export FZ_DEFAULT_COMMAND='rg —files —hidden -g !.git/'

# GOLANG
export PATH="$PATH:$HOME/go/bin"

# 1password
export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock

export STARSHIP_CONFIG="$HOME/.config/zsh/starship.toml"

