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
  # STAGING_CHECK_PATTERN is a jq test() regex over check-run names
  # (default 'staging|smoke'). Empty disables the gate entirely.
  local repo="$1" sha="$2"
  local pattern="${STAGING_CHECK_PATTERN-staging|smoke}"
  if [ -z "$pattern" ]; then
    echo true
    return 0
  fi
  # shellcheck disable=SC2016 # jq $s / $pattern bindings, not shell expansion.
  gh api "repos/$repo/commits/$sha/check-runs" \
    | jq -c --arg pattern "$pattern" \
      '[.check_runs[] | select(.name | test($pattern; "i"))] as $s
       | if ($s|length) == 0 then true
         else all($s[]; .conclusion == "success") end'
}
