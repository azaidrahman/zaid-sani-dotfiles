#!/usr/bin/env zsh
# Smoke tests for ,kgt. Run with: zsh tests/test-kgt.zsh
# The tests use a private kubeconfig and only run `kubectl config`, so they
# do not connect to a cluster.
emulate -LR zsh
set -euo pipefail

repo_root=${0:A:h:h}
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export KUBECONFIG="$tmpdir/kubeconfig" XDG_CACHE_HOME="$tmpdir/cache"
cat >"$KUBECONFIG" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: c
  cluster: {server: "https://127.0.0.1:1"}
users:
- name: u
  user: {token: x}
contexts:
- {name: connectgateway_proj1_asia-southeast1_one, context: {cluster: c, user: u}}
- {name: gke_proj1_asia-southeast1-a_one, context: {cluster: c, user: u}}
- {name: connectgateway_proj2_asia-southeast1_two, context: {cluster: c, user: u}}
- {name: gke_proj2_asia-southeast1_two, context: {cluster: c, user: u}}
- {name: gke_proj3_asia-southeast1_three, context: {cluster: c, user: u}}
- {name: minikube, context: {cluster: c, user: u}}
current-context: minikube
EOF

fpath=("$repo_root/dot_config/zsh/functions" $fpath)
autoload -Uz ,kgt

function fail() {
  print -u2 -r -- "FAIL: $1"
  exit 1
}

function assert_eq() {
  [[ "$2" == "$3" ]] || fail "$1"$'\n'"  expected: $2"$'\n'"  actual:   $3"
}

# A gke_ context with a connectgateway_ twin is hidden, also when the gke_
# name has a zone and the twin has a region.
assert_eq "contexts hides a gke_ context that has a twin" \
  "connectgateway_proj1_asia-southeast1_one connectgateway_proj2_asia-southeast1_two gke_proj3_asia-southeast1_three minikube" \
  "${(j: :)${(f)"$(,kgt contexts)"}}"

,kgt use one >/dev/null
assert_eq "a fragment selects from the visible contexts" \
  "connectgateway_proj1_asia-southeast1_one" "$(kubectl config current-context)"

,kgt use gke_proj1_asia-southeast1-a_one >/dev/null
assert_eq "a full name selects a hidden context" \
  "gke_proj1_asia-southeast1-a_one" "$(kubectl config current-context)"

,kgt ns web >/dev/null
assert_eq "ns sets the namespace that status shows" \
  "namespace: web" "$(,kgt st | grep '^namespace:')"

help=$(,kgt help)
assert_eq "help ends at the last command" ",kgt reset" "${${(f)help}[-1][1,10]}"

print -r -- "PASS: ,kgt behavior"
