#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/version-bump.sh"

@test "all chore labels → patch bump" {
  run bash -c "echo '[[\"chore\"],[\"deps\"]]' | '$SCRIPT' 1.2.20"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.21" ]
}

@test "any minor → minor bump, resets patch" {
  run bash -c "echo '[[\"chore\"],[\"minor\"]]' | '$SCRIPT' 1.2.20"
  [ "$status" -eq 0 ]
  [ "$output" = "1.3.0" ]
}

@test "any major → major bump, resets minor + patch" {
  run bash -c "echo '[[\"major\"],[\"chore\"]]' | '$SCRIPT' 1.2.20"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "mixed major and minor → major wins" {
  run bash -c "echo '[[\"minor\"],[\"major\"]]' | '$SCRIPT' 1.2.20"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0" ]
}

@test "empty labels array → patch bump" {
  run bash -c "echo '[]' | '$SCRIPT' 1.2.20"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.21" ]
}

@test "malformed input → non-zero exit" {
  run bash -c "echo 'not json' | '$SCRIPT' 1.2.20"
  [ "$status" -ne 0 ]
}
