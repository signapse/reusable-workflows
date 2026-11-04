#!/usr/bin/env bash
# prod-tags.sh [<release-tag>]
#
# Read-only: which image tag each service runs in prod, read from
# signapse-core-k8s the same way deploy-prod.yml picks the file it edits
# (SIG-2769):
#   shared   workloads/prod-common/<svc>/image-tag-patch.yaml, when it exists
#            and workloads/prod-us/<svc> does too (EU + US from one tag)
#   EU-only  workloads/prod/<svc>/helmrelease-patch.yaml
# The tag is .spec.values.image.tag. Without <release-tag> only current_tag is
# meaningful (selection-base.sh, SIG-2761). The file's commit history also says:
#   rolled_back        rollback.yml has replaced <release-tag> on this service
#                      (a "Rolled-back-from: <release-tag>" trailer). The
#                      train must never deploy that tag again by itself.
#   deployed_previous  the "Previous:" line of deploy-prod's latest
#                      "deploy(prod): <svc> → <release-tag>" commit, i.e. what
#                      ran before this tag. Recovers the previous tag on a
#                      re-run after the deploy already happened (SIG-2771
#                      needs it for the rollback).
#
# Env:
#   PROD_SERVICES  JSON array of deploy-prod.yml service names (required)
#   GITOPS_REPO    default signapse/signapse-core-k8s
#   GITOPS_REF     default main
#   GH_TOKEN       contents:read on GITOPS_REPO (the read-only pipeline app)
# Stdout: [{service, path, current_tag, on_tag, rolled_back, deployed_previous}]
# Exits 1 when a service has no prod patch file or the API fails: a guess
# here could deploy over, or skip, a service.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -le 1 ] || die "usage: prod-tags.sh [<release-tag>]"
TAG="${1:-}"
need gh
need jq
need yq

: "${PROD_SERVICES:?PROD_SERVICES not set}"
GITOPS_REPO="${GITOPS_REPO:-signapse/signapse-core-k8s}"
GITOPS_REF="${GITOPS_REF:-main}"

services=$(jq -r 'if type == "array" and length > 0 and all(type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
  then .[] else error("bad") end' <<< "$PROD_SERVICES" 2> /dev/null) \
  || die "PROD_SERVICES must be a non-empty JSON array of deploy-prod service names (got '$PROD_SERVICES')"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# exists <path>: 0 if the path exists at GITOPS_REF, 1 on 404, dies otherwise.
exists() {
  if gh api "repos/${GITOPS_REPO}/contents/$1?ref=${GITOPS_REF}" > /dev/null 2> "$work/err"; then
    return 0
  fi
  grep -q 'HTTP 404' "$work/err" && return 1
  die "reading ${GITOPS_REPO}/$1 failed: $(cat "$work/err")"
}

out='[]'
while IFS= read -r svc; do
  if exists "workloads/prod-common/${svc}/image-tag-patch.yaml" && exists "workloads/prod-us/${svc}"; then
    path="workloads/prod-common/${svc}/image-tag-patch.yaml"
  else
    path="workloads/prod/${svc}/helmrelease-patch.yaml"
  fi
  content=$(gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/${GITOPS_REPO}/contents/${path}?ref=${GITOPS_REF}" 2> "$work/err") \
    || die "no prod patch file for ${svc} (${path}): $(cat "$work/err")"
  current=$(yq '.spec.values.image.tag // ""' <<< "$content" 2> /dev/null) \
    || die "${path} is not valid YAML"
  [ -n "$current" ] && [ "$current" != null ] || die "${path} has no .spec.values.image.tag"

  hist=$(gh api "repos/${GITOPS_REPO}/commits?sha=${GITOPS_REF}&path=${path}&per_page=100" 2> "$work/err") \
    || die "reading the history of ${path} failed: $(cat "$work/err")"
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  facts=$(jq -c --arg t "$TAG" --arg s "$svc" '
    [.[]?.commit.message | split("\n") | map(sub("^\\s+"; "") | sub("\\s+$"; ""))] as $msgs
    | {rolled_back: any($msgs[][]; . == "Rolled-back-from: " + $t),
       deployed_previous: (first($msgs[] | select(.[0] == "deploy(prod): \($s) → \($t)")
                                 | .[] | select(startswith("Previous:")) | sub("^Previous:\\s*"; "")) // "")}' \
    <<< "$hist") || die "unexpected commit list for ${path}"

  out=$(jq -c --argjson a "$out" --argjson f "$facts" --arg s "$svc" --arg p "$path" --arg c "$current" --arg t "$TAG" \
    '$a + [{service: $s, path: $p, current_tag: $c, on_tag: ($t != "" and $c == $t)} + $f]' <<< 'null')
done <<< "$services"
echo "$out"
