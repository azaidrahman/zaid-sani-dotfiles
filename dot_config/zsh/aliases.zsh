alias l='lazygit'
# alias bdinit='borders active_color=0xFFFF0000 inactive_color=0xff494d64 width=10.0 &'
alias py='python3'
alias n="nvim"
# alias claude="/Users/zaid/.claude/local/claude"
alias opr="op run --"
alias cz="chezmoi"
alias czm="tree -L 2 -- $(chezmoi source-path)" # Simpler chezmoi managed
alias uvoprun='op run --env-file=.env -- uv run main.py'

alias oc="opencode"
alias c="claude"
alias cres="claude --resume" 

alias cl="gcloud"

alias st="speedtest -A"
alias tm="tmux attach -t main"
alias tma="tmux attach -t"

alias ld="eza -lD"
alias lf="eza -lf --color=always | grep -v /"
alias lh="eza -dl .* --group-directories-first"
alias ll="eza -al --group-directories-first"
# alias ls="eza -alf --color=always --sort=size | grep -v /"
alias ls="eza -al --color=always --sort=size"
alias lt="eza -al --sort=modified"

alias setalias="nvim ~/.config/zsh/aliases.zsh"

alias tf="terraform"

alias cat="bat"

alias unblock="xattr -d com.app.quarantine"

# temp gcloud logout
alias gcloud-tlo='export CLOUDSDK_CONFIG=$(mktemp -d)'
alias neog='nvim -c Neogit'

# alias help='run-help'
