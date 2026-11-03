#!/usr/bin/env bash
# notify-pr-authors.sh <failed-stage>
#
# Tells the authors of the PRs merged in a failed main-push build that their
# tickets stayed where they were. Reads merged-prs.sh JSON on stdin.
#   * Comments on each merged PR (pings its author). Needs GH_TOKEN with
#     pull-requests:write; a failed comment is a warning, not an error.
#   * Also posts one Slack message to SLACK_CHANNEL when it is set (needs
#     SLACK_BOT_TOKEN).
# Env: RUN_URL (link to the failed run), REPORT_URL (optional e2e report).
# Emits the number of PRs notified on stdout.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/slack.sh
source "$(dirname "$0")/../lib/slack.sh"

[ $# -eq 1 ] || die "usage: notify-pr-authors.sh <failed-stage>"
STAGE="$1"
need jq
need gh

RUN_URL="${RUN_URL:-}"
REPORT_URL="${REPORT_URL:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-}"

prs=$(cat)
count=$(printf '%s' "${prs:-[]}" | jq 'length')
if [ "$count" -eq 0 ]; then
  log "no merged PRs in this build; nobody to notify"
  echo 0
  exit 0
fi

links="[run](${RUN_URL})"
[ -z "$REPORT_URL" ] || links+=" · [e2e report](${REPORT_URL})"

notified=0
while IFS= read -r pr; do
  repo=$(printf '%s' "$pr" | jq -r '.repo')
  num=$(printf '%s' "$pr" | jq -r '.number')
  author=$(printf '%s' "$pr" | jq -r '.author')
  body="@${author} the main build containing this PR failed at **${STAGE}**, so its tickets were not moved to On Dev · Ready for QA. ${links}

Fix forward with a new PR, or re-run the failed jobs if it was a flake; the tickets move once a build containing this change passes dev smoke."
  if gh pr comment "$num" --repo "$repo" --body "$body" > /dev/null; then
    notified=$((notified + 1))
  else
    echo "::warning::could not comment on ${repo}#${num}; does the caller grant pull-requests: write?"
  fi
done < <(printf '%s' "$prs" | jq -c '.[]')

if [ -n "$SLACK_CHANNEL" ]; then
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  text=$(printf '%s' "$prs" | jq -r --arg stage "$STAGE" --arg run "$RUN_URL" '
    ":red_circle: main build failed at *\($stage)* (<\($run)|run>); tickets not moved to On Dev · Ready for QA.\n"
    + ([.[] | "• <\(.url)|\(.repo)#\(.number)> \(.title) (@\(.author))"] | join("\n"))')
  resp=$(jq -nc --arg c "$SLACK_CHANNEL" --arg t "$text" '{channel:$c, text:$t}' | slack_post || true)
  if [ "$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
    echo "::warning::Slack notification to ${SLACK_CHANNEL} failed: ${resp}"
  fi
fi

echo "$notified"
