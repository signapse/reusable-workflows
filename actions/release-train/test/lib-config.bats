#!/usr/bin/env bats
# Coverage for the lib-level config knobs the composite action exposes as inputs:
# SENTRY_PROJECT / SENTRY_ORG (sentry.sh) and STAGING_CHECK_PATTERN (gh_api.sh).
load 'helpers/load'

SENTRY_LIB="$BATS_TEST_DIRNAME/../lib/sentry.sh"
GH_LIB="$BATS_TEST_DIRNAME/../lib/gh_api.sh"

setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"

  # curl stub: echoes the requested URL to $TMP/curl-url, returns a count of 12.
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in https://*) echo "$arg" >> "$TMP/curl-url" ;; esac
done
echo '[{"count":"12"}]'
EOS
  chmod +x "$TMP/stub/curl"

  # gh stub: records that it was called, replays fixture check-runs through the
  # caller's jq. $CHECK_RUNS overrides the payload.
  echo '{"check_runs":[{"name":"staging-tests","conclusion":"success"}]}' \
    > "$TMP/default-check-runs.json"
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
echo called >> "$TMP/gh-called"
if [ -n "${CHECK_RUNS:-}" ]; then
  printf '%s\n' "$CHECK_RUNS"
else
  cat "$TMP/default-check-runs.json"
fi
EOS
  chmod +x "$TMP/stub/gh"

  export SENTRY_AUTH_TOKEN=x
  export GITHUB_TOKEN=x
}

teardown() { rm -rf "$TMP"; }

# --- sentry.sh ---

@test "sentry defaults to the signapse/signstream project" {
  # shellcheck source=/dev/null
  source "$SENTRY_LIB"
  run sentry_issue_count 1.2.20
  [ "$status" -eq 0 ]
  [ "$output" = "12" ]
  grep -q 'projects/signapse/signstream/' "$TMP/curl-url"
}

@test "SENTRY_PROJECT overrides the project slug" {
  # shellcheck source=/dev/null
  source "$SENTRY_LIB"
  SENTRY_PROJECT=stream-generator run sentry_issue_count 1.2.20
  [ "$status" -eq 0 ]
  grep -q 'projects/signapse/stream-generator/' "$TMP/curl-url"
}

@test "SENTRY_ORG overrides the org slug" {
  # shellcheck source=/dev/null
  source "$SENTRY_LIB"
  SENTRY_ORG=otherorg run sentry_issue_count 1.2.20
  [ "$status" -eq 0 ]
  grep -q 'projects/otherorg/signstream/' "$TMP/curl-url"
}

@test "empty SENTRY_PROJECT skips the health check, yielding 0" {
  # shellcheck source=/dev/null
  source "$SENTRY_LIB"
  SENTRY_PROJECT= run sentry_issue_count 1.2.20
  [ "$status" -eq 0 ]
  # tail -n1, not ${lines[-1]}: negative subscripts need bash 4.3+ (macOS ships 3.2).
  [ "$(echo "$output" | tail -n 1)" = "0" ]
  [ ! -f "$TMP/curl-url" ]
}

# --- gh_api.sh ---

@test "staging gate defaults to the staging|smoke pattern" {
  # shellcheck source=/dev/null
  source "$GH_LIB"
  run gh_staging_ok signapse/repo abc123
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "default pattern ignores unrelated failing checks" {
  # shellcheck source=/dev/null
  source "$GH_LIB"
  CHECK_RUNS='{"check_runs":[{"name":"lint","conclusion":"failure"}]}' \
    run gh_staging_ok signapse/repo abc123
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "default pattern fails closed on a failing staging check" {
  # shellcheck source=/dev/null
  source "$GH_LIB"
  CHECK_RUNS='{"check_runs":[{"name":"staging-tests","conclusion":"failure"}]}' \
    run gh_staging_ok signapse/repo abc123
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "STAGING_CHECK_PATTERN selects a different check-run name" {
  # shellcheck source=/dev/null
  source "$GH_LIB"
  CHECK_RUNS='{"check_runs":[{"name":"e2e-prod","conclusion":"failure"}]}' \
    STAGING_CHECK_PATTERN='e2e' run gh_staging_ok signapse/repo abc123
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "empty STAGING_CHECK_PATTERN disables the gate without calling gh" {
  # shellcheck source=/dev/null
  source "$GH_LIB"
  STAGING_CHECK_PATTERN= run gh_staging_ok signapse/repo abc123
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  [ ! -f "$TMP/gh-called" ]
}
