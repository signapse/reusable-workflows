# Migration safety

A Deployment can be rolled back automatically (a failed smoke test, for example), but the database stays on the new schema. So the previous release's code has to keep working against the schema a migration leaves behind. ADR 0001 requires every migration to be backward-compatible (expand/contract). `migration-safety.yml` enforces this on pull requests.

## What it checks

Only the migration files the PR **adds or changes** (`git diff base...head`), and only their **up** direction:

| Layout | Used by | Up direction |
|---|---|---|
| golang-migrate: `.../migrations/NNN_name.up.sql` (also `language_migrations/`) | billing-service-api, account-service-api, translation-service-api, sign-stream-platform-api | `*.up.sql`; `*.down.sql` is skipped |
| goose: `.../migrations/NNN_name.sql` | (none today) | the `-- +goose Up` section only |
| Flyway: `.../db/migration/V1__name.sql` | hub-api, video-translation-api | `V*` / `R*` files; `U*` undo files are skipped |

The SQL is read as Postgres. Comments, string literals, quoted identifiers and function bodies (`AS $$ ... $$`) are ignored. Statements inside a `DO` block (`DO $$ ... $$`, `DO LANGUAGE plpgsql $$ ... $$`, `DO '...'`) run during the migration, so they **are** checked. Statements can span lines, and keywords match in any case.

### Blocks the PR

| Statement | Why the previous code breaks |
|---|---|
| `DROP TABLE`, `DROP VIEW`, `DROP MATERIALIZED VIEW`, `DROP SCHEMA` | It still reads or writes them |
| `ALTER TABLE ... DROP [COLUMN]` | It still selects or inserts the column |
| `RENAME` of a table, column, view, schema, type, enum value or type attribute; `ALTER TABLE ... SET SCHEMA` | It still uses the old name |
| `ALTER [COLUMN] ... TYPE` / `SET DATA TYPE` | It may not read or write the new type (and the table is rewritten under lock). This includes widening (`INT` to `BIGINT`, a longer `VARCHAR`), which a reviewer can override |
| `ALTER COLUMN ... SET NOT NULL`, or `ADD [CONSTRAINT ...] CHECK (... IS NOT NULL)` (with or without `NOT VALID`, which only skips existing rows; a CHECK with an `OR` only warns) | Its INSERTs may leave the column out |
| `ADD COLUMN ... NOT NULL` or `PRIMARY KEY` with no non-null `DEFAULT`, or with one that the same migration then drops (`DROP DEFAULT` / `DROP IDENTITY`) | Its INSERTs don't know the column and fail |
| `DROP TYPE` / `DROP DOMAIN ... CASCADE` | CASCADE also drops every column of that type |

Changes to a table that the **same migration** creates with a plain `CREATE TABLE` are not flagged, because no earlier code can depend on it. `CREATE TABLE IF NOT EXISTS` doesn't count, because the table may already exist.

### Warns but passes

| Statement | Why it isn't blocking |
|---|---|
| `DROP FUNCTION` / `PROCEDURE` / `SEQUENCE` | The previous code may call them, but most are trigger functions replaced in the same migration, so the reviewer checks |
| `DROP INDEX`, `ALTER TABLE ... DROP CONSTRAINT`, `RENAME CONSTRAINT`, `ALTER INDEX ... RENAME` | The previous code's reads and writes still succeed. A dropped index or constraint costs performance or loosens a rule; it doesn't change the shape the code reads. Our migrations often drop and recreate one in the same file (billing 004 and 025). The one real break is an `ON CONFLICT` that targets the dropped unique index or names the constraint, so the warning annotation asks the reviewer to check for that |
| Other `ALTER COLUMN ... DROP DEFAULT` / `DROP IDENTITY` | They break the previous code's INSERTs that leave the column out, but only when the column is NOT NULL. The check can't see the nullability of existing columns, so the reviewer confirms every deployed writer sets the column |

### Passes silently

A new table, a nullable column, a column with a `DEFAULT`, `CREATE INDEX`, `ADD CONSTRAINT` (other than a `CHECK` with `IS NOT NULL`), `DROP NOT NULL`, data `UPDATE`s. A PR that changes no migration file prints nothing and passes. If the diff can't be computed or `migration_paths` is an invalid regex, the check fails (exit 2) rather than passing.

### Not covered

Dynamic SQL (`EXECUTE 'ALTER TABLE ...'`); non-SQL stores such as DynamoDB; MySQL-only syntax (`MODIFY`, `CHANGE`, `DROP KEY`); and proving that no code still uses a column, which is the reviewer's job when giving the override. The check also reads a changed file as a whole, so editing an old migration re-checks everything in that file.

## Adopting it

Add `.github/workflows/migration-safety.yml` to the service repo:

```yaml
name: Migration safety
on:
  pull_request:
  pull_request_review:            # needed: an override is a review, and it must re-run the check
    types: [submitted, edited, dismissed]
jobs:
  migration-safety:
    uses: signapse/reusable-workflows/.github/workflows/migration-safety.yml@main
    permissions:
      contents: read
      pull-requests: read
    with:
      reusable_workflows_ref: main   # must match the @ref above (e.g. v1 with @v1)
    #  migration_paths: '^internal/adaptors/storage/postgres/migrations/.+\.sql$'
```

Then make **`migration-safety / Migration safety`** a required status check in the repo's branch protection (a manual settings change).

| Input | Default | Meaning |
|---|---|---|
| `migration_paths` | `(^\|/)[A-Za-z0-9_-]*migrations?/.+\.sql$` | Extended regex over repo-relative paths |
| `reusable_workflows_ref` | `main` | Which ref of this repo to load the scripts from. Set it to the same ref as the `uses: ...@<ref>` pin; otherwise a `@v1` caller runs main's rules and override |

## Override

When the old shape really is unused (the contract step below), a **reviewer who is not the PR author** clears the check by **approving** the PR with this phrase anywhere in the review text:

```
allow-destructive-migration
```

The approval re-runs the check through the `pull_request_review` trigger. The check then passes and names the reviewer and their review in the log and the job summary. The override:

- must be an *Approve* review. A comment, or the PR author's own review, doesn't count. Neither do bots or anyone who isn't an owner, member or collaborator of the repo;
- is withdrawn if that reviewer later requests changes or the review is dismissed;
- survives later pushes that leave the flagged migration files unchanged. If those files change after the approval, the override goes stale and a reviewer has to approve again.

The mechanism is defined in one place, `actions/migration-safety/scripts/override.sh`. To switch to a label, CODEOWNERS or a different phrase, change it there.

## Expand/contract

Never change a shape that deployed code reads in the same release that stops reading it. Split the change across releases:

1. **Expand.** Add the new shape alongside the old: a new nullable column (or one with a `DEFAULT`), a new table, or a view. Ship code that writes both and still reads the old one. *Passes the check.*
2. **Migrate.** Backfill the new shape. Ship code that reads the new shape. *Passes.*
3. **Contract.** Once no deployed release (including the one a rollback would restore) reads the old shape, drop it in its own PR. *Blocked until a reviewer confirms no code uses it and approves with `allow-destructive-migration`.*

Examples:

- **Rename a column:** add `new_name` → write both, read `old_name` → backfill, read `new_name` → drop `old_name`.
- **Change a type:** add `col_v2` with the new type → write both → backfill and switch reads → drop `col`.
- **Make a column required:** ship code that always writes it, backfill, then `SET NOT NULL` (blocked, so the reviewer confirms that every deployed writer sets it). Alternatively add a `DEFAULT` first.
