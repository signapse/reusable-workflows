#!/usr/bin/env bash
# version-bump.sh <current-version>
#
# Reads JSON array-of-label-arrays on stdin. Emits next semver.
# Rule precedence: any 'major' → major; else any 'minor' → minor; else patch.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 1 ] || die "usage: version-bump.sh <current-version>"
CUR="$1"
need jq

[[ "$CUR" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "bad current version: $CUR"
MAJ=${BASH_REMATCH[1]}
MIN=${BASH_REMATCH[2]}
PAT=${BASH_REMATCH[3]}

labels=$(jq -r 'flatten | .[]' 2>/dev/null) || die "invalid JSON on stdin"

kind="patch"
while IFS= read -r label; do
  case "$label" in
    major) kind="major"; break ;;
    minor) [ "$kind" = "patch" ] && kind="minor" ;;
  esac
done <<< "$labels"

case "$kind" in
  major) printf '%d.0.0\n' $((MAJ + 1)) ;;
  minor) printf '%d.%d.0\n' "$MAJ" $((MIN + 1)) ;;
  patch) printf '%d.%d.%d\n' "$MAJ" "$MIN" $((PAT + 1)) ;;
esac
