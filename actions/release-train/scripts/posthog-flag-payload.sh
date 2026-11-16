#!/usr/bin/env bash
# posthog-flag-payload.sh <ticket-id> <ticket-title> [ticket-url]
#
# Prints the PostHog create-flag payload (POST /api/projects/<id>/feature_flags/)
# for a Feature ticket, in the standard setup from docs/POSTHOG-FLAGS.md. The
# flag is created with the same key in both PostHog projects:
#
#   POSTHOG_PROJECT=prod (default), project 256388 "SignStream Production":
#     groups[0]  environment in dev/staging   100%  (never changes)
#     groups[1]  QA Cohort                    100%  (never changes)
#     groups[2]  environment in prod          0%    (the Rollout percentage)
#   POSTHOG_PROJECT=dev, project 275880 "SignStream Dev":
#     groups[0]  everyone                     100%  (never changes)
#
# QA_COHORT_ID (required for prod) is the numeric id of the "QA Cohort" static
# cohort in the prod project. Prints JSON only; it never calls PostHog.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -ge 2 ] || die "usage: posthog-flag-payload.sh <ticket-id> <ticket-title> [ticket-url]"
TICKET="$1"
TITLE="$2"
URL="${3:-}"

need jq

[[ "$TICKET" =~ ^[Ss][Ii][Gg]-([0-9]+)$ ]] || die "ticket id must look like SIG-123 (got '$TICKET')"
NUM="${BASH_REMATCH[1]}"

PROJECT="${POSTHOG_PROJECT:-prod}"
case "$PROJECT" in
  prod)
    COHORT="${QA_COHORT_ID:-}"
    [[ "$COHORT" =~ ^[0-9]+$ ]] || die "QA_COHORT_ID must be the numeric PostHog cohort id (got '$COHORT')"
    ;;
  dev) COHORT=0 ;; # unused: the dev flag has no cohort condition
  *) die "POSTHOG_PROJECT must be prod or dev (got '$PROJECT')" ;;
esac

# Slug: drop a leading "[Area]" tag, lowercase, non-alphanumerics to '-',
# then cut to at most 40 characters on a word boundary.
MAX=40
slug=$(printf '%s' "$TITLE" \
  | sed -E 's/^[[:space:]]*\[[^]]*\][[:space:]]*//' \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
if [ "${#slug}" -gt "$MAX" ]; then
  cut="${slug:0:$((MAX + 1))}"
  cut="${cut%-*}"
  # A single word longer than MAX has no boundary to cut on.
  [ -n "$cut" ] && [ "${#cut}" -le "$MAX" ] || cut="${slug:0:$MAX}"
  slug="${cut%-}"
fi
[ -n "$slug" ] || die "ticket title has no letters or digits to build a slug from"

KEY="sig-${NUM}-${slug}"
NAME="SIG-${NUM}: ${TITLE}"
[ -n "$URL" ] && NAME="${NAME} (${URL})"
NAME="${NAME}. Created by Prodzilla; conditions follow reusable-workflows docs/POSTHOG-FLAGS.md, change only the last condition's percentage."

jq -n \
  --arg key "$KEY" \
  --arg name "$NAME" \
  --arg project "$PROJECT" \
  --argjson cohort "$COHORT" \
  '{
    key: $key,
    name: $name,
    active: true,
    ensure_experience_continuity: false,
    filters: {
      aggregation_group_type_index: null,
      multivariate: null,
      payloads: {},
      groups: (if $project == "dev" then
        [{properties: [], rollout_percentage: 100, variant: null}]
      else [
        {
          properties: [
            {key: "environment", type: "person", operator: "exact",
             value: ["dev", "development", "staging"]}
          ],
          rollout_percentage: 100,
          variant: null
        },
        {
          properties: [
            {key: "id", type: "cohort", operator: "in", value: $cohort}
          ],
          rollout_percentage: 100,
          variant: null
        },
        {
          properties: [
            {key: "environment", type: "person", operator: "exact",
             value: ["prod", "production"]}
          ],
          rollout_percentage: 0,
          variant: null
        }
      ] end)
    }
  }'
