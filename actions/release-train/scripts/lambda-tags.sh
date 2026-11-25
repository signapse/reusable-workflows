#!/usr/bin/env bash
# lambda-tags.sh [<release-tag>]
# lambda-tags.sh --require-all <release-tag>
#
# prod-tags.sh for Lambda services (SIG-3189): which release tag each prod
# function runs, read from the function's own tags (lib/lambda.sh), not from
# signapse-core-k8s. prod-tags.sh hands over to this script when
# LAMBDA_FUNCTIONS is set, so selection-base.sh, prod-plan.sh and the prod
# checks work unchanged. Same output shape as prod-tags.sh:
#   current_tag        release-tag
#   on_tag             current_tag == <release-tag>
#   rolled_back        <release-tag> is in release-rolled-back-from: the train
#                      moved this function off it and never deploys it again
#   deployed_previous  release-previous-tag while on <release-tag>: what ran
#                      before (the rollback restores it)
# plus function (the function name), code (CodeSha256 or the resolved image
# URI) and previous_code (release-previous-code).
#
# Env:
#   LAMBDA_FUNCTIONS  the lambda_functions input (lambda-config.sh)
#   LAMBDA_ENV        environment to read (default prod)
#   AWS credentials that allow lambda:GetFunction on the functions
# Exits 1 when a function cannot be read or carries no release-tag: a guess
# could deploy over, or skip, a function. Tag it by hand for the first
# Deployment through the train (docs/RELEASE-TRAIN.md).
# --require-all: prints nothing when every function runs <release-tag>;
# otherwise prints "<name> runs <tag>, ..." and exits 2.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/lambda.sh
source "$(dirname "$0")/../lib/lambda.sh"

REQUIRE_ALL=false
if [ "${1:-}" = --require-all ]; then
  REQUIRE_ALL=true
  shift
  [ $# -eq 1 ] && [ -n "$1" ] || die "usage: lambda-tags.sh --require-all <release-tag>"
fi
[ $# -le 1 ] || die "usage: lambda-tags.sh [<release-tag>]"
TAG="${1:-}"
need aws
need jq

fns=$("$(dirname "$0")/lambda-config.sh" "${LAMBDA_ENV:-prod}")

out='[]'
while IFS= read -r fn; do
  [ -n "$fn" ] || continue
  name=$(jq -r .name <<< "$fn")
  function=$(jq -r .function <<< "$fn")
  got=$(lambda_read "$function") || die "reading ${name} failed"
  current=$(jq -r --arg k "$LAMBDA_TAG_RELEASE" '.tags[$k] // ""' <<< "$got")
  [ -n "$current" ] || die "Lambda ${function} (${name}) has no ${LAMBDA_TAG_RELEASE} tag, so what it runs is unknown. For the first Deployment through the train, tag it with the release tag it runs (docs/RELEASE-TRAIN.md \"Lambda services\")"
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  out=$(jq -c --argjson a "$out" --arg s "$name" --arg t "$TAG" --arg c "$current" \
    --arg kp "$LAMBDA_TAG_PREVIOUS" --arg kc "$LAMBDA_TAG_PREVIOUS_CODE" --arg kr "$LAMBDA_TAG_ROLLED_BACK" '
    $a + [{service: $s, path: .function, function: .function, current_tag: $c,
           on_tag: ($t != "" and $c == $t),
           rolled_back: ($t != "" and ((.tags[$kr] // "") | split(" ") | index($t) != null)),
           deployed_previous: (if $t != "" and $c == $t then (.tags[$kp] // "") else "" end),
           code: .code, previous_code: (.tags[$kc] // "")}]' <<< "$got")
done < <(jq -c '.[]' <<< "$fns")

if [ "$REQUIRE_ALL" = true ]; then
  off=$(jq -r '[.[] | select(.on_tag | not) | "\(.service) runs \(.current_tag)"] | join(", ")' <<< "$out")
  [ -z "$off" ] || { echo "$off"; exit 2; }
  exit 0
fi
echo "$out"
