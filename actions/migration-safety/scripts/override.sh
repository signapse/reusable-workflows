#!/usr/bin/env bash
# Migration-safety override: the ONE place that decides whether a reviewer has
# cleared a destructive migration. Change the mechanism here and nowhere else
# (docs/MIGRATION-SAFETY.md describes it for humans).
#
# Mechanism: an APPROVING pull request review whose body contains
# $OVERRIDE_PHRASE, from someone who
#   * is not the PR author,
#   * is not a bot,
#   * is an OWNER / MEMBER / COLLABORATOR of the repo,
#   * has not since withdrawn it (their latest approve/request-changes/dismissed
#     review is still APPROVED),
# and the flagged migration files are byte-identical between the commit the
# review was left on and the PR head (so a later push that changes the
# migration needs a fresh override, but unrelated pushes do not).
#
# Why a review and not a label / commit trailer / CODEOWNERS:
#   * a label needs creating per repo (not agreed) and the author can apply it;
#   * a commit trailer is written by the author;
#   * CODEOWNERS approval cannot tell "reviewed the destructive change" from a
#     routine approval and needs per-repo CODEOWNERS + branch protection.
# An approving review is visible on the PR timeline, attributable, and only a
# reviewer can leave it.

OVERRIDE_PHRASE='allow-destructive-migration'

# find_override FILE...
# Env: GITHUB_REPOSITORY, PR_NUMBER, PR_AUTHOR, HEAD_SHA (+ GH_TOKEN for gh).
# Prints "<login>\t<review url>" of the first valid override and returns 0;
# returns 1 when there is none. Stale overrides are reported on stderr.
find_override() {
  local reviews candidates login commit url
  reviews=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews") || {
    echo "migration-safety: could not list PR reviews" >&2
    return 1
  }
  # --paginate concatenates one JSON array per page; -s + add joins them.
  candidates=$(jq -rs --arg author "$PR_AUTHOR" --arg phrase "$OVERRIDE_PHRASE" '
    (add // [])
    | map(select(.user.login != $author
                 and .user.type != "Bot"
                 and (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR"))))
    | group_by(.user.login)
    | map(
        (map(select(.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))) | last) as $latest
        | select($latest.state == "APPROVED")
        | map(select(.state == "APPROVED"
                     and ((.body // "") | ascii_downcase | contains($phrase))))
        | reverse
        | .[]
      )
    | .[]
    | [.user.login, .commit_id, .html_url] | @tsv' <<<"$reviews") || return 1

  while IFS=$'\t' read -r login commit url; do
    [ -n "$login" ] || continue
    if git cat-file -e "${commit}^{commit}" 2>/dev/null &&
      git diff --quiet "$commit" "$HEAD_SHA" -- "$@"; then
      printf '%s\t%s\n' "$login" "$url"
      return 0
    fi
    echo "migration-safety: override by @${login} (${url}) is stale: the flagged migrations changed after it was given." >&2
  done <<<"$candidates"
  return 1
}
