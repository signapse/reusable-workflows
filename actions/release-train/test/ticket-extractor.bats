#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/ticket-extractor.sh"

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q
  git config user.email t@t.t
  git config user.name t
  git commit -q --allow-empty -m "root"
}

teardown() { rm -rf "$TMP"; }

@test "extracts single ref from feat commit" {
  git commit -q --allow-empty -m "feat(SIG-1381): add thing"
  run "$SCRIPT" HEAD~1 HEAD
  [ "$status" -eq 0 ]
  [ "$output" = '["SIG-1381"]' ]
}

@test "extracts multiple refs from one body" {
  git commit -q --allow-empty -m "chore: bundles SIG-1 and SIG-2

  Related: SIG-3"
  run "$SCRIPT" HEAD~1 HEAD
  [ "$status" -eq 0 ]
  [ "$output" = '["SIG-1","SIG-2","SIG-3"]' ]
}

@test "ignores non-SIG refs" {
  git commit -q --allow-empty -m "feat: LIV-99 shouldn't match, but SIG-42 should"
  run "$SCRIPT" HEAD~1 HEAD
  [ "$output" = '["SIG-42"]' ]
}

@test "case-insensitive input, uppercase output, dedup across commits" {
  git commit -q --allow-empty -m "sig-9 first mention"
  git commit -q --allow-empty -m "SIG-9 again + SIG-10"
  run "$SCRIPT" HEAD~2 HEAD
  [ "$output" = '["SIG-9","SIG-10"]' ]
}

@test "dedup against PR body on stdin" {
  git commit -q --allow-empty -m "feat(SIG-1): a"
  run bash -c "echo 'body mentions SIG-2 and SIG-1' | '$SCRIPT' HEAD~1 HEAD"
  [ "$output" = '["SIG-1","SIG-2"]' ]
}

@test "empty range → empty array" {
  run "$SCRIPT" HEAD HEAD
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}
