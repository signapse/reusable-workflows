#!/usr/bin/env bats
# AC4 of SIG-2765: terraform-pending.sh blocks a Promotion when a ticket's
# merged signapse-core-terraform PR is not applied in the environment.
# Stubs:
#   curl (Linear)  $TMP/linear/<ticket>  attachment URLs, one per line
#   gh api         $TMP/pulls/<n>.json, $TMP/pulls/<n>.files (paths),
#                  $TMP/deploy-runs.json (terraform-deploy.yml runs),
#                  $TMP/orch-runs.json (orchestration.yml runs)
load 'helpers/load'

S="$BATS_TEST_DIRNAME/../scripts"
TF=https://github.com/signapse/signapse-core-terraform

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/stub" "$TMP/linear" "$TMP/pulls"
  export PATH="$TMP/stub:$PATH"
  echo '{"workflow_runs":[]}' > "$TMP/deploy-runs.json"
  echo '{"workflow_runs":[]}' > "$TMP/orch-runs.json"

  cat > "$TMP/stub/curl" <<'EOS'
#!/usr/bin/env bash
body=""; while [ $# -gt 0 ]; do [ "$1" = -d ] && body="$2"; shift; done
id=$(jq -r .variables.id <<< "$body")
f="$TMP/linear/$id"
if [ -f "$f" ]; then
  jq -Rn --arg id "$id" --argjson more "$([ -f "$TMP/more-attachments" ] && echo true || echo false)" \
    '{data: {issue: {identifier: $id, attachments: {nodes: [inputs | {url: .}], pageInfo: {hasNextPage: $more}}}}}' < "$f"
else
  echo '{"data":{"issue":null},"errors":[{"message":"Entity not found"}]}'
fi
printf '\n200'
EOS
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 1
shift
[ "$1" = --paginate ] && shift
case "$1" in
  */pulls/*/files*) n=${1#*/pulls/}; n=${n%%/*}
    jq -Rn '[inputs | {filename: .}]' < "$TMP/pulls/$n.files" ;;
  */pulls/*) cat "$TMP/pulls/${1##*/}.json" ;;
  */terraform-deploy.yml/runs*) echo "$1" >> "$TMP/run-queries"; cat "$TMP/deploy-runs.json"
    # --paginate prints one object per page.
    [ ! -f "$TMP/deploy-runs-2.json" ] || cat "$TMP/deploy-runs-2.json" ;;
  */orchestration.yml/runs*) cat "$TMP/orch-runs.json" ;;
  *) echo "gh stub: unhandled $1" >&2; exit 1 ;;
esac
EOS
  chmod +x "$TMP/stub/"*

  export GH_TOKEN=x LINEAR_API_KEY=k PRODUCT=Signstream ENVIRONMENT=stg
}

teardown() { rm -rf "$TMP"; }

# pr <n> <merged_at|""> <paths...>
pr() {
  local n="$1" m="$2"; shift 2
  jq -nc --argjson n "$n" --arg m "$m" --arg u "$TF/pull/$n" \
    '{number: $n, html_url: $u, merged_at: (if $m == "" then null else $m end),
      merge_commit_sha: ("sha" + ($n | tostring))}' > "$TMP/pulls/$n.json"
  printf '%s\n' "$@" > "$TMP/pulls/$n.files"
}

# deploy_run <title> <created_at> [conclusion] [branch]
deploy_run() {
  jq --arg t "$1" --arg c "$2" --arg k "${3:-success}" --arg b "${4:-main}" \
    '.workflow_runs += [{display_title: $t, created_at: $c, conclusion: $k, head_branch: $b}]' \
    "$TMP/deploy-runs.json" > "$TMP/r" && mv "$TMP/r" "$TMP/deploy-runs.json"
}

pending() { run "$S/terraform-pending.sh" "$@"; }
field() { tail -n1 <<< "$output" | jq -r "$1"; }

@test "AC4: merged Terraform PR with no apply since its merge blocks" {
  echo "$TF/pull/12" > "$TMP/linear/SIG-7"
  pr 12 2026-11-02T10:00:00Z terragrunt/products/Signstream/config/stg.yml
  deploy_run "Terraform plan+apply Signstream (stg/eu) [old]" 2026-11-01T09:00:00Z
  pending "SIG-7"
  [ "$status" -eq 0 ]
  [ "$(field '.pending | length')" = 1 ]
  [ "$(field '.pending[0].ticket')" = SIG-7 ]
  [ "$(field '.pending[0].pr')" = 12 ]
  [ "$(field '.pending[0].url')" = "$TF/pull/12" ]
  [ "$(field '.pending[0].products | join(",")')" = Signstream ]
  # the run listing is narrowed to runs created since the merge
  grep -q 'branch=main&status=success&created=>=2026-11-02T10:00:00Z' "$TMP/run-queries"
}

@test "AC4: a successful apply run created after the merge counts as applied" {
  echo "$TF/pull/12" > "$TMP/linear/SIG-7"
  pr 12 2026-11-02T10:00:00Z terragrunt/products/Signstream/main.tf
  deploy_run "Terraform plan+apply Signstream (stg/eu) [gate]" 2026-11-02T11:00:00Z
  pending "SIG-7"
  [ "$status" -eq 0 ]
  [ "$(field '.pending | length')" = 0 ]
  [ "$(field '.checked[0].state')" = merged ]
}

@test "AC4: apply runs for another environment, branch, outcome or product do not count" {
  echo "$TF/pull/12" > "$TMP/linear/SIG-7"
  pr 12 2026-11-02T10:00:00Z terragrunt/products/Signstream/main.tf
  deploy_run "Terraform plan+apply Signstream (prod/eu) [a]" 2026-11-02T11:00:00Z
  deploy_run "Terraform plan+apply Signstream (stg/eu) [b]" 2026-11-02T11:00:00Z success feature
  deploy_run "Terraform plan+apply Signstream (stg/eu) [c]" 2026-11-02T11:00:00Z failure
  deploy_run "Terraform plan Signstream (stg/eu) [d]" 2026-11-02T11:00:00Z
  deploy_run "Terraform plan+apply SignstreamX (stg/eu) [e]" 2026-11-02T11:00:00Z
  deploy_run "Terraform plan+apply Signstream (stg/us) [f]" 2026-11-02T11:00:00Z
  pending "SIG-7"
  [ "$(field '.pending | length')" = 1 ]
}

@test "AC4: a full 'apply all' run for the environment counts" {
  echo "$TF/pull/12" > "$TMP/linear/SIG-7"
  pr 12 2026-11-02T10:00:00Z terragrunt/products/Signstream/main.tf
  deploy_run "Terraform apply all (stg/eu)" 2026-11-02T12:00:00Z
  pending "SIG-7"
  [ "$(field '.pending | length')" = 0 ]
}

@test "AC4: a PR touching another product needs that product applied" {
  echo "$TF/pull/13" > "$TMP/linear/SIG-8"
  pr 13 2026-11-02T10:00:00Z terragrunt/products/Hub/config/stg.yml terragrunt/products/Signstream/main.tf
  deploy_run "Terraform plan+apply Signstream (stg/eu) [gate]" 2026-11-02T11:00:00Z
  pending "SIG-8"
  [ "$(field '.pending[0].products | join(",")')" = Hub ]
  [ "$(field '.checked[0].products | join(",")')" = "Hub,Signstream" ]
}

@test "AC4: shared module changes are attributed to the promoted product" {
  echo "$TF/pull/14" > "$TMP/linear/SIG-9"
  pr 14 2026-11-02T10:00:00Z terraform/modules/sqs/main.tf
  pending "SIG-9"
  [ "$(field '.pending[0].products | join(",")')" = Signstream ]
}

@test "AC4: PRs that change no infrastructure, unmerged PRs and other repos' PRs do not block" {
  printf '%s\n' "$TF/pull/15" "$TF/pull/16" "https://github.com/signapse/sign-stream-api/pull/99" > "$TMP/linear/SIG-10"
  pr 15 2026-11-02T10:00:00Z README.md .github/workflows/orchestration.yml
  pr 16 "" terragrunt/products/Signstream/main.tf
  pending "SIG-10"
  [ "$status" -eq 0 ]
  [ "$(field '.pending | length')" = 0 ]
  [ "$(field '[.checked[] | "\(.pr):\(.state)"] | join(",")')" = "15:merged,16:unmerged" ]
  [[ "$output" == *"not merged"* ]]
}

@test "AC4: tickets without Terraform PRs pass; several tickets are all checked" {
  : > "$TMP/linear/SIG-1"
  echo "$TF/pull/12" > "$TMP/linear/SIG-2"
  pr 12 2026-11-02T10:00:00Z terragrunt/products/Signstream/main.tf
  pending " SIG-1, SIG-2 "
  [ "$(field '[.pending[].ticket] | join(",")')" = SIG-2 ]
}

@test "AC4 in dev: the orchestration merge-apply run on the merge commit counts" {
  ENVIRONMENT=dev
  echo "$TF/pull/12" > "$TMP/linear/SIG-7"
  pr 12 2026-11-02T10:00:00Z terragrunt/products/Signstream/main.tf
  echo '{"workflow_runs":[{"head_sha":"sha12","conclusion":"success"}]}' > "$TMP/orch-runs.json"
  ENVIRONMENT=dev pending "SIG-7"
  [ "$(field '.pending | length')" = 0 ]
  echo '{"workflow_runs":[{"head_sha":"sha12","conclusion":"failure"}]}' > "$TMP/orch-runs.json"
  ENVIRONMENT=dev pending "SIG-7"
  [ "$(field '.pending | length')" = 1 ]
}

@test "fails closed when Linear does not know the ticket" {
  pending "SIG-404"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linear returned no issue for SIG-404"* ]]
}

@test "no tickets: nothing pending" {
  pending ""
  [ "$status" -eq 0 ]
  [ "$(field '.pending | length')" = 0 ]
}

@test "AC4: an apply on a later page of runs counts" {
  echo "$TF/pull/12" > "$TMP/linear/SIG-1"
  pr 12 2026-11-01T10:00:00Z terragrunt/products/Signstream/stg/eu/sqs/terragrunt.hcl
  deploy_run "Terraform plan+apply Hub (stg/eu) [k1]" 2026-11-01T11:00:00Z
  echo '{"workflow_runs":[{"display_title":"Terraform plan+apply Signstream (stg/eu) [k2]","created_at":"2026-11-01T12:00:00Z","conclusion":"success","head_branch":"main"}]}' > "$TMP/deploy-runs-2.json"
  pending SIG-1
  [ "$status" -eq 0 ]
  [ "$(field '.pending | length')" = 0 ]
  grep -q 'per_page=100' "$TMP/run-queries"
}

@test "fails closed when a ticket has more attachments than one page" {
  echo "$TF/pull/12" > "$TMP/linear/SIG-1"
  pr 12 2026-11-01T10:00:00Z terragrunt/products/Signstream/stg/eu/sqs/terragrunt.hcl
  touch "$TMP/more-attachments"
  pending SIG-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than 250 attachments"* ]]
}
