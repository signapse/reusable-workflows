#!/usr/bin/env bash
# pipeline-config.sh <key> [--required] [file]
#
# Prints a top-level scalar from a product repo's .signapse/pipeline.yml
# (default file: $PIPELINE_CONFIG, else .signapse/pipeline.yml), e.g.
# `pipeline-config.sh product` -> Signstream.
#
# Without --required, a missing file or key prints nothing and exits 0
# (optional keys such as sentry_project). With --required it exits 1 with a
# clear message instead (keys every caller needs, such as product).
#
# A trailing comment is stripped; a quoted value is taken verbatim between its
# quotes, so it may contain '#'. Deliberately not yq: the file is a flat
# key: value list, and the tests then need nothing beyond bash.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

usage="usage: pipeline-config.sh <key> [--required] [file]"
[ $# -ge 1 ] || die "$usage"
key="$1"
shift
required=false
file="${PIPELINE_CONFIG:-.signapse/pipeline.yml}"
for arg in "$@"; do
  case "$arg" in
    --required) required=true ;;
    -*) die "$usage" ;;
    *) file="$arg" ;;
  esac
done

missing() {
  [ "$required" = true ] && die "$1"
  exit 0
}

[ -f "$file" ] || missing "$file not found: the repo must declare its pipeline config there (see docs)"

line=$(sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -1)
case "$line" in
  \"*) line="${line#\"}"; value="${line%%\"*}" ;;
  \'*) line="${line#\'}"; value="${line%%\'*}" ;;
  *) value=$(printf '%s\n' "$line" | sed -e 's/^#.*$//' -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//') ;;
esac
[ -n "$value" ] || missing "$file has no '${key}:' value"
printf '%s\n' "$value"
