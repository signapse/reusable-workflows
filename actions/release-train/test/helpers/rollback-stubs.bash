# Shared stubs for the SIG-2771 rollback follow-up scripts. Source from setup().
# One curl stub routes by URL:
#   api.linear.app/graphql  by query text; every request body goes to $TMP/linear.log
#     release(id:)          $TMP/release.json, or "Entity not found" when absent
#     releasePipelines      $TMP/pipelines.json (default one pipeline "pipe-1")
#     releases(filter       $TMP/release.json as the only node, or none
#     releaseUpdate         success
#     issue(id:) comments   $TMP/comments-<id> holds existing comment bodies (JSON array)
#     commentCreate, workflowStates, issueUpdate, issueRemoveLabel   success
#     issue(id:) state      $TMP/state-<id>, default On Prod
#     issue(id:) labels     QA Passed (lbl-qa) and Feature (lbl-feature)
#   api.incident.io         body to $TMP/incident.json; answers $TMP/inc-code (201) with $TMP/inc-body
#     /v2/incidents?...     (list) $TMP/inc-list, default no incidents
#   slack.com               body to $TMP/slack.log (one JSON per line); {"ok":true}
# $TMP/linear-down makes every Linear call fail with HTTP 500.

install_rollback_stubs() {
  mkdir -p "$TMP/stub"
  export PATH="$TMP/stub:$PATH"
  : > "$TMP/linear.log"
  : > "$TMP/slack.log"
  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
url="" body=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -d) body="${args[$((i + 1))]}" ;;
    --data-binary) [ "${args[$((i + 1))]}" = @- ] && body=$(cat) || body="${args[$((i + 1))]}" ;;
    https://*) url="${args[$i]}" ;;
  esac
done
case "$url" in
  https://api.linear.app/graphql)
    echo "$body" >> "$TMP/linear.log"
    [ -f "$TMP/linear-down" ] && { printf '{"errors":[{"message":"down"}]}\n500'; exit 0; }
    q=$(jq -r .query <<< "$body")
    case "$q" in
      *releaseUpdate*) out='{"data":{"releaseUpdate":{"success":true}}}' ;;
      *releasePipelines*) out=$(cat "$TMP/pipelines.json" 2>/dev/null || echo '{"data":{"releasePipelines":{"nodes":[{"id":"pipe-1"}]}}}') ;;
      *"releases(filter"*)
        if [ -f "$TMP/release.json" ]; then out=$(jq -c '{data: {releases: {nodes: [.]}}}' "$TMP/release.json")
        else out='{"data":{"releases":{"nodes":[]}}}'; fi ;;
      *"release(id:"*)
        if [ -f "$TMP/release.json" ]; then out=$(jq -c '{data: {release: .}}' "$TMP/release.json")
        else out='{"data":null,"errors":[{"message":"Entity not found: Release"}]}'; fi ;;
      *commentCreate*) out='{"data":{"commentCreate":{"success":true}}}' ;;
      *workflowStates*) out='{"data":{"workflowStates":{"nodes":[{"id":"state-qa-failed"}]}}}' ;;
      *issueUpdate*) out='{"data":{"issueUpdate":{"success":true}}}' ;;
      *issueRemoveLabel*) out='{"data":{"issueRemoveLabel":{"success":true}}}' ;;
      *"issue(id:\$id){state{name}}"*)
        id=$(jq -r .variables.id <<< "$body")
        out=$(jq -nc --arg s "$(cat "$TMP/state-$id" 2>/dev/null || echo 'On Prod')" '{data: {issue: {state: {name: $s}}}}') ;;
      *"issue(id:\$id){labels{nodes{id name}}}"*)
        out='{"data":{"issue":{"labels":{"nodes":[{"id":"lbl-qa","name":"QA Passed"},{"id":"lbl-feature","name":"Feature"}]}}}}' ;;
      *"issue(id:"*)
        id=$(jq -r .variables.id <<< "$body")
        out=$(jq -nc --arg id "$id" --argjson c "$(cat "$TMP/comments-$id" 2>/dev/null || echo '[]')" \
          '{data: {issue: {id: "uuid-\($id)", comments: {nodes: [$c[] | {body: .}]}}}}') ;;
      *) echo "curl stub: unhandled Linear query: $q" >&2; exit 1 ;;
    esac
    printf '%s\n200' "$out" ;;
  https://api.incident.io/v2/incidents\?*)
    cat "$TMP/inc-list" 2>/dev/null || echo '{"incidents":[]}' ;;
  https://api.incident.io/*)
    echo "$body" > "$TMP/incident.json"
    printf '%s\n%s' "$(cat "$TMP/inc-body" 2>/dev/null || echo '{"incident":{"id":"01INC","reference":"INC-7","permalink":"https://app.incident.io/signapse-workspace/incidents/7"}}')" \
      "$(cat "$TMP/inc-code" 2>/dev/null || echo 201)" ;;
  https://slack.com/*)
    echo "$body" >> "$TMP/slack.log"
    echo '{"ok":true,"ts":"1.2"}' ;;
  *) echo "curl stub: unhandled url $url" >&2; exit 1 ;;
esac
EOS
  chmod +x "$TMP/stub/curl"
}

# Linear requests whose query contains $1, as compact JSON lines.
linear_calls() { jq -c --arg q "$1" 'select(.query | contains($q))' "$TMP/linear.log"; }

# A Release in Deployed, in a pipeline with Deployed / Rolling Out / Released / Rolled back.
write_release() { # write_release [stage-name]
  jq -nc --arg s "${1:-Deployed}" '{id: "rel-1", url: "https://linear.app/signapse/release/rel-1", version: "1.4.0",
    stage: {id: ("stage-" + ($s | ascii_downcase | gsub(" "; "-"))), name: $s, type: (if $s == "Rolled back" then "canceled" else "started" end)},
    pipeline: {name: "SignStream", stages: {nodes: [
      {id: "stage-deployed", name: "Deployed", type: "started"},
      {id: "stage-rolling-out", name: "Rolling Out", type: "started"},
      {id: "stage-released", name: "Released", type: "completed"},
      {id: "stage-rolled-back", name: "Rolled back", type: "canceled"}]}}}' > "$TMP/release.json"
}
