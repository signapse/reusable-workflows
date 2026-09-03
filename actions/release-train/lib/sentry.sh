#!/usr/bin/env bash
# sentry.sh — issue count for a given release tag in last 24h.

sentry_issue_count() {
  local org="signapse" project="signstream" release="$1"
  if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    echo "sentry_issue_count: SENTRY_AUTH_TOKEN not set" >&2
    return 1
  fi
  # 'events' would need Sentry Discover; a simpler 'issues' count is fine here.
  curl -sSf -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
    "https://sentry.io/api/0/projects/${org}/${project}/issues/?query=release:${release}&statsPeriod=24h" \
    | jq -r '[.[].count] | map(tonumber) | add // 0'
}
