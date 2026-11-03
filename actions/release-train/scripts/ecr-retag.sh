#!/usr/bin/env bash
# ecr-retag.sh <repo> <source_tag> <dest_tag>
#
# Copies the image manifest at <repo>:<source_tag> to <repo>:<dest_tag> via
# aws ecr put-image. No rebuild: the manifest bytes are re-put unchanged, so
# both tags name the same image digest.
#
#   * Idempotent: if dest already points at the source digest, exits 0 with
#     "no-op".
#   * Never moves a release tag: if dest already points at a DIFFERENT digest,
#     fails rather than overwrite it (mutable repos would otherwise allow it).
#   * Verifies: after the put, dest's digest is read back and must equal the
#     source digest.
# The last stdout line is JSON:
#   {"repository","source_tag","tag","source_digest","tag_digest"}

set -euo pipefail

REPO="${1:?repo required}"
SRC="${2:?source_tag required}"
DEST="${3:?dest_tag required}"

# Ask for every manifest type so ECR returns the stored manifest as-is (an
# index from buildx included) rather than converting it.
ACCEPTED=(
  application/vnd.docker.distribution.manifest.v2+json
  application/vnd.docker.distribution.manifest.list.v2+json
  application/vnd.oci.image.manifest.v1+json
  application/vnd.oci.image.index.v1+json
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

src_image=$(aws ecr batch-get-image \
  --repository-name "$REPO" \
  --image-ids imageTag="$SRC" \
  --accepted-media-types "${ACCEPTED[@]}" \
  --output json)

# jq -j writes the manifest string byte for byte (no trailing newline), and
# put-image reads it from the file, so the digest cannot drift.
echo "$src_image" | jq -j '.images[0].imageManifest // empty' > "$tmp/manifest"
if [ ! -s "$tmp/manifest" ]; then
  echo "manifest not found: $REPO:$SRC" >&2
  echo "$src_image" >&2
  exit 1
fi
src_digest=$(echo "$src_image" | jq -r '.images[0].imageId.imageDigest // empty')
media_type=$(echo "$src_image" | jq -r '.images[0].imageManifestMediaType // empty')
if [ -z "$src_digest" ]; then
  echo "no digest for $REPO:$SRC" >&2
  exit 1
fi

dest_digest_of() {
  aws ecr describe-images \
    --repository-name "$REPO" \
    --image-ids imageTag="$DEST" \
    --output json 2>/dev/null \
    | jq -r '.imageDetails[0].imageDigest // empty' || true
}

result() {
  jq -nc --arg r "$REPO" --arg s "$SRC" --arg t "$DEST" --arg sd "$src_digest" --arg td "$1" \
    '{repository: $r, source_tag: $s, tag: $t, source_digest: $sd, tag_digest: $td}'
}

dest_digest=$(dest_digest_of)
if [ "$src_digest" = "$dest_digest" ]; then
  echo "no-op: $REPO:$DEST already points at $src_digest"
  result "$dest_digest"
  exit 0
fi
if [ -n "$dest_digest" ]; then
  echo "refusing to move $REPO:$DEST: it points at $dest_digest, not $REPO:$SRC ($src_digest)" >&2
  exit 1
fi

put_args=(--repository-name "$REPO" --image-tag "$DEST" --image-manifest "file://$tmp/manifest")
[ -z "$media_type" ] || put_args+=(--image-manifest-media-type "$media_type")
aws ecr put-image "${put_args[@]}" > /dev/null

dest_digest=$(dest_digest_of)
if [ "$dest_digest" != "$src_digest" ]; then
  echo "digest mismatch after retag: $REPO:$SRC is $src_digest but $REPO:$DEST is ${dest_digest:-missing}" >&2
  exit 1
fi
echo "retagged: $REPO:$SRC -> $REPO:$DEST ($src_digest)"
result "$dest_digest"
