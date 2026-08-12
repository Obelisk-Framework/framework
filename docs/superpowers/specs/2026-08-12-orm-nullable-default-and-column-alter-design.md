# ORM: NOT NULL-by-default columns and dual-dialect column alteration

**Goal:** Flip the ORM's `Blueprint` column builders to default every column to `NOT NULL` (matching `id()`'s existing behavior), replace the `nullable()`/`notNullable()` pair with a single `nullable(value)` method, and add a `:change()` capability so an existing column's definition (nullability, type, length, default) can be altered in a later migration — correctly, across both MySQL and PostgreSQL, without MySQL's `MODIFY COLUMN` silently dropping attributes the migration didn't restate.

**Source of this change:** surfaced while designing a migration for a new `streamer_entities` table; the entity streamer feature itself is parked until this lands, since its migration should be written against the final nullable semantics, not semantics about to change.

## Architecture

- `Blueprint:nullable(value)` (`core/core/server/ORM/Schema.lua`) replaces both `nullable()` and `notNullable()`. `value` defaults to `true` when omitted, so `:nullable()` still reads naturally; `:nullable(false)` is the only way to require a column. `notNullable()` is deleted from `Blueprint` entirely — any surviving call site becomes a hard Lua error (`attempt to call a nil value`), which is what makes the migration-file audit (below) mechanically verifiable rather than a best-effort grep.
- Every column builder (`string`, `integer`, `bigInteger`, `unsignedInteger`, `float`, `decimal`, `boolean`, `json`, `text`, `date`, `datetime`, `timestamp`, `enum`) flips its default from `nullable = true` to `nullable = false`. `id()` is unaffected (already `nullable = false`).
- `Blueprint:change()` marks the most-recently-defined column on the current `Schema.table(...)` blueprint as an alteration rather than an addition (`self.columns[#self.columns].change = true`), the same mutate-the-last-column pattern `nullable()`/`default()`/`unsigned()` already use.
- `Schema.table(...)`'s statement builder branches per column: columns without the `change` marker keep generating `ADD COLUMN` (unchanged, existing behavior); `change`-marked columns go through the new dialect path below.
- New dialect contract, one addition per dialect module:
  - `dialect.introspectColumn(tableName, columnName) -> { type, length, nullable, default } | nil` — queries `information_schema.columns` (MySQL) or `information_schema.columns` + `pg_catalog.pg_attrdef` (Postgres, for accurate default-expression text) at migration-run time. Returns `nil` if the column doesn't exist.
  - `dialect.alterModifyColumnStatements(tableName, col, currentInfo, q) -> string[]` — MySQL merges `col`'s explicitly-set fields over `currentInfo`'s introspected ones and emits one full `MODIFY COLUMN` statement (MySQL redefines the entire column in one clause, so anything not restated would otherwise be dropped). Postgres emits one independent `ALTER COLUMN` clause per attribute that actually changed (`TYPE`, `SET/DROP NOT NULL`, `SET/DROP DEFAULT`), skipping whichever weren't touched — no merge/introspection-driven restatement needed there.

## Components & File Structure

```
core/core/server/ORM/
  Schema.lua          -- Blueprint:nullable(value) replaces nullable()/notNullable();
                          every column-builder default flips to nullable=false;
                          Blueprint:change() marker; Schema.table()'s per-column branch
  Dialects/
    Init.lua           -- unchanged (dialect selection/dispatch)
    MySQL.lua           -- + introspectColumn(), + alterModifyColumnStatements()
    Postgres.lua        -- + introspectColumn(), + alterModifyColumnStatements()
```

No new files. `:change()` is a natural extension of the create-table column-builder API `Schema.lua`/`Dialects/` already own.

## Migration Audit

One-time, mechanical, repo-wide, done as part of shipping this change. For every `*.lua` file under `core/server/database/migrations/`, `modules/*/server/migrations/`, `plugins/*/server/migrations/`:

1. Delete every `:notNullable()` call — it's now the default, so removing it is a pure no-op under the new semantics.
2. For every column with **neither** `:nullable()` nor `:notNullable()` today, add an explicit `:nullable()` — under the *old* default those columns were nullable; without this step the *new* default (`false`) would silently make them required on a fresh install, while every already-provisioned database keeps the old, now-mismatched schema. This is the step that actually preserves behavior; step 1 alone would be safe on its own but step 2 is what prevents drift between fresh and existing databases.
3. Verify via the audit script (see Testing) that every migration file still loads without error and, where feasible, that a fresh migration run produces column-for-column identical `NOT NULL`-ness to before the flip.

## Data Flow & Error Handling

- **Create-time (`Schema.create`)**: unchanged — `Blueprint:toSql()` still walks `self.columns` and emits one `CREATE TABLE`. Only the *default* `nullable` value each builder method inserts has changed.
- **Alter-time, new column (`Schema.table`, no `:change()`)**: unchanged — one `ADD COLUMN` per new column, exactly as today.
- **Alter-time, changed column (`Schema.table`, with `:change()`)**:
  1. The statement loop sees `col.change == true` and calls `dialect.introspectColumn(tableName, col.name)`.
  2. Calls `dialect.alterModifyColumnStatements(tableName, col, currentInfo, q)`, which merges `col`'s explicitly-set fields over `currentInfo`'s introspected ones for anything unstated, returning the dialect-correct statement(s).
  3. If `introspectColumn` returns `nil` (typo, wrong table, already-renamed column), `Schema.table` raises a clear Lua error naming the table and column — it never silently emits a no-op `ALTER`.
- **Audit failure mode**: a migration file that still calls the deleted `:notNullable()` errors the instant it's loaded/run (Lua nil-call), which is the audit's actual pass/fail signal — see Testing.

## Testing

- **`Blueprint` unit tests** (extend `core/tests/orm_spec.lua` or a new `schema_spec.lua`, plain `lua5.4`, no live DB): assert `:nullable()` / `:nullable(false)` / bare column builders produce the correct `nullable` flag; assert `:change()` marks only the most-recently-defined column.
- **Dialect unit tests** (fixed "current column" fixture, no live DB): for both `MySQL.lua` and `Postgres.lua`, feed a fixture like `{type='varchar', length=100, nullable=true, default=nil}` plus a `:change()`'d column that only sets `nullable(false)`, and assert the generated SQL is exactly right — for MySQL, confirm the emitted `MODIFY COLUMN` restates the original `varchar(100)` even though the migration never mentioned it (this is the test that catches the "silently drops the default" class of bug); for Postgres, confirm only a `SET NOT NULL` clause is emitted.
- **Integration/live-DB check** (manual, both dialects — this repo's test suite doesn't spin up a real database): run one `Schema.create` plus one `Schema.table(...):change()` against a real MariaDB (the existing `docker-compose.yml` service) and a one-off Postgres container, confirm `DESCRIBE`/`\d` shows the expected column state after each step. Not automatable in this repo's current test setup; a manual verification step in the implementation plan, not a spec file.
- **Audit verification**: a script that `dofile`s every migration file across `core`/`modules/*`/`plugins/*` and asserts none of them error — this is the audit's pass/fail gate, ideally wired into CI alongside the existing `npm test` step so a future migration can't reintroduce `:notNullable()`.

## Out of Scope

- The entity streamer feature this was spun out of — parked, resumes once this lands.
- Any retroactive `ALTER` of already-provisioned databases' existing columns — the audit only concerns what *future* migrations generate; it does not touch already-applied schema state.
