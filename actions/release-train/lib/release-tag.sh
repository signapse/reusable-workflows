#!/usr/bin/env bash
# release-tag.sh: release tags on the release branch. Source this file.
# Exposes:
#   last_release_tag <head-sha> <tag-ERE>
#     The last Promotion: the nearest matching tag on <head-sha>'s
#     first-parent history. Ancestry, not version order: a tag on a merged
#     side branch, or a mix of bare and v-prefixed tags, must not move the
#     boundary. Tags on one commit are tried highest version first. Prints
#     nothing when no tag matches.
#   release_tag_at <sha> <tag-ERE>
#     The highest matching tag pointing at <sha>, or nothing.
# Used by release-candidate.sh (SIG-2761), selection-base.sh and
# qa-failed-revert.sh (SIG-2766).

last_release_tag() {
  local head_sha="$1" pattern="$2" tagmap
  tagmap=$(git tag --merged "$head_sha" --sort=-v:refname \
    | { grep -E "$pattern" || true; } \
    | while IFS= read -r t; do printf '%s %s\n' "$(git rev-parse "${t}^{commit}")" "$t"; done)
  [ -n "$tagmap" ] || return 0
  git rev-list --first-parent "$head_sha" \
    | awk 'NR == FNR { if (!($1 in m)) m[$1] = $2; next } ($1 in m) { print m[$1]; exit }' \
      <(printf '%s\n' "$tagmap") -
}

release_tag_at() {
  git tag --points-at "$1" --sort=-v:refname | { grep -E "$2" || true; } | head -1
}
