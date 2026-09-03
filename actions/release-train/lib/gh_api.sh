#!/usr/bin/env bash
# gh_api.sh — thin wrappers over `gh` CLI. Requires GITHUB_TOKEN in env.

gh_prs_since_tag() {
  # $1=owner/repo, $2=last-tag, $3=head-sha
  local repo="$1" since="$2" head="$3"
  local shas
  shas=$(gh api --paginate "repos/$repo/compare/${since}...${head}" --jq \
    '.commits[].sha')
  if [ -z "$shas" ]; then
    echo '[]'
    return 0
  fi
  echo "$shas" \
    | while IFS= read -r sha; do
        gh pr list --repo "$repo" --search "$sha" --state merged --json number,title,author,labels
      done \
    | jq -sc 'add // [] | unique_by(.number)'
}

gh_staging_ok() {
  # $1=owner/repo, $2=head-sha
  local repo="$1" sha="$2"
  # shellcheck disable=SC2016 # jq $s binding, not shell expansion.
  gh api "repos/$repo/commits/$sha/check-runs" --jq \
    '[.check_runs[] | select(.name | test("staging|smoke"; "i"))] as $s
     | if ($s|length) == 0 then true
       else all($s[]; .conclusion == "success") end'
}
