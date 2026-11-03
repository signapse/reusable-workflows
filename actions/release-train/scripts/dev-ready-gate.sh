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
#      QA Failed, are never touched.
#   2. If Linear has GitHub PRs attached to it, at least one is a PR merged in
#      this build (CURRENT_PRS), so a passing dev build of an unrelated change
#      does not move it. A ticket with no PR attachments is trusted on the
#      commit or branch mention alone.
#   3. Every other attached PR, in any repo, is merged and the main-push run on
#      its merge commit has a job matching SMOKE_JOB_PATTERN that succeeded.
#      PRs closed without merging are ignored. A merged PR in a repo whose runs
#      have no such job (a repo not on the pipeline, e.g. Terraform) counts as
#      passed only once every push run on its merge commit succeeded.
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
# Prints "pass|<note>", "skip|<note>" or "block|<reason>".
pr_verdict() {
  local repo="$1" num="$2" pr merged state sha runs jobs matched
  if ! pr=$(gh api "repos/${repo}/pulls/${num}" 2>/dev/null); then
    echo "block|cannot read ${repo}#${num} (token lacks access?)"
    return
  fi
  merged=$(printf '%s' "$pr" | jq -r '.merged_at // empty')
  state=$(printf '%s' "$pr" | jq -r '.state')
  if [ -z "$merged" ]; then
    if [ "$state" = "closed" ]; then
      echo "skip|${repo}#${num} closed without merging"
    else
      echo "block|${repo}#${num} not merged yet"
    fi
    return
  fi
  sha=$(printf '%s' "$pr" | jq -r '.merge_commit_sha')
  if ! runs=$(gh api "repos/${repo}/actions/runs?head_sha=${sha}&event=push&per_page=100" \
    --jq '[.workflow_runs[] | {id, status, conclusion}]' 2>/dev/null); then
    echo "block|cannot read workflow runs of ${repo}@${sha:0:7}"
    return
  fi
  jobs='[]'
  local id
  for id in $(printf '%s' "$runs" | jq -r '.[].id'); do
    local j
    if ! j=$(gh api "repos/${repo}/actions/runs/${id}/jobs?filter=latest&per_page=100" \
      --jq '[.jobs[] | {name, status, conclusion}]' 2>/dev/null); then
      echo "block|cannot read jobs of ${repo} run ${id}"
      return
    fi
    jobs=$(jq -nc --argjson a "$jobs" --argjson b "$j" '$a + $b')
  done
  # shellcheck disable=SC2016 # jq $p binding, not shell expansion.
  matched=$(printf '%s' "$jobs" | jq -c --arg p "$SMOKE_JOB_PATTERN" '[.[] | select(.name | test($p))]')
  if printf '%s' "$matched" | jq -e 'any(.[]; .conclusion == "success")' > /dev/null; then
    echo "pass|${repo}#${num} passed dev smoke"
  elif printf '%s' "$matched" | jq -e 'length > 0' > /dev/null; then
    if printf '%s' "$matched" | jq -e 'any(.[]; .status != "completed")' > /dev/null; then
      echo "block|${repo}#${num} dev smoke still running"
    else
      echo "block|${repo}#${num} dev smoke $(printf '%s' "$matched" | jq -r '[.[].conclusion] | unique | join(",")')"
    fi
  elif printf '%s' "$runs" | jq -e 'any(.[]; .status != "completed")' > /dev/null; then
    echo "block|${repo}#${num} build still running"
  elif printf '%s' "$runs" | jq -e 'length == 0' > /dev/null; then
    echo "block|${repo}#${num} has no main-push run on ${sha:0:7} yet"
  elif printf '%s' "$runs" | jq -e 'all(.[]; .conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral")' > /dev/null; then
    echo "pass|${repo}#${num} merged and its runs passed; ${repo} has no dev smoke job"
  else
    echo "block|${repo}#${num} has no dev smoke job and a run on ${sha:0:7} did not pass"
  fi
}

results='[]'
add() {
  # add <id> <move> <reason>
  log "$1: $([ "$2" = true ] && echo move || echo stay) - $3"
  results=$(printf '%s' "$results" | jq -c --arg id "$1" --argjson m "$2" --arg r "$3" '. + [{id:$id, move:$m, reason:$r}]')
}

while IFS= read -r id; do
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansion.
  resp=$(linear_query 'query($id:String!){issue(id:$id){identifier state{name} attachments{nodes{url}}}}' \
    "$(jq -nc --arg id "$id" '{id:$id}')" || true)
  issue=$(printf '%s' "$resp" | jq -c '.data.issue // empty' 2>/dev/null || true)
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

  blocked=""
  notes=""
  for ref in $(jq -rn --argjson l "$linked" --argjson c "$CURRENT_PRS" '$l[] | select(. as $x | $c | index($x) | not)'); do
    v=$(pr_verdict "${ref%#*}" "${ref##*#}")
    case "$v" in
      block\|*) blocked+="${blocked:+; }${v#block|}" ;;
      *) notes+="${notes:+; }${v#*|}" ;;
    esac
  done
  if [ -n "$blocked" ]; then
    add "$id" false "waiting on linked PRs: $blocked"
  else
    add "$id" true "all linked PRs merged and passed dev smoke${notes:+ ($notes)}"
  fi
done <<< "$tickets"

echo "$results"
