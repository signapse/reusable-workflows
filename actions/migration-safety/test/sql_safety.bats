#!/usr/bin/env bats
# Statement-level rules of sql_safety.py, one fixture migration each.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/sql_safety.py"
  FX="$BATS_TEST_DIRNAME/fixtures"
}

check() { run python3 "$SCRIPT" "$FX/$1"; }

@test "drop column fails with file, line and reason" {
  check drop_column.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"drop_column.up.sql:1: BLOCK: DROP COLUMN usage_events.price_modifier: the previous code still selects or inserts this column"* ]]
}

@test "drop table fails" {
  check drop_table.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: DROP TABLE invitation"* ]]
}

@test "rename column across lines fails, reported on the RENAME line" {
  check rename_column.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"rename_column.up.sql:2: BLOCK: RENAME COLUMN usage_records.minutes_used -> seconds_used"* ]]
}

@test "lower-case rename of a quoted table fails" {
  check rename_table.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: RENAME TABLE invoices -> billing_invoices"* ]]
}

@test "ALTER COLUMN TYPE and SET DATA TYPE both fail" {
  check type_change.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *":1: BLOCK: ALTER COLUMN TYPE translation.video_duration"* ]]
  [[ "$output" == *":2: BLOCK: ALTER COLUMN TYPE translation.size"* ]]
}

@test "SET NOT NULL on an existing column fails" {
  check set_not_null.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: SET NOT NULL gloss_signs.language_id"* ]]
}

@test "ADD COLUMN NOT NULL without DEFAULT fails" {
  check add_not_null_no_default.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: ADD COLUMN NOT NULL accounts.region (no non-null DEFAULT)"* ]]
}

@test "additive migration passes with no output" {
  check additive.up.sql
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "DROP INDEX / DROP CONSTRAINT warn but do not fail" {
  check index_constraint_swap.up.sql
  [ "$status" -eq 0 ]
  [[ "$output" == *":2: warn: DROP INDEX uq_running_account_add_on"* ]]
  [[ "$output" == *":10: warn: DROP CONSTRAINT account_subscriptions.uq_one_non_ended_subscription_per_product_tier"* ]]
  [[ "$output" != *BLOCK* ]]
}

@test "comments, strings, quoted identifiers and function bodies are not matched" {
  check comments_and_strings.up.sql
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "DDL inside a DO block runs at migration time and is checked" {
  check do_block.up.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *"do_block.up.sql:4: BLOCK: DROP COLUMN users.legacy"* ]]
}

@test "changes to a table created in the same migration pass" {
  check same_migration_table.up.sql
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "goose: only the Up section is checked" {
  check goose_up_down.sql
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  check goose_destructive.sql
  [ "$status" -eq 1 ]
  [[ "$output" == *":2: BLOCK: DROP COLUMN feature_flags.key"* ]]
  [ "$(grep -c BLOCK <<<"$output")" -eq 1 ]
}

@test "real billing-service-api 006_rate_micros: every type change, rename and drop, and nothing in its DO block" {
  check billing_006_rate_micros.up.sql
  [ "$status" -eq 1 ]
  [ "$(grep -c 'BLOCK: ALTER COLUMN TYPE' <<<"$output")" -eq 6 ]
  [ "$(grep -c 'BLOCK: RENAME COLUMN' <<<"$output")" -eq 5 ]
  [[ "$output" == *":68: BLOCK: DROP COLUMN usage_events.price_modifier"* ]]
  [ "$(grep -c BLOCK <<<"$output")" -eq 12 ]
}

@test "--format github adds error annotations" {
  run python3 "$SCRIPT" --format github "$FX/drop_column.up.sql"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error file=$FX/drop_column.up.sql,line=1,title=Destructive migration::DROP COLUMN usage_events.price_modifier"* ]]
}

@test "missing file is a usage error (exit 2)" {
  run python3 "$SCRIPT" "$FX/does-not-exist.sql"
  [ "$status" -eq 2 ]
}

# --- edge cases raised in review (PR #38) -----------------------------------

sql() { printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/m.up.sql"; run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/m.up.sql"; }

@test "DO LANGUAGE plpgsql \$\$ body is checked" {
  sql 'DO LANGUAGE plpgsql $$ BEGIN ALTER TABLE users DROP COLUMN legacy; END $$;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROP COLUMN users.legacy"* ]]
}

@test "DO LANGUAGE with a quoted or string language name is checked" {
  sql 'DO LANGUAGE "plpgsql" $$ BEGIN ALTER TABLE users DROP COLUMN legacy; END $$;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROP COLUMN users.legacy"* ]]
  sql "DO LANGUAGE 'plpgsql' \$\$ BEGIN ALTER TABLE users DROP COLUMN legacy; END \$\$;"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROP COLUMN users.legacy"* ]]
}

@test "single-quoted DO body is checked" {
  sql "DO 'BEGIN ALTER TABLE users DROP COLUMN legacy; END';"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DROP COLUMN users.legacy"* ]]
}

@test "ALTER VIEW ... SET SCHEMA fails" {
  sql 'ALTER MATERIALIZED VIEW reporting.daily SET SCHEMA archive;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: SET SCHEMA reporting.daily -> schema archive (view)"* ]]
}

@test "ADD COLUMN ... PRIMARY KEY without default fails" {
  sql 'ALTER TABLE tenants ADD COLUMN tenant_id bigint PRIMARY KEY;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"ADD COLUMN NOT NULL tenants.tenant_id"* ]]
}

@test "ADD COLUMN NOT NULL DEFAULT NULL fails; so does ADD COLUMN ... CHECK (x IS NOT NULL)" {
  sql 'ALTER TABLE accounts ADD COLUMN region text NOT NULL DEFAULT NULL;'
  [ "$status" -eq 1 ]
  sql 'ALTER TABLE accounts ADD COLUMN region text CHECK (region IS NOT NULL);'
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: CHECK NOT NULL accounts"* ]]
}

@test "ADD CONSTRAINT CHECK (x IS NOT NULL) blocks like SET NOT NULL, NOT VALID too" {
  sql 'ALTER TABLE users ADD CONSTRAINT email_nn CHECK (email IS NOT NULL);'
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: CHECK NOT NULL users"* ]]
  sql 'ALTER TABLE users ADD CONSTRAINT email_nn CHECK (email IS NOT NULL) NOT VALID;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: CHECK NOT NULL users"* ]]
  sql 'ALTER TABLE users ADD CONSTRAINT c CHECK ((coalesce(a, 0) > 0) AND (b IS NOT NULL));'
  [ "$status" -eq 1 ]
  # IS NOT NULL outside the CHECK expression is not a CHECK NOT NULL.
  sql 'ALTER TABLE users ADD COLUMN x boolean CHECK (x) DEFAULT (1 IS NOT NULL);'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "DROP DEFAULT / DROP IDENTITY warn; DROP DEFAULT on a column just added NOT NULL blocks" {
  sql 'ALTER TABLE users ALTER COLUMN created_at DROP DEFAULT;'
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn: DROP DEFAULT users.created_at"* ]]
  sql 'ALTER TABLE users ALTER COLUMN id DROP IDENTITY IF EXISTS;'
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn: DROP IDENTITY users.id"* ]]
  sql 'ALTER TABLE users ADD CONSTRAINT age_pos CHECK (age > 0), ALTER COLUMN bio DROP NOT NULL;'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # account-service-api 017's shape: add NOT NULL with a default, then drop it.
  printf '%s\n' 'ALTER TABLE accounts ADD COLUMN tier text NOT NULL DEFAULT '"'"'free'"'"';' \
    'ALTER TABLE accounts ALTER COLUMN tier DROP DEFAULT;' > "$BATS_TEST_TMPDIR/m.up.sql"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/m.up.sql"
  [ "$status" -eq 1 ]
  [[ "$output" == *":2: BLOCK: DROP DEFAULT accounts.tier"* ]]
}

@test "quoted identifier with an escaped quote is still parsed" {
  sql 'ALTER TABLE accounts RENAME COLUMN "old""column" TO current_column;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: RENAME COLUMN accounts."* ]]
}

@test "CREATE TABLE IF NOT EXISTS does not exempt later drops (table may already exist)" {
  sql $'CREATE TABLE IF NOT EXISTS users (id bigint);\nALTER TABLE users DROP COLUMN email;'
  [ "$status" -eq 1 ]
  [[ "$output" == *":2: BLOCK: DROP COLUMN users.email"* ]]
}

@test "DROP TYPE CASCADE fails; DROP FUNCTION warns; plain DROP TYPE passes" {
  sql 'DROP TYPE IF EXISTS status_enum CASCADE;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK: DROP TYPE CASCADE status_enum"* ]]
  sql 'DROP FUNCTION IF EXISTS touch_updated_at;'
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn: DROP ROUTINE touch_updated_at"* ]]
  sql 'DROP TYPE IF EXISTS status_enum;'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "goose: line numbers stay right with text before -- +goose Up" {
  sql $'-- header\n-- more\n\n-- +goose Up\nALTER TABLE t DROP COLUMN c;\n-- +goose Down\nALTER TABLE t ADD COLUMN c int;'
  [ "$status" -eq 1 ]
  [[ "$output" == *"m.up.sql:5: BLOCK: DROP COLUMN t.c"* ]]
}

@test "non-UTF-8 file is an error (exit 2), not a blocked migration" {
  printf 'ALTER TABLE t ADD COLUMN c text DEFAULT \xff;\n' >"$BATS_TEST_TMPDIR/bad.up.sql"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/bad.up.sql"
  [ "$status" -eq 2 ]
}
