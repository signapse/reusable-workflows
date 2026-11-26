#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq bindings ($a, $c, ...) in single quotes throughout, not shell expansion.
# lambda-deploy.sh
#
# Deploys a release tag to one environment's Lambda functions (SIG-3189), in
# place of Flux (staging) and deploy-prod.yml (prod) for Lambda services.
# Synchronous: when it reports ok, every function runs the release artefact
# and says so in its release-tag tag (lib/lambda.sh).
#
# Per function in LAMBDA_FUNCTIONS, one at a time:
#   1. The artefact, never rebuilt:
#      zip    s3-artefact-copy.sh copies SOURCE_ENV's
#             <prefix>/<SOURCE_ARTEFACT>.zip to TARGET_ENV's <prefix>/<TAG>.zip
#             (staging: from the dev build main-<n>-<sha>; prod: from
#             staging's <TAG>.zip), refusing different bytes under that name.
#             The function must then report that SHA-256 as its CodeSha256.
#      image  <image_repository>@<digest> when IMAGE_DIGESTS names the digest
#             (the Promotion's ecr-retag.sh result), else <image_repository>:<TAG>
#             (ecr-retag.sh never moves a release tag). The digest Lambda
#             resolved is checked against IMAGE_DIGESTS when given.
#   2. Skip it when it already runs those bytes and carries release-tag=TAG
#      (a re-run).
#   3. Before changing the code, record what runs now: release-previous-tag
#      and release-previous-code, and release-deploying=TAG. A re-run that
#      finds release-deploying=TAG keeps the recorded previous values, which
#      a first attempt that died after the code update would otherwise
#      overwrite with the new code.
#   4. update-function-code, wait (function-updated-v2), read it back and
#      check the code, then release-tag=TAG (release-deploying removed).
#
# On a failure it stops and reports which functions run the new code now
# (`moved`: a partial Deployment, which the rollback restores), and
# unknown=true when a function's state could not be read after an update was
# sent (never guessed: a human checks).
#
# Env:
#   TAG               release tag (required)
#   LAMBDA_FUNCTIONS  the lambda_functions input (required)
#   TARGET_ENV        stg or prod (required)
#   SOURCE_ENV        environment whose bucket holds the ZIP to copy (required with ZIPs)
#   SOURCE_ARTEFACT   that ZIP's name without .zip (main-<n>-<sha>, or TAG)
#   IMAGE_DIGESTS     optional JSON {ecr_repository: "sha256:..."}
#   PREVIOUS_TAGS     optional JSON {name: tag}: what prod ran before, when a
#                     function has no release-tag yet
#   ARTEFACTS_ONLY    true: step 1 only (the Promotion puts the release ZIPs
#                     in place before the git tag, like ECR, and deploys after)
#   AWS credentials of TARGET_ENV's role (and read access to SOURCE_ENV's bucket)
# Stdout: {ok, reason, unknown, moved: [names], functions: [{service, function,
#   package, artefact, expected, previous_tag, previous_code, code, changed, on_new}]}
# Exit 0 whenever that object is printed; exit 1 only on bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/lambda.sh
source "$(dirname "$0")/../lib/lambda.sh"

need aws
need jq
HERE="$(dirname "$0")"

: "${TAG:?TAG not set}"
: "${TARGET_ENV:?TARGET_ENV not set}"
[[ "$TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "TAG must be a release tag (semver), got '$TAG'"
case "$TARGET_ENV" in stg | prod) ;; *) die "TARGET_ENV must be stg or prod (got '$TARGET_ENV')" ;; esac
IMAGE_DIGESTS="${IMAGE_DIGESTS:-}"
[ -n "$IMAGE_DIGESTS" ] || IMAGE_DIGESTS='{}'
PREVIOUS_TAGS="${PREVIOUS_TAGS:-}"
[ -n "$PREVIOUS_TAGS" ] || PREVIOUS_TAGS='{}'
jq -e 'type == "object"' <<< "$IMAGE_DIGESTS" > /dev/null 2>&1 || die "IMAGE_DIGESTS must be a JSON object (got '$IMAGE_DIGESTS')"
jq -e 'type == "object"' <<< "$PREVIOUS_TAGS" > /dev/null 2>&1 || die "PREVIOUS_TAGS must be a JSON object (got '$PREVIOUS_TAGS')"

target=$("$HERE/lambda-config.sh" "$TARGET_ENV")
source_cfg='[]'
if jq -e 'any(.[]; .package == "zip")' <<< "$target" > /dev/null; then
  : "${SOURCE_ENV:?SOURCE_ENV not set (the bucket the ZIP is copied from)}"
  [[ "${SOURCE_ARTEFACT:-}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "SOURCE_ARTEFACT must name the source ZIP (main-<n>-<sha> or the tag), got '${SOURCE_ARTEFACT:-}'"
  source_cfg=$("$HERE/lambda-config.sh" "$SOURCE_ENV")
fi

functions='[]'
unknown=false
moved() { jq -c '[.[] | select(.on_new) | .service]' <<< "$functions"; }
result() { # result <ok> <reason>
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  jq -nc --argjson ok "$1" --arg r "$2" --argjson u "$unknown" --argjson m "$(moved)" --argjson f "$functions" \
    '{ok: $ok, reason: $r, unknown: $u, moved: $m, functions: $f}'
  exit 0
}
cur='{}'
record() { functions=$(jq -c --argjson c "$cur" '. + [$c]' <<< "$functions"); }
set_cur() { cur=$(jq -c "$@" <<< "$cur"); }

while IFS= read -r fn; do
  [ -n "$fn" ] || continue
  name=$(jq -r .name <<< "$fn")
  function=$(jq -r .function <<< "$fn")
  package=$(jq -r .package <<< "$fn")
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  cur=$(jq -nc --arg s "$name" --arg f "$function" --arg p "$package" \
    '{service: $s, function: $f, package: $p, artefact: "", expected: "", previous_tag: "", previous_code: "", code: "", changed: false, on_new: false}')

  # 1. The artefact.
  if [ "$package" = zip ]; then
    prefix=$(jq -r .s3_prefix <<< "$fn")
    src_bucket=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .s3_bucket' <<< "$source_cfg")
    dest="s3://$(jq -r .s3_bucket <<< "$fn")/${prefix}/${TAG}.zip"
    if ! copy=$("$HERE/s3-artefact-copy.sh" "s3://${src_bucket}/${prefix}/${SOURCE_ARTEFACT}.zip" "$dest"); then
      record
      result false "${name}: could not put the release artefact ${dest} (see the log); nothing was deployed to ${function}"
    fi
    printf '%s\n' "$copy" | sed '$d' >&2
    expected=$(printf '%s\n' "$copy" | tail -1 | jq -r .code_sha256)
    artefact="$dest"
    update=(--s3-bucket "$(jq -r .s3_bucket <<< "$fn")" --s3-key "${prefix}/${TAG}.zip")
  else
    repo=$(jq -r .image_repository <<< "$fn")
    expected=$(jq -r --arg r "$(jq -r .ecr_repository <<< "$fn")" '.[$r] // ""' <<< "$IMAGE_DIGESTS")
    if [ -n "$expected" ]; then artefact="${repo}@${expected}"; else artefact="${repo}:${TAG}"; fi
    update=(--image-uri "$artefact")
  fi
  set_cur '.artefact = $a | .expected = $e' --arg a "$artefact" --arg e "$expected"
  if [ "${ARTEFACTS_ONLY:-false}" = true ]; then
    record
    continue
  fi

  # on_code <lambda_read json>: the function runs the release artefact.
  on_code() {
    if [ "$package" = zip ]; then
      [ "$(jq -r .code <<< "$1")" = "$expected" ]
    elif [ -n "$expected" ]; then
      [ "$(jq -r .digest <<< "$1")" = "$expected" ]
    else
      false
    fi
  }

  # 2. Already there?
  after=""
  before=$(lambda_read "$function") || { record; result false "${name}: cannot read ${function}; nothing was deployed to it"; }
  arn=$(jq -r .arn <<< "$before")
  have_tag=$(jq -r --arg k "$LAMBDA_TAG_RELEASE" '.tags[$k] // ""' <<< "$before")
  deploying=$(jq -r '.tags["release-deploying"] // ""' <<< "$before")
  # An image deployed by tag has no digest to compare: the tag is enough.
  if [ "$have_tag" = "$TAG" ] && { on_code "$before" || [ "$package:$expected" = image: ]; }; then
    set_cur '.code = $c | .on_new = true | .previous_tag = $p | .previous_code = $pc' \
      --arg c "$(jq -r .code <<< "$before")" \
      --arg p "$(jq -r --arg k "$LAMBDA_TAG_PREVIOUS" '.tags[$k] // ""' <<< "$before")" \
      --arg pc "$(jq -r --arg k "$LAMBDA_TAG_PREVIOUS_CODE" '.tags[$k] // ""' <<< "$before")"
    log "${name}: ${function} already runs ${TAG}; nothing to do"
    record
    continue
  fi

  # 3. What runs now, unless an earlier attempt at TAG recorded it already.
  if [ "$deploying" = "$TAG" ]; then
    prev_tag=$(jq -r --arg k "$LAMBDA_TAG_PREVIOUS" '.tags[$k] // ""' <<< "$before")
    prev_code=$(jq -r --arg k "$LAMBDA_TAG_PREVIOUS_CODE" '.tags[$k] // ""' <<< "$before")
    log "${name}: an earlier attempt started deploying ${TAG}; keeping its record of the previous code (${prev_tag:-no tag})"
  else
    prev_tag="$have_tag"
    [ -n "$prev_tag" ] || prev_tag=$(jq -r --arg n "$name" '.[$n] // ""' <<< "$PREVIOUS_TAGS")
    prev_code=$(jq -r .code <<< "$before")
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    tags=$(jq -nc --arg t "$TAG" --arg kp "$LAMBDA_TAG_PREVIOUS" --arg p "$prev_tag" --arg kc "$LAMBDA_TAG_PREVIOUS_CODE" --arg c "$prev_code" \
      '{"release-deploying": $t} + (if $p != "" then {($kp): $p} else {} end) + (if $c != "" then {($kc): $c} else {} end)')
    lambda_tag "$arn" "$tags" || { record; result false "${name}: could not tag ${function} before the deploy; nothing was deployed to it"; }
  fi
  set_cur '.previous_tag = $p | .previous_code = $c' --arg p "$prev_tag" --arg c "$prev_code"

  # 4. Deploy and check.
  if ! on_code "$before"; then
    log "${name}: updating ${function} to ${artefact}"
    if ! aws lambda update-function-code --function-name "$function" "${update[@]}" > /dev/null; then
      # A rejected request changes nothing, but a timeout might have: read it.
      if after=$(lambda_read "$function") && on_code "$after"; then
        set_cur '.on_new = true | .changed = true | .code = $c' --arg c "$(jq -r .code <<< "$after")"
      elif [ -z "${after:-}" ]; then
        unknown=true
      fi
      record
      result false "${name}: update-function-code failed for ${function}"
    fi
    set_cur '.changed = true'
    lambda_wait "$function" || log "${name}: waiting for ${function} failed; reading it back"
  fi
  after=$(lambda_read "$function") || { unknown=true; record; result false "${name}: cannot read ${function} after the update; check what it runs"; }
  code=$(jq -r .code <<< "$after")
  set_cur '.code = $c' --arg c "$code"
  if [ "$(jq -r .update_status <<< "$after")" != Successful ]; then
    on_code "$after" && set_cur '.on_new = true'
    record
    result false "${name}: ${function}'s last update is $(jq -r .update_status <<< "$after") (state $(jq -r .state <<< "$after"))"
  fi
  if [ "$package" = image ] && [ -z "$expected" ]; then
    # Deployed by tag: Lambda resolved it, record what it runs.
    expected=$(jq -r .digest <<< "$after")
    [ -n "$expected" ] || { unknown=true; record; result false "${name}: ${function} reports no image digest after the update"; }
    set_cur '.expected = $e' --arg e "$expected"
  fi
  if ! on_code "$after"; then
    record
    result false "${name}: ${function} runs ${code:-nothing readable}, not the release artefact ${expected} (${artefact})"
  fi
  set_cur '.on_new = true'
  if ! lambda_tag "$arn" "$(jq -nc --arg k "$LAMBDA_TAG_RELEASE" --arg t "$TAG" '{($k): $t}')" \
    || ! lambda_untag "$arn" release-deploying; then
    record
    result false "${name}: ${function} runs ${TAG}, but setting its ${LAMBDA_TAG_RELEASE} tag failed; re-run to finish"
  fi
  log "${name}: ${function} runs ${TAG} (${code})"
  record
done < <(jq -c '.[]' <<< "$target")

[ "${ARTEFACTS_ONLY:-false}" != true ] || result true "every ZIP release artefact for ${TAG} is in place"
result true "every function runs ${TAG}"
