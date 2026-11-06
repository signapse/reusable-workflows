#!/usr/bin/env bash
# deploy-window.sh
#
# Deploy window gate (spec "Guardrails"). Deployments and Promotions run
# Monday-Thursday 09:00-16:00 and Friday 09:00-12:00 UK time (Europe/London,
# so GMT in winter and BST in summer). Start inclusive, end exclusive: Mon
# 09:00 is open, Thu 16:00 and Fri 12:00 are closed. A ticket carrying the
# hotfix label bypasses the window.
#
# Shared by the staging Promotion (SIG-2764) and the prod Deployment
# (SIG-2769). It never sleeps: outside the window the caller reports
# `deferred` and does nothing; the train's hourly run re-selects and promotes
# once the window is open.
#
# Stdin: JSON array of label arrays, one per ticket ([["Bug","hotfix"],[]]).
#        Empty stdin means no tickets.
# Env:
#   NOW           clock override for tests: epoch seconds or
#                 YYYY-MM-DDTHH:MM:SSZ (UTC). Default: the current time.
#   HOTFIX_LABEL  label that bypasses the window (default hotfix)
# Stdout: {"decision": "open"|"hotfix"|"deferred", "local_time": "...",
#          "next_open": "..." (deferred only, UK time)}
# Exit 0 for every decision; non-zero only on bad input.

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need jq
need date

HOTFIX_LABEL="${HOTFIX_LABEL:-hotfix}"
UK_TZ="Europe/London"

case "${NOW:-}" in
  "") now=$(date -u +%s) ;;
  *[!0-9]*)
    now=$(jq -nr --arg t "$NOW" '$t | fromdateiso8601' 2>/dev/null) \
      || die "NOW must be epoch seconds or YYYY-MM-DDTHH:MM:SSZ, got '$NOW'"
    ;;
  *) now="$NOW" ;;
esac

# uk_fmt <epoch> <format>: format an instant in UK time (GNU or BSD date).
uk_fmt() {
  TZ="$UK_TZ" date -d "@$1" "+$2" 2>/dev/null || TZ="$UK_TZ" date -r "$1" "+$2"
}

# is_open <epoch>: window open at that instant?
is_open() {
  local t dow hhmm
  t=$(uk_fmt "$1" '%u%H%M')   # e.g. 10859 = Monday 08:59
  dow=${t:0:1}
  hhmm=$((10#${t:1}))
  case "$dow" in
    1 | 2 | 3 | 4) [ "$hhmm" -ge 900 ] && [ "$hhmm" -lt 1600 ] ;;
    5) [ "$hhmm" -ge 900 ] && [ "$hhmm" -lt 1200 ] ;;
    *) return 1 ;;
  esac
}

labels=$(cat)
[ -n "$labels" ] || labels='[]'
hotfix=$(printf '%s' "$labels" | jq -r --arg h "$HOTFIX_LABEL" \
  'if type == "array" then ([.[]? | arrays | .[]] | index($h) != null) else error("not an array") end' 2>/dev/null) \
  || die "stdin must be a JSON array of label arrays"

local_time=$(uk_fmt "$now" '%a %Y-%m-%d %H:%M %Z')

if is_open "$now"; then
  jq -nc --arg t "$local_time" '{decision: "open", local_time: $t}'
elif [ "$hotfix" = true ]; then
  jq -nc --arg t "$local_time" '{decision: "hotfix", local_time: $t}'
else
  # Window edges are on the hour and UK offsets are whole hours, so the next
  # opening is on a UTC hour boundary within the next week.
  next=$(( now - now % 3600 + 3600 ))
  for _ in $(seq 1 170); do
    is_open "$next" && break
    next=$((next + 3600))
  done
  jq -nc --arg t "$local_time" --arg n "$(uk_fmt "$next" '%a %Y-%m-%d %H:%M %Z')" \
    '{decision: "deferred", local_time: $t, next_open: $n}'
fi
