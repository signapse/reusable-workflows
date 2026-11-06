#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/merged-prs.sh"

# The fake `gh api repos/R/commits/<sha>/pulls` answers from the commit's own
# subject: "pr:<n>:<merged|open>[,...]" lists the PRs associated with it.
setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
url="$2"
sha=$(echo "$url" | sed -E 's#.*/commits/([^/]+)/pulls#\1#')
echo "$url" >> "$TMP/gh.log"
subject=$(git log -1 --format=%s "$sha")
spec="${subject#pr:}"
[ "$spec" != "$subject" ] || { echo '[]'; exit 0; }
echo "$spec" | tr ',' '\n' | while IFS=: read -r n st; do
  merged=null; [ "$st" = merged ] && merged='"2026-11-01T00:00:00Z"'
  echo "{\"number\":$n,\"merged_at\":$merged,\"title\":\"PR $n\",\"user\":{\"login\":\"dev$n\"},\"head\":{\"ref\":\"alex/sig-$n-x\"},\"html_url\":\"https://github.com/signapse/app/pull/$n\"}"
done | jq -sc .
EOS
  chmod +x "$TMP/stub/gh"
  cd "$TMP"
  git init -q repo && cd repo
  git config user.email t@t.t && git config user.name t
  git commit -q --allow-empty -m root
}

teardown() { rm -rf "$TMP"; }

@test "lists merged PRs for the range with repo, author, title, branch, url" {
  git commit -q --allow-empty -m "pr:5:merged"
  run "$SCRIPT" signapse/app HEAD~1 HEAD
  [ "$status" -eq 0 ]
  [ "$output" = '[{"repo":"signapse/app","number":5,"author":"dev5","title":"PR 5","head_ref":"alex/sig-5-x","url":"https://github.com/signapse/app/pull/5"}]' ]
}

@test "drops unmerged PRs that merely contain the commit" {
  git commit -q --allow-empty -m "pr:5:merged,6:open"
  run "$SCRIPT" signapse/app HEAD~1 HEAD
  [ "$(echo "$output" | jq -c 'map(.number)')" = '[5]' ]
}

@test "dedupes a PR seen on several commits of the range" {
  git commit -q --allow-empty -m "pr:5:merged"
  git commit -q --allow-empty -m "pr:5:merged,7:merged"
  git commit -q --allow-empty -m "direct push, no PR"
  run "$SCRIPT" signapse/app HEAD~3 HEAD
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c 'map(.number)')" = '[5,7]' ]
}

@test "empty range emits [] without calling GitHub" {
  run "$SCRIPT" signapse/app HEAD HEAD
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  [ ! -f "$TMP/gh.log" ]
}

@test "unknown since-ref emits []" {
  run "$SCRIPT" signapse/app deadbeef HEAD
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}
