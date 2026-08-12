# ORM Nullable-Default Flip and Column-Alter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flip the ORM's `Blueprint` column builders to default every column to `NOT NULL`, replace `nullable()`/`notNullable()` with a single `nullable(value)`, add dual-dialect `:change()` support for altering an existing column, and rewrite every migration file in the repo (58 files across `core`, 6 modules, 3 plugins) so fresh installs keep producing the exact same schema as before the flip.

**Architecture:** All ORM changes live in `core/core/server/ORM/Schema.lua` and `core/core/server/ORM/Dialects/{MySQL,Postgres}.lua`. `Blueprint:change()` marks the last-defined column as an alteration; `Schema.table()` branches per column between the existing `ADD COLUMN` path and a new dialect-driven `ALTER`/`MODIFY COLUMN` path that introspects the column's live state first (MySQL must restate the whole column in one `MODIFY COLUMN`, or it silently drops whatever wasn't restated; Postgres emits independent per-attribute `ALTER COLUMN` clauses instead). The migration-file rewrite is mechanical and repo-by-repo, verified by a reusable audit script that actually *runs* each migration's `up()` against a stubbed `Schema`/`Database` (not just `dofile`s the file — a stray call to the removed `notNullable()` only errors when the closure is invoked, not when the file is loaded).

**Tech Stack:** Lua 5.4, this repo's own ORM (`core/server/ORM/`), `lua5.4` as the test runner (plain scripts, no busted), `Database.dialect`'s `mysql`/`postgres` implementations.

## Global Constraints

- No live-database automated tests — this repo's test suite runs pure-Lua logic against stubbed `Database.querySync`, never a real MySQL/Postgres connection (see `tests/orm_spec.lua`'s own header comment). Any DB-integration verification is a manual plan step, not a test file.
- Tests run individually: `lua5.4 <path>.lua` from the repo root, matching `tests/orm_spec.lua`'s own invocation convention (`arg[0]:match('(.*/)')` for path resolution).
- `notNullable()` must be fully removed from `Blueprint` — not deprecated, not aliased. Any remaining call site anywhere in the repo must become a hard Lua error the moment it runs.
- Every column builder except `id()` flips its default from `nullable = true` to `nullable = false`. `id()` (`nullable = false` already) is unaffected.
- No Claude co-authorship in any commit. Minimize em/en dashes in prose (commit messages, docs), not code/SQL.
- This is a breaking change to `Blueprint`'s public API — it must land as ONE atomic state per repo: a repo's migrations must never sit in a half-rewritten state where some files call `:notNullable()` (now a hard error) and others don't, since running migrations top-to-bottom on a fresh install would fail partway through. Each audit task (6-9 below) rewrites and verifies its entire repo's migration set before committing.

---

## File Structure

```
core/core/server/ORM/
  Schema.lua                          -- Blueprint:nullable(value), column-builder
                                          default flip, Blueprint:change(),
                                          Schema.table()'s per-column branch
  Dialects/
    MySQL.lua                          -- + introspectColumn(), + alterModifyColumnStatements()
    Postgres.lua                       -- + introspectColumn(), + alterModifyColumnStatements()

core/tests/
  orm_spec.lua                         -- 2 existing :notNullable() call sites fixed;
                                          new tests for nullable(value)/:change()/introspection
  support/
    audit_migrations.lua               -- new: reusable audit function, given a directory,
                                          loads + runs every migration's up() against a
                                          stubbed Schema/Database, returns pass/fail per file
  migration_audit_spec.lua             -- new: runs the audit against core's own migrations,
                                          wired into package.json's "test" script and CI

core/server/database/migrations/*.lua  -- 9 files, notNullable() removed, nullable() added
                                          where the old implicit default was relied on
modules/oblsk_accounts/server/migrations/*.lua       -- 3 files
modules/oblsk_characters/server/migrations/*.lua     -- 4 files
modules/oblsk_items/server/migrations/*.lua          -- 2 files
modules/oblsk_organizations/server/migrations/*.lua  -- 5 files
modules/oblsk_preferences/server/migrations/*.lua    -- 1 file
modules/oblsk_vehicles/server/migrations/*.lua       -- 6 files
plugins/oblsk_garage/server/migrations/*.lua         -- 2 files
plugins/oblsk_mdt/server/migrations/*.lua            -- 13 files
plugins/oblsk_phone/server/migrations/*.lua          -- 13 files
```

---

## Task 1: `Blueprint:nullable(value)` and the column-builder default flip

**Files:**
- Modify: `core/core/server/ORM/Schema.lua:32-154` (every column-builder method + `nullable()`/`notNullable()`)
- Modify: `core/tests/orm_spec.lua:279` (`t:string('name', 100):notNullable()` → `t:string('name', 100)`)
- Modify: `core/tests/orm_spec.lua:469` (same fix, inside the `postgres: Schema.create produces SERIAL PRIMARY KEY...` test)
- Test: `core/tests/orm_spec.lua` (new tests appended)

**Interfaces:**
- Produces: `Blueprint:nullable(value)` — `value` defaults to `true` when called with no arguments (`t:string('x'):nullable()` still means "this column is optional"); `t:string('x'):nullable(false)` marks it required. Replaces `nullable()` and `notNullable()` entirely — `Blueprint.notNullable` no longer exists as a function.
- Produces: every column builder (`string`, `text`, `json`, `integer`, `bigInteger`, `unsignedInteger`, `float`, `decimal`, `boolean`, `date`, `datetime`, `timestamp`, `enum`, `foreignId`) now inserts `nullable = false` into the column table instead of `nullable = true`. `id()` is unchanged (`nullable = false` already).
- Consumes: nothing new — this task only touches `Blueprint`'s own methods.

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/orm_spec.lua`, in the `-- Schema blueprint -> CREATE TABLE` section (near the existing tests around line 272):

```lua
test('Blueprint: string() defaults to NOT NULL', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:string('name', 50)
    end)

    Database.querySync = original

    truthy(captured:find('`name` VARCHAR(50) NOT NULL', 1, true), 'string() is NOT NULL by default')
end)

test('Blueprint: nullable() with no args makes the last column optional', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:string('nickname', 50):nullable()
    end)

    Database.querySync = original

    truthy(not captured:find('`nickname` VARCHAR(50) NOT NULL', 1, true), 'nullable() removes NOT NULL')
    truthy(captured:find('`nickname` VARCHAR(50)', 1, true), 'column still present')
end)

test('Blueprint: nullable(false) makes the last column required, same as the new default', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:integer('count'):nullable(false)
    end)

    Database.querySync = original

    truthy(captured:find('`count` INT NOT NULL', 1, true), 'nullable(false) is NOT NULL')
end)

test('Blueprint: calling the removed notNullable() raises an error', function()
    throws(function()
        Schema.create('widgets', function(t)
            t:id()
            t:string('name', 50):notNullable()
        end)
    end, 'notNullable() must no longer exist on Blueprint')
end)

test('Blueprint: every column builder except id() defaults to NOT NULL', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('kitchen_sink', function(t)
        t:id()
        t:string('a', 10)
        t:text('b')
        t:json('c')
        t:integer('d')
        t:bigInteger('e')
        t:unsignedInteger('f')
        t:float('g')
        t:decimal('h')
        t:boolean('i')
        t:date('j')
        t:datetime('k')
        t:timestamp('l')
        t:enum('m', {'x', 'y'})
    end)

    Database.querySync = original

    for _, col in ipairs({'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm'}) do
        truthy(captured:find('`' .. col .. '`.-NOT NULL', 1, false) ~= nil or captured:find('`' .. col .. '` .- NOT NULL'),
            col .. ' should be NOT NULL by default')
    end
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: FAIL — `nullable(value)` doesn't exist yet (current `nullable()` takes no value), the default-flip tests fail because columns are still nullable by default, and the `notNullable()`-removed test fails because the method still exists and succeeds instead of throwing.

- [ ] **Step 3: Implement the Blueprint changes**

In `core/core/server/ORM/Schema.lua`, replace lines 140-154 (`nullable()` and `notNullable()`):

```lua
--- Set the nullability of the last column. `value` defaults to `true`, so
--- `:nullable()` reads naturally for "this column is optional". Pass
--- `false` to require it: `:nullable(false)`.
function Blueprint:nullable(value)
    if value == nil then value = true end
    if #self.columns > 0 then
        self.columns[#self.columns].nullable = value
    end
    return self
end
```

Then flip every column builder's default. For each of the following methods, change `nullable = true` to `nullable = false` in the inserted column table:

- `string` (line 32-40)
- `text` (line 43-46)
- `json` (line 49-52)
- `integer` (line 55-58)
- `bigInteger` (line 61-64)
- `unsignedInteger` (line 67-72)
- `float` (line 75-80)
- `decimal` (line 83-91)
- `boolean` (line 94-99) — keep `default = 0` unchanged, only flip `nullable`
- `date` (line 102-105)
- `datetime` (line 108-111)
- `timestamp` (line 114-117)
- `enum` (line 135-138)
- `foreignId` (line 303-309)

`timestamps()` (line 124-132) inserts two `timestamp` columns manually rather than calling `Blueprint:timestamp()` — flip both of its `nullable = true` occurrences to `nullable = false` too, for consistency (both already carry `default = 'CURRENT_TIMESTAMP'`, so this doesn't change real-world behavior since a `DEFAULT` satisfies inserts either way, but it keeps every column in the file consistent with the new rule).

`id()` (line 18-29) is untouched — already `nullable = false`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: all tests pass, including every pre-existing test in the file (the two `:notNullable()` call sites from Step-0 must already be fixed per the Files list above, or this run fails on them).

- [ ] **Step 5: Fix the two pre-existing test call sites**

In `core/tests/orm_spec.lua`:
- Line 279: change `t:string('name', 100):notNullable()` to `t:string('name', 100)`.
- Line 469: change `t:string('name', 100):notNullable()` to `t:string('name', 100)`.

Both tests assert `'...VARCHAR(100) NOT NULL'` is present in the generated SQL — that assertion still passes since NOT NULL is now the default.

- [ ] **Step 6: Run the full suite one more time**

```bash
lua5.4 tests/orm_spec.lua
npm test
```

Expected: PASS (all of `orm_spec.lua`, `obelisk_spec.lua`, `action_service_spec.lua`).

- [ ] **Step 7: Commit**

```bash
git add core/server/ORM/Schema.lua tests/orm_spec.lua
git commit -m "Flip Blueprint column defaults to NOT NULL, replace nullable()/notNullable() with nullable(value)"
```

---

## Task 2: `Blueprint:change()` and `Schema.table()`'s alter-column branch

**Files:**
- Modify: `core/core/server/ORM/Schema.lua:452-494` (`Schema.table`)
- Modify: `core/core/server/ORM/Schema.lua` (add `Blueprint:change()` near `nullable()`)
- Test: `core/tests/orm_spec.lua`

**Interfaces:**
- Consumes: `dialect.introspectColumn(tableName, columnName)` and `dialect.alterModifyColumnStatements(tableName, col, currentInfo, q)` — **not implemented until Tasks 3 (MySQL) and 4 (Postgres)**. This task stubs both as functions that `error('not implemented')` on the currently-registered dialects so `Schema.table()`'s branching logic can be written and tested in isolation first, with a fake dialect substituted in tests (matching how `orm_spec.lua` already swaps `Database.dialect` for tests, e.g. line 88 `Database.dialect = Dialects.resolve('postgres')`).
- Produces: `Blueprint:change()` — marks `self.columns[#self.columns].change = true`. `Schema.table(tableName, callback)`'s statement loop: for each column, if `col.change` is truthy, call the two dialect functions above instead of building an `ADD COLUMN` statement.

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/orm_spec.lua`:

```lua
test('Blueprint: change() marks only the most-recently-defined column', function()
    local blueprint = Blueprint.new('widgets')
    blueprint:string('a', 50)
    blueprint:string('b', 50):nullable(false):change()

    eq(blueprint.columns[1].change, nil, 'first column untouched')
    eq(blueprint.columns[2].change, true, 'second column marked for change')
end)

test('Schema.table: a :change()-marked column calls the dialect introspect+alter path, not ADD COLUMN', function()
    local introspectCalledWith, alterCalledWith
    local fakeDialect = {
        quoteIdentifier = Database.dialect.quoteIdentifier,
        columnType = Database.dialect.columnType,
        formatDefault = Database.dialect.formatDefault,
        alterAddIndexStatements = Database.dialect.alterAddIndexStatements,
        introspectColumn = function(tableName, columnName)
            introspectCalledWith = {tableName, columnName}
            return {type = 'varchar', length = 50, nullable = true, default = nil}
        end,
        alterModifyColumnStatements = function(tableName, col, currentInfo, q)
            alterCalledWith = {tableName, col, currentInfo}
            return {'-- fake alter statement --'}
        end,
    }

    local original = Database.dialect
    Database.dialect = fakeDialect

    local executed = {}
    local originalQuery = Database.querySync
    Database.querySync = function(query) table.insert(executed, query) return {} end

    Schema.table('widgets', function(t)
        t:string('name', 50):nullable(false):change()
    end)

    Database.querySync = originalQuery
    Database.dialect = original

    truthy(introspectCalledWith ~= nil, 'introspectColumn was called')
    eq(introspectCalledWith[1], 'widgets')
    eq(introspectCalledWith[2], 'name')
    truthy(alterCalledWith ~= nil, 'alterModifyColumnStatements was called')
    eq(#executed, 1, 'exactly one statement executed')
    eq(executed[1], '-- fake alter statement --')
end)

test('Schema.table: an unmarked column still uses ADD COLUMN (existing behavior)', function()
    local captured = {}
    local original = Database.querySync
    Database.querySync = function(query) table.insert(captured, query) return {} end

    Schema.table('widgets', function(t)
        t:string('bio', 255)
    end)

    Database.querySync = original

    truthy(captured[1]:find('ADD COLUMN', 1, true), 'unmarked column still adds')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: FAIL — `Blueprint:change()` doesn't exist, and `Schema.table()` has no branch for it.

- [ ] **Step 3: Implement `Blueprint:change()`**

In `core/core/server/ORM/Schema.lua`, add right after the new `nullable()` method from Task 1:

```lua
--- Mark the last-defined column as an alteration of an existing column
--- rather than a new one, for use inside Schema.table(...). Only meaningful
--- there — Schema.create() ignores the flag since every column is new.
function Blueprint:change()
    if #self.columns > 0 then
        self.columns[#self.columns].change = true
    end
    return self
end
```

- [ ] **Step 4: Implement `Schema.table()`'s branch**

Replace the column loop in `Schema.table` (currently lines 462-475):

```lua
    for _, col in ipairs(blueprint.columns) do
        if col.change then
            local currentInfo = dialect.introspectColumn(tableName, col.name)
            if not currentInfo then
                error('Schema.table: cannot :change() column "' .. col.name ..
                      '" on table "' .. tableName .. '" — it does not exist', 2)
            end
            for _, stmt in ipairs(dialect.alterModifyColumnStatements(tableName, col, currentInfo, q)) do
                table.insert(statements, stmt)
            end
        else
            local typeStr = dialect.columnType(col.kind, col.opts, col.autoIncrement)
            local def = q(col.name) .. ' ' .. typeStr

            if not col.nullable then
                def = def .. ' NOT NULL'
            end

            if col.default ~= nil then
                def = def .. ' DEFAULT ' .. dialect.formatDefault(col.kind, col.default)
            end

            table.insert(statements, 'ALTER TABLE ' .. q(tableName) .. ' ADD COLUMN ' .. def .. ';')
        end
    end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/server/ORM/Schema.lua tests/orm_spec.lua
git commit -m "Add Blueprint:change() and Schema.table()'s alter-column branch"
```

---

## Task 3: MySQL dialect — `introspectColumn` and `alterModifyColumnStatements`

**Files:**
- Modify: `core/core/server/ORM/Dialects/MySQL.lua`
- Test: `core/tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Database.querySync(sql, params) -> rows[]` (stubbed in tests, matching every other test in `orm_spec.lua`).
- Produces: `MySQLDialect.introspectColumn(tableName, columnName) -> { type, length, nullable, default } | nil` and `MySQLDialect.alterModifyColumnStatements(tableName, col, currentInfo, q) -> string[]` — the exact interface `Schema.table()` (Task 2) already calls.

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/orm_spec.lua`:

```lua
test('MySQLDialect.introspectColumn: queries information_schema and parses the row', function()
    local capturedSql, capturedParams
    local original = Database.querySync
    Database.querySync = function(sql, params)
        capturedSql, capturedParams = sql, params
        return {{DATA_TYPE = 'varchar', CHARACTER_MAXIMUM_LENGTH = 100, IS_NULLABLE = 'YES', COLUMN_DEFAULT = nil}}
    end

    local info = MySQLDialect.introspectColumn('widgets', 'name')

    Database.querySync = original

    truthy(capturedSql:find('information_schema.COLUMNS', 1, true), 'queries information_schema.COLUMNS')
    eqList(capturedParams, {'widgets', 'name'})
    eq(info.type, 'varchar')
    eq(info.length, 100)
    eq(info.nullable, true)
    eq(info.default, nil)
end)

test('MySQLDialect.introspectColumn: returns nil when the column does not exist', function()
    local original = Database.querySync
    Database.querySync = function() return {} end

    local info = MySQLDialect.introspectColumn('widgets', 'ghost')

    Database.querySync = original

    eq(info, nil)
end)

test('MySQLDialect.alterModifyColumnStatements: restates the full column, merging unstated attributes from introspection', function()
    local q = MySQLDialect.quoteIdentifier
    -- The migration only changes nullability; type/length/default are NOT
    -- restated by the caller, and must come from currentInfo instead.
    local col = {name = 'name', kind = 'string', opts = {}, nullable = false}
    local currentInfo = {type = 'varchar', length = 100, nullable = true, default = 'unknown'}

    local statements = MySQLDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

    eq(#statements, 1)
    truthy(statements[1]:find('MODIFY COLUMN', 1, true), 'uses MODIFY COLUMN')
    truthy(statements[1]:find('VARCHAR(100)', 1, true), 'restates the original length even though the migration did not specify it')
    truthy(statements[1]:find('NOT NULL', 1, true), 'applies the new nullability')
    truthy(statements[1]:find("DEFAULT 'unknown'", 1, true), 'restates the original default so it is not silently dropped')
end)

test('MySQLDialect.alterModifyColumnStatements: an explicit new type/default on the migration overrides introspection', function()
    local q = MySQLDialect.quoteIdentifier
    local col = {name = 'name', kind = 'string', opts = {length = 150}, nullable = true, default = 'fallback', _explicitType = true, _explicitDefault = true}
    local currentInfo = {type = 'varchar', length = 100, nullable = false, default = nil}

    local statements = MySQLDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

    truthy(statements[1]:find('VARCHAR(150)', 1, true), 'uses the migration''s new length, not the introspected one')
    truthy(statements[1]:find("DEFAULT 'fallback'", 1, true), 'uses the migration''s new default')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: FAIL — `MySQLDialect.introspectColumn`/`alterModifyColumnStatements` don't exist.

- [ ] **Step 3: Implement `MySQLDialect.introspectColumn`**

Add to `core/core/server/ORM/Dialects/MySQL.lua`, after `tableExistsPredicate` (after line 71):

```lua
--- Read the live definition of one column from information_schema. Returns
--- nil if the column doesn't exist (caller decides how to handle that).
--- @param tableName string
--- @param columnName string
--- @return table|nil { type, length, nullable, default }
function MySQLDialect.introspectColumn(tableName, columnName)
    local sql = 'SELECT DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE, COLUMN_DEFAULT ' ..
                'FROM information_schema.COLUMNS WHERE ' ..
                MySQLDialect.tableExistsPredicate() ..
                ' AND TABLE_NAME = ? AND COLUMN_NAME = ?'
    local rows = Database.querySync(sql, {tableName, columnName})
    if not rows or not rows[1] then return nil end

    local row = rows[1]
    return {
        type = row.DATA_TYPE,
        length = row.CHARACTER_MAXIMUM_LENGTH and tonumber(row.CHARACTER_MAXIMUM_LENGTH) or nil,
        nullable = row.IS_NULLABLE == 'YES',
        default = row.COLUMN_DEFAULT,
    }
end
```

- [ ] **Step 4: Implement `MySQLDialect.alterModifyColumnStatements`**

Add right after `introspectColumn`:

```lua
--- Build a single MODIFY COLUMN statement that restates the column's FULL
--- definition — MySQL redefines the entire column in one MODIFY COLUMN, so
--- any attribute not restated here would silently revert to no default /
--- the new type's implicit default. Anything the migration's own column
--- builder explicitly set (kind/opts/default) wins; anything it left at the
--- builder's bare default is filled in from currentInfo (the live column),
--- so a migration that only calls :nullable(false):change() doesn't
--- accidentally drop the column's existing type/default.
--- @param tableName string
--- @param col table the Blueprint column entry, with .change == true
--- @param currentInfo table introspectColumn()'s return for this column
--- @param q function quoteIdentifier
--- @return string[]
function MySQLDialect.alterModifyColumnStatements(tableName, col, currentInfo, q)
    local typeStr
    if col._explicitType then
        typeStr = MySQLDialect.columnType(col.kind, col.opts, col.autoIncrement)
    else
        typeStr = currentInfo.length and (currentInfo.type:upper() .. '(' .. currentInfo.length .. ')')
                  or currentInfo.type:upper()
    end

    local nullable = col.nullable
    if nullable == nil then nullable = currentInfo.nullable end

    local default = col.default
    if not col._explicitDefault then default = currentInfo.default end

    local def = q(col.name) .. ' ' .. typeStr
    if not nullable then
        def = def .. ' NOT NULL'
    end
    if default ~= nil then
        def = def .. ' DEFAULT ' .. MySQLDialect.formatDefault(col.kind, default)
    end

    return { 'ALTER TABLE ' .. q(tableName) .. ' MODIFY COLUMN ' .. def .. ';' }
end
```

Note: `col._explicitType`/`col._explicitDefault` are flags a future task could set from `Blueprint` when a migration author explicitly calls a type-changing method or `:default(...)` alongside `:change()` (per the design spec's "full column-alter API" scope) — for THIS plan, no `Blueprint` method sets them yet (Task 2's `:change()` only concerns nullability changes end-to-end), so `alterModifyColumnStatements` always falls back to `currentInfo` for type/default today. The two flags and the branches that read them are still implemented now (not stubbed) because the unit tests in Step 1 exercise both paths directly against the dialect function — wiring `Blueprint` methods to set them is explicitly out of scope for this plan (see Out of Scope in the spec) and can reuse this exact function unchanged when it lands.

- [ ] **Step 5: Run tests to verify they pass**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/server/ORM/Dialects/MySQL.lua tests/orm_spec.lua
git commit -m "Add MySQL dialect column introspection and MODIFY COLUMN generation"
```

---

## Task 4: Postgres dialect — `introspectColumn` and `alterModifyColumnStatements`

**Files:**
- Modify: `core/core/server/ORM/Dialects/Postgres.lua`
- Test: `core/tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Database.querySync(sql, params) -> rows[]` (stubbed in tests).
- Produces: `PostgresDialect.introspectColumn(tableName, columnName) -> {...} | nil` and `PostgresDialect.alterModifyColumnStatements(tableName, col, currentInfo, q) -> string[]`, same interface shape as Task 3's MySQL versions, but Postgres emits one independent clause per changed attribute rather than a full restatement.

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/orm_spec.lua`:

```lua
test('PostgresDialect.introspectColumn: queries information_schema.columns and parses the row', function()
    withDialect('postgres', function()
        local capturedSql, capturedParams
        local original = Database.querySync
        Database.querySync = function(sql, params)
            capturedSql, capturedParams = sql, params
            return {{data_type = 'character varying', character_maximum_length = 100, is_nullable = 'YES', column_default = nil}}
        end

        local info = PostgresDialect.introspectColumn('widgets', 'name')

        Database.querySync = original

        truthy(capturedSql:find('information_schema.columns', 1, true), 'queries information_schema.columns')
        eqList(capturedParams, {'widgets', 'name'})
        eq(info.type, 'character varying')
        eq(info.length, 100)
        eq(info.nullable, true)
    end)
end)

test('PostgresDialect.introspectColumn: returns nil when the column does not exist', function()
    withDialect('postgres', function()
        local original = Database.querySync
        Database.querySync = function() return {} end

        local info = PostgresDialect.introspectColumn('widgets', 'ghost')

        Database.querySync = original

        eq(info, nil)
    end)
end)

test('PostgresDialect.alterModifyColumnStatements: emits one independent clause per changed attribute', function()
    withDialect('postgres', function()
        local q = PostgresDialect.quoteIdentifier
        local col = {name = 'name', kind = 'string', opts = {}, nullable = false}
        local currentInfo = {type = 'character varying', length = 100, nullable = true, default = nil}

        local statements = PostgresDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

        eq(#statements, 1, 'only nullability changed, so only one clause')
        truthy(statements[1]:find('ALTER COLUMN "name" SET NOT NULL', 1, true), 'sets NOT NULL')
        truthy(not statements[1]:find('TYPE', 1, true), 'does not restate the unchanged type')
    end)
end)

test('PostgresDialect.alterModifyColumnStatements: reverting to nullable emits DROP NOT NULL', function()
    withDialect('postgres', function()
        local q = PostgresDialect.quoteIdentifier
        local col = {name = 'name', kind = 'string', opts = {}, nullable = true}
        local currentInfo = {type = 'character varying', length = 100, nullable = false, default = nil}

        local statements = PostgresDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

        truthy(statements[1]:find('DROP NOT NULL', 1, true), 'drops NOT NULL')
    end)
end)
```

`withDialect(name, fn)` already exists in `orm_spec.lua` (used at line 433) — it swaps `Database.dialect` to the named dialect for the duration of `fn` and restores it afterward. Reuse it rather than manually swapping `Database.dialect`, matching every other Postgres-specific test in this file.

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: FAIL — `PostgresDialect.introspectColumn`/`alterModifyColumnStatements` don't exist.

- [ ] **Step 3: Implement `PostgresDialect.introspectColumn`**

Add to `core/core/server/ORM/Dialects/Postgres.lua`, after `tableExistsPredicate` (after line 84):

```lua
--- Read the live definition of one column from information_schema. Returns
--- nil if the column doesn't exist.
--- @param tableName string
--- @param columnName string
--- @return table|nil { type, length, nullable, default }
function PostgresDialect.introspectColumn(tableName, columnName)
    local sql = 'SELECT data_type, character_maximum_length, is_nullable, column_default ' ..
                'FROM information_schema.columns WHERE ' ..
                PostgresDialect.tableExistsPredicate() ..
                ' AND table_name = $1 AND column_name = $2'
    local rows = Database.querySync(sql, {tableName, columnName})
    if not rows or not rows[1] then return nil end

    local row = rows[1]
    return {
        type = row.data_type,
        length = row.character_maximum_length and tonumber(row.character_maximum_length) or nil,
        nullable = row.is_nullable == 'YES',
        default = row.column_default,
    }
end
```

- [ ] **Step 4: Implement `PostgresDialect.alterModifyColumnStatements`**

Add right after `introspectColumn`:

```lua
--- Build one ALTER TABLE statement containing one ALTER COLUMN clause per
--- attribute that actually changed. Unlike MySQL, Postgres's ALTER COLUMN
--- clauses are independent — nothing needs to be restated, so this only
--- touches what the migration actually changed.
--- @param tableName string
--- @param col table the Blueprint column entry, with .change == true
--- @param currentInfo table introspectColumn()'s return for this column
--- @param q function quoteIdentifier
--- @return string[]
function PostgresDialect.alterModifyColumnStatements(tableName, col, currentInfo, q)
    local clauses = {}
    local prefix = 'ALTER TABLE ' .. q(tableName) .. ' ALTER COLUMN ' .. q(col.name) .. ' '

    if col._explicitType then
        local typeStr = PostgresDialect.columnType(col.kind, col.opts, col.autoIncrement)
        table.insert(clauses, prefix .. 'TYPE ' .. typeStr .. ';')
    end

    local nullable = col.nullable
    if nullable == nil then nullable = currentInfo.nullable end
    if nullable ~= currentInfo.nullable then
        table.insert(clauses, prefix .. (nullable and 'DROP NOT NULL' or 'SET NOT NULL') .. ';')
    end

    if col._explicitDefault then
        if col.default == nil then
            table.insert(clauses, prefix .. 'DROP DEFAULT;')
        else
            table.insert(clauses, prefix .. 'SET DEFAULT ' .. PostgresDialect.formatDefault(col.kind, col.default) .. ';')
        end
    end

    return clauses
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
lua5.4 tests/orm_spec.lua
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/server/ORM/Dialects/Postgres.lua tests/orm_spec.lua
git commit -m "Add Postgres dialect column introspection and per-attribute ALTER COLUMN generation"
```

---

## Task 5: Audit-verification script + CI wiring

**Files:**
- Create: `core/tests/support/audit_migrations.lua`
- Create: `core/tests/migration_audit_spec.lua`
- Modify: `core/package.json:9` (`"test"` script)

**Interfaces:**
- Produces: `AuditMigrations.run(directoryPath) -> { passed: string[], failed: { file: string, error: string }[] }` — given a directory, finds every `*.lua` file directly inside it (non-recursive is fine, every migrations directory in this repo is flat), `dofile`s each one to get its `{up, down}` table, then calls `up()` wrapped in `pcall` with `Schema`/`Database` already loaded and `Database.querySync` stubbed to a no-op. This is reusable by Tasks 6-9 to verify each repo's rewritten migrations, not just by this task's own spec.
- Consumes: nothing new — loads the same `core/server/ORM/*` files `orm_spec.lua` already does.

- [ ] **Step 1: Write the failing test**

`core/tests/migration_audit_spec.lua`:

```lua
--- Runs every migration file's up() against a stubbed Schema/Database and
--- asserts none of them error. This is what actually catches a stray call
--- to the removed Blueprint:notNullable() — a plain dofile() would not,
--- since dofile only defines the up()/down() closures, it doesn't call them.
---
--- Run from the repository root:  lua5.4 tests/migration_audit_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')

local AuditMigrations = dofile(scriptDir .. 'support/audit_migrations.lua')

local result = AuditMigrations.run(ROOT .. '/core/server/database/migrations')

if #result.failed > 0 then
    print('FAILED migrations:')
    for _, f in ipairs(result.failed) do
        print('  ' .. f.file .. ': ' .. f.error)
    end
    os.exit(1)
end

print(#result.passed .. ' migration files passed audit, 0 failed')
os.exit(0)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
lua5.4 tests/migration_audit_spec.lua
```

Expected: FAIL — `tests/support/audit_migrations.lua` doesn't exist yet.

- [ ] **Step 3: Implement `AuditMigrations.run`**

`core/tests/support/audit_migrations.lua`:

```lua
--- Given a directory of migration files, loads and runs each one's up()
--- against the already-loaded Schema/Database globals (Database.querySync
--- stubbed to a no-op per file), returning which passed/failed. Reused by
--- both migration_audit_spec.lua (core's own migrations) and the per-repo
--- audit tasks that verify modules'/plugins' migrations after rewriting
--- them (invoked the same way, pointed at a different directory).
local AuditMigrations = {}

--- @param directoryPath string absolute or relative path to a flat directory of *.lua migration files
--- @return table { passed: string[], failed: {file: string, error: string}[] }
function AuditMigrations.run(directoryPath)
    local passed, failed = {}, {}

    local pfile = io.popen('ls "' .. directoryPath .. '"/*.lua 2>/dev/null')
    local files = {}
    for line in pfile:lines() do
        table.insert(files, line)
    end
    pfile:close()

    for _, path in ipairs(files) do
        local originalQuery = Database.querySync
        Database.querySync = function() return {} end

        local ok, err = pcall(function()
            local migration = dofile(path)
            if type(migration) ~= 'table' or type(migration.up) ~= 'function' then
                error('migration file does not return { up = function() ... end }')
            end
            migration.up()
        end)

        Database.querySync = originalQuery

        if ok then
            table.insert(passed, path)
        else
            table.insert(failed, { file = path, error = tostring(err) })
        end
    end

    return { passed = passed, failed = failed }
end

return AuditMigrations
```

- [ ] **Step 4: Run test to verify it passes**

```bash
lua5.4 tests/migration_audit_spec.lua
```

Expected at this point in the plan: still FAIL — core's own 9 migration files (Task 6, not done yet) still call the now-removed `:notNullable()`, so this correctly reports 9 failures right now. That's expected; Task 6 makes this pass.

- [ ] **Step 5: Wire into `package.json`**

Modify `core/package.json`'s `"test"` script (currently `"lua5.4 tests/orm_spec.lua && lua5.4 tests/obelisk_spec.lua && lua5.4 tests/action_service_spec.lua"`) to also run the audit:

```json
"test": "lua5.4 tests/orm_spec.lua && lua5.4 tests/obelisk_spec.lua && lua5.4 tests/action_service_spec.lua && lua5.4 tests/migration_audit_spec.lua"
```

This runs on every push/PR via the existing `ci.yml` (`npm test`), and will keep failing until Task 6 rewrites core's own migrations. Later tasks in this same plan (6-9) fix each repo's migrations, but only core's are checked by core's own CI — `modules/*` and `plugins/*` are separate git repos not present in a CI checkout of `core` alone (confirmed: gitignored from `core`'s own `.gitignore`). Tasks 6-9 each run `AuditMigrations.run(...)` manually (via a one-off `lua5.4 -e` invocation or a scratch spec file, not committed) pointed at their own repo's migrations directory to self-verify before committing, since there's no shared CI to catch it for them.

- [ ] **Step 6: Commit**

```bash
git add tests/support/audit_migrations.lua tests/migration_audit_spec.lua package.json
git commit -m "Add migration audit script, wire into npm test"
```

Note: this commit lands with `npm test` currently RED (core's own migrations aren't fixed until Task 6). That's expected and intentional for this plan's task ordering — the audit script needs to exist and be provably correct (it's failing for the right reason: 9 real `:notNullable()` call sites) before Task 6 fixes what it's flagging. If your CI gate blocks merging red commits, Tasks 5 and 6 should be treated as one continuous unit of work by whoever executes this plan (finish Task 6 in the same sitting before considering either "done"), even though they're written as separate tasks here for review granularity.

---

## Task 6: Migration audit — `core`

**Files:**
- Modify: all 9 files under `core/server/database/migrations/`:
  - `2024_10_04_000001_create_actions_table.lua` (1 `notNullable()` call)
  - `2024_10_04_000002_create_interactions_table.lua` (4 calls)
  - `2024_10_04_000003_create_keybinds_table.lua` (2 calls)
  - `2024_10_04_000004_create_policies_table.lua` (1 call)
  - `2024_10_04_000005_create_policy_attachments_table.lua` (3 calls)
  - `2024_10_04_000006_create_action_policy_table.lua` (2 calls)
  - `2024_10_04_000007_create_interaction_policy_table.lua` (2 calls)
  - `2026_08_10_041318_fix_keybinds_action_id_type.lua` (0 calls — check anyway, see Step 1)
  - `2026_08_11_070000_create_permissions_table.lua` (3 calls)

**Interfaces:**
- Consumes: `AuditMigrations.run` (Task 5) to self-verify.
- Produces: nothing new — this task only rewrites existing migration files' internal column definitions.

- [ ] **Step 1: Read every file and apply the two-rule transformation**

For every column definition in every file listed above, apply exactly these two rules:

1. **If the column chain calls `:notNullable()`**, delete that call. Nothing else on the line changes. (Under the new default this is a no-op removal — the column is already `NOT NULL` without it.)
2. **If the column chain calls neither `:notNullable()` nor `:nullable()`**, add `:nullable()` to the end of the chain. (Under the *old* default this column was optional; without this addition the *new* default would silently make it required.)

Columns that already call `:nullable()` explicitly need no change (already correct under both old and new semantics).

Read each file with the `Read` tool before editing it — do not guess at content from the file list. `2026_08_10_041318_fix_keybinds_action_id_type.lua` is an `ALTER`-style migration (per its name) and may have zero `notNullable()`/`nullable()` calls at all if it only changes a column's type via the pre-`:change()` mechanism this plan doesn't touch — read it to confirm; if it has no nullable-relevant column definitions, it needs no edit but should still be re-verified in Step 2 (harmless if unchanged).

- [ ] **Step 2: Verify with the audit script**

```bash
lua5.4 -e "
dofile('tests/support/fivem_stubs.lua')
dofile('core/server/ORM/Dialects/Init.lua')
dofile('core/server/ORM/Dialects/MySQL.lua')
dofile('core/server/ORM/Dialects/Postgres.lua')
dofile('core/server/ORM/Database.lua')
dofile('core/server/ORM/QueryBuilder.lua')
dofile('core/server/ORM/Schema.lua')
local AuditMigrations = dofile('tests/support/audit_migrations.lua')
local result = AuditMigrations.run('core/server/database/migrations')
print(#result.passed .. ' passed, ' .. #result.failed .. ' failed')
for _, f in ipairs(result.failed) do print('  ' .. f.file .. ': ' .. f.error) end
"
```

Expected: `9 passed, 0 failed`.

- [ ] **Step 3: Run the full suite, confirm `npm test` is green again**

```bash
npm test
```

Expected: PASS (this is what turns Task 5's intentionally-red commit green).

- [ ] **Step 4: Commit**

```bash
git add core/server/database/migrations
git commit -m "Audit core migrations for the ORM nullable-default flip"
```

---

## Task 7: Migration audit — modules (6 repos, 21 files)

**Files:** Same two-rule transformation as Task 6, applied to each of these separate git repos:
- `modules/oblsk_accounts/server/migrations/` — 3 files (`2026_08_10_090621_create_accounts_table.lua`, `2026_08_10_090622_create_account_identifiers_table.lua`, `2026_08_10_090623_create_bans_table.lua`)
- `modules/oblsk_characters/server/migrations/` — 4 files (`2026_08_10_095223_create_characters_table.lua`, `2026_08_10_095224_create_character_appearances_table.lua`, `2026_08_10_220102_add_vitals_to_characters_table.lua`, `2026_08_10_220535_add_max_characters_to_accounts_table.lua`)
- `modules/oblsk_items/server/migrations/` — 2 files (`2026_08_10_041853_create_base_items_table.lua`, `2026_08_10_041855_create_items_table.lua`)
- `modules/oblsk_organizations/server/migrations/` — 5 files (`2026_08_11_080000_create_organizations_table.lua`, `2026_08_11_080001_create_departments_table.lua`, `2026_08_11_080002_create_ranks_table.lua`, `2026_08_11_080003_create_organization_memberships_table.lua`, `2026_08_11_080004_create_organization_department_members_table.lua`)
- `modules/oblsk_preferences/server/migrations/` — 1 file (`2026_08_10_194309_create_preferences_table.lua`)
- `modules/oblsk_vehicles/server/migrations/` — 6 files (`2026_08_10_054223_create_fuel_types_table.lua`, `2026_08_10_054225_create_base_vehicles_table.lua`, `2026_08_10_054227_create_vehicles_table.lua`, `2026_08_10_054229_create_vehicle_tunings_table.lua`, `2026_08_10_054231_create_vehicle_handling_table.lua`, `2026_08_12_060100_add_instance_fields_to_vehicles_table.lua`)

**Interfaces:**
- Consumes: `AuditMigrations.run` (Task 5) — copy `core/tests/support/audit_migrations.lua`'s logic inline into a one-off `lua5.4 -e` command per repo (each module is a separate git repo, doesn't have `core`'s `tests/` directory available at a relative path) rather than depending on a file path across repos.

- [ ] **Step 1: Apply the two-rule transformation (same rules as Task 6, Step 1) to every file in every module listed above**

Read each file before editing. Same two rules: delete every `:notNullable()` call; add `:nullable()` to any column with neither call.

- [ ] **Step 2: Verify each module with the audit script, pointed at that module's own migrations directory**

For each module directory, run (adjust the two paths per module):

```bash
lua5.4 -e "
dofile('/home/andi/Projects/obelisk-framework/core/tests/support/fivem_stubs.lua')
dofile('/home/andi/Projects/obelisk-framework/core/core/server/ORM/Dialects/Init.lua')
dofile('/home/andi/Projects/obelisk-framework/core/core/server/ORM/Dialects/MySQL.lua')
dofile('/home/andi/Projects/obelisk-framework/core/core/server/ORM/Dialects/Postgres.lua')
dofile('/home/andi/Projects/obelisk-framework/core/core/server/ORM/Database.lua')
dofile('/home/andi/Projects/obelisk-framework/core/core/server/ORM/QueryBuilder.lua')
dofile('/home/andi/Projects/obelisk-framework/core/core/server/ORM/Schema.lua')
local AuditMigrations = dofile('/home/andi/Projects/obelisk-framework/core/tests/support/audit_migrations.lua')
local result = AuditMigrations.run('/home/andi/Projects/obelisk-framework/core/modules/oblsk_accounts/server/migrations')
print(#result.passed .. ' passed, ' .. #result.failed .. ' failed')
for _, f in ipairs(result.failed) do print('  ' .. f.file .. ': ' .. f.error) end
"
```

Expected per module: `<file count> passed, 0 failed` (3 for `oblsk_accounts`, 4 for `oblsk_characters`, 2 for `oblsk_items`, 5 for `oblsk_organizations`, 1 for `oblsk_preferences`, 6 for `oblsk_vehicles`).

- [ ] **Step 3: Run each module's own test suite where one exists**

```bash
cd modules/oblsk_accounts && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
cd modules/oblsk_characters && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
cd modules/oblsk_items && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
cd modules/oblsk_organizations && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
cd modules/oblsk_vehicles && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
```

Expected: all pass (this doesn't run migrations, so it should be unaffected by the audit — this step confirms the migration edits didn't accidentally touch anything else in those files).

- [ ] **Step 4: Commit each module separately (each is its own git repo)**

```bash
cd modules/oblsk_accounts && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
cd modules/oblsk_characters && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
cd modules/oblsk_items && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
cd modules/oblsk_organizations && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
cd modules/oblsk_preferences && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
cd modules/oblsk_vehicles && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
```

---

## Task 8: Migration audit — `oblsk_garage` and `oblsk_mdt` (2 repos, 15 files)

**Files:**
- `plugins/oblsk_garage/server/migrations/` — 2 files (`2026_08_12_060000_create_garages_table.lua`, `2026_08_12_060200_add_garage_fk_to_vehicles_table.lua`)
- `plugins/oblsk_mdt/server/migrations/` — 13 files (`2026_08_12_000001_create_mdt_audit_log_table.lua` through `2026_08_12_000013_create_mdt_calendar_tables.lua`, all 13 already listed in the File Structure section above)

**Interfaces:**
- Consumes: `AuditMigrations.run` (Task 5), same one-off `lua5.4 -e` invocation pattern as Task 7.

- [ ] **Step 1: Apply the two-rule transformation to every file in both plugin directories**

Read each file before editing, then apply exactly these two rules to every column definition:

1. **If the column chain calls `:notNullable()`**, delete that call. Nothing else on the line changes.
2. **If the column chain calls neither `:notNullable()` nor `:nullable()`**, add `:nullable()` to the end of the chain.

Columns that already call `:nullable()` explicitly need no change.

- [ ] **Step 2: Verify each plugin with the audit script, pointed at that plugin's own migrations directory**

Same invocation shape as Task 7 Step 2, substituting `plugins/oblsk_garage/server/migrations` and `plugins/oblsk_mdt/server/migrations`.

Expected: `2 passed, 0 failed` for `oblsk_garage`; `13 passed, 0 failed` for `oblsk_mdt`.

- [ ] **Step 3: Run each plugin's own test suite**

```bash
cd plugins/oblsk_garage && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
cd plugins/oblsk_mdt && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
```

Expected: all pass (15 spec files total in `oblsk_mdt` per its own plan's final state).

- [ ] **Step 4: Commit each plugin separately**

```bash
cd plugins/oblsk_garage && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
cd plugins/oblsk_mdt && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
```

---

## Task 9: Migration audit — `oblsk_phone` (1 repo, 13 files)

**Files:**
`plugins/oblsk_phone/server/migrations/` — 13 files: `2026_08_10_222635_add_phone_number_to_characters_table.lua`, `2026_08_10_222636_create_phone_apps_table.lua`, `2026_08_10_222637_create_phone_installed_apps_table.lua`, `2026_08_11_060739_create_phone_recents_table.lua`, `2026_08_11_061456_create_phone_notes_table.lua`, `2026_08_11_062039_create_phone_contacts_table.lua`, `2026_08_11_070512_create_phone_radio_presets_table.lua`, `2026_08_11_090000_create_phone_map_pois_table.lua`, `2026_08_11_090001_create_phone_map_pins_table.lua`, `2026_08_11_094545_create_phone_dispatch_calls_table.lua`, `2026_08_11_163801_create_phone_threads_table.lua`, `2026_08_11_163802_create_phone_thread_members_table.lua`, `2026_08_11_163803_create_phone_messages_table.lua`.

**Interfaces:**
- Consumes: `AuditMigrations.run` (Task 5), same pattern as Tasks 7-8.

- [ ] **Step 1: Apply the two-rule transformation to all 13 files**

Read each file before editing, then apply exactly these two rules to every column definition:

1. **If the column chain calls `:notNullable()`**, delete that call. Nothing else on the line changes.
2. **If the column chain calls neither `:notNullable()` nor `:nullable()`**, add `:nullable()` to the end of the chain.

Columns that already call `:nullable()` explicitly need no change.

- [ ] **Step 2: Verify with the audit script, pointed at `plugins/oblsk_phone/server/migrations`**

Same invocation shape as Task 7 Step 2. Expected: `13 passed, 0 failed`.

- [ ] **Step 3: Run the plugin's own test suite**

```bash
cd plugins/oblsk_phone && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done; cd -
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
cd plugins/oblsk_phone && git add server/migrations && git commit -m "Audit migrations for the ORM nullable-default flip" && cd -
```

---

## Post-Plan Follow-Up (not part of this plan's tasks)

- Wiring `Blueprint` methods (a type-changing method, `:default(...)`) to actually set `col._explicitType`/`col._explicitDefault` for use with `:change()`, completing the "full column-alter API" scope from the spec — Task 3/4's dialect functions already support both flags, only the `Blueprint`-side wiring to set them is deferred.
- The entity streamer feature this ORM work was spun out of — resumes once this plan is merged.
- `MySQLDialect.renameColumnSQL`'s pre-existing "always retypes to VARCHAR(255)" limitation (`core/core/server/ORM/Dialects/MySQL.lua:109-117`) is a related footgun in the same family as the one this plan fixes for `:change()`, but is explicitly out of scope per that function's own comment — worth revisiting with the same introspection technique this plan introduces, as a separate follow-up.
