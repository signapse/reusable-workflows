#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# QA Failed revert PRs (SIG-2766, ADR 0001). git is real (a scratch repo with
# a bare "origin"); GitHub, Linear and Slack are stubbed:
#   $TMP/linear.json   id -> issue node (state, history)
#   $TMP/prs.json      commit subject -> [{title, head}] merged PRs
#   $TMP/open-prs      branch names that have an open PR
#   $TMP/pr-create-N   args of the Nth `gh pr create` (one per line)
#   $TMP/comments      Linear commentCreate variables, one JSON per line
#   $TMP/slack         Slack chat.postMessage bodies, one JSON per line
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/qa-failed-revert.sh"
NOW_EPOCH=1793000000

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/repo"
  export PATH="$TMP/stub:$PATH"
  echo '{}' > "$TMP/linear.json"
  echo '{}' > "$TMP/prs.json"
  : > "$TMP/open-prs"
  : > "$TMP/comments"
  : > "$TMP/slack"

  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
url=""; prev=""; body=""
for arg in "$@"; do
  [ "$prev" = "-d" ] && body="$arg"
  case "$arg" in https://*) url="$arg" ;; esac
  prev="$arg"
done
[ "$body" = "" ] && body=$(cat)
case "$url" in
  *slack.com*)
    echo "$body" >> "$TMP/slack"
    [ -f "$TMP/slack-down" ] && { echo '{"ok":false,"error":"channel_not_found"}'; exit 0; }
    echo '{"ok":true,"ts":"1.2"}'
    ;;
  *linear.app*)
    [ -f "$TMP/linear-down" ] && { printf 'boom\n500'; exit 0; }
    if echo "$body" | jq -e '.query | test("commentCreate")' > /dev/null; then
      [ -f "$TMP/comment-down" ] && { printf 'boom\n500'; exit 0; }
      echo "$body" | jq -c .variables >> "$TMP/comments"
      printf '{"data":{"commentCreate":{"success":true}}}\n200'
    elif echo "$body" | jq -e '.query | test("comments\\(")' > /dev/null; then
      # Has the ticket a comment containing variables.t? From $TMP/comments.
      t=$(echo "$body" | jq -r .variables.t)
      n=$(jq -s --arg t "$t" '[.[] | select(.body | contains($t))] | length' "$TMP/comments")
      printf '{"data":{"issue":{"comments":{"nodes":%s}}}}\n200' "$(jq -nc --argjson n "$n" '[range($n)] | map({id: "c"})')"
    else
      id=$(echo "$body" | jq -r '.variables.id')
      node=$(jq -c --arg id "$id" '.[$id] // null' "$TMP/linear.json")
      printf '{"data":{"issue":%s}}\n200' "$node"
    fi
    ;;
  *) echo "curl stub: unhandled $url" >&2; exit 1 ;;
esac
EOS

  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "api "*)
    url="$2"; filter="."
    [ "${3:-}" = --jq ] && filter="$4"
    sha=$(echo "$url" | sed -E 's#.*/commits/([0-9a-f]+)/pulls#\1#')
    subj=$(git log -1 --format=%s "$sha")
    jq -c --arg s "$subj" \
      '[(.[$s] // [])[] | {title, head: {ref: .head}, merged_at: "2026-11-01T00:00:00Z"}]' \
      "$TMP/prs.json" | jq -c "$filter"
    ;;
  "pr list")
    head=""; prev=""
    for a in "$@"; do [ "$prev" = --head ] && head="$a"; prev="$a"; done
    if grep -qxF "$head" "$TMP/open-prs"; then
      echo "https://github.com/o/r/pull/99"
    else
      echo ""
    fi
    ;;
  "pr create")
    [ -f "$TMP/gh-create-down" ] && { echo "gh: boom" >&2; exit 1; }
    n=$(( $(ls "$TMP" | grep -c '^pr-create-' || true) + 1 ))
    printf '%s\n' "$@" > "$TMP/pr-create-$n"
    echo "https://github.com/o/r/pull/$n"
    ;;
  *) echo "gh stub: unhandled $*" >&2; exit 1 ;;
esac
EOS
  chmod +x "$TMP/stub/curl" "$TMP/stub/gh"

  git init -q --bare -b main "$TMP/origin.git"
  cd "$TMP/repo" || return 1
  git init -q -b main
  git config user.email prodzilla@test
  git config user.name prodzilla
  git remote add origin "$TMP/origin.git"
  printf 'one\ntwo\nthree\n' > f
  git add f
  git commit -q -m "root"
  git tag 1.0.0

  export LINEAR_API_KEY=x
  export GH_TOKEN=x
  export GITHUB_REPOSITORY=o/r
  export NOW=$NOW_EPOCH
  export THRESHOLD_HOURS=24
  unset SLACK_CHANNEL SLACK_BOT_TOKEN
}

teardown() { rm -rf "$TMP"; }

run_revert() { "$SCRIPT" "$@" 2> "$TMP/stderr" < /dev/null; }
# change <file> <content> <message>: commit a file change on main.
change() { printf '%s\n' "$2" > "$1"; git add "$1"; git commit -q -m "$3"; }
sha_of() { git log --format='%H %s' | awk -v s="$1" '{h=$1; $1=""; if (substr($0,2)==s) {print h; exit}}'; }
# ticket <id> <state> [<hours-ago-it-entered-QA-Failed>]
ticket() {
  local id="$1" state="$2" ago="${3:-}"
  jq --arg id "$id" --arg st "$state" --arg ago "$ago" --argjson now "$NOW_EPOCH" '
    .[$id] = {id: "uuid-\($id)", identifier: $id, title: "t \($id)",
              url: "https://linear.app/x/\($id)", state: {name: $st},
              history: {pageInfo: {hasNextPage: false, endCursor: null},
                nodes: ([{createdAt: (($now - 999999) | todate), toState: {name: "In Review"}}]
                  + (if $ago == "" then [] else
                      [{createdAt: (($now - ($ago | tonumber) * 3600) | todate | sub("Z$"; ".123Z")),
                        toState: {name: "QA Failed"}}] end))}}' \
    "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
}
pr_for() {
  jq --arg s "$1" --arg t "$2" --arg h "$3" '.[$s] = [{title: $t, head: $h}]' "$TMP/prs.json" > "$TMP/p" \
    && mv "$TMP/p" "$TMP/prs.json"
}
remote_log() { git --git-dir="$TMP/origin.git" log --format=%s "$1"; }
created() { local f n=0; for f in "$TMP"/pr-create-*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }

@test "AC1: in QA Failed past the threshold -> revert PR opened and linked on the ticket" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0] | .id == "SIG-1" and .action == "opened"
    and .pr_url == "https://github.com/o/r/pull/1" and .age_hours == 25' > /dev/null
  [ "$(created)" -eq 1 ]
  grep -qxF -- "--title" "$TMP/pr-create-1"
  grep -qxF "Revert SIG-1: t SIG-1" "$TMP/pr-create-1"
  grep -qxF "prodzilla/revert-SIG-1" "$TMP/pr-create-1"
  ! grep -qxF -- "--draft" "$TMP/pr-create-1" || false
  grep -q "https://linear.app/x/SIG-1" "$TMP/pr-create-1"
  grep -q "stops the line" "$TMP/pr-create-1"
  # The branch reverts the commit; the checkout is left clean and detached.
  [ "$(remote_log prodzilla/revert-SIG-1 | head -n 1)" = 'Revert "feat(SIG-1): A"' ]
  [ "$(git --git-dir="$TMP/origin.git" show prodzilla/revert-SIG-1:f)" = "$(printf 'one\ntwo\nthree')" ]
  [ -z "$(git status --porcelain)" ]
  ! git show-ref -q --heads prodzilla/revert-SIG-1 || false
  # Linked on the ticket.
  jq -e 'select(.id == "uuid-SIG-1") | .body | test("https://github.com/o/r/pull/1")' "$TMP/comments" > /dev/null
}

@test "AC1: ticket found through its PR title and branch, merge commit reverted with -m 1" {
  git checkout -q -b feature
  change f "one-b" "wip"
  git checkout -q main
  git merge -q --no-ff feature -m "Merge pull request #5 from o/alex/sig-7-fix"
  pr_for "Merge pull request #5 from o/alex/sig-7-fix" "Fix the header" "alex/sig-7-fix"
  ticket SIG-7 "QA Failed" 30
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "opened"' > /dev/null
  [ "$(git --git-dir="$TMP/origin.git" show prodzilla/revert-SIG-7:f)" = "$(printf 'one\ntwo\nthree')" ]
}

@test "AC1: several commits are reverted newest first; other tickets' commits stay" {
  change f "one-1" "feat(SIG-1): first"
  change g "other" "feat(SIG-2): other ticket"
  change f "one-2" "feat(SIG-1): second"
  change h "chore" "chore: untracked"
  change f "one-3" "feat(SIG-1): third"
  ticket SIG-1 "QA Failed" 48
  ticket SIG-2 "On Dev · Ready for QA"
  run run_revert
  [ "$status" -eq 0 ]
  diff <(remote_log prodzilla/revert-SIG-1 | head -n 3) - <<'EOF'
Revert "feat(SIG-1): first"
Revert "feat(SIG-1): second"
Revert "feat(SIG-1): third"
EOF
  [ "$(git --git-dir="$TMP/origin.git" show prodzilla/revert-SIG-1:f)" = "$(printf 'one\ntwo\nthree')" ]
  [ "$(git --git-dir="$TMP/origin.git" show prodzilla/revert-SIG-1:g)" = "other" ]
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1"] and (.tickets[0].reverted | length) == 3' > /dev/null
  echo "$output" | jq -e '[.tickets[0].reverted[].subject] == ["feat(SIG-1): third","feat(SIG-1): second","feat(SIG-1): first"]' > /dev/null
}

@test "threshold not reached -> no PR, ticket reported as waiting" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 23
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "waiting"' > /dev/null
  [ "$(created)" -eq 0 ]
  [ -z "$(git --git-dir="$TMP/origin.git" branch --list 'prodzilla/*')" ]
  [ ! -s "$TMP/comments" ]
}

@test "threshold is configurable in fractions of an hour (QA tests with minutes)" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 0.1
  THRESHOLD_HOURS=0.05 run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "opened"' > /dev/null
  THRESHOLD_HOURS=abc run run_revert
  [ "$status" -ne 0 ]
  grep -q "THRESHOLD_HOURS must be" "$TMP/stderr"
}

@test "AC3: ticket that left QA Failed (QA re-passed it) -> no PR" {
  change f "one-a" "feat(SIG-1): A"
  # Entered QA Failed 30h ago, then moved on.
  ticket SIG-1 "On Dev · Ready for QA" 30
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets == []' > /dev/null
  [ "$(created)" -eq 0 ]
  [ ! -s "$TMP/comments" ]
}

@test "re-entering QA Failed restarts the clock" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 30
  jq '.["SIG-1"].history.nodes += [{createdAt: ((1793000000 - 3600) | todate), toState: {name: "QA Failed"}}]' \
    "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "waiting" and .tickets[0].age_hours == 1' > /dev/null
}

@test "AC4: conflict -> draft PR explaining it, Slack alert, ticket comment; checkout left clean" {
  change f "one-a" "feat(SIG-1): A"
  change f "one-b" "feat(SIG-2): B edits the same line"
  ticket SIG-1 "QA Failed" 25
  ticket SIG-2 "On Dev · Ready for QA"
  export SLACK_CHANNEL="#releases" SLACK_BOT_TOKEN=x
  run run_revert
  [ "$status" -eq 0 ]
  a=$(sha_of "feat(SIG-1): A")
  echo "$output" | jq -e --arg a "$a" '.tickets[0] | .action == "opened_draft_conflict"
    and .conflict.sha == $a and .conflict.files == ["f"] and .reverted == []' > /dev/null
  grep -qxF -- "--draft" "$TMP/pr-create-1"
  grep -q "Conflict: this revert is incomplete" "$TMP/pr-create-1"
  grep -q "git revert -m 1 $a" "$TMP/pr-create-1"
  [ "$(remote_log prodzilla/revert-SIG-1 | head -n 1)" = "Revert SIG-1: needs manual conflict resolution" ]
  jq -e '.channel == "#releases" and (.text | test("SIG-1.*conflict.*pull/1"))' "$TMP/slack" > /dev/null
  jq -e '.body | test("could not revert") and test("pull/1")' "$TMP/comments" > /dev/null
  [ -z "$(git status --porcelain)" ]
  [ ! -f .git/REVERT_HEAD ]
  [ "$(git rev-parse HEAD)" = "$(git rev-parse main)" ]
}

@test "AC4: conflict part-way keeps the newer reverts and stops at the conflicting commit" {
  change f "one-a" "feat(SIG-1): A"
  change f "one-b" "feat(SIG-2): B edits the same line"
  change g "g1" "feat(SIG-1): A2"
  ticket SIG-1 "QA Failed" 25
  ticket SIG-2 "On Dev · Ready for QA"
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0] | .action == "opened_draft_conflict" and ([.reverted[].subject] == ["feat(SIG-1): A2"])' > /dev/null
  [ "$(remote_log prodzilla/revert-SIG-1 | head -n 1)" = 'Revert "feat(SIG-1): A2"' ]
  # Nothing older is left to try, so the PR lists none (A conflicted itself).
  echo "$output" | jq -e '.tickets[0].not_attempted == []' > /dev/null
  # No Slack configured: the comment still explains it.
  [ ! -s "$TMP/slack" ]
  [ -s "$TMP/comments" ]
}

@test "AC4: a failing Slack alert fails the run instead of passing silently" {
  change f "one-a" "feat(SIG-1): A"
  change f "one-b" "feat(SIG-2): B"
  ticket SIG-1 "QA Failed" 25
  ticket SIG-2 "On Dev · Ready for QA"
  export SLACK_CHANNEL="#releases" SLACK_BOT_TOKEN=x
  touch "$TMP/slack-down"
  run run_revert
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.tickets[0] | .action == "failed" and (.error | test("Slack"))' > /dev/null
}

@test "AC5: an open revert PR exists -> no second PR" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 25
  echo "prodzilla/revert-SIG-1" > "$TMP/open-prs"
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0] | .action == "open_pr_exists" and .pr_url == "https://github.com/o/r/pull/99"' > /dev/null
  [ "$(created)" -eq 0 ]
  # The ticket did not carry the PR link (an earlier comment failed): posted
  # once, then never again.
  [ "$(jq -s '[.[] | select(.body | contains("pull/99"))] | length' "$TMP/comments")" -eq 1 ]
  run run_revert
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/comments" | tr -d ' ')" -eq 1 ]
}

@test "AC5: a failed ticket comment is retried on the next run" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 25
  touch "$TMP/comment-down"
  run run_revert
  [ "$status" -eq 1 ]
  [ "$(created)" -eq 1 ]
  rm "$TMP/comment-down"
  echo "prodzilla/revert-SIG-1" > "$TMP/open-prs"
  run run_revert
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/comments" | tr -d ' ')" -eq 1 ]
}

@test "AC5: second run after a PR was opened -> branch exists, nothing new" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  [ "$(created)" -eq 1 ]
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "branch_exists"' > /dev/null
  [ "$(created)" -eq 1 ]
  [ "$(wc -l < "$TMP/comments")" -eq 1 ]
}

@test "commits already reverted by a person are skipped and noted" {
  change f "one-a" "feat(SIG-1): A"
  a=$(sha_of "feat(SIG-1): A")
  change g "g1" "feat(SIG-1): A2"
  git revert --no-edit "$a" > /dev/null
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg a "$a" '.tickets[0] | .action == "opened"
    and ([.reverted[].subject] == ["feat(SIG-1): A2"])
    and (.skipped[0].sha == $a) and (.skipped[0].reason | test("already reverted by"))' > /dev/null
  grep -q "## Skipped" "$TMP/pr-create-1"
}

@test "AC4: older commits after a conflict are listed in the PR as not attempted" {
  change g "g0" "feat(SIG-1): A0"
  change f "one-a" "feat(SIG-1): A"
  change f "one-b" "feat(SIG-2): B edits the same line"
  ticket SIG-1 "QA Failed" 25
  ticket SIG-2 "On Dev · Ready for QA"
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0] | .action == "opened_draft_conflict"
    and .conflict.subject == "feat(SIG-1): A" and ([.not_attempted[].subject] == ["feat(SIG-1): A0"])' > /dev/null
  grep -q "## Not attempted" "$TMP/pr-create-1"
  grep -q "feat(SIG-1): A0" "$TMP/pr-create-1"
}

@test "a revert that was itself reverted does not count: the commit is reverted again" {
  change f "one-a" "feat(SIG-1): A"
  git revert --no-edit HEAD > /dev/null
  r=$(git rev-parse HEAD)
  # Older git (and GitHub's revert button) title a re-land 'Revert "Revert ..."'.
  git revert --no-commit HEAD > /dev/null
  git commit -q -m 'Revert "Revert "feat(SIG-1): A""' -m "This reverts commit $r."
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  # The re-land is ticket work: it is reverted (newest first), after which A
  # has nothing left to revert. A is not skipped as "already reverted".
  echo "$output" | jq -e '.tickets[0] | .action == "opened"
    and ([.reverted[].subject] == ["Revert \"Revert \"feat(SIG-1): A\"\""])
    and any(.skipped[]; .subject == "feat(SIG-1): A" and .reason == "nothing left to revert")' > /dev/null
  [ "$(git show origin/prodzilla/revert-SIG-1:f 2> /dev/null || git --git-dir="$TMP/origin.git" show prodzilla/revert-SIG-1:f)" = "$(printf 'one\ntwo\nthree')" ]
}

@test "the walk base the caller passes (the tag prod runs) reaches commits in already-tagged builds" {
  change f "one-a" "feat(SIG-1): A"
  git tag 1.1.0   # promoted to staging, failed: SIG-1 is in QA Failed
  change g "g1" "feat(SIG-2): B"
  ticket SIG-1 "QA Failed" 25
  ticket SIG-2 "On Dev · Ready for QA"
  run run_revert 1.0.0 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.last_tag == "1.0.0" and .tickets[0].id == "SIG-1" and .tickets[0].action == "opened"' > /dev/null
}

@test "every commit already reverted -> no PR, reported" {
  change f "one-a" "feat(SIG-1): A"
  git revert --no-edit HEAD > /dev/null
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "already_reverted"' > /dev/null
  [ "$(created)" -eq 0 ]
  [ -z "$(git --git-dir="$TMP/origin.git" branch --list 'prodzilla/*')" ]
}

@test "change undone by hand without a revert trailer -> skipped as nothing left to revert" {
  change f "one-a" "feat(SIG-1): A"
  printf 'one\ntwo\nthree\n' > f; git commit -q -am "fix: put it back"
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0] | .action == "already_reverted" and .skipped[0].reason == "nothing left to revert"' > /dev/null
}

@test "a merged Prodzilla revert is not treated as the ticket's work" {
  change f "one-a" "feat(SIG-1): A"
  git revert --no-edit HEAD > /dev/null
  git commit -q --amend -m "Revert SIG-1: t SIG-1" -m "This reverts commit $(sha_of "feat(SIG-1): A")."
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "already_reverted" and (.tickets[0].reverted == [])' > /dev/null
}

@test "commits shared with another ticket are flagged in the PR" {
  change f "one-a" "feat(SIG-1, SIG-3): A"
  ticket SIG-1 "QA Failed" 25
  ticket SIG-3 "On Dev · Ready for QA"
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].shared_with == ["SIG-3"]' > /dev/null
  grep -q "also carry SIG-3" "$TMP/pr-create-1"
}

@test "commits before the last Promotion tag are not reverted" {
  change f "one-a" "feat(SIG-1): A"
  git tag 1.1.0
  change g "g1" "feat(SIG-1): A2"
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.last_tag == "1.1.0" and ([.tickets[0].reverted[].subject] == ["feat(SIG-1): A2"])' > /dev/null
}

@test "Linear down -> the run fails and opens nothing" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 25
  touch "$TMP/linear-down"
  run run_revert
  [ "$status" -ne 0 ]
  [ "$(created)" -eq 0 ]
}

@test "a ref Linear does not know is skipped; later tickets still get their revert" {
  change f "one-a" "feat(SIG-0): typo'd ticket"
  change g "x" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 25
  run run_revert
  [ "$status" -eq 0 ]
  grep -q "SIG-0: not found in Linear" "$TMP/stderr"
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1"] and .tickets[0].action == "opened"' > /dev/null
  [ "$(created)" -eq 1 ]
}

@test "PR creation failure fails the run and is reported" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed" 25
  touch "$TMP/gh-create-down"
  run run_revert
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.tickets[0] | .action == "failed" and (.error | test("PR creation failed"))' > /dev/null
  [ -z "$(git status --porcelain)" ]
}

@test "in QA Failed with no history move into it -> no action, reported" {
  change f "one-a" "feat(SIG-1): A"
  ticket SIG-1 "QA Failed"
  run run_revert
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0].action == "no_history"' > /dev/null
  [ "$(created)" -eq 0 ]
}

@test "a re-land whose original revert is older than the walk base is reverted (selection blocks on it)" {
  change f "one-a" "feat(SIG-1): A"
  git revert --no-edit HEAD > /dev/null
  r=$(git rev-parse HEAD)
  git tag 1.1.0   # prod runs this
  git revert --no-commit HEAD > /dev/null
  git commit -q -m 'Revert "Revert "feat(SIG-1): A""' -m "This reverts commit $r."
  ticket SIG-1 "QA Failed" 25
  run run_revert 1.1.0 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickets[0] | .id == "SIG-1" and .action == "opened"
    and ([.reverted[].subject] == ["Revert \"Revert \"feat(SIG-1): A\"\""])' > /dev/null
}
