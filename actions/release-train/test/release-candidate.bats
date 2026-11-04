#!/usr/bin/env bats
# Release Candidate selection (SIG-2761, ADR 0001). Linear and GitHub are
# stubbed: tickets come from $TMP/linear.json (id -> issue node), builds from
# $TMP/builds.json (commit subject -> main-push run_number) and PRs from
# $TMP/prs.json (commit subject -> [{title, head}]).
load 'helpers/load'
bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/release-candidate.sh"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/repo"
  export PATH="$TMP/stub:$PATH"
  echo '{}' > "$TMP/linear.json"
  echo '{}' > "$TMP/builds.json"
  echo '{}' > "$TMP/prs.json"
  : > "$TMP/linear-calls"

  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
prev=""; body=""
for arg in "$@"; do
  [ "$prev" = "-d" ] && body="$arg"
  prev="$arg"
done
[ -f "$TMP/linear-down" ] && { printf 'boom\n500'; exit 0; }
id=$(echo "$body" | jq -r '.variables.id')
echo "$id" >> "$TMP/linear-calls"
[ -f "$TMP/raw-$id" ] && { printf '%s\n200' "$(cat "$TMP/raw-$id")"; exit 0; }
node=$(jq -c --arg id "$id" '.[$id] // null' "$TMP/linear.json")
printf '{"data":{"issue":%s}}\n200' "$node"
EOS

  # gh api <url> --jq <filter>: resolves the sha in the URL to its commit
  # subject in the scratch repo, then applies the caller's filter for real.
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "gh stub: unhandled $*" >&2; exit 1; }
url="$2"; filter="."
[ "${3:-}" = --jq ] && filter="$4"
case "$url" in
  *"/actions/workflows/main-push.yml/runs?"*)
    sha=$(echo "$url" | sed -E 's/.*head_sha=([0-9a-f]+).*/\1/')
    subj=$(git log -1 --format=%s "$sha")
    jq -c --arg s "$subj" --arg sha "$sha" \
      '{workflow_runs: (if has($s) then [{run_number: .[$s], event: "push", head_sha: $sha,
         html_url: "https://github.com/o/r/actions/runs/\(.[$s])"}] else [] end)}' \
      "$TMP/builds.json" | jq -r "$filter"
    ;;
  *"/commits/"*"/pulls")
    sha=$(echo "$url" | sed -E 's#.*/commits/([0-9a-f]+)/pulls#\1#')
    subj=$(git log -1 --format=%s "$sha")
    jq -c --arg s "$subj" \
      '[(.[$s] // [])[] | {title, head: {ref: .head}, merged_at: "2026-11-01T00:00:00Z"}]' \
      "$TMP/prs.json" | jq -r "$filter"
    ;;
  *) echo "gh stub: unhandled url $url" >&2; exit 1 ;;
esac
EOS
  chmod +x "$TMP/stub/curl" "$TMP/stub/gh"

  cd "$TMP/repo" || return 1
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  git commit -q --allow-empty -m "root"
  git tag 1.0.0

  export LINEAR_API_KEY=x
  export GH_TOKEN=x
  export GITHUB_REPOSITORY=o/r
}

teardown() { rm -rf "$TMP"; }

# Logs go to stderr; keep them out of $output so it stays JSON.
select_rc() { "$SCRIPT" "$@" 2> "$TMP/stderr"; }
commit() { git commit -q --allow-empty -m "$1"; }
sha_of() { git log --format='%H %s' | awk -v s="$1" '{h=$1; $1=""; if (substr($0,2)==s) {print h; exit}}'; }
built() {
  jq --arg s "$1" --argjson n "$2" '.[$s] = $n' "$TMP/builds.json" > "$TMP/b" && mv "$TMP/b" "$TMP/builds.json"
}
# ticket <id> <state> [label...]
ticket() {
  local id="$1" state="$2"; shift 2
  local labels
  labels=$(printf '%s\n' "$@" | jq -R 'select(. != "") | {name: .}' | jq -s .)
  jq --arg id "$id" --arg st "$state" --argjson l "$labels" \
    '.[$id] = {identifier: $id, title: "t \($id)", url: "https://linear.app/x/\($id)",
               state: {name: $st}, labels: {nodes: $l}}' \
    "$TMP/linear.json" > "$TMP/l" && mv "$TMP/l" "$TMP/linear.json"
}
pr() {
  jq --arg s "$1" --arg t "$2" --arg h "$3" '.[$s] = [{title: $t, head: $h}]' "$TMP/prs.json" > "$TMP/p" \
    && mv "$TMP/p" "$TMP/prs.json"
}
# A then B, each its own build.
a_then_b() {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 12
}

@test "AC1: A passed, B not passed -> the build with A and not B" {
  a_then_b
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed" Improvement
  ticket SIG-2 "On Dev · Ready for QA" Improvement
  run select_rc
  [ "$status" -eq 0 ]
  a=$(sha_of "feat(SIG-1): A")
  echo "$output" | jq -e --arg a "$a" '.outcome == "selected" and .rc.sha == $a' > /dev/null
  echo "$output" | jq -e --arg a "$a" '.rc.image_tag == "main-11-\($a)"' > /dev/null
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1"]' > /dev/null
  echo "$output" | jq -e '.blocked_by.id == "SIG-2" and (.blocked_by.reason | test("no QA Passed"))' > /dev/null
}

@test "AC2: A and B both passed -> the newest build containing both" {
  a_then_b
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  b=$(sha_of "feat(SIG-2): B")
  echo "$output" | jq -e --arg b "$b" '.rc.sha == $b and .rc.image_tag == "main-12-\($b)"' > /dev/null
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1","SIG-2"]' > /dev/null
  echo "$output" | jq -e '.blocked_by == null' > /dev/null
}

@test "AC3: A in QA Failed stops the line -> no build past its merge" {
  a_then_b
  # QA Failed wins even if the QA Passed label was not removed yet.
  ticket SIG-1 "QA Failed" "QA Passed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "none" and .rc == null and .tickets == []' > /dev/null
  echo "$output" | jq -e '.blocked_by.id == "SIG-1" and .blocked_by.reason == "in QA Failed"' > /dev/null
  echo "$output" | jq -e --arg a "$(sha_of "feat(SIG-1): A")" '.blocked_by.sha == $a' > /dev/null
}

@test "AC3: QA Failed in the middle -> the build before it, nothing after" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  commit "feat(SIG-3): C"; built "feat(SIG-3): C" 12
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 13
  ticket SIG-1 "On Staging" "QA Passed"
  ticket SIG-3 "QA Failed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg a "$(sha_of "feat(SIG-1): A")" '.rc.sha == $a' > /dev/null
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1"] and .blocked_by.id == "SIG-3"' > /dev/null
  # The walk stopped: SIG-2 was never even looked up.
  run ! grep -qx SIG-2 "$TMP/linear-calls"
}

@test "AC4: a commit with no ticket never blocks and is listed as untracked" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  commit "chore(deps): bump lodash"; built "chore(deps): bump lodash" 12
  pr "chore(deps): bump lodash" "chore(deps): bump lodash" "dependabot/npm_and_yarn/lodash-4.17.21"
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  d=$(sha_of "chore(deps): bump lodash")
  echo "$output" | jq -e --arg d "$d" '.rc.sha == $d and .blocked_by == null' > /dev/null
  echo "$output" | jq -e --arg d "$d" '.untracked_commits == [{sha: $d, subject: "chore(deps): bump lodash"}]' > /dev/null
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1"]' > /dev/null
}

@test "AC4: an untracked commit past the block is not listed (it does not ride along)" {
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 11
  commit "chore: tidy"; built "chore: tidy" 12
  ticket SIG-2 "On Dev · Ready for QA"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.rc == null and .untracked_commits == [] and .blocked_by.id == "SIG-2"' > /dev/null
}

@test "AC5: a repeat run with nothing changed selects the same build" {
  a_then_b
  commit "chore: tidy"
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed"
  ticket SIG-2 "On Dev · Ready for QA"
  run select_rc
  [ "$status" -eq 0 ]
  first="$output"
  # The hourly backstop has no triggering ticket; selection must not care.
  TICKET=SIG-1 TRIGGER_ID=abc run select_rc
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  run select_rc
  [ "$output" = "$first" ]
}

@test "AC5: a missed QA Passed event is picked up by the next run" {
  a_then_b
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed"
  ticket SIG-2 "On Dev · Ready for QA"
  run select_rc
  echo "$output" | jq -e --arg a "$(sha_of "feat(SIG-1): A")" '.rc.sha == $a' > /dev/null
  # QA Passed applied to B, but its webhook never arrived: the hourly run
  # reads Linear afresh and moves on to B's build.
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  echo "$output" | jq -e --arg b "$(sha_of "feat(SIG-2): B")" '.rc.sha == $b' > /dev/null
}

@test "only commits with a successful build are selectable" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  commit "feat(SIG-2): B"
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg a "$(sha_of "feat(SIG-1): A")" '.rc.sha == $a' > /dev/null
  # B is not in the Release Candidate until its build exists.
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1"] and .blocked_by == null' > /dev/null
  echo "$output" | jq -e '.commits | length == 2 and .[1].build == null' > /dev/null
}

@test "a ticket named only by the PR branch still blocks (squash merge)" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  commit "Fix the header (#42)"; built "Fix the header (#42)" 12
  pr "Fix the header (#42)" "Fix the header" "alex/sig-7-fix-header"
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed"
  ticket SIG-7 "On Dev · Ready for QA"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocked_by.id == "SIG-7" and .untracked_commits == []' > /dev/null
}

@test "a merge commit carries the tickets of its branch" {
  git checkout -q -b feature
  commit "feat(SIG-5): work"
  git checkout -q main
  git merge -q --no-ff feature -m "Merge pull request #9 from o/feature"
  built "Merge pull request #9 from o/feature" 11
  ticket SIG-5 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-5"] and .rc.image_tag != null' > /dev/null
  # First-parent walk: the branch commit is not a build candidate itself.
  echo "$output" | jq -e '.commits | length == 1' > /dev/null
}

@test "a ticket missing from Linear blocks" {
  commit "feat(SIG-404): ghost"; built "feat(SIG-404): ghost" 11
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocked_by.id == "SIG-404" and .blocked_by.reason == "not found in Linear"' > /dev/null
}

@test "Linear down -> the run fails instead of selecting" {
  a_then_b
  touch "$TMP/linear-down"
  run select_rc
  [ "$status" -ne 0 ]
}

@test "nothing since the last Promotion -> outcome none" {
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "none" and .rc == null and .last_tag == "1.0.0"' > /dev/null
}

@test "walks from the nearest release tag, ignoring other tags" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  git tag 1.0.1
  git tag not-a-release
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 12
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.last_tag == "1.0.1" and [.tickets[].id] == ["SIG-2"]' > /dev/null
  run ! grep -qx SIG-1 "$TMP/linear-calls"
}

@test "a higher release tag on a merged side branch does not move the boundary" {
  git checkout -q -b side
  commit "side work"
  git tag 9.9.9
  git checkout -q main
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  git merge -q --no-ff side -m "Merge side"
  built "Merge side" 12
  ticket SIG-1 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.last_tag == "1.0.0" and [.tickets[].id] == ["SIG-1"]' > /dev/null
  echo "$output" | jq -e --arg m "$(sha_of "Merge side")" '.rc.sha == $m' > /dev/null
}

@test "a newer bare tag wins over an older v-prefixed one" {
  commit "feat(SIG-1): A"
  git tag v1.9.0
  commit "feat(SIG-2): B"
  git tag 2.0.0
  commit "feat(SIG-3): C"; built "feat(SIG-3): C" 13
  ticket SIG-3 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.last_tag == "2.0.0" and [.tickets[].id] == ["SIG-3"]' > /dev/null
}

@test "Linear errors next to issue data fail the run" {
  a_then_b
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  echo '{"data":{"issue":{"identifier":"SIG-1","title":"A","url":"u","state":null,"labels":{"nodes":[{"name":"QA Passed"}]}}},"errors":[{"message":"state failed"}]}' > "$TMP/raw-SIG-1"
  run select_rc
  [ "$status" -ne 0 ]
  grep -q "errors with partial data" "$TMP/stderr"
}

@test "a Linear issue without state fails the run" {
  a_then_b
  echo '{"data":{"issue":{"identifier":"SIG-1","title":"A","url":"u","labels":{"nodes":[{"name":"QA Passed"}]}}}}' > "$TMP/raw-SIG-1"
  run select_rc
  [ "$status" -ne 0 ]
  grep -q "lacks identifier, state or labels" "$TMP/stderr"
}

@test "an unparsable Linear reply fails the run" {
  a_then_b
  echo 'not json' > "$TMP/raw-SIG-1"
  run select_rc
  [ "$status" -ne 0 ]
}

@test "Linear errors with no issue block the ticket and keep the error" {
  a_then_b
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  echo '{"data":{"issue":null},"errors":[{"message":"Entity not found"}]}' > "$TMP/raw-SIG-1"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.rc == null and .blocked_by.reason == "not found in Linear (Entity not found)"' > /dev/null
}

@test "ticket-like text that is not a reference does not block" {
  commit "chore: bump SIG-123abc fixture"; built "chore: bump SIG-123abc fixture" 11
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.rc.image_tag != null and (.untracked_commits | length) == 1' > /dev/null
}

@test "a Release Candidate that already carries a release tag is a no-op" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  git tag v1.0.1
  ticket SIG-1 "On Staging" "QA Passed"
  run select_rc 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "already_promoted" and .already_promoted == true' > /dev/null
}

@test "custom label and column names are honoured" {
  a_then_b
  ticket SIG-1 "Ready for QA" "QA OK"
  ticket SIG-2 "Rejected" "QA OK"
  QA_PASSED_LABEL="QA OK" QA_FAILED_STATE="Rejected" run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-1"] and .blocked_by.reason == "in Rejected"' > /dev/null
}

@test "no release tag -> clear error" {
  git tag -d 1.0.0 > /dev/null
  run select_rc
  [ "$status" -ne 0 ]
  grep -q "no tag matching" "$TMP/stderr"
}

# --- Walk from the tag prod runs (finding: failed-staging tag then N+1) ---

@test "a tag that failed staging keeps stopping the line for the next candidate" {
  # Prod runs 1.0.0. 1.0.1 (SIG-1) was promoted, failed staging: SIG-1 is in
  # QA Failed. SIG-2 then passes QA on dev.
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  git tag 1.0.1
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 12
  ticket SIG-1 "QA Failed" "QA Passed" "Staging Failed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  # Walking from the last Promotion (old behaviour) would select B:
  run select_rc
  echo "$output" | jq -e --arg b "$(sha_of "feat(SIG-2): B")" '.base == "1.0.1" and .rc.sha == $b' > /dev/null
  # From the tag prod runs, SIG-1 stops the line: nothing is selectable.
  run select_rc 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.base == "1.0.0" and .last_release_tag == "1.0.1"' > /dev/null
  echo "$output" | jq -e '.outcome == "none" and .rc == null and .blocked_by.id == "SIG-1"' > /dev/null
}

@test "from the prod tag, tickets cover every commit not in prod yet" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  git tag 1.0.1
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 12
  ticket SIG-1 "On Staging" "QA Passed" "Staging Passed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "selected" and [.tickets[].id] == ["SIG-1","SIG-2"]' > /dev/null
  # The newest build that already carries a release tag is what prod may resume.
  echo "$output" | jq -e --arg a "$(sha_of "feat(SIG-1): A")" \
    '.staged == {sha: $a, image_tag: "main-11-\($a)", release_tag: "1.0.1", tickets: ["SIG-1"]}' > /dev/null
}

@test "already_promoted: the newest selectable build is the tag on staging" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  git tag 1.0.1
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 12
  ticket SIG-1 "On Staging" "QA Passed"
  ticket SIG-2 "On Dev · Ready for QA"
  run select_rc 1.0.0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "already_promoted" and .rc.release_tag == "1.0.1"' > /dev/null
  echo "$output" | jq -e '.staged.release_tag == "1.0.1" and .blocked_by.id == "SIG-2"' > /dev/null
}

@test "a base that is not on the branch is an error" {
  git checkout -q -b side; commit "side"; git tag 5.0.0; git checkout -q main
  run select_rc 5.0.0
  [ "$status" -ne 0 ]
  grep -q "not in HEAD's history" "$TMP/stderr"
}

# --- Reverts (ADR 0001 24 h revert, SIG-2766) ---

# revert_of <subject-of-target> <message>: an empty commit carrying git's trailer.
revert_of() {
  git commit -q --allow-empty -m "$2" -m "This reverts commit $(sha_of "$1")."
}

@test "a QA Failed ticket whose commit is reverted no longer blocks" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 12
  revert_of "feat(SIG-1): A" 'Revert "feat(SIG-1): A"'; built 'Revert "feat(SIG-1): A"' 13
  ticket SIG-1 "QA Failed" "QA Passed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  run select_rc
  [ "$status" -eq 0 ]
  r=$(sha_of 'Revert "feat(SIG-1): A"')
  echo "$output" | jq -e --arg r "$r" '.outcome == "selected" and .rc.sha == $r and .blocked_by == null' > /dev/null
  echo "$output" | jq -e '[.tickets[].id] == ["SIG-2"]' > /dev/null
  echo "$output" | jq -e --arg r "$r" '.reverted == [{sha: .reverted[0].sha, subject: "feat(SIG-1): A", tickets: ["SIG-1"], reverted_by: [$r]}]' > /dev/null
  echo "$output" | jq -e '[.untracked_commits[] | select(.revert)] | length == 1' > /dev/null
  # Linear is never asked about SIG-1: neither the reverted commit nor the revert block.
  run ! grep -qx SIG-1 "$TMP/linear-calls"
}

@test "builds between a reverted commit and its revert are not selectable" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  commit "feat(SIG-2): B"; built "feat(SIG-2): B" 12
  ticket SIG-1 "QA Failed"
  ticket SIG-2 "On Dev · Ready for QA" "QA Passed"
  revert_of "feat(SIG-1): A" 'Revert "feat(SIG-1): A"'
  # The revert has no build yet: B's build still contains A, so nothing.
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "none" and .rc == null and .blocked_by == null' > /dev/null
}

@test "a merged revert PR naming the ticket in its title and branch does not block" {
  git checkout -q -b prodzilla/revert-SIG-1
  commit "feat(SIG-1): A"
  git checkout -q main
  git merge -q --no-ff prodzilla/revert-SIG-1 -m "Merge pull request #7 from o/feature-sig-1"
  built "Merge pull request #7 from o/feature-sig-1" 11
  git checkout -q -b revert-branch
  git revert -m 1 --no-edit HEAD > /dev/null 2>&1 || git commit -q --allow-empty -m 'Revert "Merge pull request #7"' -m "This reverts commit $(git rev-parse main)."
  git checkout -q main
  git merge -q --no-ff revert-branch -m "Merge pull request #8 from o/prodzilla/revert-SIG-1"
  built "Merge pull request #8 from o/prodzilla/revert-SIG-1" 12
  pr "Merge pull request #8 from o/prodzilla/revert-SIG-1" "Revert SIG-1: A" "prodzilla/revert-SIG-1"
  ticket SIG-1 "QA Failed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "selected" and .tickets == [] and .blocked_by == null' > /dev/null
  echo "$output" | jq -e --arg m "$(sha_of "Merge pull request #8 from o/prodzilla/revert-SIG-1")" '.rc.sha == $m' > /dev/null
}

@test "a ticket with a live commit next to a reverted one still blocks" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  revert_of "feat(SIG-1): A" 'Revert "feat(SIG-1): A"'; built 'Revert "feat(SIG-1): A"' 12
  commit "fix(SIG-1): A again"; built "fix(SIG-1): A again" 13
  ticket SIG-1 "QA Failed"
  run select_rc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg r "$(sha_of 'Revert "feat(SIG-1): A"')" '.rc.sha == $r and .blocked_by.id == "SIG-1"' > /dev/null
}

@test "a re-land (revert of the revert) brings the code back and blocks again" {
  commit "feat(SIG-1): A"; built "feat(SIG-1): A" 11
  revert_of "feat(SIG-1): A" 'Revert "feat(SIG-1): A"'; built 'Revert "feat(SIG-1): A"' 12
  revert_of 'Revert "feat(SIG-1): A"' 'Revert "Revert "feat(SIG-1): A""'; built 'Revert "Revert "feat(SIG-1): A""' 13
  ticket SIG-1 "QA Failed"
  run select_rc
  [ "$status" -eq 0 ]
  # A is live again, so it blocks at A itself: nothing is selectable.
  echo "$output" | jq -e '.rc == null and .blocked_by.id == "SIG-1"' > /dev/null
  echo "$output" | jq -e --arg a "$(sha_of "feat(SIG-1): A")" '.blocked_by.sha == $a' > /dev/null
}
