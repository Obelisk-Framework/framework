# Item Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `oblsk_items` module (`BaseItem`/`Item` catalog-and-instance pattern, polymorphic ownership, the `step`/`step_key` depletion mechanic, and a use pipeline built entirely on the existing `ActionService`), and the two core fixes it depends on: `ActionService.register` becoming DB-backed, and `BaseModel`'s `casts = {x = 'json'}` actually working.

**Architecture:** See `docs/superpowers/specs/2026-08-10-item-module-design.md` for full rationale. Tasks run in dependency order: core ORM/service fixes first (everything else needs them), then the module's schema, then its models, then the use-pipeline actions that tie it together.

**Tech Stack:** Lua (FXServer resource scripts), the existing ORM (`BaseModel`/`QueryBuilder`/`Schema`), `lua5.4` for the pure-logic unit tests.

## Global Constraints

- `oblsk_items` is a **separate git repository** (`core/modules/oblsk_items/`, remote `git@github.com:Obelisk-Framework/oblsk_items.git`, currently empty, no commits), not part of `core`'s repo. Tasks 1-3 (the core fixes) commit to `core`'s repo; Tasks 4-6 (the module itself) commit to `oblsk_items`'s own repo. These need two independent worktrees/branches when executing, not one.
- No FXServer runtime exists in this repo's test environment. Anything touching real natives, real migrations run against a live database, or FXServer-only globals gets manual verification only (syntax checks, `npm test` regression guard), matching the existing convention. Pure Lua logic (weight formulas, JSON cast encode/decode, stack-eligibility comparison, the `ActionService` upsert logic) gets real unit tests.
- `tests/support/fivem_stubs.lua`'s `json` stub is currently a placeholder (`encode` returns a literal `'{...}'` string for any table, `decode` always returns `{}` regardless of input) and has never been exercised for real round-tripping. Task 1 upgrades it to a small but real encode/decode pair, since this plan is the first thing that actually needs correct JSON semantics to test anything meaningfully. Verify no existing test in `tests/orm_spec.lua` currently depends on the placeholder's specific (incorrect) behavior before changing it (a plain repo-wide `grep -n "json\." tests/orm_spec.lua` early in Task 1 confirms this).
- Every event name (if any get added later, none are needed for this plan) still follows `<plugin>:<server|client>:<action>`; not relevant to this plan's actual scope, noted only for consistency.
- No Claude co-authorship in any commit (repo convention, applies in both repos).
- Minimize em/en dashes in prose (project owner's stated preference); this constraint is about commit messages and any docs prose touched, not code/SQL.

---

## Task 1: `BaseModel` JSON casts actually work

**Files:**
- Modify: `core/server/ORM/BaseModel.lua`
- Modify: `tests/support/fivem_stubs.lua`
- Modify: `tests/orm_spec.lua`

**Interfaces:**
- Produces: `BaseModel:encodeJsonCasts(attributes)` (returns a copy with `casts[key] == 'json'` table values JSON-encoded, used internally by `save`/`saveSync`), `BaseModel:decodeJsonCasts(attributes)` (mutates and returns `attributes` with `casts[key] == 'json'` string values JSON-decoded, used internally by `newFromQuery`). Every later task that reads/writes a JSON-cast attribute (`BaseItem.data`, `BaseItem.actions`, `Item.data` in Task 5) relies on this working.

- [ ] **Step 1: Confirm no existing test depends on the placeholder json stub's specific behavior**

Run: `grep -n "json\." tests/orm_spec.lua`
Expected: no matches, or only matches unrelated to relying on `encode`/`decode`'s exact (currently incorrect) output. If any match does rely on the placeholder behavior, read it and adjust this task's stub replacement to preserve that specific case.

- [ ] **Step 2: Write the failing tests**

Add to `tests/orm_spec.lua`, after the existing `'BaseModel query proxy: works on an extend()-based subclass too'` test:

```lua
--------------------------------------------------------------------------------
-- BaseModel JSON casts
--------------------------------------------------------------------------------
test('BaseModel casts: json cast field decodes from a JSON string on find', function()
    local original = Database.executeQuery
    Database.executeQuery = function(query, params)
        return {{ id = 1, name = 'Test', meta = '{"a":1}' }}
    end

    local Widget = setmetatable({}, {__index = BaseModel})
    Widget.table = 'widgets'
    Widget.primaryKey = 'id'
    Widget.timestamps = false
    Widget.casts = { meta = 'json' }

    local widget = Widget:findSync(1)
    Database.executeQuery = original

    truthy(type(widget.attributes.meta) == 'table', 'meta decoded into a table')
    eq(widget.attributes.meta.a, 1)
end)

test('BaseModel casts: json cast field is JSON-encoded for the write, stays a table in memory', function()
    withCapture(function(get)
        local Widget = setmetatable({}, {__index = BaseModel})
        Widget.table = 'widgets'
        Widget.primaryKey = 'id'
        Widget.timestamps = false
        Widget.casts = { meta = 'json' }

        local widget = Widget.new({ meta = { a = 1 } })
        widget:saveSync()

        truthy(type(widget.attributes.meta) == 'table', 'in-memory meta stays a table after save')

        local metaParam
        for _, p in ipairs(get().params) do
            if type(p) == 'string' and p:find('"a"', 1, true) then
                metaParam = p
            end
        end
        truthy(metaParam ~= nil, 'meta was JSON-encoded in the write params')
    end)
end)

test('BaseModel casts: malformed json cast field decodes to an empty table, no error', function()
    local original = Database.executeQuery
    Database.executeQuery = function() return {{ id = 1, meta = 'not-json{' }} end

    local Widget = setmetatable({}, {__index = BaseModel})
    Widget.table = 'widgets'
    Widget.primaryKey = 'id'
    Widget.timestamps = false
    Widget.casts = { meta = 'json' }

    local widget = Widget:findSync(1)
    Database.executeQuery = original

    eqList(widget.attributes.meta, {})
end)
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `lua5.4 tests/orm_spec.lua`
Expected: the three new tests fail (`BaseModel` has no `casts` handling yet: the first test's `meta` stays the literal string `'{"a":1}'`, `.a` on a string errors; the second test's params never contain an encoded string since nothing encodes it; the third fails identically to the first).

- [ ] **Step 4: Upgrade the `json` stub to real (if minimal) encode/decode**

In `tests/support/fivem_stubs.lua`, replace the existing placeholder block:

```lua
if not _G.json then
    _G.json = {
        encode = function(v)
            local t = type(v)
            if t == 'string' then return '"' .. v .. '"' end
            if t == 'table' then
                return next(v) == nil and '{}' or '{...}'
            end
            return tostring(v)
        end,
        decode = function() return {} end,
    }
end
```

with:

```lua
--- Minimal but real JSON encode/decode. Good enough for flat/simple-nested
--- fixtures in the test suite; not a general-purpose JSON library (no
--- unicode escapes, no scientific notation). Only exists here because the
--- real FXServer `json` global isn't available under a vanilla Lua
--- interpreter, and BaseModel's JSON casts (see BaseModel.lua) need
--- something that actually round-trips to be testable at all.
if not _G.json then
    local function encodeValue(v)
        local t = type(v)
        if v == nil then
            return 'null'
        elseif t == 'boolean' then
            return v and 'true' or 'false'
        elseif t == 'number' then
            return tostring(v)
        elseif t == 'string' then
            return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
        elseif t == 'table' then
            local n = 0
            local isArray = true
            for k in pairs(v) do
                n = n + 1
                if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then
                    isArray = false
                end
            end
            if n == 0 then
                return '{}'
            elseif isArray then
                local parts = {}
                for i = 1, n do
                    parts[i] = encodeValue(v[i])
                end
                return '[' .. table.concat(parts, ',') .. ']'
            else
                local parts = {}
                for k, val in pairs(v) do
                    table.insert(parts, '"' .. tostring(k) .. '":' .. encodeValue(val))
                end
                return '{' .. table.concat(parts, ',') .. '}'
            end
        end
        return 'null'
    end

    local decodeValue

    local function skipSpace(s, i)
        while i <= #s and s:sub(i, i):match('%s') do
            i = i + 1
        end
        return i
    end

    decodeValue = function(s, i)
        i = skipSpace(s, i)
        local c = s:sub(i, i)
        if c == '{' then
            local obj = {}
            i = skipSpace(s, i + 1)
            if s:sub(i, i) == '}' then
                return obj, i + 1
            end
            while true do
                local key, ni = decodeValue(s, i)
                i = skipSpace(s, ni)
                i = i + 1 -- skip ':'
                local val, ni2 = decodeValue(s, i)
                obj[key] = val
                i = skipSpace(s, ni2)
                if s:sub(i, i) == ',' then
                    i = skipSpace(s, i + 1)
                else
                    break
                end
            end
            return obj, i + 1
        elseif c == '[' then
            local arr = {}
            i = skipSpace(s, i + 1)
            if s:sub(i, i) == ']' then
                return arr, i + 1
            end
            while true do
                local val, ni = decodeValue(s, i)
                table.insert(arr, val)
                i = skipSpace(s, ni)
                if s:sub(i, i) == ',' then
                    i = skipSpace(s, i + 1)
                else
                    break
                end
            end
            return arr, i + 1
        elseif c == '"' then
            i = i + 1
            local buf = {}
            while s:sub(i, i) ~= '"' do
                if s:sub(i, i) == '\\' then
                    table.insert(buf, s:sub(i + 1, i + 1))
                    i = i + 2
                else
                    table.insert(buf, s:sub(i, i))
                    i = i + 1
                end
            end
            return table.concat(buf), i + 1
        elseif c == 't' then
            return true, i + 4
        elseif c == 'f' then
            return false, i + 5
        elseif c == 'n' then
            return nil, i + 4
        else
            local numStr = s:match('^%-?%d+%.?%d*', i)
            if not numStr then
                error('json.decode: unexpected character at position ' .. i)
            end
            return tonumber(numStr), i + #numStr
        end
    end

    _G.json = {
        encode = encodeValue,
        decode = function(s)
            if type(s) ~= 'string' or s == '' then
                error('json.decode: invalid input')
            end
            local value = decodeValue(s, 1)
            return value
        end,
    }
end
```

- [ ] **Step 5: Add `encodeJsonCasts`/`decodeJsonCasts` to `BaseModel.lua`, wire them into `newFromQuery`/`save`/`saveSync`**

In `core/server/ORM/BaseModel.lua`, add after `copyTable` (the last function before `return BaseModel`):

```lua
--- Encode any `casts[key] == 'json'` table attributes to JSON strings for
--- writing to the database. Returns a copy; never mutates `attributes`.
--- @param attributes table
--- @return table
function BaseModel:encodeJsonCasts(attributes)
    local encoded = self:copyTable(attributes)
    for key, castType in pairs(self.casts or {}) do
        if castType == 'json' and type(encoded[key]) == 'table' then
            encoded[key] = json.encode(encoded[key])
        end
    end
    return encoded
end

--- Decode any `casts[key] == 'json'` string attributes into tables after
--- reading from the database. Mutates and returns `attributes`. A malformed
--- JSON string decodes to an empty table rather than erroring, matching how
--- the rest of the codebase tolerates unparseable JSON (see
--- core/server/bootstrap.lua's migration runner).
--- @param attributes table
--- @return table
function BaseModel:decodeJsonCasts(attributes)
    for key, castType in pairs(self.casts or {}) do
        if castType == 'json' and type(attributes[key]) == 'string' then
            local ok, decoded = pcall(json.decode, attributes[key])
            attributes[key] = (ok and decoded) or {}
        end
    end
    return attributes
end
```

Change:

```lua
function BaseModel:newFromQuery(attributes)
    local instance = self.new(attributes)
```

to:

```lua
function BaseModel:newFromQuery(attributes)
    attributes = self:decodeJsonCasts(attributes)
    local instance = self.new(attributes)
```

Change (in `BaseModel:save`):

```lua
    if self.exists then
        -- Update existing
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(self.attributes, function(affected)
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    else
        -- Insert new
        self:newQuery():insert(self.attributes, function(insertId)
            self.attributes[self.primaryKey] = insertId
            self.exists = true
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    end
```

to:

```lua
    local writeAttributes = self:encodeJsonCasts(self.attributes)

    if self.exists then
        -- Update existing
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(writeAttributes, function(affected)
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    else
        -- Insert new
        self:newQuery():insert(writeAttributes, function(insertId)
            self.attributes[self.primaryKey] = insertId
            self.exists = true
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    end
```

Change (in `BaseModel:saveSync`, the same shape, synchronous):

```lua
    if self.exists then
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(self.attributes)
        self.original = self:copyTable(self.attributes)
    else
        local insertId = self:newQuery():insert(self.attributes)
        self.attributes[self.primaryKey] = insertId
        self.exists = true
        self.original = self:copyTable(self.attributes)
    end
```

to:

```lua
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
```

- [ ] **Step 6: Run the tests to confirm they pass**

Run: `lua5.4 tests/orm_spec.lua`
Expected: all tests pass, including the three new ones (total count = previous count + 3).

- [ ] **Step 7: Commit**

```bash
git add core/server/ORM/BaseModel.lua tests/support/fivem_stubs.lua tests/orm_spec.lua
git commit -m "fix(orm): make BaseModel casts = {x = 'json'} actually encode/decode"
```

---

## Task 2: `ActionService` becomes DB-backed

**Files:**
- Modify: `core/server/Services/ActionService.lua`
- Create: `tests/action_service_spec.lua`
- Modify: `package.json`
- Modify: `tests/README.md`

**Interfaces:**
- Produces: `ActionService.getDbId(actionId)` (returns the integer `actions.id` for a registered string actionId, or `nil`), `ActionService.resolveDbId(dbId)` (reverse lookup, integer to string, or `nil`). Task 3 (`KeybindService`) and Task 6 (`ItemService.use`) both call these.

- [ ] **Step 1: Write the failing test file**

Create `tests/action_service_spec.lua`:

```lua
--- Unit tests for ActionService.register's DB-backed upsert behavior.
--- Run from the repository root:  lua5.4 tests/action_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/Services/ActionService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

--- Fakes the `actions` table as an in-memory list, so ActionService.register's
--- upsert logic (SELECT-then-INSERT-or-UPDATE) can be tested without a real
--- database. Resets between tests.
local function withFakeActionsTable(fn)
    local rows = {}
    local nextId = 1
    local inserts, updates = 0, 0

    local original = Database.executeQuery
    Database.executeQuery = function(query, params)
        if query:find('SELECT', 1, true) and query:find('FROM `actions`', 1, true) then
            for _, row in ipairs(rows) do
                if row.action_id == params[1] then
                    return {row}
                end
            end
            return {}
        elseif query:find('INSERT INTO', 1, true) then
            local row = {id = nextId, action_id = params[1], label = params[2], description = params[3], options = params[4]}
            table.insert(rows, row)
            nextId = nextId + 1
            inserts = inserts + 1
            return {insertId = row.id}
        elseif query:find('UPDATE', 1, true) then
            updates = updates + 1
            return {affectedRows = 1}
        end
        return {}
    end

    local ok, err = pcall(fn, function() return {rows = rows, inserts = inserts, updates = updates} end)
    Database.executeQuery = original
    if not ok then error(err, 2) end
end

test('register: a brand-new actionId inserts exactly one row', function()
    withFakeActionsTable(function(get)
        ActionService.register('test:foo', function() end, {label = 'Foo'})
        local state = get()
        eq(#state.rows, 1)
        eq(state.rows[1].action_id, 'test:foo')
    end)
end)

test('register: registering the same actionId twice never inserts a second row', function()
    withFakeActionsTable(function(get)
        ActionService.register('test:foo', function() end, {label = 'Foo'})
        ActionService.register('test:foo', function() end, {label = 'Foo v2'})
        local state = get()
        eq(#state.rows, 1)
    end)
end)

test('getDbId: returns the integer id for a registered actionId', function()
    withFakeActionsTable(function()
        ActionService.register('test:bar', function() end, {})
        truthy(type(ActionService.getDbId('test:bar')) == 'number', 'getDbId returns a number')
    end)
end)

test('getDbId: returns nil for an actionId that was never registered', function()
    eq(ActionService.getDbId('test:never-registered'), nil)
end)

test('resolveDbId: reverse-resolves the integer id back to the string actionId', function()
    withFakeActionsTable(function()
        ActionService.register('test:baz', function() end, {})
        local dbId = ActionService.getDbId('test:baz')
        eq(ActionService.resolveDbId(dbId), 'test:baz')
    end)
end)

test('resolveDbId: returns nil for an unknown integer id', function()
    eq(ActionService.resolveDbId(999999), nil)
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running ActionService unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = t.name
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err):gsub('\n', '\n         '))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `lua5.4 tests/action_service_spec.lua`
Expected: fails, `ActionService.getDbId`/`resolveDbId` don't exist yet, and `register` never touches `Database.executeQuery` at all yet.

- [ ] **Step 3: Implement the fix in `ActionService.lua`**

Change:

```lua
function ActionService.register(actionId, handler, options)
    if ActionService.registry[actionId] then
        print('[ActionService] Warning: Overwriting existing action: ' .. actionId)
    end
    
    ActionService.registry[actionId] = {
        id = actionId,
        handler = handler,
        options = options or {}
    }
    
    print('[ActionService] Registered action: ' .. actionId)
end
```

to:

```lua
function ActionService.register(actionId, handler, options)
    options = options or {}
    if ActionService.registry[actionId] then
        print('[ActionService] Warning: Overwriting existing action: ' .. actionId)
    end

    local existing = QueryBuilder.new('actions'):where('action_id', actionId):firstSync()
    local dbId
    if existing then
        dbId = existing.id
        QueryBuilder.new('actions'):where('id', dbId):update({
            label = options.label,
            description = options.description,
            options = json.encode(options)
        })
    else
        dbId = QueryBuilder.new('actions'):insert({
            action_id = actionId,
            label = options.label,
            description = options.description,
            options = json.encode(options)
        })
    end

    ActionService.registry[actionId] = { id = actionId, dbId = dbId, handler = handler, options = options }
    ActionService.idToActionId[dbId] = actionId

    print('[ActionService] Registered action: ' .. actionId .. ' (db id ' .. tostring(dbId) .. ')')
end

--- @param actionId string
--- @return number|nil
function ActionService.getDbId(actionId)
    local entry = ActionService.registry[actionId]
    return entry and entry.dbId
end

--- @param dbId number
--- @return string|nil
function ActionService.resolveDbId(dbId)
    return ActionService.idToActionId[dbId]
end
```

Also change the module-level declaration near the top of the file:

```lua
ActionService = {}
ActionService.registry = {}
```

to:

```lua
ActionService = {}
ActionService.registry = {}
ActionService.idToActionId = {}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `lua5.4 tests/action_service_spec.lua`
Expected: `6 passed, 0 failed`.

- [ ] **Step 5: Wire the new spec into `npm test` and the tests README**

In `package.json`, change:

```json
"test": "lua5.4 tests/orm_spec.lua && lua5.4 tests/obelisk_spec.lua",
```

to:

```json
"test": "lua5.4 tests/orm_spec.lua && lua5.4 tests/obelisk_spec.lua && lua5.4 tests/action_service_spec.lua",
```

Add a sentence to `tests/README.md`'s coverage description, matching the existing style for `orm_spec.lua`/`obelisk_spec.lua`, noting `action_service_spec.lua` covers `ActionService.register`'s DB-upsert logic and the `getDbId`/`resolveDbId` lookups.

Run: `npm test`. Expected: all three suites green.

- [ ] **Step 6: Commit**

```bash
git add core/server/Services/ActionService.lua tests/action_service_spec.lua package.json tests/README.md
git commit -m "fix(core): make ActionService.register persist into the actions table"
```

---

## Task 3: `keybinds.action_id` becomes the integer it always claimed to be

**Files:**
- Create: `core/server/database/migrations/<timestamp>_fix_keybinds_action_id_type.lua`
- Modify: `core/server/database/migrations.json`
- Modify: `core/server/Services/KeybindService.lua`

**Interfaces:**
- Consumes: `ActionService.getDbId(actionId)` (Task 2).
- No new interfaces produced; this is an internal storage-format fix.

- [ ] **Step 1: Determine the exact migration filename**

Run: `date -u +%Y_%m_%d_%H%M%S` to get a timestamp in the same format the existing migrations use (`YYYY_MM_DD_HHMMSS`), and name the file `<that>_fix_keybinds_action_id_type.lua`.

- [ ] **Step 2: Write the migration**

Create `core/server/database/migrations/<timestamp>_fix_keybinds_action_id_type.lua`:

```lua
--- Migration: Fix keybinds.action_id to be the integer actions.id it always
--- claimed to be. The column was VARCHAR(100) storing the string actionId,
--- while loadPlayerKeybinds's query already joined ON k.action_id = a.id
--- (the integer PK), a join that never matched anything. See the item
--- module design spec (2026-08-10-item-module-design.md) for the full story.
return {
    up = function()
        Schema.table('keybinds', function(table)
            table:integer('action_id_int')
        end)

        local rows = Database.querySync('SELECT id, action_id FROM keybinds', {})
        for _, row in ipairs(rows or {}) do
            local action = Database.querySync('SELECT id FROM actions WHERE action_id = ?', {row.action_id})
            if action and action[1] then
                Database.updateSync('UPDATE keybinds SET action_id_int = ? WHERE id = ?', {action[1].id, row.id})
            else
                print('[Migration] WARNING: keybind #' .. row.id .. ' references unknown action_id "' .. tostring(row.action_id) .. '", leaving action_id_int NULL')
            end
        end

        Schema.dropColumn('keybinds', 'action_id')
        Schema.renameColumn('keybinds', 'action_id_int', 'action_id')

        print('[Migration] Converted keybinds.action_id to an integer FK against actions.id')
    end,

    down = function()
        error('This migration is not reversible: the original varchar action_id values are not recoverable once dropped.')
    end
}
```

- [ ] **Step 3: Register the migration**

In `core/server/database/migrations.json`, append the new migration's filename (without `.lua`) to the `migrations` array, after the existing 7 entries.

- [ ] **Step 4: Fix `KeybindService.lua`'s writes to resolve through `ActionService.getDbId`**

In `core/server/Services/KeybindService.lua`, change (in `registerGlobal`):

```lua
function KeybindService.registerGlobal(key, actionId, data)
    local sql = [[
        INSERT INTO keybinds (key_code, action_id, data, is_global, player_identifier)
        VALUES (?, ?, ?, 1, NULL)
    ]]
    
    local jsonData = data and json.encode(data) or nil
    local keybindId = Database.insertSync(sql, {key, actionId, jsonData})
```

to:

```lua
function KeybindService.registerGlobal(key, actionId, data)
    local dbId = ActionService.getDbId(actionId)
    if not dbId then
        print('[KeybindService] Error: action "' .. actionId .. '" is not registered')
        return nil
    end

    local sql = [[
        INSERT INTO keybinds (key_code, action_id, data, is_global, player_identifier)
        VALUES (?, ?, ?, 1, NULL)
    ]]
    
    local jsonData = data and json.encode(data) or nil
    local keybindId = Database.insertSync(sql, {key, dbId, jsonData})
```

And (in `registerPlayer`):

```lua
function KeybindService.registerPlayer(source, key, actionId, data)
    local identifier = GetPlayerIdentifier(source, 0)
    
    local sql = [[
        INSERT INTO keybinds (key_code, action_id, data, is_global, player_identifier)
        VALUES (?, ?, ?, 0, ?)
    ]]
    
    local jsonData = data and json.encode(data) or nil
    local keybindId = Database.insertSync(sql, {key, actionId, jsonData, identifier})
```

to:

```lua
function KeybindService.registerPlayer(source, key, actionId, data)
    local dbId = ActionService.getDbId(actionId)
    if not dbId then
        print('[KeybindService] Error: action "' .. actionId .. '" is not registered')
        return nil
    end

    local identifier = GetPlayerIdentifier(source, 0)
    
    local sql = [[
        INSERT INTO keybinds (key_code, action_id, data, is_global, player_identifier)
        VALUES (?, ?, ?, 0, ?)
    ]]
    
    local jsonData = data and json.encode(data) or nil
    local keybindId = Database.insertSync(sql, {key, dbId, jsonData, identifier})
```

Leave `loadPlayerKeybinds`/`loadPlayerKeybindsSync`'s SQL (`LEFT JOIN actions a ON k.action_id = a.id`) exactly as-is; it was already correct, only the data it joins against was wrong.

- [ ] **Step 5: Manual verification**

Run: `lua5.4 -e "assert(loadfile('core/server/database/migrations/<timestamp>_fix_keybinds_action_id_type.lua'))"` and the same for `core/server/Services/KeybindService.lua`, both must parse.

Run: `node -e "require('./core/server/database/migrations.json')"` from the repo root, confirms the JSON is still valid after the append.

Run: `npm test`. Unaffected, all suites still green (this task's logic isn't unit-testable without a real database, per the Global Constraints; this is purely a regression guard).

- [ ] **Step 6: Commit**

```bash
git add core/server/database/migrations/*_fix_keybinds_action_id_type.lua core/server/database/migrations.json core/server/Services/KeybindService.lua
git commit -m "fix(core): keybinds.action_id is now the integer actions.id it always claimed to be"
```

---

## Task 4: `oblsk_items` module scaffold, `base_items`/`items` schema

**Repository note:** this task and the two after it commit to the **separate** `oblsk_items` git repository (`core/modules/oblsk_items/`), not `core`'s repo. Set up its own isolated worktree/branch before starting.

**Files:**
- Create: `oblsk_items/fxmanifest.lua` is **not** created (per the fold-modules-plugins convention, module resources have no manifest of their own; they load via `core`'s globs).
- Create: `README.md`
- Create: `server/migrations/<timestamp1>_create_base_items_table.lua`
- Create: `server/migrations/<timestamp2>_create_items_table.lua`
- Create: `server/migrations.json`

**Interfaces:**
- Produces: the `base_items` and `items` tables. Task 5's models and Task 6's actions both depend on these existing.

- [ ] **Step 1: Determine migration timestamps**

Run: `date -u +%Y_%m_%d_%H%M%S` twice (a few seconds apart, or increment the seconds by hand) to get two distinct timestamps in the existing `YYYY_MM_DD_HHMMSS` format, one for each migration below.

- [ ] **Step 2: Write the `base_items` migration**

Create `server/migrations/<timestamp1>_create_base_items_table.lua`:

```lua
--- Migration: Create base_items table
return {
    up = function()
        Schema.create('base_items', function(table)
            table:id()
            table:string('name', 255):notNullable()
            table:text('description')
            table:string('icon', 255)
            table:float('weight'):notNullable():default(0)
            table:boolean('is_takeable'):default(1)
            table:boolean('is_giveable'):default(1)
            table:boolean('is_dropable'):default(1)
            table:boolean('is_container'):default(0)
            table:boolean('is_useable'):default(0)
            table:boolean('is_stackable'):default(0)
            table:float('step')
            table:string('step_key', 100)
            table:integer('max_stack_amount')
            table:json('data')
            table:json('actions')
            table:timestamps()
        end)

        print('[Migration] Created base_items table')
    end,

    down = function()
        Schema.drop('base_items')
        print('[Migration] Dropped base_items table')
    end
}
```

- [ ] **Step 3: Write the `items` migration**

Create `server/migrations/<timestamp2>_create_items_table.lua`:

```lua
--- Migration: Create items table
return {
    up = function()
        Schema.create('items', function(table)
            table:id()
            table:integer('base_item_id'):notNullable()
            table:string('owner_type', 50):notNullable()
            table:integer('owner_id'):notNullable()
            table:json('data')
            table:integer('amount'):default(1)
            table:timestamps()

            table:index({'owner_type', 'owner_id'})
            table:foreign('base_item_id'):references('id'):on('base_items'):onDelete('RESTRICT')
        end)

        print('[Migration] Created items table')
    end,

    down = function()
        Schema.drop('items')
        print('[Migration] Dropped items table')
    end
}
```

- [ ] **Step 4: Register both migrations**

Create `server/migrations.json`:

```json
{
  "migrations": [
    "<timestamp1>_create_base_items_table",
    "<timestamp2>_create_items_table"
  ]
}
```

(with the real timestamps substituted, in this order: `base_items` must be created before `items`, since `items` has a foreign key against it.)

- [ ] **Step 5: Write the module README**

Create `README.md`:

```markdown
# oblsk_items

Item catalog (`base_items`) and per-instance inventory items (`items`) for the Obelisk framework. Loads as part of `core`; restart `core` (or the whole server) to pick up changes.

See [Item module design](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-10-item-module-design.md) for the full architecture.
```

(Adjust the link if the design spec's actual URL/path differs by the time this is written; the goal is pointing at the source-of-truth design doc, not a specific literal URL.)

- [ ] **Step 6: Register the module in `core`'s `modules/registry.json`**

This step touches **core's** repo, not `oblsk_items`'s, since the registry file lives in `core/modules/registry.json`. In `core`'s repo (a separate checkout/worktree from this task's `oblsk_items` one), change:

```json
{
  "modules": []
}
```

to:

```json
{
  "modules": ["oblsk_items"]
}
```

- [ ] **Step 7: Manual verification**

Run: `lua5.4 -e "assert(loadfile('server/migrations/<timestamp1>_create_base_items_table.lua'))"` and the same for the `items` migration file, both must parse.

Run: `node -e "require('./server/migrations.json')"` from the `oblsk_items` repo root, confirms valid JSON.

- [ ] **Step 8: Commit (two repos)**

In the `oblsk_items` repo:

```bash
git add README.md server/migrations server/migrations.json
git commit -m "feat: add base_items/items schema"
```

In `core`'s repo:

```bash
git add modules/registry.json
git commit -m "feat: register oblsk_items module"
```

---

## Task 5: `BaseItem`/`Item` models

**Repository:** `oblsk_items` (same worktree/branch as Task 4).

**Files:**
- Create: `server/models/BaseItem.lua`
- Create: `server/models/Item.lua`
- Create: `tests/item_spec.lua` (a new, self-contained test file inside the `oblsk_items` repo, following the same pattern as `core`'s `tests/orm_spec.lua`)

**Interfaces:**
- Produces: `Item:getWeight()` (pure function, the weight-ratio formula), `Item.isStackableWith(a, b)` (pure function, stack-eligibility comparison). Task 6's `item:consume_step` action and any future inventory-listing code both need these.

- [ ] **Step 1: Write the failing tests**

Create `tests/item_spec.lua` in the `oblsk_items` repo:

```lua
--- Unit tests for the pure logic in the Item module (weight calculation,
--- stack eligibility). Run from the repository root:  lua5.4 tests/item_spec.lua
---
--- This module depends on core's ORM (BaseModel) being loadable stand-alone,
--- the same way core/tests/orm_spec.lua already loads it. CORE_ROOT below is
--- not a guess: oblsk_items must physically live at <core-root>/modules/
--- oblsk_items/ for core's fxmanifest.lua glob to load it at all (see the
--- fold-modules-plugins design), so this repo's own root is always exactly
--- three directories below core's root, in every real checkout.

local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(scriptDir .. '../server/models/BaseItem.lua')
dofile(scriptDir .. '../server/models/Item.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

test('Item:getWeight() returns the flat base weight when step_key is not set', function()
    local baseItem = BaseItem.new({ weight = 5, step = nil, step_key = nil, data = {} })
    local item = Item.new({ data = {} })
    item.baseItem = baseItem
    eq(item:getWeight(), 5)
end)

test('Item:getWeight() scales weight by the remaining/capacity ratio when step_key is set', function()
    local baseItem = BaseItem.new({ weight = 1000, step = 100, step_key = 'fill_ml', data = { fill_ml = 1000 } })
    local item = Item.new({ data = { fill_ml = 900 } })
    item.baseItem = baseItem
    eq(item:getWeight(), 900)
end)

test('Item:getWeight() falls back to flat weight if the step_key is missing from data', function()
    local baseItem = BaseItem.new({ weight = 1000, step = 100, step_key = 'fill_ml', data = {} })
    local item = Item.new({ data = {} })
    item.baseItem = baseItem
    eq(item:getWeight(), 1000)
end)

test('Item.isStackableWith: identical data on the same base_item_id/owner is stackable', function()
    local a = Item.new({ base_item_id = 1, owner_type = 'character', owner_id = 1, data = { fill_ml = 1000 } })
    local b = Item.new({ base_item_id = 1, owner_type = 'character', owner_id = 1, data = { fill_ml = 1000 } })
    truthy(Item.isStackableWith(a, b), 'identical data stacks')
end)

test('Item.isStackableWith: different data on the same base_item_id/owner is not stackable', function()
    local a = Item.new({ base_item_id = 1, owner_type = 'character', owner_id = 1, data = { fill_ml = 1000 } })
    local b = Item.new({ base_item_id = 1, owner_type = 'character', owner_id = 1, data = { fill_ml = 900 } })
    eq(Item.isStackableWith(a, b), false)
end)

test('Item.isStackableWith: different owner is not stackable even with identical data', function()
    local a = Item.new({ base_item_id = 1, owner_type = 'character', owner_id = 1, data = {} })
    local b = Item.new({ base_item_id = 1, owner_type = 'character', owner_id = 2, data = {} })
    eq(Item.isStackableWith(a, b), false)
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running Item unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = t.name
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err):gsub('\n', '\n         '))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `lua5.4 tests/item_spec.lua`
Expected: fails immediately, `server/models/BaseItem.lua`/`Item.lua` don't exist yet.

- [ ] **Step 3: Write `BaseItem.lua`**

Create `server/models/BaseItem.lua`:

```lua
--- BaseItem Model - the item catalog/template. One row per item type.
--- `BaseModel` is a global provided by core; this module loads as part of
--- core's own resource (see the fold-modules-plugins design), not as a
--- separate FXServer resource.
BaseItem = BaseModel:extend('base_items')

BaseItem.primaryKey = 'id'
BaseItem.timestamps = true

BaseItem.fillable = {
    'name', 'description', 'icon', 'weight',
    'is_takeable', 'is_giveable', 'is_dropable', 'is_container', 'is_useable', 'is_stackable',
    'step', 'step_key', 'max_stack_amount',
    'data', 'actions',
}

BaseItem.hidden = {}

BaseItem.casts = {
    data = 'json',
    actions = 'json',
}

return BaseItem
```

- [ ] **Step 4: Write `Item.lua`**

Create `server/models/Item.lua`:

```lua
--- Item Model - a single owned instance of a BaseItem (a stack, a specific
--- partially-consumed item, etc). Ownership is polymorphic: owner_type is an
--- open string ('character', 'item', 'vehicle_trunk', 'vehicle_glovebox',
--- more later), owner_id points at whatever that type's table primary key
--- is. No FK constraint on owner_id since the target table varies.
Item = BaseModel:extend('items')

Item.primaryKey = 'id'
Item.timestamps = true

Item.fillable = {
    'base_item_id', 'owner_type', 'owner_id', 'data', 'amount',
}

Item.hidden = {}

Item.casts = {
    data = 'json',
}

function Item:baseItemRelation()
    return self:belongsTo(BaseItem, 'base_item_id', 'id')
end

--- Weight of this specific item instance. Flat base weight unless the item
--- type depletes (step_key set), in which case it scales by how much of
--- data[step_key] remains versus the base item's starting capacity.
--- Assumes self.baseItem is already set (via :loadSync('baseItemRelation')
--- or set directly, as the pure-logic tests in tests/item_spec.lua do).
--- this method does not lazily load the relation itself, callers control
--- when that query happens.
--- @return number
function Item:getWeight()
    local baseItem = self.baseItem
    local key = baseItem.attributes.step_key
    if key and baseItem.attributes.step and self.attributes.data[key] and baseItem.attributes.data[key] then
        return baseItem.attributes.weight * (self.attributes.data[key] / baseItem.attributes.data[key])
    end
    return baseItem.attributes.weight
end

--- Whether two Item instances are eligible to merge into one stacked row:
--- same base item, same owner, and byte-identical data. Does not check
--- is_stackable itself or max_stack_amount, both of which need the BaseItem,
--- not just the two Item instances; callers check those separately.
--- @param a table Item instance
--- @param b table Item instance
--- @return boolean
function Item.isStackableWith(a, b)
    if a.attributes.base_item_id ~= b.attributes.base_item_id then return false end
    if a.attributes.owner_type ~= b.attributes.owner_type then return false end
    if a.attributes.owner_id ~= b.attributes.owner_id then return false end
    return json.encode(a.attributes.data) == json.encode(b.attributes.data)
end

return Item
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `lua5.4 tests/item_spec.lua`
Expected: `6 passed, 0 failed`.

- [ ] **Step 6: Manual verification**

Run: `lua5.4 -e "assert(loadfile('server/models/BaseItem.lua'))"` and the same for `Item.lua`, both must parse (this is in addition to, not instead of, the real test run above, since `dofile`-based test loading can mask certain syntax issues that a plain `loadfile` catches more directly).

- [ ] **Step 7: Commit**

```bash
git add server/models/BaseItem.lua server/models/Item.lua tests/item_spec.lua
git commit -m "feat: add BaseItem/Item models with weight calculation and stack eligibility"
```

---

## Task 6: Built-in item actions and the use pipeline

**Repository:** `oblsk_items` (same worktree/branch as Tasks 4-5).

**Files:**
- Create: `server/services/ItemService.lua`
- Create: `server/actions/ItemActions.lua`

**Interfaces:**
- Consumes: `ActionService.register`/`getDbId`/`resolveDbId` (Task 2), `Item.getWeight`/`isStackableWith`, `BaseItem`/`Item` models (Task 5).
- Produces: `ItemService.use(source, item)`, `ItemService.consumeStep(item, baseItem)` (the pure logic `item:consume_step` calls, kept separate so it stays unit-testable without going through `ActionService.execute`).

- [ ] **Step 1: Write `ItemService.lua`**

Create `server/services/ItemService.lua`:

```lua
--- ItemService - runs a BaseItem's use pipeline (base_items.actions) through
--- the existing ActionService, and holds the pure step-consumption logic the
--- item:consume_step action delegates to.
ItemService = {}

--- Subtract baseItem.step from item.data[baseItem.step_key], clamped to >= 0,
--- and persist the item. No-op if the item type has no step_key configured.
--- Kept separate from the item:consume_step action registration below so
--- this logic stays a plain, unit-testable function.
--- @param item table Item instance
--- @param baseItem table BaseItem instance
function ItemService.consumeStep(item, baseItem)
    local key = baseItem.attributes.step_key
    if not (key and baseItem.attributes.step) then return end

    local current = item.attributes.data[key] or 0
    item.attributes.data[key] = math.max(0, current - baseItem.attributes.step)
    item:saveSync()
end

--- Run a BaseItem's use pipeline for a given Item instance. Does nothing if
--- the item type isn't marked is_useable. Each pipeline entry's action_id is
--- an integer referencing actions.id (see ActionService); unknown ids are
--- skipped with a warning, not treated as a hard failure.
--- @param source number Player server ID
--- @param item table Item instance
function ItemService.use(source, item)
    local baseItem = BaseItem:findSync(item.attributes.base_item_id)
    if not baseItem or not baseItem.attributes.is_useable then return end

    for _, entry in ipairs(baseItem.attributes.actions or {}) do
        local actionId = ActionService.resolveDbId(entry.action_id)
        if actionId then
            local data = baseItem:copyTable(entry.data or {})
            data.item = item
            data.baseItem = baseItem
            ActionService.execute(source, actionId, data)
        else
            print('[ItemService] WARNING: base_item #' .. baseItem.attributes.id .. ' references unknown action db id ' .. tostring(entry.action_id) .. ', skipping')
        end
    end
end

return ItemService
```

- [ ] **Step 2: Write `ItemActions.lua`, registering the two built-in actions**

Create `server/actions/ItemActions.lua`:

```lua
--- Built-in actions usable from any base_items.actions pipeline entry.
--- Registered once at module load, same mechanism every other action in the
--- framework uses (see core/server/Services/ActionService.lua).

ActionService.register('item:consume_step', function(source, data)
    if not (data.item and data.baseItem) then return end
    ItemService.consumeStep(data.item, data.baseItem)
end, { label = 'Consume one step of a depletable item' })

ActionService.register('item:notify', function(source, data)
    NotificationService.notify(source, {
        type = data.kind or 'info',
        title = data.title,
        description = data.text
    })
end, { label = 'Send a notification as an item-use side effect' })
```

- [ ] **Step 3: Manual verification**

Run: `lua5.4 -e "assert(loadfile('server/services/ItemService.lua'))"` and the same for `server/actions/ItemActions.lua`, both must parse.

Read through `ItemService.consumeStep` once more and confirm it matches Task 5's `Item:getWeight()` in which field it reads (`baseItem.attributes.step_key`, `baseItem.attributes.step`, `item.attributes.data[key]`) so the depletion write and the weight-read formula stay in agreement about the shape of `data`.

Run (from `core`'s repo, unrelated regression guard): `npm test`, still green, unaffected by this task's changes (which live entirely in the separate `oblsk_items` repo).

- [ ] **Step 4: Commit**

```bash
git add server/services/ItemService.lua server/actions/ItemActions.lua
git commit -m "feat: add item use pipeline (item:consume_step, item:notify) via ActionService"
```
