#!/usr/bin/env bash
# lambda-config.sh <dev|stg|prod>
#
# Resolves the `lambda_functions` input (SIG-3189) for one environment. A repo
# whose services are Lambda functions lists them once; each entry is either a
# ZIP function whose code lives in S3 or a container-image function whose
# image lives in the shared ECR:
#
#   [{"name": "platform-api", "package": "zip",
#     "function": "{env}-website-translation-v2-platform-api",
#     "s3_bucket": {"dev": "dev-global-lambda-s3", "stg": "staging-global-lambda-s3",
#                   "prod": "production-global-lambda-s3"},
#     "s3_prefix": "website-translation-platform-api"},
#    {"name": "screenshot", "package": "image",
#     "function": "{env}-website-translation-v2-screenshot",
#     "image_repository": "827204657141.dkr.ecr.eu-west-2.amazonaws.com/website-translation-screenshot"}]
#
# `function` and `s3_bucket` are a string, where {env} becomes the
# environment, or an object keyed by environment. `name` is the service name
# the train reports (previous_tags, moved_services, rollback results).
#
# Artefacts (build once, ADR 0001):
#   zip    s3://<bucket>/<s3_prefix>/<artefact>.zip, where <artefact> is
#          main-<run_number>-<sha> (the build) or the release tag
#   image  <image_repository>:<artefact>, re-tagged by ecr-retag.sh
#
# Env: LAMBDA_FUNCTIONS (required)
# Stdout: [{name, package, function, s3_bucket, s3_prefix, image_repository,
#           ecr_repository}] with every value resolved for the environment;
#           ecr_repository is image_repository's path (ecr-retag.sh's repo).
# Exits 1 on any invalid entry: a guess here deploys the wrong function.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need jq
[ $# -eq 1 ] || die "usage: lambda-config.sh <dev|stg|prod>"
ENV_NAME="$1"
case "$ENV_NAME" in dev | stg | prod) ;; *) die "environment must be dev, stg or prod (got '$ENV_NAME')" ;; esac
: "${LAMBDA_FUNCTIONS:?LAMBDA_FUNCTIONS not set}"

# shellcheck disable=SC2016 # jq program, not shell expansion.
out=$(jq -c --arg env "$ENV_NAME" '
  def per_env($f): if type == "object" then (.[$env] // "") elif type == "string" then gsub("\\{env\\}"; $env) else "" end;
  def bad($m): error($m);
  if type != "array" or length == 0 then bad("lambda_functions must be a non-empty JSON array") else . end
  | if ([.[].name] | unique | length) != length then bad("lambda_functions names must be unique") else . end
  | map(
      . as $e
      | (($e.name // "") | if test("^[a-z0-9][a-z0-9-]{0,62}$") then . else bad("bad name \(tojson)") end) as $name
      | (($e.function // "") | per_env($env)) as $fn
      | if ($fn | test("^(arn:aws:lambda:[a-z0-9-]+:[0-9]{12}:function:)?[A-Za-z0-9_-]{1,64}$")) then . else bad("\($name): function for \($env) is missing or not a Lambda name (\($fn | tojson))") end
      | {name: $name, package: ($e.package // ""), function: $fn,
         s3_bucket: "", s3_prefix: "", image_repository: "", ecr_repository: ""}
      | if .package == "zip" then
          (($e.s3_bucket // "") | per_env($env)) as $b
          | ($e.s3_prefix // "" | sub("/+$"; "")) as $p
          | if ($b | test("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")) | not then bad("\($name): s3_bucket for \($env) is missing or invalid (\($b | tojson))")
            elif ($p | test("^[A-Za-z0-9!_.*()/-]+$")) | not then bad("\($name): s3_prefix is required (the key prefix of the ZIP artefacts)")
            else .s3_bucket = $b | .s3_prefix = $p end
        elif .package == "image" then
          ($e.image_repository // "") as $r
          | if ($r | test("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9][a-z0-9._/-]*$")) | not
            then bad("\($name): image_repository must be <account>.dkr.ecr.<region>.amazonaws.com/<repo> (got \($r | tojson))")
            else .image_repository = $r | .ecr_repository = ($r | sub("^[^/]+/"; "")) end
        else bad("\($name): package must be zip or image (got \(.package | tojson))") end)
' <<< "$LAMBDA_FUNCTIONS" 2>&1) || die "invalid lambda_functions: ${out#jq: error (at <stdin>:*): }"
printf '%s\n' "$out"
