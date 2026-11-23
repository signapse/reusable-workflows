#!/usr/bin/env bats
# End to end: a throwaway origin holding a base and a PR head at refs/pull/7/head, a base-branch clone to run in, a
# stubbed `gh` that answers from canned JSON and logs every call (with its --input body), and gate-run.js run
# against a fake event.

setup() {
  export RISK="$BATS_TEST_DIRNAME/.."
  export TMP="$(mktemp -d)"
  export GH_DATA="$TMP/data" CALLS="$TMP/stub/gh.calls"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$TMP/stub" "$GH_DATA"
  cat >"$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
echo "gh $*" >>"$CALLS"
case "$*" in *--input*) cat >>"$CALLS"; echo >>"$CALLS" ;; esac
case "$*" in
  *"-X POST"* | *"-X PATCH"* | *"-X PUT"*) echo '{"id":1}' ;;
  *" repos/signapse/app/pulls/7") cat "$GH_DATA/pr.json" ;;
  *" repos/signapse/app/issues/7/comments") cat "$GH_DATA/comments.json" ;;
  *" repos/signapse/app/pulls/7/reviews") cat "$GH_DATA/reviews.json" ;;
  *"/check-runs?check_name=Risk%20Gate") cat "$GH_DATA/checks.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOS
  chmod +x "$TMP/stub/gh"
  export PATH="$TMP/stub:$PATH"

  # The Writer's repo: a base, and a PR that changes UI copy (a Low Risk Floor).
  cd "$TMP" && git init -q -b main writer && cd writer
  mkdir src && echo '<b>Save</b>' >src/Button.tsx
  git add -A && git commit -qm base
  export BASE_SHA=$(git rev-parse HEAD)
  git checkout -qb pr && echo '<b>Save changes</b>' >src/Button.tsx && git commit -qam copy
  export HEAD_SHA=$(git rev-parse HEAD)
  git init -q --bare ../origin.git
  git push -q ../origin.git main:refs/heads/main pr:refs/pull/7/head
  git clone -q -b main ../origin.git ../work
  cd ../work

  printf '{"number":7,"state":"open","user":{"login":"writer"},"head":{"sha":"%s"},"base":{"sha":"%s"}}' "$HEAD_SHA" "$BASE_SHA" >"$GH_DATA/pr.json"
  echo '[[]]' >"$GH_DATA/reviews.json"
  echo '{"total_count":0,"check_runs":[]}' >"$GH_DATA/checks.json"
  rate low
  echo '{"pull_request":{"number":7}}' >"$TMP/event.json"
  export GITHUB_EVENT_NAME=pull_request_target GITHUB_EVENT_PATH="$TMP/event.json" GITHUB_REPOSITORY=signapse/app
  export RISK_BOT_SLUG=signapse-risk-bot GH_TOKEN=fake
}

teardown() { rm -rf "$TMP"; }

# rate TIER: the PR author's Risk Rating for the head, as the only comment, written with the risk core itself.
rate() {
  TIER="$1" node --input-type=module -e '
    const { RISK, TMP, BASE_SHA, HEAD_SHA, TIER } = process.env;
    const { diff } = await import(`${RISK}/diff.js`);
    const { formatRating } = await import(`${RISK}/rating.js`);
    const { patchId } = diff(`${TMP}/writer`, BASE_SHA, HEAD_SHA);
    const body = formatRating({ version: 1, tier: TIER, patchId, headSha: HEAD_SHA, kinds: ["ui-copy"], floorTier: "low",
      model: "claude-sonnet-5-5", rulesSha: "c".repeat(40), certain: true, summary: "ui-copy on unlisted (Tier 2)", findingCount: 0 });
    console.log(JSON.stringify([[{ user: { login: "someone-else" }, body: "LGTM" }, { user: { login: "writer" }, body }]]));
  ' >"$GH_DATA/comments.json"
}

calls() { grep -c -- "$1" "$CALLS" || true; }

# approved_by LOGIN ID [COMMIT]: one APPROVED review, as the slurped reviews list.
approved_by() { echo "[[{\"id\":$2,\"user\":{\"login\":\"$1\"},\"state\":\"APPROVED\",\"commit_id\":\"${3:-$HEAD_SHA}\",\"body\":\"Risk Gate: Low: approved by the Risk Bot\"}]]"; }

@test "live: a valid Low Risk Rating creates the Risk Gate check and approves the head" {
  RISK_GATE_MODE=live run node "$RISK/gate-run.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Risk Gate: Low: approved by the Risk Bot"* ]]
  [ "$(calls '^gh api -X POST repos/signapse/app/check-runs --input -$')" -eq 1 ]
  grep -q "\"head_sha\":\"$HEAD_SHA\"" "$CALLS"
  grep -q '"conclusion":"success","output":{"title":"Low: approved by the Risk Bot"' "$CALLS"
  [ "$(calls '^gh api -X POST repos/signapse/app/pulls/7/reviews --input -$')" -eq 1 ]
  grep -q "{\"commit_id\":\"$HEAD_SHA\",\"event\":\"APPROVE\"" "$CALLS"
  # The PR head was fetched as objects, never checked out.
  [ "$(git rev-parse HEAD)" = "$BASE_SHA" ]
  [ "$(cat src/Button.tsx)" = '<b>Save</b>' ]
  git cat-file -e "$HEAD_SHA^{commit}"
}

@test "shadow: the same rating creates the check, never approves, and withdraws a standing Risk Bot approval" {
  approved_by signapse-risk-bot[bot] 99 >"$GH_DATA/reviews.json"
  RISK_GATE_MODE=shadow run node "$RISK/gate-run.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Risk Gate: Low (shadow): would be approved"* ]]
  [ "$(calls '^gh api -X POST repos/signapse/app/check-runs --input -$')" -eq 1 ]
  [ "$(calls '^gh api -X PUT repos/signapse/app/pulls/7/reviews/99/dismissals --input -$')" -eq 1 ]
  [ "$(calls '^gh api -X POST repos/signapse/app/pulls/7/reviews')" -eq 0 ]
}

@test "issue_comment: updates the Risk Bot's own check and does not approve a head it already approved" {
  echo '{"issue":{"number":7,"pull_request":{"url":"x"}},"comment":{"body":"/accept-risk"}}' >"$TMP/event.json"
  echo '{"check_runs":[{"id":41,"app":{"slug":"someone-elses-app"}},{"id":42,"app":{"slug":"signapse-risk-bot"}}]}' >"$GH_DATA/checks.json"
  echo "[[{\"user\":{\"login\":\"signapse-risk-bot[bot]\"},\"state\":\"APPROVED\",\"commit_id\":\"$HEAD_SHA\"}]]" >"$GH_DATA/reviews.json"
  GITHUB_EVENT_NAME=issue_comment RISK_GATE_MODE=live run node "$RISK/gate-run.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already approved this head"* ]]
  [ "$(calls '^gh api -X PATCH repos/signapse/app/check-runs/42 --input -$')" -eq 1 ]
  [ "$(calls 'POST')" -eq 0 ]
}

@test "live: a Medium Risk Rating without a Risk Acceptance waits and does not approve" {
  rate medium
  RISK_GATE_MODE=live run node "$RISK/gate-run.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Risk Gate: Medium: waiting for the Writer's Risk Acceptance"* ]]
  [ "$(calls '^gh api -X POST repos/signapse/app/pulls/7/reviews')" -eq 0 ]
  [ "$(calls 'dismissals')" -eq 0 ]
}

@test "live: a High Risk Rating for an approved head withdraws the Risk Bot's approval and approves nothing" {
  # The Writer raised the rating to High with no push: same head, same patch-id. Another engineer's approval, even
  # one whose text looks like the Gate's, is left alone: only the Risk Bot's login counts.
  rate high
  echo "[[{\"id\":98,\"user\":{\"login\":\"engineer\"},\"state\":\"APPROVED\",\"commit_id\":\"$HEAD_SHA\",\"body\":\"Risk Gate: Low: approved by the Risk Bot\"},
         {\"id\":99,\"user\":{\"login\":\"signapse-risk-bot[bot]\"},\"state\":\"APPROVED\",\"commit_id\":\"$HEAD_SHA\"},
         {\"id\":100,\"user\":{\"login\":\"signapse-risk-bot[bot]\"},\"state\":\"DISMISSED\",\"commit_id\":\"$HEAD_SHA\"}]]" >"$GH_DATA/reviews.json"
  RISK_GATE_MODE=live run node "$RISK/gate-run.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Risk Gate: High: needs another engineer's approval"* ]]
  [ "$(calls 'dismissals')" -eq 1 ]
  [ "$(calls '^gh api -X PUT repos/signapse/app/pulls/7/reviews/99/dismissals --input -$')" -eq 1 ]
  grep -q "{\"message\":\"Risk Gate: High: needs another engineer's approval; approval withdrawn\",\"event\":\"DISMISS\"}" "$CALLS"
  [ "$(calls '^gh api -X POST repos/signapse/app/pulls/7/reviews')" -eq 0 ]
}

@test "off: posts no check but still withdraws a standing Risk Bot approval" {
  approved_by signapse-risk-bot[bot] 99 >"$GH_DATA/reviews.json"
  RISK_GATE_MODE=off run node "$RISK/gate-run.js"
  [ "$status" -eq 0 ]
  [ "$(calls '^gh api -X PUT repos/signapse/app/pulls/7/reviews/99/dismissals --input -$')" -eq 1 ]
  [ "$(calls 'check-runs')" -eq 0 ]
  [ "$(calls '^gh api -X POST')" -eq 0 ]
}

@test "issue_comment on an issue that is not a pull request: no GitHub calls at all" {
  echo '{"issue":{"number":7},"comment":{"body":"hi"}}' >"$TMP/event.json"
  GITHUB_EVENT_NAME=issue_comment RISK_GATE_MODE=live run node "$RISK/gate-run.js"
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
}
