#!/usr/bin/env bash
# The upload step of prefix+v in Rex (special_paste.lua).
#
#   special-paste.sh <ssh pid>
#
# The script sends the clipboard image to the host of an ssh process. It
# uses the same ssh options as that process, so `ssh -p 2222 -J jump onyx`
# also works. Then it prints the path of the image on that host. The Lua
# action pastes the path into the pane.
#
# This is the same upload as clipssh (~/.local/bin/clipssh), with two
# differences:
#
#   - The script does not change the clipboard. The image stays on it.
#   - The script finds the host from the ssh process, not from an argument.
#
# Exit status:
#
#   0  the upload is done. stdout holds the remote path.
#   3  the clipboard holds no image. The action does a normal paste.
#   1  an error. stderr holds one line that tells why.
#
# The Rex server runs the script with only the system directories in PATH.
# Thus add the directories of pngpaste at the end. A test puts its stubs
# first in PATH.
set -uo pipefail

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

NO_IMAGE=3

pid=${1:?ssh pid required}

# These ssh options take a value. In OpenSSH, an option letter and its value
# can be one word (-p2222) or two words (-p 2222).
VALUE_OPTS=BbcDEeFIiJLlmOoPpQRSWw
# Drop these options that take a value: the port forwards (D L R W), the
# control command (O) and the query (Q). The upload needs none of them, and a
# second forward of the same port fails.
DROP_VALUE_OPTS=DLROQW
# Drop these flags: -f (background), -M (control master), -N (no command),
# -n (stdin from /dev/null), -s (subsystem), -T and -t (a terminal). Each of
# them stops the upload, or makes it wait.
DROP_FLAGS=fMNnsTt

# parse_ssh ARGS — set SSH_OPTS to the options to keep and DEST to the
# destination. ARGS are the words after "ssh". The destination is the first
# word that is not an option or the value of an option.
parse_ssh() {
  SSH_OPTS=()
  DEST=""
  local i=0 n=$# word rest c value
  local -a words=("$@")
  while ((i < n)); do
    word=${words[i]}
    i=$((i + 1))
    if [[ $word == -- ]]; then
      DEST=${words[i]:-}
      return
    fi
    if [[ $word != -?* ]]; then
      DEST=$word
      return
    fi
    rest=${word#-}
    while [[ -n $rest ]]; do
      c=${rest:0:1}
      rest=${rest:1}
      if [[ $VALUE_OPTS == *"$c"* ]]; then
        if [[ -n $rest ]]; then
          value=$rest
          rest=""
        else
          value=${words[i]:-}
          i=$((i + 1))
        fi
        [[ $DROP_VALUE_OPTS == *"$c"* ]] || SSH_OPTS+=("-$c" "$value")
      else
        [[ $DROP_FLAGS == *"$c"* ]] || SSH_OPTS+=("-$c")
      fi
    done
  done
}

# Read the clipboard first. If it holds no image, the action does a normal
# paste, and the script does not need ssh.
tmp=$(mktemp "${TMPDIR:-/tmp}/special-paste.XXXXXX")
trap 'rm -f "$tmp" "$tmp.err"' EXIT
if ! pngpaste "$tmp" >/dev/null 2>&1 || [[ ! -s $tmp ]]; then
  exit "$NO_IMAGE"
fi

# ps gives the command line as one string. Words split on spaces, so an
# option value with a space does not work. Host names and ports have none.
args=$(ps -o args= -p "$pid" 2>/dev/null) || {
  echo "the ssh process $pid is gone" >&2
  exit 1
}
# shellcheck disable=SC2086 # split the command line into words
set -- $args
shift # the word "ssh"
parse_ssh "$@"
if [[ -z $DEST ]]; then
  echo "no host in the ssh command: $args" >&2
  exit 1
fi

dir=${CLIPSSH_REMOTE_DIR:-/tmp}
remote="$dir/clipboard-$(date +%s)-$RANDOM.png"

# BatchMode stops a password prompt: the script has no terminal. umask 077
# keeps the image at mode 0600 on the host, as clipssh does.
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$DEST" \
  "umask 077 && mkdir -p '$dir' && cat > '$remote'" <"$tmp" 2>"$tmp.err"; then
  echo "the upload to $DEST failed: $(tail -n 1 "$tmp.err")" >&2
  exit 1
fi

printf '%s' "$remote"
