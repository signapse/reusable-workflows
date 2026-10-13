#!/usr/bin/env bash
# rollback.sh <service> <tag>
#
# Validates tag in ECR, runs serialization detector to gather warning text,
# opens + auto-merges a cross-repo PR on signapse/signapse-core-k8s pinning
# the Helm image tag. Prints PR URL on stdout (the only thing on stdout).
# Warning banner (if any) goes to stderr, prefixed "WARNING: ".

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/gh_api.sh
source "$(dirname "$0")/../lib/gh_api.sh"

[ $# -eq 2 ] || die "usage: rollback.sh <service> <tag>"
SERVICE="$1"; TAG="$2"

case "$SERVICE" in
  http|websocket|pip-worker) ;;
  *) die "invalid service: $SERVICE (want http|websocket|pip-worker)" ;;
esac

need aws; need git; need gh; need jq
: "${SIGNAPSE_CORE_K8S_PAT:?}"

REGION=eu-west-2
REPO="signstream/${SERVICE}"

# 1. Validate tag exists in ECR.
aws ecr describe-images --region "$REGION" \
  --repository-name "$REPO" \
  --image-ids "imageTag=$TAG" > /dev/null \
  || die "tag not found in ECR: $REPO:$TAG"

# 2. Serialization detector — target tag -> HEAD. Failure/empty is treated
# as "no warning" so a detector hiccup never blocks a rollback.
HERE="$(dirname "$0")"
DETECTOR="${SERIALIZATION_SCRIPT:-$HERE/serialization-detector.sh}"
warn_json=$("$DETECTOR" "$TAG" HEAD 2>/dev/null || echo '{"touched":false,"files":[]}')
warn_text=""
if echo "$warn_json" | jq -e '.touched' > /dev/null 2>&1; then
  files=$(echo "$warn_json" | jq -r '.files | join(", ")')
  warn_text="Serialization-adjacent files changed since ${TAG}: ${files}. Independent per-service rollback may corrupt cross-service data. Consider rolling back all three services together."
fi

# 3. Clone k8s repo (using PAT).
WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

GH_TOKEN="$SIGNAPSE_CORE_K8S_PAT" gh repo clone signapse/signapse-core-k8s "$WORKDIR/k8s" -- --depth=1 > /dev/null
cd "$WORKDIR/k8s"
BRANCH="rollback-${SERVICE}-${TAG}-$(date +%s)"
git checkout -q -b "$BRANCH" > /dev/null 2>&1

# 4. Edit Helm values (convention: charts/signstream/values-<service>.yaml, key `image.tag`).
VALUES="charts/signstream/values-${SERVICE}.yaml"
[ -f "$VALUES" ] || die "expected file missing: $VALUES"
# Pin exact tag (single line; format assumed `  tag: "1.2.20"`).
sed -i.bak -E "s|^([[:space:]]*tag:[[:space:]]*).*\$|\\1\"${TAG}\"|" "$VALUES" && rm -f "${VALUES}.bak"
git add "$VALUES"
git -c user.email=release-train@signapse.ai -c user.name="Release Train Bot" \
    commit -q -m "Rollback signstream/${SERVICE} to ${TAG}" > /dev/null
# Push with PAT embedded in the URL — no ambient git credential helper in CI.
push_url="${ROLLBACK_PUSH_URL_OVERRIDE:-https://x-access-token:${SIGNAPSE_CORE_K8S_PAT}@github.com/signapse/signapse-core-k8s.git}"
git push -q "$push_url" "HEAD:$(git rev-parse --abbrev-ref HEAD)" > /dev/null 2>&1

# 5. Open PR + auto-merge.
body="Automated rollback."
if [ -n "$warn_text" ]; then
  body="$body

WARNING: $warn_text"
fi

pr_url=$(GH_TOKEN="$SIGNAPSE_CORE_K8S_PAT" gh pr create \
  --repo signapse/signapse-core-k8s \
  --title "Rollback signstream/${SERVICE} to ${TAG}" \
  --body "$body")

GH_TOKEN="$SIGNAPSE_CORE_K8S_PAT" gh pr merge --repo signapse/signapse-core-k8s --squash --auto "$pr_url" > /dev/null 2>&1 || true

if [ -n "$warn_text" ]; then
  echo "WARNING: $warn_text" >&2
fi

echo "$pr_url"
