#!/usr/bin/env bash
# s3-artefact-copy.sh <s3://src-bucket/key> <s3://dest-bucket/key>
#
# The ZIP counterpart of ecr-retag.sh (SIG-3189): copies a Lambda ZIP built
# once by main-push (<prefix>/main-<n>-<sha>.zip) to its release name
# (<prefix>/<release-tag>.zip), in the same or another environment's bucket.
# The bytes are downloaded and put back unchanged; the SHA-256 of both is
# compared, so the release artefact is provably the build that ran on dev.
#
#   * Idempotent: a dest that already holds the same bytes is a no-op.
#   * Never moves a release artefact: a dest holding OTHER bytes is refused.
#   * Conditional put (If-None-Match: *): a writer that created dest after
#     the lookup makes the put fail, and dest is read back instead.
#   * Verifies: dest is read back after the put and must hash the same.
# Only NoSuchKey (or a 404) means "does not exist": any other failure stops
# the script before a write, like ecr-retag.sh's lookup. The role therefore
# needs s3:ListBucket on the dest bucket (without it S3 answers a missing key
# with AccessDenied).
#
# The last stdout line is JSON:
#   {"source","dest","sha256","code_sha256","result"}
# sha256 is hex; code_sha256 is base64, the form Lambda reports as CodeSha256.
# result is copied or no-op.

set -euo pipefail

SRC="${1:?source s3 uri required}"
DEST="${2:?dest s3 uri required}"
URI='^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/(.+)$'
[[ "$SRC" =~ $URI ]] || { echo "not an s3://bucket/key uri: $SRC" >&2; exit 1; }
SRC_BUCKET="${BASH_REMATCH[1]}" SRC_KEY="${BASH_REMATCH[2]}"
[[ "$DEST" =~ $URI ]] || { echo "not an s3://bucket/key uri: $DEST" >&2; exit 1; }
DEST_BUCKET="${BASH_REMATCH[1]}" DEST_KEY="${BASH_REMATCH[2]}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sha_hex() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }
sha_b64() { openssl dgst -sha256 -binary "$1" | base64; }

if ! aws s3api get-object --bucket "$SRC_BUCKET" --key "$SRC_KEY" "$tmp/src" > /dev/null 2> "$tmp/src.err"; then
  echo "cannot read $SRC: $(cat "$tmp/src.err")" >&2
  exit 1
fi
[ -s "$tmp/src" ] || { echo "$SRC is empty" >&2; exit 1; }
src_sha=$(sha_hex "$tmp/src")
src_b64=$(sha_b64 "$tmp/src")

# dest_sha: the hex SHA-256 dest holds, or nothing when it does not exist.
dest_sha() {
  rm -f "$tmp/dest"
  if aws s3api get-object --bucket "$DEST_BUCKET" --key "$DEST_KEY" "$tmp/dest" > /dev/null 2> "$tmp/dest.err"; then
    sha_hex "$tmp/dest"
  elif grep -qE 'NoSuchKey|\(404\)|Not Found' "$tmp/dest.err"; then
    return 0
  else
    echo "cannot read $DEST: $(cat "$tmp/dest.err")" >&2
    return 1
  fi
}

result() {
  jq -nc --arg s "$SRC" --arg d "$DEST" --arg h "$src_sha" --arg b "$src_b64" --arg r "$1" \
    '{source: $s, dest: $d, sha256: $h, code_sha256: $b, result: $r}'
}
refuse() {
  echo "refusing to replace $DEST: it holds other bytes (sha256 $1) than $SRC ($src_sha)." \
    "A release artefact never changes. If git has no tag for it, an earlier Promotion stopped before the git tag" \
    "and left it behind: delete it (aws s3api delete-object --bucket $DEST_BUCKET --key $DEST_KEY) and re-run." >&2
  exit 1
}

have=$(dest_sha) || exit 1
if [ "$have" = "$src_sha" ]; then
  echo "no-op: $DEST already holds sha256 $src_sha"
  result no-op
  exit 0
fi
[ -z "$have" ] || refuse "$have"

if ! aws s3api put-object --bucket "$DEST_BUCKET" --key "$DEST_KEY" --body "$tmp/src" \
  --if-none-match '*' --checksum-sha256 "$src_b64" --metadata "sha256=$src_sha" > /dev/null 2> "$tmp/put.err"; then
  grep -qE 'PreconditionFailed|ConditionalRequestConflict' "$tmp/put.err" || { cat "$tmp/put.err" >&2; exit 1; }
  have=$(dest_sha) || exit 1
  if [ "$have" = "$src_sha" ]; then
    echo "no-op: $DEST was written with the same bytes meanwhile"
    result no-op
    exit 0
  fi
  refuse "${have:-unreadable}"
fi

have=$(dest_sha) || exit 1
if [ "$have" != "$src_sha" ]; then
  echo "sha256 mismatch after the copy: $SRC is $src_sha but $DEST is ${have:-missing}" >&2
  exit 1
fi
echo "copied: $SRC -> $DEST (sha256 $src_sha)"
result copied
