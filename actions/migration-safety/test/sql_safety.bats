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
  [[ "$output" == *"BLOCK: ADD COLUMN NOT NULL accounts.region (no DEFAULT)"* ]]
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
