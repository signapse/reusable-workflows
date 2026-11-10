#!/usr/bin/env bats
# The prod "Smoke result" step (SIG-2771): runs the step's own script, cut
# out of release-train-prod.yml, so the workflow cannot drift from the test.
load 'helpers/load'

WF="$BATS_TEST_DIRNAME/../../../.github/workflows/release-train-prod.yml"

setup() {
  TMP="$(mktemp -d)"
  # The run: block of the step with `id: smoke`, de-indented.
  awk '/^        id: smoke$/ { f = 1; next }
       f && /^        run: \|$/ { r = 1; next }
       r && /^      - / { exit }
       r { sub(/^          /, ""); print }' "$WF" > "$TMP/step.sh"
  [ -s "$TMP/step.sh" ]
}

teardown() { rm -rf "$TMP"; }

# smoke <job result> <suite result>: prints the step's passed output.
smoke() {
  : > "$TMP/out"
  JOB_RESULT="$1" RESULT="$2" REPORT_URL='' TAG=1.4.0 GITHUB_OUTPUT="$TMP/out" \
    GITHUB_STEP_SUMMARY=/dev/null bash "$TMP/step.sh"
  sed -n 's/^passed=//p' "$TMP/out"
}

@test "a suite that ran and passed: passed" {
  [ "$(smoke success passed)" = true ]
}

@test "a suite that ran and failed: failed, so the rollback runs" {
  [ "$(smoke failure failed)" = false ]
}

@test "failed from a cancelled or skipped suite job is unknown, never a rollback" {
  [ "$(smoke cancelled failed)" = "" ]
  [ "$(smoke skipped failed)" = "" ]
}

@test "no result, errored, or passed from a job that did not succeed: unknown" {
  [ "$(smoke failure '')" = "" ]
  [ "$(smoke failure errored)" = "" ]
  [ "$(smoke failure passed)" = "" ]
}
