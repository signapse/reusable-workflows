#!/usr/bin/env bash
# promotion-version.sh <rc-sha>
#
# Picks the release tag for a Promotion of <rc-sha>. Stdin: the tickets' label
# arrays (ticket-labels.sh output) for version-bump.sh: any `major` label bumps
# major, any `minor` bumps minor, otherwise patch.
#
#   * <rc-sha> already carries a release tag: reuse it (existing: true). A
#     re-run never cuts a second version for the same build.
#   * Otherwise bump the HIGHEST release tag in the repo, not the nearest one.
#     Flux's staging and prod ImagePolicies pick the highest semver tag, so a
#     new tag below an existing one would never deploy.
# The new tag keeps the highest tag's prefix: bare (1.2.45) or `v` (v1.2.45).
# Signapse repos and ECR use bare semver today, and some staging ImagePolicies
# only accept bare tags (signapse-core-k8s workloads/stg/*/image-policy*.yaml).
#
# Env: RELEASE_TAG_PATTERN (default ^v?[0-9]+\.[0-9]+\.[0-9]+$)
# Stdout: {"tag", "version", "previous_tag", "existing": bool}

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 1 ] || die "usage: promotion-version.sh <rc-sha>"
need git
need jq
RC_SHA=$(git rev-parse --verify "${1}^{commit}") || die "unknown commit: $1"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-^v?[0-9]+\.[0-9]+\.[0-9]+$}"

# "<major> <minor> <patch> <tag>" per release tag, highest version last.
by_version() {
  { grep -E "$RELEASE_TAG_PATTERN" || true; } \
    | sed -nE 's/^(v?)([0-9]+)\.([0-9]+)\.([0-9]+)$/\2 \3 \4 \1\2.\3.\4/p' \
    | sort -t' ' -k1,1n -k2,2n -k3,3n
}

labels=$(cat)
[ -n "$labels" ] || labels='[]'

existing=$(git tag --points-at "$RC_SHA" | by_version | tail -1 | cut -d' ' -f4)
if [ -n "$existing" ]; then
  log "$RC_SHA already carries $existing; reusing it"
  jq -nc --arg t "$existing" \
    '{tag: $t, version: ($t | ltrimstr("v")), previous_tag: "", existing: true}'
  exit 0
fi

prev=$(git tag | by_version | tail -1 | cut -d' ' -f4)
[ -n "$prev" ] || die "no tag matching $RELEASE_TAG_PATTERN; seed one (git tag 0.0.0 <sha>)"
prefix=""
[ "${prev:0:1}" = v ] && prefix=v
next=$(printf '%s' "$labels" | "$(dirname "$0")/version-bump.sh" "${prev#v}")
tag="${prefix}${next}"
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
  die "next tag $tag already exists on another commit"
fi
log "next version: $prev -> $tag"
jq -nc --arg t "$tag" --arg v "$next" --arg p "$prev" \
  '{tag: $t, version: $v, previous_tag: $p, existing: false}'
