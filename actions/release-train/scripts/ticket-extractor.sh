#!/usr/bin/env bash
# ticket-extractor.sh <since-ref> <until-ref>
#
# Reads commits in the range, plus optional PR body on stdin. Emits a JSON
# array of <TEAM>-\d+ refs, uppercase, sorted numerically, deduped.
#
# LINEAR_TEAM_KEY selects the team prefix (default SIG). Alphanumeric only —
# the numeric sort splits on '-'.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -ge 2 ] || die "usage: ticket-extractor.sh <since-ref> <until-ref>"
SINCE="$1"
UNTIL="$2"

need git
need jq

TEAM_KEY="${LINEAR_TEAM_KEY:-SIG}"
case "$TEAM_KEY" in
  "" | *[!A-Za-z0-9]*) die "LINEAR_TEAM_KEY must be alphanumeric (got '$TEAM_KEY')" ;;
esac

commits=$(git log --format=%B "${SINCE}..${UNTIL}" 2>/dev/null || true)

pr_body=""
if [ ! -t 0 ]; then
  pr_body=$(cat)
fi

printf '%s\n%s\n' "$commits" "$pr_body" \
  | (grep -oiE "${TEAM_KEY}-[0-9]+" || true) \
  | tr '[:lower:]' '[:upper:]' \
  | awk -F- '!seen[$0]++ { print $2, $0 }' \
  | sort -n -k1,1 \
  | awk '{ print $2 }' \
  | jq -R . \
  | jq -sc '.'
