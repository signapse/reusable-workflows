#!/usr/bin/env bash
# Migration safety check for one pull request.
#
# Finds the SQL migration files the PR adds or changes, checks their "up"
# direction with sql_safety.py, and fails on a change that would break a
# rollback to the previous code, unless a reviewer has given the override
# (see override.sh).
#
# Run from the repo checkout at HEAD_SHA (history must contain BASE_SHA).
# Env:
#   BASE_SHA, HEAD_SHA        PR base and head commits (required)
#   MIGRATION_PATH_REGEX      ERE for migration paths (default below)
#   GITHUB_REPOSITORY, PR_NUMBER, PR_AUTHOR, GH_TOKEN
#                             needed only when a destructive change is found
#   GITHUB_ACTIONS=true       emit ::error/::warning annotations
#   GITHUB_STEP_SUMMARY       if set, a summary is appended to it
# Exit: 0 pass (silent when no migration changed), 1 blocked, 2 error.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/override.sh
source "$here/override.sh"

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
# golang-migrate (migrations/NNN_x.up.sql), goose (migrations/NNN_x.sql) and
# Flyway (db/migration/V1__x.sql).
regex="${MIGRATION_PATH_REGEX:-(^|/)migrations?/.+\.sql$}"

files=()
while IFS= read -r f; do
  case "$f" in
    *.down.sql) continue ;;          # golang-migrate down direction
  esac
  case "$(basename "$f")" in
    U[0-9]*__*.sql) continue ;;      # Flyway undo migration
  esac
  files+=("$f")
done < <(git diff --name-only --diff-filter=AMR "${BASE_SHA}...${HEAD_SHA}" | grep -E -- "$regex" || true)

[ "${#files[@]}" -gt 0 ] || exit 0

fmt=plain
[ "${GITHUB_ACTIONS:-}" = "true" ] && fmt=github

rc=0
report=$(python3 "$here/sql_safety.py" --format "$fmt" "${files[@]}") || rc=$?
[ -z "$report" ] || printf '%s\n' "$report"
[ "$rc" -le 1 ] || exit "$rc"

summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"; }
findings() { grep -E ':[0-9]+: (BLOCK|warn): ' <<<"$report" | sed 's/^/    /' || true; }

if [ "$rc" -eq 0 ]; then
  echo "Migration safety: ${#files[@]} migration file(s) checked, no destructive change."
  summary "### Migration safety: passed" "" "${#files[@]} migration file(s) checked, no destructive change." "" '```' "$(findings)" '```'
  exit 0
fi

blocked=()
while IFS= read -r f; do blocked+=("$f"); done < <(grep -E ':[0-9]+: BLOCK: ' <<<"$report" | sed -E 's/:[0-9]+: BLOCK: .*//' | sort -u)

if hit=$(find_override "${blocked[@]}"); then
  login=${hit%%$'\t'*}
  url=${hit#*$'\t'}
  echo "Migration safety: destructive change allowed by @${login}: ${url}"
  [ "$fmt" = github ] && echo "::notice title=Destructive migration overridden::Allowed by @${login} (${url})"
  summary "### Migration safety: overridden by @${login}" "" "Review: ${url}" "" '```' "$(findings)" '```'
  exit 0
fi

cat <<EOF

Migration safety: FAILED. The migration(s) above would break a rollback:
the previous release still runs against this database after a rollback.
Use expand/contract: add the new shape now, move the code over, and remove the
old shape in a later release once no deployed code uses it.

If no deployed code uses the old shape any more, a reviewer (not the author)
can approve this PR with "${OVERRIDE_PHRASE}" in the review text.
EOF
summary "### Migration safety: failed" "" '```' "$(findings)" '```' "" \
  "Use expand/contract, or a reviewer (not the author) approves with \`${OVERRIDE_PHRASE}\` in the review text."
exit 1
