#!/usr/bin/env bats
load 'helpers/load'
bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/linear-release.sh"

# Stateful fake Linear API. Dispatches on the GraphQL operation in the request
# body; a created Release is persisted to $STATE/release.json so a second run
# sees it. Every request's operation is appended to $STATE/calls.
setup() {
  export TMP="$(mktemp -d)"
  export STATE="$TMP/state"
  mkdir -p "$TMP/stub" "$STATE"
  export PATH="$TMP/stub:$PATH"
  export LINEAR_API_KEY=fake
  export GITHUB_REPOSITORY=signapse/test-repo
  : > "$STATE/calls"
  # Default fixture: SignStream pipeline with the SIG-2748 stages.
  cat > "$STATE/pipelines.json" <<'EOF'
{"data":{"releasePipelines":{"nodes":[{"id":"pipe-1","name":"SignStream","type":"continuous","stages":{"nodes":[
 {"id":"st-dep","name":"Deployed","type":"started"},
 {"id":"st-roll","name":"Rolling Out","type":"started"},
 {"id":"st-rel","name":"Released","type":"completed"}]}}]}}}
EOF

  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
prev=""; body=""
for a in "$@"; do [ "$prev" = "-d" ] && body="$a"; prev="$a"; done
q=$(jq -r '.query' <<<"$body")
v=$(jq -c '.variables' <<<"$body")
case "$q" in
  *releasePipelines*) echo "pipelines" >> "$STATE/calls"; cat "$STATE/pipelines.json" ;;
  *releaseCreate*)
    echo "releaseCreate" >> "$STATE/calls"
    echo "$v" > "$STATE/create-vars.json"
    jq -c '{id:"rel-1", url:"https://linear.app/signapse/release/rel-1", version:.input.version, stage:{name:"Deployed"}}' <<<"$v" > "$STATE/release.json"
    jq -c '{data:{releaseCreate:{success:true, release:.}}}' "$STATE/release.json" ;;
  *releaseUpdate*)
    echo "releaseUpdate" >> "$STATE/calls"
    echo "$v" > "$STATE/update-vars.json"
    printf '{"data":{"releaseUpdate":{"success":true}}}' ;;
  *issueUpdate*)
    id=$(jq -r '.id' <<<"$v")
    echo "issueUpdate $id" >> "$STATE/calls"
    if [ -f "$STATE/deny" ]; then
      printf '{"errors":[{"message":"Authentication required"}],"data":null}'
    else
      printf '{"data":{"issueUpdate":{"success":true}}}'
    fi ;;
  *"issues("*)
    # Every requested SIG-<n> exists unless listed in $STATE/missing.
    echo "issues" >> "$STATE/calls"
    jq -c --rawfile miss <(cat "$STATE/missing" 2>/dev/null || true) '
      ($miss | split("\n") | map(select(. != ""))) as $m
      | {data:{issues:{nodes:[.n[] | "SIG-\(.)" | select(IN($m[]) | not) | {id:("uuid-" + .), identifier:.}]}}}' <<<"$v" ;;
  *orderBy:createdAt*)
    # Previous-Release lookup for the default range start.
    echo "prev-releases $(jq -c . <<<"$v")" >> "$STATE/calls"
    cat "$STATE/prev.json" 2>/dev/null || printf '{"data":{"releases":{"nodes":[]}}}' ;;
  *"releases("*)
    echo "releases" >> "$STATE/calls"
    if [ -f "$STATE/release.json" ]; then
      jq -c '{data:{releases:{nodes:[.]}}}' "$STATE/release.json"
    else
      printf '{"data":{"releases":{"nodes":[]}}}'
    fi ;;
  *) printf '{"errors":[{"message":"unexpected query"}]}' ;;
esac
printf '\n200'
EOS
  chmod +x "$TMP/stub/curl"

  cd "$TMP"
  git init -q repo
  cd repo
  git config user.email t@t.t
  git config user.name t
  git commit -q --allow-empty -m "root"
  git tag v0.0.0
  git commit -q --allow-empty -m "feat(SIG-101): first"
  git commit -q --allow-empty -m "chore: bump deps"
  git commit -q --allow-empty -m "fix: SIG-102 second"
  git tag v0.0.1
  mkdir -p .signapse
  printf 'product: Signstream\nlinear_pipeline: SignStream  # prod pipeline\n' > .signapse/pipeline.yml
}

teardown() { rm -rf "$TMP"; }

@test "create: Release in stage Deployed with the range's tickets" {
  run --separate-stderr "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = "rel-1" ]
  [ "$(jq -r '.url' <<<"$output")" = "https://linear.app/signapse/release/rel-1" ]
  [ "$(jq -r '.created' <<<"$output")" = "true" ]
  [ "$(jq -c '.tickets' <<<"$output")" = '["SIG-101","SIG-102"]' ]
  # pipeline name came from .signapse/pipeline.yml (comment stripped)
  [ "$(jq -r '.input.pipelineId' "$STATE/create-vars.json")" = "pipe-1" ]
  [ "$(jq -r '.input.stageId' "$STATE/create-vars.json")" = "st-dep" ]
  [ "$(jq -r '.input.version' "$STATE/create-vars.json")" = "v0.0.1" ]
  [ "$(jq -r '.input.commitSha' "$STATE/create-vars.json")" = "$(git rev-parse v0.0.1)" ]
  grep -qx "issueUpdate uuid-SIG-101" "$STATE/calls"
  grep -qx "issueUpdate uuid-SIG-102" "$STATE/calls"
}

@test "untracked: commit with no ticket is listed in the description, no error" {
  run --separate-stderr "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.untracked | length' <<<"$output")" = "1" ]
  [[ "$(jq -r '.untracked[0]' <<<"$output")" == *"chore: bump deps" ]]
  desc=$(jq -r '.input.description' "$STATE/create-vars.json")
  [[ "$desc" == *"Untracked commits (no ticket):"* ]]
  [[ "$desc" == *"chore: bump deps"* ]]
  [[ "$desc" == *"Tickets: SIG-101, SIG-102"* ]]
  [[ "$desc" == *"signapse/test-repo@"* ]]
}

@test "untracked: a merge commit counts as tracked when its branch commits carry the ticket" {
  git checkout -q -b feat v0.0.1
  git commit -q --allow-empty -m "wip"
  git commit -q --allow-empty -m "SIG-200 done"
  git checkout -q -
  git merge -q --no-ff -m "Merge pull request #1 from feat" feat
  run --separate-stderr "$SCRIPT" v0.0.2 HEAD v0.0.1
  [ "$status" -eq 0 ]
  [ "$(jq -c '.untracked' <<<"$output")" = '[]' ]
  [ "$(jq -c '.tickets' <<<"$output")" = '["SIG-200"]' ]
}

@test "idempotent: second run for the same version reuses the Release" {
  run --separate-stderr "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -eq 0 ]
  run --separate-stderr "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -eq 0 ]
  [ "$(grep -c '^releaseCreate$' "$STATE/calls")" -eq 1 ]
  [ "$(jq -r '.created' <<<"$output")" = "false" ]
  [ "$(jq -r '.id' <<<"$output")" = "rel-1" ]
  [ "$(jq -c '.tickets' <<<"$output")" = '["SIG-101","SIG-102"]' ]
}

@test "missing pipeline: clear error naming the pipeline, nothing created" {
  printf '{"data":{"releasePipelines":{"nodes":[]}}}' > "$STATE/pipelines.json"
  run "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linear release pipeline 'SignStream' not found"* ]]
  ! grep -q releaseCreate "$STATE/calls"
}

@test "missing pipeline config: clear error when no input and no pipeline.yml" {
  rm .signapse/pipeline.yml
  run "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"no linear_pipeline input and no .signapse/pipeline.yml"* ]]
}

@test "missing stage: error lists the pipeline's stages (SignStream today has only Released)" {
  cat > "$STATE/pipelines.json" <<'EOF'
{"data":{"releasePipelines":{"nodes":[{"id":"pipe-1","name":"SignStream","type":"continuous","stages":{"nodes":[{"id":"st-rel","name":"Released","type":"completed"}]}}]}}}
EOF
  run "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage 'Deployed' not found in pipeline 'SignStream' (has: Released)"* ]]
  ! grep -q releaseCreate "$STATE/calls"
}

@test "LINEAR_PIPELINE and LINEAR_STAGE override config and default" {
  rm .signapse/pipeline.yml
  LINEAR_PIPELINE=SignStream LINEAR_STAGE="Rolling Out" run --separate-stderr "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.input.stageId' "$STATE/create-vars.json")" = "st-roll" ]
}

@test "ticket not in Linear: reported as unresolved, run still succeeds" {
  echo SIG-102 > "$STATE/missing"
  run --separate-stderr "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tickets' <<<"$output")" = '["SIG-101"]' ]
  [ "$(jq -c '.unresolved' <<<"$output")" = '["SIG-102"]' ]
  [[ "$(jq -r '.d' "$STATE/update-vars.json")" == *"not found in Linear: SIG-102"* ]]
  ! grep -qx "issueUpdate uuid-SIG-102" "$STATE/calls"
}

@test "attach failure (auth / bad release id): run fails, not reported as unresolved" {
  touch "$STATE/deny"
  run "$SCRIPT" v0.0.1 v0.0.1 v0.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linear API error: Authentication required"* ]]
}

@test "since defaults to the latest Release's commit: a skipped RC's tickets land in the next Release" {
  # v0.0.1 was deployed. v0.0.2 was tagged but failed staging (never a
  # Release). v0.0.3 is deployed: its range must start at v0.0.1, not v0.0.2.
  jq -nc --arg sha "$(git rev-parse v0.0.1)" \
    '{data:{releases:{nodes:[{version:"v0.0.1", commitSha:$sha, createdAt:"2026-11-01T00:00:00Z"},
                             {version:"v0.0.0", commitSha:null, createdAt:"2026-10-01T00:00:00Z"}]}}}' > "$STATE/prev.json"
  git commit -q --allow-empty -m "feat(SIG-103): in the skipped RC"
  git tag v0.0.2
  git commit -q --allow-empty -m "feat(SIG-104): in the deployed RC"
  git tag v0.0.3
  run --separate-stderr "$SCRIPT" v0.0.3 v0.0.3
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tickets' <<<"$output")" = '["SIG-103","SIG-104"]' ]
  [ "$(jq -r '.since' <<<"$output")" = "$(git rev-parse v0.0.1)" ]
  # lookup excludes this version (re-runs) and canceled stages (Rolled back)
  grep -q '^prev-releases .*"v":"v0.0.3"' "$STATE/calls"
}

@test "since: no earlier Release and no explicit since → clear error" {
  run "$SCRIPT" v0.0.1 v0.0.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no earlier Release with a commit; pass 'since'"* ]]
  ! grep -q releaseCreate "$STATE/calls"
}

@test "pipeline-config.sh reads keys, strips comments and quotes, empty when absent" {
  printf 'product: Signstream\nlinear_pipeline: "SignStream"  # prod\nsentry_project: signstream\n' > .signapse/pipeline.yml
  CFG="$BATS_TEST_DIRNAME/../scripts/pipeline-config.sh"
  [ "$("$CFG" linear_pipeline)" = "SignStream" ]
  [ "$("$CFG" sentry_project)" = "signstream" ]
  [ "$("$CFG" missing_key)" = "" ]
  [ "$("$CFG" sentry_project /nonexistent.yml)" = "" ]
}
