#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Dark Deployment plan (SIG-2769): prod-plan.sh with prod-tags.sh and
# prod-tickets.sh underneath. A real git repo plays the product repo:
#   1.0.0  init
#          SIG-1 feature, SIG-2 fix, SIG-99 (not in Linear)
#   1.1.0  release tag under test
# A fake gh plays signapse-core-k8s: files under $TMP/k8s/<path>, commit
# history of a path in $TMP/hist/<path with / -> _>. A fake curl plays Linear
# from $TMP/linear.json {SIG-n: {state, labels}}; $TMP/linear-fail breaks it.
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"
IN_WINDOW=2026-11-02T10:00:00Z     # Monday 10:00 GMT
OUT_OF_WINDOW=2026-11-02T17:00:00Z # Monday 17:00 GMT

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/k8s" "$TMP/hist"
  export PATH="$TMP/stub:$PATH"

  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "gh stub: unhandled $*" >&2; exit 1; }
shift
while [ "$1" = -H ] || [ "$1" = --paginate ]; do
  [ "$1" = --paginate ] && { echo paginate >> "$TMP/gh-flags"; shift; continue; }
  shift 2
done
url="$1"
case "$url" in
  repos/*/contents/*)
    p="${url#repos/*/*/contents/}"; p="${p%%\?*}"
    if [ -d "$TMP/k8s/$p" ]; then echo '[]'
    elif [ -f "$TMP/k8s/$p" ]; then cat "$TMP/k8s/$p"
    else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  repos/*/commits\?*)
    p=$(sed -E 's/.*[?&]path=([^&]*).*/\1/' <<< "$url")
    f="$TMP/hist/$(tr / _ <<< "$p")"
    if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
    # --paginate prints one array per page: $TMP/hist/<path>.2 is page 2.
    [ ! -f "$f.2" ] || cat "$f.2" ;;
  *) echo "gh stub: unhandled api $url" >&2; exit 1 ;;
esac
EOS
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
body=""; prev=""
for a in "$@"; do [ "$prev" = -d ] && body="$a"; prev="$a"; done
[ -f "$TMP/linear-fail" ] && { printf '{"errors":[{"message":"Rate limit exceeded"}],"data":null}\n200'; exit 0; }
id=$(jq -r .variables.id <<< "$body")
jq -c --arg id "$id" 'if has($id) then .[$id] as $i
  | {data: {issue: {identifier: $id, state: {name: $i.state}, labels: {nodes: [$i.labels[] | {name: .}]}}}}
  else {errors: [{message: "Entity not found: Issue"}], data: null} end' "$TMP/linear.json"
printf '\n200'
EOS
  chmod +x "$TMP/stub/"*

  git init -q -b main "$TMP/repo"
  cd "$TMP/repo" || return 1
  git config user.email t@example.com
  git config user.name t
  git commit -q --allow-empty -m init
  git tag 1.0.0
  git commit -q --allow-empty -m "SIG-1 feature"
  git commit -q --allow-empty -m "SIG-2 fix (mentions SIG-99)"
  git tag 1.1.0

  cat > "$TMP/linear.json" <<'EOF'
{"SIG-1": {"state": "On Staging", "labels": ["Feature", "QA Passed", "Staging Passed"]},
 "SIG-2": {"state": "On Staging", "labels": ["Bug", "QA Passed", "Staging Passed"]}}
EOF
  prod_tag svc-a 1.0.0
  export PROD_SERVICES='["svc-a"]' GH_TOKEN=x LINEAR_API_KEY=x NOW="$IN_WINDOW"
}

teardown() { rm -rf "$TMP"; }

# prod_tag <service> <tag> [shared]: what prod runs, per deploy-prod's layout.
prod_tag() {
  local p="workloads/prod/$1/helmrelease-patch.yaml"
  if [ "${3:-}" = shared ]; then
    p="workloads/prod-common/$1/image-tag-patch.yaml"
    mkdir -p "$TMP/k8s/workloads/prod-us/$1"
  fi
  mkdir -p "$TMP/k8s/$(dirname "$p")"
  # shellcheck disable=SC2016 # literal Flux setter comment
  printf 'spec:\n  values:\n    image:\n      tag: "%s" # {"$imagepolicy": "flux-system:%s:tag"}\n' "$2" "$1" > "$TMP/k8s/$p"
}

# k8s_history <path> <message>...: commit list of a k8s file, newest first.
k8s_history() {
  local p="$1"; shift
  jq -nc '$ARGS.positional | map({commit: {message: .}})' --args "$@" > "$TMP/hist/$(tr / _ <<< "$p")"
}

plan() { run "$S/prod-plan.sh"; }
field() { tail -n1 <<< "$output" | jq -r "$@"; }

@test "AC1: fresh, inside the window: deploy, with prod's tag as the previous one" {
  export RELEASE_TAG=1.1.0 TICKETS=SIG-1
  plan
  [ "$status" -eq 0 ]
  [ "$(field .mode)" = fresh ]
  [ "$(field .decision)" = deploy ]
  [ "$(field .version)" = 1.1.0 ]
  [ "$(field .sha)" = "$(git rev-parse 1.1.0)" ]
  [ "$(field -c .to_deploy)" = '["svc-a"]' ]
  [ "$(field -c .previous_tags)" = '{"svc-a":"1.0.0"}' ]
  [ "$(field .base)" = 1.0.0 ]
}

@test "tickets: the RC's plus every ref since prod's tag; refs Linear does not know are dropped" {
  export RELEASE_TAG=1.1.0 TICKETS=SIG-1
  plan
  [ "$status" -eq 0 ]
  [ "$(field -c .tickets)" = '["SIG-1","SIG-2"]' ]
  [ "$(field '.ticket_details[] | select(.id == "SIG-99") | .found')" = false ]
}

@test "AC6: fresh, outside the window: deferred, nothing to do yet" {
  export RELEASE_TAG=1.1.0 NOW="$OUT_OF_WINDOW"
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = deferred ]
  [[ "$(field .next_open)" == "Tue 2026-11-03 09:00"* ]]
}

@test "outside the window, a hotfix ticket bypasses it" {
  jq '."SIG-2".labels += ["hotfix"]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  export RELEASE_TAG=1.1.0 NOW="$OUT_OF_WINDOW"
  plan
  [ "$(field .decision)" = hotfix ]
}

@test "re-run after the deploy: already_deployed, previous tag recovered from deploy-prod's commit" {
  prod_tag svc-a 1.1.0
  k8s_history workloads/prod/svc-a/helmrelease-patch.yaml \
    $'deploy(prod): svc-a → 1.1.0\n\nPrevious: 1.0.0\nNew:      1.1.0' \
    $'deploy(prod): svc-a → 1.0.0\n\nPrevious: 0.9.0'
  export RELEASE_TAG=1.1.0 NOW="$OUT_OF_WINDOW"
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = already_deployed ]
  [ "$(field -c .to_deploy)" = '[]' ]
  [ "$(field -c .tickets)" = '["SIG-1","SIG-2"]' ]
}

@test "a tag rollback.yml replaced is refused in a fresh run" {
  k8s_history workloads/prod/svc-a/helmrelease-patch.yaml \
    $'rollback(prod): svc-a → 1.0.0\n\nRestored: 1.0.0\nWas:      1.1.0\n\nRolled-back-from: 1.1.0\nRollback-run-key: k'
  export RELEASE_TAG=1.1.0
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = refused ]
  [[ "$(field .reason)" == *"rolled back"* ]]
}

@test "a tag replaced by hand with deploy-prod.yml (no trailer) is refused too" {
  k8s_history workloads/prod/svc-a/helmrelease-patch.yaml \
    $'deploy(prod): svc-a → 1.0.0\n\nPrevious: 1.1.0' \
    $'deploy(prod): svc-a → 1.1.0\n\nPrevious: 1.0.0'
  export RELEASE_TAG=1.1.0
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = refused ]
}

@test "a rollback trailer past the first page of the file's history still counts" {
  k8s_history workloads/prod/svc-a/helmrelease-patch.yaml $'chore: unrelated'
  printf '%s' "$(jq -nc '[{commit: {message: "rollback(prod): svc-a → 1.0.0\n\nRolled-back-from: 1.1.0"}}]')" \
    > "$TMP/hist/workloads_prod_svc-a_helmrelease-patch.yaml.2"
  export RELEASE_TAG=1.1.0
  plan
  [ "$(field .decision)" = refused ]
  grep -q paginate "$TMP/gh-flags"
}

@test "shared services read workloads/prod-common, as deploy-prod.yml does" {
  rm -rf "$TMP/k8s/workloads/prod"
  prod_tag svc-a 1.0.0 shared
  export RELEASE_TAG=1.1.0
  plan
  [ "$status" -eq 0 ]
  [ "$(field '.services[0].path')" = workloads/prod-common/svc-a/image-tag-patch.yaml ]
  [ "$(field .decision)" = deploy ]
}

@test "two services: only the one not on the tag is deployed" {
  prod_tag svc-b 1.1.0
  export RELEASE_TAG=1.1.0 PROD_SERVICES='["svc-a","svc-b"]'
  plan
  [ "$(field -c .to_deploy)" = '["svc-a"]' ]
}

@test "services on different tags: the oldest one is the base, so every ticket reaching prod is checked" {
  git tag 1.0.5 "$(git rev-list -n1 --grep='SIG-1 feature' HEAD)"
  prod_tag svc-a 1.0.5
  prod_tag svc-b 1.0.0
  jq '.["SIG-1"].labels = ["Feature", "QA Passed"]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  export RELEASE_TAG=1.1.0 PROD_SERVICES='["svc-a","svc-b"]'
  plan
  [ "$(field .base)" = 1.0.0 ]
  [ "$(field .decision)" = refused ]
  [[ "$(field .reason)" == *"SIG-1"* ]]
}

@test "a service with no prod patch file fails the plan" {
  export RELEASE_TAG=1.1.0 PROD_SERVICES='["svc-a","nope"]'
  plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"no prod patch file for nope"* ]]
}

@test "a Linear failure fails the plan instead of guessing the window" {
  touch "$TMP/linear-fail"
  export RELEASE_TAG=1.1.0
  plan
  [ "$status" -ne 0 ]
}

@test "AC6 resume: the newest tag with Staging Passed everywhere deploys in the next window" {
  plan
  [ "$status" -eq 0 ]
  [ "$(field .mode)" = resume ]
  [ "$(field .release_tag)" = 1.1.0 ]
  [ "$(field .decision)" = deploy ]
  [ "$(field -c .tickets)" = '["SIG-1","SIG-2"]' ]
}

@test "AC6 resume outside the window stays deferred" {
  export NOW="$OUT_OF_WINDOW"
  plan
  [ "$(field .decision)" = deferred ]
}

@test "resume: nothing when prod already runs the newest tag" {
  prod_tag svc-a 1.1.0
  plan
  [ "$(field .decision)" = nothing ]
  [[ "$(field .reason)" == *"already runs 1.1.0"* ]]
}

@test "resume: nothing when a ticket failed staging or is in QA Failed" {
  jq '."SIG-2".labels = ["Bug", "Staging Failed"] | ."SIG-2".state = "QA Failed"' "$TMP/linear.json" > "$TMP/l"
  mv "$TMP/l" "$TMP/linear.json"
  plan
  [ "$(field .decision)" = nothing ]
  [[ "$(field .reason)" == *"SIG-2 (QA Failed"* ]]
}

@test "resume: nothing when a ticket lacks Staging Passed (staging never ran)" {
  jq '."SIG-1".labels = ["Feature", "QA Passed"]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  plan
  [ "$(field .decision)" = nothing ]
}

@test "resume: never redeploys a tag that was rolled back from" {
  k8s_history workloads/prod/svc-a/helmrelease-patch.yaml $'rollback(prod): svc-a\n\nRolled-back-from: 1.1.0'
  plan
  [ "$(field .decision)" = nothing ]
}

@test "resume: a ticketless tag cannot prove its staging pass, so it waits" {
  cd "$TMP/repo" || return 1
  git commit -q --allow-empty -m "chore: untracked"
  git tag 1.2.0
  prod_tag svc-a 1.1.0
  plan
  [ "$(field .release_tag)" = 1.2.0 ]
  [ "$(field .decision)" = nothing ]
  [[ "$(field .reason)" == *"no Linear tickets"* ]]
}

@test "resume: no release tag yet is nothing" {
  cd "$TMP/repo" || return 1
  git tag -d 1.0.0 1.1.0 > /dev/null
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = nothing ]
}

# --- Review fix: fresh mode checks every ticket since the tag prod runs ----

@test "fresh: refuses when a ticket since prod's tag is in QA Failed (failed staging earlier)" {
  jq '."SIG-1".state = "QA Failed" | ."SIG-1".labels = ["Feature", "Staging Failed"]' "$TMP/linear.json" > "$TMP/l"
  mv "$TMP/l" "$TMP/linear.json"
  export RELEASE_TAG=1.1.0 TICKETS=SIG-2
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = refused ]
  [[ "$(field .reason)" == *"SIG-1 (QA Failed"* ]]
}

@test "fresh: refuses when a ticket in range has no Staging Pass on record" {
  jq '."SIG-2".labels = ["Bug", "QA Passed"]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  export RELEASE_TAG=1.1.0 TICKETS=SIG-1
  plan
  [ "$(field .decision)" = refused ]
}

@test "resume: RESUME_TAG (the train's staged_tag) is the candidate, not the newest tag" {
  cd "$TMP/repo" || return 1
  git commit -q --allow-empty -m "SIG-3 newer, failed staging"
  git tag 1.2.0
  jq '."SIG-3" = {state: "QA Failed", labels: ["Staging Failed"]}' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  export RESUME_TAG=1.1.0
  plan
  [ "$(field .release_tag)" = 1.1.0 ]
  [ "$(field .decision)" = deploy ]
  unset RESUME_TAG
  plan
  [ "$(field .release_tag)" = 1.2.0 ]
  [ "$(field .decision)" = nothing ]
}

@test "never deploys an older tag over a newer one prod runs (hand-deployed hotfix)" {
  git commit -q --allow-empty -m "SIG-1 hotfix"
  git tag 1.2.0
  prod_tag svc-a 1.2.0
  export RELEASE_TAG=1.1.0 TICKETS=SIG-1
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = refused ]
  [[ "$(field .reason)" == *"svc-a runs 1.2.0"* ]]
  unset RELEASE_TAG
  export RESUME_TAG=1.1.0
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = nothing ]
}

@test "resume without RESUME_TAG never picks a release-shaped tag on a merged side branch" {
  git checkout -q -b side
  git commit -q --allow-empty -m "SIG-1 side work"
  git tag 9.9.9
  git checkout -q main
  git merge -q --no-ff --no-edit side
  unset RELEASE_TAG RESUME_TAG
  plan
  [ "$status" -eq 0 ]
  [ "$(field .release_tag)" = 1.1.0 ]
}

@test "a reverted commit's ticket in range does not refuse the Deployment" {
  cd "$TMP/repo" || return 1
  echo broken > sig-4 && git add sig-4 && git commit -q -m "SIG-4 broke staging"
  bad=$(git rev-parse HEAD)
  git revert --no-commit "$bad" > /dev/null
  git commit -q -m 'Revert "SIG-4 broke staging"' -m "This reverts commit $bad."
  git tag 1.2.0
  jq '."SIG-4" = {state: "QA Failed", labels: ["Staging Failed"]}' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  export RELEASE_TAG=1.2.0
  plan
  [ "$status" -eq 0 ]
  [ "$(field .decision)" = deploy ]
  [ "$(field -c .tickets)" = '["SIG-1","SIG-2"]' ]
}

@test "prod-tags.sh --require-all: silent when every service runs the tag, else names the others" {
  export PROD_SERVICES='["svc-a","svc-b"]'
  prod_tag svc-a 1.1.0
  prod_tag svc-b 1.1.0
  run "$S/prod-tags.sh" --require-all 1.1.0
  [ "$status" -eq 0 ] && [ -z "$output" ]
  prod_tag svc-b 1.0.0
  run "$S/prod-tags.sh" --require-all 1.1.0
  [ "$status" -eq 2 ]
  [ "$(tail -n1 <<< "$output")" = "svc-b runs 1.0.0" ]
}
