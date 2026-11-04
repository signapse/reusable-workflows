#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Forward-only column moves (ticket-transitioner.sh) and label removal
# (ticket-labels-remove.sh). A fake curl plays Linear from $TMP/issues.json:
# {id: {state, labels: [names]}}; it records moves and removals in $TMP/calls.
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub"
  export PATH="$TMP/stub:$PATH"
  : > "$TMP/calls"
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
prev=""; body=""
for a in "$@"; do [ "$prev" = -d ] && body="$a"; prev="$a"; done
q=$(jq -r .query <<< "$body")
id=$(jq -r '.variables.id // ""' <<< "$body")
[ -f "$TMP/down-$id" ] && { printf 'boom\n500'; exit 0; }
case "$q" in
  *workflowStates*)
    echo "team $(jq -r .variables.team <<< "$body")" >> "$TMP/calls"
    printf '{"data":{"workflowStates":{"nodes":[{"id":"state-%s"}]}}}\n200' "$(jq -r .variables.name <<< "$body" | tr ' ' _)" ;;
  *issueUpdate*)
    echo "move $id $(jq -r .variables.state <<< "$body")" >> "$TMP/calls"
    printf '{"data":{"issueUpdate":{"success":true}}}\n200' ;;
  *issueRemoveLabel*)
    echo "unlabel $id $(jq -r .variables.l <<< "$body")" >> "$TMP/calls"
    printf '{"data":{"issueRemoveLabel":{"success":true}}}\n200' ;;
  *state*)
    jq -c --arg id "$id" '{data: {issue: (if has($id) then {state: {name: .[$id].state}} else null end)}}' "$TMP/issues.json"
    printf '\n200' ;;
  *labels*)
    jq -c --arg id "$id" '{data: {issue: (if has($id) then {labels: {nodes: [.[$id].labels[] | {id: "lbl-\(.)", name: .}]}} else null end)}}' "$TMP/issues.json"
    printf '\n200' ;;
esac
EOS
  chmod +x "$TMP/stub/curl"
  cat > "$TMP/issues.json" <<'EOF2'
{"SIG-1": {"state": "On Dev · Ready for QA", "labels": ["QA Passed", "Staging Passed"]},
 "SIG-2": {"state": "On Prod", "labels": ["QA Passed", "Staging Failed", "Bug"]},
 "SIG-3": {"state": "QA Failed", "labels": ["QA Passed"]},
 "SIG-4": {"state": "Done", "labels": []},
 "SIG-5": {"state": "On Staging", "labels": []}}
EOF2
  export LINEAR_API_KEY=x
}

teardown() { rm -rf "$TMP"; }

move() { printf '%s' "$2" | "$S/ticket-transitioner.sh" "$1" 2> "$TMP/stderr"; }

@test "moves from an allowed column; the team key is configurable" {
  LINEAR_TEAM_KEY=ENG ALLOWED_FROM="On Dev · Ready for QA" run move "On Staging" '["SIG-1"]'
  [ "$status" -eq 0 ]
  grep -qx "team ENG" "$TMP/calls"
  grep -qx "move SIG-1 state-On_Staging" "$TMP/calls"
  jq -e '.[0] | .success and .moved and .from == "On Dev · Ready for QA"' <<< "$output"
}

@test "never moves backwards: a ticket further on is skipped, not an error" {
  ALLOWED_FROM="On Dev · Ready for QA" run move "On Staging" '["SIG-2"]'
  [ "$status" -eq 0 ]
  [ "$(grep -c "^move" "$TMP/calls")" -eq 0 ]
  jq -e '.[0] | .success and (.moved | not) and (.reason | test("not one of"))' <<< "$output"
}

@test "never moves a ticket out of QA Failed or Done, whatever ALLOWED_FROM says" {
  run move "On Prod" '["SIG-3","SIG-4"]'
  [ "$status" -eq 0 ]
  [ "$(grep -c "^move" "$TMP/calls")" -eq 0 ]
  jq -e 'all(.[]; .success and (.moved | not))' <<< "$output"
}

@test "a ticket already in the target column is a no-op" {
  run move "On Staging" '["SIG-5"]'
  [ "$status" -eq 0 ]
  [ "$(grep -c "^move" "$TMP/calls")" -eq 0 ]
}

@test "moving to QA Failed works from On Prod" {
  run move "QA Failed" '["SIG-2"]'
  [ "$status" -eq 0 ]
  grep -qx "move SIG-2 state-QA_Failed" "$TMP/calls"
}

@test "an unreadable ticket is a failure for that ticket only" {
  touch "$TMP/down-SIG-1"
  run move "On Staging" '["SIG-1","SIG-5"]'
  [ "$status" -eq 0 ]
  jq -e '(.[0].success | not) and .[1].success' <<< "$output"
}

@test "promotion-tickets.sh fails on an unreadable ticket, not on a skipped one" {
  touch "$TMP/down-SIG-1"
  run "$S/promotion-tickets.sh" "On Staging" "SIG-1,SIG-2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SIG-1"* ]]
  run "$S/promotion-tickets.sh" "On Staging" "SIG-2,SIG-3"
  [ "$status" -eq 0 ]
}

@test "labels: removes only the named labels the ticket carries" {
  run "$S/ticket-labels-remove.sh" "Staging Passed,Staging Failed" "SIG-1,SIG-2,SIG-4"
  [ "$status" -eq 0 ]
  grep -qx "unlabel SIG-1 lbl-Staging Passed" "$TMP/calls"
  grep -qx "unlabel SIG-2 lbl-Staging Failed" "$TMP/calls"
  [ "$(grep -c '^unlabel' "$TMP/calls")" -eq 2 ]
  jq -e '.[2].removed == []' <<< "$output"
}

@test "labels: a Linear failure fails after trying every ticket" {
  touch "$TMP/down-SIG-1"
  run "$S/ticket-labels-remove.sh" "QA Passed" "SIG-1,SIG-3"
  [ "$status" -ne 0 ]
  grep -qx "unlabel SIG-3 lbl-QA Passed" "$TMP/calls"
}

@test "labels: no tickets needs no Linear key" {
  unset LINEAR_API_KEY
  run "$S/ticket-labels-remove.sh" "QA Passed" ""
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}
