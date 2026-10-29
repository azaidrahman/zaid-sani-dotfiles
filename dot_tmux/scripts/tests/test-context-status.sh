#!/usr/bin/env bash
# Unit tests for the consolidated context-status popup.
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../popups" && pwd)/executable_context-status.sh"
fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Sourcing the script must NOT run the popup (no stdout, exit 0).
out=$( source "$SCRIPT" 2>/dev/null; echo "SOURCED_OK" )
check "source is side-effect free" "SOURCED_OK" "${out##*$'\n'}"

source "$SCRIPT" 2>/dev/null   # bring parsing/render functions into scope

# A fixed clock. Every countdown below is derived from it.
export FAKE_NOW=1782129600
HOUR=3600
SESSION=$(( GCLOUD_SESSION_HOURS * HOUR ))

get() { printf '%s\n' "$1" | awk -v k="$2" '$1==k{ $1=""; sub(/^ /,""); print; exit }'; }

# --- parse_gcloud_config ------------------------------------------------
INI=$'[core]\naccount = jane.doe@example.com\nproject = my-project-123\ndisable_usage_reporting = False'
blob=$(parse_gcloud_config "$INI")
check "full unmasked account extracted" "jane.doe@example.com" "$(get "$blob" ACCOUNT)"
check "project extracted"               "my-project-123"       "$(get "$blob" PROJECT)"

blob_empty=$(parse_gcloud_config "")
check "empty ini -> empty account" "" "$(get "$blob_empty" ACCOUNT)"
check "empty ini -> empty project" "" "$(get "$blob_empty" PROJECT)"

# --- parse_kube_context --------------------------------------------------
KUBECFG=$'apiVersion: v1\ncurrent-context: gke_myproj_us-central1_gtech-svc-obs-prd\nkind: Config'
check "full context extracted, no stopword stripping" \
  "gke_myproj_us-central1_gtech-svc-obs-prd" "$(parse_kube_context "$KUBECFG")"

check "empty kubeconfig -> empty context" "" "$(parse_kube_context "")"
check "an unset context -> empty context" "" "$(parse_kube_context 'current-context: ""')"

# --- parse_kube_namespace --------------------------------------------------
# contexts is the last key here, so the last entry ends at the end of the text.
KUBECFG_NS=$'apiVersion: v1\ncurrent-context: ctx-a\ncontexts:
- context:\n    cluster: a\n    namespace: argocd\n    user: a\n  name: ctx-a
- context:\n    cluster: b\n    user: b\n  name: ctx-b
- name: ctx-c\n  context:\n    cluster: c\n    namespace: "web"'
while IFS='|' read -r label ctx want; do
  check "$label" "$want" "$(parse_kube_namespace "$KUBECFG_NS" "$ctx")"
done <<'EOF'
the namespace of the context in kubectl order|ctx-a|argocd
a context without a namespace has none|ctx-b|
name first, a quoted value, and the last entry|ctx-c|web
an unknown context has none|ctx-x|
EOF

# --- parse_kube_parts ------------------------------------------------------
while IFS='|' read -r label ctx want; do
  check "$label" "$want" "$(parse_kube_parts "$ctx" | tr '\n' ' ' | sed 's/ $//')"
done <<'EOF'
a gke context splits into its parts|gke_myproj_us-central1_obs-prd|TYPE gke PROJECT myproj CLUSTER obs-prd
a connect gateway context splits too|connectgateway_myproj_us-central1_obs-prd|TYPE connectgateway PROJECT myproj CLUSTER obs-prd
another context has no parts|minikube|
EOF

# --- render_gcloud --------------------------------------------------------
strip() { sed $'s/\033\\[[0-9;]*m//g'; }

blob=$(parse_gcloud_config "$INI")
out=$(render_gcloud "work" "$blob" "" | strip)
check "render shows configuration name" "1" "$(printf '%s\n' "$out" | grep -c 'config: work')"
check "render shows full unmasked account" "1" "$(printf '%s\n' "$out" | grep -c 'jane.doe@example.com')"
check "render shows project"            "1" "$(printf '%s\n' "$out" | grep -c 'my-project-123')"

out_empty=$(render_gcloud "default" "$(parse_gcloud_config "")" "" | strip)
check "render gcloud fallback when not configured" "1" \
  "$(printf '%s\n' "$out_empty" | grep -c 'not configured')"

# --- session_from_logins ---------------------------------------------------
# Only a login after the end of the last session starts a new one. A re-login
# inside a session does not extend it.
while IFS='|' read -r label logins want; do
  got=$(printf '%s\n' $logins | session_from_logins | tr '\n' ' ')
  check "$label" "$want" "${got% }"
done <<EOF
one login starts the session|1000|START 1000 LATEST 1000
a re-login inside the session keeps the start|1000 8200|START 1000 LATEST 8200
a login after the session ended starts a new one|1000 $(( 1000 + SESSION ))|START $(( 1000 + SESSION )) LATEST $(( 1000 + SESSION ))
no login gives no session||
EOF

# --- render_session --------------------------------------------------------
session_blob() { printf 'START %s\nLATEST %s\n' "$1" "$2"; }

start=$(( FAKE_NOW - 3 * HOUR ))
out=$(render_session "$(session_blob "$start" "$start")" | strip)
check "an active session shows the time left" "1" "$(printf '%s\n' "$out" | grep -c '✓ 13h 0m left · ends')"
check "a single login has no re-login note"   "0" "$(printf '%s\n' "$out" | grep -c 'did not extend')"

out=$(render_session "$(session_blob "$start" "$(( start + HOUR ))")" | strip)
check "a re-login says it did not extend the session" "1" \
  "$(printf '%s\n' "$out" | grep -c 'did not extend it')"

out=$(render_session "$(session_blob "$(( FAKE_NOW - SESSION + HOUR ))" "$(( FAKE_NOW - SESSION + HOUR ))")")
check "under two hours left the line turns yellow" "1" \
  "$(printf '%s\n' "$out" | grep -c $'\033\\[33m✓ 1h 0m left')"

out=$(render_session "$(session_blob "$(( FAKE_NOW - SESSION - 1 ))" "$(( FAKE_NOW - SESSION - 1 ))")" | strip)
check "an ended session asks for a login" "1" "$(printf '%s\n' "$out" | grep -c '✗ ended .* run gcloud auth login')"

out=$(render_session "" | strip)
check "no session asks for a login" "1" "$(printf '%s\n' "$out" | grep -c 'no login found')"

# --- render_kube -----------------------------------------------------------
out=$(render_kube "gke_myproj_us-central1_gtech-svc-obs-prd" | strip)
check "render shows the project first" "1" "$(printf '%s\n' "$out" | sed -n 1p | grep -c 'project  myproj$')"
check "render shows the cluster and the type second" "1" \
  "$(printf '%s\n' "$out" | sed -n 2p | grep -c 'cluster  gtech-svc-obs-prd  (gke)$')"
check "render shows default when the namespace is not set" "1" \
  "$(printf '%s\n' "$out" | sed -n 3p | grep -c 'ns       default$')"
check "render shows the full context last" "1" \
  "$(printf '%s\n' "$out" | sed -n 4p | grep -c 'gke_myproj_us-central1_gtech-svc-obs-prd')"
check "render shows only the context when it has no parts" "1" \
  "$(render_kube minikube | strip | grep -c 'kube     minikube$')"

out_empty=$(render_kube "" | strip)
check "render kube fallback when no context" "1" \
  "$(printf '%s\n' "$out_empty" | grep -c 'no current-context')"

# --- main(): end-to-end with fixture config dirs, no real gcloud/kube ------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"   # the session cache goes here, not in the real TMPDIR

mkdir -p "$TMP/gcloud/configurations"
echo -n "work" > "$TMP/gcloud/active_config"
cat > "$TMP/gcloud/configurations/config_work" <<'EOF'
[core]
account = jane.doe@example.com
project = my-project-123
EOF

# The same order of keys as kubectl writes.
cat > "$TMP/kubeconfig" <<'EOF'
apiVersion: v1
contexts:
- context:
    cluster: gke_myproj_us-central1_gtech-svc-obs-prd
    namespace: argocd
    user: gke_myproj_us-central1_gtech-svc-obs-prd
  name: gke_myproj_us-central1_gtech-svc-obs-prd
current-context: gke_myproj_us-central1_gtech-svc-obs-prd
kind: Config
EOF

out=$(printf 'x' | GCLOUD_CONFIG_DIR="$TMP/gcloud" KUBECONFIG="$TMP/kubeconfig" bash "$SCRIPT" | strip)
check "main shows gcloud account"  "1" "$(printf '%s\n' "$out" | grep -c 'jane.doe@example.com')"
check "main shows gcloud project"  "1" "$(printf '%s\n' "$out" | grep -c 'my-project-123')"
check "main shows kube context"    "1" "$(printf '%s\n' "$out" | grep -c 'gke_myproj_us-central1_gtech-svc-obs-prd')"
check "main shows kube namespace"  "1" "$(printf '%s\n' "$out" | grep -c 'ns       argocd$')"
check "main shows close hint"      "1" "$(printf '%s\n' "$out" | grep -c '\[any key to close\]')"

# fake_login <HH:MM:SS> : what `gcloud auth login` leaves behind at that time
# on 2026-10-29: a log in local time, and a new time on the credential file.
LOGS="$TMP/gcloud/logs/2026.10.29"
CRED="$TMP/gcloud/legacy_credentials/jane.doe@example.com/adc.json"
fake_login() {
  mkdir -p "$LOGS" "${CRED%/*}"
  printf '%s\n' \
    "2026-10-29 $1,615 DEBUG    root            Running [gcloud.auth.login] with arguments: []" \
    "2026-10-29 $1,046 INFO     ___FILE_ONLY___" \
    "You are now logged in as [jane.doe@example.com]." > "$LOGS/${1//:/.}.000000.log"
  touch -t "20261029$(printf '%s' "${1%:*}" | tr -d :).${1##*:}" "$CRED"
}
epoch_at() { date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-29 $1" +%s; }
show() { printf 'x' | FAKE_NOW=$1 GCLOUD_CONFIG_DIR="$TMP/gcloud" KUBECONFIG="$TMP/kubeconfig" bash "$SCRIPT" | strip; }

fake_login 10:48:21
login=$(epoch_at 10:48:21)
check "main reads the session from the login log" "1" \
  "$(show $(( login + 3 * HOUR )) | grep -c '✓ 13h 0m left')"

# The tmux alert shows only when the session has ended.
alert() { FAKE_NOW=$1 GCLOUD_CONFIG_DIR="$TMP/gcloud" bash "$SCRIPT" --tmux-alert; }
check "the tmux alert is empty in a live session" "" "$(alert $(( login + 3 * HOUR )))"
check "the tmux alert is red after the session ends" "#[fg=#ffffff,bg=#ff0000,bold] ✗ gcloud not authed #[default]" \
  "$(alert $(( login + SESSION )))"

# Each login gives the credential file a new time. While that time stays the
# same, the session comes from the cache and the logs are not read again.
rm -rf "$LOGS"
fake_login 11:48:21
touch -t 202610291048.21 "$CRED"
check "an unchanged credential file reuses the cached session" "1" \
  "$(show $(( login + 3 * HOUR )) | grep -c '✓ 13h 0m left')"

# Without a login log, the time of the credential file starts the session.
rm -rf "$LOGS"
touch -t 202610290948.21 "$CRED"
check "main falls back to the credential file" "1" \
  "$(show $(( login + 3 * HOUR )) | grep -c '✓ 12h 0m left')"

# Missing config dirs -> both fallbacks, no crash
out=$(printf 'x' | GCLOUD_CONFIG_DIR="$TMP/no-such-dir" KUBECONFIG="$TMP/no-such-kubeconfig" bash "$SCRIPT" | strip)
check "main gcloud fallback when unconfigured" "1" "$(printf '%s\n' "$out" | grep -c 'not configured')"
check "main kube fallback when unconfigured"   "1" "$(printf '%s\n' "$out" | grep -c 'no current-context')"

exit $fail
