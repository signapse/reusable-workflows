#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/ecr-retag.sh"

setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"
}

teardown() {
  rm -rf "$TMP"
}

@test "retags source tag to dest tag" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*)
    echo '{"images":[{"imageManifest":"{\"schemaVersion\":2}","imageId":{"imageDigest":"sha256:X"}}]}'
    ;;
  *"ecr put-image"*)
    echo "PUT_IMAGE_CALLED: $*" > "$TMP/put-image.log"
    echo '{"image":{"imageId":{"imageTag":"1.2.33"}}}'
    ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -eq 0 ]
  grep -q "signstream/http" "$TMP/put-image.log"
  grep -q -- "--image-tag 1.2.33" "$TMP/put-image.log"
}

@test "exits non-zero when source manifest not found" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*)
    echo '{"images":[],"failures":[{"failureCode":"ImageNotFound"}]}'
    ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-missing 1.2.33
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest not found"* ]]
}

@test "no-op when dest tag already points at same manifest" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*"main-abc123"*)
    echo '{"images":[{"imageManifest":"MANIFEST_X","imageId":{"imageDigest":"sha256:X"}}]}'
    ;;
  *"ecr describe-images"*"1.2.33"*)
    echo '{"imageDetails":[{"imageDigest":"sha256:X"}]}'
    ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}
