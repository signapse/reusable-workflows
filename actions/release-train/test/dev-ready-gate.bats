#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/dev-ready-gate.sh"

# Fixtures:
#   $TMP/linear.json   {"SIG-1": <issue node>, ...}  (missing id = not found)
#   $TMP/gh/<url>      GitHub API response for that path+query, with every
#                      '/', '?', '&' and '=' replaced by '_'. Missing = 404.
setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub" "$TMP/gh"
  echo '{}' > "$TMP/linear.json"
  export LINEAR_FIXTURE="$TMP/linear.json" GH_FIX="$TMP/gh"
  export LINEAR_API_KEY=fake GH_TOKEN=fake
  export CURRENT_PRS='["signapse/app#10"]'
  unset FROM_STATES SMOKE_JOB_PATTERN

  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
prev=""; body=""
for arg in "$@"; do
  [ "$prev" = "-d" ] && body="$arg"
  prev="$arg"
done
case "${LINEAR_MODE:-}" in
  http401)   printf '{"errors":[{"message":"Authentication required"}]}\n401'; exit 0 ;;
  ratelimit) printf '{"errors":[{"message":"Rate limit exceeded"}],"data":null}\n200'; exit 0 ;;
esac
id=$(echo "$body" | jq -r '.variables.id')
node=$(jq -c --arg id "$id" '.[$id] // null' "$LINEAR_FIXTURE")
if [ "$node" = null ]; then
  # What Linear returns for an unknown identifier.
  printf '{"errors":[{"message":"Entity not found: Issue","extensions":{"code":"INPUT_ERROR"}}],"data":null}\n200'
else
  printf '{"data":{"issue":%s}}\n200' "$node"
fi
EOS

  # Fake gh api: serves fixture files, applying --jq like the real CLI.
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
[ "$1" = api ] || { echo "gh stub: unexpected $*" >&2; exit 1; }
shift
url=""; filter="."
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) filter="$2"; shift ;;
    -H) shift ;;
    *) [ -z "$url" ] && url="$1" ;;
  esac
  shift
done
echo "$url" >> "$GH_FIX/calls.log"
f="$GH_FIX/$(echo "$url" | tr '/?&=' '____')"
[ -f "$f" ] || { echo "gh: HTTP 404 $url" >&2; exit 1; }
jq -rc "$filter" "$f"   # gh --jq prints strings raw
EOS
  chmod +x "$TMP/stub/curl" "$TMP/stub/gh"
}

teardown() { rm -rf "$TMP"; }

# issue <id> <state> <pr-url>...
issue() {
  local id="$1" state="$2"; shift 2
  local urls
  urls=$(printf '%s\n' "$@" | jq -R 'select(. != "") | {url: .}' | jq -sc .)
  jq --arg id "$id" --arg s "$state" --argjson n "$urls" \
    '.[$id] = {identifier:$id, state:{name:$s}, attachments:{nodes:$n}}' \
    "$LINEAR_FIXTURE" > "$LINEAR_FIXTURE.tmp" && mv "$LINEAR_FIXTURE.tmp" "$LINEAR_FIXTURE"
}

gh_fix() { echo "$2" > "$GH_FIX/$(echo "$1" | tr '/?&=' '____')"; }

# pr <repo> <n> <state> <merged:true|false> <merge-sha> [merged_at]
pr() {
  local merged_at=null
  [ "$4" = true ] && merged_at="\"${6:-2026-11-01T00:00:00Z}\""
  gh_fix "repos/$1/pulls/$2" "{\"state\":\"$3\",\"merged_at\":$merged_at,\"merge_commit_sha\":\"$5\"}"
}

# runs <repo> <sha> <runs-json> ; jobs <repo> <run-id> <jobs-json>
runs() { gh_fix "repos/$1/actions/runs?head_sha=$2&event=push&per_page=100" "{\"workflow_runs\":$3}"; }
jobs() { gh_fix "repos/$1/actions/runs/$2/jobs?filter=latest&per_page=100" "{\"jobs\":$3}"; }

decision() { echo "$output" | jq -r --arg id "$1" '.[] | select(.id == $id) | .move'; }
reason()   { echo "$output" | jq -r --arg id "$1" '.[] | select(.id == $id) | .reason'; }

run_gate() { run bash -c "echo '$1' | '$SCRIPT' 2>/dev/null"; }

@test "empty input emits [] without needing Linear credentials" {
  unset LINEAR_API_KEY
  run_gate '[]'
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "AC1: In Review ticket linked only to this build's PR moves" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10
  run_gate '["SIG-1"]'
  [ "$status" -eq 0 ]
  [ "$(decision SIG-1)" = true ]
}

@test "today's 'PR in Review' column is an allowed source by default" {
  issue SIG-1 "PR in Review" https://github.com/signapse/app/pull/10
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

@test "ticket in QA Failed is never moved" {
  issue SIG-1 "QA Failed" https://github.com/signapse/app/pull/10
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"QA Failed"* ]]
}

@test "ticket already further along is never moved back" {
  issue SIG-1 "On Staging" https://github.com/signapse/app/pull/10
  issue SIG-2 "On Dev · Ready for QA" https://github.com/signapse/app/pull/10
  run_gate '["SIG-1","SIG-2"]'
  [ "$(decision SIG-1)" = false ]
  [ "$(decision SIG-2)" = false ]
}

@test "FROM_STATES is configurable" {
  issue SIG-1 "PR in Review" https://github.com/signapse/app/pull/10
  FROM_STATES="In Review" run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
}

@test "ticket not found in Linear stays" {
  run_gate '["SIG-404"]'
  [ "$status" -eq 0 ]
  [ "$(decision SIG-404)" = false ]
  [[ "$(reason SIG-404)" == *"not found"* ]]
}

@test "Linear auth failure fails the run instead of reporting not found" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10
  LINEAR_MODE=http401 run bash -c "echo '[\"SIG-1\"]' | '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linear lookup of SIG-1 failed"* ]]
  [[ "$output" != *'"move"'* ]]
}

@test "Linear GraphQL error (rate limit) fails the run" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10
  LINEAR_MODE=ratelimit run bash -c "echo '[\"SIG-1\"]' | '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Rate limit exceeded"* ]]
}

@test "ticket with no PR attachments moves on the commit mention alone" {
  issue SIG-1 "In Review"
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

@test "ticket whose linked PRs are all outside this build stays" {
  issue SIG-1 "In Review" https://github.com/signapse/other/pull/5
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"is in this build"* ]]
}

@test "PR URL matching is case-insensitive and ignores non-PR attachments" {
  issue SIG-1 "In Review" https://github.com/Signapse/App/pull/10 https://www.notion.so/x https://github.com/signapse/app/commit/abc
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

@test "AC3: second linked PR still open -> stays, says why" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7
  pr signapse/api 7 open false null
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"signapse/api#7 not merged"* ]]
}

@test "AC3: second linked PR merged but its dev smoke failed -> stays" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7
  pr signapse/api 7 closed true sha7
  runs signapse/api sha7 '[{"id":71,"status":"completed"}]'
  jobs signapse/api 71 '[{"name":"build / build (http)","status":"completed","conclusion":"success"},
                         {"name":"dev / Dev smoke verdict","status":"completed","conclusion":"failure"}]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"signapse/api#7 dev smoke failure"* ]]
}

@test "AC3: second linked PR merged and its dev smoke still running -> stays" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7
  pr signapse/api 7 closed true sha7
  runs signapse/api sha7 '[{"id":71,"status":"in_progress"}]'
  jobs signapse/api 71 '[{"name":"dev / Dev smoke verdict","status":"queued","conclusion":null}]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"still running"* ]]
}

@test "AC3: both linked PRs merged and both passed dev smoke -> moves" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7
  pr signapse/api 7 closed true sha7
  runs signapse/api sha7 '[{"id":70,"status":"completed"},{"id":71,"status":"completed"}]'
  jobs signapse/api 70 '[{"name":"lint","status":"completed","conclusion":"success"}]'
  jobs signapse/api 71 '[{"name":"dev / Dev smoke verdict","status":"completed","conclusion":"success"}]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

# smoke_failed <repo> <n> <sha> <run-id> <merged_at>: a merged PR whose dev smoke failed.
smoke_failed() {
  pr "$1" "$2" closed true "$3" "$5"
  runs "$1" "$3" "[{\"id\":$4,\"status\":\"completed\",\"conclusion\":\"failure\"}]"
  jobs "$1" "$4" '[{"name":"dev / Dev smoke verdict","status":"completed","conclusion":"failure"}]'
}
# smoke_passed <repo> <n> <sha> <run-id> <merged_at>
smoke_passed() {
  pr "$1" "$2" closed true "$3" "$5"
  runs "$1" "$3" "[{\"id\":$4,\"status\":\"completed\",\"conclusion\":\"success\"}]"
  jobs "$1" "$4" '[{"name":"dev / Dev smoke verdict","status":"completed","conclusion":"success"}]'
}

@test "fix PR in this build, merged after the failed one in the same repo, supersedes it -> moves" {
  CURRENT_PRS='["signapse/app#11"]'
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/app/pull/11
  smoke_failed signapse/app 10 sha10 100 2026-11-01T10:00:00Z
  pr signapse/app 11 closed true sha11 2026-11-01T12:00:00Z
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
  [[ "$(reason SIG-1)" == *"signapse/app#10 dev smoke failure, superseded by signapse/app#11"* ]]
}

@test "this build's PR merged BEFORE the failed one does not supersede it -> stays" {
  CURRENT_PRS='["signapse/app#11"]'
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/app/pull/11
  smoke_failed signapse/app 10 sha10 100 2026-11-01T12:00:00Z
  pr signapse/app 11 closed true sha11 2026-11-01T10:00:00Z
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"signapse/app#10 dev smoke failure"* ]]
}

@test "an earlier passing PR elsewhere does not supersede; a later passing PR in the same repo does" {
  # app#10 is this build. api#7 failed; api#8 merged later and passed.
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7 https://github.com/signapse/api/pull/8
  smoke_failed signapse/api 7 sha7 70 2026-11-01T10:00:00Z
  smoke_passed signapse/api 8 sha8 80 2026-11-01T11:00:00Z
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
  [[ "$(reason SIG-1)" == *"superseded by signapse/api#8"* ]]
}

@test "same-second merges: the pass supersedes only if its merge commit contains the failed one" {
  CURRENT_PRS='["signapse/app#11"]'
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/app/pull/11
  smoke_failed signapse/app 10 sha10 100 2026-11-01T10:00:00Z
  pr signapse/app 11 closed true sha11 2026-11-01T10:00:00Z
  gh_fix "repos/signapse/app/compare/sha10...sha11" '{"status":"ahead"}'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

@test "same-second merges: a pass that does not contain the failed commit does not supersede" {
  CURRENT_PRS='["signapse/app#11"]'
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/app/pull/11
  smoke_failed signapse/app 10 sha10 100 2026-11-01T10:00:00Z
  pr signapse/app 11 closed true sha11 2026-11-01T10:00:00Z
  gh_fix "repos/signapse/app/compare/sha10...sha11" '{"status":"behind"}'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
}

@test "a passing PR in a different repo never supersedes a failure" {
  CURRENT_PRS='["signapse/app#10"]'
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7
  smoke_failed signapse/api 7 sha7 70 2026-11-01T10:00:00Z
  gh_fix "repos/signapse/app/pulls/10" '{"state":"closed","merged_at":"2026-11-02T00:00:00Z"}'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
}

@test "a pending (still running) PR is not superseded by a later pass" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7 https://github.com/signapse/api/pull/8
  pr signapse/api 7 closed true sha7 2026-11-01T10:00:00Z
  runs signapse/api sha7 '[{"id":70,"status":"in_progress"}]'
  jobs signapse/api 70 '[{"name":"dev / Dev smoke verdict","status":"queued","conclusion":null}]'
  smoke_passed signapse/api 8 sha8 80 2026-11-01T11:00:00Z
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"still running"* ]]
}

@test "a later PR whose smoke also failed does not supersede -> stays" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7 https://github.com/signapse/api/pull/8
  smoke_failed signapse/api 7 sha7 70 2026-11-01T10:00:00Z
  smoke_failed signapse/api 8 sha8 80 2026-11-01T11:00:00Z
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
}

@test "linked PR closed without merging is ignored" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/6
  pr signapse/api 6 closed false null
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

@test "merged PR in a repo without a dev smoke job counts once its runs succeeded" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/infra/pull/3
  pr signapse/infra 3 closed true sha3
  runs signapse/infra sha3 '[{"id":30,"status":"completed","conclusion":"success"}]'
  jobs signapse/infra 30 '[{"name":"terraform plan","status":"completed","conclusion":"success"}]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
  [[ "$(reason SIG-1)" == *"no dev smoke job"* ]]
}

@test "merged PR in a repo without a dev smoke job whose build failed stays" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/portal/pull/4
  pr signapse/portal 4 closed true sha4
  runs signapse/portal sha4 '[{"id":40,"status":"completed","conclusion":"failure"}]'
  jobs signapse/portal 40 '[{"name":"build / build (portal)","status":"completed","conclusion":"failure"}]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"did not pass"* ]]
}

@test "no dev smoke job and only skipped/neutral runs is not a successful build" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/infra/pull/3
  pr signapse/infra 3 closed true sha3
  runs signapse/infra sha3 '[{"id":30,"status":"completed","conclusion":"skipped"},{"id":31,"status":"completed","conclusion":"neutral"}]'
  jobs signapse/infra 30 '[]'
  jobs signapse/infra 31 '[]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
}

@test "no dev smoke job: one successful run plus a skipped one passes" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/infra/pull/3
  pr signapse/infra 3 closed true sha3
  runs signapse/infra sha3 '[{"id":30,"status":"completed","conclusion":"success"},{"id":31,"status":"completed","conclusion":"skipped"}]'
  jobs signapse/infra 30 '[]'
  jobs signapse/infra 31 '[]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

@test "merged PR with no main-push run yet stays" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7
  pr signapse/api 7 closed true sha7
  runs signapse/api sha7 '[]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
}

@test "unreadable linked repo blocks rather than passes" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/secret/pull/1
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
  [[ "$(reason SIG-1)" == *"cannot read"* ]]
}

@test "this build's own PR is not re-checked on GitHub" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10
  run_gate '["SIG-1"]'
  [ ! -f "$GH_FIX/calls.log" ]
}

@test "mixed batch: each ticket decided independently" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10
  issue SIG-2 "QA Failed" https://github.com/signapse/app/pull/10
  issue SIG-3 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/7
  pr signapse/api 7 open false null
  run_gate '["SIG-1","SIG-2","SIG-3"]'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.[] | select(.move) | .id]')" = '["SIG-1"]' ]
}
