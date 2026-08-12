# Organizations Module and Core Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic, reusable permission-grant mechanism to core (`PermissionService` + `HasPermissions` trait), then build `modules/oblsk_organizations` (organizations/departments/ranks/memberships) on top of it, wiring ranks and departments into permission checks on `Character` without `oblsk_characters` ever depending on `oblsk_organizations`.

**Architecture:** Core gets one polymorphic `permissions` table and a registry-based service (`PermissionService`, mirroring the existing `PolicyService` idiom of registry + polymorphic pivot table). A small mixin (`HasPermissions`) adds `:can/:grant/:revoke/:permissionList` to any `BaseModel` subclass that opts in. `oblsk_organizations` is a new module (peer to `oblsk_accounts`/`oblsk_characters`) with its own five tables, a `Department`/`Rank` model pair using the trait, an `OrganizationService`, admin commands, and one `PermissionService.addDelegate('character', ...)` call that is the entire cross-module link.

**Tech Stack:** Lua 5.4, the existing Obelisk ORM (`BaseModel`, `QueryBuilder`, `Schema`), plain-Lua unit tests run via `lua5.4 <file>.lua` against a fake in-memory `QueryBuilder`, `luac5.4 -p` for syntax-only checks on files that can't be unit tested outside FXServer (migrations, commands).

## Global Constraints

- Repo root is `/home/andi/Projects/obelisk-framework/core`. It contains its own nested `core/` folder for the FXServer resource's client/server/shared scripts (i.e. `core/server/ORM/...` is `<repo-root>/core/server/ORM/...`), plus top-level `modules/`, `plugins/`, `docs/`, `tests/`, `fxmanifest.lua`.
- `modules/*` and `plugins/*` are gitignored by the `core` repo itself (verified in `core/.gitignore`) — every module (`oblsk_accounts`, `oblsk_characters`, ...) is its own independent git repository nested inside `core`'s working tree, not tracked by `core`'s own history. `modules/registry.json` is itself also gitignored (an earlier `fold-modules-plugins` change replaced the hand-maintained/committed registry with `node cli/index.js registry:generate`, which scans `modules/`/`plugins/` on disk — see `cli/commands/registry-generate.js`) — it needs regenerating, never editing or committing. `modules/oblsk_organizations` does not exist yet: Task 5's first step is `git init` there, exactly like every existing module. Every later task's commit that touches files under `modules/oblsk_organizations/` runs as `git -C modules/oblsk_organizations ...`, never as a plain `git add` from `core`'s own root (which would silently no-op on a gitignored path).
- Every `source` used inside an `Obelisk.onServer`/net-event handler must start with `local source = source` as its first line — FiveM's `source` is a real implicit global, never a callback parameter.
- Cross-module references are plain globals resolved at runtime (e.g. `CharacterService.getActiveCharacterId(source)`), never `require`. No migration-level foreign key across module boundaries.
- Config: this framework has **no** existing global `Config` convention (verified — no file anywhere defines one). Do not invent one for this plan. `OrganizationService.ALLOW_MULTIPLE_MEMBERSHIPS` is a plain module-level boolean constant at the top of `OrganizationService.lua`, editable directly by a server owner, same as `PhoneAppRegistry.CATALOG` being a plain table constant.
- A permission grant's existence in the `permissions` table IS the grant — no `value` column, nothing else to store.
- `HasPermissions` is one small mixin for this one behavior, not a general trait framework. Do not build extension points beyond what this plan specifies.
- Every new Lua file must pass `luac5.4 -p <file>`. Every new/touched `.vue` file (none in this plan) would need `@vue/compiler-sfc` parsing, not applicable here.
- Commands in this framework are never unit-tested (verified: no test file exists for `AccountCommands` or any other command file anywhere in the repo) — a `luac5.4 -p` syntax check is the only required verification for the commands task.
- Migrations in this framework are never executed inside unit tests (verified: no spec anywhere calls a migration's `.up()`) — a `luac5.4 -p` syntax check is the only required verification for migration files.

---

## Task 1: Core `permissions` table + `PermissionService` (registerType/grant/revoke/has/list)

**Files:**
- Create: `core/server/database/migrations/2026_08_11_070000_create_permissions_table.lua`
- Modify: `core/server/database/migrations.json`
- Create: `core/server/Services/PermissionService.lua`
- Create: `tests/support/fake_query_builder.lua`
- Test: `tests/permission_service_spec.lua`

**Interfaces:**
- Produces: `PermissionService.registerType(typeName, Model)`, `PermissionService.grant(ownerType, ownerId, key)`, `PermissionService.revoke(ownerType, ownerId, key)`, `PermissionService.has(ownerType, ownerId, key) -> boolean`, `PermissionService.list(ownerType, ownerId) -> string[]`. `PermissionService.registeredTypes` (table, typeName -> Model) and `PermissionService.delegates` (table, typeName -> array of resolver fns) as public fields future tasks read/write directly.

- [ ] **Step 1: Write the migration**

```lua
--- Migration: Create permissions table
--- One generic polymorphic permission-grant table, reusable by any entity
--- type any module registers with PermissionService. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
return {
    up = function()
        Schema.create('permissions', function(table)
            table:id()
            table:string('owner_type', 50):notNullable()
            table:integer('owner_id'):notNullable()
            table:string('permission_key', 150):notNullable()
            table:timestamps()

            table:unique({'owner_type', 'owner_id', 'permission_key'})
            table:index({'owner_type', 'owner_id'})
        end)

        print('[Migration] Created permissions table')
    end,

    down = function()
        Schema.drop('permissions')
        print('[Migration] Dropped permissions table')
    end
}
```

- [ ] **Step 2: Register the migration**

Add `"2026_08_11_070000_create_permissions_table"` to the end of the `migrations` array in `core/server/database/migrations.json` (it currently ends with `"2026_08_10_041318_fix_keybinds_action_id_type"`).

- [ ] **Step 3: Verify the migration parses**

Run: `luac5.4 -p core/server/database/migrations/2026_08_11_070000_create_permissions_table.lua`
Expected: no output, exit code 0.

- [ ] **Step 4: Create the core-level fake QueryBuilder test support file**

`tests/support/fake_query_builder.lua` — identical in shape to the one already used by every module (e.g. `plugins/oblsk_phone/tests/support/fake_query_builder.lua`), copied verbatim since core-level specs need the exact same in-memory double and none currently exists at `tests/support/`:

```lua
--- A fake QueryBuilder.new that operates on in-memory Lua tables instead of
--- real SQL. See tests/permission_service_spec.lua for how this is
--- swapped in for the real global QueryBuilder around each test.
local FakeQueryBuilder = {}
FakeQueryBuilder.__index = FakeQueryBuilder

local function rowMatches(row, wheres, whereNulls)
    for _, w in ipairs(wheres) do
        if row[w.column] ~= w.value then return false end
    end
    for _, col in ipairs(whereNulls) do
        if row[col] ~= nil then return false end
    end
    return true
end

function FakeQueryBuilder:where(column, a, b)
    local value = b ~= nil and b or a
    table.insert(self.wheres, { column = column, value = value })
    return self
end

function FakeQueryBuilder:whereNull(column)
    table.insert(self.whereNulls, column)
    return self
end

function FakeQueryBuilder:orderBy(column, direction)
    self.orderByColumn = column
    self.orderByDirection = direction or 'asc'
    return self
end

function FakeQueryBuilder:limit(n)
    self.limitCount = n
    return self
end

function FakeQueryBuilder:firstSync()
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            return row
        end
    end
    return nil
end

function FakeQueryBuilder:getSync()
    local results = {}
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            table.insert(results, row)
        end
    end

    if self.orderByColumn then
        local column, descending = self.orderByColumn, self.orderByDirection == 'desc'
        table.sort(results, function(a, b)
            if a[column] == b[column] then
                if descending then return a.id > b.id end
                return a.id < b.id
            end
            if descending then return a[column] > b[column] end
            return a[column] < b[column]
        end)
    end

    if self.limitCount and #results > self.limitCount then
        local limited = {}
        for i = 1, self.limitCount do
            limited[i] = results[i]
        end
        results = limited
    end

    return results
end

function FakeQueryBuilder:insert(data)
    self.nextIds[self.tableName] = (self.nextIds[self.tableName] or 0) + 1
    local id = self.nextIds[self.tableName]
    local row = { id = id }
    for k, v in pairs(data) do row[k] = v end
    table.insert(self.rows, row)
    return id
end

function FakeQueryBuilder:update(data)
    local affected = 0
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            for k, v in pairs(data) do row[k] = v end
            affected = affected + 1
        end
    end
    return affected
end

function FakeQueryBuilder:delete()
    local kept, removed = {}, 0
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            removed = removed + 1
        else
            table.insert(kept, row)
        end
    end
    for i = #self.rows, 1, -1 do
        table.remove(self.rows, i)
    end
    for _, row in ipairs(kept) do
        table.insert(self.rows, row)
    end
    return removed
end

--- @param tables table tableName -> array of row tables (shared, mutated in place across calls)
--- @return table a QueryBuilder-shaped module (has .new(tableName))
local function makeFakeQueryBuilderModule(tables)
    local nextIds = {}
    local Module = {}
    function Module.new(tableName)
        tables[tableName] = tables[tableName] or {}
        return setmetatable({
            tableName = tableName,
            rows = tables[tableName],
            nextIds = nextIds,
            wheres = {},
            whereNulls = {},
        }, FakeQueryBuilder)
    end
    return Module
end

return makeFakeQueryBuilderModule
```

- [ ] **Step 5: Write the failing test**

`tests/permission_service_spec.lua`:

```lua
--- Unit tests for PermissionService: entity-type registration and direct
--- grant/revoke/has/list. Delegated (PermissionService.can) behavior is
--- covered in permission_service_delegates_spec.lua (Task 2).
--- Run from the repository root:  lua5.4 tests/permission_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/Services/PermissionService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

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

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    -- Each test gets a clean registry too, so registerType calls in one
    -- test never leak into the next.
    local originalTypes, originalDelegates = PermissionService.registeredTypes, PermissionService.delegates
    PermissionService.registeredTypes = {}
    PermissionService.delegates = {}

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    PermissionService.registeredTypes = originalTypes
    PermissionService.delegates = originalDelegates
    if not ok then error(err, 2) end
end

test('grant: rejects an unregistered owner type', function()
    withFakeDb(function()
        local ok = pcall(PermissionService.grant, 'widget', 1, 'manage')
        eq(ok, false)
    end)
end)

test('grant: creates a row for a registered type', function()
    withFakeDb(function(tables)
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        eq(#tables.permissions, 1)
        eq(tables.permissions[1].owner_type, 'character')
        eq(tables.permissions[1].owner_id, 1)
        eq(tables.permissions[1].permission_key, 'manage_bank')
    end)
end)

test('grant: calling it twice never duplicates the row', function()
    withFakeDb(function(tables)
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        PermissionService.grant('character', 1, 'manage_bank')
        eq(#tables.permissions, 1)
    end)
end)

test('has: true only for an exact owner_type/owner_id/key match', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')

        truthy(PermissionService.has('character', 1, 'manage_bank'))
        eq(PermissionService.has('character', 2, 'manage_bank'), false)
        eq(PermissionService.has('character', 1, 'manage_fleet'), false)
    end)
end)

test('revoke: removes the grant', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        PermissionService.revoke('character', 1, 'manage_bank')

        eq(PermissionService.has('character', 1, 'manage_bank'), false)
    end)
end)

test('list: returns every granted key for that owner, no others', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        PermissionService.grant('character', 1, 'manage_fleet')
        PermissionService.grant('character', 2, 'manage_bank')

        local keys = PermissionService.list('character', 1)
        table.sort(keys)
        eq(#keys, 2)
        eq(keys[1], 'manage_bank')
        eq(keys[2], 'manage_fleet')
    end)
end)

print('Running PermissionService unit tests\n')
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

- [ ] **Step 6: Run the test to verify it fails**

Run: `lua5.4 tests/permission_service_spec.lua`
Expected: FAIL — `core/server/Services/PermissionService.lua` does not exist yet (`dofile` errors).

- [ ] **Step 7: Write `PermissionService.lua`**

```lua
--- PermissionService (core) - a generic polymorphic permission-grant store,
--- reusable by any entity type any module registers. Mirrors PolicyService's
--- registry + polymorphic-pivot-table idiom, except one fixed table
--- (`permissions`) instead of a table-per-resource-type, since a grant is
--- just "does this row exist", nothing configurable to store alongside it.
--- See docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
PermissionService = {}

--- typeName -> Model, populated by each entity type's owning module calling
--- registerType once at boot. grant/revoke/has/list reject an unregistered
--- type instead of silently writing garbage.
PermissionService.registeredTypes = {}

--- typeName -> array of resolver functions, populated by a DIFFERENT module
--- than the one that owns typeName (see addDelegate, Task 2).
PermissionService.delegates = {}

--- @param typeName string
--- @param Model table the model class this type corresponds to (kept for
---   future admin tooling; not required for grant/revoke/has/list to work)
function PermissionService.registerType(typeName, Model)
    PermissionService.registeredTypes[typeName] = Model
end

local function assertRegistered(ownerType)
    if not PermissionService.registeredTypes[ownerType] then
        error('PermissionService: "' .. tostring(ownerType) .. '" is not a registered entity type', 3)
    end
end

--- @param ownerType string
--- @param ownerId number
--- @param key string
function PermissionService.grant(ownerType, ownerId, key)
    assertRegistered(ownerType)

    local existing = QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('permission_key', key):firstSync()
    if existing then
        return
    end

    QueryBuilder.new('permissions'):insert({
        owner_type = ownerType,
        owner_id = ownerId,
        permission_key = key,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param ownerType string
--- @param ownerId number
--- @param key string
function PermissionService.revoke(ownerType, ownerId, key)
    assertRegistered(ownerType)

    QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('permission_key', key):delete()
end

--- Direct grant lookup only. No unregistered-type check: a lookup for an
--- owner type nobody ever registered is simply always false, same as one
--- that was registered but never granted anything.
--- @param ownerType string
--- @param ownerId number
--- @param key string
--- @return boolean
function PermissionService.has(ownerType, ownerId, key)
    local row = QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('permission_key', key):firstSync()
    return row ~= nil
end

--- @param ownerType string
--- @param ownerId number
--- @return string[] every granted permission_key for this owner
function PermissionService.list(ownerType, ownerId)
    local rows = QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):getSync()

    local keys = {}
    for _, row in ipairs(rows) do
        table.insert(keys, row.permission_key)
    end
    return keys
end

return PermissionService
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `lua5.4 tests/permission_service_spec.lua`
Expected: `6 passed, 0 failed`

- [ ] **Step 9: Verify syntax and commit**

Run: `luac5.4 -p core/server/Services/PermissionService.lua`
Expected: no output, exit code 0.

```bash
git add core/server/database/migrations/2026_08_11_070000_create_permissions_table.lua \
        core/server/database/migrations.json \
        core/server/Services/PermissionService.lua \
        tests/support/fake_query_builder.lua \
        tests/permission_service_spec.lua
git commit -m "feat: add core permissions table and PermissionService (register/grant/revoke/has/list)"
```

---

## Task 2: `PermissionService.addDelegate` + `PermissionService.can`

**Files:**
- Modify: `core/server/Services/PermissionService.lua`
- Test: `tests/permission_service_spec.lua`

**Interfaces:**
- Consumes: `PermissionService.has`, `PermissionService.delegates` (both from Task 1).
- Produces: `PermissionService.addDelegate(typeName, resolverFn)` where `resolverFn(ownerId) -> table[]` of `{ type = string, id = number }`; `PermissionService.can(ownerType, ownerId, key) -> boolean`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/permission_service_spec.lua`, directly before the `print('Running PermissionService unit tests...` line:

```lua
test('can: true for a direct grant even with no delegates registered', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')

        truthy(PermissionService.can('character', 1, 'manage_bank'))
    end)
end)

test('can: false when there is no direct grant and no delegate finds one', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        eq(PermissionService.can('character', 1, 'manage_bank'), false)
    end)
end)

test('can: true via a delegate that resolves to a ref holding the grant', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.registerType('rank', {})
        PermissionService.grant('rank', 5, 'manage_bank')

        PermissionService.addDelegate('character', function(characterId)
            if characterId == 1 then
                return { { type = 'rank', id = 5 } }
            end
            return {}
        end)

        truthy(PermissionService.can('character', 1, 'manage_bank'))
        eq(PermissionService.can('character', 2, 'manage_bank'), false)
    end)
end)

test('can: checks every registered delegate for the type, not just the first', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.registerType('rank', {})
        PermissionService.registerType('department', {})
        PermissionService.grant('department', 9, 'manage_fleet')

        PermissionService.addDelegate('character', function() return { { type = 'rank', id = 999 } } end)
        PermissionService.addDelegate('character', function() return { { type = 'department', id = 9 } } end)

        truthy(PermissionService.can('character', 1, 'manage_fleet'))
    end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua5.4 tests/permission_service_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'addDelegate')` / `(field 'can')`.

- [ ] **Step 3: Implement `addDelegate` and `can`**

Add to `core/server/Services/PermissionService.lua`, after `PermissionService.list`:

```lua
--- Registers a resolver that extends what "can <typeName> #id do X" means,
--- on behalf of a DIFFERENT module than the one owning typeName. Multiple
--- delegates for the same typeName may be registered; all run. Does not
--- validate typeName against registeredTypes, a delegate may be added
--- before or after its target type is registered.
--- @param typeName string
--- @param resolverFn function(ownerId) -> table[] of { type = string, id = number }
function PermissionService.addDelegate(typeName, resolverFn)
    PermissionService.delegates[typeName] = PermissionService.delegates[typeName] or {}
    table.insert(PermissionService.delegates[typeName], resolverFn)
end

--- @param ownerType string
--- @param ownerId number
--- @param key string
--- @return boolean true if directly granted, or granted to any ref any delegate resolves to
function PermissionService.can(ownerType, ownerId, key)
    if PermissionService.has(ownerType, ownerId, key) then
        return true
    end

    for _, resolver in ipairs(PermissionService.delegates[ownerType] or {}) do
        for _, ref in ipairs(resolver(ownerId) or {}) do
            if PermissionService.has(ref.type, ref.id, key) then
                return true
            end
        end
    end

    return false
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua5.4 tests/permission_service_spec.lua`
Expected: `10 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/PermissionService.lua tests/permission_service_spec.lua
git commit -m "feat: add PermissionService.addDelegate and .can (delegated permission checks)"
```

---

## Task 3: `HasPermissions` trait

**Files:**
- Create: `core/server/Traits/HasPermissions.lua`
- Modify: `fxmanifest.lua`
- Test: `tests/has_permissions_spec.lua`

**Interfaces:**
- Consumes: `PermissionService.registerType/grant/revoke/list/can` (Tasks 1-2).
- Produces: `HasPermissions.apply(Model, typeName)`, which sets `Model.permissionType = typeName` and adds instance methods `:can(key)`, `:grant(key)`, `:revoke(key)`, `:permissionList()`.

- [ ] **Step 1: Add the `Traits` glob to `fxmanifest.lua`**

In `fxmanifest.lua`'s `server_scripts` block, `core/server/Traits/**/*.lua` must load after `core/server/Services/*.lua` (where `PermissionService.lua` lives) and before any module. Insert it right after the `-- Policies` block and before `-- Bootstrap`:

```lua
    -- Policies
    'core/server/Policies/**/*.lua',
    
    -- Traits
    'core/server/Traits/**/*.lua',
    
    -- Bootstrap
    'core/server/bootstrap.lua',
```

- [ ] **Step 2: Write the failing test**

`tests/has_permissions_spec.lua` defines a tiny throwaway `BaseModel` subclass to exercise the trait generically, without depending on any real module's model:

```lua
--- Unit tests for the HasPermissions trait: applying it to a plain
--- BaseModel subclass wires up PermissionService.registerType and adds
--- :can/:grant/:revoke/:permissionList. Uses a throwaway model so this
--- stays independent of any specific module's real models (see
--- modules/oblsk_characters/tests/character_model_spec.lua and
--- modules/oblsk_accounts/tests/account_model_spec.lua for the real ones).
--- Run from the repository root:  lua5.4 tests/has_permissions_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(ROOT .. '/core/server/Services/PermissionService.lua')
dofile(ROOT .. '/core/server/Traits/HasPermissions.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

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

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local originalTypes, originalDelegates = PermissionService.registeredTypes, PermissionService.delegates
    PermissionService.registeredTypes = {}
    PermissionService.delegates = {}

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    PermissionService.registeredTypes = originalTypes
    PermissionService.delegates = originalDelegates
    if not ok then error(err, 2) end
end

test('apply: sets permissionType and registers with PermissionService', function()
    withFakeDb(function()
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        eq(Widget.permissionType, 'widget')
        truthy(PermissionService.registeredTypes.widget ~= nil)
    end)
end)

test('grant/can: an instance can grant itself a key and then see it as true', function()
    withFakeDb(function(tables)
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        tables.widgets = { { id = 7, name = 'thingamajig' } }
        local instance = Widget:findSync(7)

        eq(instance:can('spin'), false)
        instance:grant('spin')
        truthy(instance:can('spin'))
    end)
end)

test('revoke: removes a previously granted key', function()
    withFakeDb(function(tables)
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        tables.widgets = { { id = 7, name = 'thingamajig' } }
        local instance = Widget:findSync(7)

        instance:grant('spin')
        instance:revoke('spin')
        eq(instance:can('spin'), false)
    end)
end)

test('permissionList: returns every key granted to this instance', function()
    withFakeDb(function(tables)
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        tables.widgets = { { id = 7, name = 'thingamajig' } }
        local instance = Widget:findSync(7)

        instance:grant('spin')
        instance:grant('paint')

        local keys = instance:permissionList()
        table.sort(keys)
        eq(#keys, 2)
        eq(keys[1], 'paint')
        eq(keys[2], 'spin')
    end)
end)

print('Running HasPermissions unit tests\n')
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

- [ ] **Step 3: Run the test to verify it fails**

Run: `lua5.4 tests/has_permissions_spec.lua`
Expected: FAIL — `core/server/Traits/HasPermissions.lua` does not exist yet (`dofile` errors).

- [ ] **Step 4: Write `HasPermissions.lua`**

```lua
--- HasPermissions (core trait) - one mixin, not a general trait system.
--- HasPermissions.apply(Character, 'character') registers Character with
--- PermissionService under the 'character' type and adds :can/:grant/
--- :revoke/:permissionList instance methods backed by it. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
HasPermissions = {}

--- @param Model table a BaseModel subclass (the result of BaseModel:extend(...))
--- @param typeName string the PermissionService entity type this model is registered as
function HasPermissions.apply(Model, typeName)
    Model.permissionType = typeName
    PermissionService.registerType(typeName, Model)

    function Model:can(key)
        return PermissionService.can(self.permissionType, self:get(self.primaryKey), key)
    end

    function Model:grant(key)
        return PermissionService.grant(self.permissionType, self:get(self.primaryKey), key)
    end

    function Model:revoke(key)
        return PermissionService.revoke(self.permissionType, self:get(self.primaryKey), key)
    end

    function Model:permissionList()
        return PermissionService.list(self.permissionType, self:get(self.primaryKey))
    end
end

return HasPermissions
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `lua5.4 tests/has_permissions_spec.lua`
Expected: `4 passed, 0 failed`

- [ ] **Step 6: Verify syntax and commit**

Run: `luac5.4 -p core/server/Traits/HasPermissions.lua`
Expected: no output, exit code 0.

```bash
git add core/server/Traits/HasPermissions.lua fxmanifest.lua tests/has_permissions_spec.lua
git commit -m "feat: add HasPermissions trait"
```

---

## Task 4: Apply the trait to `Account` and `Character`

**Files:**
- Modify: `modules/oblsk_accounts/server/models/Account.lua`
- Modify: `modules/oblsk_characters/server/models/Character.lua`
- Test: `modules/oblsk_accounts/tests/account_model_spec.lua`
- Test: `modules/oblsk_characters/tests/character_model_spec.lua`

**Interfaces:**
- Consumes: `HasPermissions.apply` (Task 3).
- Produces: `Account.permissionType == 'account'`, `Character.permissionType == 'character'`, both usable via `:can/:grant/:revoke/:permissionList`.

- [ ] **Step 1: Write the failing test for `Account`**

`modules/oblsk_accounts/tests/account_model_spec.lua` — check the existing `modules/oblsk_accounts/tests/account_service_spec.lua` header first for this module's exact `CORE_ROOT` relative path and stub load order, then mirror it. Given that file's established pattern:

```lua
--- Unit tests for Account's HasPermissions wiring.
--- Run from the repository root:  lua5.4 tests/account_model_spec.lua
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
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(CORE_ROOT .. '/core/server/Traits/HasPermissions.lua')
dofile(scriptDir .. '../server/models/Account.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

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

test('Account.permissionType is "account"', function()
    eq(Account.permissionType, 'account')
end)

test('an Account instance can grant and check its own permission', function()
    local tables = { accounts = { { id = 3, max_characters = 3 } } }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(function()
        local instance = Account:findSync(3)
        eq(instance:can('bypass_ban'), false)
        instance:grant('bypass_ban')
        truthy(instance:can('bypass_ban'))
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

print('Running Account model unit tests\n')
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

- [ ] **Step 2: Write the failing test for `Character`**

`modules/oblsk_characters/tests/character_model_spec.lua`, same shape (check `modules/oblsk_characters/tests/character_service_spec.lua`'s header first to match its exact `CORE_ROOT` path):

```lua
--- Unit tests for Character's HasPermissions wiring.
--- Run from the repository root:  lua5.4 tests/character_model_spec.lua
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
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(CORE_ROOT .. '/core/server/Traits/HasPermissions.lua')

-- Character.lua declares belongsTo(Account, ...)/hasOne(CharacterAppearance, ...)
-- relationships; the classes only need to exist as globals, never resolved
-- in these tests.
_G.Account = _G.Account or {}
_G.CharacterAppearance = _G.CharacterAppearance or {}

dofile(scriptDir .. '../server/models/Character.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

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

test('Character.permissionType is "character"', function()
    eq(Character.permissionType, 'character')
end)

test('a Character instance can grant and check its own permission', function()
    local tables = { characters = { { id = 11, account_id = 3, slot = 0, first_name = 'Jane', last_name = 'Doe' } } }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(function()
        local instance = Character:findSync(11)
        eq(instance:can('manage_bank'), false)
        instance:grant('manage_bank')
        truthy(instance:can('manage_bank'))
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

print('Running Character model unit tests\n')
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

- [ ] **Step 3: Run both tests to verify they fail**

Run: `cd modules/oblsk_accounts && lua5.4 tests/account_model_spec.lua`
Run: `cd modules/oblsk_characters && lua5.4 tests/character_model_spec.lua`
Expected: both FAIL — `Account.permissionType`/`Character.permissionType` is `nil`.

- [ ] **Step 4: Apply the trait in `Account.lua`**

Add one line at the end of `modules/oblsk_accounts/server/models/Account.lua`, immediately before `return Account`:

```lua
HasPermissions.apply(Account, 'account')

return Account
```

- [ ] **Step 5: Apply the trait in `Character.lua`**

Add one line at the end of `modules/oblsk_characters/server/models/Character.lua`, immediately before `return Character`:

```lua
HasPermissions.apply(Character, 'character')

return Character
```

- [ ] **Step 6: Run both tests to verify they pass**

Run: `cd modules/oblsk_accounts && lua5.4 tests/account_model_spec.lua`
Run: `cd modules/oblsk_characters && lua5.4 tests/character_model_spec.lua`
Expected: both `2 passed, 0 failed`

- [ ] **Step 7: Run each module's full existing test suite to confirm nothing else broke**

Run: `cd modules/oblsk_accounts && lua5.4 tests/account_service_spec.lua`
Run: `cd modules/oblsk_characters && lua5.4 tests/character_service_spec.lua`
Expected: both fully green, same pass counts as before this task.

- [ ] **Step 8: Commit**

```bash
git -C modules/oblsk_accounts add server/models/Account.lua tests/account_model_spec.lua
git -C modules/oblsk_accounts commit -m "feat: apply HasPermissions trait to Account"

git -C modules/oblsk_characters add server/models/Character.lua tests/character_model_spec.lua
git -C modules/oblsk_characters commit -m "feat: apply HasPermissions trait to Character"
```

---

## Task 5: `oblsk_organizations` scaffold + schema

**Files:**
- Create: `modules/oblsk_organizations/server/migrations/2026_08_11_080000_create_organizations_table.lua`
- Create: `modules/oblsk_organizations/server/migrations/2026_08_11_080001_create_departments_table.lua`
- Create: `modules/oblsk_organizations/server/migrations/2026_08_11_080002_create_ranks_table.lua`
- Create: `modules/oblsk_organizations/server/migrations/2026_08_11_080003_create_organization_memberships_table.lua`
- Create: `modules/oblsk_organizations/server/migrations/2026_08_11_080004_create_organization_department_members_table.lua`
- Create: `modules/oblsk_organizations/server/migrations.json`
- Create: `modules/oblsk_organizations/server/main.lua` (placeholder, filled in Task 9)
- Create: `modules/oblsk_organizations/README.md`
- Regenerate (not a git change): `modules/registry.json`

**Interfaces:**
- Produces: five tables (`organizations`, `departments`, `ranks`, `organization_memberships`, `organization_department_members`) that Tasks 6-8 build models/services on top of.

- [ ] **Step 1: Initialize `oblsk_organizations` as its own git repository**

Mirrors every existing module (`oblsk_accounts`, `oblsk_characters`, ...): `core`'s own `.gitignore` excludes `modules/*`, so this module is its own independent repo, not part of `core`'s history.

```bash
mkdir -p modules/oblsk_organizations
git init modules/oblsk_organizations
```

- [ ] **Step 2: Write the five migrations**

`modules/oblsk_organizations/server/migrations/2026_08_11_080000_create_organizations_table.lua`:

```lua
--- Migration: Create organizations table
return {
    up = function()
        Schema.create('organizations', function(table)
            table:id()
            table:string('name'):notNullable()
            table:timestamps()
        end)

        print('[Migration] Created organizations table')
    end,

    down = function()
        Schema.drop('organizations')
        print('[Migration] Dropped organizations table')
    end
}
```

`modules/oblsk_organizations/server/migrations/2026_08_11_080001_create_departments_table.lua`:

```lua
--- Migration: Create departments table
--- Pure grouping label within one organization. Not a hierarchy of its
--- own, permission checks go through HasPermissions once applied to the
--- Department model (see Task 6).
return {
    up = function()
        Schema.create('departments', function(table)
            table:id()
            table:integer('organization_id'):notNullable()
            table:string('name'):notNullable()
            table:timestamps()

            table:index({'organization_id'})
        end)

        print('[Migration] Created departments table')
    end,

    down = function()
        Schema.drop('departments')
        print('[Migration] Dropped departments table')
    end
}
```

`modules/oblsk_organizations/server/migrations/2026_08_11_080002_create_ranks_table.lua`:

```lua
--- Migration: Create ranks table
--- grade is the hierarchy level (higher = more senior), used for
--- promotion/demotion ordering. Permission checks go through
--- HasPermissions once applied to the Rank model (see Task 6), not grade
--- comparisons.
return {
    up = function()
        Schema.create('ranks', function(table)
            table:id()
            table:integer('organization_id'):notNullable()
            table:string('name'):notNullable()
            table:integer('grade'):notNullable():default(0)
            table:timestamps()

            table:index({'organization_id'})
        end)

        print('[Migration] Created ranks table')
    end,

    down = function()
        Schema.drop('ranks')
        print('[Migration] Dropped ranks table')
    end
}
```

`modules/oblsk_organizations/server/migrations/2026_08_11_080003_create_organization_memberships_table.lua`:

```lua
--- Migration: Create organization_memberships table
--- One row per character per organization they belong to. rank_id is
--- nullable: removing a rank a membership pointed at (OrganizationService.
--- removeRank) clears this to nil rather than deleting the membership or
--- cascading further.
return {
    up = function()
        Schema.create('organization_memberships', function(table)
            table:id()
            table:integer('character_id'):notNullable()
            table:integer('organization_id'):notNullable()
            table:integer('rank_id')
            table:timestamps()

            table:index({'character_id'})
            table:index({'organization_id'})
            table:unique({'character_id', 'organization_id'})
        end)

        print('[Migration] Created organization_memberships table')
    end,

    down = function()
        Schema.drop('organization_memberships')
        print('[Migration] Dropped organization_memberships table')
    end
}
```

`modules/oblsk_organizations/server/migrations/2026_08_11_080004_create_organization_department_members_table.lua`:

```lua
--- Migration: Create organization_department_members table
--- Many-to-many: a character (via their membership row) can belong to 0-n
--- departments within the organization they're already a member of.
return {
    up = function()
        Schema.create('organization_department_members', function(table)
            table:id()
            table:integer('membership_id'):notNullable()
            table:integer('department_id'):notNullable()
            table:timestamps()

            table:index({'membership_id'})
            table:index({'department_id'})
            table:unique({'membership_id', 'department_id'})
        end)

        print('[Migration] Created organization_department_members table')
    end,

    down = function()
        Schema.drop('organization_department_members')
        print('[Migration] Dropped organization_department_members table')
    end
}
```

- [ ] **Step 3: Write `migrations.json`**

`modules/oblsk_organizations/server/migrations.json`:

```json
{
  "migrations": [
    "2026_08_11_080000_create_organizations_table",
    "2026_08_11_080001_create_departments_table",
    "2026_08_11_080002_create_ranks_table",
    "2026_08_11_080003_create_organization_memberships_table",
    "2026_08_11_080004_create_organization_department_members_table"
  ]
}
```

- [ ] **Step 4: Write a placeholder `main.lua`**

`modules/oblsk_organizations/server/main.lua` (Task 9 fills in the real delegate wiring; this placeholder just makes the module a valid, loadable no-op until then):

```lua
--- oblsk_organizations - Server Main
--- See docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
print('[oblsk_organizations] Loading...')
print('[oblsk_organizations] Loaded successfully!')
```

- [ ] **Step 5: Write `README.md`**

`modules/oblsk_organizations/README.md`:

```markdown
# oblsk_organizations

In-game organizations (jobs like police/EMS, gangs) with departments and
ranks. Depends on `oblsk_characters` for `character_id`. See
`docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md`.
```

- [ ] **Step 6: Regenerate the module registry**

`modules/registry.json` is a generated, gitignored artifact (see `cli/commands/registry-generate.js`, added by an earlier `fold-modules-plugins` change) — it is scanned from the `modules/` directory on disk, never hand-edited or committed. Once `modules/oblsk_organizations/` exists on disk (Step 1), regenerate it:

```bash
node cli/index.js registry:generate
```

Expected: `modules/registry.json` now includes `"oblsk_organizations"` alongside the existing five.

- [ ] **Step 7: Verify every new Lua file parses**

Run:
```bash
for f in modules/oblsk_organizations/server/migrations/*.lua modules/oblsk_organizations/server/main.lua; do
  luac5.4 -p "$f" || echo "FAIL: $f"
done
```
Expected: no `FAIL` lines.

- [ ] **Step 8: Commit**

`modules/oblsk_organizations` is its own git repo (Step 1), independent of `core`'s. `modules/registry.json` is gitignored/generated (Step 6) — nothing to commit for it, in either repo:

```bash
git -C modules/oblsk_organizations add .
git -C modules/oblsk_organizations commit -m "feat: scaffold oblsk_organizations module (schema for orgs/departments/ranks/memberships)"
```

---

## Task 6: `Department`/`Rank` models with `HasPermissions`

**Files:**
- Create: `modules/oblsk_organizations/server/models/Department.lua`
- Create: `modules/oblsk_organizations/server/models/Rank.lua`
- Test: `modules/oblsk_organizations/tests/department_rank_model_spec.lua`

**Interfaces:**
- Consumes: `HasPermissions.apply` (Task 3).
- Produces: `Department.permissionType == 'department'`, `Rank.permissionType == 'rank'`, both usable via `:can/:grant/:revoke/:permissionList`; `Department`/`Rank` as `BaseModel` subclasses Task 7 uses for CRUD.

- [ ] **Step 1: Write the failing test**

`modules/oblsk_organizations/tests/department_rank_model_spec.lua`:

```lua
--- Unit tests for Department/Rank's HasPermissions wiring.
--- Run from the repository root:  lua5.4 tests/department_rank_model_spec.lua
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
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(CORE_ROOT .. '/core/server/Traits/HasPermissions.lua')
dofile(scriptDir .. '../server/models/Department.lua')
dofile(scriptDir .. '../server/models/Rank.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

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

test('Department.permissionType is "department"', function()
    eq(Department.permissionType, 'department')
end)

test('Rank.permissionType is "rank"', function()
    eq(Rank.permissionType, 'rank')
end)

test('a Department instance can grant and check its own permission', function()
    local tables = { departments = { { id = 1, organization_id = 1, name = 'SWAT' } } }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(function()
        local instance = Department:findSync(1)
        eq(instance:can('deploy_swat'), false)
        instance:grant('deploy_swat')
        truthy(instance:can('deploy_swat'))
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

test('a Rank instance can grant and check its own permission', function()
    local tables = { ranks = { { id = 1, organization_id = 1, name = 'Sergeant', grade = 3 } } }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(function()
        local instance = Rank:findSync(1)
        eq(instance:can('manage_bank'), false)
        instance:grant('manage_bank')
        truthy(instance:can('manage_bank'))
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

print('Running Department/Rank model unit tests\n')
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

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/oblsk_organizations && lua5.4 tests/department_rank_model_spec.lua`
Expected: FAIL — `server/models/Department.lua` does not exist yet.

- [ ] **Step 3: Write `Department.lua`**

```lua
--- Department Model - a pure grouping label within one Organization. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
Department = BaseModel:extend('departments')

Department.primaryKey = 'id'
Department.timestamps = true
Department.fillable = { 'organization_id', 'name' }
Department.hidden = {}

HasPermissions.apply(Department, 'department')

return Department
```

- [ ] **Step 4: Write `Rank.lua`**

```lua
--- Rank Model - one hierarchy level within one Organization. grade is the
--- ordering (higher = more senior); permission checks go through
--- HasPermissions, not grade comparisons. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
Rank = BaseModel:extend('ranks')

Rank.primaryKey = 'id'
Rank.timestamps = true
Rank.fillable = { 'organization_id', 'name', 'grade' }
Rank.hidden = {}

HasPermissions.apply(Rank, 'rank')

return Rank
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd modules/oblsk_organizations && lua5.4 tests/department_rank_model_spec.lua`
Expected: `4 passed, 0 failed`

- [ ] **Step 6: Verify syntax and commit**

Run: `luac5.4 -p modules/oblsk_organizations/server/models/Department.lua modules/oblsk_organizations/server/models/Rank.lua`
Expected: no output, exit code 0.

```bash
git -C modules/oblsk_organizations add server/models tests/department_rank_model_spec.lua
git -C modules/oblsk_organizations commit -m "feat: add Department/Rank models with HasPermissions"
```

---

## Task 7: `OrganizationService` — organization/department/rank CRUD

**Files:**
- Create: `modules/oblsk_organizations/server/services/OrganizationService.lua`
- Create: `modules/oblsk_organizations/tests/support/fake_query_builder.lua`
- Test: `modules/oblsk_organizations/tests/organization_service_crud_spec.lua`

**Interfaces:**
- Produces: `OrganizationService.create(name) -> orgId`, `.rename(orgId, name)`, `.delete(orgId)`, `.addDepartment(orgId, name) -> deptId`, `.removeDepartment(deptId)`, `.addRank(orgId, name, grade) -> rankId`, `.removeRank(rankId)`. These are consumed directly by Task 8 (membership) and Task 10 (commands).

- [ ] **Step 1: Copy the fake QueryBuilder test support file**

`modules/oblsk_organizations/tests/support/fake_query_builder.lua` — identical content to `tests/support/fake_query_builder.lua` from Task 1 (same file, copied into this module's own `tests/support/`, following the same one-copy-per-module convention every other module in this repo already uses).

- [ ] **Step 2: Write the failing tests**

`modules/oblsk_organizations/tests/organization_service_crud_spec.lua`:

```lua
--- Unit tests for OrganizationService: organization/department/rank CRUD.
--- Membership and department-membership behavior is covered in
--- organization_service_membership_spec.lua (Task 8).
--- Run from the repository root:  lua5.4 tests/organization_service_crud_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(scriptDir .. '../server/services/OrganizationService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('create: inserts an organization row and returns its id', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('Los Santos Police Department')
        eq(#tables.organizations, 1)
        eq(tables.organizations[1].id, orgId)
        eq(tables.organizations[1].name, 'Los Santos Police Department')
    end)
end)

test('rename: updates the organization name', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        OrganizationService.rename(orgId, 'Los Santos Police Department')
        eq(tables.organizations[1].name, 'Los Santos Police Department')
    end)
end)

test('delete: removes the organization and its departments/ranks/memberships', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        OrganizationService.addDepartment(orgId, 'SWAT')
        OrganizationService.addRank(orgId, 'Sergeant', 3)
        QueryBuilder.new('organization_memberships'):insert({
            character_id = 1, organization_id = orgId, rank_id = nil,
            created_at = Database.now(), updated_at = Database.now(),
        })

        OrganizationService.delete(orgId)

        eq(#tables.organizations, 0)
        eq(#tables.departments, 0)
        eq(#tables.ranks, 0)
        eq(#tables.organization_memberships, 0)
    end)
end)

test('addDepartment: inserts a department scoped to the organization', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local deptId = OrganizationService.addDepartment(orgId, 'SWAT')

        eq(#tables.departments, 1)
        eq(tables.departments[1].id, deptId)
        eq(tables.departments[1].organization_id, orgId)
        eq(tables.departments[1].name, 'SWAT')
    end)
end)

test('removeDepartment: removes the department and its department-member rows', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local deptId = OrganizationService.addDepartment(orgId, 'SWAT')
        QueryBuilder.new('organization_department_members'):insert({
            membership_id = 1, department_id = deptId,
            created_at = Database.now(), updated_at = Database.now(),
        })

        OrganizationService.removeDepartment(deptId)

        eq(#tables.departments, 0)
        eq(#tables.organization_department_members, 0)
    end)
end)

test('addRank: inserts a rank scoped to the organization with the given grade', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Sergeant', 3)

        eq(#tables.ranks, 1)
        eq(tables.ranks[1].id, rankId)
        eq(tables.ranks[1].organization_id, orgId)
        eq(tables.ranks[1].name, 'Sergeant')
        eq(tables.ranks[1].grade, 3)
    end)
end)

test('removeRank: removes the rank and nils out rank_id on any membership that held it', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Sergeant', 3)
        local membershipId = QueryBuilder.new('organization_memberships'):insert({
            character_id = 1, organization_id = orgId, rank_id = rankId,
            created_at = Database.now(), updated_at = Database.now(),
        })

        OrganizationService.removeRank(rankId)

        eq(#tables.ranks, 0)
        local membership = QueryBuilder.new('organization_memberships'):where('id', membershipId):firstSync()
        eq(membership.rank_id, nil)
    end)
end)

print('Running OrganizationService CRUD unit tests\n')
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

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd modules/oblsk_organizations && lua5.4 tests/organization_service_crud_spec.lua`
Expected: FAIL — `server/services/OrganizationService.lua` does not exist yet.

- [ ] **Step 4: Write `OrganizationService.lua` (CRUD portion)**

```lua
--- OrganizationService (server) - organizations, their departments and
--- ranks, and character membership within them. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
OrganizationService = {}

--- Whether a character may hold membership in more than one organization
--- at once. This framework has no Config global convention (see the plan's
--- Global Constraints), so this is a plain constant, edit directly.
OrganizationService.ALLOW_MULTIPLE_MEMBERSHIPS = false

--- @param name string
--- @return number orgId
function OrganizationService.create(name)
    return QueryBuilder.new('organizations'):insert({
        name = name,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param orgId number
--- @param name string
function OrganizationService.rename(orgId, name)
    QueryBuilder.new('organizations'):where('id', orgId):update({
        name = name,
        updated_at = Database.now(),
    })
end

--- Cascades: removes this organization's departments, ranks, memberships,
--- and department-member rows, so nothing is left pointing at a deleted
--- organization_id.
--- @param orgId number
function OrganizationService.delete(orgId)
    local memberships = QueryBuilder.new('organization_memberships'):where('organization_id', orgId):getSync()
    for _, membership in ipairs(memberships) do
        QueryBuilder.new('organization_department_members'):where('membership_id', membership.id):delete()
    end
    QueryBuilder.new('organization_memberships'):where('organization_id', orgId):delete()
    QueryBuilder.new('departments'):where('organization_id', orgId):delete()
    QueryBuilder.new('ranks'):where('organization_id', orgId):delete()
    QueryBuilder.new('organizations'):where('id', orgId):delete()
end

--- @param orgId number
--- @param name string
--- @return number deptId
function OrganizationService.addDepartment(orgId, name)
    return QueryBuilder.new('departments'):insert({
        organization_id = orgId,
        name = name,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- Cascades: removes this department's department-member rows.
--- @param deptId number
function OrganizationService.removeDepartment(deptId)
    QueryBuilder.new('organization_department_members'):where('department_id', deptId):delete()
    QueryBuilder.new('departments'):where('id', deptId):delete()
end

--- @param orgId number
--- @param name string
--- @param grade number higher = more senior
--- @return number rankId
function OrganizationService.addRank(orgId, name, grade)
    return QueryBuilder.new('ranks'):insert({
        organization_id = orgId,
        name = name,
        grade = grade,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- Does not kick anyone from the organization: any membership that held
--- this rank has its rank_id set to nil instead, they simply have no rank
--- until OrganizationService.setRank (Task 8) gives them a new one.
--- @param rankId number
function OrganizationService.removeRank(rankId)
    QueryBuilder.new('organization_memberships'):where('rank_id', rankId):update({ rank_id = Database.NULL })
    QueryBuilder.new('ranks'):where('id', rankId):delete()
end

return OrganizationService
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd modules/oblsk_organizations && lua5.4 tests/organization_service_crud_spec.lua`
Expected: `7 passed, 0 failed`

- [ ] **Step 6: Verify syntax and commit**

Run: `luac5.4 -p modules/oblsk_organizations/server/services/OrganizationService.lua`
Expected: no output, exit code 0.

```bash
git -C modules/oblsk_organizations add server/services/OrganizationService.lua \
        tests/support/fake_query_builder.lua \
        tests/organization_service_crud_spec.lua
git -C modules/oblsk_organizations commit -m "feat: add OrganizationService organization/department/rank CRUD"
```

---

## Task 8: `OrganizationService` — membership + department membership

**Files:**
- Modify: `modules/oblsk_organizations/server/services/OrganizationService.lua`
- Test: `modules/oblsk_organizations/tests/organization_service_membership_spec.lua`

**Interfaces:**
- Consumes: `OrganizationService.create/addDepartment/addRank` (Task 7).
- Produces: `OrganizationService.join(characterId, orgId, rankId)`, `.leave(characterId, orgId)`, `.setRank(characterId, orgId, rankId)`, `.joinDepartment(characterId, orgId, deptId)`, `.leaveDepartment(characterId, orgId, deptId)`, `.getMembership(characterId, orgId) -> { organization_id, rank_id, department_ids } | nil`, `.getMemberships(characterId) -> table[]` (same shape as `getMembership`'s non-nil return, one per org). Task 9's delegate resolver calls `getMemberships` directly.

- [ ] **Step 1: Write the failing tests**

`modules/oblsk_organizations/tests/organization_service_membership_spec.lua`:

```lua
--- Unit tests for OrganizationService: membership and department
--- membership. Organization/department/rank CRUD is covered in
--- organization_service_crud_spec.lua (Task 7).
--- Run from the repository root:  lua5.4 tests/organization_service_membership_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(scriptDir .. '../server/services/OrganizationService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

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

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    OrganizationService.ALLOW_MULTIPLE_MEMBERSHIPS = false

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('join: creates a membership with the given rank', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Sergeant', 3)

        OrganizationService.join(1, orgId, rankId)

        eq(#tables.organization_memberships, 1)
        eq(tables.organization_memberships[1].character_id, 1)
        eq(tables.organization_memberships[1].organization_id, orgId)
        eq(tables.organization_memberships[1].rank_id, rankId)
    end)
end)

test('join: with ALLOW_MULTIPLE_MEMBERSHIPS false, joining a new org removes the old membership', function()
    withFakeDb(function(tables)
        local orgA = OrganizationService.create('LSPD')
        local orgB = OrganizationService.create('Ballas')
        local rankA = OrganizationService.addRank(orgA, 'Officer', 1)
        local rankB = OrganizationService.addRank(orgB, 'Member', 1)

        OrganizationService.join(1, orgA, rankA)
        OrganizationService.join(1, orgB, rankB)

        eq(#tables.organization_memberships, 1)
        eq(tables.organization_memberships[1].organization_id, orgB)
    end)
end)

test('join: with ALLOW_MULTIPLE_MEMBERSHIPS true, a character can hold two memberships', function()
    withFakeDb(function(tables)
        OrganizationService.ALLOW_MULTIPLE_MEMBERSHIPS = true

        local orgA = OrganizationService.create('LSPD')
        local orgB = OrganizationService.create('Ballas')
        local rankA = OrganizationService.addRank(orgA, 'Officer', 1)
        local rankB = OrganizationService.addRank(orgB, 'Member', 1)

        OrganizationService.join(1, orgA, rankA)
        OrganizationService.join(1, orgB, rankB)

        eq(#tables.organization_memberships, 2)
    end)
end)

test('leave: removes the membership and its department-member rows', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Officer', 1)
        local deptId = OrganizationService.addDepartment(orgId, 'Patrol')

        OrganizationService.join(1, orgId, rankId)
        OrganizationService.joinDepartment(1, orgId, deptId)

        OrganizationService.leave(1, orgId)

        eq(#tables.organization_memberships, 0)
        eq(#tables.organization_department_members, 0)
    end)
end)

test('setRank: changes rank_id on the existing membership', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local rankA = OrganizationService.addRank(orgId, 'Officer', 1)
        local rankB = OrganizationService.addRank(orgId, 'Sergeant', 3)

        OrganizationService.join(1, orgId, rankA)
        OrganizationService.setRank(1, orgId, rankB)

        eq(tables.organization_memberships[1].rank_id, rankB)
    end)
end)

test('joinDepartment: adds the character to a department within their org', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Officer', 1)
        local deptId = OrganizationService.addDepartment(orgId, 'SWAT')

        OrganizationService.join(1, orgId, rankId)
        OrganizationService.joinDepartment(1, orgId, deptId)

        eq(#tables.organization_department_members, 1)
        eq(tables.organization_department_members[1].department_id, deptId)
    end)
end)

test('joinDepartment: is a no-op if the character has no membership in that org', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local deptId = OrganizationService.addDepartment(orgId, 'SWAT')

        OrganizationService.joinDepartment(1, orgId, deptId)

        eq(#tables.organization_department_members, 0)
    end)
end)

test('leaveDepartment: removes just that department-member row', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Officer', 1)
        local dept1 = OrganizationService.addDepartment(orgId, 'SWAT')
        local dept2 = OrganizationService.addDepartment(orgId, 'Patrol')

        OrganizationService.join(1, orgId, rankId)
        OrganizationService.joinDepartment(1, orgId, dept1)
        OrganizationService.joinDepartment(1, orgId, dept2)

        OrganizationService.leaveDepartment(1, orgId, dept1)

        eq(#tables.organization_department_members, 1)
        eq(tables.organization_department_members[1].department_id, dept2)
    end)
end)

test('getMembership: returns organization_id, rank_id, and department_ids', function()
    withFakeDb(function()
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Officer', 1)
        local deptId = OrganizationService.addDepartment(orgId, 'SWAT')

        OrganizationService.join(1, orgId, rankId)
        OrganizationService.joinDepartment(1, orgId, deptId)

        local membership = OrganizationService.getMembership(1, orgId)
        eq(membership.organization_id, orgId)
        eq(membership.rank_id, rankId)
        eq(#membership.department_ids, 1)
        eq(membership.department_ids[1], deptId)
    end)
end)

test('getMembership: returns nil for an org the character never joined', function()
    withFakeDb(function()
        local orgId = OrganizationService.create('LSPD')
        eq(OrganizationService.getMembership(1, orgId), nil)
    end)
end)

test('getMemberships: returns one entry per org the character belongs to', function()
    withFakeDb(function()
        OrganizationService.ALLOW_MULTIPLE_MEMBERSHIPS = true

        local orgA = OrganizationService.create('LSPD')
        local orgB = OrganizationService.create('Ballas')
        local rankA = OrganizationService.addRank(orgA, 'Officer', 1)
        local rankB = OrganizationService.addRank(orgB, 'Member', 1)

        OrganizationService.join(1, orgA, rankA)
        OrganizationService.join(1, orgB, rankB)

        local memberships = OrganizationService.getMemberships(1)
        eq(#memberships, 2)
    end)
end)

print('Running OrganizationService membership unit tests\n')
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

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd modules/oblsk_organizations && lua5.4 tests/organization_service_membership_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'join')`.

- [ ] **Step 3: Add the membership functions to `OrganizationService.lua`**

Append to `modules/oblsk_organizations/server/services/OrganizationService.lua`, before `return OrganizationService`:

```lua
--- @param characterId number
--- @param orgId number
--- @param rankId number
function OrganizationService.join(characterId, orgId, rankId)
    if not OrganizationService.ALLOW_MULTIPLE_MEMBERSHIPS then
        local existing = QueryBuilder.new('organization_memberships'):where('character_id', characterId):getSync()
        for _, membership in ipairs(existing) do
            OrganizationService.leave(characterId, membership.organization_id)
        end
    end

    QueryBuilder.new('organization_memberships'):insert({
        character_id = characterId,
        organization_id = orgId,
        rank_id = rankId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- Cascades: removes this membership's department-member rows.
--- @param characterId number
--- @param orgId number
function OrganizationService.leave(characterId, orgId)
    local membership = QueryBuilder.new('organization_memberships')
        :where('character_id', characterId):where('organization_id', orgId):firstSync()
    if not membership then
        return
    end

    QueryBuilder.new('organization_department_members'):where('membership_id', membership.id):delete()
    QueryBuilder.new('organization_memberships'):where('id', membership.id):delete()
end

--- No-op if the character has no membership in this org.
--- @param characterId number
--- @param orgId number
--- @param rankId number
function OrganizationService.setRank(characterId, orgId, rankId)
    QueryBuilder.new('organization_memberships')
        :where('character_id', characterId):where('organization_id', orgId)
        :update({ rank_id = rankId, updated_at = Database.now() })
end

--- No-op if the character has no membership in this org (joining a
--- department without an existing membership is not an implicit join).
--- @param characterId number
--- @param orgId number
--- @param deptId number
function OrganizationService.joinDepartment(characterId, orgId, deptId)
    local membership = QueryBuilder.new('organization_memberships')
        :where('character_id', characterId):where('organization_id', orgId):firstSync()
    if not membership then
        return
    end

    local existing = QueryBuilder.new('organization_department_members')
        :where('membership_id', membership.id):where('department_id', deptId):firstSync()
    if existing then
        return
    end

    QueryBuilder.new('organization_department_members'):insert({
        membership_id = membership.id,
        department_id = deptId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param characterId number
--- @param orgId number
--- @param deptId number
function OrganizationService.leaveDepartment(characterId, orgId, deptId)
    local membership = QueryBuilder.new('organization_memberships')
        :where('character_id', characterId):where('organization_id', orgId):firstSync()
    if not membership then
        return
    end

    QueryBuilder.new('organization_department_members')
        :where('membership_id', membership.id):where('department_id', deptId):delete()
end

--- @param characterId number
--- @param orgId number
--- @return table|nil { organization_id, rank_id, department_ids } or nil if no membership
function OrganizationService.getMembership(characterId, orgId)
    local membership = QueryBuilder.new('organization_memberships')
        :where('character_id', characterId):where('organization_id', orgId):firstSync()
    if not membership then
        return nil
    end

    local deptRows = QueryBuilder.new('organization_department_members')
        :where('membership_id', membership.id):getSync()
    local departmentIds = {}
    for _, row in ipairs(deptRows) do
        table.insert(departmentIds, row.department_id)
    end

    return {
        organization_id = membership.organization_id,
        rank_id = membership.rank_id,
        department_ids = departmentIds,
    }
end

--- @param characterId number
--- @return table[] one entry per org the character belongs to, same shape as getMembership's non-nil return
function OrganizationService.getMemberships(characterId)
    local rows = QueryBuilder.new('organization_memberships'):where('character_id', characterId):getSync()

    local memberships = {}
    for _, row in ipairs(rows) do
        table.insert(memberships, OrganizationService.getMembership(characterId, row.organization_id))
    end
    return memberships
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd modules/oblsk_organizations && lua5.4 tests/organization_service_membership_spec.lua`
Expected: `10 passed, 0 failed`

- [ ] **Step 5: Run the CRUD spec too, to confirm nothing regressed**

Run: `cd modules/oblsk_organizations && lua5.4 tests/organization_service_crud_spec.lua`
Expected: `7 passed, 0 failed`

- [ ] **Step 6: Verify syntax and commit**

Run: `luac5.4 -p modules/oblsk_organizations/server/services/OrganizationService.lua`
Expected: no output, exit code 0.

```bash
git -C modules/oblsk_organizations add server/services/OrganizationService.lua \
        tests/organization_service_membership_spec.lua
git -C modules/oblsk_organizations commit -m "feat: add OrganizationService membership and department-membership"
```

---

## Task 9: Wire the `character` permission delegate

**Files:**
- Modify: `modules/oblsk_organizations/server/main.lua`
- Test: `modules/oblsk_organizations/tests/character_delegate_spec.lua`

**Interfaces:**
- Consumes: `PermissionService.addDelegate/can` (Task 2), `HasPermissions`-equipped `Rank`/`Department` (Task 6), `OrganizationService.getMemberships` (Task 8).
- Produces: the registered delegate itself — no new function signature, this is the integration point the whole design exists for.

- [ ] **Step 1: Write the failing test**

`modules/oblsk_organizations/tests/character_delegate_spec.lua` — this is the end-to-end proof that a grant on a `Rank` or `Department` becomes visible through `PermissionService.can('character', characterId, key)`, without ever touching a `Character` model:

```lua
--- Integration test: the character permission delegate this module
--- registers at boot (main.lua) makes PermissionService.can('character', ...)
--- see grants made to a character's rank or departments.
--- Run from the repository root:  lua5.4 tests/character_delegate_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(scriptDir .. '../server/services/OrganizationService.lua')

-- registerType('rank'/'department', ...) is normally done by HasPermissions
-- via the real Department/Rank models (Task 6); this test only needs the
-- delegate wiring from main.lua, so it registers the two types directly
-- rather than loading BaseModel/Schema/the real model files too.
PermissionService.registerType('rank', {})
PermissionService.registerType('department', {})
PermissionService.registerType('character', {})

dofile(scriptDir .. '../server/main.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

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

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('a grant on a character\'s rank is visible via PermissionService.can("character", ...)', function()
    withFakeDb(function()
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Sergeant', 3)
        OrganizationService.join(1, orgId, rankId)

        eq(PermissionService.can('character', 1, 'manage_bank'), false)
        PermissionService.grant('rank', rankId, 'manage_bank')
        truthy(PermissionService.can('character', 1, 'manage_bank'))
    end)
end)

test('a grant on a character\'s department is visible via PermissionService.can("character", ...)', function()
    withFakeDb(function()
        local orgId = OrganizationService.create('LSPD')
        local rankId = OrganizationService.addRank(orgId, 'Officer', 1)
        local deptId = OrganizationService.addDepartment(orgId, 'SWAT')
        OrganizationService.join(1, orgId, rankId)
        OrganizationService.joinDepartment(1, orgId, deptId)

        eq(PermissionService.can('character', 1, 'deploy_swat'), false)
        PermissionService.grant('department', deptId, 'deploy_swat')
        truthy(PermissionService.can('character', 1, 'deploy_swat'))
    end)
end)

test('a character with no membership at all is simply never granted anything via the delegate', function()
    withFakeDb(function()
        eq(PermissionService.can('character', 999, 'manage_bank'), false)
    end)
end)

print('Running character permission delegate integration tests\n')
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

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd modules/oblsk_organizations && lua5.4 tests/character_delegate_spec.lua`
Expected: FAIL — `can('character', ...)` stays `false` after granting, since no delegate is registered yet.

- [ ] **Step 3: Add the delegate registration to `main.lua`**

Replace the placeholder body of `modules/oblsk_organizations/server/main.lua`:

```lua
--- oblsk_organizations - Server Main
--- Registers the character permission delegate: any character's rank and
--- departments extend what PermissionService.can('character', ...) means,
--- without oblsk_characters ever depending on this module. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
print('[oblsk_organizations] Loading...')

PermissionService.addDelegate('character', function(characterId)
    local refs = {}
    for _, membership in ipairs(OrganizationService.getMemberships(characterId)) do
        if membership.rank_id then
            table.insert(refs, { type = 'rank', id = membership.rank_id })
        end
        for _, deptId in ipairs(membership.department_ids) do
            table.insert(refs, { type = 'department', id = deptId })
        end
    end
    return refs
end)

print('[oblsk_organizations] Loaded successfully!')
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd modules/oblsk_organizations && lua5.4 tests/character_delegate_spec.lua`
Expected: `3 passed, 0 failed`

- [ ] **Step 5: Run every other spec in this module to confirm nothing regressed**

Run:
```bash
cd modules/oblsk_organizations
for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAIL: $f"; done
```
Expected: no `FAIL` lines, every spec still green.

- [ ] **Step 6: Verify syntax and commit**

Run: `luac5.4 -p modules/oblsk_organizations/server/main.lua`
Expected: no output, exit code 0.

```bash
git -C modules/oblsk_organizations add server/main.lua tests/character_delegate_spec.lua
git -C modules/oblsk_organizations commit -m "feat: wire the character permission delegate (ranks + departments)"
```

---

## Task 10: Admin commands

**Files:**
- Create: `modules/oblsk_organizations/server/commands/OrganizationCommands.lua`

**Interfaces:**
- Consumes: `OrganizationService.*` (Tasks 7-8), `PermissionService.grant/revoke` (Task 1), `CharacterService.getActiveCharacterId` (external module, plain global, same as `AccountCommands`' use of `AccountService.getAccountId`).

- [ ] **Step 1: Write `OrganizationCommands.lua`**

```lua
--- oblsk_organizations - Admin Commands
--- Minimum viable surface for managing orgs/departments/ranks/memberships
--- without a UI. Every command resolves <serverId> to a character_id via
--- CharacterService.getActiveCharacterId, same pattern oblsk_accounts'
--- AccountCommands uses for accounts.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

RegisterCommand('org-create', function(source, args)
    if not isAdmin(source) then return end

    local name = table.concat(args, ' ')
    if name == '' then
        print('Usage: /org-create <name>')
        return
    end

    local orgId = OrganizationService.create(name)
    print('[oblsk_organizations] created organization #' .. orgId .. ': ' .. name)
end, false)

RegisterCommand('org-delete', function(source, args)
    if not isAdmin(source) then return end

    local orgId = tonumber(args[1])
    if not orgId then
        print('Usage: /org-delete <orgId>')
        return
    end

    OrganizationService.delete(orgId)
    print('[oblsk_organizations] deleted organization #' .. orgId)
end, false)

RegisterCommand('org-adddept', function(source, args)
    if not isAdmin(source) then return end

    local orgId = tonumber(args[1])
    local name = table.concat(args, ' ', 2)
    if not orgId or name == '' then
        print('Usage: /org-adddept <orgId> <name>')
        return
    end

    local deptId = OrganizationService.addDepartment(orgId, name)
    print('[oblsk_organizations] added department #' .. deptId .. ' (' .. name .. ') to org #' .. orgId)
end, false)

RegisterCommand('org-removedept', function(source, args)
    if not isAdmin(source) then return end

    local deptId = tonumber(args[1])
    if not deptId then
        print('Usage: /org-removedept <deptId>')
        return
    end

    OrganizationService.removeDepartment(deptId)
    print('[oblsk_organizations] removed department #' .. deptId)
end, false)

RegisterCommand('org-addrank', function(source, args)
    if not isAdmin(source) then return end

    local orgId = tonumber(args[1])
    local grade = tonumber(args[2])
    local name = table.concat(args, ' ', 3)
    if not orgId or not grade or name == '' then
        print('Usage: /org-addrank <orgId> <grade> <name>')
        return
    end

    local rankId = OrganizationService.addRank(orgId, name, grade)
    print('[oblsk_organizations] added rank #' .. rankId .. ' (' .. name .. ', grade ' .. grade .. ') to org #' .. orgId)
end, false)

RegisterCommand('org-removerank', function(source, args)
    if not isAdmin(source) then return end

    local rankId = tonumber(args[1])
    if not rankId then
        print('Usage: /org-removerank <rankId>')
        return
    end

    OrganizationService.removeRank(rankId)
    print('[oblsk_organizations] removed rank #' .. rankId)
end, false)

RegisterCommand('org-join', function(source, args)
    if not isAdmin(source) then return end

    local targetId = tonumber(args[1])
    local orgId = tonumber(args[2])
    local rankId = tonumber(args[3])
    if not targetId or not orgId or not rankId then
        print('Usage: /org-join <serverId> <orgId> <rankId>')
        return
    end

    local characterId = CharacterService.getActiveCharacterId(targetId)
    if not characterId then
        print('[oblsk_organizations] player ' .. targetId .. ' has no active character')
        return
    end

    OrganizationService.join(characterId, orgId, rankId)
    print('[oblsk_organizations] character ' .. characterId .. ' joined org #' .. orgId)
end, false)

RegisterCommand('org-leave', function(source, args)
    if not isAdmin(source) then return end

    local targetId = tonumber(args[1])
    local orgId = tonumber(args[2])
    if not targetId or not orgId then
        print('Usage: /org-leave <serverId> <orgId>')
        return
    end

    local characterId = CharacterService.getActiveCharacterId(targetId)
    if not characterId then
        print('[oblsk_organizations] player ' .. targetId .. ' has no active character')
        return
    end

    OrganizationService.leave(characterId, orgId)
    print('[oblsk_organizations] character ' .. characterId .. ' left org #' .. orgId)
end, false)

RegisterCommand('org-setrank', function(source, args)
    if not isAdmin(source) then return end

    local targetId = tonumber(args[1])
    local orgId = tonumber(args[2])
    local rankId = tonumber(args[3])
    if not targetId or not orgId or not rankId then
        print('Usage: /org-setrank <serverId> <orgId> <rankId>')
        return
    end

    local characterId = CharacterService.getActiveCharacterId(targetId)
    if not characterId then
        print('[oblsk_organizations] player ' .. targetId .. ' has no active character')
        return
    end

    OrganizationService.setRank(characterId, orgId, rankId)
    print('[oblsk_organizations] set character ' .. characterId .. '\'s rank in org #' .. orgId .. ' to #' .. rankId)
end, false)

RegisterCommand('org-adddeptmember', function(source, args)
    if not isAdmin(source) then return end

    local targetId = tonumber(args[1])
    local orgId = tonumber(args[2])
    local deptId = tonumber(args[3])
    if not targetId or not orgId or not deptId then
        print('Usage: /org-adddeptmember <serverId> <orgId> <deptId>')
        return
    end

    local characterId = CharacterService.getActiveCharacterId(targetId)
    if not characterId then
        print('[oblsk_organizations] player ' .. targetId .. ' has no active character')
        return
    end

    OrganizationService.joinDepartment(characterId, orgId, deptId)
    print('[oblsk_organizations] added character ' .. characterId .. ' to department #' .. deptId)
end, false)

RegisterCommand('org-removedeptmember', function(source, args)
    if not isAdmin(source) then return end

    local targetId = tonumber(args[1])
    local orgId = tonumber(args[2])
    local deptId = tonumber(args[3])
    if not targetId or not orgId or not deptId then
        print('Usage: /org-removedeptmember <serverId> <orgId> <deptId>')
        return
    end

    local characterId = CharacterService.getActiveCharacterId(targetId)
    if not characterId then
        print('[oblsk_organizations] player ' .. targetId .. ' has no active character')
        return
    end

    OrganizationService.leaveDepartment(characterId, orgId, deptId)
    print('[oblsk_organizations] removed character ' .. characterId .. ' from department #' .. deptId)
end, false)

RegisterCommand('org-grant', function(source, args)
    if not isAdmin(source) then return end

    local ownerType = args[1]
    local ownerId = tonumber(args[2])
    local key = args[3]
    if not ownerType or not ownerId or not key then
        print('Usage: /org-grant <ownerType> <ownerId> <key>')
        return
    end

    PermissionService.grant(ownerType, ownerId, key)
    print('[oblsk_organizations] granted "' .. key .. '" to ' .. ownerType .. ' #' .. ownerId)
end, false)

RegisterCommand('org-revoke', function(source, args)
    if not isAdmin(source) then return end

    local ownerType = args[1]
    local ownerId = tonumber(args[2])
    local key = args[3]
    if not ownerType or not ownerId or not key then
        print('Usage: /org-revoke <ownerType> <ownerId> <key>')
        return
    end

    PermissionService.revoke(ownerType, ownerId, key)
    print('[oblsk_organizations] revoked "' .. key .. '" from ' .. ownerType .. ' #' .. ownerId)
end, false)
```

- [ ] **Step 2: Verify syntax**

Run: `luac5.4 -p modules/oblsk_organizations/server/commands/OrganizationCommands.lua`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git -C modules/oblsk_organizations add server/commands/OrganizationCommands.lua
git -C modules/oblsk_organizations commit -m "feat: add oblsk_organizations admin commands"
```

---

## Task 11: Whole-plan verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run every spec this plan touched or added**

```bash
lua5.4 tests/permission_service_spec.lua && lua5.4 tests/has_permissions_spec.lua
cd modules/oblsk_accounts && lua5.4 tests/account_model_spec.lua && lua5.4 tests/account_service_spec.lua
cd modules/oblsk_characters && lua5.4 tests/character_model_spec.lua && lua5.4 tests/character_service_spec.lua
cd modules/oblsk_organizations && for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAIL: $f"; done
```
Expected: every command prints its own `N passed, 0 failed`, no `FAIL` lines.

- [ ] **Step 2: Syntax-check every new/modified Lua file in one pass**

```bash
for f in \
  core/server/database/migrations/2026_08_11_070000_create_permissions_table.lua \
  core/server/Services/PermissionService.lua \
  core/server/Traits/HasPermissions.lua \
  modules/oblsk_accounts/server/models/Account.lua \
  modules/oblsk_characters/server/models/Character.lua \
  modules/oblsk_organizations/server/migrations/*.lua \
  modules/oblsk_organizations/server/main.lua \
  modules/oblsk_organizations/server/models/*.lua \
  modules/oblsk_organizations/server/services/OrganizationService.lua \
  modules/oblsk_organizations/server/commands/OrganizationCommands.lua \
  ; do
  luac5.4 -p "$f" || echo "FAIL: $f"
done
```
Expected: no `FAIL` lines.

- [ ] **Step 3: Confirm `modules/registry.json` and both `migrations.json` files are valid JSON**

```bash
python3 -c "import json; json.load(open('modules/registry.json'))" && echo OK
python3 -c "import json; json.load(open('core/server/database/migrations.json'))" && echo OK
python3 -c "import json; json.load(open('modules/oblsk_organizations/server/migrations.json'))" && echo OK
```
Expected: three `OK` lines.

No commit for this task — it is a verification pass over commits already made in Tasks 1-10.
