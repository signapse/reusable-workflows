#!/usr/bin/env bash
# sentry.sh — issue count for a given release tag in last 24h.

sentry_issue_count() {
  local org="${SENTRY_ORG:-signapse}" project="${SENTRY_PROJECT-signstream}" release="$1"
  if [ -z "$project" ]; then
    echo "sentry_issue_count: SENTRY_PROJECT empty, skipping health check" >&2
    echo 0
    return 0
  fi
  if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    echo "sentry_issue_count: SENTRY_AUTH_TOKEN not set" >&2
    return 1
  fi
  # 'events' would need Sentry Discover; a simpler 'issues' count is fine here.
  curl -sSf -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
    "https://sentry.io/api/0/projects/${org}/${project}/issues/?query=release:${release}&statsPeriod=24h" \
    | jq -r '[.[].count] | map(tonumber) | add // 0'
}

# sentry_has_deploy <version> <environment> — prints true/false: does the
# Sentry release <version> already have a deploy to <environment>? A missing
# release (404) is "false". Used to keep the Deployment step idempotent:
# getsentry/action-release records a new deploy on every run.
sentry_has_deploy() {
  local org="${SENTRY_ORG:-signapse}" version="$1" env="$2" resp status
  if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
    echo "sentry_has_deploy: SENTRY_AUTH_TOKEN not set" >&2
    return 1
  fi
  resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
    "https://sentry.io/api/0/organizations/${org}/releases/$(jq -rn --arg v "$version" '$v|@uri')/deploys/")
  status="${resp##*$'\n'}"
  case "$status" in
    404) echo false ;;
    2??) jq -r --arg e "$env" 'any(.[]; .environment == $e)' <<<"${resp%$'\n'*}" ;;
    *)
      echo "sentry_has_deploy: HTTP $status" >&2
      return 1
      ;;
  esac
}
