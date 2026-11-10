#!/usr/bin/env bash
# promotion-tickets.sh <state> <rc-tickets>
#
# Moves every ticket of a promoted Release Candidate to <state> (On Staging
# after a staging Promotion) with the Ticket Transitioner. <rc-tickets> is the
# select job's comma-separated rc_tickets. Moving a ticket that is already in
# <state> is a no-op in Linear, so a re-run is safe. Fails when any move
# fails, naming the tickets; the others are still moved.
# Stdout: the Ticket Transitioner's [{id, success, moved, from?, reason?, error?}].

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

[ $# -eq 2 ] || die "usage: promotion-tickets.sh <state> <rc-tickets>"
need jq

ids=$(csv_json "$2")
res=$(printf '%s' "$ids" | "$(dirname "$0")/ticket-transitioner.sh" "$1")
echo "$res"
failed=$(printf '%s' "$res" | jq -r '[.[] | select(.success != true) | "\(.id)\(if .error then " (\(.error))" else "" end)"] | join(", ")')
[ -z "$failed" ] || die "could not move to '$1': $failed"
