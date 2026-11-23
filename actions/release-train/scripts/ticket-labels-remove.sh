#!/usr/bin/env bash
# ticket-labels-remove.sh <labels> <tickets>
#
# Removes each of <labels> (comma-separated label names) from each of
# <tickets> (comma-separated ids) that carries it, one label at a time
# (issueRemoveLabel), so a ticket's other labels stay. Idempotent: a label
# that is not there is left alone.
#
# Used at Promotion (SIG-2764) to clear Staging Passed / Staging Failed, so a
# staging pass of an earlier tag can never vouch for this one, and when a
# ticket goes to QA Failed (SIG-2767, SIG-2771) to clear QA Passed.
#
# Env: LINEAR_API_KEY (only when there are tickets).
# Stdout: [{id, removed: [names]}]. Exits 1 after trying every ticket when any
# Linear call failed.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

[ $# -eq 2 ] || die "usage: ticket-labels-remove.sh <labels> <tickets>"
need jq
names=$(csv_json "$1")
ids=$(csv_json "$2")
if [ "$ids" = '[]' ] || [ "$names" = '[]' ]; then
  echo '[]'
  exit 0
fi

out='[]'
errors=0
while IFS= read -r id; do
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  resp=$(linear_query 'query($id:String!){issue(id:$id){labels{nodes{id name}}}}' "$(jq -nc --arg id "$id" '{id:$id}')") || resp='{}'
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  # `arrays`: a reply without the label list (GraphQL errors, issue: null)
  # is a failure, not "no labels", or a stale verdict would survive.
  if ! hits=$(jq -ce --argjson n "$names" '.data.issue.labels.nodes | arrays | [.[] | select(.name as $x | $n | index($x))]' <<< "$resp" 2> /dev/null); then
    log "$id: cannot read its labels: $resp"
    errors=$((errors + 1))
    continue
  fi
  removed='[]'
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    lid=$(jq -r .id <<< "$l")
    name=$(jq -r .name <<< "$l")
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
    r=$(linear_query 'mutation($id:String!,$l:String!){issueRemoveLabel(id:$id,labelId:$l){success}}' \
      "$(jq -nc --arg id "$id" --arg l "$lid" '{id:$id, l:$l}')") || r='{}'
    if [ "$(jq -r '.data.issueRemoveLabel.success // false' <<< "$r" 2> /dev/null)" = true ]; then
      removed=$(jq -c --arg n "$name" '. + [$n]' <<< "$removed")
    else
      log "$id: removing '$name' failed: $r"
      errors=$((errors + 1))
    fi
  done < <(jq -c '.[]' <<< "$hits")
  out=$(jq -c --arg id "$id" --argjson r "$removed" '. + [{id: $id, removed: $r}]' <<< "$out")
done < <(jq -r '.[]' <<< "$ids")

echo "$out"
[ "$errors" -eq 0 ] || die "$errors Linear call(s) failed while removing $(jq -r 'join(", ")' <<< "$names")"
