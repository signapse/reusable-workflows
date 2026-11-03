#!/usr/bin/env bash
# check-workflow-links.sh [path...]
#
# Fails if any https://github.com/signapse/<repo>/actions/workflows/<file> link
# in the given files/dirs (default: .github/workflows actions; test/ and
# testdata/ dirs are skipped, they hold deliberately broken fixtures) names a workflow
# file that does not exist. Catches typos like deploy-to-prod.yml vs
# deploy-prod.yml (SIG-2754) in the links the release train posts to Slack.
#
# Two modes:
#   - GH_TOKEN set: ask the GitHub API whether the file exists on the target
#     repo's default branch. The token must be able to read every linked repo
#     (signapse-core-k8s is private, so the CI GITHUB_TOKEN is not enough).
#   - GH_TOKEN empty: compare each link against the checked-in allow-list
#     (WORKFLOW_LINKS_ALLOWLIST, default ../workflow-links.allowlist), one
#     <repo>/<file> per line. Offline and deterministic, but only as correct
#     as the allow-list: a rename in the target repo is not noticed.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

ALLOWLIST="${WORKFLOW_LINKS_ALLOWLIST:-$(dirname "$0")/../workflow-links.allowlist}"
[ $# -gt 0 ] || set -- .github/workflows actions
for p in "$@"; do [ -e "$p" ] || die "no such path: $p"; done

links=$(grep -rhoE --exclude-dir=test --exclude-dir=testdata 'https://github\.com/signapse/[A-Za-z0-9._-]+/actions/workflows/[A-Za-z0-9._-]+\.ya?ml' "$@" \
  | sed -E 's|https://github\.com/signapse/([^/]+)/actions/workflows/(.+)|\1/\2|' \
  | sort -u || true)

[ -n "$links" ] || { log "no workflow links found"; exit 0; }

if [ -n "${GH_TOKEN:-}" ]; then
  need gh
  mode="GitHub API"
else
  [ -f "$ALLOWLIST" ] || die "allow-list not found: $ALLOWLIST"
  mode="allow-list $ALLOWLIST"
fi

bad=0
for link in $links; do
  repo="${link%%/*}"
  file="${link#*/}"
  if [ -n "${GH_TOKEN:-}" ]; then
    gh api "repos/signapse/$repo/contents/.github/workflows/$file" --silent > /dev/null 2>&1 && ok=1 || ok=0
  else
    grep -qxF "$link" "$ALLOWLIST" && ok=1 || ok=0
  fi
  if [ "$ok" = 1 ]; then
    log "ok      signapse/$repo .github/workflows/$file"
  else
    log "MISSING signapse/$repo .github/workflows/$file (checked via $mode)"
    bad=1
  fi
done

[ "$bad" = 0 ] || die "workflow links point at files that do not exist"
