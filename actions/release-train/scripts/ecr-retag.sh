#!/usr/bin/env bash
# ecr-retag.sh <repo> <source_tag> <dest_tag>
#
# Copies the image manifest at <repo>:<source_tag> to <repo>:<dest_tag> via
# aws ecr put-image. No rebuild. Idempotent — if dest already points at the
# same manifest digest, exits 0 with "no-op".

set -euo pipefail

REPO="${1:?repo required}"
SRC="${2:?source_tag required}"
DEST="${3:?dest_tag required}"

src_image=$(aws ecr batch-get-image \
  --repository-name "$REPO" \
  --image-ids imageTag="$SRC" \
  --output json)

manifest=$(echo "$src_image" | jq -r '.images[0].imageManifest // empty')
if [ -z "$manifest" ]; then
  echo "manifest not found: $REPO:$SRC" >&2
  echo "$src_image" >&2
  exit 1
fi
src_digest=$(echo "$src_image" | jq -r '.images[0].imageId.imageDigest // empty')

dest_digest=$(aws ecr describe-images \
  --repository-name "$REPO" \
  --image-ids imageTag="$DEST" \
  --output json 2>/dev/null \
  | jq -r '.imageDetails[0].imageDigest // empty' || echo "")

if [ -n "$src_digest" ] && [ "$src_digest" = "$dest_digest" ]; then
  echo "no-op: $REPO:$DEST already points at $src_digest"
  exit 0
fi

aws ecr put-image \
  --repository-name "$REPO" \
  --image-tag "$DEST" \
  --image-manifest "$manifest" \
  > /dev/null
echo "retagged: $REPO:$SRC -> $REPO:$DEST"
