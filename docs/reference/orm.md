# ORM API Reference

Exhaustive reference for every public function in the ORM (`core/server/ORM/`). For an architectural overview and everyday usage patterns, read [ORM](/concepts/orm) first; this page is the complete signature list, including the lower-level `Database` layer and internal `QueryBuilder`/`Blueprint` methods that the concepts page only summarizes.

**Sync vs async:** a `...Sync` function blocks and returns its result directly. The non-`Sync` counterpart runs the query on a separate thread (`Citizen.CreateThread`) and calls a `callback` with the result instead of returning it; it has no meaningful return value. Several `QueryBuilder`/`BaseModel` write methods are dual mode: pass a `callback` for the async form, omit it for the sync form that returns a value directly.

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

**`Database.querySync(query, params)`**
Sync. Returns `table` (the raw result rows).

**`Database.query(query, params, callback)`**
Async. Calls `callback(result)`. `params` defaults to `{}`.

**`Database.insertSync(query, params)`**
Sync. Returns `number` (the inserted row's id, or `0` if the connector didn't report one).

**`Database.insert(query, params, callback)`**
Async. Calls `callback(insertId)`.

**`Database.updateSync(query, params)`**
Sync. Returns `number` (affected row count, or `0`).

**`Database.update(query, params, callback)`**
Async. Calls `callback(affectedRows)`.

**`Database.deleteSync(query, params)`**
Sync alias for `Database.updateSync`.

**`Database.delete(query, params, callback)`**
Async alias for `Database.update`.

**`Database.executeSync(query, params)`**
Sync alias for `Database.querySync`.

**`Database.execute(query, params, callback)`**
Async alias for `Database.query`.

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

**`:get(callback)`** / **`:getSync()`**
Async / sync. Runs the built query. Returns (or passes to `callback`) the raw result rows, not model instances.

**`:first(callback)`** / **`:firstSync()`**
Async / sync. Same as `get`, but with `limit(1)` applied first, returning a single row (or `nil`) instead of a list.

**`:count(callback)`** / **`:countSync()`**
Async / sync. Temporarily swaps in `selectRaw('COUNT(*) as count')`, runs the query, restores the prior select, and returns a `number` (coerced via `tonumber`, defaulting to `0`; this also handles Postgres returning the count as a string).

**`:insert(data, callback)`**
Dual mode. With a `callback`: async, calls `callback(insertId)`. Without one: sync, returns `number insertId` directly. Builds `INSERT INTO ... (...) VALUES (...)`, appending the dialect's `RETURNING` clause where applicable (Postgres).

**`:update(data, callback)`**
Dual mode, same pattern as `insert`. Returns/callbacks `number affectedRows`. Builds `UPDATE ... SET ...`, honoring any `where()` conditions already added to the builder.

**`:delete(callback)`**
Dual mode, same pattern. Returns/callbacks `number affectedRows`. Builds `DELETE FROM ...`, honoring any `where()` conditions already added.

**`:paginate(page, perPage, callback)`**
Async only. `page` defaults to `1`, `perPage` to `15`. Runs a count, then a `limit`/`offset` query, and calls `callback({ data, total, perPage, currentPage, lastPage })`.

```lua
local recent = QueryBuilder.new('inventories')
    :where('container', 'stash')
    :whereIn('item', {'water', 'bread'})
    :orderBy('created_at', 'DESC')
    :limit(10)
    :getSync()
```

## Schema

Table creation and migration helpers. All functions below are static, called as `Schema.x(...)`.

**`Schema.create(tableName, callback)`**
Sync. Returns `table` (the result of the last statement run). `callback(blueprint)` populates a `Blueprint`; every statement `blueprint:toSql()` produces (the `CREATE TABLE` plus any standalone `CREATE INDEX` statements a dialect needs) runs in order via `Database.querySync`.

**`Schema.table(tableName, callback)`**
Sync. No meaningful return. Same `callback(blueprint)` pattern as `create`, but every new column becomes an `ALTER TABLE ... ADD COLUMN ...` statement and every index becomes the dialect's `ALTER`-time index statement, for adding columns/indexes to an existing table.

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
Auto-incrementing integer primary key. `name` defaults to `'id'`. Not nullable.

**`:string(name, length)`**
VARCHAR-like column. `length` defaults to `255`. Nullable by default.

**`:text(name)`** / **`:json(name)`**
TEXT / JSON column. Nullable by default.

**`:integer(name)`** / **`:bigInteger(name)`** / **`:unsignedInteger(name)`**
INT / BIGINT / unsigned INT column. Nullable by default.

**`:float(name, precision, scale)`** / **`:decimal(name, precision, scale)`**
FLOAT / DECIMAL column. `decimal`'s `precision` defaults to `8`, `scale` to `2`. Nullable by default.

**`:boolean(name)`**
BOOLEAN column. Nullable, defaults to `0`.

**`:date(name)`** / **`:datetime(name)`** / **`:timestamp(name)`**
DATE / DATETIME / TIMESTAMP column. Nullable by default.

**`:timestamps()`**
Adds both `created_at` and `updated_at` as TIMESTAMP columns defaulting to `CURRENT_TIMESTAMP` at the database level. Note that `updated_at` isn't auto-refreshed by the database (there's no portable Postgres equivalent of MySQL's `ON UPDATE CURRENT_TIMESTAMP`); `BaseModel:save`/`saveSync` set it explicitly via `Database.now()` on every save instead.

**`:enum(name, values)`**
ENUM column restricted to `values` (a list of strings). Nullable by default.

### Modifiers

These mutate the most recently added column, so call them immediately after the column method they apply to.

**`:nullable()`** / **`:notNullable()`**
Marks the last column nullable / not nullable.

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

## BaseModel

The Active Record base class every model extends, either via `BaseModel:extend(tableName)` or the equivalent explicit `setmetatable(Model, { __index = BaseModel })` form. See [ORM: Models](/concepts/orm#models) for the class-level configuration fields (`primaryKey`, `timestamps`, `fillable`, `hidden`, `casts`).

### Constructing and querying

**`BaseModel:extend(tableName)`**
Returns a new subclass whose class-level lookups fall back to the parent (typically `BaseModel` itself) and whose instances resolve methods on the child first.

**`.new(attributes)`**
Constructor. Returns an instance with the given `attributes` (defaults to `{}`), an empty `relations` table, and `exists = false`. Called as `Model.new(...)`, not `Model:new(...)`.

**`:newQuery()`**
Sync. Returns a `QueryBuilder.new(self.table, self.primaryKey)`, the query object every other model method builds on.

**`:find(id, callback)`** / **`:findSync(id)`**
Async / sync. Looks up a row by primary key. Returns the wrapped model instance, or `nil` if not found.

**`:all(callback)`** / **`:allSync()`**
Async / sync. Returns every row in the table as an array of model instances.

**`:newFromQuery(attributes)`**
Sync. Returns a model instance built from a raw result row, marked `exists = true` with `original` set to a copy of `attributes`. Used internally by `find`/`all`/relationship loaders; rarely called directly.

### Saving and deleting

**`:create(attributes, callback)`** / **`:createSync(attributes)`**
Async / sync. Builds a new instance from `attributes` and saves it in one call. Returns the saved instance.

**`:save(callback)`** / **`:saveSync()`**
Async / sync. Inserts if `self.exists` is `false`, updates by primary key otherwise. When `self.timestamps` is `true`, sets `created_at` (insert only) and `updated_at` (every save) via `Database.now()`. Returns `self`.

**`:delete(callback)`** / **`:deleteSync()`**
Async / sync. Deletes the row by primary key and sets `self.exists = false`. Returns/callbacks `false` immediately, without touching the database, if the instance doesn't already exist.

### Attributes

**`:get(key)`**
Sync. Returns `self.attributes[key]`.

**`:set(key, value)`**
Sync. Sets `self.attributes[key] = value`. No return.

**`:isDirty(key)`**
Sync. Returns `boolean`. With `key`, compares that attribute against `self.original`. Without it, checks every attribute for any difference from `self.original`.

**`:toTable()`**
Sync. Returns a `table`, a deep copy of `attributes` with every key listed in `self.hidden` removed, plus any loaded `relations` recursively converted the same way. Used to serialize a model before sending it to the client.

**`:copyTable(t)`**
Sync helper. Returns a deep copy of `t`. Used internally by `toTable` and elsewhere; safe to call directly if you need a deep copy of a plain table.

### Relationships

**`:hasOne(relatedModel, foreignKey, localKey)`** / **`:hasMany(relatedModel, foreignKey, localKey)`**
Sync. Return a relationship descriptor (a plain table, not a query) for `load`/`loadSync` to resolve later. `localKey` defaults to `self.primaryKey`.

**`:belongsTo(relatedModel, foreignKey, ownerKey)`**
Sync. Returns a relationship descriptor. `ownerKey` defaults to `relatedModel.primaryKey`.

**`:belongsToMany(relatedModel, pivotTable, foreignPivotKey, relatedPivotKey)`**
Sync. Returns a relationship descriptor for a many-to-many relation through `pivotTable`.

**`:load(relationName, callback)`** / **`:loadSync(relationName)`**
Async / sync. Resolves the relationship method named `relationName` on the model (e.g. `self:owner()`), runs the appropriate query for its type, caches the result on `self.relations[relationName]`, and returns it. Returns the cached value directly on a repeat call, without re-querying. `relationName` must name a method defined on the model that returns one of the four descriptors above.

**`:attach(relationName, id, pivotData, callback)`**
Dual mode (delegates to `QueryBuilder:insert`, so pass `callback` for async, omit it for sync returning the pivot row's insert id). Inserts a pivot row linking the current instance to `id`, merging in any extra `pivotData`. Only valid on a `belongsToMany` relationship; throws otherwise.

**`:detach(relationName, id, callback)`**
Dual mode (delegates to `QueryBuilder:delete`). Removes the pivot row linking the current instance to `id`. Omit `id` to detach every related row. Only valid on a `belongsToMany` relationship; throws otherwise.

```lua
function Inventory:owner()
    return self:belongsTo(Character, 'owner', 'id')
end

local character = item:loadSync('owner')
```

## Dialects

The layer `Database`, `QueryBuilder`, and `Schema` all route through for anything SQL-dialect-specific (identifier quoting, column types, index syntax). Selected via the `db_driver` convar; see [ORM: Dialects](/concepts/orm#dialects).

**`Dialects.register(name, dialect)`**
Sync. No return. Registers a dialect implementation under a driver name (`'mysql'`, `'postgres'`). Called once per dialect module at load time, not something you call yourself.

**`Dialects.resolve(name)`**
Sync. Returns the registered dialect `table`. Throws if `name` isn't registered, listing the known drivers in the error, rather than silently falling back to one.

**`Dialects.buildQuoter(quoteChar)`**
Sync. Returns a `function(identifier): string`. The shared identifier-quoting helper every dialect's `quoteIdentifier` is built from: splits `identifier` on `.`, validates each segment against `[A-Za-z0-9_$]+` (or a bare `*`), and wraps each in `quoteChar`. This is the single point of defense against identifier-based SQL injection across both dialects, and throws on anything that fails validation.
