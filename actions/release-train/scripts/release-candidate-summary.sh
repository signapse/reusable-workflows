#!/usr/bin/env bash
# release-candidate-summary.sh
#
# Reads release-candidate.sh's JSON on stdin and prints the job summary
# (Markdown). Commit subjects, ticket titles and the trigger inputs are
# contributor text, so they are escaped: they cannot add links, headings or
# lines. Link targets other than https URLs are dropped.
#
# Env: GITHUB_REPOSITORY (required), TICKET, TRIGGER_ID (optional).

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
need jq
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"

# shellcheck disable=SC2016 # jq program, not shell expansion.
jq -r --arg ticket "${TICKET:-}" --arg trigger "${TRIGGER_ID:-}" --arg repo "$GITHUB_REPOSITORY" '
  def short: .[0:7];
  def esc: tostring | gsub("[\r\n]+"; " ") | gsub("(?<c>[\\\\`*_\\[\\]()<>|!#~&])"; "\\\(.c)");
  def link: tostring | if test("^https://[^\\s()<>]+$") then . else "#" end;
  def commit: "[`\(.sha | short)`](https://github.com/\($repo)/commit/\(.sha)) \(.subject | esc)";
  "## Release Candidate",
  "",
  (if $ticket != "" then "Triggered by \($ticket | esc) (delivery \($trigger | esc))."
   else "Scheduled run (hourly backstop)." end),
  "Walked main from `\(.last_tag)` (the release tag prod runs) to `\(.head_sha | short)`.",
  "",
  (if .outcome == "selected" then
     "**Selected** `\(.rc.image_tag)` ([build #\(.rc.run_number)](\(.rc.run_url | link)))."
   elif .outcome == "already_promoted" then
     "**No-op:** `\(.rc.image_tag)` is already promoted as `\(.rc.release_tag // "")`."
   else
     "**No Release Candidate:** no build since `\(.last_tag)` has all its tickets QA Passed."
   end),
  "",
  "### Tickets",
  (if (.tickets | length) == 0 then "_none_"
   else (.tickets[] | "- [\(.id | esc)](\(.url | link)) \(.title | esc) (\(.state | esc))") end),
  "",
  "### Untracked commits",
  (if (.untracked_commits | length) == 0 then "_none_" else (.untracked_commits[] | "- " + commit) end),
  "",
  "### Reverted (do not block)",
  (if ((.reverted // []) | length) == 0 then "_none_"
   else (.reverted[] | "- " + commit + " (\(.tickets | join(", ") | esc))") end),
  "",
  "### Blocked by",
  (if .blocked_by == null then "_nothing: every walked commit is selectable_"
   else "- [\(.blocked_by.id | esc)](\(.blocked_by.url | link)) \(.blocked_by.reason | esc), first merged in "
        + (.blocked_by | commit)
   end)
'
