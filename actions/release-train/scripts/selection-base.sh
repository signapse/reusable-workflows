#!/usr/bin/env bash
# selection-base.sh
#
# Where the Release Candidate walk starts (SIG-2761, ADR 0001): the release
# tag prod runs. Everything after it is not in prod yet, so the walk checks
# all of it on every run, including tags already promoted to staging. A tag
# that failed staging, or that prod rolled back from, leaves its tickets in
# QA Failed; starting here keeps them stopping the line, where starting at the
# last Promotion tag would let the next candidate carry their code to prod.
# After a rollback prod runs the previous tag again, so that is the base.
#
# Env:
#   SELECTION_BASE   explicit base (tag or sha), skips prod. For a repo's first
#                    Deployment through the train, when prod runs a tag this
#                    repo does not have.
#   PROD_SERVICES    JSON array of deploy-prod.yml service names (prod-tags.sh)
#   GITOPS_REPO, GITOPS_REF, GH_TOKEN   see prod-tags.sh
#   RELEASE_TAG_PATTERN  default ^v?[0-9]+\.[0-9]+\.[0-9]+$
# Runs in a full checkout of the product repo; HEAD is the walk's head.
# Stdout: {base, source: "input"|"prod", services: [{service, current_tag}]}
# Exits 1 when prod runs something that is not a release tag of this repo on
# HEAD's history: guessing a base could skip unapproved commits.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need git
need jq
HERE="$(dirname "$0")"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-^v?[0-9]+\.[0-9]+\.[0-9]+$}"

# on_release_branch <rev>: on HEAD's first-parent line, which
# release-candidate.sh walks. Any ancestor is not enough: a commit on a merged
# side branch would make the walk start from the wrong place.
on_release_branch() {
  local c
  c=$(git rev-parse -q --verify "${1}^{commit}") || return 1
  # No grep -q: an early exit would SIGPIPE rev-list under pipefail.
  git rev-list --first-parent HEAD | grep -x "$c" > /dev/null
}

if [ -n "${SELECTION_BASE:-}" ]; then
  git rev-parse -q --verify "${SELECTION_BASE}^{commit}" > /dev/null \
    || die "selection_base '$SELECTION_BASE' is not a commit in this repo"
  on_release_branch "$SELECTION_BASE" \
    || die "selection_base '$SELECTION_BASE' is not on the release branch"
  jq -nc --arg b "$SELECTION_BASE" '{base: $b, source: "input", services: []}'
  exit 0
fi

[ -n "${PROD_SERVICES:-}" ] && [ "$PROD_SERVICES" != '[]' ] \
  || die "prod_services is required: the walk starts at the tag prod runs (or set selection_base)"
services=$("$HERE/prod-tags.sh")

base=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  printf '%s\n' "$t" | grep -qE "$RELEASE_TAG_PATTERN" \
    || die "prod runs '$t', which is not a release tag; set selection_base for the first Deployment through the train"
  git rev-parse -q --verify "refs/tags/${t}^{commit}" > /dev/null \
    || die "prod runs '$t', which is not a tag in this repo; set selection_base for the first Deployment through the train"
  on_release_branch "$t" || die "prod runs '$t', which is not on the release branch"
  # Services may differ mid-deploy: walk from the oldest code in prod.
  if [ -z "$base" ] || git merge-base --is-ancestor "$t" "$base"; then base="$t"; fi
done < <(jq -r '.[].current_tag' <<< "$services")

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc --arg b "$base" --argjson s "$services" \
  '{base: $b, source: "prod", services: [$s[] | {service, current_tag}]}'
