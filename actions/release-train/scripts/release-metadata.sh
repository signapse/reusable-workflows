#!/usr/bin/env bash
# release-metadata.sh — cross-workflow-run kv persistence in the GitHub
# Release body (hidden HTML comment). Uses only gh contents:write —
# no PAT for Actions Variables.
#
# Functions:
#   release_meta_set <tag> <k=v>...
#   release_meta_get <tag> <key>          # prints value or empty; exit 0

set -euo pipefail

_meta_marker_start='<!-- release-train:meta'
_meta_marker_end='-->'

_meta_read_body() {
  gh release view "$1" --json body --jq .body
}

_meta_write_body() {
  local tag="$1" body="$2"
  local tmp; tmp=$(mktemp)
  printf '%s' "$body" > "$tmp"
  gh release edit "$tag" --notes-file "$tmp"
  rm -f "$tmp"
}

_meta_strip_block() {
  awk -v s="$_meta_marker_start" -v e="$_meta_marker_end" '
    index($0, s) { in_block = 1; next }
    in_block && index($0, e) { in_block = 0; next }
    !in_block { print }
  '
}

release_meta_set() {
  local tag="$1"; shift
  local body stripped block
  body=$(_meta_read_body "$tag")
  stripped=$(printf '%s' "$body" | _meta_strip_block)
  block="$_meta_marker_start"$'\n'
  for kv in "$@"; do
    block+="$kv"$'\n'
  done
  block+="$_meta_marker_end"
  if [ -n "$stripped" ]; then
    _meta_write_body "$tag" "$stripped"$'\n\n'"$block"
  else
    _meta_write_body "$tag" "$block"
  fi
}

release_meta_get() {
  local tag="$1" key="$2"
  local body; body=$(_meta_read_body "$tag")
  printf '%s' "$body" | awk -v s="$_meta_marker_start" -v e="$_meta_marker_end" -v k="$key" '
    index($0, s) { in_block = 1; next }
    in_block && index($0, e) { in_block = 0; next }
    in_block {
      i = index($0, "=")
      if (i > 0 && substr($0, 1, i-1) == k) {
        print substr($0, i+1)
        exit
      }
    }
  '
}
