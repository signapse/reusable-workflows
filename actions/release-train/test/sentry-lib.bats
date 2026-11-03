#!/usr/bin/env bats
load 'helpers/load'

# Fake curl returns $FAKE_BODY with HTTP $FAKE_STATUS and records the URL.
setup() {
  export TMP="$(mktemp -d)"
  mkdir -p "$TMP/stub"
  export PATH="$TMP/stub:$PATH"
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in https://*) echo "$a" > "$TMP/url" ;; esac; done
printf '%s\n%s' "$FAKE_BODY" "$FAKE_STATUS"
EOS
  chmod +x "$TMP/stub/curl"
  # shellcheck disable=SC1091
  source "$BATS_TEST_DIRNAME/../lib/sentry.sh"
  export SENTRY_AUTH_TOKEN=fake SENTRY_ORG=signapse
}

teardown() { rm -rf "$TMP"; }

@test "sentry_has_deploy: true when a deploy to the environment exists" {
  FAKE_STATUS=200 FAKE_BODY='[{"environment":"staging"},{"environment":"production"}]' \
    run sentry_has_deploy v1.2.3 production
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  [ "$(cat "$TMP/url")" = "https://sentry.io/api/0/organizations/signapse/releases/v1.2.3/deploys/" ]
}

@test "sentry_has_deploy: false when only other environments have deploys" {
  FAKE_STATUS=200 FAKE_BODY='[{"environment":"staging"}]' run sentry_has_deploy v1.2.3 production
  [ "$output" = "false" ]
}

@test "sentry_has_deploy: false when the release does not exist yet (404)" {
  FAKE_STATUS=404 FAKE_BODY='{"detail":"Not found"}' run sentry_has_deploy v1.2.3 production
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "sentry_has_deploy: fails on other HTTP errors" {
  FAKE_STATUS=500 FAKE_BODY='oops' run sentry_has_deploy v1.2.3 production
  [ "$status" -ne 0 ]
}
