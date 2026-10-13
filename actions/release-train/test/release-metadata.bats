#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/release-metadata.sh"

setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"
  export GH_BODY_FILE="$TMP/body"
  echo "Release notes here." > "$GH_BODY_FILE"
  cat > "$TMP/stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "release view")
    cat "$GH_BODY_FILE"
    ;;
  "release edit")
    while [ $# -gt 0 ]; do
      case "$1" in
        --notes-file) cat "$2" > "$GH_BODY_FILE"; shift 2 ;;
        --notes)      printf '%s' "$2" > "$GH_BODY_FILE"; shift 2 ;;
        *) shift ;;
      esac
    done
    ;;
esac
STUB
  chmod +x "$TMP/stub/gh"
}

teardown() {
  rm -rf "$TMP"
}

@test "get returns empty when marker absent" {
  source "$SCRIPT"
  run release_meta_get 1.2.33 slack_channel
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "set then get round-trips" {
  source "$SCRIPT"
  release_meta_set 1.2.33 slack_channel=C123 slack_ts=1700.0
  run release_meta_get 1.2.33 slack_channel
  [ "$status" -eq 0 ]
  [ "$output" = "C123" ]
  run release_meta_get 1.2.33 slack_ts
  [ "$output" = "1700.0" ]
}

@test "set replaces existing block, does not duplicate" {
  source "$SCRIPT"
  release_meta_set 1.2.33 slack_channel=C1
  release_meta_set 1.2.33 slack_channel=C2
  run release_meta_get 1.2.33 slack_channel
  [ "$output" = "C2" ]
  count=$(grep -c 'release-train:meta' "$GH_BODY_FILE" || true)
  [ "$count" -eq 1 ]
}

@test "existing release notes preserved" {
  source "$SCRIPT"
  release_meta_set 1.2.33 slack_channel=C1
  grep -q "Release notes here." "$GH_BODY_FILE"
}

@test "value containing equals sign preserved" {
  source "$SCRIPT"
  release_meta_set 1.2.33 slack_ts=1700.0=extra
  run release_meta_get 1.2.33 slack_ts
  [ "$output" = "1700.0=extra" ]
}
