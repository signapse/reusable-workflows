#!/usr/bin/env bash
# ticket-labels.sh
#
# Reads ["SIG-1","SIG-2"] on stdin. Emits each ticket's Linear label names as
# a JSON array of label arrays, in input order ([["Bug","hotfix"],["Feature"]]):
# the stdin format of deploy-window.sh (hotfix bypass) and version-bump.sh
# (major/minor). Any Linear failure, error or unknown ticket fails the run:
# a missed hotfix label only delays a Promotion, but a guessed version cannot
# be taken back once it is tagged.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

need jq

ids=$(jq -r '.[]?') || die "stdin must be a JSON array of ticket ids"
out='[]'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  # shellcheck disable=SC2016 # GraphQL variable, not shell expansion.
  resp=$(linear_query 'query($id:String!){issue(id:$id){identifier labels{nodes{name}}}}' \
    "$(jq -nc --arg id "$id" '{id:$id}')") || die "Linear query for $id failed"
  labels=$(printf '%s' "$resp" | jq -c '
    if (.errors // []) | length > 0 then error("errors")
    else .data.issue.labels.nodes | if type == "array" then [.[].name] else error("no labels") end
    end' 2>/dev/null) || die "Linear returned no labels for $id: $resp"
  out=$(jq -nc --argjson a "$out" --argjson l "$labels" '$a + [$l]')
done <<< "$ids"
echo "$out"
