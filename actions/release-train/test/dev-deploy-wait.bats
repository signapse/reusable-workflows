#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/dev-deploy-wait.sh"
SHA=0b2f822d075dc999f0c4b729df6b9aa4f2f6c073
OLD=1111111111111111111111111111111111111111

# The fake GitOps repo: $TMP/gitops/<path>.<poll> is served on that poll
# (1-based) of the path; the highest poll file present is served after that.
setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub" "$TMP/gitops" "$TMP/count"
  export GITOPS_DIR="$TMP/gitops" COUNT_DIR="$TMP/count"
  export RUN_NUMBER=300 SHA POLL_SECONDS=10 TIMEOUT_SECONDS=60 SETTLE_SECONDS=30
  export WATCH_PATHS="workloads/dev/api/helmrelease-patch.yaml"
  unset VERSION_URL VERSION_JQ GITOPS_REPO GITOPS_REF
  export GITHUB_STEP_SUMMARY="$TMP/summary.md"

  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in repos/*) url="$a" ;; esac; done
echo "$url" >> "$COUNT_DIR/urls"
path="${url#repos/*/*/contents/}"; path="${path%%\?*}"
key=$(echo "$path" | tr '/' '_')
n=$(( $(cat "$COUNT_DIR/$key" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNT_DIR/$key"
f=""
for i in $(seq 1 "$n"); do
  [ -f "$GITOPS_DIR/$key.$i" ] && f="$GITOPS_DIR/$key.$i"
done
[ -n "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
# A file holding only "ERR <text>" makes that poll fail with <text>.
if head -1 "$f" | grep -q '^ERR '; then sed -n '1s/^ERR //p' "$f" >&2; exit 1; fi
cat "$f"
EOS
  # curl serves $TMP/version.<poll> the same way.
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT_DIR/curl" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNT_DIR/curl"
f=""
for i in $(seq 1 "$n"); do
  [ -f "$GITOPS_DIR/../version.$i" ] && f="$GITOPS_DIR/../version.$i"
done
[ -n "$f" ] || exit 22
cat "$f"
EOS
  cat > "$TMP/stub/sleep" <<'EOS'
#!/usr/bin/env bash
echo "$1" >> "$COUNT_DIR/sleeps"
EOS
  chmod +x "$TMP/stub/gh" "$TMP/stub/curl" "$TMP/stub/sleep"
}

teardown() { rm -rf "$TMP"; }

# serve <path> <poll> <tag>
serve() {
  printf 'spec:\n  values:\n    image:\n      tag: "%s" # {"$imagepolicy": "flux-system:api-dev:tag"}\n' "$3" \
    > "$GITOPS_DIR/$(echo "$1" | tr '/' '_').$2"
}

@test "Flux already committed this tag: waits the settle period, then passes" {
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/count/sleeps")" = "30" ]
  grep -q 'repos/signapse/signapse-core-k8s/contents/workloads/dev/api/helmrelease-patch.yaml?ref=main' "$TMP/count/urls"
}

@test "a newer main build on dev also counts (it contains this commit)" {
  serve "$WATCH_PATHS" 1 "main-301-$OLD"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "run numbers compare numerically, not as strings" {
  export RUN_NUMBER=1000
  serve "$WATCH_PATHS" 1 "main-999-$OLD"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "polls until Flux commits the tag" {
  serve "$WATCH_PATHS" 1 "main-299-$OLD"
  serve "$WATCH_PATHS" 3 "main-300-$SHA"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/count/workloads_dev_api_helmrelease-patch.yaml")" = "3" ]
}

@test "times out with a clear message when Flux never commits the tag" {
  serve "$WATCH_PATHS" 1 "main-299-$OLD"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out after 60s"* ]]
  [[ "$output" == *"workloads/dev/api/helmrelease-patch.yaml"* ]]
}

@test "every watched path must reach the tag; names the stale one" {
  export WATCH_PATHS="workloads/dev/api/a.yaml, workloads/dev/ws/b.yaml"
  serve workloads/dev/api/a.yaml 1 "main-300-$SHA"
  serve workloads/dev/ws/b.yaml 1 "main-299-$OLD"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Flux did not commit main-300 (or newer) to: workloads/dev/ws/b.yaml"* ]]
}

@test "newline-separated paths, custom GitOps repo and ref" {
  export WATCH_PATHS=$'x/a.yaml\nx/b.yaml' GITOPS_REPO=acme/gitops GITOPS_REF=dev
  serve x/a.yaml 1 "main-300-$SHA"
  serve x/b.yaml 1 "main-300-$SHA"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'repos/acme/gitops/contents/x/b.yaml?ref=dev' "$TMP/count/urls"
}

@test "VERSION_URL replaces the settle period and is polled until it names the build" {
  export VERSION_URL=https://dev.example/version
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  echo '{"version":"main-299-'"$OLD"'"}' > "$TMP/version.1"
  echo '{"version":"'"$SHA"'"}' > "$TMP/version.2"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/count/curl")" = "2" ]
  ! grep -qx 30 "$TMP/count/sleeps"
}

@test "VERSION_URL may report a bare main-<n> tag" {
  export VERSION_URL=https://dev.example/version
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  echo '{"version":"main-300"}' > "$TMP/version.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "VERSION_URL: only the running-version field counts, not a pending tag" {
  export VERSION_URL=https://dev.example/version
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  echo '{"version":"main-299","waitingFor":"main-300","commit":"'"$SHA"'"}' > "$TMP/version.1"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "VERSION_URL: a tag embedded in a longer value is a near miss" {
  export VERSION_URL=https://dev.example/version
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  echo '{"version":"domain-main-301-fix"}' > "$TMP/version.1"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "VERSION_JQ selects a custom field" {
  export VERSION_URL=https://dev.example/version VERSION_JQ=.build.tag
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  echo '{"version":"1.2.3","build":{"tag":"main-301-'"$OLD"'"}}' > "$TMP/version.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "VERSION_URL that never reports the build times out" {
  export VERSION_URL=https://dev.example/version
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  echo '{"version":"main-299-'"$OLD"'"}' > "$TMP/version.1"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never reported"* ]]
}

@test "settle period is capped by the remaining budget" {
  export SETTLE_SECONDS=500
  serve "$WATCH_PATHS" 1 "main-299-$OLD"
  serve "$WATCH_PATHS" 2 "main-300-$SHA"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$TMP/count/sleeps")" = "50" ]
}

@test "empty WATCH_PATHS is a configuration error" {
  export WATCH_PATHS=" , "
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WATCH_PATHS is empty"* ]]
}

@test "missing watch path (HTTP 404) fails fast, without waiting" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 404"* ]]
  [[ "$output" == *"check dev_watch_paths"* ]]
  [ ! -f "$TMP/count/sleeps" ]
}

@test "no access to the GitOps repo (HTTP 403) fails fast" {
  echo "ERR gh: Resource not accessible by integration (HTTP 403)" > "$GITOPS_DIR/$(echo "$WATCH_PATHS" | tr '/' '_').1"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"(HTTP 403)"* ]]
  [ ! -f "$TMP/count/sleeps" ]
}

@test "transient GitHub error (HTTP 502) is retried" {
  echo "ERR gh: Bad Gateway (HTTP 502)" > "$GITOPS_DIR/$(echo "$WATCH_PATHS" | tr '/' '_').1"
  serve "$WATCH_PATHS" 2 "main-300-$SHA"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"transient error"* ]]
}

@test "VERSION_URL: a value with a newline is rejected, not trimmed" {
  export VERSION_URL=https://dev.example/version
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  printf '{"version":"main-300\\nmain-299"}' > "$TMP/version.1"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "job summary says plainly when the fixed-wait fallback was used" {
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "Dev deploy NOT confirmed: fixed-wait fallback used" "$TMP/summary.md"
}

@test "job summary records a confirmed deploy when VERSION_URL matched" {
  export VERSION_URL=https://dev.example/version
  serve "$WATCH_PATHS" 1 "main-300-$SHA"
  echo '{"version":"main-300"}' > "$TMP/version.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "Dev deploy confirmed" "$TMP/summary.md"
  ! grep -q "fallback" "$TMP/summary.md"
}
