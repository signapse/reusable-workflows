#!/usr/bin/env bash
# staging-deploy-wait.sh
#
# Waits, with a hard time limit, until staging runs release tag TAG (or a
# higher semver, which contains it because main is linear).
#
# Same signal as SIG-2759's dev-deploy-wait.sh (reusable-workflows #39): Flux
# image automation commits the tag its ImagePolicy picked into the GitOps repo
# (signapse-core-k8s workloads/stg/<service>/helmrelease-patch.yaml, the line
# carrying the {"$imagepolicy": ...} setter). That commit is the only
# cluster-side fact readable from GitHub without cluster credentials. Then:
#   * poll every VERSION_URL until the value VERSION_JQ picks from each JSON
#     body is TAG (with or without a leading v) or higher. One URL per
#     promoted service that serves one (review fix): one service reporting
#     the tag says nothing about another's rollout.
# VERSION_URL is required (review fix, SIG-2764): a Flux commit only says the
# tag was chosen, not that pods run it, and a fixed sleep let staging tests
# run against the old pods. No URL fails before any wait.
# Follow-up: once #39 lands, fold both into one script with an environment
# parameter (dev matches main-<n>, staging and prod match semver).
#
# Env:
#   GITOPS_REPO      owner/repo of the Flux repo (default signapse/signapse-core-k8s)
#   GITOPS_REF       branch Flux writes to (default main)
#   WATCH_PATHS      newline- or comma-separated files in GITOPS_REPO (required)
#   TAG              release tag to wait for, e.g. 1.2.45 or v1.2.45 (required)
#   VERSION_URL      newline- or comma-separated URLs whose JSON body names the
#                    running version, one per service that has one (required)
#   VERSION_JQ       jq path to that value (default .version)
#   TIMEOUT_SECONDS  total budget (default 1200)
#   POLL_SECONDS     poll interval (default 20)
# Needs GH_TOKEN with contents:read on GITOPS_REPO.
# Exit 0 when staging runs TAG or newer, 1 on timeout or bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need gh
need jq

GITOPS_REPO="${GITOPS_REPO:-signapse/signapse-core-k8s}"
GITOPS_REF="${GITOPS_REF:-main}"
: "${TAG:?TAG not set}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"
POLL_SECONDS="${POLL_SECONDS:-20}"
VERSION_URL="${VERSION_URL:-}"
VERSION_JQ="${VERSION_JQ:-.version}"

[ -n "$VERSION_URL" ] || die "VERSION_URL (staging_version_url) is required: without it nothing confirms staging runs ${TAG:-the tag}"
for n in "$TIMEOUT_SECONDS" "$POLL_SECONDS"; do
  case "$n" in "" | *[!0-9]*) die "numeric env expected, got '$n'" ;; esac
done
[ "$POLL_SECONDS" -gt 0 ] || die "POLL_SECONDS must be > 0"
SEMVER='^v?([0-9]+)\.([0-9]+)\.([0-9]+)$'
[[ "$TAG" =~ $SEMVER ]] || die "TAG must be semver, got '$TAG'"
WANT="${TAG#v}"

paths=$(printf '%s\n' "${WATCH_PATHS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
[ -n "$paths" ] || die "WATCH_PATHS is empty: list the GitOps files Flux updates for this repo's staging services"

# at_least <version>: true when <version> (v optional) is semver >= WANT.
at_least() {
  local v="${1#v}"
  [[ "$1" =~ $SEMVER ]] || return 1
  [ "$(printf '%s\n%s\n' "$WANT" "$v" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$WANT" ]
}

# Highest semver tag on the $imagepolicy setter lines of the text on stdin.
setter_tag() {
  # shellcheck disable=SC2016 # literal $imagepolicy marker, not an expansion.
  { grep -F '$imagepolicy' || true; } \
    | { grep -oE "tag: *[\"']?v?[0-9]+\.[0-9]+\.[0-9]+[\"']?" || true; } \
    | sed -E "s/tag: *[\"']?//; s/[\"']$//" \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

elapsed=0
tick() {
  if [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
    die "timed out after ${TIMEOUT_SECONDS}s: $1"
  fi
  sleep "$POLL_SECONDS"
  elapsed=$((elapsed + POLL_SECONDS))
}

summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; }

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT

# Phase 1: Flux has committed TAG (or newer) to every watched file.
pending="$paths"
while :; do
  still=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! body=$(gh api -H 'Accept: application/vnd.github.raw+json' \
      "repos/${GITOPS_REPO}/contents/${p}?ref=${GITOPS_REF}" 2>"$errf"); then
      body=""
      err=$(cat "$errf")
      if [[ "$err" =~ HTTP\ (401|403|404) ]]; then
        die "cannot read ${GITOPS_REPO}/${p}@${GITOPS_REF} (HTTP ${BASH_REMATCH[1]}): check staging_watch_paths and that the read app is installed on ${GITOPS_REPO}. ${err}"
      fi
      log "transient error reading ${p}, retrying: ${err}"
    fi
    have=$(printf '%s' "$body" | setter_tag)
    if [ -n "$have" ] && at_least "$have"; then
      log "Flux committed ${have} to ${p}"
    else
      log "waiting for Flux: ${p} is at ${have:-?}, want >= ${TAG}"
      still+="$p"$'\n'
    fi
  done <<< "$pending"
  pending="$still"
  [ -n "$pending" ] || break
  tick "Flux did not commit ${TAG} (or newer) to: $(printf '%s' "$pending" | paste -sd, -). Check the staging ImagePolicy accepts ${TAG} and no higher semver tag exists in ECR."
done

# Phase 2: the cluster has applied it, on every service with a version URL.
need curl
pending=$(printf '%s\n' "$VERSION_URL" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
while :; do
  still=""
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    body=$(curl -fsS --max-time 10 "$u" 2>/dev/null || true)
    running=$(printf '%s' "$body" | jq -r "($VERSION_JQ) // empty | strings" 2>/dev/null || true)
    if [[ "$running" != *$'\n'* ]] && at_least "$running"; then
      log "staging runs ${running} at ${u}"
      summary "Staging deploy confirmed: ${u} reports \`${running}\` (wanted ${TAG} or newer)."
    else
      log "waiting for ${u} to report ${TAG} or newer (now '${running}')"
      still+="$u"$'\n'
    fi
  done <<< "$pending"
  pending="$still"
  [ -n "$pending" ] || break
  tick "never reported ${TAG} (or newer): $(printf '%s' "$pending" | paste -sd, -)"
done

log "staging is running ${TAG} or newer"
