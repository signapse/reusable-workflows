#!/usr/bin/env bats
# shellcheck disable=SC2016 # literal Markdown backticks in expected output.
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/release-candidate-summary.sh"

setup() { export GITHUB_REPOSITORY=o/r; }

SEL='{"base":"1.0.0","head_sha":"abcdef1234","outcome":"selected","already_promoted":false,
  "rc":{"sha":"1111111aaaa","image_tag":"main-11-1111111aaaa","run_number":11,"run_url":"https://github.com/o/r/actions/runs/11"},
  "tickets":[{"id":"SIG-1","title":"A","url":"https://linear.app/x/SIG-1","state":"On Dev · Ready for QA"}],
  "untracked_commits":[{"sha":"2222222bbbb","subject":"chore: deps"}],
  "blocked_by":{"id":"SIG-2","title":"B","url":"https://linear.app/x/SIG-2","state":"QA Failed","reason":"in QA Failed","sha":"3333333cccc","subject":"feat(SIG-2): B"},
  "commits":[]}'

@test "renders the Release Candidate, tickets, untracked commits and the blocker" {
  run "$SCRIPT" <<< "$SEL"
  [ "$status" -eq 0 ]
  [[ "$output" == *'**Selected** `main-11-1111111aaaa` ([build #11](https://github.com/o/r/actions/runs/11)).'* ]]
  [[ "$output" == *'- [SIG-1](https://linear.app/x/SIG-1) A (On Dev · Ready for QA)'* ]]
  [[ "$output" == *'- [`2222222`](https://github.com/o/r/commit/2222222bbbb) chore: deps'* ]]
  [[ "$output" == *'- [SIG-2](https://linear.app/x/SIG-2) in QA Failed, first merged in [`3333333`]'* ]]
  [[ "$output" == *"Scheduled run (hourly backstop)."* ]]
}

@test "contributor text cannot add links or lines" {
  sel=$(jq -c '.untracked_commits[0].subject = "x [click](https://evil.example) ![i](u)"
    | .tickets[0].title = "T\n## Approved by QA"
    | .tickets[0].url = "javascript:alert(1)"' <<< "$SEL")
  TICKET='SIG-1 [x](y)' TRIGGER_ID=d run "$SCRIPT" <<< "$sel"
  [ "$status" -eq 0 ]
  [[ "$output" == *'x \[click\]\(https://evil.example\) \!\[i\]\(u\)'* ]]
  [[ "$output" == *'T \#\# Approved by QA'* ]]
  [[ "$output" != *$'\n## Approved'* ]]
  [[ "$output" == *'- [SIG-1](#) '* ]]
  [[ "$output" == *'Triggered by SIG-1 \[x\]\(y\) (delivery d).'* ]]
}

@test "no Release Candidate: the reason follows the walk" {
  sel=$(jq -c '.outcome = "none" | .rc = null | .tickets = [] | .untracked_commits = []' <<< "$SEL")
  run "$SCRIPT" <<< "$sel"
  [ "$status" -eq 0 ]
  [[ "$output" == *"**No Release Candidate:** no commits since"* ]]
  [[ "$output" == *"_none_"* ]]
  run "$SCRIPT" <<< "$(jq -c '.commits = [{"sha":"3333333cccc"}]' <<< "$sel")"
  [[ "$output" == *"the walk stopped at a blocking ticket"* ]]
  run "$SCRIPT" <<< "$(jq -c '.commits = [{"sha":"3333333cccc"}] | .blocked_by = null' <<< "$sel")"
  [[ "$output" == *"no selectable build yet"* ]]
  [[ "$output" == *"_nothing blocked the walk_"* ]]
}
