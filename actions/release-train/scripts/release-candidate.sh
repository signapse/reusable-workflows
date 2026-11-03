#!/usr/bin/env bash
# release-candidate.sh [<last-tag>] [<head-ref>]
#
# Selects the Release Candidate (ADR 0001): the newest build on main whose
# tickets all carry QA Passed. Emits one compact JSON object on stdout; log
# lines go to stderr.
#
# Walk: main's first-parent commits in <last-tag>..<head-ref>, oldest first.
#   * A commit's tickets are the <TEAM>-<n> refs in the commits it brought in
#     (<sha>^1..<sha>, so a merge commit includes its branch) plus the title
#     and head branch of the PR(s) GitHub associates with it. PR bodies are
#     ignored: they mention related tickets too often.
#   * A ticket blocks when it is in the QA Failed column, lacks the QA Passed
#     label, or cannot be read from Linear. The walk stops at the first
#     blocking commit: nothing at or past it is selectable.
#   * A commit with no ticket never blocks; it rides along as untracked.
#   * A build is a commit with a successful run of BUILD_WORKFLOW (main-push)
#     on BRANCH. Its image tag is main-<run_number>-<sha>, the tag main-push
#     gives every service image. The Release Candidate is the last build seen
#     before the walk stops.
# Everything is re-read from git, Linear and GitHub on every run, and nothing
# depends on which ticket triggered the run, so a repeat run with nothing
# changed selects the same build (the hourly backstop relies on this).
#
# <last-tag> empty or omitted: the highest tag merged into <head-ref> that
# matches RELEASE_TAG_PATTERN (the last Promotion). <head-ref> defaults to HEAD.
#
# Output:
#   {last_tag, head_sha, outcome, already_promoted,
#    rc: {sha, image_tag, run_number, run_url} | null,
#    tickets: [{id, title, url, state}],          # tickets up to the RC
#    untracked_commits: [{sha, subject}],         # ticketless commits up to the RC
#    blocked_by: {id, title, url, state, reason, sha, subject} | null,
#    commits: [{sha, subject, tickets, build}]}   # every commit walked
# outcome: selected | already_promoted | none
#
# Env:
#   GITHUB_REPOSITORY    owner/repo (required)
#   GH_TOKEN             actions:read + pull-requests:read on the repo
#   LINEAR_API_KEY       required when any walked commit carries a ticket
#   LINEAR_TEAM_KEY      ticket prefix (default SIG)
#   QA_PASSED_LABEL      default "QA Passed"
#   QA_FAILED_STATE      default "QA Failed"
#   BUILD_WORKFLOW       workflow file name of the build (default main-push.yml)
#   BRANCH               default main
#   RELEASE_TAG_PATTERN  ERE for Promotion tags (default ^v?[0-9]+\.[0-9]+\.[0-9]+$)

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

[ $# -le 2 ] || die "usage: release-candidate.sh [<last-tag>] [<head-ref>]"
LAST_TAG="${1:-}"
HEAD_REF="${2:-HEAD}"

need git
need gh
need jq

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
QA_PASSED_LABEL="${QA_PASSED_LABEL:-QA Passed}"
QA_FAILED_STATE="${QA_FAILED_STATE:-QA Failed}"
BUILD_WORKFLOW="${BUILD_WORKFLOW:-main-push.yml}"
BRANCH="${BRANCH:-main}"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-^v?[0-9]+\.[0-9]+\.[0-9]+$}"
HERE="$(dirname "$0")"

head_sha=$(git rev-parse --verify "${HEAD_REF}^{commit}") || die "unknown ref: $HEAD_REF"

if [ -z "$LAST_TAG" ]; then
  LAST_TAG=$(git tag --merged "$head_sha" --sort=-v:refname \
    | { grep -E "$RELEASE_TAG_PATTERN" || true; } | head -n 1)
  [ -n "$LAST_TAG" ] || die "no tag matching $RELEASE_TAG_PATTERN on $HEAD_REF; seed one (git tag 0.0.0 <sha>)"
fi
git rev-parse --verify -q "${LAST_TAG}^{commit}" > /dev/null || die "unknown tag: $LAST_TAG"
log "last Promotion tag: $LAST_TAG"

# ticket_verdict <id>: sets VERDICT to {id,title,url,state,blocks,reason}.
# Cached so a ticket spread over several commits is read from Linear once (it
# sets a global rather than printing, because $(...) would drop the cache).
# The cache is a JSON object, not an associative array, so the script also
# runs on macOS's bash 3.2.
VERDICTS='{}'
VERDICT=''
ticket_verdict() {
  local id="$1" resp issue
  VERDICT=$(printf '%s' "$VERDICTS" | jq -c --arg id "$id" '.[$id] // empty')
  if [ -n "$VERDICT" ]; then return 0; fi
  # A Linear failure must never let a ticket through, so it blocks; the run
  # fails below rather than selecting past a ticket it could not read.
  # shellcheck disable=SC2016 # GraphQL variable, not shell expansion.
  resp=$(linear_query 'query($id:String!){issue(id:$id){identifier title url state{name} labels{nodes{name}}}}' \
    "$(jq -nc --arg id "$id" '{id:$id}')") || die "Linear query for $id failed"
  issue=$(printf '%s' "$resp" | jq -c '.data.issue // empty' 2>/dev/null || true)
  if [ -z "$issue" ]; then
    VERDICT=$(jq -nc --arg id "$id" \
      '{id:$id, title:"", url:"", state:"", blocks:true, reason:"not found in Linear"}')
  else
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    VERDICT=$(printf '%s' "$issue" | jq -c --arg passed "$QA_PASSED_LABEL" --arg failed "$QA_FAILED_STATE" '
      {id: .identifier, title, url, state: .state.name} as $t
      | ([.labels.nodes[]?.name] | index($passed) != null) as $has
      | if .state.name == $failed then $t + {blocks:true, reason:"in \($failed)"}
        elif ($has | not) then $t + {blocks:true, reason:"no \($passed) label (state \(.state.name))"}
        else $t + {blocks:false, reason:""} end')
  fi
  VERDICTS=$(printf '%s' "$VERDICTS" | jq -c --arg id "$id" --argjson v "$VERDICT" '.[$id] = $v')
}

# build_of <sha>: prints {run_number, run_url} of the newest successful build
# run on BRANCH for <sha>, or nothing.
build_of() {
  local sha="$1"
  gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/${BUILD_WORKFLOW}/runs?head_sha=${sha}&branch=${BRANCH}&status=success&per_page=100" \
    --jq '[.workflow_runs[] | select(.event == "push" or .event == "workflow_dispatch")
           | {run_number, run_url: .html_url}] | max_by(.run_number) // empty' \
    || die "cannot read ${BUILD_WORKFLOW} runs for ${sha:0:7} (token needs actions:read)"
}

# pr_text <sha>: title and head branch of the PRs associated with <sha>.
pr_text() {
  gh api "repos/${GITHUB_REPOSITORY}/commits/$1/pulls" \
    --jq '.[] | select(.merged_at != null) | .title, .head.ref' \
    || die "cannot read PRs for ${1:0:7} (token needs pull-requests:read)"
}

commits='[]'
tickets='[]'
untracked='[]'
untracked_pending='[]'
tickets_pending='[]'
rc='null'
blocked='null'

while IFS= read -r sha; do
  [ -z "$sha" ] && continue
  subject=$(git log -1 --format=%s "$sha")
  refs=$(pr_text "$sha" | "$HERE/ticket-extractor.sh" "${sha}^1" "$sha")

  block='null'
  verdicts='[]'
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    ticket_verdict "$id"
    v="$VERDICT"
    verdicts=$(jq -nc --argjson a "$verdicts" --argjson v "$v" '$a + [$v]')
    if [ "$block" = 'null' ] && [ "$(printf '%s' "$v" | jq -r .blocks)" = true ]; then
      block="$v"
    fi
  done < <(printf '%s' "$refs" | jq -r '.[]')

  if [ "$block" != 'null' ]; then
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    blocked=$(printf '%s' "$block" | jq -c --arg sha "$sha" --arg s "$subject" \
      '{id, title, url, state, reason, sha: $sha, subject: $s}')
    commits=$(jq -nc --argjson a "$commits" --arg sha "$sha" --arg s "$subject" --argjson r "$refs" \
      '$a + [{sha: $sha, subject: $s, tickets: $r, build: null}]')
    log "stop at ${sha:0:7}: $(printf '%s' "$block" | jq -r '"\(.id) \(.reason)"')"
    break
  fi

  if [ "$refs" = '[]' ]; then
    untracked_pending=$(jq -nc --argjson a "$untracked_pending" --arg sha "$sha" --arg s "$subject" \
      '$a + [{sha: $sha, subject: $s}]')
  else
    tickets_pending=$(jq -nc --argjson a "$tickets_pending" --argjson v "$verdicts" \
      '$a + [$v[] | {id, title, url, state}]')
  fi

  build=$(build_of "$sha")
  [ -z "$build" ] && build='null'
  commits=$(jq -nc --argjson a "$commits" --arg sha "$sha" --arg s "$subject" --argjson r "$refs" --argjson b "$build" \
    '$a + [{sha: $sha, subject: $s, tickets: $r, build: $b}]')

  if [ "$build" != 'null' ]; then
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    rc=$(printf '%s' "$build" | jq -c --arg sha "$sha" \
      '{sha: $sha, image_tag: "main-\(.run_number)-\($sha)", run_number, run_url}')
    tickets=$(jq -nc --argjson a "$tickets" --argjson b "$tickets_pending" '$a + $b | unique_by(.id)')
    untracked=$(jq -nc --argjson a "$untracked" --argjson b "$untracked_pending" '$a + $b')
    tickets_pending='[]'
    untracked_pending='[]'
  fi
done < <(git rev-list --first-parent --reverse "${LAST_TAG}..${head_sha}")

already=false
outcome=none
if [ "$rc" != 'null' ]; then
  outcome=selected
  rc_sha=$(printf '%s' "$rc" | jq -r .sha)
  if git tag --points-at "$rc_sha" | grep -qE "$RELEASE_TAG_PATTERN"; then
    already=true
    outcome=already_promoted
  fi
fi

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc \
  --arg last_tag "$LAST_TAG" \
  --arg head_sha "$head_sha" \
  --arg outcome "$outcome" \
  --argjson already "$already" \
  --argjson rc "$rc" \
  --argjson tickets "$tickets" \
  --argjson untracked "$untracked" \
  --argjson blocked "$blocked" \
  --argjson commits "$commits" \
  '{last_tag: $last_tag, head_sha: $head_sha, outcome: $outcome, already_promoted: $already,
    rc: $rc, tickets: $tickets, untracked_commits: $untracked, blocked_by: $blocked,
    commits: $commits}'
