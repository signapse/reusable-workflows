# Stateful fake `aws` for the Lambda release-train tests (SIG-3189).
#
# State under $AWS_STATE:
#   s3/<bucket>/<key>            objects
#   lambda/<function>.json       get-function output (Configuration, Code, Tags)
#   ecr/<repo>/<tag>             digest an image tag names
#   calls.log                    every mutating call, one per line
#   fail                         optional: lines "<substring>" make a call whose
#                                arguments contain it fail (exit 254)
# Helpers: fake_aws_install, s3_put <bucket> <key> <content>,
# lambda_zip <function> <code_sha256_b64> [tags-json],
# lambda_image <function> <resolved-uri> [tags-json], ecr_tag <repo> <tag> <digest>,
# b64sha <content>.

fake_aws_install() {
  export AWS_STATE="$1"
  mkdir -p "$AWS_STATE/s3" "$AWS_STATE/lambda" "$AWS_STATE/ecr" "$AWS_STATE/bin"
  : > "$AWS_STATE/calls.log"
  cat > "$AWS_STATE/bin/aws" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
S="$AWS_STATE"
all="$*"
if [ -f "$S/fail" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] && [[ "$all" == *"$pat"* ]] && { echo "An error occurred (InjectedFailure): $pat" >&2; exit 254; }
  done < "$S/fail"
fi
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
fnfile() { echo "$S/lambda/$1.json"; }
b64() { openssl dgst -sha256 -binary "$1" | base64; }
svc="$1 $2"; shift 2
case "$svc" in
  "s3api get-object")
    f="$S/s3/$(arg --bucket "$@")/$(arg --key "$@")"
    [ -f "$f" ] || { echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist." >&2; exit 254; }
    cp "$f" "${!#}"; echo '{}' ;;
  "s3api put-object")
    f="$S/s3/$(arg --bucket "$@")/$(arg --key "$@")"
    echo "put-object $(arg --bucket "$@")/$(arg --key "$@")" >> "$S/calls.log"
    if [ -n "$(arg --if-none-match "$@")" ] && [ -f "$f" ]; then
      echo "An error occurred (PreconditionFailed) when calling the PutObject operation" >&2; exit 254
    fi
    [ "$(b64 "$(arg --body "$@")")" = "$(arg --checksum-sha256 "$@")" ] || { echo "An error occurred (BadDigest)" >&2; exit 254; }
    mkdir -p "$(dirname "$f")"; cp "$(arg --body "$@")" "$f"; echo '{}' ;;
  "lambda get-function")
    f=$(fnfile "$(arg --function-name "$@")")
    [ -f "$f" ] || { echo "An error occurred (ResourceNotFoundException)" >&2; exit 254; }
    cat "$f" ;;
  "lambda update-function-code")
    name=$(arg --function-name "$@"); f=$(fnfile "$name")
    [ -f "$f" ] || { echo "An error occurred (ResourceNotFoundException)" >&2; exit 254; }
    if uri=$(arg --image-uri "$@") && [ -n "$uri" ]; then
      echo "update-function-code $name $uri" >> "$S/calls.log"
      if [[ "$uri" == *@sha256:* ]]; then resolved="$uri"; else
        repo="${uri%:*}"; t="${uri##*:}"; d="$S/ecr/${repo#*/}/$t"
        [ -f "$d" ] || { echo "An error occurred (InvalidParameterValueException): image not found" >&2; exit 254; }
        resolved="${repo}@$(cat "$d")"
      fi
      jq --arg u "$resolved" '.Code.ResolvedImageUri = $u | .Configuration.LastUpdateStatus = "Successful"' "$f" > "$f.n" && mv "$f.n" "$f"
    else
      o="$S/s3/$(arg --s3-bucket "$@")/$(arg --s3-key "$@")"
      echo "update-function-code $name s3://$(arg --s3-bucket "$@")/$(arg --s3-key "$@")" >> "$S/calls.log"
      [ -f "$o" ] || { echo "An error occurred (InvalidParameterValueException): S3 key does not exist" >&2; exit 254; }
      jq --arg c "$(b64 "$o")" '.Configuration.CodeSha256 = $c | .Configuration.LastUpdateStatus = "Successful"' "$f" > "$f.n" && mv "$f.n" "$f"
    fi
    echo '{}' ;;
  "lambda wait") echo "wait $*" >> "$S/calls.log" ;;
  "lambda tag-resource")
    arn=$(arg --resource "$@"); f=$(fnfile "${arn##*:function:}")
    echo "tag-resource ${arn##*:function:} $(arg --tags "$@")" >> "$S/calls.log"
    jq --argjson t "$(arg --tags "$@")" '.Tags = ((.Tags // {}) + $t)' "$f" > "$f.n" && mv "$f.n" "$f" ;;
  "lambda untag-resource")
    arn=$(arg --resource "$@"); f=$(fnfile "${arn##*:function:}")
    keys=(); seen=false
    for a in "$@"; do if [ "$a" = --tag-keys ]; then seen=true; elif $seen; then [[ "$a" == --* ]] && break; keys+=("$a"); fi; done
    echo "untag-resource ${arn##*:function:} ${keys[*]}" >> "$S/calls.log"
    jq '.Tags = ((.Tags // {}) | with_entries(select(.key as $k | $ARGS.positional | index($k) | not)))' --args "${keys[@]}" < "$f" > "$f.n" && mv "$f.n" "$f" ;;
  *) echo "fake aws: unhandled: $svc $*" >&2; exit 99 ;;
esac
FAKE
  chmod +x "$AWS_STATE/bin/aws"
  export PATH="$AWS_STATE/bin:$PATH"
}

b64sha() { printf '%s' "$1" | openssl dgst -sha256 -binary | base64; }

s3_put() { mkdir -p "$AWS_STATE/s3/$1/$(dirname "$2")"; printf '%s' "$3" > "$AWS_STATE/s3/$1/$2"; }

lambda_zip() {
  jq -nc --arg f "$1" --arg c "$2" --argjson t "${3:-{\}}" '{Configuration: {FunctionName: $f,
    FunctionArn: "arn:aws:lambda:eu-west-2:430916267664:function:\($f)", PackageType: "Zip", CodeSha256: $c,
    State: "Active", LastUpdateStatus: "Successful"}, Code: {}, Tags: $t}' > "$AWS_STATE/lambda/$1.json"
}

lambda_image() {
  jq -nc --arg f "$1" --arg u "$2" --argjson t "${3:-{\}}" '{Configuration: {FunctionName: $f,
    FunctionArn: "arn:aws:lambda:eu-west-2:430916267664:function:\($f)", PackageType: "Image", CodeSha256: "x",
    State: "Active", LastUpdateStatus: "Successful"}, Code: {ResolvedImageUri: $u}, Tags: $t}' > "$AWS_STATE/lambda/$1.json"
}

ecr_tag() { mkdir -p "$AWS_STATE/ecr/$1"; printf '%s' "$3" > "$AWS_STATE/ecr/$1/$2"; }

fn_tag() { jq -r --arg k "$2" '.Tags[$k] // ""' "$AWS_STATE/lambda/$1.json"; }
fn_code() { jq -r 'if .Configuration.PackageType == "Image" then .Code.ResolvedImageUri else .Configuration.CodeSha256 end' "$AWS_STATE/lambda/$1.json"; }
