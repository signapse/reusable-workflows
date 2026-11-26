#!/usr/bin/env bash
# Lambda helpers for the release train (SIG-3189). Source after common.sh.
#
# What a function runs is recorded on the function itself, as tags the train
# writes (Terraform must ignore them: docs/RELEASE-TRAIN.md "Lambda services"):
#   release-tag               the release tag it runs
#   release-previous-tag      what it ran before that tag (for the rollback)
#   release-previous-code     that earlier code: CodeSha256 for a ZIP, the
#                             resolved image URI (with digest) for an image
#   release-rolled-back-from  space-separated tags the rollback moved it off,
#                             newest first; the train never deploys them again
# A tag value is at most 256 characters of letters, digits, spaces and
# _ . : / = + - @, which covers semver, base64 and image URIs.

# shellcheck disable=SC2034 # used by the scripts that source this file.
LAMBDA_TAG_RELEASE=release-tag
LAMBDA_TAG_PREVIOUS=release-previous-tag
LAMBDA_TAG_PREVIOUS_CODE=release-previous-code
LAMBDA_TAG_ROLLED_BACK=release-rolled-back-from

# lambda_read <function>: {function, arn, package, code, digest, state,
# update_status, tags}. code is what identifies the running bytes: the base64
# CodeSha256 of a ZIP, the resolved image URI (repo@sha256:...) of an image.
# Returns 1 (message on stderr) when the function cannot be read.
lambda_read() {
  local out
  out=$(aws lambda get-function --function-name "$1" --output json 2>&1) || {
    printf 'cannot read Lambda %s: %s\n' "$1" "$out" >&2
    return 1
  }
  jq -c --arg f "$1" '{
    function: $f,
    arn: (.Configuration.FunctionArn // ""),
    package: (if .Configuration.PackageType == "Image" then "image" else "zip" end),
    code: (if .Configuration.PackageType == "Image" then (.Code.ResolvedImageUri // "") else (.Configuration.CodeSha256 // "") end),
    digest: ((.Code.ResolvedImageUri // "") | capture("@(?<d>sha256:[0-9a-f]{64})$").d // ""),
    state: (.Configuration.State // ""),
    update_status: (.Configuration.LastUpdateStatus // ""),
    tags: (.Tags // {})}' <<< "$out"
}

# lambda_tag <arn> <json-object>: sets those tags on the function. JSON, not
# the k=v shorthand: base64 values end in "=" and rolled-back lists hold spaces.
lambda_tag() {
  aws lambda tag-resource --resource "$1" --tags "$2" > /dev/null
}

# lambda_untag <arn> <key>...
lambda_untag() {
  local arn="$1"
  shift
  aws lambda untag-resource --resource "$arn" --tag-keys "$@" > /dev/null
}

# lambda_wait <function>: until the last update finished; fails unless it
# succeeded.
lambda_wait() {
  aws lambda wait function-updated-v2 --function-name "$1" > /dev/null
}
