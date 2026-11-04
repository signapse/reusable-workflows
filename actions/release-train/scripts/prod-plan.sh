#!/usr/bin/env bash
# prod-plan.sh
#
# First step of the Dark Deployment to prod (SIG-2769, spec step 6). Read-only:
# decides whether this run deploys, and what. Nothing is dispatched or moved
# here, so a deferred or no-op run leaves no trace.
#
# Two modes:
#   fresh   RELEASE_TAG is set: staging just passed for it in this train run
#           (the caller only calls with staging_passed == 'true').
#   resume  RELEASE_TAG is empty: staging was not attempted in this train run
#           (nothing new promoted, deferred, or the train failed). Take
#           RESUME_TAG (the train's staged_tag) or else the newest release tag
#           on the branch, and deploy it if prod does not run it yet.
# Both modes check the staging pass of every ticket in the range (review fix,
# SIG-2769): every ticket carries Staging Passed, none carries Staging Failed
# and none is in QA Failed. Fresh refuses otherwise (red run); resume reports
# nothing. Staging Passed is cleared at each Promotion (SIG-2764), so it
# always belongs to the newest tag's staging run.
#           This is how a staging pass outside the deploy window reaches prod
#           in the next window with no stored state (AC6): the hourly train
#           run (and the 09:01 schedule) calls prod in resume mode.
#
# Tickets: TICKETS (the train's rc_tickets or staged_tickets) plus every
# ticket ref in the commits since the tag prod runs now, so a Release
# Candidate that passed staging but was overtaken before reaching prod is
# checked and moved too. Commits reverted later in that range, and revert
# commits, add no tickets (lib/revert.sh, the same rule as the selection).
#
# decision:
#   deploy            inside the deploy window
#   hotfix            outside it, a ticket carries HOTFIX_LABEL
#   deferred          outside it: do nothing; a later resume run deploys
#   already_deployed  fresh only: prod runs the tag on every service (a re-run
#                     after the deploy step). Skip the dispatch, finish the rest.
#   nothing           resume only: no candidate, prod already runs it, or its
#                     staging pass is not on record (see reason)
#   refused           fresh only: the tag was rolled back from in prod before
#                     (the train never re-deploys it by itself), or a ticket
#                     in the range has no staging pass on record
#
# Env:
#   RELEASE_TAG, RESUME_TAG, TICKETS (comma-separated), PROD_SERVICES (JSON array),
#   RELEASE_TAG_PATTERN (default ^v?[0-9]+\.[0-9]+\.[0-9]+$),
#   HOTFIX_LABEL, NOW (see deploy-window.sh),
#   STAGING_PASSED_LABEL, STAGING_FAILED_LABEL, QA_FAILED_STATE,
#   LINEAR_API_KEY, LINEAR_TEAM_KEY,
#   GITOPS_REPO, GITOPS_REF, GH_TOKEN (see prod-tags.sh)
# Runs in a full checkout (tags and history) of the product repo.
# Stdout: {mode, decision, reason, release_tag, version, sha, base,
#          services: [...prod-tags.sh], to_deploy: [...], previous_tags: {svc: tag},
#          previous_tag, tickets: [ids found in Linear], ticket_details: [...],
#          local_time?, next_open?}

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/revert.sh
source "$(dirname "$0")/../lib/revert.sh"

need git
need jq
HERE="$(dirname "$0")"

RELEASE_TAG="${RELEASE_TAG:-}"
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-^v?[0-9]+\.[0-9]+\.[0-9]+$}"
STAGING_PASSED_LABEL="${STAGING_PASSED_LABEL:-Staging Passed}"
STAGING_FAILED_LABEL="${STAGING_FAILED_LABEL:-Staging Failed}"
QA_FAILED_STATE="${QA_FAILED_STATE:-QA Failed}"

mode=fresh
[ -n "$RELEASE_TAG" ] || mode=resume
tag="$RELEASE_TAG"

# emit <decision> <reason> [extra-json]: print the plan and stop.
plan='{}'
emit() {
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  jq -nc --arg m "$mode" --arg d "$1" --arg r "$2" --arg t "$tag" --argjson p "$plan" --argjson x "$extra" '
    {release_tag: $t, version: ($t | sub("^v"; "")),
     sha: "", base: "", services: [], to_deploy: [], previous_tags: {}, previous_tag: "",
     tickets: [], ticket_details: []} + $p + $x + {mode: $m, decision: $d, reason: $r}'
  exit 0
}

if [ "$mode" = resume ]; then
  if [ -n "${RESUME_TAG:-}" ]; then
    printf '%s\n' "$RESUME_TAG" | grep -qE "$RELEASE_TAG_PATTERN" || die "resume tag '$RESUME_TAG' is not a release tag"
    tag="$RESUME_TAG"
  else
    tag=$(git tag --merged HEAD --sort=-v:refname | { grep -E "$RELEASE_TAG_PATTERN" || true; } | head -1)
  fi
  [ -n "$tag" ] || emit nothing "no release tag on the branch yet"
fi
sha=$(git rev-parse --verify -q "${tag}^{commit}") || die "release tag '$tag' is not in this repo"

services=$(PROD_SERVICES="${PROD_SERVICES:-}" "$HERE/prod-tags.sh" "$tag")
# shellcheck disable=SC2016 # jq bindings, not shell expansion.
plan=$(jq -c --arg sha "$sha" '{
  sha: $sha,
  services: .,
  to_deploy: [.[] | select(.on_tag | not) | .service],
  previous_tags: (map({key: .service, value: (if .on_tag then .deployed_previous else .current_tag end)}) | from_entries)}
  | .previous_tag = ([.previous_tags[]] | unique | if length == 1 then .[0] else "" end)' <<< "$services")

rolled=$(jq -r '[.services[] | select(.rolled_back) | .service] | join(", ")' <<< "$plan")
if [ -n "$rolled" ]; then
  if [ "$mode" = fresh ]; then
    emit refused "$tag was rolled back from in prod before ($rolled); the train does not deploy it again. Fix forward with a new Release Candidate, or deploy it by hand"
  fi
  emit nothing "the newest release tag $tag was rolled back from in prod ($rolled); waiting for a new Release Candidate"
fi

all_on=$(jq -r '.to_deploy | length == 0' <<< "$plan")
if [ "$all_on" = true ] && [ "$mode" = resume ]; then
  emit nothing "prod already runs $tag"
fi

# Commit range for the tickets: from the tag prod runs (or ran) before this
# one, when it is a release tag behind this one in git; otherwise from the
# previous release tag. With services on different tags, the OLDEST one
# (review fix): every ticket whose code reaches any service must be checked.
base=""
base_sha=""
while IFS= read -r t; do
  [ -n "$t" ] && [ "$t" != "$tag" ] || continue
  if b=$(git rev-parse --verify -q "${t}^{commit}") && git merge-base --is-ancestor "$b" "$sha"; then
    if [ -z "$base" ] || git merge-base --is-ancestor "$b" "$base_sha"; then
      base="$t"
      base_sha="$b"
    fi
  fi
done < <(jq -r '.services[] | if .on_tag then .deployed_previous else .current_tag end' <<< "$plan")
if [ -z "$base" ] && git rev-parse --verify -q "${sha}^" > /dev/null; then
  base=$(git tag --merged "${sha}^" --sort=-v:refname | { grep -E "$RELEASE_TAG_PATTERN" || true; } | head -1)
fi

ranged='[]'
if [ -n "$base" ]; then
  units=$(revert_units "$base" "$sha")
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ "$(jq -r --arg u "$u" '.[$u].kind // "normal"' <<< "$units")" = normal ] || continue
    r=$("$HERE/ticket-extractor.sh" "${u}^1" "$u" < /dev/null)
    ranged=$(jq -c --argjson r "$r" '. + $r | unique' <<< "$ranged")
  done < <(git rev-list --first-parent "${base}..${sha}")
fi
ids=$(jq -c --arg t "${TICKETS:-}" '. + ($t | split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_upcase) | map(select(. != ""))) | unique' <<< "$ranged")
details='[]'
[ "$ids" = '[]' ] || details=$(printf '%s' "$ids" | "$HERE/prod-tickets.sh")
# shellcheck disable=SC2016 # jq bindings, not shell expansion.
plan=$(jq -c --arg base "$base" --argjson d "$details" \
  '. + {base: $base, ticket_details: $d, tickets: [$d[] | select(.found) | .id]}' <<< "$plan")

if [ "$mode" = resume ]; then
  [ "$(jq '.tickets | length' <<< "$plan")" -gt 0 ] \
    || emit nothing "$tag carries no Linear tickets, so its staging pass cannot be verified from Linear; it reaches prod with the next Release Candidate, or deploy it by hand"
fi
# Every ticket in the range, in both modes: a ticket that failed staging in
# an earlier tag, or was rolled back, is still in QA Failed, and its code is
# in this tag too.
# shellcheck disable=SC2016 # jq bindings, not shell expansion.
bad=$(jq -r --arg sp "$STAGING_PASSED_LABEL" --arg sf "$STAGING_FAILED_LABEL" --arg qf "$QA_FAILED_STATE" '
  [.ticket_details[] | select(.found)
   | select((.labels | index($sp) | not) or (.labels | index($sf)) or .state == $qf)
   | "\(.id) (\(.state // "?"); \(.labels | join(", ")))"] | join("; ")' <<< "$plan")
if [ -n "$bad" ]; then
  [ "$mode" = fresh ] && emit refused "staging pass of $tag is not on record for every ticket since the tag prod runs: $bad. A ticket in QA Failed stops the line (ADR 0001)"
  emit nothing "staging pass of $tag is not on record for every ticket: $bad"
fi

if [ "$all_on" = true ]; then
  emit already_deployed "prod already runs $tag on every service; finishing the remaining steps"
fi

window=$(jq -c '[.ticket_details[] | select(.found) | .labels]' <<< "$plan" | "$HERE/deploy-window.sh")
case "$(jq -r .decision <<< "$window")" in
  open) emit deploy "inside the deploy window" "$window" ;;
  hotfix) emit hotfix "outside the deploy window; a ticket carries ${HOTFIX_LABEL:-hotfix}" "$window" ;;
  deferred) emit deferred "outside the deploy window; the train's next run in the window deploys it" "$window" ;;
  *) die "unexpected deploy window answer: $window" ;;
esac
