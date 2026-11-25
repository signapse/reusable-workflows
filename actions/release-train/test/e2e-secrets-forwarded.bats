#!/usr/bin/env bats
# Every E2E_* secret a pipeline workflow accepts must be forwarded to the
# signapse-e2e suite, and the reverse (SIG-3190: the Website Plugin accounts
# were accepted by the suite but never passed on, so its tests failed with
# "Missing E2E_...").
load 'helpers/load'

WF="$BATS_TEST_DIRNAME/../../../.github/workflows"

# Declared under on.workflow_call.secrets: "      E2E_X:" (6-space indent, no value).
declared() { grep -oE '^      E2E_[A-Z_]+:$' "$1" | tr -d ' :' | sort; }
# Forwarded to the suite: "      E2E_X: ${{ secrets.E2E_X }}".
forwarded() { grep -oE '^      E2E_[A-Z_]+: \$\{\{ secrets\.E2E_[A-Z_]+ \}\}' "$1" | cut -d: -f1 | tr -d ' ' | sort; }

assert_forwards_all() {
  run diff <(declared "$1") <(forwarded "$1")
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

assert_has_website_plugin() {
  for name in USER_EMAIL USER_PASSWORD WIZARD_USER_EMAIL WIZARD_USER_PASSWORD; do
    forwarded "$1" | grep -qx "E2E_${2}_WEBSITE_PLUGIN_${name}" || { echo "missing E2E_${2}_WEBSITE_PLUGIN_${name}"; return 1; }
  done
}

@test "main-push-dev forwards every E2E secret it accepts" {
  assert_forwards_all "$WF/main-push-dev.yml"
}

@test "main-push-dev forwards the dev Website Plugin accounts" {
  assert_has_website_plugin "$WF/main-push-dev.yml" DEV
}

@test "release-train-staging forwards every E2E secret it accepts" {
  assert_forwards_all "$WF/release-train-staging.yml"
}

@test "release-train-staging forwards the staging Website Plugin accounts" {
  assert_has_website_plugin "$WF/release-train-staging.yml" STAGING
}

@test "release-train-prod forwards every E2E secret it accepts" {
  assert_forwards_all "$WF/release-train-prod.yml"
}
