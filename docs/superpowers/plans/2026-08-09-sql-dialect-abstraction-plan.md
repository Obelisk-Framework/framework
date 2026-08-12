# SQL Dialect Abstraction (MySQL + Postgres) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the ORM (`QueryBuilder`, `Schema`, `BaseModel`) run unmodified against either MySQL/MariaDB or PostgreSQL, selected at runtime via a `db_driver` convar or connection-string scheme.

**Architecture:** A `Dialects` module exposes per-driver tables (`MySQL`, `Postgres`) implementing a small interface — identifier quoting, column-type mapping, default-value formatting, index/constraint SQL, insert `RETURNING` clauses. `QueryBuilder` and `Schema` call through `Database.dialect` instead of hardcoding MySQL syntax. `oblsk_connector` gains a `pg` driver alongside `mysql2`, chosen per-request by a `driver` field, with Postgres queries using real parameter binding (`$1, $2, ...`) instead of the MySQL path's escape-and-interpolate.

**Tech Stack:** Lua 5.4 (FXServer ORM), Node.js (`oblsk_connector` sidecar), `mysql2` (existing), `pg` (new).

## Global Constraints

- MariaDB stays the default driver; nothing about existing MySQL behavior should change unless explicitly noted below (see the two intentional exceptions: `updated_at` no longer emits `ON UPDATE CURRENT_TIMESTAMP` in DDL, and `INSERT` gains a dialect-conditional `RETURNING` clause).
- `db_driver postgres` is only valid when `oblsk_connector` is the active connector — `oxmysql` / `ghmattimysql` / `mysql-async` are MySQL-only by definition. Mismatch is a fatal, fail-fast error at `Database.init()`, never a silent fallback.
- Every existing test in `tests/orm_spec.lua` must keep passing unmodified (run it after every task).
- All new SQL string building goes through `Database.dialect.quoteIdentifier` for identifiers — never a raw backtick/doublequote literal — so the existing identifier-injection defenses apply to both dialects equally.
- Mongo support is explicitly out of scope for this plan (separate spec/plan).

---

### Task 1: Dialect registry + MySQL dialect (behavior-preserving)

**Files:**
- Create: `core/server/ORM/Dialects/Init.lua`
- Create: `core/server/ORM/Dialects/MySQL.lua`
- Modify: `core/fxmanifest.lua:34-36` (server_scripts list — load Dialects before Database)
- Modify: `tests/orm_spec.lua:9-19` (test loader — dofile the new files before Database.lua)
- Test: `tests/orm_spec.lua` (new dialect-specific assertions appended near the top, after the existing `Database.escape` section)

**Interfaces:**
- Produces: global `Dialects` table with `Dialects.register(name, dialect)`, `Dialects.resolve(name) -> dialect table` (errors on unknown name), `Dialects.buildQuoter(quoteChar) -> function(identifier): string`.
- Produces: the MySQL dialect, registered as `Dialects.resolve('mysql')`, implementing: `quoteIdentifier(identifier)`, `columnType(kind, opts, isAutoIncrement)`, `autoIncrementSuffix()`, `formatDefault(kind, value)`, `tableOptions()`, `currentDatabaseExpr()`, `inlineConstraints(indexes, q)`, `standaloneIndexStatements(tableName, indexes, q)`, `alterAddIndexStatements(tableName, idx, q)`, `renameColumnSQL(tableName, from, to)`, `insertReturningClause(primaryKey)`.
- Consumes: nothing from earlier tasks (this is the foundation).

- [ ] **Step 1: Write `core/server/ORM/Dialects/Init.lua`**

```lua
--- Dialect registry. Each dialect (MySQL.lua, Postgres.lua, ...) implements:
---   quoteIdentifier(identifier) -> string
---   columnType(kind, opts, isAutoIncrement) -> string
---   autoIncrementSuffix() -> string
---   formatDefault(kind, value) -> string
---   tableOptions() -> string
---   currentDatabaseExpr() -> string
---   inlineConstraints(indexes, q) -> string[]
---   standaloneIndexStatements(tableName, indexes, q) -> string[]
---   alterAddIndexStatements(tableName, idx, q) -> string[]
---   renameColumnSQL(tableName, from, to) -> string
---   insertReturningClause(primaryKey) -> string
--- `q` passed into the index helpers is always that dialect's own quoteIdentifier.
Dialects = {}

local registry = {}

--- Register a dialect under a driver name (e.g. 'mysql', 'postgres').
function Dialects.register(name, dialect)
    registry[name] = dialect
end

--- Resolve a driver name to its dialect table. Errors on unknown drivers —
--- there is no silent fallback, matching Database.lua's fail-fast philosophy.
--- @param name string
--- @return table dialect
function Dialects.resolve(name)
    local dialect = registry[name]
    if not dialect then
        local known = {}
        for k in pairs(registry) do known[#known + 1] = k end
        error('Dialects: unknown driver "' .. tostring(name) .. '" (known: ' ..
            table.concat(known, ', ') .. ')', 2)
    end
    return dialect
end

--- Shared identifier quoting: splits on '.', validates each segment against
--- [A-Za-z0-9_$]+ (or '*'), wraps each in the given quote character. This is
--- the sole defense against identifier-based SQL injection, so every dialect
--- routes quoteIdentifier through this rather than rolling its own check.
--- @param quoteChar string single character used to wrap each segment
--- @return fun(identifier: string): string
function Dialects.buildQuoter(quoteChar)
    return function(identifier)
        if type(identifier) ~= 'string' or identifier == '' then
            error('Dialect: invalid identifier: ' .. tostring(identifier), 2)
        end

        if identifier == '*' then
            return '*'
        end

        local parts = {}
        for part in (identifier .. '.'):gmatch('([^%.]*)%.') do
            if part == '*' then
                table.insert(parts, '*')
            elseif part:match('^[%w_$]+$') then
                table.insert(parts, quoteChar .. part .. quoteChar)
            else
                error('Dialect: illegal identifier "' .. identifier .. '"', 2)
            end
        end

        return table.concat(parts, '.')
    end
end

return Dialects
```

- [ ] **Step 2: Write `core/server/ORM/Dialects/MySQL.lua`**

This must reproduce the exact SQL the current (pre-refactor) `QueryBuilder.lua`/`Schema.lua` produce — Task 2/3 will delegate to it, and the existing test suite is the proof.

```lua
--- MySQL/MariaDB dialect. See core/server/ORM/Dialects/Init.lua for the
--- interface every dialect implements.
local MySQLDialect = {}

MySQLDialect.quoteIdentifier = Dialects.buildQuoter('`')

function MySQLDialect.columnType(kind, opts, isAutoIncrement)
    opts = opts or {}

    if kind == 'integer' then
        if isAutoIncrement then return 'INT' end
        return opts.unsigned and 'INT UNSIGNED' or 'INT'
    elseif kind == 'bigInteger' then
        return opts.unsigned and 'BIGINT UNSIGNED' or 'BIGINT'
    elseif kind == 'string' then
        return 'VARCHAR(' .. (opts.length or 255) .. ')'
    elseif kind == 'text' then
        return 'TEXT'
    elseif kind == 'json' then
        return 'JSON'
    elseif kind == 'float' then
        if opts.precision then
            return 'FLOAT(' .. opts.precision .. (opts.scale and ',' .. opts.scale or '') .. ')'
        end
        return 'FLOAT'
    elseif kind == 'decimal' then
        return 'DECIMAL(' .. (opts.precision or 8) .. ',' .. (opts.scale or 2) .. ')'
    elseif kind == 'boolean' then
        return 'TINYINT(1)'
    elseif kind == 'date' then
        return 'DATE'
    elseif kind == 'datetime' then
        return 'DATETIME'
    elseif kind == 'timestamp' then
        return 'TIMESTAMP'
    elseif kind == 'enum' then
        return "ENUM('" .. table.concat(opts.values, "','") .. "')"
    end

    error('MySQLDialect: unknown column kind "' .. tostring(kind) .. '"', 2)
end

function MySQLDialect.autoIncrementSuffix()
    return ' AUTO_INCREMENT'
end

function MySQLDialect.formatDefault(kind, value)
    if type(value) == 'string' and value:match('CURRENT_TIMESTAMP') then
        return value
    elseif type(value) == 'number' then
        return tostring(value)
    elseif type(value) == 'boolean' then
        return value and '1' or '0'
    end
    return "'" .. tostring(value) .. "'"
end

function MySQLDialect.tableOptions()
    return ' ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'
end

function MySQLDialect.currentDatabaseExpr()
    return 'DATABASE()'
end

local function quotedColumnList(columns, q)
    local quoted = {}
    for _, col in ipairs(columns) do
        quoted[#quoted + 1] = q(col)
    end
    return table.concat(quoted, ', ')
end

--- MySQL supports non-unique KEY clauses inline, so every index (unique or
--- not) is emitted inside CREATE TABLE; standaloneIndexStatements is always
--- empty.
function MySQLDialect.inlineConstraints(indexes, q)
    local clauses = {}
    for _, idx in ipairs(indexes) do
        local list = quotedColumnList(idx.columns, q)
        if idx.unique then
            clauses[#clauses + 1] = 'UNIQUE KEY ' .. q(idx.name) .. ' (' .. list .. ')'
        else
            clauses[#clauses + 1] = 'KEY ' .. q(idx.name) .. ' (' .. list .. ')'
        end
    end
    return clauses
end

function MySQLDialect.standaloneIndexStatements(_tableName, _indexes, _q)
    return {}
end

function MySQLDialect.alterAddIndexStatements(tableName, idx, q)
    local list = quotedColumnList(idx.columns, q)
    if idx.unique then
        return { 'ALTER TABLE ' .. q(tableName) .. ' ADD UNIQUE INDEX ' .. q(idx.name) .. ' (' .. list .. ');' }
    end
    return { 'ALTER TABLE ' .. q(tableName) .. ' ADD INDEX ' .. q(idx.name) .. ' (' .. list .. ');' }
end

--- Preserves the pre-existing behavior byte-for-byte: CHANGE always retypes
--- to VARCHAR(255) regardless of the column's real type. That's a known
--- limitation of the original implementation (see the comment that used to
--- live on Schema.renameColumn) — not introduced here, and out of scope to
--- fix as part of dialect abstraction.
function MySQLDialect.renameColumnSQL(tableName, from, to)
    local q = MySQLDialect.quoteIdentifier
    return 'ALTER TABLE ' .. q(tableName) .. ' CHANGE ' .. q(from) .. ' ' .. q(to) .. ' VARCHAR(255)'
end

--- MySQL connectors return connector-native insertId; no RETURNING needed.
function MySQLDialect.insertReturningClause(_primaryKey)
    return ''
end

Dialects.register('mysql', MySQLDialect)

return MySQLDialect
```

- [ ] **Step 3: Update `core/fxmanifest.lua` server_scripts to load the dialect files first**

Find (around line 34):
```lua
    -- ORM Layer
    'core/server/ORM/Database.lua',
    'core/server/ORM/QueryBuilder.lua',
    'core/server/ORM/Schema.lua',
    'core/server/ORM/BaseModel.lua',
```

Replace with:
```lua
    -- ORM Layer
    'core/server/ORM/Dialects/Init.lua',
    'core/server/ORM/Dialects/MySQL.lua',
    'core/server/ORM/Dialects/Postgres.lua',
    'core/server/ORM/Database.lua',
    'core/server/ORM/QueryBuilder.lua',
    'core/server/ORM/Schema.lua',
    'core/server/ORM/BaseModel.lua',
```

(`Postgres.lua` doesn't exist yet — it's created in Task 4. Referencing it now is fine; FXServer resolves `server_scripts` at resource start, not at this edit.)

- [ ] **Step 4: Update the test loader in `tests/orm_spec.lua`**

Find (lines 9-19):
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

-- Load stubs first so the ORM files can reference FiveM globals safely.
dofile(scriptDir .. 'support/fivem_stubs.lua')

-- Load the ORM source (each file assigns a global and/or returns the module).
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
```

Replace with:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

-- Load stubs first so the ORM files can reference FiveM globals safely.
dofile(scriptDir .. 'support/fivem_stubs.lua')

-- Load the ORM source (each file assigns a global and/or returns the module).
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
```

`Dialects/Postgres.lua` doesn't exist until Task 4 — **Task 1 stops here without running the suite.** Continue directly to Task 2 (which needs `Database.dialect` wired) before the first test run; there's no independently-testable state between Steps 4 and Task 2's Step 3. (This is the one task in this plan where the "run tests" step is deferred — noted so it isn't mistaken for a skipped step.)

- [ ] **Step 5: Commit**

```bash
cd core
git add core/server/ORM/Dialects/Init.lua core/server/ORM/Dialects/MySQL.lua fxmanifest.lua tests/orm_spec.lua
git commit -m "feat(orm): add dialect registry and MySQL dialect"
```

---

### Task 2: QueryBuilder delegates identifier quoting + gains primaryKey/RETURNING support

**Files:**
- Modify: `core/server/ORM/Database.lua:1-16` (set default dialect at load time)
- Modify: `core/server/ORM/QueryBuilder.lua:1-73` (quoteIdentifier delegation)
- Modify: `core/server/ORM/QueryBuilder.lua:66-79` (`QueryBuilder.new` gains `primaryKey` param)
- Modify: `core/server/ORM/QueryBuilder.lua:474-490` (`:insert` appends `insertReturningClause`)
- Modify: `core/server/ORM/BaseModel.lua:29-31` (`newQuery` passes `self.primaryKey`)
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Dialects.resolve` (Task 1), `MySQLDialect.quoteIdentifier`/`insertReturningClause` (Task 1).
- Produces: `Database.dialect` (a dialect table, defaults to MySQL at file-load time, reassigned by `Database.init()` in Task 5). `QueryBuilder.new(tableName, primaryKey)` — `primaryKey` optional, defaults `'id'`. `QueryBuilder:insert(data, callback)` unchanged signature.

- [ ] **Step 1: Set the default dialect in `Database.lua`**

Find (top of file, after the `Database.config` block, around line 15):
```lua
Database.debug = false
```

Replace with:
```lua
Database.debug = false

-- Default dialect: MySQL, matching Database.config's default host/port. Real
-- driver selection (from db_driver convar or connection-string scheme)
-- happens in Database.init(); this default lets QueryBuilder/Schema build
-- correct SQL even before init() runs (e.g. in unit tests).
Database.dialect = Dialects.resolve('mysql')
```

- [ ] **Step 2: Delegate `QueryBuilder.quoteIdentifier`**

Find (the whole function body, lines ~29-47 of `QueryBuilder.lua`):
```lua
function QueryBuilder.quoteIdentifier(identifier)
    if type(identifier) ~= 'string' or identifier == '' then
        error('QueryBuilder: invalid identifier: ' .. tostring(identifier), 2)
    end

    if identifier == '*' then
        return '*'
    end

    local parts = {}
    for part in (identifier .. '.'):gmatch('([^%.]*)%.') do
        if part == '*' then
            table.insert(parts, '*')
        elseif part:match('^[%w_$]+$') then
            table.insert(parts, '`' .. part .. '`')
        else
            error('QueryBuilder: illegal identifier "' .. identifier .. '"', 2)
        end
    end

    return table.concat(parts, '.')
end
```

Replace with:
```lua
function QueryBuilder.quoteIdentifier(identifier)
    return Database.dialect.quoteIdentifier(identifier)
end
```

(The doc comment above this function, describing why identifier quoting is the injection boundary, stays — only the body changes. The validation logic itself now lives in `Dialects.buildQuoter`, exercised identically through `Database.dialect.quoteIdentifier`.)

- [ ] **Step 3: Add `primaryKey` to `QueryBuilder.new`**

Find:
```lua
function QueryBuilder.new(tableName)
    local self = setmetatable({}, QueryBuilder)
    self.tableName = tableName
```

Replace with:
```lua
function QueryBuilder.new(tableName, primaryKey)
    local self = setmetatable({}, QueryBuilder)
    self.tableName = tableName
    self.primaryKey = primaryKey or 'id'
```

- [ ] **Step 4: Append the dialect's `RETURNING` clause to `INSERT`**

Find (in `QueryBuilder:insert`):
```lua
    local sql = 'INSERT INTO ' .. QueryBuilder.quoteIdentifier(self.tableName) ..
                ' (' .. table.concat(columns, ', ') .. ') VALUES (' ..
                table.concat(placeholders, ', ') .. ')'
```

Replace with:
```lua
    local sql = 'INSERT INTO ' .. QueryBuilder.quoteIdentifier(self.tableName) ..
                ' (' .. table.concat(columns, ', ') .. ') VALUES (' ..
                table.concat(placeholders, ', ') .. ')' ..
                Database.dialect.insertReturningClause(self.primaryKey)
```

- [ ] **Step 5: Pass `primaryKey` through from `BaseModel`**

Find (`BaseModel.lua`):
```lua
function BaseModel:newQuery()
    return QueryBuilder.new(self.table)
end
```

Replace with:
```lua
function BaseModel:newQuery()
    return QueryBuilder.new(self.table, self.primaryKey)
end
```

- [ ] **Step 6: Write the failing/new tests**

Add near the top of `tests/orm_spec.lua`, after the existing `Database.escape` section:

```lua
--------------------------------------------------------------------------------
-- Dialect wiring
--------------------------------------------------------------------------------
test('Database.dialect defaults to mysql before init() runs', function()
    eq(Database.dialect.quoteIdentifier('users'), '`users`')
end)

test('QueryBuilder.quoteIdentifier delegates to Database.dialect', function()
    local original = Database.dialect
    Database.dialect = Dialects.resolve('postgres')
    local ok, result = pcall(QueryBuilder.quoteIdentifier, 'users')
    Database.dialect = original
    truthy(ok, 'quoteIdentifier should not error')
    eq(result, '"users"')
end)

test('insert: mysql adds no RETURNING clause', function()
    withCapture(function(get)
        QueryBuilder.new('users'):insert({name = 'bob'})
        truthy(not get().query:find('RETURNING', 1, true), 'mysql insert has no RETURNING')
    end)
end)
```

- [ ] **Step 7: Run the tests to verify they fail correctly, then implement, then re-run**

Run: `lua5.4 tests/orm_spec.lua`
Expected before Steps 1-5: FAIL (`Database.dialect` / `Dialects` undefined, since Task 1 only created the files but they're not yet consumed).
After Steps 1-5: run again, Expected: PASS — all existing tests plus the three new ones.

- [ ] **Step 8: Commit**

```bash
cd core
git add core/server/ORM/Database.lua core/server/ORM/QueryBuilder.lua core/server/ORM/BaseModel.lua tests/orm_spec.lua
git commit -m "feat(orm): wire QueryBuilder through Database.dialect, add primaryKey/RETURNING support"
```

---

### Task 3: Refactor Schema.lua to route through the dialect

**Files:**
- Modify: `core/server/ORM/Schema.lua` (near-total rewrite of `Blueprint` column builders and all SQL-building functions)
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Database.dialect` (Task 2), all `MySQLDialect` methods (Task 1).
- Produces: `Blueprint:toSql()` now returns `string[]` (a list of statements) instead of a single `string` — `Schema.create` is updated in this task to match. No other function's public signature changes.

- [ ] **Step 1: Replace every `Blueprint` column-builder method**

Find the entire block from `function Blueprint:id(name)` through `function Blueprint:unsigned()` (lines 17-219 of the original file) and replace with:

```lua
--- Add an auto-incrementing integer primary key
function Blueprint:id(name)
    name = name or 'id'
    table.insert(self.columns, {
        name = name,
        kind = 'integer',
        opts = {},
        autoIncrement = true,
        primary = true,
        nullable = false
    })
    return self
end

--- Add a string column
function Blueprint:string(name, length)
    table.insert(self.columns, {
        name = name,
        kind = 'string',
        opts = { length = length or 255 },
        nullable = true
    })
    return self
end

--- Add a text column
function Blueprint:text(name)
    table.insert(self.columns, { name = name, kind = 'text', opts = {}, nullable = true })
    return self
end

--- Add a JSON column
function Blueprint:json(name)
    table.insert(self.columns, { name = name, kind = 'json', opts = {}, nullable = true })
    return self
end

--- Add an integer column
function Blueprint:integer(name)
    table.insert(self.columns, { name = name, kind = 'integer', opts = {}, nullable = true })
    return self
end

--- Add a big integer column
function Blueprint:bigInteger(name)
    table.insert(self.columns, { name = name, kind = 'bigInteger', opts = {}, nullable = true })
    return self
end

--- Add an unsigned integer column
function Blueprint:unsignedInteger(name)
    table.insert(self.columns, {
        name = name, kind = 'integer', opts = { unsigned = true }, nullable = true
    })
    return self
end

--- Add a float column
function Blueprint:float(name, precision, scale)
    table.insert(self.columns, {
        name = name, kind = 'float', opts = { precision = precision, scale = scale }, nullable = true
    })
    return self
end

--- Add a decimal column
function Blueprint:decimal(name, precision, scale)
    table.insert(self.columns, {
        name = name,
        kind = 'decimal',
        opts = { precision = precision or 8, scale = scale or 2 },
        nullable = true
    })
    return self
end

--- Add a boolean column
function Blueprint:boolean(name)
    table.insert(self.columns, {
        name = name, kind = 'boolean', opts = {}, nullable = true, default = 0
    })
    return self
end

--- Add a date column
function Blueprint:date(name)
    table.insert(self.columns, { name = name, kind = 'date', opts = {}, nullable = true })
    return self
end

--- Add a datetime column
function Blueprint:datetime(name)
    table.insert(self.columns, { name = name, kind = 'datetime', opts = {}, nullable = true })
    return self
end

--- Add a timestamp column
function Blueprint:timestamp(name)
    table.insert(self.columns, { name = name, kind = 'timestamp', opts = {}, nullable = true })
    return self
end

--- Add timestamps (created_at, updated_at). Both default to CURRENT_TIMESTAMP
--- at the DB level; updated_at is NOT auto-refreshed by the database (no
--- portable equivalent of MySQL's ON UPDATE CURRENT_TIMESTAMP in Postgres) —
--- BaseModel already sets it on every save via Database.now(), so no DB-level
--- trigger is needed.
function Blueprint:timestamps()
    table.insert(self.columns, {
        name = 'created_at', kind = 'timestamp', opts = {}, nullable = true, default = 'CURRENT_TIMESTAMP'
    })
    table.insert(self.columns, {
        name = 'updated_at', kind = 'timestamp', opts = {}, nullable = true, default = 'CURRENT_TIMESTAMP'
    })
    return self
end

--- Add an enum column
function Blueprint:enum(name, values)
    table.insert(self.columns, { name = name, kind = 'enum', opts = { values = values }, nullable = true })
    return self
end

--- Make the last column nullable
function Blueprint:nullable()
    if #self.columns > 0 then
        self.columns[#self.columns].nullable = true
    end
    return self
end

--- Make the last column not nullable
function Blueprint:notNullable()
    if #self.columns > 0 then
        self.columns[#self.columns].nullable = false
    end
    return self
end

--- Set default value for last column
function Blueprint:default(value)
    if #self.columns > 0 then
        self.columns[#self.columns].default = value
    end
    return self
end

--- Make the last column unsigned (integer/bigInteger only; Postgres has no
--- unsigned integer types, so this is a no-op under that dialect).
function Blueprint:unsigned()
    if #self.columns > 0 then
        local col = self.columns[#self.columns]
        if col.kind == 'integer' or col.kind == 'bigInteger' then
            col.opts.unsigned = true
        end
    end
    return self
end
```

- [ ] **Step 2: Replace `Blueprint:toSql` and `Blueprint:buildColumnList`**

Find (from `function Blueprint:toSql()` through the end of `function Blueprint:buildColumnList`, lines 297-367 of the original file) and replace with:

```lua
--- Build the CREATE TABLE statement(s). Returns a list because Postgres
--- can't express non-unique indexes inline (see Dialects/Postgres.lua) — the
--- first element is always the CREATE TABLE itself; any further elements are
--- standalone CREATE INDEX statements that must run after it.
--- @return string[] statements
function Blueprint:toSql()
    local dialect = Database.dialect
    local q = dialect.quoteIdentifier

    local sql = 'CREATE TABLE IF NOT EXISTS ' .. q(self.tableName) .. ' (\n'

    local columnDefs = {}
    for _, col in ipairs(self.columns) do
        local typeStr = dialect.columnType(col.kind, col.opts, col.autoIncrement)
        local def = '  ' .. q(col.name) .. ' ' .. typeStr

        if not col.nullable then
            def = def .. ' NOT NULL'
        end

        if col.autoIncrement then
            def = def .. dialect.autoIncrementSuffix()
        end

        if col.default ~= nil then
            def = def .. ' DEFAULT ' .. dialect.formatDefault(col.kind, col.default)
        end

        table.insert(columnDefs, def)
    end

    sql = sql .. table.concat(columnDefs, ',\n')

    for _, col in ipairs(self.columns) do
        if col.primary then
            sql = sql .. ',\n  PRIMARY KEY (' .. q(col.name) .. ')'
            break
        end
    end

    for _, clause in ipairs(dialect.inlineConstraints(self.indexes, q)) do
        sql = sql .. ',\n  ' .. clause
    end

    for _, fk in ipairs(self.foreignKeys) do
        sql = sql .. ',\n  FOREIGN KEY (' .. q(fk.column) .. ') REFERENCES ' ..
              q(fk.on) .. '(' .. q(fk.references) .. ') ON DELETE ' .. fk.onDelete ..
              ' ON UPDATE ' .. fk.onUpdate
    end

    sql = sql .. '\n)' .. dialect.tableOptions() .. ';'

    local statements = { sql }
    for _, stmt in ipairs(dialect.standaloneIndexStatements(self.tableName, self.indexes, q)) do
        table.insert(statements, stmt)
    end

    return statements
end

--- Helper to build a quoted column list for indexes
function Blueprint:buildColumnList(columns)
    local dialect = Database.dialect
    local quoted = {}
    for _, col in ipairs(columns) do
        table.insert(quoted, dialect.quoteIdentifier(col))
    end
    return table.concat(quoted, ', ')
end
```

- [ ] **Step 3: Update `Schema.create` to run the statement list**

Find:
```lua
function Schema.create(tableName, callback)
    local blueprint = Blueprint.new(tableName)
    callback(blueprint)
    local sql = blueprint:toSql()
    
    print('[Schema] Creating table: ' .. tableName)
    print('[Schema] SQL: ' .. sql)
    local result = Database.querySync(sql, {})
    print('[Schema] Result: ' .. json.encode(result))
    return result
end
```

Replace with:
```lua
function Schema.create(tableName, callback)
    local blueprint = Blueprint.new(tableName)
    callback(blueprint)
    local statements = blueprint:toSql()

    print('[Schema] Creating table: ' .. tableName)
    local result
    for _, sql in ipairs(statements) do
        print('[Schema] SQL: ' .. sql)
        result = Database.querySync(sql, {})
    end
    print('[Schema] Result: ' .. json.encode(result))
    return result
end
```

- [ ] **Step 4: Update `Schema.drop`, `Schema.hasTable`, `Schema.hasColumn`, `Schema.dropColumn`, `Schema.renameColumn`, `Schema.table`**

Find (everything from `function Schema.drop` through the end of the file, lines 385-460 of the original):
```lua
--- Drop a table
function Schema.drop(tableName)
    local sql = 'DROP TABLE IF EXISTS `' .. tableName .. '`'
    print('[Schema] Dropping table: ' .. tableName)
    return Database.querySync(sql, {})
end

--- Check if a table exists
function Schema.hasTable(tableName)
    local sql = [[SELECT COUNT(*) as count FROM information_schema.TABLES 
                  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?]]
    local result = Database.querySync(sql, {tableName})
    return result and result[1] and result[1].count > 0
end

--- Modify an existing table
function Schema.table(tableName, callback)
    local blueprint = Blueprint.new(tableName)
    blueprint.isAltering = true
    callback(blueprint)
    
    -- Build ALTER TABLE statements
    local statements = {}
    
    for _, col in ipairs(blueprint.columns) do
        local def = '`' .. col.name .. '` ' .. col.type
        
        if not col.nullable then
            def = def .. ' NOT NULL'
        end
        
        if col.default ~= nil then
            if type(col.default) == 'string' and col.default:match('CURRENT_TIMESTAMP') then
                def = def .. ' DEFAULT ' .. col.default
            else
                def = def .. ' DEFAULT \'' .. tostring(col.default) .. '\''
            end
        end
        
        table.insert(statements, 'ALTER TABLE `' .. tableName .. '` ADD COLUMN ' .. def .. ';')
    end
    
    for _, idx in ipairs(blueprint.indexes) do
        if idx.unique then
            table.insert(statements, 'ALTER TABLE `' .. tableName .. '` ADD UNIQUE INDEX `' .. 
                        idx.name .. '` (' .. blueprint:buildColumnList(idx.columns) .. ');')
        else
            table.insert(statements, 'ALTER TABLE `' .. tableName .. '` ADD INDEX `' .. 
                        idx.name .. '` (' .. blueprint:buildColumnList(idx.columns) .. ');')
        end
    end
    
    for _, sql in ipairs(statements) do
        Database.querySync(sql, {})
    end
end

--- Check if a column exists
function Schema.hasColumn(tableName, columnName)
    local sql = [[SELECT COUNT(*) as count FROM information_schema.COLUMNS 
                  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?]]
    local result = Database.querySync(sql, {tableName, columnName})
    return result and result[1] and result[1].count > 0
end

--- Drop a column
function Schema.dropColumn(tableName, columnName)
    local sql = 'ALTER TABLE `' .. tableName .. '` DROP COLUMN `' .. columnName .. '`'
    return Database.querySync(sql, {})
end

--- Rename a column
function Schema.renameColumn(tableName, from, to)
    -- Note: This is simplified, in production you'd need to get the column type first
    local sql = 'ALTER TABLE `' .. tableName .. '` CHANGE `' .. from .. '` `' .. to .. '` VARCHAR(255)'
    return Database.querySync(sql, {})
end

return Schema
```

Replace with:
```lua
--- Drop a table
function Schema.drop(tableName)
    local sql = 'DROP TABLE IF EXISTS ' .. Database.dialect.quoteIdentifier(tableName)
    print('[Schema] Dropping table: ' .. tableName)
    return Database.querySync(sql, {})
end

--- Check if a table exists
function Schema.hasTable(tableName)
    local sql = 'SELECT COUNT(*) as count FROM information_schema.TABLES WHERE TABLE_SCHEMA = ' ..
                Database.dialect.currentDatabaseExpr() .. ' AND TABLE_NAME = ?'
    local result = Database.querySync(sql, {tableName})
    return result and result[1] and result[1].count > 0
end

--- Modify an existing table
function Schema.table(tableName, callback)
    local dialect = Database.dialect
    local q = dialect.quoteIdentifier
    local blueprint = Blueprint.new(tableName)
    blueprint.isAltering = true
    callback(blueprint)

    local statements = {}

    for _, col in ipairs(blueprint.columns) do
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

    for _, idx in ipairs(blueprint.indexes) do
        for _, stmt in ipairs(dialect.alterAddIndexStatements(tableName, idx, q)) do
            table.insert(statements, stmt)
        end
    end

    for _, sql in ipairs(statements) do
        Database.querySync(sql, {})
    end
end

--- Check if a column exists
function Schema.hasColumn(tableName, columnName)
    local sql = 'SELECT COUNT(*) as count FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ' ..
                Database.dialect.currentDatabaseExpr() .. ' AND TABLE_NAME = ? AND COLUMN_NAME = ?'
    local result = Database.querySync(sql, {tableName, columnName})
    return result and result[1] and result[1].count > 0
end

--- Drop a column
function Schema.dropColumn(tableName, columnName)
    local q = Database.dialect.quoteIdentifier
    local sql = 'ALTER TABLE ' .. q(tableName) .. ' DROP COLUMN ' .. q(columnName)
    return Database.querySync(sql, {})
end

--- Rename a column
function Schema.renameColumn(tableName, from, to)
    local sql = Database.dialect.renameColumnSQL(tableName, from, to)
    return Database.querySync(sql, {})
end

return Schema
```

- [ ] **Step 5: Run the existing suite to confirm no regressions**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS — in particular `'Schema.create: generates a CREATE TABLE statement'` must still see `` `id` INT NOT NULL AUTO_INCREMENT``, `PRIMARY KEY (`id`)`, `` `name` VARCHAR(100) NOT NULL``, and `ENGINE=InnoDB` in the captured SQL (that test only calls `Database.querySync` once because the blueprint in it declares no indexes, so `standaloneIndexStatements` being empty for MySQL doesn't change the call count).

- [ ] **Step 6: Add a regression test locking in the new (intentional) `updated_at` behavior**

Add to `tests/orm_spec.lua`, in the Schema section:
```lua
test('Schema.create: updated_at has no ON UPDATE clause (app layer owns it)', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('players', function(t)
        t:id()
        t:timestamps()
    end)

    Database.querySync = original

    truthy(captured:find('`updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP', 1, true),
        'updated_at defaults to CURRENT_TIMESTAMP')
    truthy(not captured:find('ON UPDATE', 1, true), 'no ON UPDATE clause (BaseModel sets updated_at itself)')
end)
```

Run: `lua5.4 tests/orm_spec.lua` — Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd core
git add core/server/ORM/Schema.lua tests/orm_spec.lua
git commit -m "refactor(orm): route Schema DDL generation through Database.dialect"
```

---

### Task 4: Postgres dialect + parity tests

**Files:**
- Create: `core/server/ORM/Dialects/Postgres.lua`
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Dialects.register`/`Dialects.buildQuoter` (Task 1).
- Produces: `Dialects.resolve('postgres')`, implementing the same interface as `MySQLDialect`.

- [ ] **Step 1: Write `core/server/ORM/Dialects/Postgres.lua`**

```lua
--- PostgreSQL dialect. See core/server/ORM/Dialects/Init.lua for the
--- interface every dialect implements.
local PostgresDialect = {}

PostgresDialect.quoteIdentifier = Dialects.buildQuoter('"')

function PostgresDialect.columnType(kind, opts, isAutoIncrement)
    opts = opts or {}

    if kind == 'integer' then
        if isAutoIncrement then return 'SERIAL' end
        return 'INTEGER'
    elseif kind == 'bigInteger' then
        if isAutoIncrement then return 'BIGSERIAL' end
        return 'BIGINT'
    elseif kind == 'string' then
        return 'VARCHAR(' .. (opts.length or 255) .. ')'
    elseif kind == 'text' then
        return 'TEXT'
    elseif kind == 'json' then
        return 'JSONB'
    elseif kind == 'float' then
        if opts.precision then
            if opts.scale then
                -- Postgres FLOAT takes no scale argument; a scale means the
                -- caller wants fixed-point behavior, so map to NUMERIC.
                return 'NUMERIC(' .. opts.precision .. ',' .. opts.scale .. ')'
            end
            return 'FLOAT(' .. opts.precision .. ')'
        end
        return 'DOUBLE PRECISION'
    elseif kind == 'decimal' then
        return 'NUMERIC(' .. (opts.precision or 8) .. ',' .. (opts.scale or 2) .. ')'
    elseif kind == 'boolean' then
        return 'BOOLEAN'
    elseif kind == 'date' then
        return 'DATE'
    elseif kind == 'datetime' then
        return 'TIMESTAMP'
    elseif kind == 'timestamp' then
        return 'TIMESTAMP'
    elseif kind == 'enum' then
        -- No inline enum type in Postgres (would need CREATE TYPE); values
        -- are not DB-enforced under this dialect.
        return 'VARCHAR(255)'
    end

    error('PostgresDialect: unknown column kind "' .. tostring(kind) .. '"', 2)
end

function PostgresDialect.autoIncrementSuffix()
    -- SERIAL/BIGSERIAL already imply auto-increment; no separate keyword.
    return ''
end

function PostgresDialect.formatDefault(kind, value)
    if type(value) == 'string' and value:match('CURRENT_TIMESTAMP') then
        return value
    elseif kind == 'boolean' then
        return (value == 1 or value == true) and 'TRUE' or 'FALSE'
    elseif type(value) == 'number' then
        return tostring(value)
    elseif type(value) == 'boolean' then
        return value and 'TRUE' or 'FALSE'
    end
    return "'" .. tostring(value) .. "'"
end

function PostgresDialect.tableOptions()
    return ''
end

function PostgresDialect.currentDatabaseExpr()
    return 'current_database()'
end

local function quotedColumnList(columns, q)
    local quoted = {}
    for _, col in ipairs(columns) do
        quoted[#quoted + 1] = q(col)
    end
    return table.concat(quoted, ', ')
end

--- Only UNIQUE constraints can be inline in Postgres' CREATE TABLE; plain
--- indexes must be separate CREATE INDEX statements (see
--- standaloneIndexStatements).
function PostgresDialect.inlineConstraints(indexes, q)
    local clauses = {}
    for _, idx in ipairs(indexes) do
        if idx.unique then
            clauses[#clauses + 1] = 'CONSTRAINT ' .. q(idx.name) .. ' UNIQUE (' ..
                quotedColumnList(idx.columns, q) .. ')'
        end
    end
    return clauses
end

function PostgresDialect.standaloneIndexStatements(tableName, indexes, q)
    local statements = {}
    for _, idx in ipairs(indexes) do
        if not idx.unique then
            statements[#statements + 1] = 'CREATE INDEX ' .. q(idx.name) .. ' ON ' .. q(tableName) ..
                ' (' .. quotedColumnList(idx.columns, q) .. ');'
        end
    end
    return statements
end

function PostgresDialect.alterAddIndexStatements(tableName, idx, q)
    local list = quotedColumnList(idx.columns, q)
    if idx.unique then
        return { 'ALTER TABLE ' .. q(tableName) .. ' ADD CONSTRAINT ' .. q(idx.name) .. ' UNIQUE (' .. list .. ');' }
    end
    return { 'CREATE INDEX ' .. q(idx.name) .. ' ON ' .. q(tableName) .. ' (' .. list .. ');' }
end

function PostgresDialect.renameColumnSQL(tableName, from, to)
    local q = PostgresDialect.quoteIdentifier
    return 'ALTER TABLE ' .. q(tableName) .. ' RENAME COLUMN ' .. q(from) .. ' TO ' .. q(to)
end

--- Postgres connectors have no connector-native insertId; RETURNING the
--- primary key is how oblsk_connector's Postgres path recovers it (see
--- oblsk_connector/index.js).
function PostgresDialect.insertReturningClause(primaryKey)
    return ' RETURNING ' .. PostgresDialect.quoteIdentifier(primaryKey)
end

Dialects.register('postgres', PostgresDialect)

return PostgresDialect
```

- [ ] **Step 2: Write dialect-parity tests**

Add to `tests/orm_spec.lua`, in a new section after the Schema tests:

```lua
--------------------------------------------------------------------------------
-- Postgres dialect
--------------------------------------------------------------------------------
local function withDialect(name, fn)
    local original = Database.dialect
    Database.dialect = Dialects.resolve(name)
    local ok, err = pcall(fn)
    Database.dialect = original
    if not ok then error(err, 2) end
end

test('postgres: quoteIdentifier uses double quotes', function()
    withDialect('postgres', function()
        eq(QueryBuilder.quoteIdentifier('users'), '"users"')
        eq(QueryBuilder.quoteIdentifier('items.id'), '"items"."id"')
    end)
end)

test('postgres: quoteIdentifier still rejects illegal identifiers', function()
    withDialect('postgres', function()
        throws(function() QueryBuilder.quoteIdentifier('name; DROP TABLE users') end)
    end)
end)

test('postgres: toSql uses double-quoted identifiers', function()
    withDialect('postgres', function()
        local sql, params = QueryBuilder.new('users'):where('age', '>', 18):toSql()
        eq(sql, 'SELECT * FROM "users" WHERE "age" > ?')
        eqList(params, {18})
    end)
end)

test('postgres: Schema.create produces SERIAL PRIMARY KEY, no ENGINE clause', function()
    withDialect('postgres', function()
        local captured
        local original = Database.querySync
        Database.querySync = function(query) captured = query return {} end

        Schema.create('users', function(t)
            t:id()
            t:string('name', 100):notNullable()
            t:boolean('active')
        end)

        Database.querySync = original

        truthy(captured:find('CREATE TABLE IF NOT EXISTS "users"', 1, true), 'has CREATE TABLE header')
        truthy(captured:find('"id" SERIAL NOT NULL', 1, true), 'has SERIAL id')
        truthy(captured:find('PRIMARY KEY ("id")', 1, true), 'has primary key')
        truthy(captured:find('"name" VARCHAR(100) NOT NULL', 1, true), 'has not-null varchar')
        truthy(captured:find('"active" BOOLEAN DEFAULT FALSE', 1, true), 'boolean default renders as FALSE')
        truthy(not captured:find('ENGINE', 1, true), 'no MySQL ENGINE clause')
    end)
end)

test('postgres: plain index becomes a standalone CREATE INDEX, unique stays inline', function()
    withDialect('postgres', function()
        local captured = {}
        local original = Database.querySync
        Database.querySync = function(query) table.insert(captured, query) return {} end

        Schema.create('players', function(t)
            t:id()
            t:string('name', 100)
            t:index('name')
            t:unique('name', 'players_name_unique')
        end)

        Database.querySync = original

        eq(#captured, 2, 'one CREATE TABLE + one standalone CREATE INDEX')
        truthy(captured[1]:find('CONSTRAINT "players_name_unique" UNIQUE ("name")', 1, true),
            'unique constraint is inline')
        truthy(not captured[1]:find('CREATE INDEX', 1, true), 'CREATE TABLE has no inline plain index')
        truthy(captured[2]:find('CREATE INDEX "players_name_index" ON "players" ("name")', 1, true),
            'plain index is a standalone statement')
    end)
end)

test('postgres: renameColumn uses RENAME COLUMN, not CHANGE', function()
    withDialect('postgres', function()
        local captured
        local original = Database.querySync
        Database.querySync = function(query) captured = query return {} end

        Schema.renameColumn('users', 'old_name', 'new_name')

        Database.querySync = original
        eq(captured, 'ALTER TABLE "users" RENAME COLUMN "old_name" TO "new_name"')
    end)
end)

test('postgres: insert appends RETURNING <primaryKey>', function()
    withDialect('postgres', function()
        withCapture(function(get)
            QueryBuilder.new('users', 'id'):insert({name = 'bob'})
            truthy(get().query:find('RETURNING "id"', 1, true), 'insert has RETURNING clause')
        end)
    end)
end)
```

- [ ] **Step 3: Run the tests**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS — full suite including all new MySQL and Postgres tests.

- [ ] **Step 4: Commit**

```bash
cd core
git add core/server/ORM/Dialects/Postgres.lua tests/orm_spec.lua
git commit -m "feat(orm): add Postgres dialect with parity tests"
```

---

### Task 5: Database.lua driver resolution + fail-fast validation

**Files:**
- Modify: `core/server/ORM/Database.lua:22-41` (`Database.parseConnectionString`)
- Modify: `core/server/ORM/Database.lua:57-96` (`Database.init`)
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Dialects.resolve` (Task 1), `Database.dialect` default (Task 2).
- Produces: `Database.config.driver` (`'mysql'` or `'postgres'`), `Database.dialect` reassigned correctly by `Database.init()`.

- [ ] **Step 1: Generalize `Database.parseConnectionString` to accept both schemes**

Find:
```lua
function Database.parseConnectionString(connectionString)
    local config = {}
    
    local userPass, hostPath = connectionString:match('mysql://([^@]+)@(.+)')
    if userPass then
        config.user, config.password = userPass:match('([^:]+):(.+)')
    end
    
    if hostPath then
        local hostPort, database = hostPath:match('([^/]+)/(.+)')
        if hostPort then
            local host, port = hostPort:match('([^:]+):?(%d*)')
            config.host = host
            config.port = tonumber(port) or 3306
            config.database = database
        end
    end
    
    return config
end
```

Replace with:
```lua
function Database.parseConnectionString(connectionString)
    local config = {}

    local scheme, userPass, hostPath = connectionString:match('^(%a+)://([^@]+)@(.+)$')
    if scheme then
        config.driver = (scheme == 'postgres' or scheme == 'postgresql') and 'postgres' or 'mysql'
    end

    if userPass then
        config.user, config.password = userPass:match('([^:]+):(.+)')
    end

    if hostPath then
        local hostPort, database = hostPath:match('([^/]+)/(.+)')
        if hostPort then
            local host, port = hostPort:match('([^:]+):?(%d*)')
            config.host = host
            config.port = tonumber(port) or (config.driver == 'postgres' and 5432 or 3306)
            config.database = database
        end
    end

    return config
end
```

- [ ] **Step 2: Resolve driver + dialect, and fail fast on driver/connector mismatch, in `Database.init`**

Find:
```lua
function Database.init()
    local connectionString = GetConvar('mysql_connection_string', '')
    Database.debug = GetConvarInt('db_debug', 0) == 1

    if connectionString ~= '' then
        local parsed = Database.parseConnectionString(connectionString)
        for k, v in pairs(parsed) do
            if v and v ~= '' then
                Database.config[k] = v
            end
        end
    end

    Database.connector = Database.detectConnector()

    if not Database.connector then
        Database.ready = false
        print('[Database] ============================================================')
        print('[Database] FATAL: No MySQL connector resource found.')
        print('[Database] Obelisk requires a database and has no in-memory fallback.')
        print('[Database] Start one of these BEFORE obelisk in your server.cfg:')
        print('[Database]   ensure oxmysql        (recommended)')
        print('[Database]   ensure ghmattimysql')
        print('[Database]   ensure mysql-async')
        print('[Database]   ensure oblsk_connector')
        print('[Database] ============================================================')
        return false
    end

    Database.ready = true
    print('[Database] Initialized (connector: ' .. Database.connector .. ')')
    print('[Database] Config: ' .. Database.config.user .. '@' .. Database.config.host .. ':' .. Database.config.port .. '/' .. Database.config.database)

    return true
end
```

Replace with:
```lua
function Database.init()
    local connectionString = GetConvar('mysql_connection_string', '')
    Database.debug = GetConvarInt('db_debug', 0) == 1

    if connectionString ~= '' then
        local parsed = Database.parseConnectionString(connectionString)
        for k, v in pairs(parsed) do
            if v and v ~= '' then
                Database.config[k] = v
            end
        end
    end

    -- An explicit db_driver convar wins over whatever the connection string
    -- scheme implied; defaults to mysql when neither is set.
    local driverConvar = GetConvar('db_driver', '')
    if driverConvar ~= '' then
        Database.config.driver = driverConvar
    end
    Database.config.driver = Database.config.driver or 'mysql'
    Database.dialect = Dialects.resolve(Database.config.driver)

    Database.connector = Database.detectConnector()

    if not Database.connector then
        Database.ready = false
        print('[Database] ============================================================')
        print('[Database] FATAL: No MySQL connector resource found.')
        print('[Database] Obelisk requires a database and has no in-memory fallback.')
        print('[Database] Start one of these BEFORE obelisk in your server.cfg:')
        print('[Database]   ensure oxmysql        (recommended)')
        print('[Database]   ensure ghmattimysql')
        print('[Database]   ensure mysql-async')
        print('[Database]   ensure oblsk_connector')
        print('[Database] ============================================================')
        return false
    end

    if Database.config.driver == 'postgres' and Database.connector ~= 'oblsk_connector' then
        Database.ready = false
        print('[Database] ============================================================')
        print('[Database] FATAL: db_driver "postgres" requires oblsk_connector.')
        print('[Database] Connector "' .. Database.connector .. '" only speaks MySQL.')
        print('[Database] Start oblsk_connector instead, or set db_driver back to mysql.')
        print('[Database] ============================================================')
        return false
    end

    Database.ready = true
    print('[Database] Initialized (connector: ' .. Database.connector .. ', driver: ' .. Database.config.driver .. ')')
    print('[Database] Config: ' .. Database.config.user .. '@' .. Database.config.host .. ':' .. Database.config.port .. '/' .. Database.config.database)

    return true
end
```

- [ ] **Step 3: Write the tests**

Add to `tests/orm_spec.lua`, in a new "Database driver resolution" section:

```lua
--------------------------------------------------------------------------------
-- Database driver resolution
--------------------------------------------------------------------------------
test('parseConnectionString: mysql scheme (default port 3306)', function()
    local cfg = Database.parseConnectionString('mysql://obelisk:secret@db:3307/fivem')
    eq(cfg.driver, 'mysql')
    eq(cfg.user, 'obelisk')
    eq(cfg.password, 'secret')
    eq(cfg.host, 'db')
    eq(cfg.port, 3307)
    eq(cfg.database, 'fivem')
end)

test('parseConnectionString: postgres scheme defaults port 5432', function()
    local cfg = Database.parseConnectionString('postgres://obelisk:secret@db/fivem')
    eq(cfg.driver, 'postgres')
    eq(cfg.port, 5432)
end)

test('Database.init: db_driver convar wins over connection-string scheme', function()
    local originalConvar, originalConnStr = _G.GetConvar, nil
    _G.GetConvar = function(name, default)
        if name == 'mysql_connection_string' then return 'postgres://obelisk:secret@db/fivem' end
        if name == 'db_driver' then return 'mysql' end
        return default
    end
    _G.GetResourceState = function(name) return name == 'oxmysql' and 'started' or 'stopped' end

    local ok = Database.init()
    _G.GetConvar = originalConvar
    _G.GetResourceState = function() return 'stopped' end

    truthy(ok, 'init should succeed (mysql driver + mysql-only connector is valid)')
    eq(Database.config.driver, 'mysql')
    eq(Database.dialect.quoteIdentifier('x'), '`x`')
end)

test('Database.init: postgres driver with a mysql-only connector fails fast', function()
    local originalConvar = _G.GetConvar
    _G.GetConvar = function(name, default)
        if name == 'db_driver' then return 'postgres' end
        return default
    end
    _G.GetResourceState = function(name) return name == 'oxmysql' and 'started' or 'stopped' end

    local ok = Database.init()
    _G.GetConvar = originalConvar
    _G.GetResourceState = function() return 'stopped' end

    truthy(not ok, 'init should fail: oxmysql cannot serve postgres')
    truthy(not Database.ready, 'Database.ready must stay false')
end)

test('Database.init: postgres driver with oblsk_connector succeeds', function()
    local originalConvar = _G.GetConvar
    _G.GetConvar = function(name, default)
        if name == 'db_driver' then return 'postgres' end
        return default
    end
    _G.GetResourceState = function(name) return name == 'oblsk_connector' and 'started' or 'stopped' end

    local ok = Database.init()
    _G.GetConvar = originalConvar
    _G.GetResourceState = function() return 'stopped' end

    truthy(ok, 'init should succeed')
    eq(Database.dialect.quoteIdentifier('x'), '"x"')

    -- Reset global state so later tests (which assume the mysql default) aren't affected.
    Database.config.driver = 'mysql'
    Database.dialect = Dialects.resolve('mysql')
end)
```

- [ ] **Step 4: Run the tests**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS — full suite.

- [ ] **Step 5: Commit**

```bash
cd core
git add core/server/ORM/Database.lua tests/orm_spec.lua
git commit -m "feat(orm): resolve db driver/dialect from convar or connection string, fail fast on mismatch"
```

---

### Task 6: oblsk_connector server.lua — driver-aware payloads

**Files:**
- Modify: `oblsk_connector/server.lua` (whole file — `MySQL.config`, `MySQL.executeSync`, `transactionSync`, `init`)

**Interfaces:**
- Consumes: a `db_driver` convar (same name/semantics as `core`'s, read independently — `oblsk_connector` doesn't depend on `core` being loaded).
- Produces: HTTP payloads to `/query` and `/transaction` gain a `driver` field. When `driver == 'postgres'`, `/query`'s `params` field carries the **unescaped** parameter array and `query` is **not** pre-interpolated. When `driver == 'mysql'` (default), behavior is byte-for-byte unchanged from today.

- [ ] **Step 1: Read the driver convar in `init()`**

Find (near the bottom of `server.lua`):
```lua
local function init()
    local connectionString = GetConvar('mysql_connection_string', '')
    
    if connectionString ~= '' then
```

Replace with:
```lua
local function init()
    MySQL.config.driver = GetConvar('db_driver', 'mysql')
    Connector.config.driver = MySQL.config.driver

    local connectionString = GetConvar('mysql_connection_string', '')
    
    if connectionString ~= '' then
```

- [ ] **Step 2: Branch `MySQL.executeSync` on driver**

Find:
```lua
function MySQL.executeSync(query, params)
    if not query or query == '' then
        return {}
    end
    
    local parsedQuery = parseQuery(query, params)
    local result = {}
    local requestDone = false
    
    local payload = json.encode({
        query = parsedQuery,
        host = MySQL.config.host,
        port = MySQL.config.port,
        user = MySQL.config.user,
        password = MySQL.config.password,
        database = MySQL.config.database
    })
    
    print('[oblsk_connector] Executing query: ' .. parsedQuery:sub(1, 100))
```

Replace with:
```lua
function MySQL.executeSync(query, params)
    if not query or query == '' then
        return {}
    end

    local isPostgres = MySQL.config.driver == 'postgres'
    -- MySQL path: escape + interpolate client-side (unchanged behavior).
    -- Postgres path: send the raw '?'-placeholder query + unescaped params;
    -- index.js translates placeholders and lets `pg` bind them for real.
    local outgoingQuery = isPostgres and query or parseQuery(query, params)
    local result = {}
    local requestDone = false

    local payload = json.encode({
        query = outgoingQuery,
        params = isPostgres and (params or {}) or nil,
        driver = MySQL.config.driver,
        host = MySQL.config.host,
        port = MySQL.config.port,
        user = MySQL.config.user,
        password = MySQL.config.password,
        database = MySQL.config.database
    })

    print('[oblsk_connector] Executing query: ' .. outgoingQuery:sub(1, 100))
```

The rest of `MySQL.executeSync` (the `PerformHttpRequest` call and wait loop) is unchanged.

- [ ] **Step 3: Branch `transactionSync` on driver**

Find:
```lua
local function transactionSync(queries)
    if type(queries) ~= 'table' or #queries == 0 then
        return true
    end

    local statements = {}
    for _, item in ipairs(queries) do
        if type(item) == 'table' then
            statements[#statements + 1] = parseQuery(item.query, item.values)
        else
            statements[#statements + 1] = tostring(item)
        end
    end

    local result = {}
    local requestDone = false

    local payload = json.encode({
        queries = statements,
        host = MySQL.config.host,
        port = MySQL.config.port,
        user = MySQL.config.user,
        password = MySQL.config.password,
        database = MySQL.config.database
    })
```

Replace with:
```lua
local function transactionSync(queries)
    if type(queries) ~= 'table' or #queries == 0 then
        return true
    end

    local isPostgres = MySQL.config.driver == 'postgres'
    local statements = {}
    for _, item in ipairs(queries) do
        if isPostgres then
            if type(item) == 'table' then
                statements[#statements + 1] = { query = item.query, values = item.values or {} }
            else
                statements[#statements + 1] = { query = tostring(item), values = {} }
            end
        elseif type(item) == 'table' then
            statements[#statements + 1] = parseQuery(item.query, item.values)
        else
            statements[#statements + 1] = tostring(item)
        end
    end

    local result = {}
    local requestDone = false

    local payload = json.encode({
        queries = statements,
        driver = MySQL.config.driver,
        host = MySQL.config.host,
        port = MySQL.config.port,
        user = MySQL.config.user,
        password = MySQL.config.password,
        database = MySQL.config.database
    })
```

The rest of `transactionSync` is unchanged.

- [ ] **Step 4: Manual verification (no Lua test harness exists for this resource)**

`oblsk_connector` has no unit tests (it's a thin FXServer resource, exercised live). Verify with a syntax check:

Run: `lua5.4 -e "assert(loadfile('oblsk_connector/server.lua'))" ` (run from the repo root)
Expected: no output, exit code 0 (confirms the file parses — it can't fully load standalone since it references FXServer globals, but `loadfile` only compiles, it doesn't execute).

- [ ] **Step 5: Commit**

```bash
cd oblsk_connector
git add server.lua
git commit -m "feat: driver-aware payloads for postgres support"
```

---

### Task 7: oblsk_connector index.js — pg driver + insertId shaping

**Files:**
- Modify: `oblsk_connector/package.json` (add `pg` dependency)
- Modify: `oblsk_connector/index.js` (pool selection, `/query` and `/transaction` handlers)
- Create/Modify: `oblsk_connector/package-lock.json`, `oblsk_connector/node_modules/**` (via `npm install`)

**Interfaces:**
- Consumes: the `driver`/`params` payload fields from Task 6.
- Produces: for `driver: 'postgres'`, `/query` responses use the same two shapes the MySQL path already produces — `{insertId, affectedRows}` for INSERT/UPDATE/DELETE, or a bare row array for SELECT — so `Database.lua` on the Lua side needs no further changes.

- [ ] **Step 1: Add the `pg` dependency**

Find (`package.json`):
```json
  "dependencies": {
    "mysql2": "^3.6.5"
  },
```

Replace with:
```json
  "dependencies": {
    "mysql2": "^3.6.5",
    "pg": "^8.11.5"
  },
```

- [ ] **Step 2: Install it**

Run (from `oblsk_connector/`): `npm install`
Expected: `package-lock.json` updates, `node_modules/pg` and its transitive deps appear. (This repo commits `node_modules` — see Step 5.)

- [ ] **Step 3: Rewrite pool selection**

Find (top of `index.js`):
```javascript
const http = require('http');
const mysql = require('mysql2/promise');

const PORT = process.env.MYSQL_SERVER_PORT || 3000;

let pools = {};

const getPool = async (config) => {
    const key = `${config.host}:${config.port}:${config.user}:${config.database}`;
    
    if (!pools[key]) {
        pools[key] = mysql.createPool({
            host: config.host,
            user: config.user,
            password: config.password,
            database: config.database,
            port: config.port,
            waitForConnections: true,
            connectionLimit: 10,
            queueLimit: 0
        });
    }
    
    return pools[key];
};
```

Replace with:
```javascript
const http = require('http');
const mysql = require('mysql2/promise');
const { Pool: PgPool } = require('pg');

const PORT = process.env.MYSQL_SERVER_PORT || 3000;

let pools = {};

const getPool = async (driver, config) => {
    const key = `${driver}:${config.host}:${config.port}:${config.user}:${config.database}`;

    if (!pools[key]) {
        if (driver === 'postgres') {
            pools[key] = new PgPool({
                host: config.host,
                user: config.user,
                password: config.password,
                database: config.database,
                port: config.port,
                max: 10
            });
        } else {
            pools[key] = mysql.createPool({
                host: config.host,
                user: config.user,
                password: config.password,
                database: config.database,
                port: config.port,
                waitForConnections: true,
                connectionLimit: 10,
                queueLimit: 0
            });
        }
    }

    return pools[key];
};

// Translate '?' positional placeholders (Lua/QueryBuilder's format) into
// Postgres' '$1, $2, ...' — done here rather than in QueryBuilder so the
// ORM stays dialect-agnostic on placeholder syntax.
const toPositionalParams = (query) => {
    let i = 0;
    return query.replace(/\?/g, () => `$${++i}`);
};
```

- [ ] **Step 4: Branch the `/query` handler on `driver`**

Find:
```javascript
                const payload = JSON.parse(body);
                const query = payload.query;
                const host = payload.host || 'localhost';
                const port = payload.port || 3306;
                const user = payload.user || 'root';
                const password = payload.password || '';
                const database = payload.database || 'fivem';

                if (!query) {
                    res.writeHead(400);
                    res.end(JSON.stringify({ error: 'No query provided' }));
                    return;
                }

                console.log('[Query]', query.substring(0, 100) + (query.length > 100 ? '...' : ''));

                const pool = await getPool({ host, port, user, password, database });
                const connection = await pool.getConnection();
                
                try {
                    const [rows] = await connection.query(query);
                    console.log('[Result] Affected rows:', rows.affectedRows || 0, 'Rows returned:', Array.isArray(rows) ? rows.length : 0);
                    
                    // For INSERT/UPDATE/DELETE queries, return metadata
                    if (rows.insertId !== undefined || rows.affectedRows !== undefined) {
                        res.writeHead(200);
                        res.end(JSON.stringify({
                            insertId: rows.insertId || 0,
                            affectedRows: rows.affectedRows || 0
                        }));
                    } else {
                        // For SELECT queries, return rows
                        res.writeHead(200);
                        res.end(JSON.stringify(rows));
                    }
                } finally {
                    connection.release();
                }
```

Replace with:
```javascript
                const payload = JSON.parse(body);
                const query = payload.query;
                const driver = payload.driver || 'mysql';
                const host = payload.host || 'localhost';
                const port = payload.port || (driver === 'postgres' ? 5432 : 3306);
                const user = payload.user || 'root';
                const password = payload.password || '';
                const database = payload.database || 'fivem';

                if (!query) {
                    res.writeHead(400);
                    res.end(JSON.stringify({ error: 'No query provided' }));
                    return;
                }

                console.log('[Query]', query.substring(0, 100) + (query.length > 100 ? '...' : ''));

                const pool = await getPool(driver, { host, port, user, password, database });

                if (driver === 'postgres') {
                    const text = toPositionalParams(query);
                    const result = await pool.query(text, payload.params || []);
                    console.log('[Result] Row count:', result.rowCount, 'Rows returned:', result.rows.length);

                    if (/^\s*(INSERT|UPDATE|DELETE)/i.test(query)) {
                        // With RETURNING <pk> (see QueryBuilder:insert), the first
                        // column of the first returned row is the new row's id.
                        const insertId = result.rows.length > 0 ? Object.values(result.rows[0])[0] : 0;
                        res.writeHead(200);
                        res.end(JSON.stringify({
                            insertId: insertId || 0,
                            affectedRows: result.rowCount || 0
                        }));
                    } else {
                        res.writeHead(200);
                        res.end(JSON.stringify(result.rows));
                    }
                    return;
                }

                const connection = await pool.getConnection();

                try {
                    const [rows] = await connection.query(query);
                    console.log('[Result] Affected rows:', rows.affectedRows || 0, 'Rows returned:', Array.isArray(rows) ? rows.length : 0);
                    
                    // For INSERT/UPDATE/DELETE queries, return metadata
                    if (rows.insertId !== undefined || rows.affectedRows !== undefined) {
                        res.writeHead(200);
                        res.end(JSON.stringify({
                            insertId: rows.insertId || 0,
                            affectedRows: rows.affectedRows || 0
                        }));
                    } else {
                        // For SELECT queries, return rows
                        res.writeHead(200);
                        res.end(JSON.stringify(rows));
                    }
                } finally {
                    connection.release();
                }
```

(The `/query` handler's outer `try { ... } catch (error) { ... }` and the `req.on('data'/'end')` wiring around this block are unchanged — only the inner body shown above changes.)

- [ ] **Step 5: Branch the `/transaction` handler on `driver`**

Find:
```javascript
                const payload = JSON.parse(body);
                const queries = payload.queries;
                const host = payload.host || 'localhost';
                const port = payload.port || 3306;
                const user = payload.user || 'root';
                const password = payload.password || '';
                const database = payload.database || 'fivem';

                if (!Array.isArray(queries) || queries.length === 0) {
                    res.writeHead(400);
                    res.end(JSON.stringify({ success: false, error: 'No queries provided' }));
                    return;
                }

                console.log('[Transaction]', queries.length, 'statement(s)');

                const pool = await getPool({ host, port, user, password, database });
                const connection = await pool.getConnection();

                // All statements run on this single connection inside one
                // transaction, so START TRANSACTION / COMMIT actually apply.
                try {
                    await connection.beginTransaction();
                    for (const item of queries) {
                        const sql = typeof item === 'string' ? item : item.query;
                        await connection.query(sql);
                    }
                    await connection.commit();
                    res.writeHead(200);
                    res.end(JSON.stringify({ success: true }));
                } catch (error) {
                    try {
                        await connection.rollback();
                    } catch (rollbackError) {
                        console.error('Rollback error:', rollbackError.message);
                    }
                    console.error('Transaction error:', error.message);
                    res.writeHead(500);
                    res.end(JSON.stringify({ success: false, error: error.message }));
                } finally {
                    connection.release();
                }
```

Replace with:
```javascript
                const payload = JSON.parse(body);
                const queries = payload.queries;
                const driver = payload.driver || 'mysql';
                const host = payload.host || 'localhost';
                const port = payload.port || (driver === 'postgres' ? 5432 : 3306);
                const user = payload.user || 'root';
                const password = payload.password || '';
                const database = payload.database || 'fivem';

                if (!Array.isArray(queries) || queries.length === 0) {
                    res.writeHead(400);
                    res.end(JSON.stringify({ success: false, error: 'No queries provided' }));
                    return;
                }

                console.log('[Transaction]', queries.length, 'statement(s)');

                const pool = await getPool(driver, { host, port, user, password, database });

                if (driver === 'postgres') {
                    const client = await pool.connect();
                    try {
                        await client.query('BEGIN');
                        for (const item of queries) {
                            const text = toPositionalParams(item.query);
                            await client.query(text, item.values || []);
                        }
                        await client.query('COMMIT');
                        res.writeHead(200);
                        res.end(JSON.stringify({ success: true }));
                    } catch (error) {
                        try {
                            await client.query('ROLLBACK');
                        } catch (rollbackError) {
                            console.error('Rollback error:', rollbackError.message);
                        }
                        console.error('Transaction error:', error.message);
                        res.writeHead(500);
                        res.end(JSON.stringify({ success: false, error: error.message }));
                    } finally {
                        client.release();
                    }
                    return;
                }

                const connection = await pool.getConnection();

                // All statements run on this single connection inside one
                // transaction, so START TRANSACTION / COMMIT actually apply.
                try {
                    await connection.beginTransaction();
                    for (const item of queries) {
                        const sql = typeof item === 'string' ? item : item.query;
                        await connection.query(sql);
                    }
                    await connection.commit();
                    res.writeHead(200);
                    res.end(JSON.stringify({ success: true }));
                } catch (error) {
                    try {
                        await connection.rollback();
                    } catch (rollbackError) {
                        console.error('Rollback error:', rollbackError.message);
                    }
                    console.error('Transaction error:', error.message);
                    res.writeHead(500);
                    res.end(JSON.stringify({ success: false, error: error.message }));
                } finally {
                    connection.release();
                }
```

- [ ] **Step 6: Syntax-check**

Run (from `oblsk_connector/`): `node --check index.js`
Expected: no output, exit code 0.

- [ ] **Step 7: Commit (including the installed dependency, matching this repo's existing convention of committing `node_modules`)**

```bash
cd oblsk_connector
git add package.json package-lock.json index.js node_modules
git commit -m "feat: add pg driver for postgres support"
```

---

### Task 8: Docker — optional Postgres service

**Files:**
- Modify: `docker-compose.yml:1-30` (root compose file)
- Modify: `server-data/server.cfg` (document the `db_driver` convar)

**Interfaces:** none (infra only).

- [ ] **Step 1: Add a profile-gated `postgres` service**

Find (`docker-compose.yml`):
```yaml
services:
  mariadb:
    image: mariadb:latest
    container_name: obelisk-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: changeme
      MYSQL_DATABASE: fivem
      MYSQL_USER: obelisk
      MYSQL_PASSWORD: obelisk_password
    ports:
      - "3306:3306"
    volumes:
      - mariadb_data:/var/lib/mysql
      - ./docker/mariadb/init:/docker-entrypoint-initdb.d
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
```

Replace with:
```yaml
services:
  mariadb:
    image: mariadb:latest
    container_name: obelisk-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: changeme
      MYSQL_DATABASE: fivem
      MYSQL_USER: obelisk
      MYSQL_PASSWORD: obelisk_password
    ports:
      - "3306:3306"
    volumes:
      - mariadb_data:/var/lib/mysql
      - ./docker/mariadb/init:/docker-entrypoint-initdb.d
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci

  # Alternative to mariadb — start this instead (not alongside) when running
  # with `db_driver postgres` in server.cfg. Not started by default: run
  # `docker compose --profile postgres up postgres fxserver` to use it.
  postgres:
    image: postgres:16
    container_name: obelisk-postgres
    restart: unless-stopped
    profiles: ["postgres"]
    environment:
      POSTGRES_DB: fivem
      POSTGRES_USER: obelisk
      POSTGRES_PASSWORD: obelisk_password
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
```

- [ ] **Step 2: Register the new named volume**

Find:
```yaml
volumes:
  mariadb_data:
    driver: local
```

Replace with:
```yaml
volumes:
  mariadb_data:
    driver: local
  postgres_data:
    driver: local
```

- [ ] **Step 3: Document `db_driver` in `server-data/server.cfg`**

Find:
```
# oblsk_connector talks to MariaDB via this convar (see oblsk_connector/server.lua)
set mysql_connection_string "mysql://obelisk:obelisk_password@mariadb:3306/fivem"
```

Replace with:
```
# oblsk_connector talks to the database via this convar (see oblsk_connector/server.lua).
# For MariaDB (default): mysql://obelisk:obelisk_password@mariadb:3306/fivem
# For Postgres: switch db_driver below to "postgres", point this at the
# postgres service instead, and run `docker compose --profile postgres up
# postgres fxserver` (not mariadb) — see docker-compose.yml.
set mysql_connection_string "mysql://obelisk:obelisk_password@mariadb:3306/fivem"

# "mysql" (default) or "postgres". Must match the connection string above.
# postgres requires oblsk_connector — oxmysql/ghmattimysql/mysql-async are
# MySQL-only and Database.init() will fail fast if you mix them with postgres.
set db_driver "mysql"
```

- [ ] **Step 4: Validate the compose file parses**

Run: `docker compose config --quiet`
Expected: no output, exit code 0 (confirms valid YAML + compose schema; doesn't require Docker to actually be running containers).

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml server-data/server.cfg
git commit -m "feat(docker): add optional postgres service, document db_driver"
```

(This repo's root — `/home/andi/Projects/obelisk-framework` — is not itself a git repository; if it still isn't by the time this task runs, skip `git commit` here and just leave the files staged/saved. `core` and `oblsk_connector` are the two nested git repos that matter for this plan's other commits.)

---

### Task 9: Full regression pass + plan self-review

**Files:** none created/modified — verification only.

- [ ] **Step 1: Run the full Lua test suite one more time**

Run: `cd core && lua5.4 tests/orm_spec.lua`
Expected: PASS, 0 failures — every test from the original suite plus every test added in Tasks 2, 3, 4, 5.

- [ ] **Step 2: Syntax-check both connector files again**

Run:
```bash
cd oblsk_connector
lua5.4 -e "assert(loadfile('server.lua'))"
node --check index.js
```
Expected: no output from either, exit code 0.

- [ ] **Step 3: Validate the compose file one more time**

Run: `docker compose config --quiet` (from the repo root)
Expected: no output, exit code 0.

- [ ] **Step 4: Grep for any remaining hardcoded backtick SQL outside the Dialects modules**

Run: `grep -rn '\`' core/server/ORM/*.lua`
Expected: no matches in `Database.lua`, `QueryBuilder.lua`, `Schema.lua`, `BaseModel.lua` (backticks should only remain inside `core/server/ORM/Dialects/MySQL.lua`, which this grep pattern doesn't even reach since it only globs the parent directory — if it prints anything, that's a dialect leak to fix before closing this task).

- [ ] **Step 5: Confirm no other resource references the old single-string `Blueprint:toSql()` contract**

Run: `grep -rn ':toSql()' core/ --include="*.lua"`
Expected: only the call site inside `Schema.create` (updated in Task 3) — if any other file calls `:toSql()` on a Blueprint and treats the result as a string instead of a list, it needs the same list-handling update Task 3 gave `Schema.create`.
