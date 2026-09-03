#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/serialization-detector.sh"

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q; git config user.email t@t.t; git config user.name t
  # Fake tree matching watched paths so 'git diff --name-only' works.
  mkdir -p internal/adaptors/queue/sqs internal/handlers/rest/v2 internal/core/domain
  echo "a" > internal/adaptors/queue/sqs/publisher.go
  echo "a" > internal/handlers/rest/v2/generate.go
  echo "a" > internal/core/domain/types.go
  git add .; git commit -qm root
}
teardown() { rm -rf "$TMP"; }

@test "SQS publisher change → touched=true, files present" {
  echo "b" > internal/adaptors/queue/sqs/publisher.go
  git commit -qam sqs
  run "$SCRIPT" HEAD~1 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.touched == true' > /dev/null
  echo "$output" | jq -e '.files | index("internal/adaptors/queue/sqs/publisher.go")' > /dev/null
}

@test "unrelated change → touched=false, empty files" {
  echo "b" > internal/handlers/rest/v2/generate.go
  git commit -qam rest
  run "$SCRIPT" HEAD~1 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.touched == false' > /dev/null
  echo "$output" | jq -e '.files == []' > /dev/null
}

@test "domain change → touched=true" {
  echo "b" > internal/core/domain/types.go
  git commit -qam domain
  run "$SCRIPT" HEAD~1 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.touched == true' > /dev/null
}

@test "multiple watched paths in one range" {
  echo "b" > internal/adaptors/queue/sqs/publisher.go
  echo "b" > internal/core/domain/types.go
  git commit -qam multi
  run "$SCRIPT" HEAD~1 HEAD
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.files | length')
  [ "$count" -eq 2 ]
}
