#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell on purpose.
# Lambda services on the release train (SIG-3189): lambda-config.sh,
# s3-artefact-copy.sh, lambda-deploy.sh (staging and prod), lambda-tags.sh
# (what prod runs, through prod-tags.sh), lambda-rollback.sh, and prod-plan.sh
# refusing a tag rolled back from. A stateful fake aws (helpers/fake-aws.bash)
# plays S3 and Lambda; a fake curl plays Linear for prod-plan.sh.
load 'helpers/load'
load 'helpers/fake-aws'

S="$BATS_TEST_DIRNAME/../scripts"
REG=827204657141.dkr.ecr.eu-west-2.amazonaws.com
D1="sha256:$(printf 'a%.0s' {1..64})"
D0="sha256:$(printf '0%.0s' {1..64})"
BUILD=main-12-0123456789abcdef0123456789abcdef01234567

setup() {
  TMP="$(mktemp -d)"
  export TMP
  fake_aws_install "$TMP/aws"
  export LAMBDA_FUNCTIONS='[
    {"name": "platform-api", "package": "zip",
     "function": "{env}-website-translation-v2-platform-api",
     "s3_bucket": {"dev": "dev-global-lambda-s3", "stg": "staging-global-lambda-s3", "prod": "production-global-lambda-s3"},
     "s3_prefix": "website-translation-platform-api"},
    {"name": "screenshot", "package": "image",
     "function": "{env}-website-translation-v2-screenshot",
     "image_repository": "'"$REG"'/website-translation-screenshot"}]'
  # The dev build (main-push), and the screenshot image re-tagged at Promotion.
  s3_put dev-global-lambda-s3 "website-translation-platform-api/${BUILD}.zip" "zip-1.1.0"
  ecr_tag website-translation-screenshot 1.1.0 "$D1"
  ecr_tag website-translation-screenshot 1.0.0 "$D0"
  # Staging and prod run 1.0.0.
  for env in stg prod; do
    lambda_zip "${env}-website-translation-v2-platform-api" "$(b64sha zip-1.0.0)" '{"release-tag": "1.0.0"}'
    lambda_image "${env}-website-translation-v2-screenshot" "$REG/website-translation-screenshot@$D0" '{"release-tag": "1.0.0"}'
  done
  s3_put production-global-lambda-s3 website-translation-platform-api/1.0.0.zip "zip-1.0.0"
}

teardown() { rm -rf "$TMP"; }

promote_stg() {
  TAG=1.1.0 TARGET_ENV=stg SOURCE_ENV=dev SOURCE_ARTEFACT="$BUILD" \
    IMAGE_DIGESTS="{\"website-translation-screenshot\": \"$D1\"}" "$S/lambda-deploy.sh"
}
deploy_prod() {
  TAG=1.1.0 TARGET_ENV=prod SOURCE_ENV=stg SOURCE_ARTEFACT=1.1.0 PREVIOUS_TAGS='{"platform-api": "1.0.0", "screenshot": "1.0.0"}' \
    "$S/lambda-deploy.sh"
}

# --- lambda-config.sh -------------------------------------------------------

@test "config: {env} and per-environment buckets resolve; an image names its ECR repository" {
  run "$S/lambda-config.sh" prod
  [ "$status" -eq 0 ]
  jq -e '.[0] == {name: "platform-api", package: "zip", function: "prod-website-translation-v2-platform-api",
    s3_bucket: "production-global-lambda-s3", s3_prefix: "website-translation-platform-api", image_repository: "", ecr_repository: ""}' <<< "$output"
  jq -e '.[1].function == "prod-website-translation-v2-screenshot" and .[1].ecr_repository == "website-translation-screenshot"' <<< "$output"
}

@test "config: a ZIP without its bucket for the environment, an unknown package or a duplicate name is refused" {
  LAMBDA_FUNCTIONS='[{"name": "a", "package": "zip", "function": "f", "s3_bucket": {"dev": "dev-b"}, "s3_prefix": "p"}]' \
    run "$S/lambda-config.sh" prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"s3_bucket for prod"* ]]
  LAMBDA_FUNCTIONS='[{"name": "a", "package": "jar", "function": "f"}]' run "$S/lambda-config.sh" prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"package must be zip or image"* ]]
  LAMBDA_FUNCTIONS='[{"name": "a", "package": "image", "function": "f", "image_repository": "'"$REG"'/r"},
    {"name": "a", "package": "image", "function": "g", "image_repository": "'"$REG"'/r"}]' run "$S/lambda-config.sh" prod
  [ "$status" -eq 1 ]
  [[ "$output" == *"unique"* ]]
}

# --- s3-artefact-copy.sh ----------------------------------------------------

@test "copy: same bytes under the release name, conditional put, SHA-256 checked" {
  run "$S/s3-artefact-copy.sh" "s3://dev-global-lambda-s3/website-translation-platform-api/${BUILD}.zip" \
    s3://staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip
  [ "$status" -eq 0 ]
  [ "$(cat "$AWS_STATE/s3/staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip")" = zip-1.1.0 ]
  tail -1 <<< "$output" | jq -e --arg b "$(b64sha zip-1.1.0)" '.result == "copied" and .code_sha256 == $b'
}

@test "copy: a release artefact that already holds the same bytes is a no-op" {
  s3_put staging-global-lambda-s3 website-translation-platform-api/1.1.0.zip zip-1.1.0
  run "$S/s3-artefact-copy.sh" "s3://dev-global-lambda-s3/website-translation-platform-api/${BUILD}.zip" \
    s3://staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip
  [ "$status" -eq 0 ]
  tail -1 <<< "$output" | jq -e '.result == "no-op"'
  ! grep -q put-object "$AWS_STATE/calls.log"
}

@test "copy: never replaces a release artefact holding other bytes" {
  s3_put staging-global-lambda-s3 website-translation-platform-api/1.1.0.zip other-bytes
  run "$S/s3-artefact-copy.sh" "s3://dev-global-lambda-s3/website-translation-platform-api/${BUILD}.zip" \
    s3://staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to replace"* ]]
  ! grep -q put-object "$AWS_STATE/calls.log"
  [ "$(cat "$AWS_STATE/s3/staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip")" = other-bytes ]
}

@test "copy: a failed lookup (not NoSuchKey) stops before any write" {
  echo "--bucket staging-global-lambda-s3" > "$AWS_STATE/fail"
  run "$S/s3-artefact-copy.sh" "s3://dev-global-lambda-s3/website-translation-platform-api/${BUILD}.zip" \
    s3://staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read s3://staging"* ]]
  ! grep -q put-object "$AWS_STATE/calls.log"
}

@test "copy: a missing build fails" {
  run "$S/s3-artefact-copy.sh" s3://dev-global-lambda-s3/website-translation-platform-api/main-1-x.zip \
    s3://staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read s3://dev-global-lambda-s3"* ]]
}

# --- lambda-deploy.sh -------------------------------------------------------

@test "AC1/AC5 staging: the ZIP's bytes are dev's, the image is the promoted digest, both carry the release tag" {
  run promote_stg
  [ "$status" -eq 0 ]
  jq -e '.ok and (.moved == ["platform-api", "screenshot"])' <<< "$(tail -1 <<< "$output")"
  [ "$(cat "$AWS_STATE/s3/staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip")" = zip-1.1.0 ]
  [ "$(fn_code stg-website-translation-v2-platform-api)" = "$(b64sha zip-1.1.0)" ]
  [ "$(fn_code stg-website-translation-v2-screenshot)" = "$REG/website-translation-screenshot@$D1" ]
  grep -q "update-function-code stg-website-translation-v2-screenshot $REG/website-translation-screenshot@$D1" "$AWS_STATE/calls.log"
  [ "$(fn_tag stg-website-translation-v2-platform-api release-tag)" = 1.1.0 ]
  [ "$(fn_tag stg-website-translation-v2-screenshot release-tag)" = 1.1.0 ]
  [ -z "$(fn_tag stg-website-translation-v2-platform-api release-deploying)" ]
  grep -q "wait function-updated-v2" "$AWS_STATE/calls.log"
}

@test "a re-run when every function already runs the tag changes nothing" {
  promote_stg > /dev/null
  : > "$AWS_STATE/calls.log"
  run promote_stg
  [ "$status" -eq 0 ]
  jq -e '.ok' <<< "$(tail -1 <<< "$output")"
  ! grep -qE 'update-function-code|tag-resource|put-object' "$AWS_STATE/calls.log"
}

@test "AC2: a function that does not report the new code fails the deploy, and stays untagged" {
  # Lambda keeps the old code (the update silently did nothing).
  cat > "$TMP/aws-wrap" <<EOS
#!/usr/bin/env bash
case "\$*" in *"update-function-code --function-name stg-website-translation-v2-platform-api"*) echo '{}'; exit 0 ;; esac
exec "$AWS_STATE/bin/aws.real" "\$@"
EOS
  mv "$AWS_STATE/bin/aws" "$AWS_STATE/bin/aws.real"
  mv "$TMP/aws-wrap" "$AWS_STATE/bin/aws"
  chmod +x "$AWS_STATE/bin/aws"
  run promote_stg
  [ "$status" -eq 0 ]
  res=$(tail -1 <<< "$output")
  jq -e '(.ok | not) and .moved == [] and (.reason | test("not the release artefact"))' <<< "$res"
  [ "$(fn_tag stg-website-translation-v2-platform-api release-tag)" = 1.0.0 ]
}

@test "AC3 prod: copies staging's release ZIP, records what ran before, then the release tag" {
  promote_stg > /dev/null
  run deploy_prod
  [ "$status" -eq 0 ]
  jq -e '.ok' <<< "$(tail -1 <<< "$output")"
  [ "$(cat "$AWS_STATE/s3/production-global-lambda-s3/website-translation-platform-api/1.1.0.zip")" = zip-1.1.0 ]
  [ "$(fn_code prod-website-translation-v2-platform-api)" = "$(b64sha zip-1.1.0)" ]
  [ "$(fn_tag prod-website-translation-v2-platform-api release-tag)" = 1.1.0 ]
  [ "$(fn_tag prod-website-translation-v2-platform-api release-previous-tag)" = 1.0.0 ]
  [ "$(fn_tag prod-website-translation-v2-platform-api release-previous-code)" = "$(b64sha zip-1.0.0)" ]
  # Prod deploys the image by its release tag; Lambda resolves the promoted digest.
  [ "$(fn_code prod-website-translation-v2-screenshot)" = "$REG/website-translation-screenshot@$D1" ]
  [ "$(fn_tag prod-website-translation-v2-screenshot release-previous-code)" = "$REG/website-translation-screenshot@$D0" ]
}

@test "a failure on the second function reports the first as moved (a partial Deployment)" {
  promote_stg > /dev/null
  echo "--function-name prod-website-translation-v2-screenshot --image-uri" > "$AWS_STATE/fail"
  run deploy_prod
  [ "$status" -eq 0 ]
  jq -e '(.ok | not) and .moved == ["platform-api"] and (.unknown | not)' <<< "$(tail -1 <<< "$output")"
}

@test "a re-run after the code moved but before the release tag keeps the recorded previous code" {
  promote_stg > /dev/null
  # First attempt died after update-function-code: new code, old release-tag.
  echo "--tags {\"release-tag\"" > "$AWS_STATE/fail"
  run deploy_prod
  jq -e '(.ok | not) and .moved == ["platform-api"]' <<< "$(tail -1 <<< "$output")"
  [ "$(fn_tag prod-website-translation-v2-platform-api release-deploying)" = 1.1.0 ]
  rm "$AWS_STATE/fail"
  run deploy_prod
  jq -e '.ok' <<< "$(tail -1 <<< "$output")"
  [ "$(fn_tag prod-website-translation-v2-platform-api release-previous-code)" = "$(b64sha zip-1.0.0)" ]
  [ "$(fn_tag prod-website-translation-v2-platform-api release-previous-tag)" = 1.0.0 ]
}

# --- lambda-tags.sh through prod-tags.sh ------------------------------------

@test "prod-tags.sh reads the functions' tags for Lambda services (no signapse-core-k8s)" {
  promote_stg > /dev/null
  deploy_prod > /dev/null
  PROD_SERVICES='' run "$S/prod-tags.sh" 1.1.0
  [ "$status" -eq 0 ]
  jq -e 'map(.service) == ["platform-api", "screenshot"] and all(.on_tag) and all(.deployed_previous == "1.0.0") and all(.rolled_back | not)' <<< "$output"
  run "$S/prod-tags.sh" --require-all 1.1.0
  [ "$status" -eq 0 ]
  run "$S/prod-tags.sh" --require-all 1.2.0
  [ "$status" -eq 2 ]
  [[ "$output" == "platform-api runs 1.1.0, screenshot runs 1.1.0" ]]
}

@test "a prod function with no release-tag stops the read instead of guessing" {
  lambda_zip prod-website-translation-v2-platform-api "$(b64sha zip-1.0.0)"
  run "$S/prod-tags.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no release-tag tag"* ]]
}

# --- lambda-rollback.sh -----------------------------------------------------

rollback() { SERVICES='["platform-api","screenshot"]' RELEASE_TAG=1.1.0 "$S/lambda-rollback.sh"; }

@test "AC4: rollback restores the previous artefact on every function and records the tag rolled back from" {
  promote_stg > /dev/null
  deploy_prod > /dev/null
  run rollback
  [ "$status" -eq 0 ]
  jq -e '.ok and all(.results[]; .result == "success" and .restored == "1.0.0" and .expected == "1.0.0")' <<< "$(tail -1 <<< "$output")"
  [ "$(fn_code prod-website-translation-v2-platform-api)" = "$(b64sha zip-1.0.0)" ]
  [ "$(fn_code prod-website-translation-v2-screenshot)" = "$REG/website-translation-screenshot@$D0" ]
  for f in prod-website-translation-v2-platform-api prod-website-translation-v2-screenshot; do
    [ "$(fn_tag "$f" release-tag)" = 1.0.0 ]
    [ "$(fn_tag "$f" release-rolled-back-from)" = 1.1.0 ]
    [ -z "$(fn_tag "$f" release-previous-tag)" ]
  done
  # What prod runs now says 1.1.0 was rolled back from.
  run "$S/prod-tags.sh" 1.1.0
  jq -e 'all(.rolled_back) and all(.current_tag == "1.0.0")' <<< "$output"
}

@test "a re-run of the rollback finds it done and changes nothing" {
  promote_stg > /dev/null
  deploy_prod > /dev/null
  rollback > /dev/null
  : > "$AWS_STATE/calls.log"
  run rollback
  jq -e '.ok and all(.results[]; .result == "success")' <<< "$output"
  ! grep -q update-function-code "$AWS_STATE/calls.log"
}

@test "a function already on another tag is left to a human; one with no previous tag is not touched" {
  promote_stg > /dev/null
  deploy_prod > /dev/null
  "$AWS_STATE/bin/aws" lambda tag-resource --resource arn:aws:lambda:eu-west-2:430916267664:function:prod-website-translation-v2-screenshot --tags '{"release-tag":"1.2.0"}'
  "$AWS_STATE/bin/aws" lambda untag-resource --resource arn:aws:lambda:eu-west-2:430916267664:function:prod-website-translation-v2-platform-api --tag-keys release-previous-tag
  : > "$AWS_STATE/calls.log"
  run rollback
  jq -e '(.ok | not) and .needs_human
    and (.results | map({(.service): .result}) | add) == {"platform-api": "no_previous_tag", "screenshot": "not_current"}' <<< "$output"
  ! grep -q update-function-code "$AWS_STATE/calls.log"
}

@test "a restored ZIP that is not the code prod ran before is a failed rollback" {
  promote_stg > /dev/null
  deploy_prod > /dev/null
  s3_put production-global-lambda-s3 website-translation-platform-api/1.0.0.zip "rebuilt-1.0.0"
  run rollback
  jq -e '(.ok | not) and (.results[0].result == "failed") and (.results[0].reason | test("not the code it ran before"))' <<< "$(tail -1 <<< "$output")"
}

# --- prod-plan.sh on a Lambda service ---------------------------------------

@test "prod-plan.sh: deploys a new tag, then refuses it once the rollback moved prod off it" {
  mkdir -p "$TMP/stub"
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
body=""; prev=""
for a in "$@"; do [ "$prev" = -d ] && body="$a"; prev="$a"; done
id=$(jq -r .variables.id <<< "$body")
jq -c --arg id "$id" 'if has($id) then .[$id] as $i
  | {data: {issue: {identifier: $id, state: {name: $i.state}, labels: {nodes: [$i.labels[] | {name: .}]}}}}
  else {errors: [{message: "Entity not found: Issue"}], data: null} end' "$TMP/linear.json"
printf '\n200'
EOS
  chmod +x "$TMP/stub/curl"
  echo '{"SIG-1": {"state": "On Staging", "labels": ["QA Passed", "Staging Passed"]}}' > "$TMP/linear.json"
  git init -q -b main "$TMP/repo"
  cd "$TMP/repo"
  git config user.email t@example.com
  git config user.name t
  git commit -q --allow-empty -m init
  git tag 1.0.0
  git commit -q --allow-empty -m "SIG-1 fix"
  git tag 1.1.0
  export PATH="$TMP/stub:$PATH" LINEAR_API_KEY=x NOW=2026-11-02T10:00:00Z PROD_SERVICES=''

  RELEASE_TAG=1.1.0 run "$S/prod-plan.sh"
  [ "$status" -eq 0 ]
  jq -e '.decision == "deploy" and .to_deploy == ["platform-api", "screenshot"]
    and .previous_tags == {"platform-api": "1.0.0", "screenshot": "1.0.0"} and .base == "1.0.0" and .tickets == ["SIG-1"]' <<< "$output"

  promote_stg > /dev/null
  deploy_prod > /dev/null
  rollback > /dev/null
  RELEASE_TAG=1.1.0 run "$S/prod-plan.sh"
  jq -e '.decision == "refused" and (.reason | test("rolled back from"))' <<< "$output"
  RESUME_TAG=1.1.0 run "$S/prod-plan.sh"
  jq -e '.decision == "nothing"' <<< "$output"
}

# --- the Promotion's order: artefacts, then tags, then the deploy -----------

@test "ARTEFACTS_ONLY puts the release ZIP in place and deploys nothing" {
  ARTEFACTS_ONLY=true run promote_stg
  [ "$status" -eq 0 ]
  jq -e '.ok and .moved == []' <<< "$(tail -1 <<< "$output")"
  [ "$(cat "$AWS_STATE/s3/staging-global-lambda-s3/website-translation-platform-api/1.1.0.zip")" = zip-1.1.0 ]
  ! grep -qE 'update-function-code|tag-resource' "$AWS_STATE/calls.log"
}

@test "promotion-tag.sh tags git alone for a Lambda service with no image" {
  mkdir -p "$TMP/stub"
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
echo "gh $*" >> "$TMP/gh.log"
echo '{}'
EOS
  chmod +x "$TMP/stub/gh"
  sha=0123456789abcdef0123456789abcdef01234567
  PATH="$TMP/stub:$PATH" GITHUB_REPOSITORY=signapse/x GH_TOKEN=x SERVICES='[]' \
    run "$S/promotion-tag.sh" "$sha" "$BUILD" 1.1.0
  [ "$status" -eq 0 ]
  jq -e '.digests == {} and .images == [] and .tag == "1.1.0"' <<< "$(tail -1 <<< "$output")"
  grep -q "refs/tags/1.1.0" "$TMP/gh.log"
  # Without LAMBDA_FUNCTIONS an empty SERVICES is still an error (k8s path).
  LAMBDA_FUNCTIONS='' PATH="$TMP/stub:$PATH" GITHUB_REPOSITORY=signapse/x GH_TOKEN=x SERVICES='[]' \
    run "$S/promotion-tag.sh" "$sha" "$BUILD" 1.1.0
  [ "$status" -eq 1 ]
}
