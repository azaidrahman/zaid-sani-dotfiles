# function to run yazi with the current directory as the cwd
function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
	yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
	rm -f -- "$tmp"
}

# function to open nvim using zoxide
function v() {
    local file="$1"
    # local path=$(zoxide query -l | xargs -I {} find {} -name "$file" -type f 2>/dev/null | head -n 1)
    local target=$(zoxide query "$file")

    if [ -n "$target" ]; then
        nvim "$target"
    else
        echo "File not found: $target"
    fi
}

# function to read 1password entries
function env-op() {
    local search="$*"
    local keys_string values_string

    keys_string=$(op item get --fields label=username "$search")   || return
    values_string=$(op item get --reveal --fields label=credential "$search") || return


    local -a keys values
    keys=( ${(s: :)keys_string} )
    values=( ${(s: :)values_string} )

    local last_value=""
    for (( i = 1; i <= $#keys; i++ )); do
        [[ -n $values[i] ]] && last_value=$values[i]
        export "${keys[i]}"="$last_value"
        print -u 2 "Loaded ${keys[i]}"
    done
}
