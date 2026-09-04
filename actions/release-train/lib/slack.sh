#!/usr/bin/env bash
# slack.sh — Slack Web API wrappers. Requires SLACK_BOT_TOKEN in env.
# Exposes: slack_post, slack_thread_reply

slack_post() {
  # Reads Block Kit JSON on stdin. Emits {ok, ts, channel, ...} on stdout.
  : "${SLACK_BOT_TOKEN:?}"
  curl -sSf -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data-binary @-
}

slack_thread_reply() {
  # $1=channel_id, $2=thread_ts, $3=text
  : "${SLACK_BOT_TOKEN:?}"
  local channel="$1" thread_ts="$2" text="$3"
  curl -sSf -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -nc --arg c "$channel" --arg t "$thread_ts" --arg m "$text" \
      '{channel: $c, thread_ts: $t, text: $m}')"
}
