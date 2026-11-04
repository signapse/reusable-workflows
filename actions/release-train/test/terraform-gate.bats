#!/usr/bin/env bats
# Terraform gate (SIG-2765): terraform-gate.sh dispatches terraform-deploy.yml,
# finds its run by run_key, waits and reads the terraform-verdict artifact.
# The gh stub models signapse-core-terraform. Dispatch n (1-based) gets run id
# 100+n and behaves as $TMP/sc/<n>/ says:
#   conclusion    success | failure | cancelled | never (stays in_progress)
#   verdict.json  the artifact (absent: no artifact)
#   log           what `gh run view --log-failed` prints
#   polls         in_progress polls before it completes (default 1)
# Every gh call is appended to $TMP/gh.log; sleeps to $TMP/slept.
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/sc"
  export PATH="$TMP/stub:$PATH"
  : > "$TMP/dispatched"
  : > "$TMP/gh.log"

  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$TMP/gh.log"
if [ "$1" = api ]; then
  shift
  if [ "$1" = -X ]; then
    [ -f "$TMP/dispatch-fail" ] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
    key=$(printf '%s\n' "$@" | sed -n 's/^inputs\[run_key\]=//p')
    echo "$key" >> "$TMP/dispatched"
    printf '%s\n' "$@" > "$TMP/dispatch-args-$(wc -l < "$TMP/dispatched" | tr -d ' ')"
    exit 0
  fi
  case "$1" in
    */workflows/*/runs\?*)
      if [ -f "$TMP/no-runs" ]; then echo '{"workflow_runs":[]}'; exit 0; fi
      jq -Rn '[inputs] | to_entries | map({id: (101 + .key),
        display_title: ("Terraform plan+apply Signstream (stg/eu) [" + .value + "]"),
        html_url: ("https://github.com/signapse/signapse-core-terraform/actions/runs/\(101 + .key)")})
        | reverse | {workflow_runs: .}' < "$TMP/dispatched" ;;
    */actions/runs/*)
      n=$(( ${1##*/} - 100 )); d="$TMP/sc/$n"
      c=$(cat "$d/conclusion")
      p=$(cat "$d/polled" 2>/dev/null || echo 0); echo $((p + 1)) > "$d/polled"
      if [ "$c" = never ] || [ "$p" -lt "$(cat "$d/polls" 2>/dev/null || echo 1)" ]; then
        echo '{"status":"in_progress","conclusion":null}'
      else
        jq -nc --arg c "$c" '{status: "completed", conclusion: $c}'
      fi ;;
    *) echo "gh stub: unhandled api $1" >&2; exit 1 ;;
  esac
elif [ "$1" = run ]; then
  n=$(( $3 - 100 )); d="$TMP/sc/$n"
  case "$2" in
    download)
      out=""; while [ $# -gt 0 ]; do [ "$1" = -D ] && out="$2"; shift; done
      [ -f "$d/verdict.json" ] || { echo "no valid artifacts found to download" >&2; exit 1; }
      mkdir -p "$out"; cp "$d/verdict.json" "$out/verdict.json" ;;
    view) cat "$d/log" 2>/dev/null || true ;;
  esac
fi
EOS
  cat > "$TMP/stub/sleep" <<'EOS'
#!/usr/bin/env bash
echo "$1" >> "$TMP/slept"
EOS
  chmod +x "$TMP/stub/"*

  export GH_TOKEN=x PRODUCT=Signstream ENVIRONMENT=stg RUN_KEY=sign-stream-api-42-1-stg
  export POLL_SECONDS=30 TIMEOUT_SECONDS=600 FIND_TIMEOUT_SECONDS=90
}

teardown() { rm -rf "$TMP"; }

# run_as <n> <conclusion> [verdict] [applied] [apply_attempted] [destroys-json] [replaces-json]
run_as() {
  mkdir -p "$TMP/sc/$1"
  echo "$2" > "$TMP/sc/$1/conclusion"
  [ -n "${3:-}" ] || return 0
  jq -nc --arg v "$3" --argjson a "${4:-false}" --argjson t "${5:-false}" \
    --argjson d "${6:-[]}" --argjson r "${7:-[]}" \
    '{product: "Signstream", environment: "stg", verdict: $v, applied: $a,
      apply_attempted: $t, destroys: $d, replaces: $r, unclassified: []}' > "$TMP/sc/$1/verdict.json"
}

gate() { run "$S/terraform-gate.sh"; }
# stdout is one JSON line, after the stderr log lines.
field() { tail -n1 <<< "$output" | jq -r "$1"; }

@test "dispatches terraform-deploy.yml on main with product, environment, apply=true and a run_key" {
  run_as 1 success no_changes
  gate
  [ "$status" -eq 0 ]
  args="$TMP/dispatch-args-1"
  grep -qx 'repos/signapse/signapse-core-terraform/actions/workflows/terraform-deploy.yml/dispatches' "$args"
  grep -qx 'ref=main' "$args"
  grep -qx 'inputs\[product\]=Signstream' "$args"
  grep -qx 'inputs\[environment\]=stg' "$args"
  grep -qx 'inputs\[region\]=eu' "$args"
  grep -qx 'inputs\[action\]=plan' "$args"
  grep -qx 'inputs\[apply\]=true' "$args"
  grep -qx 'inputs\[run_key\]=sign-stream-api-42-1-stg-1' "$args"
}

@test "AC3: no_changes passes without applying" {
  run_as 1 success no_changes false false
  gate
  [ "$status" -eq 0 ]
  [ "$(field .gate)" = pass ]
  [ "$(field .verdict)" = no_changes ]
  [ "$(field .applied)" = false ]
  [ "$(field .run_url)" = "https://github.com/signapse/signapse-core-terraform/actions/runs/101" ]
  [ "$(field .dispatches)" = 1 ]
}

@test "AC1: safe and applied passes" {
  run_as 1 success safe true true
  gate
  [ "$(field .gate)" = pass ]
  [ "$(field .verdict)" = safe ]
  [ "$(field .applied)" = true ]
}

@test "safe but not applied fails (the gate always asks for apply)" {
  run_as 1 success safe false false
  gate
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"did not apply"* ]]
}

@test "AC2: blocked carries every destroy and replace" {
  run_as 1 failure blocked false false '["aws_ssm_parameter.old"]' '["aws_db_instance.main"]'
  gate
  [ "$status" -eq 0 ]
  [ "$(field .gate)" = blocked ]
  [ "$(field '.destroys | join(",")')" = aws_ssm_parameter.old ]
  [ "$(field '.replaces | join(",")')" = aws_db_instance.main ]
  [ "$(field .product)" = Signstream ]
  [ "$(field .environment)" = stg ]
}

@test "AC5: failed plan fails the gate" {
  run_as 1 failure failed false false
  gate
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"plan failed"* ]]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" -eq 1 ]
}

@test "AC5: a partial apply failure fails without retrying and says so" {
  run_as 1 failure failed false true
  echo "Error: creating SQS queue: AccessDenied" > "$TMP/sc/1/log"
  gate
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"partially"* ]]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" -eq 1 ]
}

@test "cancelled run is re-dispatched with a new run_key" {
  run_as 1 cancelled
  run_as 2 success safe true true
  gate
  [ "$(field .gate)" = pass ]
  [ "$(field .dispatches)" = 2 ]
  [ "$(field .run_key)" = sign-stream-api-42-1-stg-2 ]
  [ "$(sed -n 2p "$TMP/dispatched")" = sign-stream-api-42-1-stg-2 ]
  # a cancelled run is never read for a verdict
  ! grep -q 'run download 101' "$TMP/gh.log"
}

@test "cancelled re-dispatches are bounded by MAX_DISPATCHES" {
  for n in 1 2 3; do run_as "$n" cancelled; done
  MAX_DISPATCHES=3 gate
  [ "$status" -eq 0 ]
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"gave up after 3 dispatches"* ]]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" -eq 3 ]
}

@test "stale saved plan is re-dispatched once" {
  run_as 1 failure failed false true
  echo "Error: Saved plan is stale" > "$TMP/sc/1/log"
  run_as 2 success safe true true
  gate
  [ "$(field .gate)" = pass ]
  [ "$(field .dispatches)" = 2 ]
}

@test "stale saved plan twice fails (one retry only)" {
  for n in 1 2; do
    run_as "$n" failure failed false true
    echo "Error: Saved plan is stale" > "$TMP/sc/$n/log"
  done
  run_as 3 success no_changes
  gate
  [ "$(field .gate)" = failed ]
  [ "$(wc -l < "$TMP/dispatched" | tr -d ' ')" -eq 2 ]
}

@test "missing terraform-verdict artifact fails" {
  run_as 1 failure
  gate
  [ "$status" -eq 0 ]
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"without a terraform-verdict artifact"* ]]
  [[ "$(field .reason)" == *"no valid artifacts"* ]]
}

@test "a verdict for another product or environment fails" {
  run_as 1 success no_changes
  jq '.environment = "prod"' "$TMP/sc/1/verdict.json" > "$TMP/v" && mv "$TMP/v" "$TMP/sc/1/verdict.json"
  gate
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"Signstream/prod"* ]]
}

@test "unknown verdict fails" {
  run_as 1 success maybe
  gate
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"unknown verdict 'maybe'"* ]]
}

@test "timeout: fails, names the run and does not cancel it" {
  run_as 1 never
  TIMEOUT_SECONDS=120 gate
  [ "$status" -eq 0 ]
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"timed out after 120s"* ]]
  [[ "$(field .reason)" == *"NOT cancelled"* ]]
  [ "$(field .run_url)" = "https://github.com/signapse/signapse-core-terraform/actions/runs/101" ]
  [ "$(awk '{s+=$1} END{print s+0}' "$TMP/slept")" -eq 120 ]
  ! grep -q cancel "$TMP/gh.log"
}

@test "waits while the run is in progress" {
  run_as 1 success no_changes
  echo 3 > "$TMP/sc/1/polls"
  gate
  [ "$(field .gate)" = pass ]
  [ "$(wc -l < "$TMP/slept" | tr -d ' ')" -eq 3 ]
}

@test "a run that never shows up fails after FIND_TIMEOUT_SECONDS" {
  run_as 1 success no_changes
  touch "$TMP/no-runs"
  gate
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"no terraform-deploy.yml run titled [sign-stream-api-42-1-stg-1]"* ]]
  [ "$(awk '{s+=$1} END{print s+0}' "$TMP/slept")" -le 120 ]
}

@test "a failed dispatch fails with GitHub's error" {
  touch "$TMP/dispatch-fail"
  gate
  [ "$(field .gate)" = failed ]
  [[ "$(field .reason)" == *"HTTP 403"* ]]
}

@test "run_key prefix match does not pick another gate's run" {
  # key ...-stg-1 must not match a title carrying ...-stg-10
  echo "sign-stream-api-42-1-stg-10" > "$TMP/dispatched"
  mkdir -p "$TMP/sc/1" "$TMP/sc/2"
  echo never > "$TMP/sc/1/conclusion"
  run_as 2 success no_changes
  gate
  [ "$(field .gate)" = pass ]
  [ "$(field .run_url)" = "https://github.com/signapse/signapse-core-terraform/actions/runs/102" ]
}

@test "bad input exits non-zero" {
  ENVIRONMENT=staging run "$S/terraform-gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev, stg or prod"* ]]
}

# --- pipeline-config.sh ---------------------------------------------------

@test "pipeline-config reads product, stripping quotes and comments" {
  mkdir -p "$TMP/r/.signapse"
  printf 'linear_pipeline: SignStream\nproduct: "Signstream"   # terragrunt dir\n' > "$TMP/r/.signapse/pipeline.yml"
  run "$S/pipeline-config.sh" product "$TMP/r/.signapse/pipeline.yml"
  [ "$status" -eq 0 ]
  [ "$output" = Signstream ]
}

@test "pipeline-config --required fails clearly without the file or the key" {
  run "$S/pipeline-config.sh" product --required "$TMP/nope.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  printf 'linear_pipeline: SignStream\n' > "$TMP/p.yml"
  run "$S/pipeline-config.sh" product --required "$TMP/p.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no 'product:' value"* ]]
}

@test "pipeline-config without --required prints nothing for a missing key (SIG-2760's optional keys)" {
  printf 'product: Signstream\n' > "$TMP/p.yml"
  run "$S/pipeline-config.sh" sentry_project "$TMP/p.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$S/pipeline-config.sh" product "$TMP/nope.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the gate action reads product with --required" {
  grep -q 'pipeline-config.sh" product --required' "$BATS_TEST_DIRNAME/../../terraform-gate/action.yml"
}

# --- terraform-gate-alert.sh ----------------------------------------------

@test "AC2: blocked alert names product, environment and each resource" {
  run bash -c "jq -nc '{gate: \"blocked\", product: \"Signstream\", environment: \"stg\",
      destroys: [\"aws_ssm_parameter.old\"], replaces: [\"aws_db_instance.main\"], unclassified: [],
      run_url: \"https://x/runs/1\"}' | SLACK_CHANNEL=C1 CONTEXT='Promotion of signapse/api main-1-abc to staging' '$S/terraform-gate-alert.sh'"
  [ "$status" -eq 0 ]
  text=$(jq -r '.blocks[0].text.text' <<< "$output")
  [ "$(jq -r .channel <<< "$output")" = C1 ]
  [[ "$text" == *"Product *Signstream*, environment *stg*"* ]]
  [[ "$text" == *'`aws_ssm_parameter.old`'* ]]
  [[ "$text" == *'`aws_db_instance.main`'* ]]
  [[ "$text" == *"Promotion of signapse/api main-1-abc to staging"* ]]
  [[ "$text" != *unclassified* ]]
}

@test "AC5: failed alert names product, environment and reason" {
  run bash -c "jq -nc '{gate: \"failed\", product: \"Signstream\", environment: \"stg\", reason: \"the Terraform plan failed\", run_url: \"\"}' \
    | SLACK_CHANNEL=C1 '$S/terraform-gate-alert.sh'"
  [ "$status" -eq 0 ]
  text=$(jq -r '.blocks[0].text.text' <<< "$output")
  [[ "$text" == *"Terraform failed"* ]]
  [[ "$text" == *"*Signstream*, environment *stg*: the Terraform plan failed"* ]]
}

@test "AC4: unapplied alert names ticket, PR and products" {
  run bash -c "jq -nc '{gate: \"unapplied\", product: \"Signstream\", environment: \"stg\",
      pending: [{ticket: \"SIG-7\", pr: 12, url: \"https://github.com/signapse/signapse-core-terraform/pull/12\", products: [\"Hub\"]}]}' \
    | SLACK_CHANNEL=C1 '$S/terraform-gate-alert.sh'"
  [ "$status" -eq 0 ]
  text=$(jq -r '.blocks[0].text.text' <<< "$output")
  [[ "$text" == *"SIG-7: <https://github.com/signapse/signapse-core-terraform/pull/12|signapse-core-terraform#12> (Hub)"* ]]
  [[ "$text" == *"not applied in stg"* ]]
}
