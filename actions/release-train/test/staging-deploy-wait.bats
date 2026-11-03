#!/usr/bin/env bats
# staging-deploy-wait.sh (SIG-2764): waits for Flux to commit the release tag
# to signapse-core-k8s workloads/stg/... and, when a version URL is set, for
# the service to report it. The GitOps file contents come from $TMP/files/<n>
# (one per poll; past the last, the last repeats) so tests can model Flux catching up.
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/staging-deploy-wait.sh"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/files"
  export PATH="$TMP/stub:$PATH"
  echo 0 > "$TMP/polls"

  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
[ -f "$TMP/gh-404" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
n=$(cat "$TMP/polls"); echo $((n + 1)) > "$TMP/polls"
f="$TMP/files/$n"
[ -f "$f" ] || f=$(ls "$TMP/files" | sort -n | tail -1 | sed "s#^#$TMP/files/#")
cat "$f"
EOS
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
cat "$TMP/version.json"
EOS
  cat > "$TMP/stub/sleep" <<'EOS'
#!/usr/bin/env bash
echo "$1" >> "$TMP/slept"
EOS
  chmod +x "$TMP/stub/"*

  export GH_TOKEN=x TAG=1.2.45 WATCH_PATHS=workloads/stg/signstream-api/helmrelease-patch.yaml
  export POLL_SECONDS=20 TIMEOUT_SECONDS=100 SETTLE_SECONDS=30
}

teardown() { rm -rf "$TMP"; }

# file <poll-index> <tag>: the helmrelease patch Flux has written at that poll.
file() {
  cat > "$TMP/files/$1" <<EOF
    image:
      # tag: "9.9.9" in a comment does not count
      tag: "$2" # {"\$imagepolicy": "flux-system:signstream-api-stg:tag"}
EOF
}

@test "AC2: returns once Flux has committed the tag, then waits the settle time" {
  file 0 1.2.44
  file 1 1.2.44
  file 2 1.2.45
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/polls")" -eq 3 ]
  # two polls of 20s, then the 30s settle
  [ "$(paste -sd, "$TMP/slept")" = "20,20,30" ]
}

@test "a higher semver counts (it contains this build)" {
  file 0 1.3.0
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "v-prefixed tags compare as semver" {
  file 0 v1.2.45
  TAG=v1.2.45 run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "the setter line is what counts, not other tags in the file" {
  cat > "$TMP/files/0" <<'EOF'
    sidecar:
      tag: "1.2.99"
    image:
      tag: "1.2.44" # {"$imagepolicy": "flux-system:signstream-api-stg:tag"}
EOF
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]]
}

@test "times out naming the file when Flux never commits the tag" {
  file 0 1.2.44
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not commit 1.2.45"* ]]
  [[ "$output" == *"helmrelease-patch.yaml"* ]]
}

@test "with a version URL, waits until the service reports the tag" {
  file 0 1.2.45
  echo '{"version":"1.2.45"}' > "$TMP/version.json"
  VERSION_URL=https://stg.example/version run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/slept" ]
}

@test "with a version URL that keeps reporting the old tag, times out" {
  file 0 1.2.45
  echo '{"version":"1.2.44"}' > "$TMP/version.json"
  VERSION_URL=https://stg.example/version run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never reported 1.2.45"* ]]
}

@test "a GitOps path it cannot read fails at once" {
  touch "$TMP/gh-404"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 404"* ]]
  [ ! -f "$TMP/slept" ]
}

@test "bad input fails" {
  WATCH_PATHS="" run "$SCRIPT"
  [ "$status" -ne 0 ]
  TAG=main-12-abc run "$SCRIPT"
  [ "$status" -ne 0 ]
}
