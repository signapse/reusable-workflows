#!/usr/bin/env bash
# lambda-rollback.sh
#
# prod-rollback.sh for Lambda services (SIG-3189): after a failed prod smoke
# or a partial Deployment, points each prod function back at the artefact it
# ran before RELEASE_TAG, with no workflow to dispatch.
#
# Per function in SERVICES (names from lambda_functions):
#   - it must still carry release-tag=RELEASE_TAG; otherwise a newer
#     Deployment or a hand rollback landed after the smoke, and it is left to
#     a human (not_current). One already rolled back from RELEASE_TAG to the
#     expected tag (a re-run) is ok with nothing done.
#   - the previous tag is release-previous-tag (else PREVIOUS_TAGS[name]), the
#     previous code release-previous-code (lib/lambda.sh).
#       zip    <prefix>/<previous tag>.zip in the prod bucket; the restored
#              CodeSha256 must equal release-previous-code when recorded
#       image  release-previous-code (repo@sha256:..., the exact bytes), else
#              <image_repository>:<previous tag>
#   - update-function-code, wait, read back, then release-tag=<previous tag>
#     and RELEASE_TAG added to release-rolled-back-from (newest first), so
#     prod-plan.sh refuses RELEASE_TAG from now on.
#
# Results use prod-rollback.sh's shape so the rollback job, the incident and
# the Slack alert read them unchanged. result:
#   success          ok when the restored code is the recorded previous code
#   no_previous_tag  nothing recorded to roll back to: needs a human
#   not_current      the function no longer runs RELEASE_TAG: needs a human
#   failed           the update or the check failed
#
# Env:
#   SERVICES          JSON array of names to roll back (required)
#   RELEASE_TAG       the tag being rolled back from (required)
#   LAMBDA_FUNCTIONS  the lambda_functions input (required)
#   PREVIOUS_TAGS     optional JSON {name: tag} from the deploy job
#   AWS credentials of the prod role
# Stdout: {ok, needs_human, reason, results: [{service, run_key, run_id, run_url,
#   conclusion, attempts, result, expected, restored, replaced, ok, reason}]}
# Exit 0 whenever that object is printed; exit 1 only on bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/lambda.sh
source "$(dirname "$0")/../lib/lambda.sh"

need aws
need jq

: "${SERVICES:?SERVICES not set}"
: "${RELEASE_TAG:?RELEASE_TAG not set}"
PREVIOUS_TAGS="${PREVIOUS_TAGS:-}"
[ -n "$PREVIOUS_TAGS" ] || PREVIOUS_TAGS='{}'
jq -e 'type == "object"' <<< "$PREVIOUS_TAGS" > /dev/null 2>&1 || die "PREVIOUS_TAGS must be a JSON object (got '$PREVIOUS_TAGS')"
names=$(jq -r 'if type == "array" and length > 0 and all(type == "string") then .[] else error("bad") end' <<< "$SERVICES" 2> /dev/null) \
  || die "SERVICES must be a non-empty JSON array of lambda_functions names (got '$SERVICES')"
cfg=$("$(dirname "$0")/lambda-config.sh" prod)

results='[]'
add() { # add <name> <result> <ok> <expected> <restored> <reason>
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  results=$(jq -c --arg s "$1" --arg r "$2" --argjson ok "$3" --arg e "$4" --arg rs "$5" --arg why "$6" --arg t "$RELEASE_TAG" \
    '. + [{service: $s, run_key: "", run_id: "", run_url: "", conclusion: (if $ok then "success" else "failure" end),
           attempts: 1, result: $r, expected: $e, restored: $rs, replaced: $t, ok: $ok, reason: $why}]' <<< "$results")
}

while IFS= read -r name; do
  [ -n "$name" ] || continue
  fn=$(jq -c --arg n "$name" '.[] | select(.name == $n)' <<< "$cfg")
  [ -n "$fn" ] || { add "$name" failed false "" "" "not in lambda_functions"; continue; }
  function=$(jq -r .function <<< "$fn")
  package=$(jq -r .package <<< "$fn")
  if ! before=$(lambda_read "$function"); then
    add "$name" failed false "" "" "cannot read ${function}; nothing was changed"
    continue
  fi
  arn=$(jq -r .arn <<< "$before")
  tag_of() { jq -r --arg k "$2" '.tags[$k] // ""' <<< "$1"; }
  current=$(tag_of "$before" "$LAMBDA_TAG_RELEASE")
  prev=$(tag_of "$before" "$LAMBDA_TAG_PREVIOUS")
  [ -n "$prev" ] || prev=$(jq -r --arg n "$name" '.[$n] // ""' <<< "$PREVIOUS_TAGS")
  prev_code=$(tag_of "$before" "$LAMBDA_TAG_PREVIOUS_CODE")
  rolled=$(tag_of "$before" "$LAMBDA_TAG_ROLLED_BACK")

  # A re-run after this rollback already happened.
  if [ "$current" != "$RELEASE_TAG" ] && [[ " $rolled " == *" $RELEASE_TAG "* ]]; then
    add "$name" success true "$current" "$current" "already rolled back from ${RELEASE_TAG} to ${current}"
    continue
  fi
  if [ "$current" != "$RELEASE_TAG" ]; then
    add "$name" not_current false "$prev" "" "needs a human: ${function} runs ${current:-an untagged build}, not ${RELEASE_TAG}, so a newer Deployment or a hand rollback landed after the smoke; not rolled back"
    continue
  fi
  if [ -z "$prev" ]; then
    add "$name" no_previous_tag false "" "" "needs a human: ${function} has no ${LAMBDA_TAG_PREVIOUS} and the Deployment recorded none; nothing was changed"
    continue
  fi

  if [ "$package" = zip ]; then
    bucket=$(jq -r .s3_bucket <<< "$fn")
    key="$(jq -r .s3_prefix <<< "$fn")/${prev}.zip"
    update=(--s3-bucket "$bucket" --s3-key "$key")
    target="s3://${bucket}/${key}"
  elif [[ "$prev_code" == *@sha256:* ]]; then
    update=(--image-uri "$prev_code")
    target="$prev_code"
  else
    target="$(jq -r .image_repository <<< "$fn"):${prev}"
    update=(--image-uri "$target")
  fi

  log "${name}: rolling ${function} back from ${RELEASE_TAG} to ${prev} (${target})"
  if ! aws lambda update-function-code --function-name "$function" "${update[@]}" > /dev/null; then
    add "$name" failed false "$prev" "" "update-function-code to ${target} failed (does ${target} exist?); ${function} may still run ${RELEASE_TAG}"
    continue
  fi
  lambda_wait "$function" || log "${name}: waiting for ${function} failed; reading it back"
  if ! after=$(lambda_read "$function"); then
    add "$name" failed false "$prev" "" "cannot read ${function} after the rollback; check what it runs"
    continue
  fi
  code=$(jq -r .code <<< "$after")
  if [ "$(jq -r .update_status <<< "$after")" != Successful ]; then
    add "$name" failed false "$prev" "" "the rollback update of ${function} is $(jq -r .update_status <<< "$after")"
    continue
  fi
  if [ -n "$prev_code" ] && [ "$code" != "$prev_code" ]; then
    add "$name" failed false "$prev" "$prev" "${function} now runs ${code}, but before ${RELEASE_TAG} it ran ${prev_code}: ${target} is not the code it ran before"
    continue
  fi
  # Newest first, within Lambda's 256-character tag value limit.
  list=$(printf '%s %s' "$RELEASE_TAG" "$rolled" | awk '{ out = ""; for (i = 1; i <= NF; i++) { if (length(out) + length($i) + 1 > 256) break; out = out (out == "" ? "" : " ") $i } print out }')
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  tags=$(jq -nc --arg kt "$LAMBDA_TAG_RELEASE" --arg t "$prev" --arg kr "$LAMBDA_TAG_ROLLED_BACK" --arg r "$list" '{($kt): $t, ($kr): $r}')
  if ! lambda_tag "$arn" "$tags" || ! lambda_untag "$arn" "$LAMBDA_TAG_PREVIOUS" "$LAMBDA_TAG_PREVIOUS_CODE" release-deploying; then
    add "$name" failed false "$prev" "$prev" "${function} runs ${prev} again, but recording it in its tags failed: set ${LAMBDA_TAG_RELEASE}=${prev} and add ${RELEASE_TAG} to ${LAMBDA_TAG_ROLLED_BACK} by hand, or the train may deploy ${RELEASE_TAG} again"
    continue
  fi
  why="restored ${prev}"
  [ -n "$prev_code" ] || why="restored ${prev}; no previous code was recorded to check it against"
  add "$name" success true "$prev" "$prev" "$why"
done <<< "$names"

bad=$(jq -r '[.[] | select(.ok | not) | "\(.service): \(.reason)"] | join("; ")' <<< "$results")
if [ -z "$bad" ]; then
  jq -nc --argjson r "$results" '{ok: true, needs_human: false, reason: "every function is back on its previous release", results: $r}'
else
  jq -nc --argjson r "$results" --arg why "$bad" '{ok: false, needs_human: true, reason: $why, results: $r}'
fi
