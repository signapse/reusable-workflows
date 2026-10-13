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
# Emit a benign JSON response plus the http_code suffix.
printf '{"data":{}}\n200'
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
