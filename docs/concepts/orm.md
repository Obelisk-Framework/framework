# ORM

Obelisk ships a small Laravel/Eloquent-inspired ORM, implemented entirely in Lua and loaded as part of the core resource. It has three pieces, loaded in this order (see `fxmanifest.lua`'s `server_scripts`):

- `Database` — the connection/dialect layer, a thin wrapper over a MySQL-protocol connector resource.
- `QueryBuilder` — a fluent, parameterized SQL query builder.
- `Schema` (with `Blueprint`) — table creation/migration helpers.
- `BaseModel` — an Active Record base class that models extend.

There is no in-memory fallback: `Database.init()` fails fast if no connector resource (`oblsk_connector`, `oxmysql`, `ghmattimysql`, or `mysql-async`) is running.

## Models

Every model extends `BaseModel`, giving it query, save, and relationship helpers. The intended, documented API is `extend`:

```lua
Inventory = BaseModel:extend('inventories')
```

`extend(tableName)` returns a subclass whose class-level lookups fall back to `BaseModel` and whose instances resolve custom methods and relationship definitions on the child, centralizing the `setmetatable` boilerplate that model generation otherwise requires. It's equivalent to the explicit form below, which older generated models and some existing plugins still use:

```lua
Inventory = {}
setmetatable(Inventory, { __index = BaseModel })
```

A model configures itself with class-level fields, all inherited from `BaseModel`'s defaults:

```lua
BaseModel.primaryKey = 'id'
BaseModel.timestamps = true
BaseModel.fillable = {}
BaseModel.hidden = {}
BaseModel.casts = {}
```

The real `Inventory` model (`plugins/oblsk_inventory/server/models/Inventory.lua`) shows the pattern in practice, including the `'json'` cast for a metadata column:

```lua
Inventory = BaseModel:extend('inventories')

Inventory.primaryKey = 'id'
Inventory.timestamps = true

Inventory.fillable = {
    'owner', 'container', 'slot', 'item', 'count',
    'metadata',   -- JSON blob: quality, durability, ammo, etc.
}

Inventory.hidden = {}

Inventory.casts = {
    metadata = 'json',
}
```

- **`primaryKey`** — the column used by `find`/`save`/`delete` (default `'id'`).
- **`timestamps`** — when `true`, `save`/`saveSync` stamp `created_at` on insert and `updated_at` on every save, using `Database.now()`.
- **`fillable`** — documents which attributes are mass-assignable (used as a reference by generators; not enforced inside `BaseModel` itself).
- **`hidden`** — attribute names stripped out by `toTable()`, e.g. before sending a model to the client.
- **`casts`** — attribute cast hints such as `'json'`, matching the `Inventory.metadata` example above.

### Finding, saving, deleting

`BaseModel` exposes both async (callback-based) and `Sync` variants of its core operations:

```lua
-- Find
Inventory:find(id, function(item) ... end)
local item = Inventory:findSync(id)

-- All rows
Inventory:all(function(items) ... end)
local items = Inventory:allSync()

-- Create + save
local item = Inventory.new({ owner = charId, container = 'player', slot = 0, item = 'water', count = 1 })
item:save(function(saved) ... end)      -- async
item:saveSync()                          -- sync

-- create()/createSync() build and save in one call
Inventory:create({ owner = charId, item = 'water', count = 1 }, function(item) ... end)
local item = Inventory:createSync({ owner = charId, item = 'water', count = 1 })

-- Delete
item:delete(function(ok) ... end)
item:deleteSync()
```

`save`/`saveSync` decide insert vs. update from `instance.exists`: a freshly-`new`'d instance inserts (and then has its primary key set from the insert id), while an instance loaded via `find`/`all`/`create` updates in place.

### Relationships

`BaseModel` implements four relationship helpers — `hasOne`, `hasMany`, `belongsTo`, and `belongsToMany` — each returning a relationship descriptor consumed by `load`/`loadSync`:

```lua
function Inventory:owner()
    return self:belongsTo(Character, 'owner', 'id')
end
```

```lua
-- Lazy-load a relation
item:load('owner', function(character) ... end)
local character = item:loadSync('owner')
```

`belongsToMany(relatedModel, pivotTable, foreignPivotKey, relatedPivotKey)` relationships also get `attach(relationName, id, pivotData, callback)` and `detach(relationName, id, callback)` for managing pivot-table rows.

## Query Builder

`QueryBuilder` is the fluent API underneath every model query. You can also use it directly via `QueryBuilder.new(tableName)`:

```lua
local recent = QueryBuilder.new('inventories')
    :where('container', 'stash')
    :whereIn('item', {'water', 'bread'})
    :orderBy('created_at', 'DESC')
    :limit(10)
    :getSync()
```

Available methods include:

- **Selecting**: `select(columns)`, `selectRaw(expression)` (for aggregates like `COUNT(*)`; internal-only, never pass caller input here).
- **Filtering**: `where(column, [operator], value)`, `orWhere(...)`, `whereIn(column, values)`, `whereNull(column)`, `whereNotNull(column)`.
- **Ordering/paging**: `orderBy(column, direction)`, `limit(n)`, `offset(n)`.
- **Joins**: `join(tableName, first, operator, second, [joinType])`, `leftJoin(tableName, first, operator, second)`.
- **Grouping**: `groupBy(columns)`.
- **Execution**: `get(callback)` / `getSync()`, `first(callback)` / `firstSync()`, `count(callback)` / `countSync()`, `insert(data, [callback])`, `update(data, [callback])`, `delete([callback])`, `paginate(page, perPage, callback)`.

Every identifier (table/column name, operator, join type, sort direction) is validated against an allowlist before being interpolated into SQL, and every value is passed as a `?` parameter — this is what keeps `where`/`join`/`orderBy` safe from injection even though they build SQL by string concatenation internally.

A model class proxies the same starter methods (`select`, `selectRaw`, `where`, `orWhere`, `whereIn`, `whereNull`, `whereNotNull`, `orderBy`, `limit`, `offset`, `join`, `leftJoin`, `groupBy`), so you can skip the explicit `newQuery()` call and start a query straight off the model:

```lua
Inventory:where('container', 'stash'):orderBy('created_at', 'DESC'):limit(10):getSync()
```

This is equivalent to `QueryBuilder.new('inventories'):where(...)` (each proxy just opens a fresh query and forwards to it) and returns the same raw rows, not model instances, since it's the same `QueryBuilder` underneath.

## Schema & Migrations

`Schema.create(tableName, callback)` takes a callback that receives a `Blueprint` for defining columns:

```lua
Schema.create('inventories', function(table)
    table:id()
    table:string('owner', 64)
    table:string('container', 32)
    table:integer('slot')
    table:string('item', 64)
    table:integer('count')
    table:json('metadata')
    table:timestamps()

    table:index('owner')
    table:unique({'container', 'slot', 'owner'})
end)
```

`Blueprint` methods used above:

- **`id(name)`** — auto-incrementing integer primary key (defaults to `id`).
- **`string(name, length)`**, **`text(name)`**, **`json(name)`**, **`integer(name)`**, **`bigInteger(name)`**, **`unsignedInteger(name)`**, **`float(name, precision, scale)`**, **`decimal(name, precision, scale)`**, **`boolean(name)`**, **`date(name)`**, **`datetime(name)`**, **`timestamp(name)`**, **`enum(name, values)`**.
- **`timestamps()`** — adds `created_at`/`updated_at`, both defaulting to `CURRENT_TIMESTAMP` at the DB level (not auto-refreshed by the DB — `BaseModel` sets `updated_at` itself on every save).
- **`nullable()`** / **`notNullable()`** / **`default(value)`** / **`unsigned()`** — modify the most recently added column.
- **`index(columns, [name])`** / **`unique(columns, [name])`** — add an index/unique constraint; `unique()` with no columns uses the last-defined column.
- **`foreign(column)`** — chainable: `:references(col):on(table):onDelete(action)`.

Other `Schema` statics: `Schema.drop(tableName)`, `Schema.hasTable(tableName)`, `Schema.table(tableName, callback)` (add columns/indexes to an existing table), `Schema.hasColumn(tableName, columnName)`, `Schema.dropColumn(tableName, columnName)`, `Schema.renameColumn(tableName, from, to)`.

Migrations live under a module or plugin's `server/migrations/` directory — this is the exact path the CLI's `make:module` generator writes to when the "Database Migration" feature is selected (see [Quick Start](/guide/quick-start)).

## Dialects

MySQL/MariaDB is the default SQL dialect. PostgreSQL is also supported, selected via the `db_driver` convar — `"mysql"` or `"postgres"`, defaulting to `"mysql"`. This is a deliberate choice, not an inference: `Database.init()` reads `db_driver` explicitly and does **not** infer the dialect from the `mysql_connection_string` connection string's scheme, so the two never disagree.

```
set db_driver "postgres"
```

Setting `db_driver postgres` also requires `oblsk_connector` to be the active connector resource — any other connector (`oxmysql`, `ghmattimysql`, `mysql-async`) only speaks MySQL, and `Database.init()` fails fast with a fatal error if `db_driver` is `postgres` while a different connector is running.

For the complete function-by-function signature list, including the lower-level `Database` layer and every `QueryBuilder`/`Blueprint` method only summarized above, see the [ORM API Reference](/reference/orm).
