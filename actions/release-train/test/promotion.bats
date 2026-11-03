#!/usr/bin/env bats
# Staging Promotion (SIG-2764): promotion-plan.sh (window + version, no side
# effects), promotion-tag.sh (ECR re-put + git tag), promotion-tickets.sh
# (On Staging). Stubs keep state in $TMP:
#   ecr/<repo>/<tag>     digest a tag points at
#   manifests/<digest>   manifest bytes
#   refs/<tag>           sha a git tag points at (GitHub API)
#   linear.json          ticket id -> [label names]
#   calls                every aws/gh write, in order
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/repo" "$TMP/ecr" "$TMP/manifests" "$TMP/refs"
  export PATH="$TMP/stub:$PATH"
  echo '{}' > "$TMP/linear.json"
  : > "$TMP/calls"

  cat > "$TMP/stub/aws" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
sub="$2"; shift 2
repo=""; tag=""; file=""; mt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repository-name) repo="$2"; shift ;;
    --image-ids) tag="${2#imageTag=}"; shift ;;
    --image-tag) tag="$2"; shift ;;
    --image-manifest) file="${2#file://}"; shift ;;
    --image-manifest-media-type) mt="$2"; shift ;;
  esac
  shift
done
d="$TMP/ecr/$repo"
case "$sub" in
  batch-get-image)
    if [ -f "$d/$tag" ]; then
      dg=$(cat "$d/$tag")
      jq -nc --rawfile m "$TMP/manifests/$dg" --arg d "$dg" \
        '{images: [{imageId: {imageDigest: $d}, imageManifest: $m,
                    imageManifestMediaType: "application/vnd.oci.image.index.v1+json"}]}'
    else
      echo '{"images":[],"failures":[{"failureCode":"ImageNotFound"}]}'
    fi ;;
  describe-images)
    [ -f "$d/$tag" ] || { echo "ImageNotFoundException" >&2; exit 254; }
    jq -nc --arg d "$(cat "$d/$tag")" '{imageDetails: [{imageDigest: $d}]}' ;;
  put-image)
    [ -f "$TMP/aws-fail" ] && { echo "AccessDenied" >&2; exit 255; }
    echo "put-image $repo $tag $mt" >> "$TMP/calls"
    # A registry that rewrote the manifest would give it a new digest.
    if [ -f "$TMP/mangle" ]; then printf ' ' >> "$file"; fi
    dg="sha256:$(shasum -a 256 "$file" | cut -d' ' -f1)"
    cp "$file" "$TMP/manifests/$dg"
    mkdir -p "$d"; echo "$dg" > "$d/$tag"
    echo '{}' ;;
  *) echo "aws stub: unhandled $sub" >&2; exit 1 ;;
esac
EOS

  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 1; shift
if [ "$1" = -X ]; then
  shift 2; ref=""; sha=""
  for a in "$@"; do
    case "$a" in ref=refs/tags/*) ref="${a#ref=refs/tags/}" ;; sha=*) sha="${a#sha=}" ;; esac
  done
  if [ -f "$TMP/refs/$ref" ]; then echo "gh: Reference already exists (HTTP 422)" >&2; exit 1; fi
  echo "create-ref $ref $sha" >> "$TMP/calls"
  echo "$sha" > "$TMP/refs/$ref"; echo '{}'; exit 0
fi
case "$1" in
  */git/ref/tags/*)
    t="${1##*/}"
    [ -f "$TMP/refs/$t" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    echo "$(cat "$TMP/refs/$t") commit" ;;
  *) echo "gh stub: unhandled $*" >&2; exit 1 ;;
esac
EOS

  # Linear: label lookups, the state lookup and issue moves.
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
prev=""; body=""
for arg in "$@"; do [ "$prev" = "-d" ] && body="$arg"; prev="$arg"; done
q=$(echo "$body" | jq -r .query)
case "$q" in
  *workflowStates*)
    printf '{"data":{"workflowStates":{"nodes":[{"id":"state-%s"}]}}}\n200' "$(echo "$body" | jq -r .variables.name | tr ' ' _)" ;;
  *issueUpdate*)
    id=$(echo "$body" | jq -r .variables.id)
    if [ -f "$TMP/move-fail-$id" ]; then
      printf '{"data":{"issueUpdate":null},"errors":[{"message":"nope"}]}\n200'; exit 0
    fi
    echo "move $id $(echo "$body" | jq -r .variables.state)" >> "$TMP/calls"
    printf '{"data":{"issueUpdate":{"success":true}}}\n200' ;;
  *labels*)
    [ -f "$TMP/linear-down" ] && { printf 'boom\n500'; exit 0; }
    id=$(echo "$body" | jq -r .variables.id)
    jq -c --arg id "$id" '{data: {issue: (if has($id) then {identifier: $id, labels: {nodes: [.[$id][] | {name: .}]}} else null end)}}' "$TMP/linear.json"
    printf '\n200' ;;
esac
EOS
  chmod +x "$TMP/stub/aws" "$TMP/stub/gh" "$TMP/stub/curl"

  cd "$TMP/repo"
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  git commit -q --allow-empty -m root
  git tag 1.2.44
  git commit -q --allow-empty -m "feat(SIG-1): A"
  RC=$(git rev-parse HEAD)
  export RC
  SRC="main-212-$RC"
  export SRC

  # The dev build: main-212-<sha> exists in both service repos.
  for r in signstream/http signstream/websocket; do
    m="{\"schemaVersion\":2,\"repo\":\"$r\"}"
    dg="sha256:$(printf '%s' "$m" | shasum -a 256 | cut -d' ' -f1)"
    printf '%s' "$m" > "$TMP/manifests/$dg"
    mkdir -p "$TMP/ecr/$r"; echo "$dg" > "$TMP/ecr/$r/$SRC"
  done

  export LINEAR_API_KEY=x GH_TOKEN=x GITHUB_REPOSITORY=o/r
  export SERVICES='["http","websocket"]' ECR_REPO_PREFIX=signstream
  export NOW=2026-11-03T10:00:00Z   # Tuesday 10:00 GMT, inside the window
}

teardown() { rm -rf "$TMP"; }

labels() {
  local id="$1"; shift
  jq --arg id "$id" --args '.[$id] = $ARGS.positional' "$@" < "$TMP/linear.json" > "$TMP/l" \
    && mv "$TMP/l" "$TMP/linear.json"
}
plan() { "$S/promotion-plan.sh" "$@" 2> "$TMP/stderr"; }
tag() { "$S/promotion-tag.sh" "$@" 2> "$TMP/stderr"; }
digest() { cat "$TMP/ecr/$1/$2"; }

# ---- plan: window + version, no side effects ------------------------------

@test "plan inside the window: open, next patch version from the last release tag" {
  labels SIG-1 Bug
  run plan "$RC" SIG-1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "open" and .tag == "1.2.45" and .version == "1.2.45"
    and .previous_tag == "1.2.44" and .existing == false and .tickets == ["SIG-1"]' > /dev/null
}

@test "plan bumps minor/major from ticket labels (version-bump.sh)" {
  labels SIG-1 Feature minor
  run plan "$RC" SIG-1
  echo "$output" | jq -e '.tag == "1.3.0"' > /dev/null
}

@test "plan bumps the HIGHEST release tag, not the nearest, so Flux picks the new tag" {
  git tag 1.2.50 "$(git rev-list --max-parents=0 HEAD)"
  run plan "$RC" ""
  echo "$output" | jq -e '.tag == "1.2.51"' > /dev/null
}

@test "plan keeps a v prefix when the repo's release tags use one" {
  git tag v1.3.0 "$(git rev-list --max-parents=0 HEAD)"
  run plan "$RC" ""
  echo "$output" | jq -e '.tag == "v1.3.1" and .version == "1.3.1"' > /dev/null
}

@test "AC3: outside the window the plan is deferred and nothing is written" {
  labels SIG-1 Bug
  NOW=2026-11-07T10:00:00Z run plan "$RC" SIG-1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "deferred" and .next_open == "Mon 2026-11-09 09:00 GMT"' > /dev/null
  [ ! -s "$TMP/calls" ]
  [ -z "$(git tag --points-at "$RC")" ]
}

@test "AC4: a hotfix ticket outside the window goes ahead" {
  labels SIG-1 Bug
  labels SIG-2 Bug hotfix
  NOW=2026-11-07T10:00:00Z run plan "$RC" "SIG-1, SIG-2"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "hotfix" and .tickets == ["SIG-1","SIG-2"]' > /dev/null
}

@test "plan with no tickets (only untracked commits) does not call Linear" {
  unset LINEAR_API_KEY
  run plan "$RC" ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "open" and .tickets == []' > /dev/null
}

@test "plan fails when Linear is down, rather than guess the version or the hotfix" {
  labels SIG-1 Bug
  touch "$TMP/linear-down"
  run plan "$RC" SIG-1
  [ "$status" -ne 0 ]
}

@test "plan fails for a ticket Linear does not know" {
  run plan "$RC" SIG-404
  [ "$status" -ne 0 ]
  grep -q "SIG-404" "$TMP/stderr"
}

@test "idempotent: a commit that already carries a release tag reuses it (resume), even outside the window" {
  git tag 1.2.45 "$RC"
  NOW=2026-11-07T10:00:00Z run plan "$RC" ""
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "resume" and .tag == "1.2.45" and .existing == true and (has("next_open") | not)' > /dev/null
}

# ---- tag: ECR re-put + git tag ---------------------------------------------

@test "AC1: every service gets the release tag on the same digest as the dev build" {
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -eq 0 ]
  for r in signstream/http signstream/websocket; do
    [ "$(digest "$r" 1.2.45)" = "$(digest "$r" "$SRC")" ]
    echo "$output" | jq -e --arg r "$r" --arg d "$(digest "$r" "$SRC")" '.digests[$r] == $d' > /dev/null
  done
  echo "$output" | jq -e '[.images[] | .source_digest == .tag_digest] | all' > /dev/null
  # No rebuild: only manifest re-puts, carrying the stored media type.
  grep -q "put-image signstream/http 1.2.45 application/vnd.oci.image.index.v1+json" "$TMP/calls"
  ! grep -qi "build" "$TMP/calls"
}

@test "AC1: the git commit gets the same tag, after the images" {
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/refs/1.2.45")" = "$RC" ]
  [ "$(tail -1 "$TMP/calls")" = "create-ref 1.2.45 $RC" ]
}

@test "digest mismatch after the re-put fails and leaves git untagged" {
  touch "$TMP/mangle"
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -ne 0 ]
  grep -q "digest mismatch" "$TMP/stderr"
  [ ! -f "$TMP/refs/1.2.45" ]
}

@test "a missing dev image fails before anything is tagged in git" {
  rm "$TMP/ecr/signstream/websocket/$SRC"
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/refs/1.2.45" ]
}

@test "idempotent re-run: nothing is re-put or re-tagged, output is the same" {
  run tag "$RC" "$SRC" 1.2.45
  first="$output"
  : > "$TMP/calls"
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ ! -s "$TMP/calls" ]
  grep -q "no-op" "$TMP/stderr"
}

@test "re-run after a partial failure finishes the job (images done, git tag missing)" {
  run tag "$RC" "$SRC" 1.2.45
  rm "$TMP/refs/1.2.45"
  : > "$TMP/calls"
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/calls")" = "create-ref 1.2.45 $RC" ]
}

@test "an ECR release tag on other bytes is never moved" {
  other="sha256:$(printf x | shasum -a 256 | cut -d' ' -f1)"
  printf x > "$TMP/manifests/$other"
  echo "$other" > "$TMP/ecr/signstream/http/1.2.45"
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -ne 0 ]
  grep -q "refusing to move" "$TMP/stderr"
  [ "$(digest signstream/http 1.2.45)" = "$other" ]
  [ ! -f "$TMP/refs/1.2.45" ]
}

@test "a git tag already on another commit fails" {
  echo 0000000000000000000000000000000000000000 > "$TMP/refs/1.2.45"
  run tag "$RC" "$SRC" 1.2.45
  [ "$status" -ne 0 ]
  grep -q "already exists on 0000000" "$TMP/stderr"
}

@test "empty SERVICES fails" {
  SERVICES='[]' run tag "$RC" "$SRC" 1.2.45
  [ "$status" -ne 0 ]
}

# ---- tickets: On Staging ----------------------------------------------------

@test "AC2: every ticket in the Release Candidate moves to On Staging" {
  run "$S/promotion-tickets.sh" "On Staging" "SIG-1,SIG-2"
  [ "$status" -eq 0 ]
  grep -qx "move SIG-1 state-On_Staging" "$TMP/calls"
  grep -qx "move SIG-2 state-On_Staging" "$TMP/calls"
}

@test "AC2: a failed move fails the step but the other tickets still move" {
  touch "$TMP/move-fail-SIG-1"
  run "$S/promotion-tickets.sh" "On Staging" "SIG-1,SIG-2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SIG-1 (nope)"* ]]
  grep -qx "move SIG-2 state-On_Staging" "$TMP/calls"
}

@test "no tickets: nothing moves and no Linear key is needed" {
  unset LINEAR_API_KEY
  run "$S/promotion-tickets.sh" "On Staging" ""
  [ "$status" -eq 0 ]
  [ ! -s "$TMP/calls" ]
}
