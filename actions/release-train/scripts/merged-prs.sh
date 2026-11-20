#!/usr/bin/env bash
# merged-prs.sh <owner/repo> <since-ref> <until-ref>
#
# Lists the merged pull requests behind the commits in since..until (run from
# a checkout of owner/repo). Emits a JSON array, deduped by number:
#   [{repo, number, author, title, head_ref, url}]
# An empty range emits []. Needs GH_TOKEN with pull-requests:read on the repo.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 3 ] || die "usage: merged-prs.sh <owner/repo> <since-ref> <until-ref>"
REPO="$1"; SINCE="$2"; UNTIL="$3"

need git
need gh
need jq

shas=$(git rev-list "${SINCE}..${UNTIL}" 2>/dev/null || true)
if [ -z "$shas" ]; then
  echo '[]'
  exit 0
fi

while IFS= read -r sha; do
  # shellcheck disable=SC2016 # jq $repo binding, not shell expansion.
  gh api "repos/${REPO}/commits/${sha}/pulls" \
    | jq -c --arg repo "$REPO" \
      '[.[] | select(.merged_at != null)
        | {repo:$repo, number, author:.user.login, title, head_ref:.head.ref, url:.html_url}]'
done <<< "$shas" | jq -sc 'add // [] | unique_by(.number)'
