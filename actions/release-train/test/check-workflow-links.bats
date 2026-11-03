#!/usr/bin/env bats
# check-workflow-links.sh must fail on a link to a workflow file that does not
# exist (SIG-2754: deploy-to-prod.yml vs deploy-prod.yml).
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-workflow-links.sh"
K8S="https://github.com/signapse/signapse-core-k8s/actions/workflows"

setup() {
  export TMP="$(mktemp -d)"
  mkdir -p "$TMP/wf" "$TMP/stub"
  echo 'signapse-core-k8s/deploy-prod.yml' > "$TMP/allow"
  export WORKFLOW_LINKS_ALLOWLIST="$TMP/allow"
  unset GH_TOKEN

  # gh stub: the only workflow that "exists" is signapse-core-k8s deploy-prod.yml.
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
echo "$2" >> "$TMP/gh-calls"
[ "$2" = "repos/signapse/signapse-core-k8s/contents/.github/workflows/deploy-prod.yml" ]
EOS
  chmod +x "$TMP/stub/gh"
}

teardown() { rm -rf "$TMP"; }

wf() { printf "      default: '%s'\n" "$1" > "$TMP/wf/release-train.yml"; }

@test "allow-list mode: passes when the linked workflow is listed" {
  wf "$K8S/deploy-prod.yml"
  run "$SCRIPT" "$TMP/wf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok      signapse/signapse-core-k8s .github/workflows/deploy-prod.yml"* ]]
}

@test "allow-list mode: fails on a wrong workflow file name" {
  wf "$K8S/deploy-to-prod.yml"
  run "$SCRIPT" "$TMP/wf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING signapse/signapse-core-k8s .github/workflows/deploy-to-prod.yml"* ]]
}

@test "API mode: fails on a wrong workflow file name, passes on the right one" {
  export GH_TOKEN=x PATH="$TMP/stub:$PATH"
  wf "$K8S/deploy-to-prod.yml"
  run "$SCRIPT" "$TMP/wf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING"*"deploy-to-prod.yml (checked via GitHub API)"* ]]

  wf "$K8S/deploy-prod.yml"
  run "$SCRIPT" "$TMP/wf"
  [ "$status" -eq 0 ]
  grep -q 'repos/signapse/signapse-core-k8s/contents/.github/workflows/deploy-prod.yml' "$TMP/gh-calls"
}

@test "skips test/ fixtures and passes when there are no links" {
  mkdir -p "$TMP/wf/test"
  printf '%s\n' "$K8S/deploy-to-prod.yml" > "$TMP/wf/test/fixture.bats"
  run "$SCRIPT" "$TMP/wf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no workflow links found"* ]]
}

@test "fails on a path that does not exist" {
  run "$SCRIPT" "$TMP/nope"
  [ "$status" -eq 1 ]
}
