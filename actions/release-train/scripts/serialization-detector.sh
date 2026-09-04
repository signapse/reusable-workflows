#!/usr/bin/env bash
# serialization-detector.sh <since-ref> <until-ref>
#
# Emits { "touched": bool, "files": [paths...] } describing whether the
# diff touched files that affect cross-service serialization.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 2 ] || die "usage: serialization-detector.sh <since-ref> <until-ref>"
SINCE="$1"; UNTIL="$2"
need git; need jq

# Regex covers: SQS adaptor tree, DDB adaptor tree, domain tree, pub/sub-ish files.
PATTERN='^(internal/adaptors/queue/sqs/|internal/adaptors/storage/dynamodb/|internal/core/domain/|internal/.*(pubsub|publisher|subscriber|channels)\.go$)'

files=$(git diff --name-only "${SINCE}..${UNTIL}" | grep -E "$PATTERN" || true)

if [ -z "$files" ]; then
  echo '{"touched":false,"files":[]}'
else
  printf '%s\n' "$files" \
    | jq -R . \
    | jq -sc '{touched: (length > 0), files: .}'
fi
