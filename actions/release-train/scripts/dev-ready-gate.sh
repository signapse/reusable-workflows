#!/usr/bin/env bash
# dev-ready-gate.sh
#
# Decides which tickets this build may move to "On Dev · Ready for QA". Reads
# ["SIG-1","SIG-2"] on stdin and emits one decision per ticket on stdout:
#   [{id, move:bool, reason}]
# Log lines go to stderr. Stateless: everything is re-read from Linear and
# GitHub on every run, so whichever linked PR's build finishes last moves the
# ticket.
#
# A ticket moves only when all of these hold:
#   1. Its Linear state is one of FROM_STATES. Tickets further along, or in
#      QA Failed, are never touched. This is the allowed-from rule for the
#      move: ticket-transitioner.sh itself moves unconditionally. Once the
#      transitioner takes allowed-from and team options (#44), pass FROM_STATES
#      there too and keep a single implementation.
#   2. If Linear has GitHub PRs attached to it, at least one is a PR merged in
#      this build (CURRENT_PRS), so a passing dev build of an unrelated change
#      does not move it. A ticket with no PR attachments is trusted on the
#      commit or branch mention alone.
#   3. Every other attached PR, in any repo, is merged and the main-push run on
#      its merge commit has a job matching SMOKE_JOB_PATTERN that succeeded.
#      PRs closed without merging are ignored. A merged PR in a repo whose runs
#      have no such job (a repo not on the pipeline, e.g. Terraform) counts as
#      passed only once a push run on its merge commit succeeded and none
#      failed (all-skipped/neutral is not enough).
#      A linked PR whose build or dev smoke FAILED is superseded by another
#      PR on the same ticket, in the same repo, merged after it, whose build
#      passed (this build's PRs count as passed): main is linear, so that
#      later passing build contains the failed PR's change. Pending, open or
#      unreadable PRs are never superseded.
# The caller only invokes this after this build's own smoke passed, so the
# CURRENT_PRS are taken as passed.
#
# Env:
#   LINEAR_API_KEY     (required when stdin is non-empty)
#   GH_TOKEN           read access to pulls + actions of every linked repo
#   CURRENT_PRS        JSON array of "owner/repo#n" merged in this build
#   FROM_STATES        comma-separated (default "In Review,PR in Review")
#   SMOKE_JOB_PATTERN  jq test() regex over job names (default "Dev smoke verdict$")

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

need jq
need gh

FROM_STATES="${FROM_STATES:-In Review,PR in Review}"
SMOKE_JOB_PATTERN="${SMOKE_JOB_PATTERN:-Dev smoke verdict\$}"
CURRENT_PRS=$(printf '%s' "${CURRENT_PRS:-[]}" | jq -c '[.[] | ascii_downcase]')

tickets=$(jq -r '.[]?')
if [ -z "$tickets" ]; then
  echo '[]'
  exit 0
fi
[ -n "${LINEAR_API_KEY:-}" ] || die "LINEAR_API_KEY not set"

from_json=$(printf '%s' "$FROM_STATES" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))')

# pr_verdict <owner/repo> <number>
# Prints one compact JSON object {ref, repo, kind, merged, text} where kind is
#   pass   merged and passed (merged = merged_at)
#   skip   closed without merging (ignored)
#   block  not decidable yet: open, still running, unreadable, no run yet
#   fail   merged, finished, did not pass (merged = merged_at); may be
#          superseded by a later passing PR in the same repo
pr_verdict() {
  local repo="$1" num="$2" pr merged="" state sha runs jobs matched
  v() { jq -nc --arg ref "${repo}#${num}" --arg repo "$repo" --arg k "$1" --arg m "$merged" --arg t "$2" \
    '{ref:$ref, repo:$repo, kind:$k, merged:$m, text:$t}'; }
  if ! pr=$(gh api "repos/${repo}/pulls/${num}" 2>/dev/null); then
    v block "cannot read ${repo}#${num} (token lacks access?)"
    return
  fi
  merged=$(printf '%s' "$pr" | jq -r '.merged_at // empty')
  state=$(printf '%s' "$pr" | jq -r '.state')
  if [ -z "$merged" ]; then
    if [ "$state" = "closed" ]; then
      v skip "${repo}#${num} closed without merging"
    else
      v block "${repo}#${num} not merged yet"
    fi
    return
  fi
  sha=$(printf '%s' "$pr" | jq -r '.merge_commit_sha')
  if ! runs=$(gh api "repos/${repo}/actions/runs?head_sha=${sha}&event=push&per_page=100" \
    --jq '[.workflow_runs[] | {id, status, conclusion}]' 2>/dev/null); then
    v block "cannot read workflow runs of ${repo}@${sha:0:7}"
    return
  fi
  jobs='[]'
  local id
  for id in $(printf '%s' "$runs" | jq -r '.[].id'); do
    local j
    if ! j=$(gh api "repos/${repo}/actions/runs/${id}/jobs?filter=latest&per_page=100" \
      --jq '[.jobs[] | {name, status, conclusion}]' 2>/dev/null); then
      v block "cannot read jobs of ${repo} run ${id}"
      return
    fi
    jobs=$(jq -nc --argjson a "$jobs" --argjson b "$j" '$a + $b')
  done
  # shellcheck disable=SC2016 # jq $p binding, not shell expansion.
  matched=$(printf '%s' "$jobs" | jq -c --arg p "$SMOKE_JOB_PATTERN" '[.[] | select(.name | test($p))]')
  if printf '%s' "$matched" | jq -e 'any(.[]; .conclusion == "success")' > /dev/null; then
    v pass "${repo}#${num} passed dev smoke"
  elif printf '%s' "$matched" | jq -e 'length > 0' > /dev/null; then
    if printf '%s' "$matched" | jq -e 'any(.[]; .status != "completed")' > /dev/null; then
      v block "${repo}#${num} dev smoke still running"
    else
      v fail "${repo}#${num} dev smoke $(printf '%s' "$matched" | jq -r '[.[].conclusion] | unique | join(",")')"
    fi
  elif printf '%s' "$runs" | jq -e 'any(.[]; .status != "completed")' > /dev/null; then
    v block "${repo}#${num} build still running"
  elif printf '%s' "$runs" | jq -e 'length == 0' > /dev/null; then
    v block "${repo}#${num} has no main-push run on ${sha:0:7} yet"
  elif printf '%s' "$runs" | jq -e 'any(.[]; .conclusion == "success")
      and all(.[]; .conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral")' > /dev/null; then
    v pass "${repo}#${num} merged and its runs passed; ${repo} has no dev smoke job"
  else
    v fail "${repo}#${num} has no dev smoke job and a run on ${sha:0:7} did not pass"
  fi
}

results='[]'
add() {
  # add <id> <move> <reason>
  log "$1: $([ "$2" = true ] && echo move || echo stay) - $3"
  results=$(printf '%s' "$results" | jq -c --arg id "$1" --argjson m "$2" --arg r "$3" '. + [{id:$id, move:$m, reason:$r}]')
}

while IFS= read -r id; do
  # A genuine miss (rc 3) only skips this ticket; any other Linear failure
  # (bad key, rate limit, outage) fails the run instead of reporting every
  # ticket as "not found" and going green.
  rc=0
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  data=$(linear_gql 'query($id:String!){issue(id:$id){identifier state{name} attachments{nodes{url}}}}' \
    "$(jq -nc --arg id "$id" '{id:$id}')") || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    die "Linear lookup of $id failed; no tickets moved"
  fi
  issue=""
  [ "$rc" -ne 0 ] || issue=$(printf '%s' "$data" | jq -c '.issue // empty')
  if [ -z "$issue" ]; then
    add "$id" false "not found in Linear"
    continue
  fi
  state=$(printf '%s' "$issue" | jq -r '.state.name')
  if ! jq -en --arg s "$state" --argjson f "$from_json" '$f | index($s)' > /dev/null; then
    add "$id" false "state '$state' is not one of $(printf '%s' "$from_json" | jq -r 'join(", ")')"
    continue
  fi

  linked=$(printf '%s' "$issue" | jq -c '
    [.attachments.nodes[].url
     | capture("^https://github\\.com/(?<o>[^/]+)/(?<r>[^/]+)/pull/(?<n>[0-9]+)")?
     | "\(.o)/\(.r)#\(.n)" | ascii_downcase] | unique')
  if jq -en --argjson l "$linked" --argjson c "$CURRENT_PRS" \
    '($l | length) > 0 and ([$l[] | select(. as $x | $c | index($x))] | length) == 0' > /dev/null; then
    add "$id" false "none of its linked PRs ($(printf '%s' "$linked" | jq -r 'join(", ")')) is in this build"
    continue
  fi

  verdicts='[]'
  for ref in $(jq -rn --argjson l "$linked" --argjson c "$CURRENT_PRS" '$l[] | select(. as $x | $c | index($x) | not)'); do
    verdicts=$(jq -c --argjson e "$(pr_verdict "${ref%#*}" "${ref##*#}")" '. + [$e]' <<<"$verdicts")
  done
  # This build's own linked PRs passed. Their merge time only matters when a
  # failed PR in the same repo might be superseded, so fetch it only then.
  for ref in $(jq -rn --argjson l "$linked" --argjson c "$CURRENT_PRS" '$l[] | select(. as $x | $c | index($x))'); do
    repo="${ref%#*}"
    merged=""
    if jq -e --arg r "$repo" 'any(.[]; .kind == "fail" and .repo == $r)' > /dev/null <<<"$verdicts"; then
      merged=$(gh api "repos/${repo}/pulls/${ref##*#}" --jq '.merged_at // ""' 2>/dev/null || true)
    fi
    verdicts=$(jq -c --arg ref "$ref" --arg r "$repo" --arg m "$merged" \
      '. + [{ref:$ref, repo:$r, kind:"pass", merged:$m, text:"\($ref) is in this build"}]' <<<"$verdicts")
  done
  # A fail is superseded by a pass in the same repo merged strictly after it
  # (ISO-8601 UTC timestamps compare correctly as strings).
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  decided=$(jq -c '. as $all | map(
      if .kind == "fail" then
        . as $f
        | ([$all[] | select(.kind == "pass" and .repo == $f.repo and .merged != "" and $f.merged != "" and .merged > $f.merged)]
           | sort_by(.merged) | last) as $by
        | if $by then .kind = "superseded" | .text = "\($f.text), superseded by \($by.ref) merged later and passing"
          else . end
      else . end)' <<<"$verdicts")
  blocked=$(jq -r '[.[] | select(.kind == "block" or .kind == "fail") | .text] | join("; ")' <<<"$decided")
  notes=$(jq -r '[.[] | select(.kind != "block" and .kind != "fail" and (.text | endswith("is in this build") | not)) | .text] | join("; ")' <<<"$decided")
  if [ -n "$blocked" ]; then
    add "$id" false "waiting on linked PRs: $blocked"
  else
    add "$id" true "all linked PRs merged and passed dev smoke${notes:+ ($notes)}"
  fi
done <<< "$tickets"

echo "$results"
