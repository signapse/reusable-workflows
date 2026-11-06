#!/usr/bin/env bash
# terraform-gate-alert.sh
#
# Reads a Terraform gate result on stdin and prints the Slack chat.postMessage
# payload that stops the Promotion. The result is terraform-gate.sh's object,
# with `gate` one of:
#   blocked    names the product, environment and every destroyed, replaced
#              or unclassified resource (first 25 of each, then a count; the
#              job summary lists them all)
#   failed     names the product, environment and the reason
#   unapplied  terraform-pending.sh's `pending` list is merged in: names each
#              ticket, its unapplied Terraform PR and the products
# Pure: no network. The caller posts it with lib/slack.sh slack_post.
#
# Env: SLACK_CHANNEL (required), CONTEXT (what was stopped, e.g. "Promotion of
#      signapse/sign-stream-api main-12-abc to staging"), WORKFLOW_RUN_URL
#      (the run that was stopped), TF_REPO (for PR labels).

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

need jq
: "${SLACK_CHANNEL:?SLACK_CHANNEL not set}"

# shellcheck disable=SC2016 # jq bindings, not shell expansion.
jq -c --arg ch "$SLACK_CHANNEL" --arg ctx "${CONTEXT:-Promotion}" \
  --arg wf "${WORKFLOW_RUN_URL:-}" --arg tfrepo "${TF_REPO:-signapse/signapse-core-terraform}" '
  def link(u; t): if (u // "") == "" then t else "<" + u + "|" + t + ">" end;
  def bullets(k): (.[k] // []) as $a
    | if ($a | length) == 0 then empty
      else "*\(k) (\($a | length)):*\n" + ($a[:25] | map("• `\(.)`") | join("\n"))
        + (if ($a | length) > 25 then "\n• … \(($a | length) - 25) more in the run summary" else "" end)
      end;
  (.product // "?") as $p | (.environment // "?") as $e
  | (if .gate == "blocked" then
      ":no_entry: *Terraform blocked the \($ctx)*\nProduct *\($p)*, environment *\($e)*: the plan destroys or replaces resources. Nothing was applied, tagged or deployed.\n\n"
      + ([bullets("destroys"), bullets("replaces"), bullets("unclassified")] | join("\n\n"))
      + "\n\nA human must review the plan in " + link(.run_url; "the Terraform run")
      + " and apply it by hand, then re-run the train."
    elif .gate == "unapplied" then
      ":no_entry: *\($ctx) blocked: merged Terraform is not applied in \($e)*\n"
      + (.pending | map("• \(.ticket): " + link(.url; "\($tfrepo | split("/") | last)#\(.pr)")
          + " (" + (.products | join(", ")) + ")") | join("\n"))
      + "\n\nApply each product in \($e) (terraform-deploy.yml with apply=true, or the gate on its own repo), then re-run the train."
    else
      ":x: *Terraform failed for the \($ctx)*\nProduct *\($p)*, environment *\($e)*: \(.reason // "unknown error").\nNothing was tagged or deployed."
      + (if (.run_url // "") != "" then " See " + link(.run_url; "the Terraform run") + "." else "" end)
    end) as $body
  | ($body + (if $wf != "" then "\n" + link($wf; "Release train run") else "" end)) as $text
  | {channel: $ch, text: ($text | split("\n") | first),
     blocks: [{type: "section", text: {type: "mrkdwn",
       text: (if ($text | length) > 2900 then $text[:2900] + "\n…(truncated)" else $text end)}}]}'
