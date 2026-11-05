#!/usr/bin/env bash
# rollback-incident.sh
#
# Opens the incident.io incident for a failed prod smoke (SIG-2771, AC3, AC5;
# spec "incident.io"), with the incident.io API v2 (POST /v2/incidents), the
# same shape as the Prodzilla router's adaptor (signapse-core-terraform,
# SIG-2772):
#   - severity: MINOR_SEVERITY_ID when every service was rolled back, else
#     MAJOR_SEVERITY_ID (the rollback failed or needs a human: AC5). One
#     incident per Deployment either way;
#   - custom field Cause = Deployment, which dora-metrics counts for change
#     failure rate (the spec's "tagged `deployment`");
#   - a link to the failing run, in the summary and, when LINK_FIELD_ID is set,
#     in that link custom field;
#   - idempotency_key = IDEMPOTENCY_KEY (the deploy run key), so a re-run never
#     opens a second incident. A 409, or a 422 naming the idempotency key, means
#     an earlier attempt opened it: ok, created=false.
#
# Env:
#   INCIDENT_IO_API_KEY   key allowed to create incidents (required)
#   IDEMPOTENCY_KEY       required
#   ROLLBACK_OK           true | false (false = Major)
#   MINOR_SEVERITY_ID, MAJOR_SEVERITY_ID, CAUSE_FIELD_ID, CAUSE_OPTION_ID   required
#   LINK_FIELD_ID         optional link custom field for the run URL
#   INCIDENT_TYPE_ID      optional; empty = the organisation's default type
#   INCIDENT_MODE         standard (default) | test (for trying the path out)
#   REPOSITORY, RELEASE_TAG, RUN_URL (required), REPORT_URL, RELEASE_URL, TICKETS
#   ROLLBACK_RESULTS      prod-rollback.sh's results array (may be [])
#   CAUSE                 what failed, default "Prod smoke failed" (the workflow
#                         sends "Prod deploy failed part-way" for a partial Deployment)
#   INCIDENT_IO_BASE_URL  default https://api.incident.io
# Stdout: {ok, created, severity, incident_id, reference, url, reason}
# Exit 0 when the incident exists (created now or earlier), 1 otherwise.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need jq
need curl

: "${RUN_URL:?RUN_URL not set}"
BASE="${INCIDENT_IO_BASE_URL:-https://api.incident.io}"
BASE="${BASE%/}"
MODE="${INCIDENT_MODE:-standard}"
RESULTS="${ROLLBACK_RESULTS:-}"
[ -n "$RESULTS" ] || RESULTS='[]'
WHAT="${REPOSITORY:-this repo}${RELEASE_TAG:+ ${RELEASE_TAG}}"

if [ "${ROLLBACK_OK:-false}" = true ]; then sev=minor; sev_id="${MINOR_SEVERITY_ID:-}"; else sev=major; sev_id="${MAJOR_SEVERITY_ID:-}"; fi

out() { # out <ok> <created> <reason> [incident-json]
  local inc="${4:-}"
  [ -n "$inc" ] || inc='{}'
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  jq -nc --argjson ok "$1" --argjson created "$2" --arg why "$3" --argjson i "$inc" --arg sev "$sev" \
    '{ok: $ok, created: $created, severity: $sev, incident_id: ($i.id // ""), reference: ($i.reference // ""),
      url: ($i.permalink // ""), reason: $why}'
  [ "$1" = true ] || exit 1
  exit 0
}

missing=()
for v in INCIDENT_IO_API_KEY IDEMPOTENCY_KEY CAUSE_FIELD_ID CAUSE_OPTION_ID; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
[ -n "$sev_id" ] || missing+=("$([ "$sev" = minor ] && echo MINOR_SEVERITY_ID || echo MAJOR_SEVERITY_ID)")
[ "${#missing[@]}" -eq 0 ] || out false false "not opened, missing: ${missing[*]}"
case "$MODE" in standard | test) ;; *) out false false "INCIDENT_MODE must be standard or test (got '$MODE')" ;; esac
jq -e 'type == "array"' <<< "$RESULTS" > /dev/null 2>&1 || out false false "ROLLBACK_RESULTS is not a JSON array"

services=$(jq -r 'map("`\(.service)`") | join(", ")' <<< "$RESULTS")
CAUSE="${CAUSE:-Prod smoke failed}"
if [ "$sev" = minor ]; then
  name="${CAUSE} after deploying ${WHAT}; rolled back"
  impact="Customers used ${WHAT} from its Deployment until the automatic rollback finished; ${services:-every service} now runs the previous version again."
  steps="We rolled back automatically to the previous version ($(jq -r 'map("`\(.service)` → `\(.restored)`") | join(", ")' <<< "$RESULTS")) and moved the tickets to QA Failed."
else
  name="${CAUSE} after deploying ${WHAT}; ROLLBACK FAILED"
  impact="Customers may still be on ${WHAT}: the automatic rollback did not restore every service."
  steps="The automatic rollback did not finish: $(jq -r 'map("`\(.service)`: \(.reason)") | join("; ")' <<< "$RESULTS"). Someone needs to roll back by hand (signapse-core-k8s docs/OPERATIONS.md)."
fi
problem="The @prod-safe smoke tests failed after ${WHAT} was deployed to production."
[ "$CAUSE" = "Prod smoke failed" ] || problem="${CAUSE} while deploying ${WHAT} to production: some services ran it, so it was treated as a failed Deployment."
summary="**Problem**: ${problem}

**Impact**: ${impact}

**Causes**: The Deployment of ${WHAT}${TICKETS:+ (tickets ${TICKETS})}. We don't know which change yet.

**Steps to resolve**: ${steps}

[Failing run](${RUN_URL})${REPORT_URL:+ · [Smoke report](${REPORT_URL})}${RELEASE_URL:+ · [Linear Release](${RELEASE_URL})}"

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
body=$(jq -nc --arg key "$IDEMPOTENCY_KEY" --arg mode "$MODE" --arg name "$name" --arg summary "$summary" \
  --arg sev "$sev_id" --arg type "${INCIDENT_TYPE_ID:-}" --arg cause "$CAUSE_FIELD_ID" --arg opt "$CAUSE_OPTION_ID" \
  --arg link_field "${LINK_FIELD_ID:-}" --arg run "$RUN_URL" '
  {idempotency_key: $key, visibility: "public", mode: $mode, name: $name, summary: $summary, severity_id: $sev,
   custom_field_entries: ([{custom_field_id: $cause, values: [{value_option_id: $opt}]}]
     + (if $link_field != "" then [{custom_field_id: $link_field, values: [{value_link: $run}]}] else [] end))}
  + (if $type != "" then {incident_type_id: $type} else {} end)')

# Bounded: a hung connection must not hold back the ticket and Slack step.
# A timed-out POST may still have opened it; the idempotency key covers a re-run.
resp=$(curl -sS --connect-timeout 15 --max-time 60 -w '\n%{http_code}' -X POST "${BASE}/v2/incidents" \
  -H "Authorization: Bearer ${INCIDENT_IO_API_KEY}" \
  -H "Content-Type: application/json" \
  --data-binary @- <<< "$body" 2>&1) || out false false "incident.io unreachable: ${resp:0:200}"
code="${resp##*$'\n'}"
raw="${resp%$'\n'*}"
msg=$(jq -r '[.errors[]?.message] | join("; ")' <<< "$raw" 2> /dev/null || true)
[ -n "$msg" ] || msg="${raw:0:200}"

# An earlier attempt opened it (idempotency conflict): find that incident so
# the alert and the run still link it. Its summary carries this run's URL
# (the same on every attempt). Not found: still ok, just no link.
existing() {
  local list
  list=$(curl -sS --max-time 20 "${BASE}/v2/incidents?page_size=50" -H "Authorization: Bearer ${INCIDENT_IO_API_KEY}" 2> /dev/null) || return 0
  jq -c --arg r "(${RUN_URL})" '[.incidents[]? | select((.summary // "") | contains($r))] | first // empty' <<< "$list" 2> /dev/null || true
}

case "$code" in
  2??)
    inc=$(jq -c '.incident // empty' <<< "$raw" 2> /dev/null || true)
    # Created, probably, but unreadable: the idempotency key makes a re-run safe.
    [ -n "$inc" ] || out false false "incident.io answered HTTP ${code} without an incident; re-run to make sure it exists"
    log "incident.io: opened $(jq -r '.reference // .id' <<< "$inc") (${sev})"
    out true true "opened" "$inc" ;;
  409) out true false "already opened by an earlier attempt (idempotency key ${IDEMPOTENCY_KEY}): ${msg}" "$(existing)" ;;
  422)
    if jq -e '[.errors[]? | (.source.field // "") == "idempotency_key" or ((.message // "") | ascii_downcase | contains("idempotency"))] | any' <<< "$raw" > /dev/null 2>&1; then
      out true false "already opened by an earlier attempt (idempotency key ${IDEMPOTENCY_KEY}): ${msg}" "$(existing)"
    fi
    out false false "incident.io rejected the incident (HTTP 422): ${msg}" ;;
  *) out false false "incident.io HTTP ${code}: ${msg}" ;;
esac
