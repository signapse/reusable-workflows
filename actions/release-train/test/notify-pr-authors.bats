#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/notify-pr-authors.sh"

PRS='[{"repo":"signapse/app","number":5,"author":"ana","title":"Fix login","head_ref":"x","url":"https://github.com/signapse/app/pull/5"},
      {"repo":"signapse/app","number":6,"author":"bo","title":"Add flag","head_ref":"y","url":"https://github.com/signapse/app/pull/6"}]'

setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"
  export RUN_URL=https://github.com/signapse/app/actions/runs/1 GH_TOKEN=fake
  unset SLACK_CHANNEL REPORT_URL
  # gh pr comment <n> --repo <r> --body <b>: logs a JSON line; PR 404 fails.
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
[ "$1 $2" = "pr comment" ] || exit 1
[ "$3" = 404 ] && exit 1
jq -nc --arg n "$3" --arg r "$5" --arg b "$7" '{n:$n, repo:$r, body:$b}' >> "$TMP/comments"
EOS
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
cat > "$TMP/slack"
echo '{"ok":true}'
EOS
  chmod +x "$TMP/stub/gh" "$TMP/stub/curl"
}

teardown() { rm -rf "$TMP"; }

@test "AC2: comments on every merged PR, pinging its author with the failed stage" {
  run bash -c "echo '$PRS' | '$SCRIPT' 'dev smoke' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  [ "$(wc -l < "$TMP/comments" | tr -d ' ')" = 2 ]
  body=$(jq -r 'select(.n == "5") | .body' "$TMP/comments")
  [[ "$body" == "@ana "* ]]
  [[ "$body" == *"**dev smoke**"* ]]
  [[ "$body" == *"not moved to On Dev · Ready for QA"* ]]
  [[ "$body" == *"$RUN_URL"* ]]
  [[ "$body" == *"merge a fix PR in this same repo, linked to the same ticket"* ]]
  [ "$(jq -r 'select(.n == "6") | .repo' "$TMP/comments")" = signapse/app ]
}

@test "includes the e2e report link when there is one" {
  REPORT_URL=https://reports/1 run bash -c "echo '$PRS' | '$SCRIPT' 'dev smoke' 2>/dev/null"
  [[ "$(head -1 "$TMP/comments" | jq -r .body)" == *"[e2e report](https://reports/1)"* ]]
}

@test "a comment that cannot be posted is a warning, not a failure" {
  prs='[{"repo":"signapse/app","number":404,"author":"x","title":"t","url":"u"}]'
  run bash -c "echo '$prs' | '$SCRIPT' build"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::could not comment on signapse/app#404"* ]]
  [ "$(echo "$output" | tail -1)" = 0 ]
}

@test "no merged PRs: no comment, but Slack still reports the failure" {
  SLACK_CHANNEL='#eng' SLACK_BOT_TOKEN=x run bash -c "echo '[]' | '$SCRIPT' build 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  [ ! -f "$TMP/comments" ]
  [[ "$(jq -r .text "$TMP/slack")" == *"*build*"*"No merged PR found"* ]]
}

@test "empty stdin is treated as no PRs" {
  run bash -c "'$SCRIPT' build < /dev/null 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "Slack is skipped unless a channel is set" {
  run bash -c "echo '$PRS' | '$SCRIPT' build 2>/dev/null"
  [ ! -f "$TMP/slack" ]
}

@test "Slack message lists each PR and author when a channel is set" {
  SLACK_CHANNEL='#eng-alerts' SLACK_BOT_TOKEN=x run bash -c "echo '$PRS' | '$SCRIPT' 'dev deploy' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(jq -r .channel "$TMP/slack")" = '#eng-alerts' ]
  text=$(jq -r .text "$TMP/slack")
  [[ "$text" == *"*dev deploy*"* ]]
  [[ "$text" == *"<https://github.com/signapse/app/pull/5|signapse/app#5> Fix login (@ana)"* ]]
  [[ "$text" == *"signapse/app#6"* ]]
}

@test "Slack escapes PR titles so they cannot ping a channel" {
  prs='[{"repo":"signapse/app","number":5,"author":"ana","title":"Vec<T> & <!channel>","url":"u"}]'
  SLACK_CHANNEL='#eng' SLACK_BOT_TOKEN=x run bash -c "echo '$prs' | '$SCRIPT' build 2>/dev/null"
  text=$(jq -r .text "$TMP/slack")
  [[ "$text" == *"Vec&lt;T&gt; &amp; &lt;!channel&gt;"* ]]
  [[ "$text" != *"<!channel>"* ]]
}
