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

# linear_gql <graphql-string> [variables-json]
# Like linear_query, but checks GraphQL errors too. Prints .data on success.
# Returns 3 when every error message starts with Linear's "Entity not found"
# (a genuine miss the caller may tolerate) and 1 for anything else: HTTP failure, bad key, rate
# limit, malformed query. Error text goes to stderr.
linear_gql() {
  local resp
  resp=$(linear_query "$@") || { echo "linear_gql: Linear API request failed" >&2; return 1; }
  if ! jq -e . > /dev/null 2>&1 <<<"$resp"; then
    echo "linear_gql: non-JSON response: ${resp:0:200}" >&2
    return 1
  fi
  if [ "$(jq '(.errors // []) | length' <<<"$resp")" != "0" ]; then
    local msgs
    msgs=$(jq -r '[.errors[].message] | join("; ")' <<<"$resp")
    if jq -e '.errors | all(.message | startswith("Entity not found"))' > /dev/null <<<"$resp"; then
      echo "linear_gql: not found: $msgs" >&2
      return 3
    fi
    echo "linear_gql: Linear API error: $msgs" >&2
    return 1
  fi
  jq -c '.data' <<<"$resp"
}
