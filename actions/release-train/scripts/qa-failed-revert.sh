#!/usr/bin/env bash
# shellcheck disable=SC2016 # $names in single quotes are jq and GraphQL variables.
# qa-failed-revert.sh [<last-tag>] [<head-ref>]
#
# Opens a revert PR for every ticket that has sat in QA Failed for at least
# THRESHOLD_HOURS (SIG-2766, ADR 0001): a QA Failed ticket stops its repo's
# line, and the revert lets everyone else's QA Passed work ship.
#
# Stateless; everything is re-read from git, GitHub and Linear on every run, so
# the caller runs it hourly.
#
#   1. Walk main's first-parent commits in <last-tag>..<head-ref>. The caller
#      passes the tag prod runs (selection-base.sh), the same base the
#      Release Candidate walk uses: a ticket that failed staging sits in an
#      already-tagged commit, and must still be reverted (review fix). A
#      commit's tickets are found the way release-candidate.sh finds them:
#      <TEAM>-<n> refs in the commits it brought in plus the title and head
#      branch of its merged PR(s). Revert commits (lib/revert.sh, subject
#      "Revert ...", or a PR from a revert-* or prodzilla/revert-* branch)
#      are not ticket work and are never reverted.
#   2. Read each ticket from Linear. Only tickets currently in QA_FAILED_STATE
#      count; one that left the state (QA re-passed it) is never acted on. The
#      time it entered the state is the newest issue-history entry moving it
#      there. It is due once that is at least THRESHOLD_HOURS ago.
#   3. Dedupe: skip when an open PR from prodzilla/revert-<ticket> exists (and
#      post the PR link on the ticket if an earlier run failed to), or the
#      branch exists on the remote.
#   4. On branch prodzilla/revert-<ticket> from <head-ref>, git revert the
#      ticket's commits newest first (merge commits with -m 1). A commit is
#      skipped as already reverted when a later revert of it is still live
#      (lib/revert.sh: a revert that was itself reverted does not count), or
#      when the revert stages nothing.
#   5. Push and open "Revert <ticket>: <title>", then comment the PR link on
#      the ticket.
#
# Conflict: the revert is aborted at the conflicting commit. The commits
# reverted before it stay on the branch (an empty marker commit when there are
# none) and a DRAFT PR explains the conflict, lists the older commits still to
# revert, and how to finish. The branch then
# dedupes later runs, so the Linear comment and the Slack alert (when
# SLACK_CHANNEL is set) go out once.
#
# All tickets are commits already reverted: nothing is opened; the run says so.
#
# Output (stdout, one compact JSON object; logs go to stderr):
#   {last_tag, head_sha, threshold_hours,
#    tickets: [{id, title, url, entered_at, age_hours, action, branch,
#               pr_url, reverted: [{sha, subject}], skipped: [{sha, subject,
#               reason}], conflict: {sha, subject, files} | null,
#               not_attempted: [{sha, subject}] (older commits after a conflict),
#               shared_with: [ids], error}]}
#   action: waiting | open_pr_exists | branch_exists | already_reverted |
#           opened | opened_draft_conflict | no_history | failed
# Exits 1 after processing every ticket when any ticket's action is failed.
#
# Env:
#   GITHUB_REPOSITORY    owner/repo (required)
#   GH_TOKEN             Prodzilla app token: contents:write, pull_requests:write.
#                        Never GITHUB_TOKEN: its PRs do not trigger CI.
#   LINEAR_API_KEY       required
#   LINEAR_TEAM_KEY      ticket prefix (default SIG)
#   QA_FAILED_STATE      default "QA Failed"
#   THRESHOLD_HOURS      default 24; decimals allowed (0.1 = 6 minutes)
#   BRANCH               base branch of the revert PR (default main)
#   RELEASE_TAG_PATTERN  ERE for Promotion tags (default ^v?[0-9]+\.[0-9]+\.[0-9]+$)
#   REMOTE               git remote to push to (default origin)
#   SLACK_CHANNEL        optional; conflict alerts go here (needs SLACK_BOT_TOKEN)
#   RUN_URL              optional; linked from PR bodies and comments
#   NOW                  optional epoch seconds (tests)
#
# The working tree must be a clean checkout with history and tags, and git
# must have a committer identity. The script leaves HEAD detached at <head-ref>.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"
# shellcheck source=SCRIPTDIR/../lib/slack.sh
source "$(dirname "$0")/../lib/slack.sh"
# shellcheck source=SCRIPTDIR/../lib/release-tag.sh
source "$(dirname "$0")/../lib/release-tag.sh"
# shellcheck source=SCRIPTDIR/../lib/revert.sh
source "$(dirname "$0")/../lib/revert.sh"

[ $# -le 2 ] || die "usage: qa-failed-revert.sh [<last-tag>] [<head-ref>]"
LAST_TAG="${1:-}"
HEAD_REF="${2:-HEAD}"

need git
need gh
need jq
need curl

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
: "${LINEAR_API_KEY:?LINEAR_API_KEY not set}"
: "${GH_TOKEN:?GH_TOKEN not set (the Prodzilla app token)}"
QA_FAILED_STATE="${QA_FAILED_STATE:-QA Failed}"
THRESHOLD_HOURS="${THRESHOLD_HOURS:-24}"
BRANCH="${BRANCH:-main}"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-^v?[0-9]+\.[0-9]+\.[0-9]+$}"
REMOTE="${REMOTE:-origin}"
SLACK_CHANNEL="${SLACK_CHANNEL:-}"
RUN_URL="${RUN_URL:-}"
NOW="${NOW:-$(date +%s)}"
BRANCH_PREFIX="prodzilla/revert-"
HERE="$(dirname "$0")"

[[ "$THRESHOLD_HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || die "THRESHOLD_HOURS must be a non-negative number of hours (got '$THRESHOLD_HOURS')"
[[ "$NOW" =~ ^[0-9]+$ ]] || die "NOW must be epoch seconds (got '$NOW')"
if [ -n "$SLACK_CHANNEL" ] && [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  die "SLACK_CHANNEL is set but SLACK_BOT_TOKEN is not"
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes"

head_sha=$(git rev-parse --verify "${HEAD_REF}^{commit}") || die "unknown ref: $HEAD_REF"
if [ -z "$LAST_TAG" ]; then
  LAST_TAG=$(last_release_tag "$head_sha" "$RELEASE_TAG_PATTERN")
  [ -n "$LAST_TAG" ] || die "no tag matching $RELEASE_TAG_PATTERN on $HEAD_REF's first-parent history; seed one (git tag 0.0.0 <sha>)"
fi
git rev-parse --verify -q "${LAST_TAG}^{commit}" > /dev/null || die "unknown tag: $LAST_TAG"
git merge-base --is-ancestor "$LAST_TAG" "$head_sha" || die "walk base $LAST_TAG is not in $HEAD_REF's history"
log "walk base: $LAST_TAG; threshold ${THRESHOLD_HOURS}h"
# Live reverts in the range (a revert that was itself reverted does not count).
units=$(revert_units "$LAST_TAG" "$head_sha")

# merged_prs <sha>: [{title, head}] of the merged PRs GitHub associates with <sha>.
merged_prs() {
  gh api "repos/${GITHUB_REPOSITORY}/commits/$1/pulls" \
    --jq '[.[] | select(.merged_at != null) | {title, head: .head.ref}]' \
    || die "cannot read PRs for ${1:0:7} (token needs pull_requests:read)"
}

# --- 1. Walk the commits since the last Promotion --------------------------
commits='[]'
while IFS= read -r sha; do
  [ -z "$sha" ] && continue
  subject=$(git log -1 --format=%s "$sha")
  parents=$(git log -1 --format=%P "$sha" | wc -w | tr -d ' ')
  prs=$(merged_prs "$sha")
  refs=$(printf '%s' "$prs" | jq -r '.[] | .title, .head' | "$HERE/ticket-extractor.sh" "${sha}^1" "$sha")
  # lib/revert.sh decides whenever the commit carries git's "This reverts
  # commit" line: then a revert of a revert (a re-land) is ticket work even
  # though its subject starts with Revert (review fix: selection blocks on
  # it, so this run must be able to revert it). The subject and branch
  # heuristics only cover reverts without that line.
  revert=false
  if git log -1 --format=%B "$sha" | grep -q 'This reverts commit [0-9a-f]'; then
    [ "$(jq -r --arg s "$sha" '.[$s].kind // "normal"' <<< "$units")" = revert ] && revert=true
  elif [[ "$subject" == Revert* ]] \
    || printf '%s' "$prs" | jq -e 'any(.[]; .head | test("^(prodzilla/)?revert-"))' > /dev/null; then
    revert=true
  fi
  commits=$(jq -nc --argjson a "$commits" --arg sha "$sha" --arg s "$subject" \
    --argjson merge "$([ "$parents" -gt 1 ] && echo true || echo false)" \
    --argjson revert "$revert" --argjson t "$refs" \
    '$a + [{sha: $sha, subject: $s, merge: $merge, revert: $revert, tickets: $t}]')
done < <(git rev-list --first-parent --reverse "${LAST_TAG}..${head_sha}")

ticket_ids=$(printf '%s' "$commits" | jq -r '[.[] | select(.revert | not) | .tickets[]] | unique | .[]')

# --- 2. Linear ------------------------------------------------------------
# linear_issue <id>: {uuid, id, title, url, state, entered_at} where entered_at
# is the newest time the issue moved into QA_FAILED_STATE (null if never).
# Any Linear failure fails the run: a revert must never be opened, or skipped,
# on a guess.
linear_issue() {
  local id="$1" after='' resp issue entered='' page
  local q='query($id:String!,$after:String){issue(id:$id){id identifier title url state{name}
    history(first:100,after:$after){nodes{createdAt toState{name}} pageInfo{hasNextPage endCursor}}}}'
  while :; do
    resp=$(linear_query "$q" "$(jq -nc --arg id "$id" --arg a "$after" \
      '{id: $id, after: (if $a == "" then null else $a end)}')") || die "Linear query for $id failed"
    printf '%s' "$resp" | jq -e 'type == "object"' > /dev/null 2>&1 \
      || die "Linear returned an unparsable reply for $id: $resp"
    issue=$(printf '%s' "$resp" | jq -c '.data.issue // empty')
    if [ -z "$issue" ] && [ -z "$after" ]; then
      # issue: null is how Linear answers an unknown identifier (a typo, a
      # deleted ticket, a branch like alex/sig-2024-cleanup). It can't be in
      # QA Failed, so it must not stop the other tickets' reverts.
      echo null
      return 0
    fi
    printf '%s' "$resp" | jq -e '(.errors // []) | length == 0' > /dev/null \
      || die "Linear returned errors for $id: $(printf '%s' "$resp" | jq -c .errors)"
    [ -n "$issue" ] || die "Linear lost issue $id while paging its history"
    printf '%s' "$issue" | jq -e '(.identifier | type) == "string" and (.state.name | type) == "string"
        and (.history.nodes | type) == "array"' > /dev/null \
      || die "Linear reply for $id lacks identifier, state or history: $issue"
    page=$(printf '%s' "$issue" | jq -r --arg s "$QA_FAILED_STATE" \
      '[.history.nodes[] | select(.toState.name? == $s) | .createdAt] | max // ""')
    if [ -n "$page" ] && { [ -z "$entered" ] || [[ "$page" > "$entered" ]]; }; then entered="$page"; fi
    [ "$(printf '%s' "$issue" | jq -r '.history.pageInfo.hasNextPage // false')" = true ] || break
    after=$(printf '%s' "$issue" | jq -r '.history.pageInfo.endCursor')
  done
  printf '%s' "$issue" | jq -c --arg e "$entered" \
    '{uuid: .id, id: .identifier, title, url, state: .state.name,
      entered_at: (if $e == "" then null else $e end)}'
}

# linear_has_comment <uuid> <text>: prints true/false; fails on a Linear error.
linear_has_comment() {
  local resp
  resp=$(linear_query 'query($id:String!,$t:String!){issue(id:$id){comments(first:50,filter:{body:{contains:$t}}){nodes{id}}}}' \
    "$(jq -nc --arg id "$1" --arg t "$2" '{id: $id, t: $t}')") || return 1
  printf '%s' "$resp" | jq -e '(.errors // []) | length == 0' > /dev/null 2>&1 || return 1
  printf '%s' "$resp" | jq -r '(.data.issue.comments.nodes // []) | length > 0'
}

linear_comment() {
  local uuid="$1" body resp
  body="$2"
  resp=$(linear_query 'mutation($id:String!,$body:String!){commentCreate(input:{issueId:$id,body:$body}){success}}' \
    "$(jq -nc --arg id "$uuid" --arg b "$body" '{id: $id, body: $b}')") || return 1
  printf '%s' "$resp" | jq -e '.data.commentCreate.success == true' > /dev/null 2>&1 || {
    log "Linear commentCreate failed: $resp"
    return 1
  }
}

slack_alert() {
  local resp
  resp=$(jq -nc --arg c "$SLACK_CHANNEL" --arg t "$1" '{channel: $c, text: $t}' | slack_post) || return 1
  printf '%s' "$resp" | jq -e '.ok == true' > /dev/null 2>&1 || {
    log "Slack chat.postMessage failed: $resp"
    return 1
  }
}

# --- 3-5. Per ticket --------------------------------------------------------
results='[]'
failed=0
repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"
threshold_s=$(awk -v h="$THRESHOLD_HOURS" 'BEGIN { printf "%d", h * 3600 }')

# Restore a clean, detached checkout whatever state a revert left behind.
reset_checkout() {
  git revert --abort > /dev/null 2>&1 || git revert --quit > /dev/null 2>&1 || true
  git reset -q --hard
  git checkout -q --detach "$head_sha"
}

# set_r <jq args...>: update the current ticket's result r. finish: record it.
set_r() { r=$(printf '%s' "$r" | jq -c "$@"); }
finish() { results=$(jq -nc --argjson a "$results" --argjson r "$r" '$a + [$r]'); }

# The lists are read on fds 3 and 4 so nothing in the loop bodies (gh, git)
# can consume them from stdin.
while IFS= read -r id <&3; do
  [ -z "$id" ] && continue
  t=$(linear_issue "$id")
  if [ "$t" = null ]; then
    log "$id: not found in Linear; nothing to do"
    continue
  fi
  state=$(printf '%s' "$t" | jq -r .state)
  if [ "$state" != "$QA_FAILED_STATE" ]; then
    log "$id: $state, not $QA_FAILED_STATE; nothing to do"
    continue
  fi
  title=$(printf '%s' "$t" | jq -r '.title // ""')
  url=$(printf '%s' "$t" | jq -r '.url // ""')
  uuid=$(printf '%s' "$t" | jq -r .uuid)
  entered=$(printf '%s' "$t" | jq -r '.entered_at // ""')
  br="${BRANCH_PREFIX}${id}"
  r=$(printf '%s' "$t" | jq -c --arg br "$br" '{id, title, url, entered_at, age_hours: null,
    action: "", branch: $br, pr_url: null, reverted: [], skipped: [], conflict: null,
    not_attempted: [], shared_with: [], error: null}')

  if [ -z "$entered" ]; then
    # In QA Failed with no history entry moving it there (created in the
    # state?). Never guess the clock; say so in the run summary.
    log "WARNING: $id is in $QA_FAILED_STATE but its history has no move into it; not acting"
    set_r '.action = "no_history"'
    finish
    continue
  fi
  entered_s=$(jq -nr --arg e "$entered" '$e | sub("\\.[0-9]+"; "") | fromdateiso8601')
  age_s=$((NOW - entered_s))
  set_r --argjson a "$age_s" '.age_hours = (($a / 36) | floor) / 100'
  if [ "$age_s" -lt "$threshold_s" ]; then
    log "$id: in $QA_FAILED_STATE for ${age_s}s (< ${threshold_s}s); waiting"
    set_r '.action = "waiting"'
    finish
    continue
  fi

  existing=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$br" --state open --json url --jq '.[0].url // ""') \
    || die "cannot list PRs for $br"
  if [ -n "$existing" ]; then
    log "$id: revert PR already open: $existing"
    set_r --arg u "$existing" '.action = "open_pr_exists" | .pr_url = $u'
    # An earlier run may have opened the PR and then failed to comment on the
    # ticket: post the link now if the ticket does not carry it yet.
    if ! has=$(linear_has_comment "$uuid" "$existing"); then
      set_r '.action = "failed" | .error = "could not read the ticket comments"'
      failed=1
    elif [ "$has" != true ]; then
      if linear_comment "$uuid" "Prodzilla opened a revert PR for this ticket's commits: $existing

This ticket has been in $QA_FAILED_STATE for over ${THRESHOLD_HOURS}h, which stops the line for ${GITHUB_REPOSITORY}. Merge the revert to unblock it, or close it if the fix lands and QA re-passes the ticket."; then
        log "$id: posted the PR link the earlier run did not"
      else
        set_r '.action = "failed" | .error = "Linear comment failed"'
        failed=1
      fi
    fi
    finish
    continue
  fi
  remote_branch=$(git ls-remote --heads "$REMOTE" "refs/heads/$br") || die "cannot list $REMOTE branches"
  if [ -n "$remote_branch" ]; then
    log "WARNING: $id: branch $br exists with no open PR; open one from it or delete it to let Prodzilla retry"
    set_r '.action = "branch_exists"'
    finish
    continue
  fi

  # Newest first, so each revert applies on top of everything after it.
  mine=$(printf '%s' "$commits" | jq -c --arg id "$id" \
    '[.[] | select((.revert | not) and (.tickets | index($id)))] | reverse')
  set_r --argjson m "$mine" --arg id "$id" '.shared_with = ([$m[].tickets[] | select(. != $id)] | unique)'

  git checkout -q -B "$br" "$head_sha"
  while IFS= read -r c <&4; do
    sha=$(printf '%s' "$c" | jq -r .sha)
    subj=$(printf '%s' "$c" | jq -r .subject)
    # Only a live revert counts: if the revert was reverted, the code is back.
    by=$(jq -r --arg s "$sha" 'if .[$s].kind == "reverted" then (.[$s].reverted_by | map(.[0:7]) | join(", ")) else "" end' <<< "$units")
    if [ -n "$by" ]; then
      log "$id: ${sha:0:7} already reverted by $by; skipping"
      set_r --arg sha "$sha" --arg s "$subj" --arg why "already reverted by $by" \
        '.skipped += [{sha: $sha, subject: $s, reason: $why}]'
      continue
    fi
    args=(--no-commit)
    [ "$(printf '%s' "$c" | jq -r .merge)" = true ] && args+=(-m 1)
    if git revert "${args[@]}" "$sha" > /dev/null 2>&1; then
      if git diff --cached --quiet; then
        log "$id: reverting ${sha:0:7} changes nothing (undone by hand?); skipping"
        git revert --quit > /dev/null 2>&1 || true
        git reset -q --hard
        set_r --arg sha "$sha" --arg s "$subj" \
          '.skipped += [{sha: $sha, subject: $s, reason: "nothing left to revert"}]'
        continue
      fi
      git commit -q --no-edit
      set_r --arg sha "$sha" --arg s "$subj" '.reverted += [{sha: $sha, subject: $s}]'
    else
      files=$(git diff --name-only --diff-filter=U | jq -R . | jq -sc .)
      log "$id: reverting ${sha:0:7} conflicts in $(printf '%s' "$files" | jq -r 'join(", ")')"
      git revert --abort > /dev/null 2>&1 || true
      git reset -q --hard
      # The older commits after it are not attempted; the PR lists them.
      set_r --arg sha "$sha" --arg s "$subj" --argjson f "$files" --argjson m "$mine" \
        '([$m[].sha] | index($sha)) as $i
         | .conflict = {sha: $sha, subject: $s, files: $f}
         | .not_attempted = [$m[$i + 1:][] | {sha, subject}]'
      break
    fi
  done 4< <(printf '%s' "$mine" | jq -c '.[]')

  conflict=$(printf '%s' "$r" | jq -c .conflict)
  n_reverted=$(printf '%s' "$r" | jq '.reverted | length')
  if [ "$conflict" = null ] && [ "$n_reverted" -eq 0 ]; then
    log "$id: every commit is already reverted; no PR"
    set_r '.action = "already_reverted"'
    reset_checkout
    git branch -q -D "$br"
    finish
    continue
  fi
  if [ "$conflict" != null ] && [ "$n_reverted" -eq 0 ]; then
    # GitHub cannot open a PR with no commits; the marker carries the branch.
    git commit -q --allow-empty -m "Revert ${id}: needs manual conflict resolution" \
      -m "Prodzilla could not revert $(printf '%s' "$conflict" | jq -r .sha) cleanly; see the PR description."
  fi

  # PR body.
  body=$(printf '%s' "$r" | jq -r \
    --arg state "$QA_FAILED_STATE" --arg th "$THRESHOLD_HOURS" --arg base "$BRANCH" \
    --arg tag "$LAST_TAG" --arg run "$RUN_URL" --arg repo "$repo_url" '
    def c: "- \(.sha[0:7]) \(.subject)";
    "## Why\n\n"
    + "[\(.id)](\(.url)) (\(.title)) has been in **\($state)** since \(.entered_at) "
    + "(\(.age_hours)h; the limit is \($th)h). A \($state) ticket stops the line for this repo "
    + "(ADR 0001): the release train cannot form a Release Candidate past its commits. "
    + "Reverting them lets the QA Passed work merged after it be promoted while the fix is made.\n\n"
    + (if .conflict then
        "## Conflict: this revert is incomplete\n\n"
        + "Reverting \(.conflict.sha[0:7]) (\(.conflict.subject)) conflicts in:\n\n"
        + ([.conflict.files[] | "- `\(.)`"] | join("\n"))
        + "\n\nThis PR is a draft. To finish it, on this branch run\n\n```\n"
        + "git revert -m 1 \(.conflict.sha)   # drop -m 1 if it is not a merge commit\n```\n\n"
        + "then resolve the conflicts, revert the ticket'"'"'s older commits listed under "
        + "**Not attempted** the same way (newest first), push, and mark the PR ready.\n\n"
        + "## Not attempted (older, still to revert)\n\n"
        + (if (.not_attempted | length) > 0 then ([.not_attempted[] | c] | join("\n")) else "- none" end) + "\n\n"
      else "" end)
    + "## Reverted commits (newest first)\n\n"
    + (if (.reverted | length) > 0 then ([.reverted[] | c] | join("\n")) else "- none" end) + "\n"
    + (if (.skipped | length) > 0 then
        "\n## Skipped\n\n" + ([.skipped[] | "\(c) (\(.reason))"] | join("\n")) + "\n" else "" end)
    + (if (.shared_with | length) > 0 then
        "\n**Warning:** some of these commits also carry \(.shared_with | join(", ")). "
        + "Merging this PR reverts that work too.\n" else "" end)
    + "\n## What next\n\n"
    + "- Review and merge this PR to unblock the line. Re-land the fix as a new PR.\n"
    + "- If the ticket is fixed forward and QA re-passes it, close this PR and delete the branch.\n"
    + "- While the branch `\(.branch)` exists, Prodzilla opens no other revert PR for \(.id).\n\n"
    + "Commits considered: first-parent commits on `\($base)` since `\($tag)` that reference \(.id)."
    + (if $run != "" then "\n\nOpened by Prodzilla ([run](\($run)))." else "\n\nOpened by Prodzilla." end)')
  pr_title="Revert ${id}: ${title}"
  draft=()
  [ "$conflict" != null ] && draft=(--draft)

  if ! git push -q "$REMOTE" "HEAD:refs/heads/$br"; then
    log "ERROR: $id: push of $br failed (a revert touching .github/workflows needs workflows:write)"
    set_r '.action = "failed" | .error = "push failed"'
    failed=1
  elif ! pr_url=$(gh pr create --repo "$GITHUB_REPOSITORY" --base "$BRANCH" --head "$br" \
      --title "$pr_title" --body "$body" "${draft[@]+"${draft[@]}"}"); then
    log "ERROR: $id: gh pr create failed; branch $br is pushed"
    set_r '.action = "failed" | .error = "PR creation failed; branch pushed without a PR"'
    failed=1
  else
    pr_url=$(printf '%s' "$pr_url" | tail -n 1)
    log "$id: opened $pr_url"
    if [ "$conflict" = null ]; then
      set_r --arg u "$pr_url" '.action = "opened" | .pr_url = $u'
      comment="Prodzilla opened a revert PR for this ticket's commits: $pr_url

This ticket has been in $QA_FAILED_STATE for over ${THRESHOLD_HOURS}h, which stops the line for ${GITHUB_REPOSITORY}. Merge the revert to unblock it, or close it if the fix lands and QA re-passes the ticket."
    else
      set_r --arg u "$pr_url" '.action = "opened_draft_conflict" | .pr_url = $u'
      csha=$(printf '%s' "$conflict" | jq -r '.sha[0:7]')
      cfiles=$(printf '%s' "$conflict" | jq -r '.files | join(", ")')
      comment="Prodzilla could not revert this ticket's commits cleanly: reverting $csha conflicts in $cfiles. It opened a draft PR with what did revert and the steps to finish: $pr_url

This ticket has been in $QA_FAILED_STATE for over ${THRESHOLD_HOURS}h, which stops the line for ${GITHUB_REPOSITORY}."
      if [ -n "$SLACK_CHANNEL" ]; then
        if ! slack_alert "Revert of ${id} in ${GITHUB_REPOSITORY} hit a conflict: reverting ${csha} conflicts in ${cfiles}. Draft PR: ${pr_url} Ticket: ${url}"; then
          set_r '.action = "failed" | .error = "Slack alert failed"'
          failed=1
        fi
      fi
    fi
    if ! linear_comment "$uuid" "$comment"; then
      log "ERROR: $id: could not comment on the ticket"
      set_r '.action = "failed" | .error = ((.error // "") + (if .error then "; " else "" end) + "Linear comment failed")'
      failed=1
    fi
  fi
  reset_checkout
  git branch -q -D "$br"
  finish
done 3<<< "$ticket_ids"

jq -nc --arg tag "$LAST_TAG" --arg head "$head_sha" --arg th "$THRESHOLD_HOURS" --argjson t "$results" \
  '{last_tag: $tag, head_sha: $head, threshold_hours: ($th | tonumber), tickets: $t}'
exit "$failed"
