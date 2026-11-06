#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Staging verdict (SIG-2767): staging-verdict.sh labels, comments, moves and
# alerts after signapse-e2e runs on staging. A fake curl plays Linear and
# Slack, keeping state in $TMP:
#   linear.json   {issues: {SIG-n: {id, team, state, labels: [{id,name}], comments: [body]}},
#                  labels: [{id, name, team|null}]}
#   calls         every Linear write and Slack post, in order
#   fail-<op>     makes that Linear operation return a GraphQL error
#                 (issue, labels, add, remove, comment, states, move)
#   slack-fail    makes Slack answer ok:false
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"
RUN=https://github.com/signapse/demo/actions/runs/42
REPORT=https://reports.example/42/index.html

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub"
  export PATH="$TMP/stub:$PATH"
  : > "$TMP/calls"
  cat > "$TMP/linear.json" <<'EOF'
{"issues": {
  "SIG-1": {"id": "u1", "team": "t1", "state": "On Staging",
            "labels": [{"id": "lab-feature", "name": "Feature"}, {"id": "lab-qa", "name": "QA Passed"}], "comments": []},
  "SIG-2": {"id": "u2", "team": "t2", "state": "On Staging",
            "labels": [{"id": "lab-bug", "name": "Bug"}], "comments": []}},
 "labels": [
  {"id": "sp-t1", "name": "Staging Passed", "team": "t1"},
  {"id": "sf-t1", "name": "Staging Failed", "team": "t1"},
  {"id": "sp-ws", "name": "Staging Passed", "team": null},
  {"id": "sf-ws", "name": "Staging Failed", "team": null}]}
EOF

  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
url=""; body=""; prev=""
for a in "$@"; do
  case "$prev" in
    -d) body="$a" ;;
    --data-binary) [ "$a" = @- ] && body=$(cat) ;;
  esac
  case "$a" in https://*) url="$a" ;; esac
  prev="$a"
done
if [[ "$url" == *slack.com* ]]; then
  echo "slack $(jq -c . <<< "$body")" >> "$TMP/calls"
  if [ -f "$TMP/slack-fail" ]; then echo '{"ok":false,"error":"channel_not_found"}'; else echo '{"ok":true,"ts":"1.2","channel":"C1"}'; fi
  exit 0
fi
q=$(jq -r .query <<< "$body"); v=$(jq -c .variables <<< "$body")
case "$q" in
  *issueLabels*) op=labels ;;
  *issueAddLabel*) op=add ;;
  *issueRemoveLabel*) op=remove ;;
  *commentCreate*) op=comment ;;
  *workflowStates*) op=states ;;
  *issueUpdate*) op=move ;;
  *'issue(id'*) op=issue ;;
  *) echo "curl stub: unhandled query $q" >&2; exit 1 ;;
esac
if [ -f "$TMP/fail-$op" ]; then printf '{"errors":[{"message":"Rate limit exceeded"}],"data":null}\n200'; exit 0; fi
st="$TMP/linear.json"
key() { jq -r --argjson v "$v" '.issues | to_entries[] | select(.key == $v.id or .value.id == $v.id) | .key' "$st"; }
case "$op" in
  issue)
    k=$(key)
    if [ -z "$k" ]; then printf '{"errors":[{"message":"Entity not found: Issue"}],"data":null}\n200'; exit 0; fi
    jq -c --arg k "$k" --argjson v "$v" '.issues[$k] as $i
      | {data: {issue: {id: $i.id, identifier: $k, team: {id: $i.team}, state: {name: $i.state}, labels: {nodes: $i.labels},
                        comments: {nodes: [$i.comments[] | select(contains($v.run // "")) | {body: .}]}}}}' "$st" ;;
  labels)
    echo labels >> "$TMP/calls"
    jq -c --argjson v "$v" '{data: {issueLabels: {nodes: [.labels[]
      | select((.name | ascii_downcase) == ($v.n | ascii_downcase))
      | {id, name, team: (if .team then {id: .team} else null end)}]}}}' "$st" ;;
  add|remove)
    k=$(key)
    name=$(jq -r --argjson v "$v" '[.labels[] | select(.id == $v.l)][0].name // ([.issues[].labels[] | select(.id == $v.l)][0].name)' "$st")
    echo "$op $k $name ($(jq -r .l <<< "$v"))" >> "$TMP/calls"
    if [ "$op" = add ]; then
      jq --arg k "$k" --arg l "$(jq -r .l <<< "$v")" --arg n "$name" '.issues[$k].labels += [{id: $l, name: $n}]' "$st" > "$st.new"
    else
      jq --arg k "$k" --arg l "$(jq -r .l <<< "$v")" '.issues[$k].labels |= map(select(.id != $l))' "$st" > "$st.new"
    fi
    mv "$st.new" "$st"
    f=issueAddLabel; [ "$op" = remove ] && f=issueRemoveLabel
    jq -nc --arg f "$f" '{data: {($f): {success: true}}}' ;;
  comment)
    k=$(key)
    echo "comment $k" >> "$TMP/calls"
    jq --arg k "$k" --argjson v "$v" '.issues[$k].comments += [$v.b]' "$st" > "$st.new" && mv "$st.new" "$st"
    echo '{"data":{"commentCreate":{"success":true}}}' ;;
  states)
    jq -nc --argjson v "$v" '{data: {workflowStates: {nodes: [{id: ("state:" + $v.name)}]}}}' ;;
  move)
    k=$(key)
    s=$(jq -r '.state | sub("^state:"; "")' <<< "$v")
    echo "move $k $s" >> "$TMP/calls"
    jq --arg k "$k" --arg s "$s" '.issues[$k].state = $s' "$st" > "$st.new" && mv "$st.new" "$st"
    echo '{"data":{"issueUpdate":{"success":true}}}' ;;
esac
printf '\n200'
EOS
  chmod +x "$TMP/stub/curl"

  export LINEAR_API_KEY=fake SLACK_BOT_TOKEN=xoxb-fake SLACK_CHANNEL='#demo-releases'
  export RUN_URL="$RUN" REPORT_URL="$REPORT" RC_TICKETS='SIG-1,SIG-2'
  export REPOSITORY=signapse/demo RELEASE_TAG=v1.4.0
  unset SUITE_JOB_RESULT SUITE_RESULT
}

teardown() { rm -rf "$TMP"; }

labels() { jq -c --arg k "$1" '[.issues[$k].labels[].name]' "$TMP/linear.json"; }
state() { jq -r --arg k "$1" '.issues[$k].state' "$TMP/linear.json"; }
comments() { jq -r --arg k "$1" '.issues[$k].comments | length' "$TMP/linear.json"; }
comment() { jq -r --arg k "$1" '.issues[$k].comments[-1]' "$TMP/linear.json"; }
verdict() { "$S/staging-verdict.sh" 2>/dev/null; }

pass() { export SUITE_JOB_RESULT=success SUITE_RESULT=passed; }
fail() { export SUITE_JOB_RESULT=failure SUITE_RESULT=failed; }

@test "AC1/AC4: pass labels every ticket Staging Passed, comments the run, leaves the column" {
  pass
  run verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<< "$output")" = passed ]
  [ "$(jq -r .staging_passed <<< "$output")" = true ]
  [ "$(labels SIG-1)" = '["Feature","QA Passed","Staging Passed"]' ]
  [ "$(labels SIG-2)" = '["Bug","Staging Passed"]' ]
  [ "$(state SIG-1)" = "On Staging" ] && [ "$(state SIG-2)" = "On Staging" ]
  [[ "$(comment SIG-1)" == *"$RUN"* ]] && [[ "$(comment SIG-1)" == *"$REPORT"* ]]
  [[ "$(comment SIG-2)" == *"**Staging Passed**"* ]]
  [ "$(grep -c '^move\|^slack' "$TMP/calls")" -eq 0 ]
}

@test "labels resolve per team: team label first, workspace label for a team without one" {
  pass
  run verdict
  [ "$status" -eq 0 ]
  grep -q '^add SIG-1 Staging Passed (sp-t1)$' "$TMP/calls"
  grep -q '^add SIG-2 Staging Passed (sp-ws)$' "$TMP/calls"
}

@test "AC1: pass replaces Staging Failed and keeps the other labels" {
  jq '.issues["SIG-1"].labels += [{id: "sf-t1", name: "Staging Failed"}]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  pass
  run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-1)" = '["Feature","QA Passed","Staging Passed"]' ]
  grep -q '^remove SIG-1 Staging Failed (sf-t1)$' "$TMP/calls"
}

@test "AC2: fail labels Staging Failed, moves every ticket to QA Failed, comments and alerts Slack" {
  fail
  run verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<< "$output")" = failed ]
  [ "$(jq -r .staging_passed <<< "$output")" = false ]
  # QA Passed goes with the move to QA Failed (ADR 0001, spec "Board and labels").
  [ "$(labels SIG-1)" = '["Feature","Staging Failed"]' ]
  grep -q '^remove SIG-1 QA Passed (lab-qa)$' "$TMP/calls"
  [ "$(labels SIG-2)" = '["Bug","Staging Failed"]' ]
  [ "$(state SIG-1)" = "QA Failed" ] && [ "$(state SIG-2)" = "QA Failed" ]
  [[ "$(comment SIG-2)" == *"**Staging Failed**"*"$RUN"*"$REPORT"* ]]
  [ "$(grep -c '^slack' "$TMP/calls")" -eq 1 ]
  slack=$(grep '^slack' "$TMP/calls" | sed 's/^slack //')
  [ "$(jq -r .channel <<< "$slack")" = '#demo-releases' ]
  [[ "$(jq -r .text <<< "$slack")" == *"SIG-1, SIG-2"*"$RUN"* ]]
}

@test "a pass keeps QA Passed" {
  pass
  run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-1)" = '["Feature","QA Passed","Staging Passed"]' ]
}

@test "a fail never moves a Done ticket (follow-up commit) out of Done" {
  jq '.issues["SIG-2"].state = "Done"' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  fail
  run verdict
  [ "$status" -eq 0 ]
  [ "$(state SIG-2)" = "Done" ]
  [ "$(state SIG-1)" = "QA Failed" ]
  # The alert says it stayed.
  [[ "$(grep '^slack' "$TMP/calls" | sed 's/^slack //' | jq -r .text)" == *"In QA Failed: SIG-1"*"Left where they are: SIG-2 (Done)"* ]]
}

@test "a fail keeps QA Passed on a Done ticket and removes it from the moved ones" {
  jq '.issues["SIG-2"].state = "Done" | .issues["SIG-2"].labels += [{id: "lab-qa2", name: "QA Passed"}]' \
    "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  fail
  run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-2)" = '["Bug","QA Passed","Staging Failed"]' ]
  [ "$(labels SIG-1)" = '["Feature","Staging Failed"]' ]
}

@test "the label lookup is cached across tickets of the same team" {
  jq '.issues["SIG-3"] = {id: "u3", team: "t1", state: "On Staging", labels: [], comments: []}' \
    "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  pass
  RC_TICKETS='SIG-1,SIG-3' run verdict
  [ "$status" -eq 0 ]
  [ "$(grep -c '^add ' "$TMP/calls")" -eq 2 ]
  [ "$(grep -c '^labels$' "$TMP/calls")" -eq 1 ]
}

@test "a comment for a run whose URL extends this one's (run 421 vs 42) does not count" {
  jq --arg r "Run: ${RUN}1" '.issues["SIG-1"].comments += ["**Staging Passed**: ...\n\n" + $r]' \
    "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  pass
  run verdict
  [ "$(comments SIG-1)" -eq 2 ]
}

@test "the alert does not claim tickets moved when the move failed" {
  fail
  touch "$TMP/fail-move"
  run verdict
  [ "$status" -eq 1 ]
  text=$(grep '^slack' "$TMP/calls" | sed 's/^slack //' | jq -r .text)
  [[ "$text" == *"NOT moved to QA Failed (Linear failed): SIG-1, SIG-2"* ]]
  [[ "$text" != *"In QA Failed"* ]]
  # Fail closed: a ticket that should block does not stay selectable.
  [ "$(labels SIG-1)" = '["Feature","Staging Failed"]' ]
}

@test "AC2: fail replaces Staging Passed and keeps the other labels" {
  jq '.issues["SIG-2"].labels += [{id: "sp-ws", name: "Staging Passed"}]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  fail
  run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-2)" = '["Bug","Staging Failed"]' ]
  grep -q '^remove SIG-2 Staging Passed (sp-ws)$' "$TMP/calls"
}

@test "AC5: a suite that errored with no result is a failure, not a pass" {
  export SUITE_JOB_RESULT=failure SUITE_RESULT='' REPORT_URL=''
  run verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<< "$output")" = failed ]
  [ "$(state SIG-1)" = "QA Failed" ]
  [[ "$(comment SIG-1)" == *"untested"*"no report"* ]]
}

@test "AC5: a cancelled suite run is a failure (not tested)" {
  # signapse-e2e reports result=failed for a cancelled run.
  export SUITE_JOB_RESULT=cancelled SUITE_RESULT=failed
  run verdict
  [ "$status" -eq 0 ]
  [ "$(jq -r .verdict <<< "$output")" = failed ]
  [[ "$(jq -r .reason <<< "$output")" == *cancelled* ]]
  [ "$(labels SIG-1)" = '["Feature","Staging Failed"]' ]
  grep -q '^slack' "$TMP/calls"
}

@test "AC5: an unexpectedly skipped suite, or a job success without a pass, is a failure" {
  export SUITE_JOB_RESULT=skipped SUITE_RESULT=''
  run verdict
  [ "$(jq -r .verdict <<< "$output")" = failed ]
  export SUITE_JOB_RESULT=success SUITE_RESULT=''
  run verdict
  [ "$(jq -r .verdict <<< "$output")" = failed ]
}

@test "re-run after a pass: same end state, no duplicate comment, no writes" {
  pass
  run verdict
  [ "$status" -eq 0 ]
  : > "$TMP/calls"
  run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-1)" = '["Feature","QA Passed","Staging Passed"]' ]
  [ "$(comments SIG-1)" -eq 1 ] && [ "$(comments SIG-2)" -eq 1 ]
  [ ! -s "$TMP/calls" ]
}

@test "re-run after a fail: same end state, no duplicate comment" {
  fail
  run verdict
  [ "$status" -eq 0 ]
  run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-2)" = '["Bug","Staging Failed"]' ]
  [ "$(state SIG-2)" = "QA Failed" ]
  [ "$(comments SIG-1)" -eq 1 ] && [ "$(comments SIG-2)" -eq 1 ]
  [ "$(grep -c '^add' "$TMP/calls")" -eq 2 ]
}

@test "re-run that flips the verdict (fail, then pass) swaps labels and comments again" {
  fail
  run verdict
  pass
  run verdict
  [ "$status" -eq 0 ]
  # The flip records the pass, but the fail already sent the ticket to QA
  # Failed without its QA Passed: only QA takes it out, so prod must not run.
  [ "$(labels SIG-1)" = '["Feature","Staging Passed"]' ]
  [ "$(state SIG-1)" = "QA Failed" ]
  [ "$(comments SIG-1)" -eq 2 ]
  echo "$output" | jq -e '.verdict == "passed" and .staging_passed == false
    and (.reason | contains("left SIG-1, SIG-2 in QA Failed"))' > /dev/null
  [[ "$(comment SIG-1)" == *"An earlier attempt sent this ticket to **QA Failed**"* ]]
}

@test "a comment from another run does not count as already commented" {
  jq '.issues["SIG-1"].comments += ["**Staging Passed**: ... Run: https://github.com/signapse/demo/actions/runs/41"]' \
    "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  pass
  run verdict
  [ "$(comments SIG-1)" -eq 2 ]
}

@test "a Linear error fails the job and staging_passed is false, but other tickets are still updated" {
  pass
  # SIG-1 is unknown to Linear; SIG-2 must still be labelled.
  RC_TICKETS='SIG-404,SIG-2' run verdict
  [ "$status" -eq 1 ]
  [ "$(jq -r .verdict <<< "$output")" = passed ]
  [ "$(jq -r .staging_passed <<< "$output")" = false ]
  [[ "$(jq -r '.errors[0]' <<< "$output")" == SIG-404:* ]]
  [ "$(labels SIG-2)" = '["Bug","Staging Passed"]' ]
}

@test "a GraphQL error on a write fails the job instead of passing silently" {
  pass
  touch "$TMP/fail-add"
  run verdict
  [ "$status" -eq 1 ]
  [ "$(jq -r '.errors | length' <<< "$output")" -eq 2 ]
  [[ "$(jq -r '.errors[0]' <<< "$output")" == *"Rate limit"* ]]
}

@test "a missing Staging label fails the job and names it" {
  jq '.labels |= map(select(.name != "Staging Failed"))' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  fail
  run verdict
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.errors[0]' <<< "$output")" == *"label 'Staging Failed' does not exist"* ]]
  # The tickets still move and Slack still hears about it.
  [ "$(state SIG-1)" = "QA Failed" ]
  grep -q '^slack' "$TMP/calls"
}

@test "a failed move to QA Failed fails the job" {
  fail
  touch "$TMP/fail-states"
  run verdict
  [ "$status" -eq 1 ]
  [[ "$output" == *"QA Failed"* ]]
}

@test "a Slack failure, or no channel, fails the job on a staging failure" {
  fail
  touch "$TMP/slack-fail"
  run verdict
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.errors[0]' <<< "$output")" == *channel_not_found* ]]
  SLACK_CHANNEL='' run verdict
  [ "$status" -eq 1 ]
  [[ "$(jq -r '.errors[0]' <<< "$output")" == *"slack_channel"* ]]
}

@test "label names and the QA Failed column are configurable" {
  jq '.labels += [{id: "x-ok", name: "Staging OK", team: null}]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  pass
  STAGING_PASSED_LABEL='Staging OK' run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-2)" = '["Bug","Staging OK"]' ]
  fail
  jq '.labels += [{id: "x-bad", name: "Staging Bad", team: null}]' "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  STAGING_PASSED_LABEL='Staging OK' STAGING_FAILED_LABEL='Staging Bad' QA_FAILED_STATE='Rejected' run verdict
  [ "$status" -eq 0 ]
  [ "$(labels SIG-2)" = '["Bug","Staging Bad"]' ]
  [ "$(state SIG-2)" = "Rejected" ]
}

@test "no tickets: no Linear calls; a failure still alerts Slack" {
  fail
  RC_TICKETS='' LINEAR_API_KEY='' run verdict
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$TMP/calls")" -eq 1 ]
  [[ "$(grep '^slack' "$TMP/calls")" == *"untracked commits only"* ]]
}
