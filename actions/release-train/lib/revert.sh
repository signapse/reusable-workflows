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
#     whose trailers name commits it actually undoes, and nothing else
#     (_undoes). Full shas.
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
  local base="$1" head="$2" out
  out=$(git log --format='@@%H%n%B' "${base}..${head}" | _revert_lines | _verified_edges)
  # A target older than <base> may itself be a revert (prod's base sits after
  # an original revert, and the range holds the revert of that revert: a
  # re-land). Its own edges decide that, so read them too, one level deep
  # (review fix: otherwise the re-land looks like a pure revert and its code
  # is never checked).
  jq -c --argjson a "$out" '$a + . | unique' <<< "$(jq -r '[.[].target] | unique | .[]' <<< "$out" \
    | while IFS= read -r t; do
        git merge-base --is-ancestor "$t" "$base" 2> /dev/null || continue
        git log -1 --format='@@%H%n%B' "$t"
      done | _revert_lines | _verified_edges)"
}

# stdin: "<by> <target-prefix>" lines; stdout: JSON [{by, target}] for each
# <by> whose named targets all resolve and that _undoes all of them.
_verified_edges() {
  local by t full prev="" targets=() out='[]'
  flush() {
    [ -n "$prev" ] && [ "${#targets[@]}" -gt 0 ] || return 0
    _undoes "$prev" "${targets[@]}" || return 0
    out=$(jq -c --arg b "$prev" '. + [$ARGS.positional[] | {by: $b, target: .}] | unique' --args "${targets[@]}" <<< "$out")
  }
  local bad=0
  while IFS=" " read -r by t; do
    [ -n "$by" ] || continue
    if [ "$by" != "$prev" ]; then
      [ "$bad" = 1 ] || flush
      prev="$by" targets=() bad=0
    fi
    # A trailer naming something that is not a commit: the change cannot be
    # checked, so the commit is not a revert at all.
    if [ "${#t}" -lt 7 ] || ! full=$(git rev-parse -q --verify "${t}^{commit}" 2> /dev/null); then
      bad=1
      continue
    fi
    targets+=("$full")
  done
  [ "$bad" = 1 ] || flush
  echo "$out"
}

# _undoes <by> <target>...: the trailer alone proves nothing (anyone can write
# it), so <by> only counts as a revert if its whole tree equals <by>^1 with
# every named target reverted in turn, newest first (3-way merges with base
# <target>, as git revert does). Anything else in the commit (extra code, a
# conflict resolution, an empty "revert") fails, so its tickets are checked.
_undoes() {
  local by="$1" t tree cur
  shift
  cur=$(git rev-parse -q --verify "${by}^1" 2> /dev/null) || return 1
  for t in $(git rev-list --no-walk=sorted "$@" 2> /dev/null); do
    git rev-parse -q --verify "${t}^1" > /dev/null 2>&1 || return 1
    tree=$(git merge-tree --write-tree --merge-base="$t" "$cur" "${t}^1" 2> /dev/null) || return 1
    cur=$(GIT_AUTHOR_NAME=revert-check GIT_AUTHOR_EMAIL=revert-check@invalid \
      GIT_COMMITTER_NAME=revert-check GIT_COMMITTER_EMAIL=revert-check@invalid \
      git commit-tree "$(head -n 1 <<< "$tree")" -p "$cur" -m revert-check) || return 1
  done
  [ "$(git rev-parse "${cur}^{tree}")" = "$(git rev-parse "${by}^{tree}")" ]
}

# stdin: git log --format='@@%H%n%B'; stdout: "<by> <target-prefix>" per
# "This reverts commit" line.
_revert_lines() {
  awk '/^@@[0-9a-f]+$/ { h = substr($0, 3); next }
       { while (match($0, /This reverts commit [0-9a-f]+/)) {
           print h, substr($0, RSTART + 20, RLENGTH - 20); $0 = substr($0, RSTART + RLENGTH) } }'
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
