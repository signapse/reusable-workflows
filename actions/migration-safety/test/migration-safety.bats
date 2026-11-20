#!/usr/bin/env bats
# End to end: a throwaway git repo per test, a PR branch, and a stubbed `gh`
# that serves the PR's reviews from $REVIEWS.

MIG=internal/adaptors/storage/postgres/migrations

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/migration-safety.sh"
  FX="$BATS_TEST_DIRNAME/fixtures"
  TMP="$(mktemp -d)"
  export REVIEWS="$TMP/reviews.json"
  echo '[]' >"$REVIEWS"
  mkdir -p "$TMP/stub"
  cat >"$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/gh.calls"
cat "$REVIEWS"
EOS
  chmod +x "$TMP/stub/gh"
  export PATH="$TMP/stub:$PATH"
  export GITHUB_REPOSITORY=signapse/billing-service-api PR_NUMBER=7 PR_AUTHOR=author GH_TOKEN=fake
  unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY MIGRATION_PATH_REGEX

  cd "$TMP" && mkdir repo && cd repo
  git init -q -b main
  git config user.email t@example.com && git config user.name t
  mkdir -p "$MIG"
  cp "$FX/additive.up.sql" "$MIG/001_initial.up.sql"
  echo 'package main' >main.go
  git add -A && git commit -qm base
  export BASE_SHA=$(git rev-parse HEAD)
  git checkout -qb pr
}

teardown() { rm -rf "$TMP"; }

# commit_pr: commit the working tree and point HEAD_SHA at it.
commit_pr() {
  git add -A && git commit -qm "${1:-change}"
  export HEAD_SHA=$(git rev-parse HEAD)
}

# review LOGIN STATE BODY [COMMIT] [ASSOC] [TYPE]: append a review to $REVIEWS.
review() {
  jq --arg l "$1" --arg s "$2" --arg b "$3" --arg c "${4:-$HEAD_SHA}" \
    --arg a "${5:-MEMBER}" --arg t "${6:-User}" \
    '. + [{user:{login:$l,type:$t},state:$s,body:$b,commit_id:$c,author_association:$a,
           html_url:("https://github.com/x/pull/7#pullrequestreview-" + ((length + 1) | tostring))}]' \
    "$REVIEWS" >"$REVIEWS.tmp" && mv "$REVIEWS.tmp" "$REVIEWS"
}

add_migration() { cp "$FX/$1" "$MIG/$2"; }

@test "AC4: no migration files changed -> exit 0, no output, no API call" {
  echo 'package main // changed' >main.go
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TMP/stub/gh.calls" ]
}

@test "AC4: only a .down.sql changed -> silent pass" {
  add_migration drop_table.up.sql 002_x.down.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC1: drop column fails with the reason and how to proceed" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$MIG/002_drop.up.sql:1: BLOCK: DROP COLUMN usage_events.price_modifier: the previous code still selects or inserts this column"* ]]
  [[ "$output" == *"Migration safety: FAILED"* ]]
  [[ "$output" == *"allow-destructive-migration"* ]]
}

@test "AC1: rename fails" {
  add_migration rename_column.up.sql 002_rename.up.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: RENAME COLUMN usage_records.minutes_used -> seconds_used"* ]]
}

@test "AC1: type change fails" {
  add_migration type_change.up.sql 002_type.up.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: ALTER COLUMN TYPE translation.video_duration"* ]]
}

@test "AC1: editing an existing migration to add a drop fails" {
  echo 'DROP TABLE usage_events;' >>"$MIG/001_initial.up.sql"
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"001_initial.up.sql:17: BLOCK: DROP TABLE usage_events"* ]]
}

@test "AC2: additive migration passes" {
  add_migration additive.up.sql 002_add.up.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 migration file(s) checked, no destructive change."* ]]
  [ ! -e "$TMP/stub/gh.calls" ]
}

@test "destructive change only in a migration the PR did not touch is ignored" {
  add_migration drop_column.up.sql 002_drop.up.sql
  git add -A && git commit -qm "already on main" && export BASE_SHA=$(git rev-parse HEAD)
  add_migration additive.up.sql 003_add.up.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Flyway layout is found; undo migrations are ignored" {
  mkdir -p src/main/resources/db/migration
  cp "$FX/drop_table.up.sql" src/main/resources/db/migration/U2__undo.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cp "$FX/drop_table.up.sql" src/main/resources/db/migration/V2__drop_invitation.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"db/migration/V2__drop_invitation.sql:1: BLOCK: DROP TABLE invitation"* ]]
}

@test "language_migrations/ (translation-service-api) is checked by default" {
  mkdir -p internal/adaptors/storage/postgres/language_migrations
  cp "$FX/drop_table.up.sql" internal/adaptors/storage/postgres/language_migrations/003_x.up.sql
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"language_migrations/003_x.up.sql:1: BLOCK: DROP TABLE invitation"* ]]
}

@test "fails closed (exit 2) when the base commit is missing" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  BASE_SHA=0000000000000000000000000000000000000000 run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "fails closed (exit 2) on an invalid MIGRATION_PATH_REGEX" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  MIGRATION_PATH_REGEX='(' run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "MIGRATION_PATH_REGEX narrows which files are checked" {
  mkdir -p tools/migrations
  cp "$FX/drop_table.up.sql" tools/migrations/x.up.sql
  commit_pr
  MIGRATION_PATH_REGEX='^internal/.*\.sql$' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "GitHub mode writes annotations and a step summary" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$TMP/summary.md" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error file=$MIG/002_drop.up.sql,line=1,title=Destructive migration::"* ]]
  grep -q '### Migration safety: failed' "$TMP/summary.md"
}

@test "AC3: approving review with the phrase from another member passes, naming the reviewer" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly APPROVED "$(printf 'Checked no code reads price_modifier.\r\n  `Allow-Destructive-Migration`  ')"
  GITHUB_ACTIONS=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"destructive change allowed by @olly: https://github.com/x/pull/7#pullrequestreview-1"* ]]
  [[ "$output" == *"::notice title=Destructive migration overridden::"* ]]
  grep -q 'repos/signapse/billing-service-api/pulls/7/reviews' "$TMP/stub/gh.calls"
}

@test "override: the PR author cannot override their own PR" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review author APPROVED "allow-destructive-migration"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "override: an approval without the phrase does not count" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly APPROVED "LGTM"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "override: the phrase must be a line of its own, so a negation does not count" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly APPROVED "Approving the rest, but do NOT allow-destructive-migration yet"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  review kat APPROVED "$(printf 'not-allow-destructive-migration\nallow-destructive-migrations')"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "override: the phrase in a comment-only review does not count" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly COMMENTED "allow-destructive-migration"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "override: bots and outside contributors do not count" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review coderabbitai APPROVED "allow-destructive-migration" "$HEAD_SHA" NONE Bot
  review stranger APPROVED "allow-destructive-migration" "$HEAD_SHA" CONTRIBUTOR
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "override: withdrawn by a later request-changes or a dismissal" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly APPROVED "allow-destructive-migration"
  review olly CHANGES_REQUESTED "actually, wait"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  echo '[]' >"$REVIEWS"
  review olly DISMISSED "allow-destructive-migration"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "override: a later plain approval keeps the earlier override" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly APPROVED "allow-destructive-migration"
  review olly APPROVED "still fine"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "override: survives unrelated pushes, goes stale when the migration changes" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly APPROVED "allow-destructive-migration"
  echo 'package main // later fix' >main.go
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  echo 'ALTER TABLE usage_events DROP COLUMN source;' >>"$MIG/002_drop.up.sql"
  commit_pr
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"override by @olly"*"is stale"* ]]
}

@test "override: an approval on a commit not in history is stale" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review olly APPROVED "allow-destructive-migration" 0000000000000000000000000000000000000000
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "override: reviews API failure fails closed" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/stub/gh"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not list PR reviews"* ]]
}

@test "override: paginated reviews (one array per page) are joined" {
  add_migration drop_column.up.sql 002_drop.up.sql
  commit_pr
  review someone COMMENTED "first page"
  page1=$(cat "$REVIEWS")
  echo '[]' >"$REVIEWS"
  review olly APPROVED "allow-destructive-migration"
  printf '%s%s' "$page1" "$(cat "$REVIEWS")" >"$REVIEWS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
