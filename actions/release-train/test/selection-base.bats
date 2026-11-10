#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Walk base (SIG-2761): selection-base.sh with prod-tags.sh underneath. A fake
# gh plays signapse-core-k8s: files under $TMP/k8s/<path>.
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/k8s"
  export PATH="$TMP/stub:$PATH"
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 1
shift
while [ "$1" = -H ]; do shift 2; done
url="$1"
case "$url" in
  repos/*/contents/*)
    p="${url#repos/*/*/contents/}"; p="${p%%\?*}"
    if [ -d "$TMP/k8s/$p" ]; then echo '[]'
    elif [ -f "$TMP/k8s/$p" ]; then cat "$TMP/k8s/$p"
    else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  repos/*/commits\?*) echo '[]' ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$TMP/stub/gh"
  git init -q -b main "$TMP/repo"
  cd "$TMP/repo" || return 1
  git config user.email t@example.com
  git config user.name t
  git commit -q --allow-empty -m init; git tag 1.0.0
  git commit -q --allow-empty -m "SIG-1"; git tag 1.0.1
  git commit -q --allow-empty -m "SIG-2"; git tag 1.0.2
  export PROD_SERVICES='["svc-a"]' GH_TOKEN=x
}

teardown() { rm -rf "$TMP"; }

prod_tag() {
  local p="workloads/prod/$1/helmrelease-patch.yaml"
  mkdir -p "$TMP/k8s/$(dirname "$p")"
  printf 'spec:\n  values:\n    image:\n      tag: "%s"\n' "$2" > "$TMP/k8s/$p"
}

@test "the base is the tag prod runs, not the last Promotion" {
  prod_tag svc-a 1.0.0
  run "$S/selection-base.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .base <<< "$output")" = 1.0.0 ]
  [ "$(jq -r .source <<< "$output")" = prod ]
}

@test "after a rollback prod runs the previous tag again, and that is the base" {
  prod_tag svc-a 1.0.1   # 1.0.2 was rolled back
  run "$S/selection-base.sh"
  [ "$(jq -r .base <<< "$output")" = 1.0.1 ]
}

@test "services on different tags: the oldest is the base" {
  PROD_SERVICES='["svc-a","svc-b"]'
  prod_tag svc-a 1.0.2
  prod_tag svc-b 1.0.1
  run "$S/selection-base.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .base <<< "$output")" = 1.0.1 ]
}

@test "prod on a tag this repo does not have fails, naming selection_base" {
  prod_tag svc-a main-12-abc
  run "$S/selection-base.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *selection_base* ]]
}

@test "selection_base overrides prod" {
  SELECTION_BASE=1.0.1 run "$S/selection-base.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.base + " " + .source' <<< "$output")" = "1.0.1 input" ]
}

@test "no prod_services and no selection_base fails" {
  PROD_SERVICES='' run "$S/selection-base.sh"
  [ "$status" -ne 0 ]
}

@test "a prod read failure fails" {
  run "$S/selection-base.sh"   # no prod file at all
  [ "$status" -ne 0 ]
}

# A tag on a merged side branch is an ancestor of HEAD but not on main's
# first-parent line, which release-candidate.sh walks: refuse it.
side_tag() {
  git checkout -q -b side 1.0.1
  git commit -q --allow-empty -m "side work"; git tag 1.0.1-side
  git checkout -q main
  git merge -q --no-ff -m "merge side" side
}

@test "selection_base on a merged side branch fails" {
  side_tag
  SELECTION_BASE=1.0.1-side run "$S/selection-base.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on the release branch"* ]]
}

@test "prod on a tag from a merged side branch fails" {
  side_tag
  git tag 1.0.3 1.0.1-side
  prod_tag svc-a 1.0.3
  run "$S/selection-base.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on the release branch"* ]]
}
