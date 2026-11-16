#!/usr/bin/env bash
# Shared helpers for release-train scripts. Source this file.

set -euo pipefail
IFS=$'\n\t'

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "missing dependency: $1"; }
# csv_json <a, b,,c>: ["a","b","c"]. Commas or newlines separate items;
# items are trimmed and empty ones dropped.
csv_json() { jq -nc --arg t "$1" '[$t | splits("[,\n]")] | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))'; }
