#!/usr/bin/env bash
# Linear GraphQL wrapper. Requires LINEAR_API_KEY in env.
# Exposes: linear_query <graphql-string> <variables-json>

linear_query() {
  local query="$1"
  local vars='{}'
  [ $# -ge 2 ] && vars="$2"
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    die "LINEAR_API_KEY not set"
  fi
  local body
  body=$(jq -nc --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')
  local resp status
  # -f swallowed the response body on 4xx/5xx, leaving only "curl: (22) 400" —
  # print Linear's actual error message so future failures are debuggable.
  resp=$(curl -sS -w '\n%{http_code}' https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body")
  status="${resp##*$'\n'}"
  local out="${resp%$'\n'*}"
  if [ "$status" -ge 400 ]; then
    echo "linear_query: HTTP $status: $out" >&2
    return 22
  fi
  printf '%s' "$out"
}
