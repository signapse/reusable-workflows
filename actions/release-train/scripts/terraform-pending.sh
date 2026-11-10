#!/usr/bin/env bash
# terraform-pending.sh <tickets>
#
# AC4 of SIG-2765: a ticket whose signapse-core-terraform PR is merged but not
# applied in the target environment blocks the Promotion of its build. Run it
# AFTER terraform-gate.sh: the gate's own apply of PRODUCT then counts.
#
#   <tickets>  comma-separated tickets in the Release Candidate (SIG-1,SIG-2)
#
# Signal, read fresh every run (no state of our own):
#   1. The ticket's Terraform PRs are its Linear attachments whose URL is
#      https://github.com/<TF_REPO>/pull/<n> (the GitHub integration links a
#      PR whose branch or title carries the ticket ID; the spec requires
#      Terraform PRs to carry it). Unmerged PRs are ignored with a warning:
#      AC4 is about merged-but-unapplied changes.
#   2. The products a PR changes: terragrunt/products/<P>/... -> P. Any other
#      terraform/ or terragrunt/ path (modules, root.hcl) is attributed to
#      PRODUCT, the product being promoted. Other paths (docs, CI) change no
#      infrastructure and are ignored.
#   3. A PR is applied in ENVIRONMENT for product P when a terraform-deploy run
#      on main that applies P (title "Terraform plan+apply P (env/region)",
#      "Terraform apply P (...)" or "Terraform apply all (...)") concluded
#      success and was CREATED AT OR AFTER the PR's merge. A dispatch on main
#      runs main's tip at dispatch time, so it contains every PR merged before
#      it; a successful plan+apply run means the environment matched main for
#      that product (no_changes, or safe and applied). In dev, a successful
#      orchestration.yml push run on the PR's merge commit (merge-apply-dev)
#      also counts.
#   Not counted: /apply-stg and /apply-prod comment runs of orchestration.yml
#   (their run records neither the PR nor the environment in a readable
#   form). Such a PR blocks until a terraform-deploy apply for that product
#   runs; for PRODUCT the gate itself is that run.
#
# Env: PRODUCT, ENVIRONMENT (dev|stg|prod), LINEAR_API_KEY, GH_TOKEN
#      (pull-requests: read and actions: read on TF_REPO), TF_REPO, TF_WORKFLOW,
#      TF_REGION (as terraform-gate.sh), ORCHESTRATION_WORKFLOW
#      (default orchestration.yml).
# Stdout: {"pending": [{ticket, pr, url, merged_at, products: [unapplied]}]}
# Exit 0 with that object; exit 1 when Linear or GitHub cannot be read
# (fail closed: an unknown is not "applied").

# shellcheck source=SCRIPTDIR/../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=SCRIPTDIR/../lib/linear.sh
source "$(dirname "$0")/../lib/linear.sh"

[ $# -eq 1 ] || die "usage: terraform-pending.sh <tickets>"
need gh
need jq
need curl

: "${PRODUCT:?PRODUCT not set}"
: "${ENVIRONMENT:?ENVIRONMENT not set}"
TF_REPO="${TF_REPO:-signapse/signapse-core-terraform}"
TF_WORKFLOW="${TF_WORKFLOW:-terraform-deploy.yml}"
TF_REGION="${TF_REGION:-eu}"
ORCHESTRATION_WORKFLOW="${ORCHESTRATION_WORKFLOW:-orchestration.yml}"
case "$ENVIRONMENT" in dev | stg | prod) ;; *) die "ENVIRONMENT must be dev, stg or prod (got '$ENVIRONMENT')" ;; esac

tickets=$(csv_json "$1" | jq -r '.[]')

# ERE-escape the repo for the URL match (only . is special in owner/name).
repo_re=$(printf '%s' "$TF_REPO" | sed 's/\./\\./g')

# applied <product> <merged_at> <merge_sha>: exit 0 when applied (see 3.).
applied() {
  local p="$1" merged_at="$2" sha="$3" runs
  # Every page: runs for other products can push P's apply past the first.
  runs=$(gh api --paginate "repos/${TF_REPO}/actions/workflows/${TF_WORKFLOW}/runs?branch=main&status=success&created=>=${merged_at}&per_page=100") \
    || die "cannot list ${TF_WORKFLOW} runs on ${TF_REPO}"
  # shellcheck disable=SC2016 # jq bindings, not shell expansion.
  if jq -se --arg p "$p" --arg env "$ENVIRONMENT" --arg region "$TF_REGION" --arg since "$merged_at" '
      [.[].workflow_runs[]?
       | select(.head_branch == "main" and .conclusion == "success" and .created_at >= $since)
       | .display_title
       | select(test("^Terraform (plan\\+apply|apply) (" + $p + "|all) \\(" + $env + "/" + $region + "\\)"))]
      | length > 0' <<< "$runs" > /dev/null; then
    return 0
  fi
  if [ "$ENVIRONMENT" = dev ]; then
    runs=$(gh api "repos/${TF_REPO}/actions/workflows/${ORCHESTRATION_WORKFLOW}/runs?event=push&head_sha=${sha}&per_page=20") \
      || die "cannot list ${ORCHESTRATION_WORKFLOW} runs on ${TF_REPO}"
    jq -e --arg sha "$sha" '[.workflow_runs[]? | select(.head_sha == $sha and .conclusion == "success")] | length > 0' \
      <<< "$runs" > /dev/null && return 0
  fi
  return 1
}

pending='[]'
while IFS= read -r t; do
  [ -n "$t" ] || continue
  # shellcheck disable=SC2016 # GraphQL variable, not shell expansion.
  resp=$(linear_query 'query($id:String!){issue(id:$id){identifier attachments(first:250){nodes{url} pageInfo{hasNextPage}}}}' \
    "$(jq -nc --arg id "$t" '{id:$id}')") || die "Linear query for $t failed"
  urls=$(jq -r '
    if ((.errors // []) | length > 0) or .data.issue == null then error("no issue")
    else .data.issue.attachments.nodes[]?.url end' <<< "$resp" 2> /dev/null) \
    || die "Linear returned no issue for $t: $resp"
  # Fail closed rather than miss a Terraform PR on a later page.
  [ "$(jq -r '.data.issue.attachments.pageInfo.hasNextPage // false' <<< "$resp")" != true ] \
    || die "$t has more than 250 attachments; cannot check them all for Terraform PRs"

  prs=$(printf '%s\n' "$urls" | grep -ioE "^https://github\.com/${repo_re}/pull/[0-9]+" | sed -E 's#.*/##' | sort -un || true)
  for n in $prs; do
    pr=$(gh api "repos/${TF_REPO}/pulls/${n}") || die "cannot read ${TF_REPO}#${n} (linked from ${t})"
    merged_at=$(jq -r '.merged_at // ""' <<< "$pr")
    url=$(jq -r '.html_url' <<< "$pr")
    if [ -z "$merged_at" ]; then
      log "warning: ${t} links ${TF_REPO}#${n}, which is not merged; it does not block (AC4 covers merged PRs)"
      continue
    fi
    sha=$(jq -r '.merge_commit_sha' <<< "$pr")
    # A rename counts for both paths: moving a product's file away changes it.
    files=$(gh api --paginate "repos/${TF_REPO}/pulls/${n}/files?per_page=100" | jq -r '.[] | .filename, (.previous_filename // empty)') \
      || die "cannot list files of ${TF_REPO}#${n}"
    products=$(printf '%s\n' "$files" | awk -v self="$PRODUCT" '
      /^terragrunt\/products\/[^\/]+\// { split($0, a, "/"); print a[3]; next }
      /^(terraform|terragrunt)\// { print self }' | sort -u)

    unapplied=()
    for p in $products; do
      if applied "$p" "$merged_at" "$sha"; then
        log "${TF_REPO}#${n} (${t}) is applied for ${p} in ${ENVIRONMENT}"
      else
        log "${TF_REPO}#${n} (${t}) is merged but NOT applied for ${p} in ${ENVIRONMENT}"
        unapplied+=("$p")
      fi
    done
    if [ "${#unapplied[@]}" -gt 0 ]; then
      ulist=$(printf '%s\n' "${unapplied[@]}" | jq -R . | jq -sc .)
      pending=$(jq -c --arg t "$t" --argjson n "$n" --arg url "$url" --arg m "$merged_at" --argjson p "$ulist" \
        '. + [{ticket: $t, pr: $n, url: $url, merged_at: $m, products: $p}]' <<< "$pending")
    fi
  done
done <<< "$tickets"

jq -nc --argjson p "$pending" '{pending: $p}'
