#!/usr/bin/env bash
# revert.sh: which commits on the release branch were reverted. Source this
# file. ADR 0001: a ticket that sits in QA Failed gets a revert PR after 24 h
# (SIG-2766), and once that revert is on main the ticket stops the line no
# longer. Reverts are recognised by git's own trailer, "This reverts commit
# <sha>", in the reverting commit's message (git revert, GitHub's Revert
# button and squash merges of either keep it).
#
# Exposes:
#   revert_edges <base> <head>
#     JSON [{by, target}] for every commit in <base>..<head> (all parents)
#     naming a target that resolves to a commit. Full shas.
#   revert_units <base> <head>
#     JSON {"<first-parent sha>": {kind, reverted_by: [...]}} for the
#     first-parent commits in <base>..<head> that are reverted or are a
#     revert. kind:
#       reverted  the commit (or every non-merge commit it brought in) is
#                 reverted later in the range, and that revert is not itself
#                 reverted. reverted_by: the reverting commits.
#       revert    every non-merge commit it brought in is a revert of a
#                 commit that is not itself a revert. A revert of a revert
#                 (a re-land) brings code back, so it is a normal commit.
#     Commits not in the object are normal.

revert_edges() {
  local base="$1" head="$2" by t full out='[]'
  while IFS=" " read -r by t; do
    [ -n "$by" ] && [ "${#t}" -ge 7 ] || continue
    full=$(git rev-parse -q --verify "${t}^{commit}" 2> /dev/null) || continue
    out=$(jq -c --arg b "$by" --arg t "$full" '. + [{by: $b, target: $t}] | unique' <<< "$out")
  done < <(git log --format='@@%H%n%B' "${base}..${head}" \
    | awk '/^@@[0-9a-f]+$/ { h = substr($0, 3); next }
           { while (match($0, /This reverts commit [0-9a-f]+/)) {
               print h, substr($0, RSTART + 20, RLENGTH - 20); $0 = substr($0, RSTART + RLENGTH) } }')
  echo "$out"
}

revert_units() {
  local base="$1" head="$2" edges sha members out='{}'
  edges=$(revert_edges "$base" "$head")
  if [ "$edges" = '[]' ]; then
    echo '{}'
    return 0
  fi
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    members=$(git rev-list --no-merges "${sha}^1..${sha}" 2> /dev/null | jq -R . | jq -sc .)
    # shellcheck disable=SC2016 # jq program, not shell expansion.
    out=$(jq -c --arg u "$sha" --argjson m "$members" --argjson e "$edges" '
      def reverters($x): [$e[] | select(.target == $x) | .by];
      def is_reverted($x): any(reverters($x)[]; is_reverted(.) | not);
      def live_reverters($x): [reverters($x)[] | select(is_reverted(.) | not)];
      def targets($x): [$e[] | select(.by == $x) | .target];
      def is_revert($x): (targets($x) | length) > 0;
      def pure_revert($x): is_revert($x) and all(targets($x)[]; is_revert(.) | not);
      if is_reverted($u) then . + {($u): {kind: "reverted", reverted_by: live_reverters($u)}}
      elif ($m | length) > 0 and all($m[]; is_reverted(.)) then
        . + {($u): {kind: "reverted", reverted_by: ([$m[] | live_reverters(.)[]] | unique)}}
      elif ($m | length) > 0 and all($m[]; pure_revert(.)) then . + {($u): {kind: "revert", reverted_by: []}}
      else . end' <<< "$out")
  done < <(git rev-list --first-parent "${base}..${head}")
  echo "$out"
}
