#!/usr/bin/env bash
# pipeline-config.sh <key> [file]
#
# Prints a top-level scalar from a product repo's .signapse/pipeline.yml
# (default file), e.g. `pipeline-config.sh product` -> Signstream. Quotes and
# trailing comments are stripped. Exits 1 with a clear message when the file
# or the key is missing or empty: every caller needs the value to go on.
#
# Deliberately not yq: the file is a flat key: value list (see the contract in
# docs/RELEASE-TRAIN.md), and the tests then need nothing beyond bash.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: pipeline-config.sh <key> [file]"
key="$1"
file="${2:-.signapse/pipeline.yml}"

[ -f "$file" ] || die "$file not found: the repo must declare its product there (product: <terragrunt/products dir in signapse-core-terraform>)"

line=$(grep -E "^${key}:" "$file" | head -1 || true)
value=$(printf '%s' "${line#*:}" \
  | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
[ -n "$value" ] || die "$file has no '${key}:' value"
printf '%s\n' "$value"
