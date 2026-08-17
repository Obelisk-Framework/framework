# ORM API Reference

Exhaustive reference for every public function in the ORM (`core/server/ORM/`). For an architectural overview and everyday usage patterns, read [ORM](/concepts/orm) first; this page is the complete signature list, including the lower-level `Database` layer and internal `QueryBuilder`/`Blueprint` methods that the concepts page only summarizes.

**Sync vs async:** a bare-named function blocks and returns its result directly, no `callback` parameter. The `...Async`-suffixed counterpart runs the query on a separate thread (`Citizen.CreateThread`) and calls a `callback` with the result instead of returning it; it has no meaningful return value. This split is consistent throughout `QueryBuilder`/`BaseModel` — there is no callback-presence branching on a single bare-named method; `attach`/`detach` are the only exception (callback-based only, no sync form).

## Database

The connection and dialect layer. Global table `Database`, with fields `Database.ready`, `Database.connector`, `Database.config`, `Database.debug`, `Database.dialect`.

### Connection and setup

**`Database.init()`**
Sync. Returns `boolean` (the resulting `Database.ready`).
Reads the `mysql_connection_string` and `db_driver` convars (`db_debug` sets `Database.debug`), merges the connection string's fields into `Database.config`, resolves `Database.dialect` via `Dialects.resolve(driver)`, and detects the active connector resource.
Fails fast (prints a fatal banner, returns `false`) if no supported connector is running, or if `db_driver` is `"postgres"` while the detected connector isn't `oblsk_connector` (the only connector here that speaks Postgres).

**`Database.isReady()`**
Sync. Returns `boolean`, `Database.ready`.

**`Database.detectConnector()`**
Sync. Returns `string | nil`. Checks `oblsk_connector`, `oxmysql`, `ghmattimysql`, `mysql-async` in that order via `GetResourceState`, returning the first one that's `started`, or `nil` if none are.

**`Database.parseConnectionString(connectionString)`**
Sync. Returns a `table` with `driver`, `user`, `password`, `host`, `port`, `database`, parsed from a `scheme://user:password@host:port/database` string. Defaults the port to `3306` for `mysql` and `5432` for `postgres` if omitted. Note that `Database.init()` deliberately ignores this table's `driver` field; only the `db_driver` convar ever sets the active dialect, so the connection string's scheme and `db_driver` can never silently disagree.

### Raw queries

**`Database.query(query, params)`**
Sync. Returns `table` (the raw result rows).

**`Database.queryAsync(query, params, callback)`**
Async. Calls `callback(result)`. `params` defaults to `{}`.

**`Database.insert(query, params)`**
Sync. Returns `number` (the inserted row's id, or `0` if the connector didn't report one).

**`Database.insertAsync(query, params, callback)`**
Async. Calls `callback(insertId)`.

**`Database.update(query, params)`**
Sync. Returns `number` (affected row count, or `0`).

**`Database.updateAsync(query, params, callback)`**
Async. Calls `callback(affectedRows)`.

**`Database.delete(query, params)`**
Sync alias for `Database.update`.

**`Database.deleteAsync(query, params, callback)`**
Async alias for `Database.updateAsync`.

**`Database.execute(query, params)`**
Sync alias for `Database.query`.

**`Database.executeAsync(query, params, callback)`**
Async alias for `Database.queryAsync`.

**`Database.prepareQuery(query, params)`**
Sync. Returns `string`, the query with each `?` substituted left to right by `Database.escape(params[i])`. Returns `query` unchanged if `params` is empty or `nil`. Extra `?` placeholders beyond `#params` are left as literal `?`. Prints the prepared query if `Database.debug` is set.

**`Database.executeQuery(query, params)`**
Sync. Returns `table`. The dispatcher every other query method routes through: calls the detected connector's native export (`oblsk_connector:executeSync`, `oxmysql:executeSync`, `ghmattimysql:executeSync`, or, for `mysql-async`, `mysql_fetch_all_sync` against a pre-interpolated query via `prepareQuery`). Throws if `Database.connector` is unset (call `Database.init()` first) or unrecognized.

### Transactions

**`Database.newTransaction()`**
Sync. Returns a `table` with an empty `queries` list and a chainable `tx:add(query, params)` method that appends `{query, params}` and returns `tx`.

**`Database.transaction(callback)`**
Sync. Returns `boolean` (success). Builds a transaction, runs `callback(tx)` inside a `pcall`, and commits `tx.queries` via `Database.commitTransaction` only if the callback didn't error. An empty `tx.queries` (nothing added) returns `true` trivially without touching the database. A callback error aborts without committing, returning `false`.

```lua
local ok = Database.transaction(function(tx)
    tx:add('UPDATE accounts SET balance = balance - ? WHERE id = ?', {100, 1})
    tx:add('UPDATE accounts SET balance = balance + ? WHERE id = ?', {100, 2})
end)
```

**`Database.commitTransaction(queries)`**
Sync. Returns `boolean`. Prefers the connector's native atomic `transactionSync` export (`oxmysql`, `ghmattimysql`, `oblsk_connector`). Falls back to `Database.commitTransactionFallback` if no native API exists, or if the native call itself errors.

**`Database.commitTransactionFallback(queries)`**
Sync. Returns `boolean`. Manually issues `START TRANSACTION`, each statement in order, `ROLLBACK` on the first failure, or `COMMIT` once every statement succeeds. Not guaranteed atomic on a pooling connector; prints a one-time warning per connector the first time this path runs.

### Utilities

**`Database.escape(value)`**
Sync. Returns `string`. `nil` becomes `'NULL'`; numbers use `tostring`; booleans become `'1'`/`'0'`; strings are quoted with `'` and `\` doubled; tables are JSON-encoded then quoted the same way; anything else becomes `'NULL'`.

**`Database.now()`**
Sync. Returns `string`, `os.date('%Y-%m-%d %H:%M:%S')`. Used everywhere a DATETIME/TIMESTAMP column is written, since MySQL's strict mode rejects a raw epoch integer there.

## QueryBuilder

A fluent, parameterized query builder. Every chainable method below returns the builder itself (`self`) unless noted otherwise. Get an instance via `QueryBuilder.new(tableName, primaryKey)`, or implicitly through `BaseModel:newQuery()`.

Identifiers (table and column names, join types, sort directions) are validated against an allowlist at build time and every value is passed as a `?` parameter, never concatenated, which is what keeps `where`/`join`/`orderBy` safe from injection despite building SQL via string concatenation internally.

**`QueryBuilder.new(tableName, primaryKey)`**
Constructor. Returns a new `QueryBuilder`. `primaryKey` defaults to `'id'`.

**`QueryBuilder.quoteIdentifier(identifier)`**
Sync static. Returns `string`. Delegates to the active dialect's identifier quoting; throws on an identifier that fails validation, e.g. anything outside `[A-Za-z0-9_$]+` per segment.

### Selecting

**`:select(columns)`**
Sets the selected columns, accepting either a single column name or a table of names. Clears any prior `selectRaw`.

**`:selectRaw(expression)`**
Sets an unquoted, verbatim SELECT expression, e.g. `'COUNT(*) as count'`. Internal use only; this is the one place caller-supplied input must never be passed unvalidated.

### Filtering

**`:where(column, operator, value)`**
Adds an `AND` condition. The two-argument form `where(column, value)` implies `operator = '='`.

**`:orWhere(column, operator, value)`**
Same as `where`, but joined with `OR`.

**`:whereIn(column, values)`**
Adds an `AND column IN (...)` condition; each entry in `values` becomes its own `?` placeholder.

**`:whereNull(column)`**
Adds an `AND column IS NULL` condition.

**`:whereNotNull(column)`**
Adds an `AND column IS NOT NULL` condition.

### Joins, ordering, grouping

**`:join(tableName, first, operator, second, joinType)`**
Adds a join. `joinType` defaults to `'INNER'`; validated against `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS` at build time.

**`:leftJoin(tableName, first, operator, second)`**
Sugar for `join(tableName, first, operator, second, 'LEFT')`.

**`:orderBy(column, direction)`**
Adds an ORDER BY clause. `direction` defaults to `'ASC'`; anything other than `ASC`/`DESC` throws when the query is built.

**`:groupBy(columns)`**
Sets GROUP BY, accepting a single column or a table of columns.

**`:limit(limit)`** / **`:offset(offset)`**
Set LIMIT/OFFSET. Both are only validated as numeric at build time (`toSql`/execution), not when called.

### Building and executing

**`:toSql()`**
Sync. Returns `string sql, table params`. Assembles the full `SELECT ... FROM ... [JOIN] [WHERE] [GROUP BY] [ORDER BY] [LIMIT/OFFSET]` statement and resets `self.params` before rebuilding them.

**`:buildWhereClause()`**, **`:buildOrderByClause()`**, **`:buildLimitClause()`**, **`:buildJoinClause()`**, **`:buildSelectClause()`**
Sync internals `toSql()` composes from. Each returns the SQL fragment for its clause (empty string if not applicable). `buildOrderByClause`, `buildLimitClause`, and `buildJoinClause` are where the allowlist validation for direction, numeric limit/offset, and join type actually throws.

**`:get()`** / **`:getAsync(callback)`**
Sync / async. Runs the built query. On a bare `QueryBuilder.new(tableName)` (no owning model), returns (or passes to `callback`) the raw result rows. On a query opened off a model (`self.model` set, e.g. via `BaseModel:newQuery()` or a model's query-proxy methods), decodes any JSON casts and wraps each row into a model instance via `newFromQuery`, returning model instances instead.

**`:with(path)`**
Sync. Returns `self`. Appends `path` to `self.withPaths` (chainable, so `:with('a'):with('b')` accumulates two independent paths rather than overwriting). Only meaningful on a query opened off a model (`self.model` set, e.g. via `BaseModel:newQuery()` or a model's `with`/query-proxy methods) — a bare `QueryBuilder.new(tableName)` has nothing to resolve relation names against. Once the query resolves via `get()`/`getAsync()` and returns model instances, every recorded path is eager-loaded via `BaseModel:eagerLoad`, one batched query per path segment across the whole result set, before the result is returned. `path` may be dot-separated (`'a.b.c'`) to eager-load a chain of nested relations.

**`:first()`** / **`:firstAsync(callback)`**
Sync / async. Same as `get`, but with `limit(1)` applied first, returning a single row (or `nil`) instead of a list.

**`:firstOr(callback)`**
Sync only. Runs `:first()`; if it found a row, returns it; if not, calls `callback()` and returns its return value instead. `callback` here is a fallback-value function (Laravel's `firstOr` convention) — not an async completion handler like every other `callback` param in this file. There is no `firstOrAsync`.

**`:count()`** / **`:countAsync(callback)`**
Sync / async. Temporarily swaps in `selectRaw('COUNT(*) as count')`, runs the query, restores the prior select, and returns a `number` (coerced via `tonumber`, defaulting to `0`; this also handles Postgres returning the count as a string).

**`:insert(data)`** / **`:insertAsync(data, callback)`**
Sync / async. `insert` returns `number insertId` directly; `insertAsync` calls `callback(insertId)`. Builds `INSERT INTO ... (...) VALUES (...)`, appending the dialect's `RETURNING` clause where applicable (Postgres).

**`:update(data)`** / **`:updateAsync(data, callback)`**
Sync / async, same pattern as `insert`. Returns/callbacks `number affectedRows`. Builds `UPDATE ... SET ...`, honoring any `where()` conditions already added to the builder.

**`:delete()`** / **`:deleteAsync(callback)`**
Sync / async, same pattern. Returns/callbacks `number affectedRows`. Builds `DELETE FROM ...`, honoring any `where()` conditions already added.

**`:paginateAsync(page, perPage, callback)`**
Async only — bare-named `paginate` doesn't exist; internally it drives `count()`/`get()` via their Async forms and never returns synchronously, so it's named with the `Async` suffix like every other callback-only method. `page` defaults to `1`, `perPage` to `15`. Runs a count, then a `limit`/`offset` query, and calls `callback({ data, total, perPage, currentPage, lastPage })`.

```lua
local recent = QueryBuilder.new('inventories')
    :where('container', 'stash')
    :whereIn('item', {'water', 'bread'})
    :orderBy('created_at', 'DESC')
    :limit(10)
    :get()
```

## Schema

Table creation and migration helpers. All functions below are static, called as `Schema.x(...)`.

**`Schema.create(tableName, callback)`**
Sync. Returns `table` (the result of the last statement run). `callback(blueprint)` populates a `Blueprint`; every statement `blueprint:toSql()` produces (the `CREATE TABLE` plus any standalone `CREATE INDEX` statements a dialect needs) runs in order via `Database.query`.

**`Schema.table(tableName, callback)`**
Sync. No meaningful return. Same `callback(blueprint)` pattern as `create`, but every new column becomes an `ALTER TABLE ... ADD COLUMN ...` statement and every index becomes the dialect's `ALTER`-time index statement, for adding columns/indexes to an existing table. A column marked with `:change()` is altered instead of added — see [Altering an existing column](#altering-an-existing-column).

**`Schema.drop(tableName)`**
Sync. Returns `table`. Runs `DROP TABLE IF EXISTS <table>`.

**`Schema.hasTable(tableName)`**
Sync. Returns `boolean`. Queries `information_schema.TABLES` scoped by the dialect's `tableExistsPredicate()`.

**`Schema.hasColumn(tableName, columnName)`**
Sync. Returns `boolean`. Queries `information_schema.COLUMNS` the same way, additionally filtered by column name.

**`Schema.dropColumn(tableName, columnName)`**
Sync. Returns `table`. Runs `ALTER TABLE ... DROP COLUMN ...`.

**`Schema.renameColumn(tableName, from, to)`**
Sync. Returns `table`. Delegates the actual SQL to the dialect (`CHANGE` on MySQL, `RENAME COLUMN ... TO ...` on Postgres).

## Blueprint (the table builder)

The object passed into `Schema.create`/`Schema.table`'s callback as `table` (or whatever name you give the callback parameter). Every column-defining and column-modifying method returns `self` for chaining, unless noted.

### Columns

**`:id(name)`**
Auto-incrementing integer primary key. `name` defaults to `'id'`. Always `NOT NULL`.

Every column below is `NOT NULL` unless you chain `:nullable()` onto it.

**`:string(name, length)`**
VARCHAR-like column. `length` defaults to `255`.

**`:text(name)`** / **`:json(name)`**
TEXT / JSON column.

**`:integer(name)`** / **`:bigInteger(name)`** / **`:unsignedInteger(name)`**
INT / BIGINT / unsigned INT column.

**`:float(name, precision, scale)`** / **`:decimal(name, precision, scale)`**
FLOAT / DECIMAL column. `decimal`'s `precision` defaults to `8`, `scale` to `2`.

**`:boolean(name)`**
BOOLEAN column. Defaults to `0`.

**`:date(name)`** / **`:datetime(name)`** / **`:timestamp(name)`**
DATE / DATETIME / TIMESTAMP column.

**`:timestamps()`**
Adds both `created_at` and `updated_at` as TIMESTAMP columns defaulting to `CURRENT_TIMESTAMP` at the database level. Note that `updated_at` isn't auto-refreshed by the database (there's no portable Postgres equivalent of MySQL's `ON UPDATE CURRENT_TIMESTAMP`); `BaseModel:save` and `saveAsync` set it explicitly via `Database.now()` on every save instead.

**`:enum(name, values)`**
ENUM column restricted to `values` (a list of strings).

### Modifiers

These mutate the most recently added column, so call them immediately after the column method they apply to.

**`:nullable(value)`**
Sets the last column's nullability. `value` defaults to `true`, so `:nullable()` reads as "this column is optional". `:nullable(false)` marks it required — the same as the default, just stated explicitly. Since every column is `NOT NULL` unless made nullable, you only need this for optional columns.

**`:change()`**
Marks the last-defined column as an alteration of an existing column rather than a new one. Only meaningful inside `Schema.table(...)`; `Schema.create()` ignores it. See [Altering an existing column](#altering-an-existing-column).

**`:default(value)`**
Sets the last column's default value.

**`:unsigned()`**
Marks the last column unsigned. Only applies when its kind is `integer` or `bigInteger`; a no-op otherwise, and always a no-op under the Postgres dialect (no unsigned integer types there).

### Indexes and foreign keys

**`:index(columns, name)`**
Adds a plain, non-unique index. `columns` accepts a string or a list. `name` defaults to `<table>_<columns>_index`.

**`:unique(columns, name)`**
Adds a unique index. If `columns` is omitted, uses the most recently added column. `name` defaults to `<table>_<columns>_unique`. Silently does nothing if `columns` can't be resolved (no argument and no columns defined yet).

**`:foreign(column)`**
Returns a separate chainable builder, not the `Blueprint` itself: `:references(refColumn):on(refTable)`, then one of `:onDelete(action)`, `:onUpdate(action)`, or `.getBlueprint()` to finish. The foreign key is only actually registered once one of those three terminal calls happens. If neither `onDelete` nor `onUpdate` is called but `.getBlueprint()` is, both actions default to `RESTRICT`.

```lua
table:foreign('owner_id'):references('id'):on('users'):onDelete('CASCADE')
```

### Building

**`:toSql()`**
Sync. Returns a `string[]` of statements. The first is always the `CREATE TABLE IF NOT EXISTS` statement itself; any further entries are standalone `CREATE INDEX` statements for indexes a dialect can't express inline (Postgres, for plain indexes).

### Altering an existing column

Inside a `Schema.table(...)` block, chaining `:change()` onto a column marks it as an alteration of the column that already exists, instead of a new `ADD COLUMN`. The dialect introspects the live column (`information_schema`) and emits the alter statement it needs — `MODIFY COLUMN` on MySQL/MariaDB (which restates the whole definition, so the existing type and default are carried over verbatim), one independent `ALTER COLUMN ... SET/DROP NOT NULL` clause on Postgres.

```lua
--- Migration: make nickname optional
return {
    up = function()
        Schema.table('users', function(table)
            table:string('nickname', 255):nullable():change()
        end)
    end,

    down = function()
        Schema.table('users', function(table)
            table:string('nickname', 255):nullable(false):change()
        end)
    end
}
```

If the named column doesn't exist on the table, `Schema.table` raises an error rather than silently adding it.

::: warning Nullability changes only, today
`:change()` is wired end-to-end for **nullability** changes only. The dialect layer (`alterModifyColumnStatements`) can also change a column's type or default, but it reads internal `_explicitType` / `_explicitDefault` flags that no `Blueprint` method currently sets — a future addition, not a current capability. A `:change()` column's type and default are always restated from the live column as introspected, so calling `:string('nickname', 500)` or `:default('x')` alongside `:change()` will **not** change the type or default. Use `:change()` for `:nullable(...)` only.
:::

## Migrations

A migration is a `.lua` file under a module/plugin's (or core's own) `server/migrations/` directory, tracked by a sibling `migrations.json`. `obelisk make:migration` generates both; see [CLI: Command Reference](/cli/index) for the generator itself. This section documents the file's contract and every field a `Blueprint` column can carry, since those are what actually end up in a migration.

### File naming and the `up`/`down` contract

A migration file is named `<timestamp>_<description>.lua`, where `<timestamp>` is `YYYY_MM_DD_HHMMSS` (the moment it was generated, not run) and `<description>` is a snake_case name, e.g. `2024_10_04_000001_create_actions_table.lua`. The file itself returns a table with two functions:

```lua
--- Migration: Create actions table
return {
    up = function()
        Schema.create('actions', function(table)
            table:id()
            table:string('action_id', 100):unique()
            table:string('label', 255)
            table:text('description')
            table:json('options')
            table:boolean('enabled'):default(1)
            table:timestamps()
        end)

        print('[Migration] Created actions table')
    end,

    down = function()
        Schema.drop('actions')
        print('[Migration] Dropped actions table')
    end
}
```

`up()` applies the migration; `down()` reverses it. Neither takes arguments and neither is expected to return anything. The migration runner (`core/server/bootstrap.lua`) only ever calls `up()` automatically, on server start, for any migration not already recorded in the `migrations` table; nothing in the framework calls `down()` automatically, it's there for you to call by hand if you need to roll a change back.

### `migrations.json`

The sibling file the runner actually reads, one per module/plugin/core, listing every migration filename (without the `.lua` extension) that belongs to it, in the order they should run:

```json
{
  "migrations": [
    "2024_10_04_000001_create_actions_table",
    "2024_10_04_000002_create_interactions_table"
  ]
}
```

`make:migration` appends to this file automatically; if you hand-write a migration file, add its name here too, or the runner will never see it. Order in the array is execution order, not re-sorted by timestamp at runtime.

### Column fields

Every `Blueprint` column-adding method (`:id()`, `:string()`, etc.) inserts an entry into `self.columns` shaped like this, which is what `:toSql()` and `Schema.table()` actually read from:

| Field | Set by | Meaning |
|---|---|---|
| `name` | every column method | the column name, as passed in |
| `kind` | every column method | one of `integer`, `bigInteger`, `string`, `text`, `json`, `float`, `decimal`, `boolean`, `date`, `datetime`, `timestamp`, `enum` |
| `opts` | every column method | a table of kind-specific options, see the type table below |
| `nullable` | every column method (always `false`), `:nullable(value)` | whether the column allows `NULL`. Every column method sets it to `false`, so columns are `NOT NULL` unless a `:nullable()` call flips it |
| `default` | `:boolean()` (defaults to `0`), `:timestamps()` (defaults to `'CURRENT_TIMESTAMP'`), `:default(value)` | the column's `DEFAULT` clause value, formatted per dialect via `formatDefault(kind, value)` |
| `autoIncrement` | `:id()` only | marks the column as auto-incrementing (`AUTO_INCREMENT` on MySQL, `SERIAL`/`BIGSERIAL` on Postgres) |
| `primary` | `:id()` only | marks the column as the table's primary key |

`opts` fields, by `kind`:

| `kind` | `opts` fields | MySQL type | Postgres type |
|---|---|---|---|
| `integer` | `unsigned` (bool, via `:unsigned()` or `:unsignedInteger()`) | `INT` / `INT UNSIGNED`, or plain `INT` if `autoIncrement` | `SERIAL` if `autoIncrement`, else `INTEGER` (no unsigned variant, `:unsigned()` is a no-op) |
| `bigInteger` | `unsigned` (bool) | `BIGINT` / `BIGINT UNSIGNED` | `BIGSERIAL` if `autoIncrement`, else `BIGINT` (no unsigned variant) |
| `string` | `length` (number, default `255`) | `VARCHAR(length)` | `VARCHAR(length)` |
| `text` | none | `TEXT` | `TEXT` |
| `json` | none | `JSON` | `JSONB` |
| `float` | `precision`, `scale` (numbers, both optional) | `FLOAT`, or `FLOAT(precision[,scale])` if `precision` given | `DOUBLE PRECISION`; `FLOAT(precision)` if only `precision` given; `NUMERIC(precision,scale)` if both given (Postgres `FLOAT` takes no scale) |
| `decimal` | `precision` (default `8`), `scale` (default `2`) | `DECIMAL(precision,scale)` | `NUMERIC(precision,scale)` |
| `boolean` | none | `TINYINT(1)` | `BOOLEAN` |
| `date` | none | `DATE` | `DATE` |
| `datetime` | none | `DATETIME` | `TIMESTAMP` |
| `timestamp` | none | `TIMESTAMP` | `TIMESTAMP` |
| `enum` | `values` (list of strings, via `:enum(name, values)`) | `ENUM('v1','v2',...)` | `VARCHAR(255)`, not DB-enforced (Postgres has no inline enum type without a separate `CREATE TYPE`) |

### Index fields

`:index()`/`:unique()` insert an entry into `self.indexes`: `{ name, columns, unique }`, where `unique` is `true`/`false` and `columns` is always a list, even when called with a single column name.

### Foreign key fields

`:foreign(column):references(refColumn):on(refTable):onDelete(action)` (or `:onUpdate(action)`, or `.getBlueprint()`) builds an entry in `self.foreignKeys`: `{ column, references, on, onDelete, onUpdate }`. `onDelete`/`onUpdate` both default to `'RESTRICT'` if not set explicitly; the framework doesn't validate `action` against an allowlist, so any value your database accepts (`CASCADE`, `SET NULL`, `NO ACTION`, `RESTRICT`) works, but a typo reaches the database as-is rather than failing at build time.

## BaseModel

The Active Record base class every model extends, either via `BaseModel:extend(tableName)` or the equivalent explicit `setmetatable(Model, { __index = BaseModel })` form. See [ORM: Models](/concepts/orm#models) for the class-level configuration fields (`primaryKey`, `timestamps`, `fillable`, `hidden`, `casts`).

### Constructing and querying

**`BaseModel:extend(tableName)`**
Returns a new subclass whose class-level lookups fall back to the parent (typically `BaseModel` itself) and whose instances resolve methods on the child first.

**`.new(attributes)`**
Constructor. Returns an instance with the given `attributes` (defaults to `{}`), an empty `relations` table, and `exists = false`. Called as `Model.new(...)`, not `Model:new(...)`.

**`:newQuery()`**
Sync. Returns a `QueryBuilder.new(self.table, self.primaryKey)`, the query object every other model method builds on.

**`:select(...)`**, **`:selectRaw(...)`**, **`:where(...)`**, **`:orWhere(...)`**, **`:whereIn(...)`**, **`:whereNull(...)`**, **`:whereNotNull(...)`**, **`:orderBy(...)`**, **`:limit(...)`**, **`:offset(...)`**, **`:join(...)`**, **`:leftJoin(...)`**, **`:groupBy(...)`**, **`:get()`**, **`:firstOr(callback)`**
Proxies onto the same-named `QueryBuilder` method: each opens a fresh `newQuery()` (which attaches `.model`) and forwards straight to it, letting you skip the explicit `newQuery()` call, e.g. `Inventory:where('owner', id):get()`. Same parameters and return value as documented under [QueryBuilder](#querybuilder) above — for the chainable starters that's a `QueryBuilder` (so the rest of the chain and its terminal `get`/`getAsync`/`first`/etc. behave identically); for the `get` proxy specifically, because `.model` is attached, the result is JSON-cast-decoded model instances, not raw rows. `firstOr`'s `callback` is a fallback-value function (Laravel convention), not an async completion handler — there is no `firstOrAsync`.

**`:find(id)`** / **`:findAsync(id, callback)`**
Sync / async. Looks up a row by primary key. Returns the wrapped model instance, or `nil` if not found.

**`:firstOrNew(attributes, values)`**
Sync only. Looks up the first row matching every key/value pair in `attributes` (AND'd together). Found → returns it. Not found → returns a new, **unsaved** instance (`exists = false`) built from `attributes` merged with `values` (`values`' keys win on conflict); the caller calls `:save()`/`:saveAsync()` themselves. No async form — the only I/O is the lookup.

**`:firstOrCreate(attributes, values)`** / **`:firstOrCreateAsync(attributes, values, callback)`**
Sync / async. Same lookup as `firstOrNew`. Found → returns/callbacks it as-is (`values` is ignored). Not found → creates and saves a new instance from `attributes` merged with `values` (equivalent to `:create(...)`/`:createAsync(...)`) — no separate `:save()` call needed.

**`:updateOrCreate(attributes, values)`** / **`:updateOrCreateAsync(attributes, values, callback)`**
Sync / async. Same lookup. Found → applies every key in `values` via `:set()`, then `:save()`s/`:saveAsync()`s it, returns/callbacks the updated instance. Not found → same create-with-merge as `firstOrCreate`.

**`:get()`** / **`:getAsync(callback)`**
Sync / async. Returns every row in the table as an array of model instances. (This replaces the old `all()`/`allSync()` methods.)

**`:newFromQuery(attributes)`**
Sync. Returns a model instance built from a raw result row, marked `exists = true` with `original` set to a copy of `attributes`. Used internally by `find`/`get`/relationship loaders; rarely called directly.

### Saving and deleting

**`:create(attributes)`** / **`:createAsync(attributes, callback)`**
Sync / async. Builds a new instance from `attributes` and saves it in one call. Returns the saved instance.

**`:save()`** / **`:saveAsync(callback)`**
Sync / async. Inserts if `self.exists` is `false`, updates by primary key otherwise. When `self.timestamps` is `true`, sets `created_at` (insert only) and `updated_at` (every save) via `Database.now()`. Returns `self`.

**`:delete()`** / **`:deleteAsync(callback)`**
Sync / async. Deletes the row by primary key and sets `self.exists = false`. Returns/callbacks `false` immediately, without touching the database, if the instance doesn't already exist.

### Attributes

**`:set(key, value)`**
Sync. Sets `self.attributes[key] = value`. No return.

**`:isDirty(key)`**
Sync. Returns `boolean`. With `key`, compares that attribute against `self.original`. Without it, checks every attribute for any difference from `self.original`.

**`:toTable()`**
Sync. Returns a `table`, a deep copy of `attributes` with every key listed in `self.hidden` removed, plus any loaded `relations` recursively converted the same way. Used to serialize a model before sending it to the client.

**`:copyTable(t)`**
Sync helper. Returns a deep copy of `t`. Used internally by `toTable` and elsewhere; safe to call directly if you need a deep copy of a plain table.

**`.field` direct access**
Every model instance's metatable `__index` (set in `BaseModel.__index`/the per-subclass `__index` built by `extend`) is a function, not a plain table, that checks `attributes[key]`, then `relations[key]`, then falls through to the class's method table (`BaseModel[key]` or `child[key]`). So `instance.name` reads `instance.attributes.name` (or, if not an attribute, a loaded `instance.relations.name`) without an explicit `.attributes`/`.relations` lookup. `instance.attributes.field` and `instance.relations.name` still work unchanged; `.field` is a transparent read-only fallback on top of them, not a separate storage location. An attribute takes precedence over a same-named relation.

### Relationships

**`:hasOne(relatedModel, foreignKey, localKey)`** / **`:hasMany(relatedModel, foreignKey, localKey)`**
Sync. Return a relationship descriptor (a plain table, not a query) for `load`/`loadAsync` to resolve later. `localKey` defaults to `self.primaryKey`.

**`:belongsTo(relatedModel, foreignKey, ownerKey)`**
Sync. Returns a relationship descriptor. `ownerKey` defaults to `relatedModel.primaryKey`.

**`:belongsToMany(relatedModel, pivotTable, foreignPivotKey, relatedPivotKey)`**
Sync. Returns a relationship descriptor for a many-to-many relation through `pivotTable`.

**`:load(relationName)`** / **`:loadAsync(relationName, callback)`**
Sync / async. Resolves the relationship method named `relationName` on the model (e.g. `self:owner()`), runs the appropriate query for its type, caches the result on `self.relations[relationName]`, and returns it. Returns the cached value directly on a repeat call, without re-querying. `relationName` must name a method defined on the model that returns one of the four descriptors above.

**`BaseModel:with(path)`**
Sync. Returns a `QueryBuilder` — sugar for `self:newQuery():with(path)`, so it opens a fresh model-bound query and forwards straight to `QueryBuilder:with` (see [QueryBuilder: `:with(path)`](#building-and-executing)). Chainable ahead of a terminal `get()`/`getAsync()`; each call records another independent path rather than replacing the previous one.

**`BaseModel:eagerLoad(instances, path)`**
Sync. No return; mutates `instances` in place. The engine `get()`/`getAsync()` call once per recorded `with()` path once the initial fetch resolves. Splits `path` into its first segment and the remaining dot-separated `rest`, resolves the relationship descriptor for that segment off `instances[1]`, and runs one batched query (`whereIn` on the relevant key across every instance) to fetch every related row in a single round trip, instead of one query per instance. Populates `inst.relations[segment]` on every instance in `instances` from that one query's results. For a `belongsToMany` segment, related rows sharing the same primary key across different owners are interned to one shared model instance (rather than one distinct instance per pivot row), so a nested path continues to populate correctly for every owner. If `rest` is non-empty, recurses into `related:eagerLoad(nextLevelInstances, rest)` against the deduplicated set of related instances just populated, to resolve the next segment of the path.

**`:attach(relationName, id, pivotData, callback)`**
Async only, despite the bare name — there is no `attachAsync` and no sync form. Delegates to `QueryBuilder:insertAsync`. Inserts a pivot row linking the current instance to `id`, merging in any extra `pivotData`, and calls `callback(insertId)`. Only valid on a `belongsToMany` relationship; throws otherwise.

**`:detach(relationName, id, callback)`**
Async only, despite the bare name — there is no `detachAsync` and no sync form. Delegates to `QueryBuilder:deleteAsync`. Removes the pivot row linking the current instance to `id` and calls `callback(affectedRows)`. Omit `id` to detach every related row. Only valid on a `belongsToMany` relationship; throws otherwise.

```lua
function Inventory:owner()
    return self:belongsTo(Character, 'owner', 'id')
end

local character = item:load('owner')
```

## Dialects

The layer `Database`, `QueryBuilder`, and `Schema` all route through for anything SQL-dialect-specific (identifier quoting, column types, index syntax). Selected via the `db_driver` convar; see [ORM: Dialects](/concepts/orm#dialects).

**`Dialects.register(name, dialect)`**
Sync. No return. Registers a dialect implementation under a driver name (`'mysql'`, `'postgres'`). Called once per dialect module at load time, not something you call yourself.

**`Dialects.resolve(name)`**
Sync. Returns the registered dialect `table`. Throws if `name` isn't registered, listing the known drivers in the error, rather than silently falling back to one.

**`Dialects.buildQuoter(quoteChar)`**
Sync. Returns a `function(identifier): string`. The shared identifier-quoting helper every dialect's `quoteIdentifier` is built from: splits `identifier` on `.`, validates each segment against `[A-Za-z0-9_$]+` (or a bare `*`), and wraps each in `quoteChar`. This is the single point of defense against identifier-based SQL injection across both dialects, and throws on anything that fails validation.
