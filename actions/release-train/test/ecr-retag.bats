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
    touch "$TMP/put-done"
    echo '{"image":{"imageId":{"imageTag":"1.2.33"}}}'
    ;;
  *"ecr describe-images"*)
    # The dest tag exists only after the put, on the source digest.
    [ -f "$TMP/put-done" ] || { echo "An error occurred (ImageNotFoundException)" >&2; exit 254; }
    echo '{"imageDetails":[{"imageDigest":"sha256:X"}]}'
    ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -eq 0 ]
  grep -q "signstream/http" "$TMP/put-image.log"
  grep -q -- "--image-tag 1.2.33" "$TMP/put-image.log"
  printf "%s\n" "$output" | tail -1 | jq -e '.source_digest == "sha256:X" and .tag_digest == "sha256:X" and .tag == "1.2.33"' > /dev/null
}

@test "fails when the dest digest differs from the source after the put" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*)
    echo '{"images":[{"imageManifest":"M","imageId":{"imageDigest":"sha256:X"}}]}' ;;
  *"ecr put-image"*) touch "$TMP/put-done"; echo '{}' ;;
  *"ecr describe-images"*)
    [ -f "$TMP/put-done" ] || { echo "An error occurred (ImageNotFoundException)" >&2; exit 254; }
    echo '{"imageDetails":[{"imageDigest":"sha256:Y"}]}' ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -ne 0 ]
  [[ "$output" == *"digest mismatch"* ]]
}

@test "refuses to move a dest tag that points at other bytes" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*)
    echo '{"images":[{"imageManifest":"M","imageId":{"imageDigest":"sha256:X"}}]}' ;;
  *"ecr describe-images"*) echo '{"imageDetails":[{"imageDigest":"sha256:OLD"}]}' ;;
  *"ecr put-image"*) touch "$TMP/put-done"; echo '{}' ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to move"* ]]
  [ ! -f "$TMP/put-done" ]
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

@test "a describe-images failure other than not-found stops before any put" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*)
    echo '{"images":[{"imageManifest":"M","imageId":{"imageDigest":"sha256:X"}}]}' ;;
  *"ecr describe-images"*) echo "An error occurred (ThrottlingException)" >&2; exit 254 ;;
  *"ecr put-image"*) touch "$TMP/put-done"; echo '{}' ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read signstream/http:1.2.33"* ]]
  [ ! -f "$TMP/put-done" ]
}

@test "a tag created between the lookup and the put (immutable repo) is read back, never moved" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*)
    echo '{"images":[{"imageManifest":"M","imageId":{"imageDigest":"sha256:X"}}]}' ;;
  *"ecr describe-images"*)
    [ -f "$TMP/raced" ] || { echo "An error occurred (ImageNotFoundException)" >&2; exit 254; }
    echo "{\"imageDetails\":[{\"imageDigest\":\"$(cat "$TMP/raced")\"}]}" ;;
  *"ecr put-image"*)
    echo "$RACE_DIGEST" > "$TMP/raced"
    echo "An error occurred (ImageTagAlreadyExistsException)" >&2; exit 254 ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  RACE_DIGEST=sha256:OTHER run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to move"*"sha256:OTHER"* ]]
  rm "$TMP/raced"
  RACE_DIGEST=sha256:X run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -eq 0 ]
  [[ "$output" == *"created on sha256:X meanwhile"* ]]
}

@test "ECR rejecting the accepted media types falls back to a plain lookup" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*"--accepted-media-types"*)
    echo "An error occurred (InvalidParameterException): Invalid parameter at 'acceptedMediaTypes'" >&2; exit 254 ;;
  *"ecr batch-get-image"*)
    echo '{"images":[{"imageManifest":"M","imageId":{"imageDigest":"sha256:X"}}]}' ;;
  *"ecr put-image"*) touch "$TMP/put-done"; echo '{}' ;;
  *"ecr describe-images"*)
    [ -f "$TMP/put-done" ] || { echo "An error occurred (ImageNotFoundException)" >&2; exit 254; }
    echo '{"imageDetails":[{"imageDigest":"sha256:X"}]}' ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrying without it"* ]]
  [[ "$output" == *"retagged"* ]]
}

@test "any other batch-get-image failure is not retried" {
  cat > "$TMP/stub/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ecr batch-get-image"*) echo "An error occurred (AccessDeniedException)" >&2; exit 254 ;;
esac
STUB
  chmod +x "$TMP/stub/aws"
  run bash "$SCRIPT" signstream/http main-abc123 1.2.33
  [ "$status" -ne 0 ]
  [[ "$output" == *"AccessDenied"* ]]
  [[ "$output" != *"retrying"* ]]
}
