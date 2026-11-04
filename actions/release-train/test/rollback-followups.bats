#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2016 # each @test runs in its own subshell on purpose; literal backticks in expected text.
# What follows a failed prod smoke (SIG-2771), with curl stubbed
# (helpers/rollback-stubs.bash):
#   release-rolled-back.sh  AC2: Linear Release -> Rolled back
#   rollback-incident.sh    AC3/AC5: incident.io incident, Minor or Major
#   rollback-tickets.sh     AC4/AC5: tickets -> QA Failed, Slack alert
load 'helpers/load'
load 'helpers/rollback-stubs'

S="$BATS_TEST_DIRNAME/../scripts"
RUN=https://github.com/signapse/sign-stream-api/actions/runs/42
OK_RESULTS='[{"service":"signstream-api","ok":true,"result":"success","restored":"1.3.0","reason":"restored 1.3.0"}]'
BAD_RESULTS='[{"service":"signstream-api","ok":true,"result":"success","restored":"1.3.0","reason":"restored 1.3.0"},{"service":"signstream-websocket","ok":false,"result":"needs_human","restored":"","reason":"needs a human: the tag history is not clean pipeline changes (exit 4); nothing was changed"}]'

setup() {
  TMP="$(mktemp -d)"
  export TMP
  install_rollback_stubs
  export LINEAR_API_KEY=lin RUN_URL="$RUN" REPOSITORY=signapse/sign-stream-api RELEASE_TAG=1.4.0
}

teardown() { rm -rf "$TMP"; }

field() { tail -n1 <<< "$output" | jq -r "$@"; }

# --- AC2: Linear Release ---------------------------------------------------

@test "AC2: moves the Release to the canceled-type stage Rolled back" {
  write_release Deployed
  RELEASE_ID=rel-1 run "$S/release-rolled-back.sh"
  [ "$status" -eq 0 ]
  [ "$(field .changed)" = true ]
  [ "$(field .from_stage)" = Deployed ]
  [ "$(linear_calls releaseUpdate | jq -c .variables)" = '{"id":"rel-1","input":{"stageId":"stage-rolled-back"}}' ]
}

@test "AC2: idempotent, a Release already Rolled back is left alone" {
  write_release "Rolled back"
  RELEASE_ID=rel-1 run "$S/release-rolled-back.sh"
  [ "$status" -eq 0 ]
  [ "$(field .changed)" = false ]
  [ -z "$(linear_calls releaseUpdate)" ]
}

@test "AC2: the stage name is configurable; a missing stage fails naming the stages" {
  write_release Deployed
  RELEASE_ID=rel-1 STAGE_NAME="Reverted" run "$S/release-rolled-back.sh"
  [ "$status" -eq 1 ]
  [[ "$(field .reason)" == *"has no stage 'Reverted' (has: Deployed, Rolling Out, Released, Rolled back)"* ]]
  [ -z "$(linear_calls releaseUpdate)" ]
}

@test "AC2: no Release id (recording failed earlier): found by version in the pipeline" {
  write_release Deployed
  VERSION=1.4.0 LINEAR_PIPELINE=SignStream run "$S/release-rolled-back.sh"
  [ "$status" -eq 0 ]
  [ "$(linear_calls 'releases(filter' | jq -c .variables)" = '{"pid":"pipe-1","v":"1.4.0"}' ]
  [ "$(field .release_id)" = rel-1 ]
  [ "$(field .changed)" = true ]
}

@test "AC2: no Release recorded at all: reported, nothing invented" {
  VERSION=1.4.0 LINEAR_PIPELINE=SignStream run "$S/release-rolled-back.sh"
  [ "$status" -eq 1 ]
  [[ "$(field .reason)" == *"never recorded"* ]]
}

# --- AC3 / AC5: incident.io ------------------------------------------------

incident_env() {
  export INCIDENT_IO_API_KEY=inc IDEMPOTENCY_KEY=sign-stream-api-42-1-prod \
    MINOR_SEVERITY_ID=sev-p3 MAJOR_SEVERITY_ID=sev-p2 CAUSE_FIELD_ID=field-cause CAUSE_OPTION_ID=opt-deployment \
    LINK_FIELD_ID=field-link TICKETS=SIG-1,SIG-2 REPORT_URL=https://report
}

@test "AC3: rolled back: Minor severity, Cause = Deployment, link to the failing run, idempotency key = deploy run key" {
  incident_env
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-incident.sh"
  [ "$status" -eq 0 ]
  [ "$(field .severity)" = minor ]
  [ "$(field .created)" = true ]
  [ "$(field .url)" = https://app.incident.io/signapse-workspace/incidents/7 ]
  b="$TMP/incident.json"
  [ "$(jq -r .idempotency_key "$b")" = sign-stream-api-42-1-prod ]
  [ "$(jq -r .severity_id "$b")" = sev-p3 ]
  [ "$(jq -r .mode "$b")" = standard ]
  [ "$(jq -c '.custom_field_entries[0]' "$b")" = '{"custom_field_id":"field-cause","values":[{"value_option_id":"opt-deployment"}]}' ]
  [ "$(jq -c '.custom_field_entries[1]' "$b")" = "{\"custom_field_id\":\"field-link\",\"values\":[{\"value_link\":\"$RUN\"}]}" ]
  [[ "$(jq -r .summary "$b")" == *"[Failing run]($RUN)"* ]]
  [[ "$(jq -r .summary "$b")" == *'`signstream-api` → `1.3.0`'* ]]
  [[ "$(jq -r .name "$b")" == *"rolled back"* ]]
  [ "$(jq 'has("incident_type_id")' "$b")" = false ]
}

@test "AC5: rollback failed: Major severity, names the service and the reason" {
  incident_env
  ROLLBACK_OK=false ROLLBACK_RESULTS="$BAD_RESULTS" run "$S/rollback-incident.sh"
  [ "$status" -eq 0 ]
  [ "$(field .severity)" = major ]
  [ "$(jq -r .severity_id "$TMP/incident.json")" = sev-p2 ]
  [[ "$(jq -r .name "$TMP/incident.json")" == *"ROLLBACK FAILED"* ]]
  [[ "$(jq -r .summary "$TMP/incident.json")" == *'`signstream-websocket`: needs a human'* ]]
  [ "$(jq -r '.custom_field_entries[0].values[0].value_option_id' "$TMP/incident.json")" = opt-deployment ]
}

@test "AC3: re-run: the idempotency key was used already (422) is ok, not a second incident" {
  incident_env
  echo 422 > "$TMP/inc-code"
  echo '{"type":"validation_error","status":422,"errors":[{"code":"conflict","message":"An incident with this idempotency_key already exists","source":{"field":"idempotency_key"}}]}' > "$TMP/inc-body"
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-incident.sh"
  [ "$status" -eq 0 ]
  [ "$(field .created)" = false ]
  [[ "$(field .reason)" == *"already opened"* ]]
}

@test "AC3: any other 422 (e.g. a required field) fails with incident.io's message" {
  incident_env
  echo 422 > "$TMP/inc-code"
  echo '{"errors":[{"code":"missing_field","message":"Product is required","source":{"field":"custom_field_entries"}}]}' > "$TMP/inc-body"
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-incident.sh"
  [ "$status" -eq 1 ]
  [[ "$(field .reason)" == *"Product is required"* ]]
}

@test "AC3: no API key: not opened, says what is missing" {
  incident_env
  unset INCIDENT_IO_API_KEY
  ROLLBACK_OK=true run "$S/rollback-incident.sh"
  [ "$status" -eq 1 ]
  [[ "$(field .reason)" == *"INCIDENT_IO_API_KEY"* ]]
  [ ! -f "$TMP/incident.json" ]
}

@test "incident type and test mode are passed through when set" {
  incident_env
  INCIDENT_TYPE_ID=type-1 INCIDENT_MODE=test LINK_FIELD_ID='' ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-incident.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .incident_type_id "$TMP/incident.json")" = type-1 ]
  [ "$(jq -r .mode "$TMP/incident.json")" = test ]
  [ "$(jq '.custom_field_entries | length' "$TMP/incident.json")" = 1 ]
}

# --- AC4 / AC5: tickets and Slack -----------------------------------------

tickets_env() {
  export TICKETS="SIG-1, SIG-2" SLACK_CHANNEL=C123 SLACK_BOT_TOKEN=xoxb INCIDENT_URL=https://app.incident.io/signapse-workspace/incidents/7
}

@test "AC4: every ticket gets a comment and moves to QA Failed; Slack alert to the repo channel" {
  tickets_env
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-tickets.sh"
  [ "$status" -eq 0 ]
  [ "$(field .critical)" = false ]
  [ "$(linear_calls commentCreate | jq -r .variables.id | paste -sd, -)" = uuid-SIG-1,uuid-SIG-2 ]
  [[ "$(linear_calls commentCreate | head -1 | jq -r .variables.b)" == *"$RUN"* ]]
  [ "$(linear_calls workflowStates | jq -r .variables.name)" = "QA Failed" ]
  [ "$(linear_calls issueUpdate | jq -r .variables.id | paste -sd, -)" = SIG-1,SIG-2 ]
  # QA Passed goes with the move to QA Failed (review fix).
  [ "$(linear_calls issueRemoveLabel | jq -c '[.variables.id, .variables.l]' | paste -sd, -)" = '["SIG-1","lbl-qa"],["SIG-2","lbl-qa"]' ]
  [ "$(jq -r .channel "$TMP/slack.log")" = C123 ]
  text=$(jq -r .text "$TMP/slack.log")
  [[ "$text" == *"rolled back"* ]]
  [[ "$text" == *"In QA Failed: SIG-1, SIG-2"* ]]
  [[ "$text" == *"|Incident>"* ]]
  [[ "$text" != *"<!channel>"* ]]
}

@test "AC4: a Done ticket (follow-up commit in the Deployment) is not moved out of Done" {
  tickets_env
  echo Done > "$TMP/state-SIG-2"
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-tickets.sh"
  [ "$status" -eq 0 ]
  [ "$(linear_calls issueUpdate | jq -r .variables.id | paste -sd, -)" = SIG-1 ]
  # It never went back to QA: it keeps QA Passed, and the alert says it stayed.
  [ "$(linear_calls issueRemoveLabel | jq -r .variables.id | paste -sd, -)" = SIG-1 ]
  text=$(jq -r .text "$TMP/slack.log")
  [[ "$text" == *"In QA Failed: SIG-1"* ]]
  [[ "$text" == *"Left where they are: SIG-2 (Done)"* ]]
}

@test "AC4: a run whose URL extends this one's (run 421 vs 42) does not count as commented" {
  tickets_env
  jq -nc --arg b "**Prod smoke failed** after ...

Run: ${RUN}1" '[$b]' > "$TMP/comments-SIG-1"
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-tickets.sh"
  [ "$status" -eq 0 ]
  [ "$(linear_calls commentCreate | jq -r .variables.id | paste -sd, -)" = uuid-SIG-1,uuid-SIG-2 ]
}

@test "AC4: re-run: tickets already commented for this run are not commented again" {
  tickets_env
  jq -nc --arg b "**Prod smoke failed** after ...

Run: ${RUN}
Report: none" '[$b]' > "$TMP/comments-SIG-1"
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-tickets.sh"
  [ "$status" -eq 0 ]
  [ "$(linear_calls commentCreate | jq -r .variables.id | paste -sd, -)" = uuid-SIG-2 ]
  [ "$(linear_calls issueUpdate | wc -l | tr -d ' ')" = 2 ]
}

@test "AC5: rollback failed: critical Slack alert naming services and reasons" {
  tickets_env
  ROLLBACK_OK=false ROLLBACK_RESULTS="$BAD_RESULTS" NOTES=":warning: incident.io incident not opened: x" RUN_ATTEMPT=2 run "$S/rollback-tickets.sh"
  [ "$status" -eq 0 ]
  [ "$(field .critical)" = true ]
  text=$(jq -r .text "$TMP/slack.log")
  [[ "$text" == *"<!channel>"* ]]
  [[ "$text" == *"Prod rollback FAILED"* ]]
  [[ "$text" == *'`signstream-websocket`: needs a human'* ]]
  [[ "$text" == *"incident.io incident not opened"* ]]
  [[ "$text" == *"attempt 2"* ]]
  # Tickets still move (AC5: steps 2-4 still happen).
  [ "$(linear_calls issueUpdate | wc -l | tr -d ' ')" = 2 ]
}

@test "AC4: Linear down: Slack is still alerted, and the script fails naming it" {
  tickets_env
  touch "$TMP/linear-down"
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-tickets.sh"
  [ "$status" -eq 1 ]
  [ "$(field '.errors | length')" -ge 1 ]
  [[ "$(jq -r .text "$TMP/slack.log")" == *"Some Linear updates failed"* ]]
}

@test "no Slack token: the failure is reported" {
  tickets_env
  unset SLACK_BOT_TOKEN
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-tickets.sh"
  [ "$status" -eq 1 ]
  [[ "$(field '.errors | join(" ")')" == *"Slack alert not sent"* ]]
}

@test "AC4: the alert does not claim tickets moved when Linear failed" {
  tickets_env
  touch "$TMP/linear-down"
  ROLLBACK_OK=true ROLLBACK_RESULTS="$OK_RESULTS" run "$S/rollback-tickets.sh"
  [ "$status" -eq 1 ]
  text=$(jq -r .text "$TMP/slack.log")
  [[ "$text" == *"NOT moved to QA Failed (Linear failed): SIG-1, SIG-2"* ]]
  [[ "$text" != *"In QA Failed"* ]]
}
