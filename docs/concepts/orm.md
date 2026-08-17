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
- **`timestamps`** — when `true`, `save` and `saveAsync` stamp `created_at` on insert and `updated_at` on every save, using `Database.now()`.
- **`fillable`** — documents which attributes are mass-assignable (used as a reference by generators; not enforced inside `BaseModel` itself).
- **`hidden`** — attribute names stripped out by `toTable()`, e.g. before sending a model to the client.
- **`casts`** — attribute cast hints such as `'json'`, matching the `Inventory.metadata` example above.

### Finding, saving, deleting

`BaseModel` exposes both sync (direct return) and async (callback-based) variants of its core operations. Bare method names are sync; methods suffixed with `Async` take a callback:

```lua
-- Find
local item = Inventory:find(id)                    -- sync
Inventory:findAsync(id, function(item) ... end)   -- async

-- Get all rows
local items = Inventory:get()                      -- sync (replaces old all()/allSync())
Inventory:getAsync(function(items) ... end)       -- async

-- Create + save
local item = Inventory.new({ owner = charId, container = 'player', slot = 0, item = 'water', count = 1 })
item:save()                                        -- sync
item:saveAsync(function(saved) ... end)           -- async

-- create()/createAsync() build and save in one call
local item = Inventory:create({ owner = charId, item = 'water', count = 1 })
Inventory:createAsync({ owner = charId, item = 'water', count = 1 }, function(item) ... end)

-- Delete
item:delete()                                      -- sync
item:deleteAsync(function(ok) ... end)            -- async
```

`save`/`saveAsync` decide insert vs. update from `instance.exists`: a freshly-`new`'d instance inserts (and then has its primary key set from the insert id), while an instance loaded via `find`/`get`/`create` updates in place.

### Attribute access

A model instance's metatable `__index` falls back through `attributes`, then loaded `relations`, then the class's own method table, so you can read a column or a loaded relation directly off the instance instead of going through `instance.attributes`:

```lua
local item = Inventory:find(id)
print(item.item, item.count)          -- same as item.attributes.item, item.attributes.count

local character = item:load('owner')
print(item.owner.name)                -- reads the loaded `owner` relation off item.relations
```

`instance.attributes.field` still works unchanged — `.field` is a convenience fallback, not a replacement; nothing stops you from using either form. If an attribute and a relation share a name, the attribute wins (the lookup checks `attributes` first). If nothing matches in `attributes` or `relations`, the lookup falls through to the model's class methods, which is how instance calls like `item:save()` resolve in the first place.

### Relationships

`BaseModel` implements four relationship helpers — `hasOne`, `hasMany`, `belongsTo`, and `belongsToMany` — each returning a relationship descriptor consumed by `load`/`loadAsync`:

```lua
function Inventory:owner()
    return self:belongsTo(Character, 'owner', 'id')
end
```

```lua
-- Lazy-load a relation
local character = item:load('owner')                        -- sync
item:loadAsync('owner', function(character) ... end)       -- async
```

`belongsToMany(relatedModel, pivotTable, foreignPivotKey, relatedPivotKey)` relationships also get `attach(relationName, id, pivotData, callback)` and `detach(relationName, id, callback)` for managing pivot-table rows.

#### Eager loading with `with()`

`load`/`loadAsync` resolve one relation on one already-fetched instance at a time. For a list of instances, calling `load` in a loop means one query per instance — the classic N+1 pattern. `Model:with(path)` avoids that: it records a relation path to eager-load once the terminal `get()`/`getAsync()` fetch resolves, then loads it for the whole result set in one batched query per path segment, not one per instance:

```lua
-- One query for the inventories, one more for every owner they reference
local items = Inventory:with('owner'):get()
for _, item in ipairs(items) do
    print(item.relations.owner.name)   -- already loaded, no extra query
end
```

`path` can be dot-separated to eager-load a chain of nested relations (`'a.b.c'`), one additional batched query per segment:

```lua
local items = Inventory:with('owner.faction'):get()
```

Multiple `with()` calls chain and accumulate independent paths rather than overwriting each other:

```lua
Inventory:with('owner'):with('owner.faction'):get()
```

For `belongsToMany` relations specifically, a related row shared by more than one owner (e.g. the same faction on two characters) is interned to a single shared model instance rather than one distinct instance per pivot row, so a nested path through it populates correctly for every owner that references it.

## Query Builder

`QueryBuilder` is the fluent API underneath every model query. You can also use it directly via `QueryBuilder.new(tableName)`:

```lua
local recent = QueryBuilder.new('inventories')
    :where('container', 'stash')
    :whereIn('item', {'water', 'bread'})
    :orderBy('created_at', 'DESC')
    :limit(10)
    :get()
```

Available methods include:

- **Selecting**: `select(columns)`, `selectRaw(expression)` (for aggregates like `COUNT(*)`; internal-only, never pass caller input here).
- **Filtering**: `where(column, [operator], value)`, `orWhere(...)`, `whereIn(column, values)`, `whereNull(column)`, `whereNotNull(column)`.
- **Ordering/paging**: `orderBy(column, direction)`, `limit(n)`, `offset(n)`.
- **Joins**: `join(tableName, first, operator, second, [joinType])`, `leftJoin(tableName, first, operator, second)`.
- **Grouping**: `groupBy(columns)`.
- **Execution**: `get()` / `getAsync(callback)`, `first()` / `firstAsync(callback)`, `count()` / `countAsync(callback)`, `insert(data)` / `insertAsync(data, callback)`, `update(data)` / `updateAsync(data, callback)`, `delete()` / `deleteAsync(callback)`, `paginateAsync(page, perPage, callback)`.

Every identifier (table/column name, operator, join type, sort direction) is validated against an allowlist before being interpolated into SQL, and every value is passed as a `?` parameter — this is what keeps `where`/`join`/`orderBy` safe from injection even though they build SQL by string concatenation internally.

A model class proxies the same starter methods (`select`, `selectRaw`, `where`, `orWhere`, `whereIn`, `whereNull`, `whereNotNull`, `orderBy`, `limit`, `offset`, `join`, `leftJoin`, `groupBy`), so you can skip the explicit `newQuery()` call and start a query straight off the model:

```lua
Inventory:where('container', 'stash'):orderBy('created_at', 'DESC'):limit(10):get()
```

This is equivalent to `Inventory:newQuery():where(...)` (each proxy just opens a fresh query, with `.model` attached, and forwards to it). Because the query is opened off the model, `get()`/`getAsync()`/`first()`/`firstAsync()` decode JSON casts and return model instances, not raw rows — that's only true of a *bare* `QueryBuilder.new('inventories')` with no owning model.

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
- **`nullable(value)`** / **`default(value)`** / **`unsigned()`** — modify the most recently added column. Every column is `NOT NULL` by default; `nullable()` (or `nullable(true)`) makes the last column optional, and `nullable(false)` states the default explicitly.
- **`change()`** — marks the last-defined column as an alteration of an existing column, for use inside `Schema.table(...)`. Today this is wired end-to-end for nullability changes only.
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
