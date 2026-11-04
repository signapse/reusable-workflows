#!/usr/bin/env bash
# release-candidate.sh [<base>] [<head-ref>]
#
# Selects the Release Candidate (ADR 0001): the newest build on main whose
# tickets all carry QA Passed. Emits one compact JSON object on stdout; log
# lines go to stderr.
#
# <base> is where the walk starts. The train passes the release tag prod runs
# (selection-base.sh), so every commit not yet in prod is checked again on
# every run: a tag that failed staging or was rolled back leaves its tickets
# in QA Failed, and they keep stopping the line until QA re-passes them or
# their commits are reverted. Walking only from the last Promotion would let
# the next Release Candidate carry that code past them.
#
# Walk: main's first-parent commits in <base>..<head-ref>, oldest first.
#   * A commit's tickets are the <TEAM>-<n> refs in the commits it brought in
#     (<sha>^1..<sha>, so a merge commit includes its branch) plus the title
#     and head branch of the PR(s) GitHub associates with it. PR bodies are
#     ignored: they mention related tickets too often.
#   * A ticket blocks when it is in the QA Failed column, lacks the QA Passed
#     label, or cannot be read from Linear. The walk stops at the first
#     blocking commit: nothing at or past it is selectable.
#   * A commit with no ticket never blocks; it rides along as untracked.
#   * Reverts (lib/revert.sh, ADR 0001's 24 h revert, SIG-2766): a commit
#     reverted later in the range, by a revert that is not itself reverted,
#     does not block and its tickets are not in the candidate; no build
#     between it and its revert is selectable, because those builds still
#     contain its code. A revert commit (or a merged revert PR) never blocks
#     either, whatever ticket its message, title or branch names; it rides
#     along as untracked. A re-land (revert of a revert) is a normal commit.
#   * A build is a commit with a successful run of BUILD_WORKFLOW (main-push)
#     on BRANCH. Its image tag is main-<run_number>-<sha>, the tag main-push
#     gives every service image. The Release Candidate is the last build seen
#     before the walk stops.
# Everything is re-read from git, Linear and GitHub on every run, and nothing
# depends on which ticket triggered the run, so a repeat run with nothing
# changed selects the same build (the hourly backstop relies on this).
#
# <base> empty or omitted: the nearest tag matching RELEASE_TAG_PATTERN on
# <head-ref>'s first-parent history (the last Promotion). Tests and manual runs
# only; the train always passes the prod tag. <head-ref> defaults to HEAD.
#
# Output:
#   {base, last_tag (= base), last_release_tag, head_sha, outcome, already_promoted,
#    rc: {sha, image_tag, run_number, run_url, release_tag} | null,
#    tickets: [{id, title, url, state}],          # every live ticket from <base> to the RC
#    untracked_commits: [{sha, subject, revert?}],# ticketless and revert commits up to the RC
#    reverted: [{sha, subject, tickets, reverted_by}],  # reverted commits walked
#    staged: {sha, image_tag, release_tag, tickets: [ids]} | null,
#                       # newest build up to the RC that already carries a
#                       # release tag: what prod may deploy (resume mode)
#    blocked_by: {id, title, url, state, reason, sha, subject} | null,
#    commits: [{sha, subject, tickets, build, kind}]}   # every commit walked
# outcome: selected | already_promoted (the RC already carries a release tag:
# promoted before, nothing new to promote) | none
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
# shellcheck source=SCRIPTDIR/../lib/release-tag.sh
source "$(dirname "$0")/../lib/release-tag.sh"
# shellcheck source=SCRIPTDIR/../lib/revert.sh
source "$(dirname "$0")/../lib/revert.sh"

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

last_release=$(last_release_tag "$head_sha" "$RELEASE_TAG_PATTERN")
if [ -z "$LAST_TAG" ]; then
  LAST_TAG="$last_release"
  [ -n "$LAST_TAG" ] || die "no tag matching $RELEASE_TAG_PATTERN on $HEAD_REF's first-parent history; seed one (git tag 0.0.0 <sha>)"
fi
git rev-parse --verify -q "${LAST_TAG}^{commit}" > /dev/null || die "unknown tag: $LAST_TAG"
git merge-base --is-ancestor "$LAST_TAG" "$head_sha" || die "walk base $LAST_TAG is not in $HEAD_REF's history"
log "walk base: $LAST_TAG (last release tag: ${last_release:-none})"
units=$(revert_units "$LAST_TAG" "$head_sha")

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
  # A Linear failure must never let a ticket through: a failed call, an
  # unparsable reply, GraphQL errors next to issue data, or an issue missing
  # the fields the verdict reads all fail the run rather than select past it.
  # shellcheck disable=SC2016 # GraphQL variable, not shell expansion.
  resp=$(linear_query 'query($id:String!){issue(id:$id){identifier title url state{name} labels{nodes{name}}}}' \
    "$(jq -nc --arg id "$id" '{id:$id}')") || die "Linear query for $id failed"
  printf '%s' "$resp" | jq -e 'type == "object"' > /dev/null 2>&1 \
    || die "Linear returned an unparsable reply for $id"
  issue=$(printf '%s' "$resp" | jq -c '.data.issue // empty')
  if [ -z "$issue" ]; then
    # issue: null is how Linear answers an unknown identifier. It blocks.
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    VERDICT=$(printf '%s' "$resp" | jq -c --arg id "$id" '
      ([.errors[]?.message] | join("; ")) as $e
      | {id:$id, title:"", url:"", state:"", blocks:true,
         reason: ("not found in Linear" + (if $e != "" then " (\($e))" else "" end))}')
  else
    printf '%s' "$resp" | jq -e '(.errors // []) | length == 0' > /dev/null \
      || die "Linear returned errors with partial data for $id: $(printf '%s' "$resp" | jq -c .errors)"
    printf '%s' "$issue" | jq -e '(.identifier | type) == "string" and (.state.name | type) == "string"
        and (.labels.nodes | type) == "array"' > /dev/null \
      || die "Linear reply for $id lacks identifier, state or labels: $issue"
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    VERDICT=$(printf '%s' "$issue" | jq -c --arg passed "$QA_PASSED_LABEL" --arg failed "$QA_FAILED_STATE" '
      {id: .identifier, title, url, state: .state.name} as $t
      | ([.labels.nodes[].name] | index($passed) != null) as $has
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
reverted='[]'
holes='[]'   # live reverting commits not walked yet: no build is selectable
rc='null'
staged='null'
blocked='null'

while IFS= read -r sha; do
  [ -z "$sha" ] && continue
  subject=$(git log -1 --format=%s "$sha")
  refs=$(pr_text "$sha" | "$HERE/ticket-extractor.sh" "${sha}^1" "$sha")
  unit=$(printf '%s' "$units" | jq -c --arg s "$sha" '.[$s] // {kind: "normal", reverted_by: []}')
  kind=$(printf '%s' "$unit" | jq -r .kind)

  # A hole closes once its reverting commit is in this first-parent commit.
  if [ "$holes" != '[]' ]; then
    left='[]'
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      git merge-base --is-ancestor "$r" "$sha" \
        || left=$(jq -nc --argjson a "$left" --arg r "$r" '$a + [$r]')
    done < <(printf '%s' "$holes" | jq -r '.[]')
    holes="$left"
  fi

  block='null'
  verdicts='[]'
  if [ "$kind" = normal ]; then
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      ticket_verdict "$id"
      v="$VERDICT"
      verdicts=$(jq -nc --argjson a "$verdicts" --argjson v "$v" '$a + [$v]')
      if [ "$block" = 'null' ] && [ "$(printf '%s' "$v" | jq -r .blocks)" = true ]; then
        block="$v"
      fi
    done < <(printf '%s' "$refs" | jq -r '.[]')
  fi

  if [ "$block" != 'null' ]; then
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    blocked=$(printf '%s' "$block" | jq -c --arg sha "$sha" --arg s "$subject" \
      '{id, title, url, state, reason, sha: $sha, subject: $s}')
    commits=$(jq -nc --argjson a "$commits" --arg sha "$sha" --arg s "$subject" --argjson r "$refs" \
      '$a + [{sha: $sha, subject: $s, tickets: $r, build: null, kind: "normal"}]')
    log "stop at ${sha:0:7}: $(printf '%s' "$block" | jq -r '"\(.id) \(.reason)"')"
    break
  fi

  case "$kind" in
    reverted)
      # shellcheck disable=SC2016 # jq bindings, not shell expansion.
      reverted=$(jq -nc --argjson a "$reverted" --arg sha "$sha" --arg s "$subject" --argjson r "$refs" --argjson u "$unit" \
        '$a + [{sha: $sha, subject: $s, tickets: $r, reverted_by: $u.reverted_by}]')
      holes=$(jq -nc --argjson a "$holes" --argjson u "$unit" '$a + $u.reverted_by | unique')
      log "${sha:0:7} is reverted later; its tickets ($(printf '%s' "$refs" | jq -r 'join(",")')) do not block"
      ;;
    revert)
      untracked_pending=$(jq -nc --argjson a "$untracked_pending" --arg sha "$sha" --arg s "$subject" \
        '$a + [{sha: $sha, subject: $s, revert: true}]')
      ;;
    *)
      if [ "$refs" = '[]' ]; then
        untracked_pending=$(jq -nc --argjson a "$untracked_pending" --arg sha "$sha" --arg s "$subject" \
          '$a + [{sha: $sha, subject: $s}]')
      else
        tickets_pending=$(jq -nc --argjson a "$tickets_pending" --argjson v "$verdicts" \
          '$a + [$v[] | {id, title, url, state}]')
      fi
      ;;
  esac

  build=$(build_of "$sha")
  [ -z "$build" ] && build='null'
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  commits=$(jq -nc --argjson a "$commits" --arg sha "$sha" --arg s "$subject" --argjson r "$refs" --argjson b "$build" --arg k "$kind" \
    '$a + [{sha: $sha, subject: $s, tickets: $r, build: $b, kind: $k}]')

  if [ "$build" != 'null' ] && [ "$holes" = '[]' ]; then
    tag=$(release_tag_at "$sha" "$RELEASE_TAG_PATTERN")
    # shellcheck disable=SC2016 # jq bindings, not shell expansion.
    rc=$(printf '%s' "$build" | jq -c --arg sha "$sha" --arg t "$tag" \
      '{sha: $sha, image_tag: "main-\(.run_number)-\($sha)", run_number, run_url, release_tag: $t}')
    tickets=$(jq -nc --argjson a "$tickets" --argjson b "$tickets_pending" '$a + $b | unique_by(.id)')
    untracked=$(jq -nc --argjson a "$untracked" --argjson b "$untracked_pending" '$a + $b')
    tickets_pending='[]'
    untracked_pending='[]'
    if [ -n "$tag" ]; then
      # shellcheck disable=SC2016 # jq bindings, not shell expansion.
      staged=$(jq -nc --argjson rc "$rc" --argjson t "$tickets" \
        '{sha: $rc.sha, image_tag: $rc.image_tag, release_tag: $rc.release_tag, tickets: [$t[].id]}')
    fi
  elif [ "$build" != 'null' ]; then
    log "build of ${sha:0:7} is not selectable: it still contains reverted code (revert not merged yet)"
  fi
done < <(git rev-list --first-parent --reverse "${LAST_TAG}..${head_sha}")

already=false
outcome=none
if [ "$rc" != 'null' ]; then
  outcome=selected
  if [ -n "$(printf '%s' "$rc" | jq -r .release_tag)" ]; then
    already=true
    outcome=already_promoted
  fi
fi

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc \
  --arg base "$LAST_TAG" \
  --arg last_release "$last_release" \
  --arg head_sha "$head_sha" \
  --arg outcome "$outcome" \
  --argjson already "$already" \
  --argjson rc "$rc" \
  --argjson tickets "$tickets" \
  --argjson untracked "$untracked" \
  --argjson reverted "$reverted" \
  --argjson staged "$staged" \
  --argjson blocked "$blocked" \
  --argjson commits "$commits" \
  '{base: $base, last_tag: $base, last_release_tag: $last_release, head_sha: $head_sha,
    outcome: $outcome, already_promoted: $already,
    rc: $rc, tickets: $tickets, untracked_commits: $untracked, reverted: $reverted,
    staged: $staged, blocked_by: $blocked, commits: $commits}'
