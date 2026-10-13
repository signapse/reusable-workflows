#!/usr/bin/env bash
# slack-composer.sh --variant ready|held [--draft-url <url>]
#
# Reads TrainState JSON (produced by train-composer.sh) on stdin; emits
# Slack Block Kit JSON on stdout, shape {channel, blocks}, ready to POST
# to chat.postMessage.
#
# Variants:
#   ready  - requires --draft-url. Tickets block is omitted when
#            ready_tickets is empty (non-ticket-only release).
#   held   - blocking + waiting tickets, no draft link.
#
# Regenerate a snapshot after an intentional formatting change with:
#   echo "$STATE" | ./slack-composer.sh --variant ready --draft-url <url> \
#     | jq -S . > testdata/snapshots/slack-ready.json
# Review the diff by eye before committing.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

VARIANT=""
DRAFT_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --variant)   VARIANT="$2"; shift 2 ;;
    --draft-url) DRAFT_URL="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$VARIANT" ] || die "--variant required"
case "$VARIANT" in
  ready|held) ;;
  *) die "unknown variant: $VARIANT (expected ready|held)" ;;
esac

need jq
STATE=$(cat)
echo "$STATE" | jq -e . > /dev/null 2>&1 || die "invalid TrainState JSON on stdin"

GROUP="${SLACK_RELEASE_CLICKERS_GROUP_ID:-S000RELEASE}"
CHANNEL="${SLACK_RELEASES_CHANNEL:-#releases}"

next=$(echo "$STATE" | jq -r '.next_version')
last=$(echo "$STATE" | jq -r '.last_tag')
staging=$(echo "$STATE" | jq -r '.staging_ok')
sentry=$(echo "$STATE" | jq -r '.sentry_error_count_24h')

if [ "$VARIANT" = "held" ]; then
  block_count=$(echo "$STATE" | jq -r '.blocking_tickets | length')
  wait_count=$(echo "$STATE" | jq -r '.ready_tickets | length')
  blocking_lines=$(echo "$STATE" | jq -r '.blocking_tickets | map("• \(.id) \(.title) — \(.status) (assignee: \(.assignee))") | join("\n")')
  waiting_lines=$(echo "$STATE" | jq -r '.ready_tickets | map("• \(.id) \(.title) (\(.author))") | join("\n")')

  jq -nc \
    --arg channel "$CHANNEL" \
    --arg header "⏸ Release train held for $next" \
    --arg block  "*Blocking ($block_count):*
$blocking_lines" \
    --arg wait   "*Waiting ($wait_count):*
$waiting_lines" \
    --arg ctx    "Nagged assignees will unblock once tickets reach *Ready for Prod*." \
    '{channel: $channel, blocks: [
       {type: "header", text: {type: "plain_text", text: $header}},
       {type: "section", text: {type: "mrkdwn", text: $block}},
       {type: "section", text: {type: "mrkdwn", text: $wait}},
       {type: "context", elements: [{type: "mrkdwn", text: $ctx}]}
     ]}'
  exit 0
fi

# ready variant (collapses to non-ticket-only when ready_tickets is empty)
[ -n "$DRAFT_URL" ] || die "ready variant requires --draft-url"

ready_count=$(echo "$STATE" | jq -r '.ready_tickets | length')
non_ticket_count=$(echo "$STATE" | jq -r '.non_ticket_prs | length')
ticket_lines=$(echo "$STATE" | jq -r '.ready_tickets | map("• \(.id) \(.title) (\(.author))") | join("\n")')
non_ticket_lines=$(echo "$STATE" | jq -r '.non_ticket_prs | map("• #\(.number) \(.title) (@\(.author)) [\(.labels | join(","))]") | join("\n")')

staging_line="Staging ❌"
[ "$staging" = "true" ] && staging_line="Staging ✅"

blocks='[]'
blocks=$(echo "$blocks" | jq --arg t "🚂 Ready to cut $next for prod" \
  '. + [{type: "header", text: {type: "plain_text", text: $t}}]')

if [ "$ready_count" != "0" ]; then
  blocks=$(echo "$blocks" | jq --arg t "*Tickets ($ready_count):*
$ticket_lines" '. + [{type: "section", text: {type: "mrkdwn", text: $t}}]')
fi

if [ "$non_ticket_count" != "0" ]; then
  blocks=$(echo "$blocks" | jq --arg t "*Other PRs ($non_ticket_count):*
$non_ticket_lines" '. + [{type: "section", text: {type: "mrkdwn", text: $t}}]')
fi

blocks=$(echo "$blocks" | jq --arg t "*Health:*
• $staging_line
• Sentry 24h: $sentry errors on $last" '. + [{type: "section", text: {type: "mrkdwn", text: $t}}]')

blocks=$(echo "$blocks" | jq --arg url "$DRAFT_URL" \
  '. + [{type: "actions", elements: [{type: "button", text: {type: "plain_text", text: "Cut release tag"}, url: $url, style: "primary"}]}]')

blocks=$(echo "$blocks" | jq --arg t "<!subteam^${GROUP}|@release-clickers> — publishing the draft retags the image for prod promotion." \
  '. + [{type: "context", elements: [{type: "mrkdwn", text: $t}]}]')

jq -nc --arg channel "$CHANNEL" --argjson blocks "$blocks" '{channel: $channel, blocks: $blocks}'
