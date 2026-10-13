#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/slack-composer.sh"
SNAPS="$BATS_TEST_DIRNAME/../testdata/snapshots"

DRAFT="https://github.com/signapse/text-to-video-api/releases/tag/1.2.25"

STATE_READY='{
  "last_tag":"1.2.24","head_sha":"abc","next_version":"1.2.25",
  "ready_tickets":[
    {"id":"SIG-1","title":"First","author":"@alex","status":"Ready for Prod"},
    {"id":"SIG-2","title":"Second","author":"@bob","status":"Ready for Prod"}],
  "blocking_tickets":[],
  "non_ticket_prs":[{"number":294,"title":"chore: dep bump","author":"dependabot","labels":["deps"]}],
  "staging_ok":true,"sentry_error_count_24h":12
}'

STATE_HELD='{
  "last_tag":"1.2.24","head_sha":"abc","next_version":"1.2.25",
  "ready_tickets":[{"id":"SIG-1","title":"First","author":"@alex","status":"Ready for Prod"}],
  "blocking_tickets":[{"id":"SIG-2","title":"Second","author":"@bob","status":"In QA","assignee":"@bob"}],
  "non_ticket_prs":[],
  "staging_ok":true,"sentry_error_count_24h":0
}'

STATE_NON_TICKET='{
  "last_tag":"1.2.24","head_sha":"abc","next_version":"1.2.25",
  "ready_tickets":[],
  "blocking_tickets":[],
  "non_ticket_prs":[{"number":294,"title":"chore: dep bump","author":"dependabot","labels":["deps"]}],
  "staging_ok":true,"sentry_error_count_24h":12
}'

setup() {
  export SLACK_RELEASE_CLICKERS_GROUP_ID=S000RELEASE
  export SLACK_RELEASES_CHANNEL='#releases'
}

@test "ready snapshot matches" {
  run bash -c "echo '$STATE_READY' | '$SCRIPT' --variant ready --draft-url '$DRAFT'"
  [ "$status" -eq 0 ]
  diff <(echo "$output" | jq -S .) <(jq -S . < "$SNAPS/slack-ready.json")
}

@test "held snapshot matches" {
  run bash -c "echo '$STATE_HELD' | '$SCRIPT' --variant held"
  [ "$status" -eq 0 ]
  diff <(echo "$output" | jq -S .) <(jq -S . < "$SNAPS/slack-held.json")
}

@test "non-ticket-only snapshot matches" {
  run bash -c "echo '$STATE_NON_TICKET' | '$SCRIPT' --variant ready --draft-url '$DRAFT'"
  [ "$status" -eq 0 ]
  diff <(echo "$output" | jq -S .) <(jq -S . < "$SNAPS/slack-non-ticket-only.json")
}

@test "ready without --draft-url fails" {
  run bash -c "echo '$STATE_READY' | '$SCRIPT' --variant ready"
  [ "$status" -ne 0 ]
}
