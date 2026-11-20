#!/usr/bin/env bats
load 'helpers/load'

setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"
  # Fake curl: echo the request body it received to stderr so we can inspect it.
  # linear_query now uses -w '%{http_code}' so responses must end with \n<status>.
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
# Capture the last -d value.
prev=""
for arg in "$@"; do
  if [ "$prev" = "-d" ]; then
    echo "$arg" > /tmp/linear-request-body.$$
  fi
  prev="$arg"
done
# Emit the canned response (default: benign) plus the http_code suffix.
printf '%s\n%s' "${LINEAR_RESP:-"{\"data\":{}}"}" "${LINEAR_STATUS:-200}"
EOS
  chmod +x "$TMP/stub/curl"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../lib/linear.sh"
  export LINEAR_API_KEY=fake
}

teardown() { rm -rf "$TMP" /tmp/linear-request-body.* 2>/dev/null || true; }

@test "linear_query with no vars sends empty-object variables" {
  linear_query 'query{ viewer{ id } }' > /dev/null
  body=$(cat /tmp/linear-request-body.*)
  [ "$(echo "$body" | jq -r '.variables')" = "{}" ]
}

@test "linear_query with explicit vars preserves them verbatim" {
  linear_query 'mutation($x:String!){ x(x:$x){ ok } }' '{"x":"y"}' > /dev/null
  body=$(cat /tmp/linear-request-body.*)
  [ "$(echo "$body" | jq -r '.variables.x')" = "y" ]
  # Also assert the request body has no trailing junk (would-be `}}` regression).
  echo "$body" | jq -e '.' > /dev/null
}

@test "linear_gql prints .data on success" {
  LINEAR_RESP='{"data":{"issue":{"id":"x"}}}' run linear_gql 'query{x}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"issue":{"id":"x"}}' ]
}

@test "linear_gql returns 3 when every error is Entity not found" {
  LINEAR_RESP='{"errors":[{"message":"Entity not found: Issue"}],"data":null}' run linear_gql 'query{x}'
  [ "$status" -eq 3 ]
}

@test "linear_gql returns 1 on any other GraphQL error" {
  LINEAR_RESP='{"errors":[{"message":"Entity not found: Issue"},{"message":"Rate limit exceeded"}]}' run linear_gql 'query{x}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rate limit exceeded"* ]]
}

@test "linear_gql returns 1 on HTTP failure" {
  LINEAR_RESP='{"errors":[{"message":"Authentication required"}]}' LINEAR_STATUS=401 run linear_gql 'query{x}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 401"* ]]
}

@test "linear_gql: other errors mentioning 'not found' are failures, not misses" {
  LINEAR_RESP='{"errors":[{"message":"Authentication token not found"}]}' run linear_gql 'query{x}'
  [ "$status" -eq 1 ]
}
