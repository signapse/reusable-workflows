#!/usr/bin/env bash
# train-composer.sh <last-tag> <head-ref>
#
# Sole producer of TrainState JSON. Emits it on stdout, one compact line.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"
# shellcheck source=SCRIPTDIR/../lib/gh_api.sh
source "$(dirname "$0")/../lib/gh_api.sh"
# shellcheck source=SCRIPTDIR/../lib/sentry.sh
source "$(dirname "$0")/../lib/sentry.sh"

[ $# -eq 2 ] || die "usage: train-composer.sh <last-tag> <head-ref>"
LAST_TAG="$1"; HEAD_REF="$2"
need jq
need git

: "${GITHUB_REPOSITORY:?}"

HERE="$(dirname "$0")"

# 1. Ticket refs from commits in range.
refs=$("$HERE/ticket-extractor.sh" "$LAST_TAG" "$HEAD_REF" < /dev/null)

# 2. PRs merged since last tag.
prs=$(gh_prs_since_tag "$GITHUB_REPOSITORY" "$LAST_TAG" "$HEAD_REF")

# 3. Query Linear for ticket state (skip the call entirely if nothing referenced —
# Task 3 regression class: no-match paths must not fail or require creds).
ready='[]'
blocking='[]'
if [ "$refs" != '[]' ]; then
  # IssueFilter has no `identifier` field (would 400). Fetch each issue individually
  # via `issue(id: String!)` — that accepts identifiers like "SIG-883" — then aggregate.
  nodes='[]'
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    # shellcheck disable=SC2016 # GraphQL variable ($id), not shell expansion.
    r=$(linear_query \
      'query($id:String!){issue(id:$id){identifier title assignee{displayName} creator{displayName} state{name}}}' \
      "$(jq -nc --arg id "$id" '{id:$id}')")
    node=$(echo "$r" | jq -c '.data.issue // empty')
    if [ -n "$node" ]; then
      nodes=$(echo "$nodes" | jq -c --argjson n "$node" '. + [$n]')
    fi
  done < <(echo "$refs" | jq -r '.[]')
  ready=$(echo "$nodes" | jq -c '[.[]
    | select(.state.name == "Ready for Prod")
    | {id: .identifier, title, author: ("@" + (.creator.displayName // "unknown")), status: .state.name}]')
  blocking=$(echo "$nodes" | jq -c '[.[]
    | select(.state.name != "Ready for Prod")
    | {id: .identifier, title,
       author: ("@" + (.creator.displayName // "unknown")),
       assignee: ("@" + (.assignee.displayName // "unassigned")),
       status: .state.name}]')
fi

# 4. Non-ticket PRs = merged PRs whose title has no SIG-<n> reference.
non_ticket=$(echo "$prs" | jq -c '[.[]?
  | select((.title // "") | test("SIG-[0-9]+"; "i") | not)
  | {number, title, author: .author.login, labels: [.labels[]?.name]}]')

# 5. Staging gate.
staging_ok=$(gh_staging_ok "$GITHUB_REPOSITORY" "$HEAD_REF")

# 6. Sentry error count for the outgoing release.
sentry_count=$(sentry_issue_count "$LAST_TAG" 2>/dev/null || echo 0)

# 7. Next version, derived from merged-PR labels.
pr_labels=$(echo "$prs" | jq -c '[.[]? | [.labels[]?.name]]')
next_version=$(echo "$pr_labels" | "$HERE/version-bump.sh" "$LAST_TAG")

head_sha=$(git rev-parse "$HEAD_REF")

jq -nc \
  --arg last_tag "$LAST_TAG" \
  --arg head_sha "$head_sha" \
  --arg next_version "$next_version" \
  --argjson ready "$ready" \
  --argjson blocking "$blocking" \
  --argjson non_ticket "$non_ticket" \
  --argjson staging_ok "$staging_ok" \
  --argjson sentry "$sentry_count" \
  '{last_tag: $last_tag, head_sha: $head_sha, next_version: $next_version,
    ready_tickets: $ready, blocking_tickets: $blocking, non_ticket_prs: $non_ticket,
    staging_ok: $staging_ok, sentry_error_count_24h: $sentry}'
