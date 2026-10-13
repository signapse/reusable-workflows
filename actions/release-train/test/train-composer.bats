#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/train-composer.sh"
FIXTURES="$BATS_TEST_DIRNAME/../testdata"

setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"

  # Fake `curl`. linear_query now expects `body\n<status>` (from -w '%{http_code}')
  # and issues one per-identifier query — look up the requested id in $LINEAR_FIXTURE
  # and return {data:{issue:<node>}}. sentry_issue_count uses -sSf (no status suffix).
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
prev=""
body=""
for arg in "$@"; do
  if [ "$prev" = "-d" ]; then body="$arg"; fi
  prev="$arg"
done
if [[ "$*" == *"api.linear.app"* ]]; then
  id=$(echo "$body" | jq -r '.variables.id // empty')
  node=$(jq -c --arg id "$id" '.[$id] // empty' "$LINEAR_FIXTURE")
  if [ -n "$node" ]; then
    printf '{"data":{"issue":%s}}\n200' "$node"
  else
    printf '{"data":{"issue":null},"errors":[{"message":"not found"}]}\n200'
  fi
elif [[ "$*" == *"sentry.io"* ]]; then
  echo '[{"count":"12"}]'
else
  exit 1
fi
EOS
  chmod +x "$TMP/stub/curl"

  # Fake `gh` for: compare (paginate+jq), pr list, check-runs (jq).
  # Actually runs the requested --jq filter against fixture JSON via jq, so the
  # stub stays correct even if the real script's filter expression changes.
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

sub="$1"; shift

case "$sub" in
  api)
    url=""
    filter="."
    args=("$@")
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
      arg="${args[$i]}"
      case "$arg" in
        --paginate) ;;
        --jq)
          i=$((i + 1))
          filter="${args[$i]}"
          ;;
        *)
          [ -z "$url" ] && url="$arg"
          ;;
      esac
      i=$((i + 1))
    done
    case "$url" in
      *"/compare/"*)
        echo '{"commits":[{"sha":"aaa"}]}' | jq -r "$filter"
        ;;
      *"/check-runs")
        echo '{"check_runs":[{"name":"staging-tests","conclusion":"success"}]}' | jq -r "$filter"
        ;;
      *)
        echo "gh stub: unhandled api url: $url" >&2
        exit 1
        ;;
    esac
    ;;
  pr)
    # gh pr list --repo REPO --search SHA --state merged --json ...
    echo '[{"number":1,"title":"t","author":{"login":"x"},"labels":[{"name":"chore"}]}]'
    ;;
  *)
    echo "gh stub: unhandled subcommand: $sub" >&2
    exit 1
    ;;
esac
EOS
  chmod +x "$TMP/stub/gh"

  # Fake `git log` via a scratch repo:
  cd "$TMP"
  git init -q
  git config user.email t@t.t
  git config user.name t
  git commit -q --allow-empty -m "root"
  git commit -q --allow-empty -m "feat(SIG-1): a"
  git commit -q --allow-empty -m "feat(SIG-2): b"
  git tag 1.2.20 HEAD~2

  export LINEAR_API_KEY=x
  export SENTRY_AUTH_TOKEN=x
  export GITHUB_TOKEN=x
  export GITHUB_REPOSITORY=signapse/text-to-video-api
}

teardown() { rm -rf "$TMP"; }

@test "all ready → blocking_tickets empty" {
  export LINEAR_FIXTURE="$FIXTURES/linear/ready-state.json"
  run "$SCRIPT" 1.2.20 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocking_tickets == []' > /dev/null
  echo "$output" | jq -e '.ready_tickets | length == 2' > /dev/null
  echo "$output" | jq -e '.next_version == "1.2.21"' > /dev/null
  echo "$output" | jq -e '.staging_ok == true' > /dev/null
}

@test "in-QA present → tagged blocking" {
  export LINEAR_FIXTURE="$FIXTURES/linear/in-qa-state.json"
  run "$SCRIPT" 1.2.20 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blocking_tickets | length == 1' > /dev/null
  echo "$output" | jq -e '.blocking_tickets[0].id == "SIG-2"' > /dev/null
  echo "$output" | jq -e '.ready_tickets | length == 1' > /dev/null
}

@test "sentry count wired through" {
  export LINEAR_FIXTURE="$FIXTURES/linear/ready-state.json"
  run "$SCRIPT" 1.2.20 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.sentry_error_count_24h == 12' > /dev/null
}

@test "all PRs are ticketed → non_ticket_prs is empty" {
  export LINEAR_FIXTURE="$FIXTURES/linear/ready-state.json"
  # Override the pr list stub to return a ticketed PR (title contains SIG-1).
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *"compare"*)         echo '{"commits":[{"sha":"aaa"}]}';;
  *"pr list"*)         echo '[{"number":1,"title":"feat(SIG-1): thing","author":{"login":"x"},"labels":[{"name":"chore"}]}]';;
  *"check-runs"*)      echo '{"check_runs":[{"name":"staging-tests","conclusion":"success"}]}';;
  *)                   echo '{}';;
esac
EOS
  chmod +x "$TMP/stub/gh"
  run "$SCRIPT" 1.2.20 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.non_ticket_prs == []' > /dev/null
}

@test "missing SENTRY_AUTH_TOKEN degrades sentry count to 0 without aborting" {
  export LINEAR_FIXTURE="$FIXTURES/linear/ready-state.json"
  unset SENTRY_AUTH_TOKEN
  run "$SCRIPT" 1.2.20 HEAD
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.sentry_error_count_24h == 0' > /dev/null
}
