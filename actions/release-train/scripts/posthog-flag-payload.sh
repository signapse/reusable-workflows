#!/usr/bin/env bash
# posthog-flag-payload.sh <ticket-id> <ticket-title> [ticket-url]
#
# Prints the PostHog create-flag payload (POST /api/projects/<id>/feature_flags/)
# for a Feature ticket, in the standard setup from docs/POSTHOG-FLAGS.md:
#
#   groups[0]  environment in dev/staging   100%  (never changes)
#   groups[1]  QA Cohort                    100%  (never changes)
#   groups[2]  environment in prod          0%    (the Rollout percentage)
#
# QA_COHORT_ID (required) is the numeric id of the "QA Cohort" static cohort.
# Prints JSON only; it never calls PostHog.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -ge 2 ] || die "usage: posthog-flag-payload.sh <ticket-id> <ticket-title> [ticket-url]"
TICKET="$1"
TITLE="$2"
URL="${3:-}"

need jq

[[ "$TICKET" =~ ^[Ss][Ii][Gg]-([0-9]+)$ ]] || die "ticket id must look like SIG-123 (got '$TICKET')"
NUM="${BASH_REMATCH[1]}"

COHORT="${QA_COHORT_ID:-}"
[[ "$COHORT" =~ ^[0-9]+$ ]] || die "QA_COHORT_ID must be the numeric PostHog cohort id (got '$COHORT')"

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
      groups: [
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
      ]
    }
  }'
