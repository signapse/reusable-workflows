#!/usr/bin/env bash
# promotion-plan.sh <rc-sha> <rc-tickets>
#
# First step of a staging Promotion (SIG-2764). Read-only: decides whether the
# Promotion may run now and which release tag it gets. Nothing is tagged,
# deployed or moved here, so a deferred run leaves no trace.
#
#   <rc-tickets>  comma-separated tickets in the Release Candidate (SIG-1,SIG-2),
#                 the select job's rc_tickets output. May be empty.
#
# decision:
#   open      inside the deploy window
#   hotfix    outside it, but a ticket carries the hotfix label
#   deferred  outside it: the caller does nothing; the hourly train run
#             re-selects and promotes once the window opens
#   resume    <rc-sha> already carries a release tag, i.e. an earlier attempt
#             of this run tagged it and failed later (re-run of failed jobs).
#             The image is already out; finish the remaining steps regardless
#             of the window.
#
# Env: LINEAR_API_KEY (when there are tickets), NOW, HOTFIX_LABEL,
#      RELEASE_TAG_PATTERN (see deploy-window.sh, promotion-version.sh).
# Stdout: {"decision", "local_time", "next_open"?, "tag", "version",
#          "previous_tag", "existing", "tickets": [...]}

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 2 ] || die "usage: promotion-plan.sh <rc-sha> <rc-tickets>"
need jq
HERE="$(dirname "$0")"
RC_SHA="$1"

tickets=$(csv_json "$2")
labels='[]'
if [ "$tickets" != '[]' ]; then
  labels=$(printf '%s' "$tickets" | "$HERE/ticket-labels.sh")
fi

window=$(printf '%s' "$labels" | "$HERE/deploy-window.sh")
version=$(printf '%s' "$labels" | "$HERE/promotion-version.sh" "$RC_SHA")

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc --argjson w "$window" --argjson v "$version" --argjson t "$tickets" '
  $w + $v + {tickets: $t}
  | if .existing then .decision = "resume" | del(.next_open) else . end'
