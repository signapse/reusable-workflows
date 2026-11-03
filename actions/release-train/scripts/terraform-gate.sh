#!/usr/bin/env bash
# terraform-gate.sh
#
# Terraform gate before a Promotion (SIG-2765, ADR 0002). Dispatches
# signapse-core-terraform's terraform-deploy.yml (contract: SIG-2751) for one
# product and environment with apply=true, finds the run by the run_key in its
# title, waits for it (bounded) and reads its `terraform-verdict` artifact.
# The Terraform repo does the plan, the classification and the apply with its
# own AWS role; this side only dispatches and reads (ADR 0005).
#
# Verdict -> gate:
#   no_changes            pass     nothing to apply
#   safe + applied        pass     creates/updates only, applied by the run
#   blocked               blocked  destroy, replace or unrecognised action;
#                                  nothing applied, a human must review
#   failed                failed   plan or apply error
#   anything else         failed   missing artifact, unknown verdict, verdict
#                                  for another product/environment, timeout
# Retries, both bounded by MAX_DISPATCHES and TIMEOUT_SECONDS:
#   run concluded `cancelled`: GitHub keeps one pending run per concurrency
#     group (product+environment+region), so a newer dispatch cancelled ours
#     before it ran, or someone cancelled it. Re-dispatch: a fresh plan is
#     re-classified, so this is safe even after a partial apply.
#   verdict failed, apply attempted, log says "Saved plan is stale": another
#     apply changed the state between plan and apply; nothing from the plan
#     was applied. Re-dispatch once.
# A run still going at the timeout is NOT cancelled (it may be mid-apply); the
# result names it so a human can follow it.
#
# Env:
#   PRODUCT          terragrunt/products dir, from .signapse/pipeline.yml (required)
#   ENVIRONMENT      dev | stg | prod (required)
#   RUN_KEY          unique prefix for this gate; dispatch n gets RUN_KEY-n (required)
#   TF_REPO          default signapse/signapse-core-terraform
#   TF_WORKFLOW      default terraform-deploy.yml
#   TF_REF           ref to dispatch on, default main
#   TF_REGION        eu | us, default eu
#   TIMEOUT_SECONDS  budget for finding + waiting, all dispatches (default 2700)
#   FIND_TIMEOUT_SECONDS  per dispatch, until the run shows up (default 300)
#   POLL_SECONDS     default 30
#   MAX_DISPATCHES   default 4 (first dispatch + 3 re-dispatches)
# Needs GH_TOKEN with actions: write on TF_REPO.
#
# Stdout: one JSON object
#   {gate: pass|blocked|failed, verdict, reason, product, environment,
#    applied, apply_attempted, destroys, replaces, unclassified,
#    run_id, run_url, run_key, conclusion, dispatches}
# Exit 0 whenever that object is printed (the caller acts on .gate); exit 1
# only on bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need gh
need jq

: "${PRODUCT:?PRODUCT not set}"
: "${ENVIRONMENT:?ENVIRONMENT not set}"
: "${RUN_KEY:?RUN_KEY not set}"
TF_REPO="${TF_REPO:-signapse/signapse-core-terraform}"
TF_WORKFLOW="${TF_WORKFLOW:-terraform-deploy.yml}"
TF_REF="${TF_REF:-main}"
TF_REGION="${TF_REGION:-eu}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-2700}"
FIND_TIMEOUT_SECONDS="${FIND_TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-30}"
MAX_DISPATCHES="${MAX_DISPATCHES:-4}"

case "$ENVIRONMENT" in dev | stg | prod) ;; *) die "ENVIRONMENT must be dev, stg or prod (got '$ENVIRONMENT')" ;; esac
case "$TF_REGION" in eu | us) ;; *) die "TF_REGION must be eu or us (got '$TF_REGION')" ;; esac
[[ "$PRODUCT" =~ ^[A-Za-z0-9_-]+$ ]] || die "PRODUCT must be a terragrunt/products directory name (got '$PRODUCT')"
[[ "$RUN_KEY" =~ ^[A-Za-z0-9._-]+$ ]] || die "RUN_KEY must be [A-Za-z0-9._-] (got '$RUN_KEY')"
for n in "$TIMEOUT_SECONDS" "$FIND_TIMEOUT_SECONDS" "$POLL_SECONDS" "$MAX_DISPATCHES"; do
  case "$n" in "" | *[!0-9]*) die "numeric env expected, got '$n'" ;; esac
done
[ "$POLL_SECONDS" -gt 0 ] || die "POLL_SECONDS must be > 0"
[ "$MAX_DISPATCHES" -gt 0 ] || die "MAX_DISPATCHES must be > 0"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

dispatches=0
key=""
run_id=""
run_url=""
conclusion=""
verdict_json='{}'
elapsed=0

# result <gate> <reason>: print the result object and stop.
result() {
  jq -nc --arg gate "$1" --arg reason "$2" --arg product "$PRODUCT" --arg env "$ENVIRONMENT" \
    --arg run_id "$run_id" --arg run_url "$run_url" --arg key "$key" \
    --arg conclusion "$conclusion" --argjson n "$dispatches" --argjson v "$verdict_json" '
    {gate: $gate, verdict: ($v.verdict // null), reason: $reason,
     product: $product, environment: $env,
     applied: ($v.applied // false), apply_attempted: ($v.apply_attempted // false),
     destroys: ($v.destroys // []), replaces: ($v.replaces // []),
     unclassified: ($v.unclassified // []),
     run_id: $run_id, run_url: $run_url, run_key: $key,
     conclusion: $conclusion, dispatches: $n}'
  exit 0
}

# tick: one poll interval, or false when the overall budget is spent.
tick() {
  [ "$elapsed" -lt "$TIMEOUT_SECONDS" ] || return 1
  sleep "$POLL_SECONDS"
  elapsed=$((elapsed + POLL_SECONDS))
}

dispatch() {
  gh api -X POST "repos/${TF_REPO}/actions/workflows/${TF_WORKFLOW}/dispatches" \
    -f ref="$TF_REF" \
    -f "inputs[product]=$PRODUCT" \
    -f "inputs[environment]=$ENVIRONMENT" \
    -f "inputs[region]=$TF_REGION" \
    -f "inputs[action]=plan" \
    -f "inputs[apply]=true" \
    -f "inputs[run_key]=$key" > /dev/null 2> "$work/err"
}

# find_run: sets run_id/run_url for the run whose title carries [key].
find_run() {
  local waited=0 runs
  while :; do
    if runs=$(gh api "repos/${TF_REPO}/actions/workflows/${TF_WORKFLOW}/runs?event=workflow_dispatch&per_page=100" 2> "$work/err"); then
      run_id=$(jq -r --arg k "[$key]" \
        '[.workflow_runs[]? | select(.display_title | contains($k))] | first | .id // empty' <<< "$runs" 2> /dev/null || true)
      if [ -n "$run_id" ]; then
        run_url=$(jq -r --argjson id "$run_id" '.workflow_runs[] | select(.id == $id) | .html_url' <<< "$runs")
        log "found run ${run_id} for ${key}: ${run_url}"
        return 0
      fi
    else
      log "listing runs failed, retrying: $(cat "$work/err")"
    fi
    [ "$waited" -lt "$FIND_TIMEOUT_SECONDS" ] || return 1
    tick || return 1
    waited=$((waited + POLL_SECONDS))
  done
}

# wait_run: sets conclusion once the run completes; false on timeout.
wait_run() {
  local run status
  while :; do
    if run=$(gh api "repos/${TF_REPO}/actions/runs/${run_id}" 2> "$work/err"); then
      status=$(jq -r '.status // ""' <<< "$run")
      if [ "$status" = completed ]; then
        conclusion=$(jq -r '.conclusion // ""' <<< "$run")
        log "run ${run_id} completed: ${conclusion}"
        return 0
      fi
      log "run ${run_id} is ${status:-?} (${elapsed}s of ${TIMEOUT_SECONDS}s)"
    else
      log "reading run ${run_id} failed, retrying: $(cat "$work/err")"
    fi
    tick || return 1
  done
}

stale_retried=false
while :; do
  if [ "$dispatches" -ge "$MAX_DISPATCHES" ]; then
    result failed "gave up after ${dispatches} dispatches: every run was cancelled or went stale before giving a verdict (another run for ${PRODUCT}/${ENVIRONMENT} kept superseding it)"
  fi
  dispatches=$((dispatches + 1))
  key="${RUN_KEY}-${dispatches}"
  run_id="" run_url="" conclusion="" verdict_json='{}'

  log "dispatching ${TF_WORKFLOW} on ${TF_REPO}@${TF_REF}: ${PRODUCT} ${ENVIRONMENT}/${TF_REGION} apply=true run_key=${key}"
  dispatch || result failed "could not dispatch ${TF_WORKFLOW} on ${TF_REPO}: $(cat "$work/err")"

  find_run || result failed "no ${TF_WORKFLOW} run titled [${key}] appeared on ${TF_REPO}; the dispatch may not have started a run"

  if ! wait_run; then
    result failed "timed out after ${TIMEOUT_SECONDS}s waiting for the Terraform run; it was NOT cancelled and may still apply. Follow it before re-running the Promotion"
  fi

  if [ "$conclusion" = cancelled ]; then
    log "run ${run_id} was cancelled (superseded in its concurrency group); re-dispatching"
    continue
  fi

  rm -rf "$work/artifact"
  if ! gh run download "$run_id" -R "$TF_REPO" -n terraform-verdict -D "$work/artifact" > /dev/null 2> "$work/err" \
    || [ ! -f "$work/artifact/verdict.json" ]; then
    result failed "run concluded ${conclusion:-?} without a terraform-verdict artifact: $(cat "$work/err")"
  fi
  if ! verdict_json=$(jq -ce 'if type == "object" then . else error("not an object") end' "$work/artifact/verdict.json" 2> /dev/null); then
    verdict_json='{}'
    result failed "terraform-verdict/verdict.json is not a JSON object"
  fi

  got=$(jq -r '"\(.product)/\(.environment)"' <<< "$verdict_json")
  [ "$got" = "${PRODUCT}/${ENVIRONMENT}" ] \
    || result failed "verdict is for ${got}, not ${PRODUCT}/${ENVIRONMENT}"

  verdict=$(jq -r '.verdict // ""' <<< "$verdict_json")
  case "$verdict" in
    no_changes) result pass "no infrastructure changes" ;;
    safe)
      [ "$(jq -r '.applied' <<< "$verdict_json")" = true ] \
        || result failed "plan was safe but the run did not apply it"
      result pass "creates and updates only; applied" ;;
    blocked) result blocked "the plan destroys, replaces or makes a change the classifier does not recognise; nothing was applied" ;;
    failed)
      if [ "$stale_retried" = false ] \
        && [ "$(jq -r '.apply_attempted == true and .applied != true' <<< "$verdict_json")" = true ] \
        && gh run view "$run_id" -R "$TF_REPO" --log-failed 2> /dev/null | grep -qi 'saved plan is stale'; then
        log "run ${run_id}: saved plan went stale (another apply ran in between); re-dispatching once"
        stale_retried=true
        continue
      fi
      if [ "$(jq -r '.apply_attempted == true and .applied != true' <<< "$verdict_json")" = true ]; then
        result failed "the apply failed part-way and may have partially changed infrastructure; re-plan before retrying"
      fi
      result failed "the Terraform plan failed" ;;
    *) result failed "unknown verdict '${verdict}'" ;;
  esac
done
