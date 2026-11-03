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
id=$(echo "$body" | jq -r '.variables.id')
node=$(jq -c --arg id "$id" '.[$id] // null' "$LINEAR_FIXTURE")
printf '{"data":{"issue":%s}}\n200' "$node"
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
jq -c "$filter" "$f"
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

# pr <repo> <n> <state> <merged:true|false> <merge-sha>
pr() {
  local merged_at=null
  [ "$4" = true ] && merged_at='"2026-11-01T00:00:00Z"'
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

@test "AC3: two PRs in the same repo, earlier one's smoke failed -> stays" {
  CURRENT_PRS='["signapse/app#11"]'
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/app/pull/11
  pr signapse/app 10 closed true sha10
  runs signapse/app sha10 '[{"id":100,"status":"completed"}]'
  jobs signapse/app 100 '[{"name":"build / build (web)","status":"completed","conclusion":"failure"},
                          {"name":"dev / Dev smoke verdict","status":"completed","conclusion":"failure"}]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = false ]
}

@test "linked PR closed without merging is ignored" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/api/pull/6
  pr signapse/api 6 closed false null
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
}

@test "merged PR in a repo without a dev smoke job counts once its runs finished" {
  issue SIG-1 "In Review" https://github.com/signapse/app/pull/10 https://github.com/signapse/infra/pull/3
  pr signapse/infra 3 closed true sha3
  runs signapse/infra sha3 '[{"id":30,"status":"completed"}]'
  jobs signapse/infra 30 '[{"name":"terraform plan","status":"completed","conclusion":"success"}]'
  run_gate '["SIG-1"]'
  [ "$(decision SIG-1)" = true ]
  [[ "$(reason SIG-1)" == *"no dev smoke job"* ]]
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
