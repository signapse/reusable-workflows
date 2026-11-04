#!/usr/bin/env bash
# qa-failed-tickets.sh <tickets>
#
# Sends tickets back to QA (ADR 0001, spec "Board and labels"): moves each of
# <tickets> (comma-separated) to QA_FAILED_STATE with the Ticket Transitioner,
# then removes QA_PASSED_LABEL from every ticket that is in QA Failed now or
# whose move failed. QA approval does not survive QA Failed, so a fix merged
# later cannot ride on the old approval. A ticket left alone because it is
# Done (a follow-up commit in the range) keeps its QA Passed: it never went
# back to QA. When the move result cannot be read at all, QA Passed is removed
# from every ticket (fail closed: a ticket that should block must not stay
# selectable).
#
# One place for this, used by the staging verdict (SIG-2767) and the prod
# rollback (SIG-2771), so both say the same thing about what happened.
#
# Env: LINEAR_API_KEY (when there are tickets), QA_FAILED_STATE (QA Failed),
#      QA_PASSED_LABEL (QA Passed), DONE_STATE, LINEAR_TEAM_KEY.
# Stdout: {moved: [ids], already: [ids], kept: [{id, state}], failed: [ids],
#          qa_passed_removed: [ids], errors: [msgs]}
# Exit 1 when any Linear call failed; the object is printed either way.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 1 ] || die "usage: qa-failed-tickets.sh <tickets>"
need jq
HERE="$(dirname "$0")"
QA_FAILED="${QA_FAILED_STATE:-QA Failed}"
QA_PASSED="${QA_PASSED_LABEL:-QA Passed}"

ids=$(jq -nc --arg t "$1" '$t | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))')
errors='[]'
add_error() { errors=$(jq -nc --argjson e "$errors" --arg m "$1" '$e + [$m]'); log "ERROR: $1"; }

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
res='[]'
if [ "$ids" != '[]' ]; then
  set +e
  # Any column may go to QA Failed (only Done is final), whatever ALLOWED_FROM the caller set.
  out=$(printf '%s' "$ids" | ALLOWED_FROM='' "$HERE/ticket-transitioner.sh" "$QA_FAILED" 2> "$errf")
  rc=$?
  set -e
  cat "$errf" >&2
  if [ "$rc" -eq 0 ] && jq -e 'type == "array"' <<< "$out" > /dev/null 2>&1; then
    res="$out"
    # shellcheck disable=SC2016 # jq program, not shell expansion.
    failed=$(jq -r '[.[] | select(.success != true) | "\(.id)\(if .error then " (\(.error))" else "" end)"] | join(", ")' <<< "$res")
    [ -z "$failed" ] || add_error "could not move to '${QA_FAILED}': $failed"
  else
    add_error "could not move to '${QA_FAILED}': $(grep -v '^\[' "$errf" | tail -n 1)"
    res=$(jq -c 'map({id: ., success: false, moved: false})' <<< "$ids")
  fi
fi

# Everyone but a ticket left in another column on purpose (Done) loses QA Passed.
strip=$(jq -c --arg qf "$QA_FAILED" '[.[] | select(.success != true or .moved == true or .from == $qf) | .id]' <<< "$res")
removed='[]'
if [ "$strip" != '[]' ]; then
  set +e
  out=$("$HERE/ticket-labels-remove.sh" "$QA_PASSED" "$(jq -r 'join(",")' <<< "$strip")" 2> "$errf")
  rc=$?
  set -e
  cat "$errf" >&2
  [ "$rc" -eq 0 ] || add_error "could not remove '${QA_PASSED}' from every ticket in ${QA_FAILED}"
  removed=$(jq -c '[.[]? | select((.removed | length) > 0) | .id]' <<< "${out:-[]}" 2> /dev/null || echo '[]')
fi

# shellcheck disable=SC2016 # jq program, not shell expansion.
jq -nc --argjson r "$res" --arg qf "$QA_FAILED" --argjson q "$removed" --argjson e "$errors" '{
  moved: [$r[] | select(.success == true and .moved == true) | .id],
  already: [$r[] | select(.success == true and .moved != true and .from == $qf) | .id],
  kept: [$r[] | select(.success == true and .moved != true and .from != $qf) | {id, state: .from}],
  failed: [$r[] | select(.success != true) | .id],
  qa_passed_removed: $q,
  errors: $e}'
[ "$(jq length <<< "$errors")" -eq 0 ] || exit 1
