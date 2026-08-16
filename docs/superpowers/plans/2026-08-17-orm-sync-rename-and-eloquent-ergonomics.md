# ORM sync/async rename + Eloquent ergonomics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the core ORM's naming so bare method names are synchronous
(the common case) and `...Async` suffixes are callback-based (the rare
case), and land three ergonomics improvements: direct `.field` attribute
access on model instances, a model-aware `get()` that replaces
`all()`/`allSync()`, and nested-path `:with('a.b.c')` eager loading.

**Architecture:** Mechanical rename across `Database`/`QueryBuilder`/
`BaseModel` plus every in-core caller and the existing `tests/orm_spec.lua`
suite, done bottom-up (Database → QueryBuilder → BaseModel) so each layer's
tests stay green before the next layer is touched. New behavior (`.field`
access, model-aware `get()`, `with()`) is added test-first once naming is
settled, since it's easier to reason about new logic against final names.

**Tech Stack:** Lua 5.4 (server-side FXServer scripts), a hand-rolled test
framework in `tests/orm_spec.lua` run via `lua5.4 tests/orm_spec.lua`
(no external test library — see the `eq`/`eqList`/`truthy`/`falsy`/`throws`
helpers already defined at the top of that file).

**Spec:** `docs/superpowers/specs/2026-08-17-orm-sync-rename-and-eloquent-ergonomics-design.md`

## Global Constraints

- Bare method name = synchronous, returns a value, no callback parameter.
  `...Async` suffix = callback-based. This applies uniformly to `Database`,
  `QueryBuilder`, and `BaseModel`.
- External connector exports (`exports.oxmysql:executeSync`,
  `exports.oblsk_connector:executeSync`, `exports.ghmattimysql:executeSync`
  inside `Database.lua`'s connector-dispatch code) are **never** renamed —
  third-party API, not ours.
- `Schema.lua`'s own public DDL method names are unchanged; it only follows
  its existing calls into the renamed `Database.*` methods.
- No dual-naming/alias period — every old name is fully removed, not kept
  as a deprecated alias.
- This plan covers **core repo only** (`core/server/ORM/*.lua`,
  `core/server/Services/*.lua`, `tests/orm_spec.lua`). The ~42 dependent
  module/plugin repos are a separate rollout effort per the spec's
  "Rollout" section (a multi-agent workflow sweep) — out of scope here.
  This plan's own final task (Task 9) is the prerequisite survey grep for
  that later effort, run against this repo's finished state.
- Run `lua5.4 tests/orm_spec.lua` after every task; it must print all tests
  passing with zero failures before moving to the next task.

---

## File Structure

| File | Responsibility |
|---|---|
| `core/server/ORM/Database.lua` | Renamed `query/insert/update/delete/execute` (now sync) and new `queryAsync/insertAsync/updateAsync/deleteAsync/executeAsync` (callback). |
| `core/server/ORM/QueryBuilder.lua` | Renamed `get/first/count` (sync) + new `getAsync/firstAsync/countAsync`; `insert/update/delete` split into sync-return + new `insertAsync/updateAsync/deleteAsync`; model-aware `get()`/`getAsync()` via `.model` back-ref. |
| `core/server/ORM/BaseModel.lua` | Renamed `find/create/save/delete/load` (sync) + new `findAsync/createAsync/saveAsync/deleteAsync/loadAsync`; `all`/`allSync` removed; `get(key)` attribute getter removed; new function-`__index` metatable for `.field` access; `newQuery()` attaches `.model`; new `with()`/`withAsync()` nested eager loading. |
| `core/server/ORM/Schema.lua` | No new responsibility — its `Database.querySync(...)` calls become `Database.query(...)`. |
| `core/server/Services/ActionService.lua`, `SchedulerService.lua`, `InstanceService.lua`, `EntityStreamerService.lua`, `PolicyService.lua`, `PermissionService.lua` | No new responsibility — each has 1-5 call sites using old `Sync`-suffixed names, updated to new bare names. |
| `tests/orm_spec.lua` | Existing 1365-line suite; every mock/call of a renamed method updated to the new name; new test blocks added for `.field` access, model-aware `get()`, `with()` nested eager loading, and the `insert`/`update`/`delete` sync/async split. |

---

### Task 1: Rename `Database.lua` methods

**Files:**
- Modify: `core/server/ORM/Database.lua:146-236` (the `query`/`querySync`/
  `insert`/`insertSync`/`update`/`updateSync`/`delete`/`deleteSync`/
  `execute`/`executeSync` block)
- Test: `tests/orm_spec.lua` (every `Database.querySync = function...` mock
  and every direct `Database.querySync(...)`/`Database.insertSync(...)`/
  `Database.updateSync(...)` call)

**Interfaces:**
- Produces: `Database.query(query, params) -> table results` (sync),
  `Database.queryAsync(query, params, callback)`,
  `Database.insert(query, params) -> number insertId` (sync),
  `Database.insertAsync(query, params, callback)`,
  `Database.update(query, params) -> number affectedRows` (sync),
  `Database.updateAsync(query, params, callback)`,
  `Database.delete(query, params) -> number affectedRows` (sync, alias of
  `Database.update`), `Database.deleteAsync(query, params, callback)`
  (alias of `Database.updateAsync`), `Database.execute(query, params) ->
  table` (sync, alias of `Database.query`), `Database.executeAsync(query,
  params, callback)` (alias of `Database.queryAsync`).

- [ ] **Step 1: Rewrite the method block in `Database.lua`**

Replace lines 142-236 (from `--- Execute query asynchronously` through the
end of `Database.executeSync`) with:

```lua
--- Execute query synchronously
--- @param query string SQL query
--- @param params table Parameters
--- @return table result
function Database.query(query, params)
    params = params or {}
    return Database.executeQuery(query, params)
end

--- Execute query asynchronously
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback function
function Database.queryAsync(query, params, callback)
    params = params or {}

    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        if callback then
            callback(result)
        end
    end)
end

--- Insert query sync
--- @param query string SQL query
--- @param params table Parameters
--- @return number insertId
function Database.insert(query, params)
    params = params or {}
    local result = Database.executeQuery(query, params)
    return result and result.insertId or 0
end

--- Insert query async
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback with insertId
function Database.insertAsync(query, params, callback)
    params = params or {}

    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        local insertId = result and result.insertId or 0
        if callback then
            callback(insertId)
        end
    end)
end

--- Update query sync
--- @param query string SQL query
--- @param params table Parameters
--- @return number affectedRows
function Database.update(query, params)
    params = params or {}
    local result = Database.executeQuery(query, params)
    return result and result.affectedRows or 0
end

--- Update query async
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback with affectedRows
function Database.updateAsync(query, params, callback)
    params = params or {}

    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        local affectedRows = result and result.affectedRows or 0
        if callback then
            callback(affectedRows)
        end
    end)
end

--- Delete query sync (alias for update)
function Database.delete(query, params)
    return Database.update(query, params)
end

--- Delete query async (alias for update)
function Database.deleteAsync(query, params, callback)
    Database.updateAsync(query, params, callback)
end

--- Execute raw query sync
function Database.execute(query, params)
    return Database.query(query, params)
end

--- Execute raw query async
function Database.executeAsync(query, params, callback)
    Database.queryAsync(query, params, callback)
end
```

- [ ] **Step 2: Rename every `Database.querySync`/`Database.insertSync`/
      `Database.updateSync`/`Database.deleteSync`/`Database.executeSync`
      reference in `tests/orm_spec.lua` to the new sync name**

Run this from the repo root — it only touches the five renamed sync names,
leaving `Sync`-suffixed connector export calls (none exist in this test
file) untouched:

```bash
sed -i \
  -e 's/Database\.querySync/Database.query/g' \
  -e 's/Database\.insertSync/Database.insert/g' \
  -e 's/Database\.updateSync/Database.update/g' \
  -e 's/Database\.deleteSync/Database.delete/g' \
  -e 's/Database\.executeSync/Database.execute/g' \
  tests/orm_spec.lua
```

- [ ] **Step 3: Rename the same five names in `Schema.lua`**

```bash
sed -i \
  -e 's/Database\.querySync/Database.query/g' \
  core/server/ORM/Schema.lua
```

(Only `querySync` appears in `Schema.lua` per the earlier grep — the other
four don't occur there.)

- [ ] **Step 4: Rename the same five names in `QueryBuilder.lua`'s internal
      calls (not its own `getSync`/`firstSync` method names yet — those are
      Task 2)**

```bash
sed -i \
  -e 's/Database\.querySync/Database.query/g' \
  -e 's/Database\.insertSync/Database.insert/g' \
  -e 's/Database\.updateSync/Database.update/g' \
  core/server/ORM/QueryBuilder.lua
```

- [ ] **Step 5: Rename `Database.querySync`/`Database.insertSync`/
      `Database.updateSync`/`Database.deleteSync` in the six Services files**

```bash
sed -i 's/Database\.querySync/Database.query/g; s/Database\.updateSync/Database.update/g; s/Database\.insertSync/Database.insert/g; s/Database\.deleteSync/Database.delete/g' \
  core/server/Services/PolicyService.lua
```

- [ ] **Step 6: Run the ORM test suite, confirm all pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: all tests pass (no `attempt to call a nil value` for any renamed
`Database.*` method, no leftover `Sync`-suffixed call).

- [ ] **Step 7: Commit**

```bash
git add core/server/ORM/Database.lua core/server/ORM/Schema.lua core/server/ORM/QueryBuilder.lua core/server/Services/PolicyService.lua tests/orm_spec.lua
git commit -m "refactor(orm): rename Database sync/async methods (bare=sync, ...Async=callback)"
```

---

### Task 2: Rename `QueryBuilder.lua`'s `get`/`first`/`count`

**Files:**
- Modify: `core/server/ORM/QueryBuilder.lua:398-451`
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Database.query`, `Database.queryAsync` (Task 1).
- Produces: `QueryBuilder:get() -> table results` (sync),
  `QueryBuilder:getAsync(callback)`, `QueryBuilder:first() -> table|nil`
  (sync), `QueryBuilder:firstAsync(callback)`, `QueryBuilder:count() ->
  number` (sync), `QueryBuilder:countAsync(callback)`. `get()`/`getAsync()`
  are NOT yet model-aware — that's Task 6.

- [ ] **Step 1: Replace `QueryBuilder:get`/`:getSync`/`:first`/`:firstSync`/
      `:count`/`:countSync` (lines 398-451) with:**

```lua
--- Execute the query synchronously
--- @return table Results
function QueryBuilder:get()
    local sql, params = self:toSql()
    return Database.query(sql, params)
end

--- Execute the query and return results (async)
--- @param callback function
function QueryBuilder:getAsync(callback)
    local sql, params = self:toSql()
    Database.queryAsync(sql, params, callback)
end

--- Get first result synchronously
--- @return table|nil
function QueryBuilder:first()
    self:limit(1)
    local results = self:get()
    return results[1]
end

--- Get first result (async)
--- @param callback function
function QueryBuilder:firstAsync(callback)
    self:limit(1)
    self:getAsync(function(results)
        callback(results[1])
    end)
end

--- Count synchronously
--- @return number
function QueryBuilder:count()
    local originalRaw = self.rawSelect
    self:selectRaw('COUNT(*) as count')

    local result = self:first()
    self.rawSelect = originalRaw

    return tonumber(result and result.count) or 0
end

--- Count results (async)
--- @param callback function
function QueryBuilder:countAsync(callback)
    local originalRaw = self.rawSelect
    self:selectRaw('COUNT(*) as count')

    self:firstAsync(function(result)
        self.rawSelect = originalRaw
        callback(tonumber(result and result.count) or 0)
    end)
end
```

- [ ] **Step 2: Rename `getSync`/`firstSync`/`countSync` call sites
      elsewhere in `QueryBuilder.lua`** (the `paginate` method uses `:get`/
      `:count` already with callback style — verify it still reads
      `self:count(function(total) ... self:limit(perPage):offset(offset):get(function(data) ...`
      and rename those two calls to `:countAsync(...)`/`:getAsync(...)`
      since `paginate` is callback-based):

```bash
sed -i \
  -e '/function QueryBuilder:paginate/,/^end$/ s/self:count(function/self:countAsync(function/' \
  -e '/function QueryBuilder:paginate/,/^end$/ s/:get(function(data)/:getAsync(function(data)/' \
  core/server/ORM/QueryBuilder.lua
```

- [ ] **Step 3: Rename `getSync`/`firstSync` in `BaseModel.lua` and the two
      Services files that call them directly (mechanical rename only — no
      behavior change; `BaseModel.lua`'s own `findSync`/`allSync`/etc. names
      are renamed in Task 4, this step only touches its *internal calls* to
      `QueryBuilder:getSync`/`:firstSync`)**

```bash
sed -i \
  -e 's/:getSync(/:get(/g' \
  -e 's/:firstSync(/:first(/g' \
  core/server/ORM/BaseModel.lua \
  core/server/Services/ActionService.lua \
  core/server/Services/SchedulerService.lua \
  core/server/Services/InstanceService.lua \
  core/server/Services/EntityStreamerService.lua \
  core/server/Services/PermissionService.lua
```

- [ ] **Step 4: Rename the same two in `tests/orm_spec.lua`**

```bash
sed -i -e 's/:getSync(/:get(/g' -e 's/:firstSync(/:first(/g' tests/orm_spec.lua
```

- [ ] **Step 5: Update the `QUERY_PROXY_METHODS` doc comment in
      `BaseModel.lua`** (it references the old name in prose, line 71):

```lua
--- `Inventory:where('owner', id):get()` works without an explicit
```

- [ ] **Step 6: Run the test suite, confirm all pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add core/server/ORM/QueryBuilder.lua core/server/ORM/BaseModel.lua core/server/Services/ActionService.lua core/server/Services/SchedulerService.lua core/server/Services/InstanceService.lua core/server/Services/EntityStreamerService.lua core/server/Services/PermissionService.lua tests/orm_spec.lua
git commit -m "refactor(orm): rename QueryBuilder get/first/count (bare=sync, ...Async=callback)"
```

---

### Task 3: Split `QueryBuilder` `insert`/`update`/`delete` into sync + `...Async`

**Files:**
- Modify: `core/server/ORM/QueryBuilder.lua:453-527`
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `Database.insert`/`Database.insertAsync`,
  `Database.update`/`Database.updateAsync` (Task 1).
- Produces: `QueryBuilder:insert(data) -> number insertId` (always sync,
  no callback param), `QueryBuilder:insertAsync(data, callback)`,
  `QueryBuilder:update(data) -> number affectedRows` (always sync),
  `QueryBuilder:updateAsync(data, callback)`, `QueryBuilder:delete() ->
  number affectedRows` (always sync), `QueryBuilder:deleteAsync(callback)`.
  Breaking change: the old callback-presence branch is gone — every caller
  passing a callback to `insert`/`update`/`delete` must now call the
  `...Async` form explicitly.

- [ ] **Step 1: Write failing tests for the new sync/async split**

Add to `tests/orm_spec.lua` near the existing insert/update/delete tests
(search for `function QueryBuilder:insert` usage context, e.g. around line
760-800):

```lua
test('QueryBuilder.insert: sync form returns insertId with no callback', function()
    local original = Database.insert
    Database.insert = function(sql, values) return 42 end
    local id = QueryBuilder.new('widgets'):insert({name = 'a'})
    Database.insert = original
    eq(id, 42, 'insert: sync insertId')
end)

test('QueryBuilder.insertAsync: calls back with insertId', function()
    local original = Database.insertAsync
    local capturedCallback
    Database.insertAsync = function(sql, values, callback) capturedCallback = callback end
    local received
    QueryBuilder.new('widgets'):insertAsync({name = 'a'}, function(id) received = id end)
    capturedCallback(7)
    Database.insertAsync = original
    eq(received, 7, 'insertAsync: callback receives insertId')
end)

test('QueryBuilder.update: sync form returns affectedRows with no callback', function()
    local original = Database.update
    Database.update = function(sql, values) return 3 end
    local affected = QueryBuilder.new('widgets'):where('id', 1):update({name = 'b'})
    Database.update = original
    eq(affected, 3, 'update: sync affectedRows')
end)

test('QueryBuilder.updateAsync: calls back with affectedRows', function()
    local original = Database.updateAsync
    local capturedCallback
    Database.updateAsync = function(sql, values, callback) capturedCallback = callback end
    local received
    QueryBuilder.new('widgets'):where('id', 1):updateAsync({name = 'b'}, function(affected) received = affected end)
    capturedCallback(1)
    Database.updateAsync = original
    eq(received, 1, 'updateAsync: callback receives affectedRows')
end)

test('QueryBuilder.delete: sync form returns affectedRows with no callback', function()
    local original = Database.update
    Database.update = function(sql, values) return 1 end
    local affected = QueryBuilder.new('widgets'):where('id', 1):delete()
    Database.update = original
    eq(affected, 1, 'delete: sync affectedRows')
end)

test('QueryBuilder.deleteAsync: calls back with affectedRows', function()
    local original = Database.updateAsync
    local capturedCallback
    Database.updateAsync = function(sql, values, callback) capturedCallback = callback end
    local received
    QueryBuilder.new('widgets'):where('id', 1):deleteAsync(function(affected) received = affected end)
    capturedCallback(2)
    Database.updateAsync = original
    eq(received, 2, 'deleteAsync: callback receives affectedRows')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 tests/orm_spec.lua`
Expected: FAIL — `insertAsync`/`updateAsync`/`deleteAsync` are nil (don't
exist yet), and `insert`/`update`/`delete` still branch on callback
presence so the "no callback" sync-return assertions may already
coincidentally pass but the Async ones must fail.

- [ ] **Step 3: Replace `insert`/`update`/`delete` (lines 453-527) with**

```lua
--- Insert data (sync)
--- @param data table Key-value pairs
--- @return number insertId
function QueryBuilder:insert(data)
    local sql, values = self:buildInsertSql(data)
    return Database.insert(sql, values)
end

--- Insert data (async)
--- @param data table Key-value pairs
--- @param callback function Receives insertId
function QueryBuilder:insertAsync(data, callback)
    local sql, values = self:buildInsertSql(data)
    Database.insertAsync(sql, values, callback)
end

--- Build the INSERT SQL + values, shared by insert()/insertAsync()
--- @param data table
--- @return string sql, table values
function QueryBuilder:buildInsertSql(data)
    local columns = {}
    local placeholders = {}
    local values = {}

    for column, value in pairs(data) do
        table.insert(columns, QueryBuilder.quoteIdentifier(column))
        table.insert(placeholders, '?')
        table.insert(values, value)
    end

    local sql = 'INSERT INTO ' .. QueryBuilder.quoteIdentifier(self.tableName) ..
                ' (' .. table.concat(columns, ', ') .. ') VALUES (' ..
                table.concat(placeholders, ', ') .. ')' ..
                Database.dialect.insertReturningClause(self.primaryKey)

    return sql, values
end

--- Update data (sync)
--- @param data table Key-value pairs
--- @return number affectedRows
function QueryBuilder:update(data)
    local sql, values = self:buildUpdateSql(data)
    return Database.update(sql, values)
end

--- Update data (async)
--- @param data table Key-value pairs
--- @param callback function Receives affectedRows
function QueryBuilder:updateAsync(data, callback)
    local sql, values = self:buildUpdateSql(data)
    Database.updateAsync(sql, values, callback)
end

--- Build the UPDATE SQL + values, shared by update()/updateAsync()
--- @param data table
--- @return string sql, table values
function QueryBuilder:buildUpdateSql(data)
    local setClauses = {}
    local values = {}

    for column, value in pairs(data) do
        if value == Database.NULL then
            table.insert(setClauses, QueryBuilder.quoteIdentifier(column) .. ' = NULL')
        else
            table.insert(setClauses, QueryBuilder.quoteIdentifier(column) .. ' = ?')
            table.insert(values, value)
        end
    end

    local sql = 'UPDATE ' .. QueryBuilder.quoteIdentifier(self.tableName) .. ' SET ' .. table.concat(setClauses, ', ')

    local whereClause = self:buildWhereClause()
    if whereClause ~= '' then
        sql = sql .. ' ' .. whereClause
        for _, param in ipairs(self.params) do
            table.insert(values, param)
        end
    end

    return sql, values
end

--- Delete records (sync)
--- @return number affectedRows
function QueryBuilder:delete()
    local sql = self:buildDeleteSql()
    return Database.update(sql, self.params)
end

--- Delete records (async)
--- @param callback function
function QueryBuilder:deleteAsync(callback)
    local sql = self:buildDeleteSql()
    Database.updateAsync(sql, self.params, callback)
end

--- Build the DELETE SQL, shared by delete()/deleteAsync()
--- @return string sql
function QueryBuilder:buildDeleteSql()
    local sql = 'DELETE FROM ' .. QueryBuilder.quoteIdentifier(self.tableName)

    local whereClause = self:buildWhereClause()
    if whereClause ~= '' then
        sql = sql .. ' ' .. whereClause
    end

    return sql
end
```

- [ ] **Step 4: Rename `paginate`'s and any other in-file `insert`/`update`/
      `delete` calls that relied on the callback-branch form.** `paginate`
      doesn't call insert/update/delete, so no change needed there. Grep to
      confirm nothing else in `QueryBuilder.lua` calls its own `insert`/
      `update`/`delete` with a trailing callback:

```bash
grep -n ':insert(\|:update(\|:delete(' core/server/ORM/QueryBuilder.lua core/server/ORM/BaseModel.lua
```

Expect only the definitions themselves plus `BaseModel:save`/`saveAsync`
and `BaseModel:delete`/`deleteAsync` (renamed in Task 4) calling
`:insert(writeAttributes)`/`:update(writeAttributes)`/`:delete()` with no
trailing callback — if any call site still passes a callback as a 2nd/3rd
arg to `:insert`/`:update`/`:delete`, note it for Task 4's rewrite.

- [ ] **Step 5: Run tests to verify they now pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS, including the 6 new tests from Step 1.

- [ ] **Step 6: Commit**

```bash
git add core/server/ORM/QueryBuilder.lua tests/orm_spec.lua
git commit -m "feat(orm): split QueryBuilder insert/update/delete into sync + ...Async forms"
```

---

### Task 4: Rename `BaseModel.lua`'s `find`/`create`/`save`/`delete`/`load`, remove `all`/`allSync`

**Files:**
- Modify: `core/server/ORM/BaseModel.lua:86-256, 349-451`
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder:get/getAsync/first/firstAsync/insert/insertAsync/
  update/updateAsync/delete/deleteAsync` (Tasks 2-3).
- Produces: `BaseModel:find(id) -> BaseModel|nil` (sync),
  `BaseModel:findAsync(id, callback)`, `BaseModel:create(attributes) ->
  BaseModel` (sync), `BaseModel:createAsync(attributes, callback)`,
  `BaseModel:save() -> BaseModel` (sync, instance method),
  `BaseModel:saveAsync(callback)`, `BaseModel:delete() -> boolean` (sync),
  `BaseModel:deleteAsync(callback)`, `BaseModel:load(relationName) -> any`
  (sync), `BaseModel:loadAsync(relationName, callback)`. `all`/`allSync`
  removed entirely (no replacement in this task — `get()` becomes their
  replacement in Task 6).

- [ ] **Step 1: Replace lines 86-132 (`find` through `allSync`) with**

```lua
--- Find synchronously
--- @param id any
--- @return BaseModel|nil
function BaseModel:find(id)
    local result = self:newQuery():where(self.primaryKey, id):first()
    if result then
        return self:newFromQuery(result)
    end
    return nil
end

--- Find a model by primary key (async)
--- @param id any
--- @param callback function
function BaseModel:findAsync(id, callback)
    self:newQuery():where(self.primaryKey, id):firstAsync(function(result)
        if result then
            local instance = self:newFromQuery(result)
            callback(instance)
        else
            callback(nil)
        end
    end)
end
```

- [ ] **Step 2: Replace `create`/`createSync` (old lines 151-172) with**

```lua
--- Create synchronously
--- @param attributes table
--- @return BaseModel
function BaseModel:create(attributes)
    local instance = self.new(attributes)
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    instance:save()
    return instance
end

--- Create and save a new model (async)
--- @param attributes table
--- @param callback function
function BaseModel:createAsync(attributes, callback)
    local instance = self.new(attributes)
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    instance:saveAsync(callback)
end
```

- [ ] **Step 3: Replace `save`/`saveSync` (old lines 174-228) with**

```lua
--- Save synchronously
--- @return BaseModel
function BaseModel:save()
    if self.timestamps then
        if not self.exists then
            self.attributes.created_at = Database.now()
        end
        self.attributes.updated_at = Database.now()
    end

    local writeAttributes = self:encodeJsonCasts(self.attributes)

    if self.exists then
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(writeAttributes)
        self.original = self:copyTable(self.attributes)
    else
        local insertId = self:newQuery():insert(writeAttributes)
        self.attributes[self.primaryKey] = insertId
        self.exists = true
        self.original = self:copyTable(self.attributes)
    end

    return self
end

--- Save the model (async)
--- @param callback function
function BaseModel:saveAsync(callback)
    if self.timestamps then
        if not self.exists then
            self.attributes.created_at = Database.now()
        end
        self.attributes.updated_at = Database.now()
    end

    local writeAttributes = self:encodeJsonCasts(self.attributes)

    if self.exists then
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):updateAsync(writeAttributes, function(affected)
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    else
        self:newQuery():insertAsync(writeAttributes, function(insertId)
            self.attributes[self.primaryKey] = insertId
            self.exists = true
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    end
end
```

- [ ] **Step 4: Replace `delete`/`deleteSync` (old lines 230-256) with**

```lua
--- Delete synchronously
--- @return boolean
function BaseModel:delete()
    if not self.exists then
        return false
    end

    local pk = self.attributes[self.primaryKey]
    self:newQuery():where(self.primaryKey, pk):delete()
    self.exists = false
    return true
end

--- Delete the model (async)
--- @param callback function
function BaseModel:deleteAsync(callback)
    if not self.exists then
        if callback then callback(false) end
        return
    end

    local pk = self.attributes[self.primaryKey]
    self:newQuery():where(self.primaryKey, pk):deleteAsync(function(affected)
        self.exists = false
        if callback then callback(true) end
    end)
end
```

- [ ] **Step 5: Replace `load`/`loadSync` (old lines 349-451) — rename
      `load` → callback stays as `loadAsync`, `loadSync` → `load`, and
      rename their internal `QueryBuilder`/`BaseModel` calls to the new
      names**

```lua
--- Load relationship synchronously
--- @param relationName string
--- @return any
function BaseModel:load(relationName)
    if self.relations[relationName] then
        return self.relations[relationName]
    end

    local relation = self[relationName](self)

    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        local result = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):first()
        if result then
            self.relations[relationName] = relation.relatedModel:newFromQuery(result)
        end
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        local results = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):get()
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, relation.relatedModel:newFromQuery(result))
        end
        self.relations[relationName] = models
    elseif relation.type == 'belongsTo' then
        local foreignValue = self.attributes[relation.foreignKey]
        self.relations[relationName] = relation.relatedModel:find(foreignValue)
    elseif relation.type == 'belongsToMany' then
        local localId = self.attributes[self.primaryKey]
        local query = relation.relatedModel:newQuery()
            :join(relation.pivotTable,
                  relation.relatedModel.table .. '.' .. relation.relatedModel.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :where(relation.pivotTable .. '.' .. relation.foreignPivotKey, localId)

        local results = query:get()
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, relation.relatedModel:newFromQuery(result))
        end
        self.relations[relationName] = models
    end

    return self.relations[relationName]
end

--- Load a relationship (lazy loading, async)
--- @param relationName string
--- @param callback function
function BaseModel:loadAsync(relationName, callback)
    if self.relations[relationName] then
        callback(self.relations[relationName])
        return
    end

    local relation = self[relationName](self)

    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):firstAsync(function(result)
            if result then
                self.relations[relationName] = relation.relatedModel:newFromQuery(result)
            end
            callback(self.relations[relationName])
        end)
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):getAsync(function(results)
            local models = {}
            for _, result in ipairs(results) do
                table.insert(models, relation.relatedModel:newFromQuery(result))
            end
            self.relations[relationName] = models
            callback(models)
        end)
    elseif relation.type == 'belongsTo' then
        local foreignValue = self.attributes[relation.foreignKey]
        relation.relatedModel:findAsync(foreignValue, function(model)
            self.relations[relationName] = model
            callback(model)
        end)
    elseif relation.type == 'belongsToMany' then
        local localId = self.attributes[self.primaryKey]

        local query = relation.relatedModel:newQuery()
            :join(relation.pivotTable,
                  relation.relatedModel.table .. '.' .. relation.relatedModel.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :where(relation.pivotTable .. '.' .. relation.foreignPivotKey, localId)

        query:getAsync(function(results)
            local models = {}
            for _, result in ipairs(results) do
                table.insert(models, relation.relatedModel:newFromQuery(result))
            end
            self.relations[relationName] = models
            callback(models)
        end)
    end
end
```

- [ ] **Step 6: Rename `BaseModel.lua`'s remaining internal calls** —
      `attach`/`detach` use `QueryBuilder.new(...):insert(data, callback)`
      and `:delete(callback)` with a trailing callback (old dual-mode
      style). Update them to the new `...Async` forms since they're
      callback-taking:

```lua
-- in BaseModel:attach, replace:
--   QueryBuilder.new(relation.pivotTable):insert(data, callback)
-- with:
    QueryBuilder.new(relation.pivotTable):insertAsync(data, callback)
```

```lua
-- in BaseModel:detach, replace the trailing:
--   query:delete(callback)
-- with:
    query:deleteAsync(callback)
```

- [ ] **Step 7: Rename `findSync`/`createSync`/`saveSync`/`deleteSync`/
      `loadSync`/`allSync`/`all(` call sites in the Services files and
      `tests/orm_spec.lua`**

```bash
sed -i \
  -e 's/:findSync(/:find(/g' \
  -e 's/:createSync(/:create(/g' \
  -e 's/:saveSync(/:save(/g' \
  -e 's/:deleteSync(/:delete(/g' \
  -e 's/:loadSync(/:load(/g' \
  core/server/Services/*.lua tests/orm_spec.lua
```

Then grep for remaining `allSync`/`:all(` usage and handle manually (there
should be none in core per the earlier survey, but confirm):

```bash
grep -rn 'allSync\|:all(' core/server tests/orm_spec.lua
```

If any test exercises `allSync`/`all()`, delete that test — it's superseded
by Task 6's `get()` tests, not renamed 1:1.

- [ ] **Step 8: Run the test suite, confirm all pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS (some previously-passing `allSync`/`all()` tests may be
gone per Step 7 — that's expected, not a regression).

- [ ] **Step 9: Commit**

```bash
git add core/server/ORM/BaseModel.lua core/server/Services/*.lua tests/orm_spec.lua
git commit -m "refactor(orm): rename BaseModel find/create/save/delete/load, drop all/allSync"
```

---

### Task 5: Remove `BaseModel:get(key)`, add `.field` direct access

**Files:**
- Modify: `core/server/ORM/BaseModel.lua:17-62` (`new`, `extend`), remove
  old `get(key)`/`set(key, value)` block (now-shifted line numbers near the
  old 258-270, post-Task-4 edits)
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: `instance.someField` reads `instance.attributes.someField` (or
  `instance.relations.someField` as fallback, or a method) via a function
  `__index`. `BaseModel:get(key)` is removed. `BaseModel:set(key, value)`
  is unchanged (still the sole write path alongside
  `instance.attributes.field = value`).

- [ ] **Step 1: Write a failing test for `.field` access**

Add to `tests/orm_spec.lua` (near existing `BaseModel` extend/instance
tests, e.g. after the `findSync`/`saveSync` block, now renamed):

```lua
test('BaseModel instance: .field reads attributes directly', function()
    local Widget = BaseModel:extend('widgets')
    local widget = Widget.new({id = 1, name = 'gizmo'})
    eq(widget.name, 'gizmo', '.field should read attributes.field')
    eq(widget.attributes.name, 'gizmo', '.attributes.field should still work')
end)

test('BaseModel instance: .field falls through to relations then methods', function()
    local Widget = BaseModel:extend('widgets')
    function Widget:describe() return 'a widget' end
    local widget = Widget.new({id = 1})
    widget.relations.owner = {id = 9}
    eq(widget.owner.id, 9, '.field should fall through to relations')
    eq(widget:describe(), 'a widget', 'method calls should still resolve')
end)

test('BaseModel: get(key) attribute getter is removed', function()
    local Widget = BaseModel:extend('widgets')
    local widget = Widget.new({id = 1})
    -- get() is now the query-fetch method (class-level); calling it as an
    -- instance attribute getter with a key arg is no longer supported.
    truthy(widget.get == nil or type(widget.get) == 'function', 'get should not be an attribute getter')
end)
```

- [ ] **Step 2: Run tests to verify the `.field` tests fail**

Run: `lua5.4 tests/orm_spec.lua`
Expected: FAIL — `widget.name` is `nil` today (table-based `__index`
doesn't check `attributes`).

- [ ] **Step 3: In `BaseModel.lua`, change `BaseModel:extend`'s `child.__index
      = child` to a function `__index`**

Replace (near the top of `extend`, currently `child.__index = child`):

```lua
function BaseModel:extend(tableName)
    local child = {}
    child.__index = function(instance, key)
        local attrs = rawget(instance, 'attributes')
        if attrs and attrs[key] ~= nil then
            return attrs[key]
        end
        local rels = rawget(instance, 'relations')
        if rels and rels[key] ~= nil then
            return rels[key]
        end
        return child[key]
    end
    setmetatable(child, { __index = self })
    ...
```

(keep the rest of `extend` — `if tableName then ... end`, `child.new`,
`return child` — unchanged).

- [ ] **Step 4: Apply the same function `__index` to the root `BaseModel`
      itself** (line 3-4, `BaseModel.__index = BaseModel`), so a model used
      directly without `:extend()` also gets `.field` access:

```lua
BaseModel.__index = function(instance, key)
    local attrs = rawget(instance, 'attributes')
    if attrs and attrs[key] ~= nil then
        return attrs[key]
    end
    local rels = rawget(instance, 'relations')
    if rels and rels[key] ~= nil then
        return rels[key]
    end
    return BaseModel[key]
end
```

- [ ] **Step 5: Remove the old `BaseModel:get(key)` attribute-getter
      method** (search for `--- Get attribute value` / `function
      BaseModel:get(key)` and delete that 4-line function; leave
      `BaseModel:set(key, value)` in place).

- [ ] **Step 6: Rename any remaining `:get(someKey)` attribute-getter call
      sites** — grep to confirm none exist outside tests already rewritten
      in Step 1:

```bash
grep -n '\.attributes\[' core/server/ORM/BaseModel.lua
grep -rn ':get(' core/server/Services/*.lua
```

Any hit outside `BaseModel.lua` itself and the query-fetch usages already
renamed in Tasks 2/4 means a caller was using the old attribute-getter form
— replace `instance:get('field')` with `instance.field` at that call site.

- [ ] **Step 7: Run tests to verify they pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add core/server/ORM/BaseModel.lua tests/orm_spec.lua
git commit -m "feat(orm): add .field direct access to model instances, remove get(key) attribute getter"
```

---

### Task 6: Model-aware `get()`/`getAsync()`, remove `all`/`allSync` gap

**Files:**
- Modify: `core/server/ORM/BaseModel.lua` (`newQuery`)
- Modify: `core/server/ORM/QueryBuilder.lua` (`get`, `getAsync`)
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `.field` access (Task 5), `newFromQuery` (existing), `decodeJsonCasts` (existing).
- Produces: `QueryBuilder.model` (optional back-ref field, nil for bare
  `QueryBuilder.new(...)`), `QueryBuilder:get()`/`:getAsync(callback)` now
  decode+wrap into model instances when `self.model` is set, otherwise
  return raw rows exactly as before.

- [ ] **Step 1: Write a failing test for model-aware `get()`**

Add to `tests/orm_spec.lua`:

```lua
test('BaseModel: get() (no filter) decodes JSON casts and returns model instances', function()
    local Category = BaseModel:extend('categories')
    Category.casts = {fields = 'json'}

    local original = Database.query
    Database.query = function(sql, params)
        return {{id = 1, fields = '{"color":"red"}'}}
    end

    local results = Category:get()
    Database.query = original

    eq(#results, 1, 'get(): one row')
    truthy(type(results[1].fields) == 'table', 'get(): json cast decoded')
    eq(results[1].fields.color, 'red', 'get(): decoded value correct')
    eq(results[1].id, 1, 'get(): .field access on wrapped instance')
end)

test('BaseModel: where(...):get() (filtered) also decodes and wraps', function()
    local Category = BaseModel:extend('categories')
    Category.casts = {fields = 'json'}

    local original = Database.query
    Database.query = function(sql, params)
        return {{id = 2, fields = '{"color":"blue"}'}}
    end

    local results = Category:where('id', 2):get()
    Database.query = original

    eq(results[1].fields.color, 'blue', 'where():get(): decoded value correct')
end)

test('QueryBuilder.get(): bare QueryBuilder (no model) returns raw rows', function()
    local original = Database.query
    Database.query = function(sql, params) return {{id = 1, fields = '{"a":1}'}} end
    local results = QueryBuilder.new('categories'):get()
    Database.query = original

    eq(type(results[1].fields), 'string', 'bare QueryBuilder: no decoding, still a string')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 tests/orm_spec.lua`
Expected: FAIL — `get()` currently returns raw rows regardless of model.

- [ ] **Step 3: In `BaseModel.lua`, update `newQuery` to attach `.model`**

```lua
function BaseModel:newQuery()
    local query = QueryBuilder.new(self.table, self.primaryKey)
    query.model = self
    return query
end
```

- [ ] **Step 4: In `QueryBuilder.lua`, make `get()`/`getAsync()`
      model-aware**

```lua
--- Execute the query synchronously
--- @return table Results (raw rows, or model instances if opened via a BaseModel)
function QueryBuilder:get()
    local sql, params = self:toSql()
    local results = Database.query(sql, params)
    if not self.model then
        return results
    end
    local models = {}
    for _, result in ipairs(results) do
        table.insert(models, self.model:newFromQuery(result))
    end
    return models
end

--- Execute the query and return results (async)
--- @param callback function
function QueryBuilder:getAsync(callback)
    local sql, params = self:toSql()
    Database.queryAsync(sql, params, function(results)
        if not self.model then
            callback(results)
            return
        end
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, self.model:newFromQuery(result))
        end
        callback(models)
    end)
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/server/ORM/BaseModel.lua core/server/ORM/QueryBuilder.lua tests/orm_spec.lua
git commit -m "feat(orm): make QueryBuilder.get()/getAsync() model-aware via .model back-ref"
```

---

### Task 7: `:with('a.b.c')` nested eager loading

**Files:**
- Modify: `core/server/ORM/BaseModel.lua` (add `with`/`withAsync`, add
  `withPaths` tracking to `newQuery`/query chain, add post-fetch loading
  helper)
- Test: `tests/orm_spec.lua`

**Interfaces:**
- Consumes: `.model` back-ref (Task 6), relation definitions (`hasOne`/
  `hasMany`/`belongsTo`/`belongsToMany`, existing), `.relations[name]`
  storage + `.field` fallback (Task 5).
- Produces: `Model:with(path) -> QueryBuilder` (chainable, records the
  path), `Model:withAsync(path)` (same, for use before `getAsync`/
  `findAsync`; actual eager-load happens after the terminal fetch
  resolves). `path` is a single relation name (`'customer'`) or dot-path
  (`'customer.address'`). Multiple `with()` calls accumulate multiple
  independent paths.

- [ ] **Step 1: Write failing tests for single-level and nested eager
      loading**

Add to `tests/orm_spec.lua`. This test builds two related models (`Order`
`belongsTo` `Customer`, `Customer` `hasOne` `Address`) and stubs
`Database.query` to return canned rows per table, then asserts `with()`
batches correctly and populates `.field` access at each level:

```lua
test('BaseModel.with: single-level eager load batches into one query per relation', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Order:customer() return self:belongsTo(Customer, 'customer_id') end

    local queries = {}
    local original = Database.query
    Database.query = function(sql, params)
        table.insert(queries, sql)
        if sql:find('FROM `orders`') then
            return {{id = 1, customer_id = 10}, {id = 2, customer_id = 11}}
        elseif sql:find('FROM `customers`') then
            eqList(params, {10, 11}, 'with: customer_id IN batch')
            return {{id = 10, name = 'Alice'}, {id = 11, name = 'Bob'}}
        end
        return {}
    end

    local orders = Order:with('customer'):get()
    Database.query = original

    eq(#orders, 2, 'with: base rows returned')
    eq(orders[1].customer.name, 'Alice', 'with: relation attached and .field-readable')
    eq(orders[2].customer.name, 'Bob', 'with: relation attached and .field-readable')
end)

test('BaseModel.with: nested dot-path batches one query per segment', function()
    local Address = BaseModel:extend('addresses')
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Order:customer() return self:belongsTo(Customer, 'customer_id') end
    function Customer:address() return self:hasOne(Address, 'customer_id') end

    local queryCount = 0
    local original = Database.query
    Database.query = function(sql, params)
        queryCount = queryCount + 1
        if sql:find('FROM `orders`') then
            return {{id = 1, customer_id = 10}}
        elseif sql:find('FROM `customers`') then
            return {{id = 10, name = 'Alice'}}
        elseif sql:find('FROM `addresses`') then
            return {{id = 100, customer_id = 10, city = 'Metropolis'}}
        end
        return {}
    end

    local orders = Order:with('customer.address'):get()
    Database.query = original

    eq(queryCount, 3, 'with nested: exactly 3 queries (base + 2 segments)')
    eq(orders[1].customer.address.city, 'Metropolis', 'with nested: deep .field access resolves')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 tests/orm_spec.lua`
Expected: FAIL — `with` doesn't exist on `BaseModel`.

- [ ] **Step 3: Add `withPaths` tracking to `QueryBuilder`** — in
      `QueryBuilder.new`, add `self.withPaths = {}` alongside the other
      state fields.

- [ ] **Step 4: Add `BaseModel:with`/`:withAsync` as `QUERY_PROXY_METHODS`
      style chain starters, plus the post-fetch loader**

Add to `BaseModel.lua`, near `QUERY_PROXY_METHODS`:

```lua
--- Record a relation path (single-level or dot-separated) to eager-load
--- after the terminal fetch resolves.
--- @param path string
--- @return QueryBuilder
function BaseModel:with(path)
    local query = self:newQuery()
    table.insert(query.withPaths, path)
    return query
end
```

`with()` needs to be chainable to further `where()`/`get()` calls, and
`where()`/`get()` opened directly on a model also need to carry
`withPaths` if `with()` was called first in the chain. Since
`QUERY_PROXY_METHODS` always opens a *fresh* query per call today (`self:newQuery()`
each time), chaining `Model:with('customer'):where(...):get()` already works
naturally because `:with()` returns the same `query` object that `:where()`
then mutates in place (QueryBuilder methods return `self`). Add eager-load
resolution to `QueryBuilder:get()`/`:getAsync()` themselves (Task 6's
model-aware branch), extending it:

```lua
--- Execute the query synchronously
--- @return table Results (raw rows, or model instances if opened via a BaseModel)
function QueryBuilder:get()
    local sql, params = self:toSql()
    local results = Database.query(sql, params)
    if not self.model then
        return results
    end
    local models = {}
    for _, result in ipairs(results) do
        table.insert(models, self.model:newFromQuery(result))
    end
    if #self.withPaths > 0 then
        for _, path in ipairs(self.withPaths) do
            self.model:eagerLoad(models, path)
        end
    end
    return models
end
```

(apply the same `#self.withPaths > 0` block inside `getAsync`'s callback,
right before `callback(models)`, calling `self.model:eagerLoad(models,
path)` synchronously there too — eager-loading itself stays sync-only in
this pass, matching the spec's scope; only the *base* fetch has an async
form.)

- [ ] **Step 5: Implement `BaseModel:eagerLoad(instances, path)`** — the
      segment-by-segment batch loader:

```lua
--- Eager-load a (possibly dot-separated) relation path across a batch of
--- already-fetched model instances, one batched query per path segment.
--- @param instances table Array of model instances sharing this model's relations
--- @param path string e.g. 'customer' or 'customer.address'
function BaseModel:eagerLoad(instances, path)
    local segment, rest = path:match('^([^.]+)%.?(.*)$')
    if #instances == 0 then
        return
    end

    local relation = instances[1][segment](instances[1])
    local related = relation.relatedModel

    if relation.type == 'hasOne' or relation.type == 'hasMany' then
        local localValues = {}
        for _, inst in ipairs(instances) do
            table.insert(localValues, inst.attributes[relation.localKey])
        end
        local rows = related:newQuery():whereIn(relation.foreignKey, localValues):get()
        local byForeign = {}
        for _, row in ipairs(rows) do
            local fk = row.attributes[relation.foreignKey]
            byForeign[fk] = byForeign[fk] or {}
            table.insert(byForeign[fk], row)
        end
        for _, inst in ipairs(instances) do
            local matches = byForeign[inst.attributes[relation.localKey]] or {}
            inst.relations[segment] = (relation.type == 'hasOne') and matches[1] or matches
        end
    elseif relation.type == 'belongsTo' then
        local foreignValues = {}
        for _, inst in ipairs(instances) do
            table.insert(foreignValues, inst.attributes[relation.foreignKey])
        end
        local rows = related:newQuery():whereIn(relation.ownerKey, foreignValues):get()
        local byOwner = {}
        for _, row in ipairs(rows) do
            byOwner[row.attributes[relation.ownerKey]] = row
        end
        for _, inst in ipairs(instances) do
            inst.relations[segment] = byOwner[inst.attributes[relation.foreignKey]]
        end
    elseif relation.type == 'belongsToMany' then
        local localIds = {}
        for _, inst in ipairs(instances) do
            table.insert(localIds, inst.attributes[inst.primaryKey])
        end
        local rows = related:newQuery()
            :join(relation.pivotTable,
                  related.table .. '.' .. related.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :whereIn(relation.pivotTable .. '.' .. relation.foreignPivotKey, localIds)
            :get()
        -- Grouping by owning instance requires the pivot's foreign key in the
        -- selected columns; select it explicitly alongside the related row.
        for _, inst in ipairs(instances) do
            inst.relations[segment] = inst.relations[segment] or {}
        end
        for _, row in ipairs(rows) do
            for _, inst in ipairs(instances) do
                table.insert(inst.relations[segment], row)
            end
        end
    end

    if rest ~= '' then
        local nextLevelInstances = {}
        local seenIds = {}
        for _, inst in ipairs(instances) do
            local rel = inst.relations[segment]
            local relList = (relation.type == 'hasMany' or relation.type == 'belongsToMany') and rel or {rel}
            for _, relInst in ipairs(relList) do
                if relInst then
                    local id = relInst.attributes[relInst.primaryKey]
                    if not seenIds[id] then
                        seenIds[id] = true
                        table.insert(nextLevelInstances, relInst)
                    end
                end
            end
        end
        related:eagerLoad(nextLevelInstances, rest)
    end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: PASS, including the two new `with` tests from Step 1.

- [ ] **Step 7: Commit**

```bash
git add core/server/ORM/BaseModel.lua core/server/ORM/QueryBuilder.lua tests/orm_spec.lua
git commit -m "feat(orm): add with('a.b.c') nested eager loading"
```

---

### Task 8: Full-suite regression pass + doc comment sweep

**Files:**
- Modify: `core/server/ORM/*.lua` (doc comments only, no logic changes)
- Test: `tests/orm_spec.lua`

**Interfaces:** none new — this task only cleans up stale references.

- [ ] **Step 1: Grep every ORM file and Services file for stale `Sync`
      references in comments/docstrings** (logic was already renamed in
      Tasks 1-7; this catches prose that still says `getSync`/`findSync`/
      etc.):

```bash
grep -rn 'Sync\b' core/server/ORM/*.lua core/server/Services/*.lua
```

Expected remaining hits: only the external connector export names in
`Database.lua` (`exports.oxmysql:executeSync`, `exports.oblsk_connector:
executeSync`, `exports.ghmattimysql:executeSync`, `connector.transactionSync`)
and the `-- Any connector that exports transactionSync...` comment
explaining them — those are intentionally untouched per the spec's
non-goals. Every other hit is a stale doc comment; fix the wording (no
code change) to reference the new bare/`...Async` names.

- [ ] **Step 2: Run the full project test command**

Run: `npm test` (from repo root — runs `orm_spec.lua` plus every other
`*_spec.lua` and the web test suite; confirms this rename didn't break
`ActionService`/`SchedulerService`/etc. tests elsewhere in the suite, if
any reference the ORM directly)
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add core/server/ORM/*.lua core/server/Services/*.lua
git commit -m "docs(orm): update stale Sync references in comments after rename"
```

---

### Task 9: Cross-repo survey grep (prep for the separate rollout effort)

**Files:** none modified — read-only survey, output informs the follow-on
rollout (out of scope for this plan per Global Constraints).

**Interfaces:** none.

- [ ] **Step 1: Confirm zero remaining old-name call sites in core**

```bash
grep -rn 'getSync\|firstSync\|findSync\|allSync\|createSync\|saveSync\|deleteSync\|loadSync\|countSync\|Database\.querySync\|Database\.insertSync\|Database\.updateSync\|Database\.deleteSync\|Database\.executeSync' \
  core/ tests/orm_spec.lua
```

Expected: no output (zero matches) — anything found here is a missed call
site from Tasks 1-7 and must be fixed before this task is considered done.

- [ ] **Step 2: Produce the survey list the rollout effort needs** — grep
      every module/plugin repo path under `modules/` and `plugins/` for the
      same old-name patterns, to hand off as the "Survey" step input from
      the spec's Rollout section:

```bash
grep -rln 'getSync\|firstSync\|findSync\|allSync\|createSync\|saveSync\|deleteSync\|loadSync\|countSync\|querySync\|insertSync\|updateSync\|deleteSync\|executeSync\|\.get(key)\|:get(''' \
  modules/ plugins/ 2>/dev/null
```

Save this file list — it's the input to the separate multi-agent rollout
workflow described in the spec (not executed by this plan).

- [ ] **Step 3: No commit** — this task is read-only verification; if Step
      1 finds a leftover call site, fix it, re-run `lua5.4
      tests/orm_spec.lua`, and commit that fix under the appropriate
      earlier task's message pattern (e.g. `fix(orm): rename missed
      getSync call site in <file>`).

---

## Self-Review Notes

- **Spec coverage:** Naming convention table (Tasks 1-4), attribute access
  (Task 5), model-aware `get()` (Task 6), nested `with()` (Task 7), rollout
  prep (Task 9) all have tasks. `insert`/`update`/`delete` callback-branch
  removal is Task 3. External connector exclusion and `Schema.lua` scope
  are called out in Global Constraints and touched only mechanically
  (Task 1 Step 3).
- **Type consistency:** `QueryBuilder.model` (Task 6) is read by
  `eagerLoad`'s `related:newQuery()` calls, which re-attach `.model` per
  Task 6's Step 3 change — every model-opened query in the eager-load path
  stays model-aware automatically.
- **Placeholder scan:** no TBD/TODO; every step has literal code or an
  exact runnable command.
