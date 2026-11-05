#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# End to end at the script level (review finding 1): a tag that failed
# staging, then a newer Release Candidate (N+1) with an unrelated ticket.
# selection-base.sh -> release-candidate.sh -> prod-plan.sh in one repo, with
# one fake Linear ($TMP/linear.json: id -> {state, labels}) and one fake gh
# (product repo builds and PRs; signapse-core-k8s prod files under $TMP/k8s).
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"
IN_WINDOW=2026-11-02T10:00:00Z

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/k8s/workloads/prod/svc-a"
  export PATH="$TMP/stub:$PATH"
  echo '{}' > "$TMP/builds.json"

  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 1
shift
while [ "$1" = -H ] || [ "$1" = --paginate ]; do [ "$1" = --paginate ] && shift || shift 2; done
url="$1"; filter="."
[ "${2:-}" = --jq ] && filter="$3"
case "$url" in
  *"/actions/workflows/main-push.yml/runs?"*)
    sha=$(sed -E 's/.*head_sha=([0-9a-f]+).*/\1/' <<< "$url")
    jq -c --arg s "$sha" '{workflow_runs: (if has($s) then [{run_number: .[$s], event: "push",
        html_url: "https://github.com/o/r/actions/runs/\(.[$s])"}] else [] end)}' "$TMP/builds.json" | jq -r "$filter" ;;
  *"/commits/"*"/pulls") echo '[]' | jq -r "$filter" ;;
  repos/*/contents/*)
    p="${url#repos/*/*/contents/}"; p="${p%%\?*}"
    if [ -f "$TMP/k8s/$p" ]; then cat "$TMP/k8s/$p"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  repos/*/commits\?*) echo '[]' ;;
  *) echo "gh stub: unhandled $url" >&2; exit 1 ;;
esac
EOS
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
body=""; prev=""
for a in "$@"; do [ "$prev" = -d ] && body="$a"; prev="$a"; done
id=$(jq -r .variables.id <<< "$body")
jq -c --arg id "$id" 'if has($id) then .[$id] as $i
  | {data: {issue: {identifier: $id, title: "t", url: "https://linear.app/x/\($id)",
      state: {name: $i.state}, labels: {nodes: [$i.labels[] | {name: .}]}}}}
  else {data: {issue: null}, errors: [{message: "Entity not found: Issue"}]} end' "$TMP/linear.json"
printf '\n200'
EOS
  chmod +x "$TMP/stub/"*

  git init -q -b main "$TMP/repo"
  cd "$TMP/repo" || return 1
  git config user.email t@example.com
  git config user.name t
  git commit -q --allow-empty -m init
  git tag 1.0.0
  prod 1.0.0
  echo '{}' > "$TMP/linear.json"
  export PROD_SERVICES='["svc-a"]' GH_TOKEN=x LINEAR_API_KEY=x GITHUB_REPOSITORY=o/r NOW="$IN_WINDOW"
}

teardown() { rm -rf "$TMP"; }

prod() { printf 'spec:\n  values:\n    image:\n      tag: "%s"\n' "$1" > "$TMP/k8s/workloads/prod/svc-a/helmrelease-patch.yaml"; }
# merge <subject> [body]: a real change (a file per subject); a revert body
# ("This reverts commit <sha>.") undoes that commit for real, since only a
# commit that undoes its target counts as a revert (lib/revert.sh).
merge() {
  local t
  t=$(sed -nE 's/^This reverts commit ([0-9a-f]+)\.?$/\1/p' <<< "${2:-}")
  if [ -n "$t" ]; then
    git revert --no-commit "$t" > /dev/null
  else
    echo "$1" >> "f-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
    git add -A
  fi
  git commit -q -m "$1" ${2:+-m "$2"}
  jq --arg s "$(git rev-parse HEAD)" --argjson n "$(( $(jq length "$TMP/builds.json") + 11 ))" '.[$s] = $n' \
    "$TMP/builds.json" > "$TMP/b" && mv "$TMP/b" "$TMP/builds.json"
}
ticket() {
  local id="$1" st="$2"; shift 2
  jq --arg id "$id" --arg st "$st" --args '.[$id] = {state: $st, labels: $ARGS.positional}' "$@" \
    < "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
}
select_rc() { "$S/release-candidate.sh" "$(jq -r .base <<< "$("$S/selection-base.sh")")" HEAD 2> /dev/null; }
prod_plan() { "$S/prod-plan.sh" 2> /dev/null | tail -n1; }

@test "a tag that failed staging, then N+1: nothing is promoted or deployed until QA re-passes it or it is reverted" {
  # N = 1.0.1: SIG-1 promoted, staging failed (SIG-2767 moved it to QA
  # Failed, Staging Failed, QA Passed removed).
  merge "feat(SIG-1): A"
  git tag 1.0.1
  ticket SIG-1 "QA Failed" Feature "Staging Failed"
  # N+1: SIG-2 merged and passes QA on dev.
  merge "feat(SIG-2): B"
  ticket SIG-2 "On Dev · Ready for QA" Bug "QA Passed"

  # Staging: the walk starts at prod's 1.0.0, so SIG-1 stops the line.
  run select_rc
  [ "$status" -eq 0 ]
  [ "$(jq -r '.base + " " + .outcome + " " + .blocked_by.id' <<< "$output")" = "1.0.0 none SIG-1" ]

  # Prod: even if N+1 were tagged and its own tickets passed staging, the
  # fresh plan refuses, naming SIG-1; resume does nothing.
  git tag 1.0.2
  ticket SIG-2 "On Staging" Bug "QA Passed" "Staging Passed"
  RELEASE_TAG=1.0.2 TICKETS=SIG-2 run prod_plan
  [ "$(jq -r .decision <<< "$output")" = refused ]
  [[ "$(jq -r .reason <<< "$output")" == *"SIG-1 (QA Failed"* ]]
  run prod_plan
  [ "$(jq -r .decision <<< "$output")" = nothing ]
  git tag -d 1.0.2 > /dev/null

  # The 24 h revert of SIG-1 merges: the line moves again, without SIG-1.
  merge 'Revert "feat(SIG-1): A"' "This reverts commit $(git rev-parse 1.0.1)."
  run select_rc
  [ "$(jq -r .outcome <<< "$output")" = selected ]
  [ "$(jq -c '[.tickets[].id]' <<< "$output")" = '["SIG-2"]' ]
  [ "$(jq -r .rc.sha <<< "$output")" = "$(git rev-parse HEAD)" ]
  # Promoted as 1.0.2 and staging passed for SIG-2: prod deploys it.
  git tag 1.0.2
  RELEASE_TAG=1.0.2 TICKETS=SIG-2 run prod_plan
  [ "$(jq -r .decision <<< "$output")" = deploy ]
  [ "$(jq -c .tickets <<< "$output")" = '["SIG-2"]' ]
}

@test "a rolled-back tag: prod runs the previous tag, so the next candidate is blocked by its tickets" {
  merge "feat(SIG-1): A"
  git tag 1.0.1
  # 1.0.1 reached prod, the smoke failed, rollback.yml put 1.0.0 back and
  # SIG-2771 moved SIG-1 to QA Failed.
  prod 1.0.0
  ticket SIG-1 "QA Failed" Feature
  merge "feat(SIG-2): B"
  ticket SIG-2 "On Dev · Ready for QA" Bug "QA Passed"
  run select_rc
  [ "$(jq -r '.outcome + " " + .blocked_by.id' <<< "$output")" = "none SIG-1" ]
}
