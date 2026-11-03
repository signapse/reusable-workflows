#!/usr/bin/env bash
# dev-deploy-wait.sh
#
# Waits, with a hard time limit, until dev is running this build's image
# (main-<RUN_NUMBER>-<SHA>) or a newer main-<n> build, which contains it because
# main is linear.
#
# Signal: Flux image automation commits the tag it picked into the GitOps repo
# (signapse-core-k8s workloads/dev/<service>/helmrelease-patch.yaml). Each
# WATCH_PATHS file must name main-<n> with n >= RUN_NUMBER. That commit is the
# only cluster-side fact readable from GitHub without cluster credentials. Flux
# then needs up to source (1m) + Kustomization (2m) + HelmRelease (2m) intervals
# plus the pod rollout to apply it, so the script then:
#   * polls VERSION_URL until its body names this SHA or a main-<n> tag with
#     n >= RUN_NUMBER, when the service exposes one; otherwise
#   * waits SETTLE_SECONDS.
#
# Env:
#   GITOPS_REPO      owner/repo of the Flux repo (default signapse/signapse-core-k8s)
#   GITOPS_REF       branch Flux writes to (default main)
#   WATCH_PATHS      newline- or comma-separated file paths in GITOPS_REPO (required)
#   RUN_NUMBER, SHA  identify this build's tag (required)
#   VERSION_URL      optional URL whose body names the running build
#   SETTLE_SECONDS   wait after the Flux commit when VERSION_URL is unset (default 240)
#   TIMEOUT_SECONDS  total budget (default 1200)
#   POLL_SECONDS     poll interval (default 20)
# Needs GH_TOKEN with contents:read on GITOPS_REPO.
# Exit 0 when dev runs the build, 1 on timeout or bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need gh
need curl

GITOPS_REPO="${GITOPS_REPO:-signapse/signapse-core-k8s}"
GITOPS_REF="${GITOPS_REF:-main}"
: "${RUN_NUMBER:?RUN_NUMBER not set}"
: "${SHA:?SHA not set}"
SETTLE_SECONDS="${SETTLE_SECONDS:-240}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"
POLL_SECONDS="${POLL_SECONDS:-20}"
VERSION_URL="${VERSION_URL:-}"

for n in "$RUN_NUMBER" "$SETTLE_SECONDS" "$TIMEOUT_SECONDS" "$POLL_SECONDS"; do
  case "$n" in "" | *[!0-9]*) die "numeric env expected, got '$n'" ;; esac
done
[ "$POLL_SECONDS" -gt 0 ] || die "POLL_SECONDS must be > 0"

paths=$(printf '%s\n' "${WATCH_PATHS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
[ -n "$paths" ] || die "WATCH_PATHS is empty: list the GitOps files Flux updates for this repo's dev services"

elapsed=0
tick() {
  # Sleep one poll interval; fail once the budget is spent.
  if [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
    die "timed out after ${TIMEOUT_SECONDS}s: $1"
  fi
  sleep "$POLL_SECONDS"
  elapsed=$((elapsed + POLL_SECONDS))
}

# Largest main-<n> run number named in the text on stdin, or empty.
max_run() {
  (grep -oE 'main-[0-9]+-[0-9a-f]{40}' || true) | cut -d- -f2 | sort -n | tail -1
}

# Phase 1: Flux has committed this build (or newer) for every watched file.
pending="$paths"
while :; do
  still=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    body=$(gh api -H 'Accept: application/vnd.github.raw+json' \
      "repos/${GITOPS_REPO}/contents/${p}?ref=${GITOPS_REF}" 2>/dev/null || true)
    n=$(printf '%s' "$body" | max_run)
    if [ -n "$n" ] && [ "$n" -ge "$RUN_NUMBER" ]; then
      log "Flux committed main-${n} to ${p}"
    else
      log "waiting for Flux: ${p} is at main-${n:-?}, want >= main-${RUN_NUMBER}"
      still+="$p"$'\n'
    fi
  done <<< "$pending"
  pending="$still"
  [ -n "$pending" ] || break
  tick "Flux did not commit main-${RUN_NUMBER} (or newer) to: $(printf '%s' "$pending" | paste -sd, -)"
done

# Phase 2: the cluster has applied it.
if [ -n "$VERSION_URL" ]; then
  while :; do
    body=$(curl -fsS --max-time 10 "$VERSION_URL" 2>/dev/null || true)
    n=$(printf '%s' "$body" | max_run)
    if printf '%s' "$body" | grep -qF "$SHA" \
      || { [ -n "$n" ] && [ "$n" -ge "$RUN_NUMBER" ]; }; then
      log "dev reports this build (or newer) at ${VERSION_URL}"
      break
    fi
    log "waiting for ${VERSION_URL} to report ${SHA:0:7} or main-${RUN_NUMBER}+"
    tick "${VERSION_URL} never reported ${SHA} or main-${RUN_NUMBER} (or newer)"
  done
else
  remaining=$((TIMEOUT_SECONDS - elapsed))
  settle=$SETTLE_SECONDS
  [ "$settle" -le "$remaining" ] || settle=$remaining
  log "no VERSION_URL; allowing ${settle}s for Flux to apply the commit and roll pods"
  sleep "$settle"
fi

log "dev is running main-${RUN_NUMBER} or newer"
