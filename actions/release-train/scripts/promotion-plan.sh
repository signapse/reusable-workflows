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
#   superseded  the last release tag on the release branch is no longer the
#             one select saw (SEEN_RELEASE_TAG): another Promotion finished
#             while this one was queued behind it, so <rc-sha> may be older
#             than what staging runs. Do nothing, like deferred; the next
#             train run re-selects. Cutting a higher tag here would make Flux
#             roll staging back to the older commit.
#
# Env: LINEAR_API_KEY (when there are tickets), NOW, HOTFIX_LABEL,
#      RELEASE_TAG_PATTERN (see deploy-window.sh, promotion-version.sh).
#   SEEN_RELEASE_TAG  select's last_release_tag; unset skips the superseded
#                     check (tests). The workflow always sets it.
#   HOTFIX_TICKETS    comma-separated tickets whose hotfix label may bypass the
#                     window: those new since the last Promotion (select's
#                     rc_new_tickets). A hotfix label left on a ticket already
#                     on staging must not open the window for every later
#                     Promotion. Unset: every ticket in <rc-tickets>.
# Stdout: {"decision", "local_time", "next_open"?, "tag", "version",
#          "previous_tag", "existing", "tickets": [...], "newer_tag"?}

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/release-tag.sh
source "$(dirname "$0")/../lib/release-tag.sh"

[ $# -eq 2 ] || die "usage: promotion-plan.sh <rc-sha> <rc-tickets>"
need jq
HERE="$(dirname "$0")"
RC_SHA="$1"

tickets=$(csv_json "$2")
labels='[]'
if [ "$tickets" != '[]' ]; then
  labels=$(printf '%s' "$tickets" | "$HERE/ticket-labels.sh")
fi

# Labels of the tickets allowed to bypass the window (ticket-labels.sh keeps
# input order).
hotfix_labels="$labels"
if [ -n "${HOTFIX_TICKETS+x}" ]; then
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  hotfix_labels=$(jq -nc --argjson t "$tickets" --argjson l "$labels" --argjson h "$(csv_json "$HOTFIX_TICKETS")" \
    '[range($t | length) | select($t[.] as $id | $h | index($id)) | $l[.]]')
fi

window=$(printf '%s' "$hotfix_labels" | "$HERE/deploy-window.sh")
version=$(printf '%s' "$labels" | "$HERE/promotion-version.sh" "$RC_SHA")

newer=""
if [ -n "${SEEN_RELEASE_TAG+x}" ]; then
  now_tag=$(last_release_tag "$(git rev-parse HEAD)" "${RELEASE_TAG_PATTERN:-^v?[0-9]+\.[0-9]+\.[0-9]+$}")
  [ "$now_tag" = "$SEEN_RELEASE_TAG" ] || newer="$now_tag"
fi

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -nc --argjson w "$window" --argjson v "$version" --argjson t "$tickets" --arg n "$newer" '
  $w + $v + {tickets: $t}
  | if .existing then .decision = "resume" | del(.next_open)
    elif $n != "" then .decision = "superseded" | .newer_tag = $n | del(.next_open)
    else . end'
