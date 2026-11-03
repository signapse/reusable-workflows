#!/usr/bin/env bash
# promotion-tag.sh <rc-sha> <rc-image-tag> <release-tag>
#
# The side effects of a staging Promotion (SIG-2764), after promotion-plan.sh
# said go:
#   1. For every service, re-put the Release Candidate's manifest
#      (<rc-image-tag>, main-<n>-<sha>) under <release-tag> in ECR, no rebuild,
#      and check both tags name the same digest (ecr-retag.sh).
#   2. Tag <rc-sha> in git with <release-tag> through the GitHub API.
# ECR goes first and git last: the git tag is what makes the next selection
# report already_promoted, so it must only exist once every image does. Both
# steps are idempotent, so a re-run of a failed attempt finishes the job.
#
# Env:
#   SERVICES           JSON array of ECR repository names (required)
#   ECR_REPO_PREFIX    prefix joined with "/" (e.g. signstream), may be empty
#   GITHUB_REPOSITORY  owner/repo to tag
#   GH_TOKEN           contents:write on GITHUB_REPOSITORY
# Stdout: {"tag", "sha", "digests": {"<repo>": "sha256:..."}, "images": [...]}

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 3 ] || die "usage: promotion-tag.sh <rc-sha> <rc-image-tag> <release-tag>"
RC_SHA="$1"
SRC_TAG="$2"
TAG="$3"
need jq
need gh
need aws
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
[[ "$RC_SHA" =~ ^[0-9a-f]{40}$ ]] || die "rc sha must be a full 40-char sha, got '$RC_SHA'"
HERE="$(dirname "$0")"

repos=$(printf '%s' "${SERVICES:-}" | jq -r --arg p "${ECR_REPO_PREFIX:-}" \
  'if type == "array" and length > 0 then .[] | (if $p == "" then . else "\($p)/\(.)" end) else error("empty") end' 2>/dev/null) \
  || die "SERVICES must be a non-empty JSON array of ECR repository names"

# 1. ECR: same manifest, new tag, digests verified.
images='[]'
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  out=$("$HERE/ecr-retag.sh" "$repo" "$SRC_TAG" "$TAG") || die "retag failed for $repo"
  printf '%s\n' "$out" | sed '$d' >&2
  img=$(printf '%s\n' "$out" | tail -1)
  printf '%s' "$img" | jq -e '.source_digest != "" and .source_digest == .tag_digest' > /dev/null \
    || die "digest mismatch for $repo: $img"
  log "$repo: $SRC_TAG and $TAG are both $(printf '%s' "$img" | jq -r .tag_digest)"
  images=$(jq -nc --argjson a "$images" --argjson i "$img" '$a + [$i]')
done <<< "$repos"

# 2. Git: lightweight tag on the Release Candidate commit. An existing tag on
# the same commit is a re-run; on another commit it is an error.
errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
if gh api -X POST "repos/${GITHUB_REPOSITORY}/git/refs" \
    -f "ref=refs/tags/${TAG}" -f "sha=${RC_SHA}" > /dev/null 2> "$errf"; then
  log "tagged ${RC_SHA:0:7} as $TAG"
else
  existing=$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${TAG}" --jq '.object.sha + " " + .object.type' 2>/dev/null) \
    || die "cannot create tag $TAG: $(cat "$errf")"
  obj="${existing% *}"
  if [ "${existing#* }" = tag ]; then
    obj=$(gh api "repos/${GITHUB_REPOSITORY}/git/tags/${obj}" --jq .object.sha) \
      || die "cannot read annotated tag $TAG"
  fi
  [ "$obj" = "$RC_SHA" ] || die "tag $TAG already exists on ${obj:0:7}, not ${RC_SHA:0:7}"
  log "tag $TAG already on ${RC_SHA:0:7}; nothing to do"
fi

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc --arg t "$TAG" --arg s "$RC_SHA" --argjson i "$images" \
  '{tag: $t, sha: $s, digests: ($i | map({(.repository): .tag_digest}) | add), images: $i}'
