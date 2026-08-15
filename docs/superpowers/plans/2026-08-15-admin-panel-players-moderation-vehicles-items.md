# Admin Panel — Players, Moderation, Vehicles, Items Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up the Players, Moderation, Vehicles, and Items tabs of the `oblsk_admin` Staff Panel, which currently render the shared `ComingSoon` placeholder.

**Architecture:** Each tab follows the exact three-hop NUI pattern the Organisations tab already established: Vue emits an `admin:client:<tab>-<verb>` NUI event → `oblsk_admin/client/main.lua` relays it verbatim to `admin:server:<tab>-<verb>` → a new per-tab server handler file in `oblsk_admin/server/` (guarded by a local `isAdmin(source)` check) calls into a module service (`AccountService`, `VehicleService`, `ItemService` — all extended with new methods below) and replies with the tab's full refreshed list via `admin:client:<tab>-reply`. Moderation needs one new table (`moderation_logs`); Players/Vehicles/Items need no schema changes.

**Tech Stack:** Lua 5.4 (FXServer server-side), the framework's own ORM (`QueryBuilder`/`BaseModel`/`Schema`), Vue 3 `<script setup>`, Tailwind utility classes (no separate stylesheet — matches every other tab).

**Spec:** `docs/superpowers/specs/2026-08-15-admin-panel-players-moderation-vehicles-items-design.md`

## Global Constraints

- Every new `Obelisk.onServer('admin:server:*')` handler starts with a local `isAdmin(source)` guard (`return source == 0 or IsPlayerAceAllowed(source, 'admin')`), copied per-file — no shared guard module exists in this plugin.
- Mutations reply with the tab's full refreshed list, not a partial patch (matches Organisations' `replyWithList` convention).
- `issued_by`/admin-identity fields use `tostring(source)`, matching `AccountCommands.lua`'s existing `/ban` command convention — no separate identifier-lookup helper exists.
- New Vue tab components get an `import.meta.env.DEV` fixture branch for their list state (no game client answers `Obelisk.emit` in `vite dev`), matching `OrganisationsTab.vue`.
- `base_items.name` and the `data`/`actions` JSON columns are not editable from the Items tab (out of scope per spec).
- Full spectate mode is stubbed with a "not implemented" notice, not built (out of scope per spec).
- No automated tests exist anywhere in this codebase for `Obelisk.onServer` handler wiring or `ActionService`/NUI plumbing (confirmed: `organisations.lua` itself has zero spec files) — only the module service methods (`AccountService`, `VehicleService`, `ItemService` additions) get Busted-style specs, matching actual repo convention. Handler wiring and all Vue components are verified manually.

---

## File Structure

**New files:**
- `modules/oblsk_accounts/server/migrations/2026_08_15_120000_create_moderation_logs_table.lua` — new table
- `modules/oblsk_accounts/server/models/ModerationLog.lua` — model for the new table
- `oblsk_admin/server/players.lua` — Players tab handlers
- `oblsk_admin/server/moderation.lua` — Moderation tab handlers
- `oblsk_admin/server/vehicles.lua` — Vehicles tab handlers
- `oblsk_admin/server/items.lua` — Items tab handlers
- `oblsk_admin/web/PlayersTab.vue`
- `oblsk_admin/web/ModerationTab.vue`
- `oblsk_admin/web/VehiclesTab.vue`
- `oblsk_admin/web/ItemsTab.vue`
- `modules/oblsk_accounts/tests/account_service_moderation_spec.lua`
- `modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua`
- `modules/oblsk_items/tests/item_service_admin_spec.lua`
- `modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua`

**Modified files:**
- `modules/oblsk_accounts/server/migrations.json` — register the new migration
- `modules/oblsk_accounts/server/services/AccountService.lua` — add `listBans`, `listModerationLogs`, `warn`, `logKick`
- `modules/oblsk_vehicles/server/services/VehicleService.lua` — add `listAll`, `deleteById`, `teleportToCoords`
- `modules/oblsk_items/server/services/ItemService.lua` — add `listBaseItems`, `updateBaseItem`, `createBaseItem`, `giveToPlayer`
- `oblsk_admin/client/main.lua` — relay wiring for the four new tabs
- `oblsk_admin/web/AdminPanel.vue` — render the four new tab components instead of `ComingSoon`

Paths above under `modules/` and `oblsk_admin/`/`core/` are relative to `core/` (the framework repo root); `oblsk_admin` is `core/plugins/oblsk_admin`.

---

### Task 1: `moderation_logs` migration + model

**Files:**
- Create: `core/modules/oblsk_accounts/server/migrations/2026_08_15_120000_create_moderation_logs_table.lua`
- Modify: `core/modules/oblsk_accounts/server/migrations.json`
- Create: `core/modules/oblsk_accounts/server/models/ModerationLog.lua`
- Test: `core/modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua`

**Interfaces:**
- Produces: table `moderation_logs(id, account_id, type, reason, issued_by, created_at, updated_at)`; model `ModerationLog` (fillable: `account_id`, `type`, `reason`, `issued_by`), consumed by Task 2.

- [ ] **Step 1: Write the migration**

```lua
-- core/modules/oblsk_accounts/server/migrations/2026_08_15_120000_create_moderation_logs_table.lua
--- Migration: Create moderation_logs table — persists warn/kick history.
--- Bans already persist via the `bans` table (see
--- 2026_08_10_090623_create_bans_table.lua); this covers the two
--- moderation actions that had nowhere to live before.
return {
    up = function()
        Schema.create('moderation_logs', function(table)
            table:id()
            table:integer('account_id')
            table:string('type', 10) -- 'warn' | 'kick', enforced at the service layer
            table:text('reason')
            table:string('issued_by', 255)
            table:timestamps()

            table:index({'account_id'})
            table:foreign('account_id'):references('id'):on('accounts'):onDelete('CASCADE')
        end)

        print('[Migration] Created moderation_logs table')
    end,

    down = function()
        Schema.drop('moderation_logs')
        print('[Migration] Dropped moderation_logs table')
    end
}
```

- [ ] **Step 2: Register the migration**

Edit `core/modules/oblsk_accounts/server/migrations.json`, appending to the array (order matters — this must run after `create_accounts_table` since it has a foreign key to `accounts`):

```json
{
  "migrations": [
    "2026_08_10_090621_create_accounts_table",
    "2026_08_10_090622_create_account_identifiers_table",
    "2026_08_10_090623_create_bans_table",
    "2026_08_15_120000_create_moderation_logs_table"
  ]
}
```

- [ ] **Step 3: Write the model**

```lua
-- core/modules/oblsk_accounts/server/models/ModerationLog.lua
--- ModerationLog Model - warn/kick history. Bans stay in their own `bans`
--- table (older, already has expires_at/revoked_at); this is only for the
--- two moderation actions that don't have a lifecycle to track.
ModerationLog = BaseModel:extend('moderation_logs')

ModerationLog.primaryKey = 'id'
ModerationLog.timestamps = true
ModerationLog.fillable = { 'account_id', 'type', 'reason', 'issued_by' }
ModerationLog.hidden = {}

function ModerationLog:accountRelation()
    return self:belongsTo(Account, 'account_id', 'id')
end

return ModerationLog
```

- [ ] **Step 4: Write the migration test**

Follow the pattern of `core/plugins/oblsk_shop/tests/shops_migration_spec.lua` — run `up` against a fake `Schema`/`Database`, then `down`, asserting both succeed without error and the table is created/dropped.

```lua
-- core/modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local migration = dofile(scriptDir .. '../server/migrations/2026_08_15_120000_create_moderation_logs_table.lua')

test('up: creates moderation_logs without error', function()
    local ok = pcall(migration.up)
    truthy(ok, 'migration.up() should not error')
end)

test('down: drops moderation_logs without error', function()
    local ok = pcall(migration.down)
    truthy(ok, 'migration.down() should not error')
end)

print('Running moderation_logs migration tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  ok   - ' .. t.name)
    else failures[#failures + 1] = t.name; print('  FAIL - ' .. t.name); print('         ' .. tostring(err)) end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 5: Run it, verify pass**

Run: `lua5.4 modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua` (from `core/`)
Expected: `2 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add modules/oblsk_accounts/server/migrations/2026_08_15_120000_create_moderation_logs_table.lua \
        modules/oblsk_accounts/server/migrations.json \
        modules/oblsk_accounts/server/models/ModerationLog.lua \
        modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua
git commit -m "feat(accounts): add moderation_logs table for warn/kick history"
```

---

### Task 2: `AccountService` moderation methods

**Files:**
- Modify: `core/modules/oblsk_accounts/server/services/AccountService.lua`
- Test: `core/modules/oblsk_accounts/tests/account_service_moderation_spec.lua`

**Interfaces:**
- Consumes: `Ban` model, `ModerationLog` model (Task 1), `Character` model (`Character.fillable` includes `first_name`/`last_name`; `Character:where('account_id', id):firstSync()` returns the first matching row or nil).
- Produces: `AccountService.listBans() -> table[]` (each `{ id, account_id, display_name|nil, identifier_type, identifier_value, reason, issued_by, expires_at, revoked_at, created_at }`), `AccountService.listModerationLogs() -> table[]` (same shape minus ban-only fields, plus `type`), `AccountService.warn(accountId, reason, issuedBy)`, `AccountService.logKick(accountId, reason, issuedBy)` — both consumed by Task 5/6.

- [ ] **Step 1: Write the failing tests**

```lua
-- core/modules/oblsk_accounts/tests/account_service_moderation_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_accounts/tests/account_service_moderation_spec.lua
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
dofile(scriptDir .. '../server/models/AccountIdentifier.lua')
dofile(scriptDir .. '../server/models/Ban.lua')
dofile(scriptDir .. '../server/models/ModerationLog.lua')
dofile(CORE_ROOT .. '/modules/oblsk_characters/server/models/Character.lua')
dofile(scriptDir .. '../server/services/AccountService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

--------------------------------------------------------------------------------
-- listBans
--------------------------------------------------------------------------------

test('listBans: returns all bans newest first, with display_name from a character', function()
    withFakeDb(function(tables)
        tables.accounts = { { id = 1 } }
        tables.characters = { { id = 10, account_id = 1, first_name = 'Jane', last_name = 'Doe', deleted_at = nil } }
        tables.bans = {
            { id = 1, account_id = 1, reason = 'first', issued_by = '1', created_at = '2026-08-10 00:00:00' },
            { id = 2, account_id = 1, reason = 'second', issued_by = '1', created_at = '2026-08-11 00:00:00' },
        }

        local bans = AccountService.listBans()
        eq(#bans, 2)
        eq(bans[1].reason, 'second', 'newest first')
        eq(bans[1].display_name, 'Jane Doe')
    end)
end)

test('listBans: identifier-only ban has no display_name', function()
    withFakeDb(function(tables)
        tables.bans = { { id = 1, identifier_type = 'ip', identifier_value = '127.0.0.1', reason = 'x', issued_by = '1', created_at = '2026-08-10 00:00:00' } }
        local bans = AccountService.listBans()
        eq(#bans, 1)
        eq(bans[1].display_name, nil)
    end)
end)

--------------------------------------------------------------------------------
-- listModerationLogs
--------------------------------------------------------------------------------

test('listModerationLogs: returns warn/kick rows newest first', function()
    withFakeDb(function(tables)
        tables.moderation_logs = {
            { id = 1, account_id = 1, type = 'warn', reason = 'a', issued_by = '1', created_at = '2026-08-10 00:00:00' },
            { id = 2, account_id = 1, type = 'kick', reason = 'b', issued_by = '1', created_at = '2026-08-11 00:00:00' },
        }
        local logs = AccountService.listModerationLogs()
        eq(#logs, 2)
        eq(logs[1].type, 'kick', 'newest first')
    end)
end)

--------------------------------------------------------------------------------
-- warn / logKick
--------------------------------------------------------------------------------

test('warn: inserts a moderation_logs row with type warn', function()
    withFakeDb(function(tables)
        AccountService.warn(1, 'being rude', '99')
        eq(#tables.moderation_logs, 1)
        eq(tables.moderation_logs[1].type, 'warn')
        eq(tables.moderation_logs[1].account_id, 1)
        eq(tables.moderation_logs[1].reason, 'being rude')
        eq(tables.moderation_logs[1].issued_by, '99')
    end)
end)

test('logKick: inserts a moderation_logs row with type kick', function()
    withFakeDb(function(tables)
        AccountService.logKick(1, 'exploiting', '99')
        eq(#tables.moderation_logs, 1)
        eq(tables.moderation_logs[1].type, 'kick')
    end)
end)

print('Running AccountService moderation unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  ok   - ' .. t.name)
    else failures[#failures + 1] = t.name; print('  FAIL - ' .. t.name); print('         ' .. tostring(err):gsub('\n', '\n         ')) end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run it, verify it fails**

Run: `lua5.4 modules/oblsk_accounts/tests/account_service_moderation_spec.lua` (from `core/`)
Expected: FAIL — `AccountService.listBans` is nil (attempt to call a nil value)

- [ ] **Step 3: Implement the four methods**

Append to `core/modules/oblsk_accounts/server/services/AccountService.lua` (after `AccountService.getAccountId`, before the final `return AccountService` if present — otherwise at end of file):

```lua
--- Best-effort display name for a ban/log row: the first non-deleted
--- character on that account, or nil if the account has none yet (bans can
--- predate character creation, e.g. an identifier-only ban).
--- @param accountId number|nil
--- @return string|nil
local function characterDisplayName(accountId)
    if not accountId then return nil end
    local character = Character:where('account_id', accountId):whereNull('deleted_at'):firstSync()
    if not character then return nil end
    return character.first_name .. ' ' .. character.last_name
end

--- @return table[] every ban, newest first, each with a best-effort display_name
function AccountService.listBans()
    local rows = QueryBuilder.new('bans'):orderBy('created_at', 'desc'):getSync()
    for _, row in ipairs(rows) do
        row.display_name = characterDisplayName(row.account_id)
    end
    return rows
end

--- @return table[] every warn/kick log row, newest first, each with a best-effort display_name
function AccountService.listModerationLogs()
    local rows = QueryBuilder.new('moderation_logs'):orderBy('created_at', 'desc'):getSync()
    for _, row in ipairs(rows) do
        row.display_name = characterDisplayName(row.account_id)
    end
    return rows
end

--- @param accountId number
--- @param reason string
--- @param issuedBy string
function AccountService.warn(accountId, reason, issuedBy)
    return ModerationLog:createSync({ account_id = accountId, type = 'warn', reason = reason, issued_by = issuedBy })
end

--- @param accountId number
--- @param reason string
--- @param issuedBy string
function AccountService.logKick(accountId, reason, issuedBy)
    return ModerationLog:createSync({ account_id = accountId, type = 'kick', reason = reason, issued_by = issuedBy })
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `lua5.4 modules/oblsk_accounts/tests/account_service_moderation_spec.lua` (from `core/`)
Expected: `5 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add modules/oblsk_accounts/server/services/AccountService.lua \
        modules/oblsk_accounts/tests/account_service_moderation_spec.lua
git commit -m "feat(accounts): add listBans/listModerationLogs/warn/logKick to AccountService"
```

---

### Task 3: `VehicleService` admin methods

**Files:**
- Modify: `core/modules/oblsk_vehicles/server/services/VehicleService.lua`
- Test: `core/modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua`

**Interfaces:**
- Consumes: `VehicleService.activeNetIds` (existing, `vehicleId -> netId`), `Vehicle`/`BaseVehicle` models.
- Produces: `VehicleService.listAll() -> table[]` (each `{ id, plate, display_name, model, name, owner_type, owner_id, stored, garage_id, fuel_level, net_id|nil }`), `VehicleService.deleteById(vehicleId) -> boolean, string|nil reason`, `VehicleService.teleportToCoords(vehicleId, coords) -> boolean, string|nil reason` — consumed by Task 7.

- [ ] **Step 1: Write the failing tests**

```lua
-- core/modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua
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
dofile(scriptDir .. '../server/models/Vehicle.lua')
dofile(scriptDir .. '../server/models/BaseVehicle.lua')
dofile(scriptDir .. '../server/services/VehicleService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

-- FXServer network natives, stubbed for the deleteById/teleportToCoords paths.
local deletedEntities, movedEntities = {}, {}
function NetworkGetEntityFromNetworkId(netId) return 'entity:' .. netId end
function DeleteEntity(entity) deletedEntities[#deletedEntities + 1] = entity end
function SetEntityCoords(entity, x, y, z) movedEntities[#movedEntities + 1] = { entity = entity, x = x, y = y, z = z } end
function DoesEntityExist(entity) return true end

--------------------------------------------------------------------------------
-- listAll
--------------------------------------------------------------------------------

test('listAll: joins base_vehicles for model/name and flags spawned vehicles', function()
    withFakeDb(function(tables)
        tables.base_vehicles = { { id = 5, model = 'sultan', name = 'Sultan' } }
        tables.vehicles = { { id = 1, base_vehicle_id = 5, plate = 'ABC123', display_name = nil, owner_type = 'character', owner_id = 10, stored = 1, garage_id = 2, fuel_level = 80 } }
        VehicleService.activeNetIds = { [1] = 999 }

        local rows = VehicleService.listAll()
        eq(#rows, 1)
        eq(rows[1].model, 'sultan')
        eq(rows[1].name, 'Sultan')
        eq(rows[1].net_id, 999)
    end)
end)

test('listAll: net_id is nil for a vehicle not currently spawned', function()
    withFakeDb(function(tables)
        tables.base_vehicles = { { id = 5, model = 'sultan', name = 'Sultan' } }
        tables.vehicles = { { id = 2, base_vehicle_id = 5, owner_type = 'character', owner_id = 10 } }
        VehicleService.activeNetIds = {}

        local rows = VehicleService.listAll()
        eq(rows[1].net_id, nil)
    end)
end)

--------------------------------------------------------------------------------
-- deleteById
--------------------------------------------------------------------------------

test('deleteById: despawns then deletes the row when spawned', function()
    withFakeDb(function(tables)
        tables.vehicles = { { id = 1 } }
        VehicleService.activeNetIds = { [1] = 999 }
        deletedEntities = {}

        local ok = VehicleService.deleteById(1)
        truthy(ok)
        eq(#deletedEntities, 1)
        eq(#tables.vehicles, 0)
    end)
end)

test('deleteById: deletes the row without despawning when not spawned', function()
    withFakeDb(function(tables)
        tables.vehicles = { { id = 3 } }
        VehicleService.activeNetIds = {}
        deletedEntities = {}

        local ok = VehicleService.deleteById(3)
        truthy(ok)
        eq(#deletedEntities, 0)
        eq(#tables.vehicles, 0)
    end)
end)

--------------------------------------------------------------------------------
-- teleportToCoords
--------------------------------------------------------------------------------

test('teleportToCoords: moves a spawned vehicle', function()
    VehicleService.activeNetIds = { [1] = 999 }
    movedEntities = {}

    local ok = VehicleService.teleportToCoords(1, { x = 1, y = 2, z = 3 })
    truthy(ok)
    eq(#movedEntities, 1)
end)

test('teleportToCoords: fails with a reason when the vehicle is not spawned', function()
    VehicleService.activeNetIds = {}
    local ok, reason = VehicleService.teleportToCoords(5, { x = 1, y = 2, z = 3 })
    eq(ok, false)
    truthy(reason ~= nil)
end)

print('Running VehicleService admin unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  ok   - ' .. t.name)
    else failures[#failures + 1] = t.name; print('  FAIL - ' .. t.name); print('         ' .. tostring(err):gsub('\n', '\n         ')) end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run it, verify it fails**

Run: `lua5.4 modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua` (from `core/`)
Expected: FAIL — `VehicleService.listAll` is nil

- [ ] **Step 3: Implement the three methods**

Append to `core/modules/oblsk_vehicles/server/services/VehicleService.lua`, before `return VehicleService`:

```lua
--- @return table[] every vehicle row with its base model's model/name, plus net_id if currently spawned
function VehicleService.listAll()
    local vehicles = QueryBuilder.new('vehicles'):getSync()
    local baseById = {}
    for _, base in ipairs(QueryBuilder.new('base_vehicles'):getSync()) do
        baseById[base.id] = base
    end

    for _, vehicle in ipairs(vehicles) do
        local base = baseById[vehicle.base_vehicle_id]
        vehicle.model = base and base.model or nil
        vehicle.name = base and base.name or nil
        vehicle.net_id = VehicleService.activeNetIds[vehicle.id]
    end

    return vehicles
end

--- Despawns the vehicle if currently spawned, then deletes its row.
--- @param vehicleId number
--- @return boolean
function VehicleService.deleteById(vehicleId)
    local netId = VehicleService.activeNetIds[vehicleId]
    if netId then
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity and DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
        VehicleService.activeNetIds[vehicleId] = nil
    end

    QueryBuilder.new('vehicles'):where('id', vehicleId):delete()
    return true
end

--- Moves a currently-spawned vehicle to the given coords. No-ops (with a
--- reason) if the vehicle isn't spawned — spawning one just to move it is
--- Garage-tab territory, not this slice.
--- @param vehicleId number
--- @param coords table { x, y, z }
--- @return boolean, string|nil reason
function VehicleService.teleportToCoords(vehicleId, coords)
    local netId = VehicleService.activeNetIds[vehicleId]
    if not netId then
        return false, 'Vehicle is not currently spawned'
    end

    local entity = NetworkGetEntityFromNetworkId(netId)
    SetEntityCoords(entity, coords.x, coords.y, coords.z)
    return true
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `lua5.4 modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua` (from `core/`)
Expected: `6 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add modules/oblsk_vehicles/server/services/VehicleService.lua \
        modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua
git commit -m "feat(vehicles): add listAll/deleteById/teleportToCoords to VehicleService"
```

---

### Task 4: `ItemService` admin methods

**Files:**
- Modify: `core/modules/oblsk_items/server/services/ItemService.lua`
- Test: `core/modules/oblsk_items/tests/item_service_admin_spec.lua`

**Interfaces:**
- Consumes: `BaseItem` model, `ItemService.add(source, baseItem, amount)` (existing — `baseItem` is a plain attributes table, not a model instance, per `ItemService.binding`'s existing convention).
- Produces: `ItemService.listBaseItems() -> table[]`, `ItemService.updateBaseItem(baseItemId, attributes) -> boolean, string|nil reason`, `ItemService.createBaseItem(attributes) -> number|nil id, string|nil reason`, `ItemService.giveToPlayer(source, baseItemId, amount) -> boolean, string|nil reason` — consumed by Task 8.

- [ ] **Step 1: Write the failing tests**

```lua
-- core/modules/oblsk_items/tests/item_service_admin_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_items/tests/item_service_admin_spec.lua
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

-- CharacterService stub: ItemService.add needs an active character to give to.
CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    if source == 42 then return 100 end
    return nil
end

dofile(scriptDir .. '../server/services/ItemService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

--------------------------------------------------------------------------------
-- listBaseItems
--------------------------------------------------------------------------------

test('listBaseItems: returns every base_items row', function()
    withFakeDb(function(tables)
        tables.base_items = { { id = 1, name = 'water', weight = 0.5 }, { id = 2, name = 'bread', weight = 0.3 } }
        local items = ItemService.listBaseItems()
        eq(#items, 2)
    end)
end)

--------------------------------------------------------------------------------
-- updateBaseItem
--------------------------------------------------------------------------------

test('updateBaseItem: updates whitelisted fields only', function()
    withFakeDb(function(tables)
        tables.base_items = { { id = 1, name = 'water', weight = 0.5, is_giveable = 1 } }
        local ok = ItemService.updateBaseItem(1, { weight = 0.8, is_giveable = 0, name = 'renamed' })
        truthy(ok)
        eq(tables.base_items[1].weight, 0.8)
        eq(tables.base_items[1].is_giveable, 0)
        eq(tables.base_items[1].name, 'water', 'name is not editable')
    end)
end)

--------------------------------------------------------------------------------
-- createBaseItem
--------------------------------------------------------------------------------

test('createBaseItem: inserts a new row and returns its id', function()
    withFakeDb(function(tables)
        local id, reason = ItemService.createBaseItem({ name = 'bandage', weight = 0.1 })
        truthy(id ~= nil, 'expected an id')
        eq(reason, nil)
        eq(#tables.base_items, 1)
        eq(tables.base_items[1].name, 'bandage')
    end)
end)

--------------------------------------------------------------------------------
-- giveToPlayer
--------------------------------------------------------------------------------

test('giveToPlayer: adds the item to the target\'s inventory', function()
    withFakeDb(function(tables)
        tables.base_items = { { id = 1, name = 'water', weight = 0.5 } }
        local ok = ItemService.giveToPlayer(42, 1, 3)
        truthy(ok)
        eq(#tables.items, 1)
        eq(tables.items[1].base_item_id, 1)
        eq(tables.items[1].amount, 3)
    end)
end)

test('giveToPlayer: fails with a reason when the base item does not exist', function()
    withFakeDb(function(tables)
        local ok, reason = ItemService.giveToPlayer(42, 999, 1)
        eq(ok, false)
        truthy(reason ~= nil)
    end)
end)

print('Running ItemService admin unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  ok   - ' .. t.name)
    else failures[#failures + 1] = t.name; print('  FAIL - ' .. t.name); print('         ' .. tostring(err):gsub('\n', '\n         ')) end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run it, verify it fails**

Run: `lua5.4 modules/oblsk_items/tests/item_service_admin_spec.lua` (from `core/`)
Expected: FAIL — `ItemService.listBaseItems` is nil

- [ ] **Step 3: Implement the four methods**

Append to `core/modules/oblsk_items/server/services/ItemService.lua`, before `return ItemService`:

```lua
--- @return table[] every base_items row
function ItemService.listBaseItems()
    return QueryBuilder.new('base_items'):getSync()
end

--- Whitelist-updates an existing base item. `name` and the `data`/`actions`
--- JSON columns are intentionally excluded — `name` is the lookup key
--- ItemService.binding() and every plugin's Config.Requires reference by
--- string, and data/actions are config-shaped, not admin-panel-shaped.
--- @param baseItemId number
--- @param attributes table any of: description, icon, weight, is_takeable,
---   is_giveable, is_dropable, is_container, is_useable, is_stackable, max_stack_amount
--- @return boolean
local EDITABLE_BASE_ITEM_FIELDS = {
    'description', 'icon', 'weight',
    'is_takeable', 'is_giveable', 'is_dropable', 'is_container', 'is_useable', 'is_stackable',
    'max_stack_amount',
}
function ItemService.updateBaseItem(baseItemId, attributes)
    local update = {}
    for _, field in ipairs(EDITABLE_BASE_ITEM_FIELDS) do
        if attributes[field] ~= nil then
            update[field] = attributes[field]
        end
    end
    QueryBuilder.new('base_items'):where('id', baseItemId):update(update)
    return true
end

--- @param attributes table see BaseItem.fillable for accepted keys
--- @return number|nil id, string|nil reason
function ItemService.createBaseItem(attributes)
    if not attributes.name or attributes.name == '' then
        return nil, 'Name is required'
    end
    local ok, result = pcall(function() return BaseItem:createSync(attributes) end)
    if not ok then
        return nil, 'Name already in use'
    end
    return result.id
end

--- @param source number target player to give the item to
--- @param baseItemId number
--- @param amount number
--- @return boolean, string|nil reason
function ItemService.giveToPlayer(source, baseItemId, amount)
    local base = BaseItem:findSync(baseItemId)
    if not base then
        return false, 'Item not found'
    end
    return ItemService.add(source, base.attributes, amount)
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `lua5.4 modules/oblsk_items/tests/item_service_admin_spec.lua` (from `core/`)
Expected: `6 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add modules/oblsk_items/server/services/ItemService.lua \
        modules/oblsk_items/tests/item_service_admin_spec.lua
git commit -m "feat(items): add listBaseItems/updateBaseItem/createBaseItem/giveToPlayer to ItemService"
```

---

### Task 5: Players tab server handlers

**Files:**
- Create: `core/plugins/oblsk_admin/server/players.lua`

**Interfaces:**
- Consumes: `CharacterService.sessionCharacters` (existing, `source -> characterId`), `Character:findSync`, `AccountService.getAccountId`, `AccountService.logKick` (Task 2), `NotificationService.info/error` (existing, `core/server/Services/NotificationService.lua`).
- Produces: NUI events `admin:server:players-list`, `admin:server:players-teleport-to-player`, `admin:server:players-bring-player`, `admin:server:players-kick`, `admin:server:players-spectate`, all replying via `admin:client:players-reply` — consumed by Task 9 (client relay) and Task 10 (Vue).

- [ ] **Step 1: Write the handler file**

```lua
-- core/plugins/oblsk_admin/server/players.lua
--- oblsk_admin server: Players tab NUI handlers. Reads live server state
--- (GetPlayers()), not a database table -- there's nothing to persist for
--- an online-player list.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

local function listPlayers()
    local rows = {}
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        local characterId = CharacterService.sessionCharacters[playerId]
        local character = characterId and Character:findSync(characterId)
        local coords = GetEntityCoords(GetPlayerPed(playerId))

        table.insert(rows, {
            source = playerId,
            name = GetPlayerName(playerId),
            characterName = character and (character.attributes.first_name .. ' ' .. character.attributes.last_name) or nil,
            ping = GetPlayerPing(playerId),
            coords = { x = coords.x, y = coords.y, z = coords.z },
        })
    end
    return rows
end

local function replyWithList(source)
    Obelisk.emitClient('admin:client:players-reply', source, { players = listPlayers() })
end

Obelisk.onServer('admin:server:players-list', function()
    local source = source
    if not isAdmin(source) then return end
    replyWithList(source)
end)

Obelisk.onServer('admin:server:players-teleport-to-player', function(data)
    local source = source
    if not isAdmin(source) then return end
    local targetPed = GetPlayerPed(data.targetSource)
    if targetPed == 0 then return end
    local coords = GetEntityCoords(targetPed)
    SetEntityCoords(GetPlayerPed(source), coords.x, coords.y, coords.z)
end)

Obelisk.onServer('admin:server:players-bring-player', function(data)
    local source = source
    if not isAdmin(source) then return end
    local adminCoords = GetEntityCoords(GetPlayerPed(source))
    local targetPed = GetPlayerPed(data.targetSource)
    if targetPed == 0 then return end
    SetEntityCoords(targetPed, adminCoords.x, adminCoords.y, adminCoords.z)
end)

Obelisk.onServer('admin:server:players-kick', function(data)
    local source = source
    if not isAdmin(source) then return end
    local accountId = AccountService.getAccountId(data.targetSource)
    if accountId then
        AccountService.logKick(accountId, data.reason or 'No reason given', tostring(source))
    end
    DropPlayer(data.targetSource, 'Kicked: ' .. (data.reason or 'No reason given'))
    replyWithList(source)
end)

Obelisk.onServer('admin:server:players-spectate', function(data)
    local source = source
    if not isAdmin(source) then return end
    NotificationService.info(source, 'Players', 'Spectate mode is not implemented yet.')
end)
```

- [ ] **Step 2: Commit**

```bash
git add plugins/oblsk_admin/server/players.lua
git commit -m "feat(admin): add Players tab server handlers"
```

---

### Task 6: Moderation tab server handlers

**Files:**
- Create: `core/plugins/oblsk_admin/server/moderation.lua`

**Interfaces:**
- Consumes: `AccountService.listBans/listModerationLogs/ban/unban/warn/logKick` (existing + Task 2), `NotificationService.info` (existing).
- Produces: NUI events `admin:server:moderation-list`, `-ban`, `-unban`, `-warn`, `-kick`, replying via `admin:client:moderation-reply` — consumed by Task 9/11.

- [ ] **Step 1: Write the handler file**

```lua
-- core/plugins/oblsk_admin/server/moderation.lua
--- oblsk_admin server: Moderation tab NUI handlers. Bans persist through
--- the pre-existing `bans` table/AccountService.ban (already enforced at
--- connect via checkBan); warn/kick persist through the new
--- moderation_logs table/AccountService.warn/logKick.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

local function replyWithLists(source)
    Obelisk.emitClient('admin:client:moderation-reply', source, {
        bans = AccountService.listBans(),
        logs = AccountService.listModerationLogs(),
    })
end

Obelisk.onServer('admin:server:moderation-list', function()
    local source = source
    if not isAdmin(source) then return end
    replyWithLists(source)
end)

Obelisk.onServer('admin:server:moderation-ban', function(data)
    local source = source
    if not isAdmin(source) then return end

    local expiresAt = nil
    if data.durationHours and data.durationHours > 0 then
        expiresAt = os.date('%Y-%m-%d %H:%M:%S', os.time() + data.durationHours * 3600)
    end

    AccountService.ban({ accountId = data.accountId }, data.reason or 'No reason given', tostring(source), expiresAt)

    -- A ban that doesn't remove the still-connected player is a broken ban.
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if AccountService.getAccountId(playerId) == data.accountId then
            DropPlayer(playerId, 'Banned: ' .. (data.reason or 'No reason given'))
        end
    end

    replyWithLists(source)
end)

Obelisk.onServer('admin:server:moderation-unban', function(data)
    local source = source
    if not isAdmin(source) then return end
    AccountService.unban(data.banId)
    replyWithLists(source)
end)

Obelisk.onServer('admin:server:moderation-warn', function(data)
    local source = source
    if not isAdmin(source) then return end
    AccountService.warn(data.accountId, data.reason or 'No reason given', tostring(source))

    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if AccountService.getAccountId(playerId) == data.accountId then
            NotificationService.warning(playerId, 'Warning', data.reason or 'No reason given')
        end
    end

    replyWithLists(source)
end)

Obelisk.onServer('admin:server:moderation-kick', function(data)
    local source = source
    if not isAdmin(source) then return end
    AccountService.logKick(data.accountId, data.reason or 'No reason given', tostring(source))

    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if AccountService.getAccountId(playerId) == data.accountId then
            DropPlayer(playerId, 'Kicked: ' .. (data.reason or 'No reason given'))
        end
    end

    replyWithLists(source)
end)
```

- [ ] **Step 2: Commit**

```bash
git add plugins/oblsk_admin/server/moderation.lua
git commit -m "feat(admin): add Moderation tab server handlers"
```

---

### Task 7: Vehicles tab server handlers

**Files:**
- Create: `core/plugins/oblsk_admin/server/vehicles.lua`

**Interfaces:**
- Consumes: `VehicleService.listAll/deleteById/teleportToCoords` (Task 3).
- Produces: NUI events `admin:server:vehicles-list`, `-delete`, `-teleport-to-admin`, replying via `admin:client:vehicles-reply` — consumed by Task 9/12.

- [ ] **Step 1: Write the handler file**

```lua
-- core/plugins/oblsk_admin/server/vehicles.lua
--- oblsk_admin server: Vehicles tab NUI handlers.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

local function replyWithList(source)
    Obelisk.emitClient('admin:client:vehicles-reply', source, { vehicles = VehicleService.listAll() })
end

Obelisk.onServer('admin:server:vehicles-list', function()
    local source = source
    if not isAdmin(source) then return end
    replyWithList(source)
end)

Obelisk.onServer('admin:server:vehicles-delete', function(data)
    local source = source
    if not isAdmin(source) then return end
    VehicleService.deleteById(data.vehicleId)
    replyWithList(source)
end)

Obelisk.onServer('admin:server:vehicles-teleport-to-admin', function(data)
    local source = source
    if not isAdmin(source) then return end
    local adminCoords = GetEntityCoords(GetPlayerPed(source))
    local ok, reason = VehicleService.teleportToCoords(data.vehicleId, adminCoords)
    if not ok then
        NotificationService.error(source, 'Vehicles', reason)
    end
    replyWithList(source)
end)
```

- [ ] **Step 2: Commit**

```bash
git add plugins/oblsk_admin/server/vehicles.lua
git commit -m "feat(admin): add Vehicles tab server handlers"
```

---

### Task 8: Items tab server handlers

**Files:**
- Create: `core/plugins/oblsk_admin/server/items.lua`

**Interfaces:**
- Consumes: `ItemService.listBaseItems/updateBaseItem/createBaseItem/giveToPlayer` (Task 4).
- Produces: NUI events `admin:server:items-list`, `-update`, `-create`, `-give`, replying via `admin:client:items-reply` — consumed by Task 9/13.

- [ ] **Step 1: Write the handler file**

```lua
-- core/plugins/oblsk_admin/server/items.lua
--- oblsk_admin server: Items tab NUI handlers.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

local function replyWithList(source)
    Obelisk.emitClient('admin:client:items-reply', source, { items = ItemService.listBaseItems() })
end

Obelisk.onServer('admin:server:items-list', function()
    local source = source
    if not isAdmin(source) then return end
    replyWithList(source)
end)

Obelisk.onServer('admin:server:items-update', function(data)
    local source = source
    if not isAdmin(source) then return end
    ItemService.updateBaseItem(data.baseItemId, data.attributes or {})
    replyWithList(source)
end)

Obelisk.onServer('admin:server:items-create', function(data)
    local source = source
    if not isAdmin(source) then return end
    local id, reason = ItemService.createBaseItem(data.attributes or {})
    if not id then
        NotificationService.error(source, 'Items', reason)
    end
    replyWithList(source)
end)

Obelisk.onServer('admin:server:items-give', function(data)
    local source = source
    if not isAdmin(source) then return end
    local ok, reason = ItemService.giveToPlayer(data.targetSource, data.baseItemId, data.amount)
    if ok then
        NotificationService.success(source, 'Items', 'Item given.')
        NotificationService.info(data.targetSource, 'Items', 'You received an item from staff.')
    else
        NotificationService.error(source, 'Items', reason)
    end
    replyWithList(source)
end)
```

- [ ] **Step 2: Commit**

```bash
git add plugins/oblsk_admin/server/items.lua
git commit -m "feat(admin): add Items tab server handlers"
```

---

### Task 9: Client relay wiring for all four tabs

**Files:**
- Modify: `core/plugins/oblsk_admin/client/main.lua`

**Interfaces:**
- Consumes: existing `WebView.on`/`Obelisk.onClient`/`Obelisk.emitServer`/`SendNUIMessage` (already used by the `ORG_RELAYS` block in this file).
- Produces: relays for every event name Tasks 5-8 register server-side, and a `SendNUIMessage` forward for each `-reply` event — consumed by the Vue components in Tasks 10-13.

- [ ] **Step 1: Add the relay blocks**

Append to `core/plugins/oblsk_admin/client/main.lua`, after the existing `Obelisk.onClient('admin:client:organisations-reply', ...)` block:

```lua
-- Thin relays for the Players/Moderation/Vehicles/Items tabs, same pattern
-- as ORG_RELAYS above: every admin:client:<tab>-<verb> NUI event forwards
-- verbatim to the matching admin:server:<tab>-<verb> handler.
local TAB_RELAYS = {
    'players-list', 'players-teleport-to-player', 'players-bring-player', 'players-kick', 'players-spectate',
    'moderation-list', 'moderation-ban', 'moderation-unban', 'moderation-warn', 'moderation-kick',
    'vehicles-list', 'vehicles-delete', 'vehicles-teleport-to-admin',
    'items-list', 'items-update', 'items-create', 'items-give',
}
for _, name in ipairs(TAB_RELAYS) do
    WebView.on('admin:client:' .. name, function(data)
        Obelisk.emitServer('admin:server:' .. name, data)
    end)
end

local TAB_REPLIES = { 'players-reply', 'moderation-reply', 'vehicles-reply', 'items-reply' }
for _, name in ipairs(TAB_REPLIES) do
    Obelisk.onClient('admin:client:' .. name, function(payload)
        SendNUIMessage({ eventname = 'admin:client:' .. name, args = { payload } })
    end)
end
```

- [ ] **Step 2: Commit**

```bash
git add plugins/oblsk_admin/client/main.lua
git commit -m "feat(admin): relay Players/Moderation/Vehicles/Items NUI events client-side"
```

---

### Task 10: Players tab Vue component

**Files:**
- Create: `core/plugins/oblsk_admin/web/PlayersTab.vue`
- Modify: `core/plugins/oblsk_admin/web/AdminPanel.vue`

**Interfaces:**
- Consumes: `admin:client:players-list` (emit), `admin:client:players-reply` (on) — payload `{ players: [{ source, name, characterName, ping, coords }] }`, matching Task 5's `listPlayers()`.

- [ ] **Step 1: Write the component**

```vue
<!-- core/plugins/oblsk_admin/web/PlayersTab.vue -->
<script setup>
import { ref, onMounted, onBeforeUnmount, inject, watch } from 'vue'
import Obelisk from '@/obelisk.js'

const players = ref([])
const kickReason = ref('')
const kickTarget = ref(null)

const DEV_PLAYERS = [
  { source: 1, name: 'Steam_abc123', characterName: 'Jane Doe', ping: 34, coords: { x: 215.3, y: -810.2, z: 30.7 } },
  { source: 2, name: 'Steam_def456', characterName: 'Mark Ito', ping: 58, coords: { x: -48.1, y: -1090.5, z: 26.4 } },
]

const onReply = ({ players: next }) => { players.value = next }

const fetchList = () => {
  if (import.meta.env.DEV) { players.value = DEV_PLAYERS; return }
  Obelisk.emit('admin:client:players-list', {})
}

onMounted(() => {
  Obelisk.on('admin:client:players-reply', onReply)
  fetchList()
})
onBeforeUnmount(() => Obelisk.off('admin:client:players-reply', onReply))

const registry = inject('obelisk:globalElementsRegistry', null)
if (registry) {
  watch(() => registry.get('admin')?.visible, (visible) => { if (visible) fetchList() })
}

const teleportTo = (p) => Obelisk.emit('admin:client:players-teleport-to-player', { targetSource: p.source })
const bring = (p) => Obelisk.emit('admin:client:players-bring-player', { targetSource: p.source })
const spectate = (p) => Obelisk.emit('admin:client:players-spectate', { targetSource: p.source })
const openKick = (p) => { kickTarget.value = p; kickReason.value = '' }
const submitKick = () => {
  Obelisk.emit('admin:client:players-kick', { targetSource: kickTarget.value.source, reason: kickReason.value || 'No reason given' })
  kickTarget.value = null
}
</script>

<template>
  <div class="flex-1 overflow-hidden flex flex-col p-5 gap-3">
    <div class="text-[12.5px] font-medium">Players online · {{ players.length }}</div>
    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex-1 overflow-y-auto">
      <div v-for="p in players" :key="p.source" class="px-3.5 py-2.5 flex items-center gap-3 border-b border-white/6">
        <span class="ob-mono text-[10px] text-white/35 w-8 shrink-0">#{{ p.source }}</span>
        <span class="min-w-0 flex-1">
          <span class="block text-[12px] truncate">{{ p.characterName || p.name }}</span>
          <span class="block ob-mono text-[9px] text-white/35 truncate">{{ p.name }} · {{ p.ping }}ms</span>
        </span>
        <button @click="teleportTo(p)" class="ob-mono text-[9px] px-1.5 py-1 rounded border border-white/12 hover:bg-white/8">GOTO</button>
        <button @click="bring(p)" class="ob-mono text-[9px] px-1.5 py-1 rounded border border-white/12 hover:bg-white/8">BRING</button>
        <button @click="spectate(p)" class="ob-mono text-[9px] px-1.5 py-1 rounded border border-white/12 hover:bg-white/8">SPEC</button>
        <button @click="openKick(p)" class="ob-mono text-[9px] px-1.5 py-1 rounded border border-white/12 text-red-300 hover:bg-red-500/10">KICK</button>
      </div>
      <div v-if="!players.length" class="py-6 text-center text-[11.5px] text-white/30">No players online.</div>
    </div>

    <div v-if="kickTarget" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-3">
      <div class="text-[12.5px] font-medium">Kick {{ kickTarget.characterName || kickTarget.name }}</div>
      <input v-model="kickReason" placeholder="Reason" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
      <div class="flex gap-2">
        <button @click="kickTarget = null" class="h-9 px-3.5 rounded-lg border border-white/12 text-[12px]">Cancel</button>
        <button @click="submitKick" class="h-9 px-4 rounded-lg text-black text-[12px] font-medium" style="background: var(--ob-accent)">Kick</button>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Wire it into AdminPanel.vue**

Edit `core/plugins/oblsk_admin/web/AdminPanel.vue`:

```diff
 import ComingSoon from './ComingSoon.vue'
 import OrganisationsTab from './OrganisationsTab.vue'
+import PlayersTab from './PlayersTab.vue'
```

```diff
       <OrganisationsTab v-if="activeTab === 'organisations'" />
+      <PlayersTab v-else-if="activeTab === 'players'" />
       <ComingSoon v-else :label="TABS.find(([k]) => k === activeTab)[1]" />
```

- [ ] **Step 3: Manual verification**

Run: `cd core/web && npm run dev` (or the repo's existing Vite dev command for this workspace), open `/Admin` in a browser.
Expected: Players tab shows the two dev-fixture rows; GOTO/BRING/SPEC/KICK buttons are clickable without console errors (their `Obelisk.emit` calls are no-ops without a game client, which is expected in dev).

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_admin/web/PlayersTab.vue plugins/oblsk_admin/web/AdminPanel.vue
git commit -m "feat(admin): add Players tab UI"
```

---

### Task 11: Moderation tab Vue component

**Files:**
- Create: `core/plugins/oblsk_admin/web/ModerationTab.vue`
- Modify: `core/plugins/oblsk_admin/web/AdminPanel.vue`

**Interfaces:**
- Consumes: `admin:client:moderation-list` (emit), `admin:client:moderation-reply` (on) — payload `{ bans: [...], logs: [...] }`, matching Task 6.

- [ ] **Step 1: Write the component**

```vue
<!-- core/plugins/oblsk_admin/web/ModerationTab.vue -->
<script setup>
import { ref, onMounted, onBeforeUnmount, inject, watch } from 'vue'
import Obelisk from '@/obelisk.js'

const bans = ref([])
const logs = ref([])
const draft = ref(null) // { kind: 'ban'|'warn'|'kick', accountId, reason, durationHours }

const DEV_BANS = [
  { id: 1, account_id: 7, display_name: 'Ricky Stone', reason: 'RDM', issued_by: '1', expires_at: null, revoked_at: null, created_at: '2026-08-14 10:00:00' },
]
const DEV_LOGS = [
  { id: 1, account_id: 8, display_name: 'Mila Fenn', type: 'warn', reason: 'Chat spam', issued_by: '1', created_at: '2026-08-15 09:00:00' },
]

const onReply = (payload) => { bans.value = payload.bans; logs.value = payload.logs }

const fetchLists = () => {
  if (import.meta.env.DEV) { bans.value = DEV_BANS; logs.value = DEV_LOGS; return }
  Obelisk.emit('admin:client:moderation-list', {})
}

onMounted(() => {
  Obelisk.on('admin:client:moderation-reply', onReply)
  fetchLists()
})
onBeforeUnmount(() => Obelisk.off('admin:client:moderation-reply', onReply))

const registry = inject('obelisk:globalElementsRegistry', null)
if (registry) {
  watch(() => registry.get('admin')?.visible, (visible) => { if (visible) fetchLists() })
}

const openDraft = (kind) => { draft.value = { kind, accountId: '', reason: '', durationHours: '' } }
const submitDraft = () => {
  const accountId = Number(draft.value.accountId)
  const reason = draft.value.reason || 'No reason given'
  if (draft.value.kind === 'ban') {
    Obelisk.emit('admin:client:moderation-ban', { accountId, reason, durationHours: draft.value.durationHours ? Number(draft.value.durationHours) : null })
  } else if (draft.value.kind === 'warn') {
    Obelisk.emit('admin:client:moderation-warn', { accountId, reason })
  } else if (draft.value.kind === 'kick') {
    Obelisk.emit('admin:client:moderation-kick', { accountId, reason })
  }
  draft.value = null
}
const unban = (banId) => Obelisk.emit('admin:client:moderation-unban', { banId })
</script>

<template>
  <div class="grid gap-3 min-h-0 p-5" style="grid-template-columns: 1fr 1fr">
    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex flex-col">
      <div class="px-4 py-2.5 border-b border-white/8 flex items-center justify-between">
        <span class="text-[12.5px] font-medium">Bans · {{ bans.length }}</span>
        <button @click="openDraft('ban')" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">+ BAN</button>
      </div>
      <div class="overflow-y-auto" style="max-height: 460px">
        <div v-for="b in bans" :key="b.id" class="px-3.5 py-2.5 border-b border-white/6">
          <div class="flex items-center justify-between">
            <span class="text-[12px]">{{ b.display_name || ('Account #' + b.account_id) }}</span>
            <button v-if="!b.revoked_at" @click="unban(b.id)" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">UNBAN</button>
            <span v-else class="ob-mono text-[9px] text-white/30">REVOKED</span>
          </div>
          <div class="ob-mono text-[9px] text-white/35 mt-1">{{ b.reason }} · {{ b.expires_at || 'permanent' }}</div>
        </div>
        <div v-if="!bans.length" class="py-6 text-center text-[11.5px] text-white/30">No bans.</div>
      </div>
    </div>

    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex flex-col">
      <div class="px-4 py-2.5 border-b border-white/8 flex items-center justify-between gap-1.5">
        <span class="text-[12.5px] font-medium">Warnings & kicks · {{ logs.length }}</span>
        <div class="flex gap-1.5">
          <button @click="openDraft('warn')" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">+ WARN</button>
          <button @click="openDraft('kick')" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">+ KICK</button>
        </div>
      </div>
      <div class="overflow-y-auto" style="max-height: 460px">
        <div v-for="l in logs" :key="l.id" class="px-3.5 py-2.5 border-b border-white/6">
          <div class="flex items-center gap-2">
            <span class="ob-mono text-[9px] uppercase" :style="{ color: l.type === 'kick' ? '#f87171' : '#e0b64a' }">{{ l.type }}</span>
            <span class="text-[12px]">{{ l.display_name || ('Account #' + l.account_id) }}</span>
          </div>
          <div class="ob-mono text-[9px] text-white/35 mt-1">{{ l.reason }}</div>
        </div>
        <div v-if="!logs.length" class="py-6 text-center text-[11.5px] text-white/30">No warnings or kicks.</div>
      </div>
    </div>

    <div v-if="draft" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-3 col-span-2">
      <div class="text-[13px] font-medium capitalize">{{ draft.kind }} account</div>
      <input v-model="draft.accountId" placeholder="Account ID" type="number" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
      <input v-model="draft.reason" placeholder="Reason" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
      <input v-if="draft.kind === 'ban'" v-model="draft.durationHours" placeholder="Duration in hours (blank = permanent)" type="number" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
      <div class="flex gap-2">
        <button @click="draft = null" class="h-9 px-3.5 rounded-lg border border-white/12 text-[12px]">Cancel</button>
        <button @click="submitDraft" class="h-9 px-4 rounded-lg text-black text-[12px] font-medium capitalize" style="background: var(--ob-accent)">{{ draft.kind }}</button>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Wire it into AdminPanel.vue**

```diff
 import PlayersTab from './PlayersTab.vue'
+import ModerationTab from './ModerationTab.vue'
```

```diff
       <PlayersTab v-else-if="activeTab === 'players'" />
+      <ModerationTab v-else-if="activeTab === 'moderation'" />
```

- [ ] **Step 3: Manual verification**

Run: dev server as in Task 10, open `/Admin` → Moderation tab.
Expected: dev-fixture ban and warn rows render; +BAN/+WARN/+KICK open the draft form, Cancel closes it, no console errors.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_admin/web/ModerationTab.vue plugins/oblsk_admin/web/AdminPanel.vue
git commit -m "feat(admin): add Moderation tab UI"
```

---

### Task 12: Vehicles tab Vue component

**Files:**
- Create: `core/plugins/oblsk_admin/web/VehiclesTab.vue`
- Modify: `core/plugins/oblsk_admin/web/AdminPanel.vue`

**Interfaces:**
- Consumes: `admin:client:vehicles-list` (emit), `admin:client:vehicles-reply` (on) — payload `{ vehicles: [{ id, plate, display_name, model, name, owner_type, owner_id, stored, garage_id, fuel_level, net_id }] }`, matching Task 3's `listAll()` shape.

- [ ] **Step 1: Write the component**

```vue
<!-- core/plugins/oblsk_admin/web/VehiclesTab.vue -->
<script setup>
import { ref, onMounted, onBeforeUnmount, inject, watch } from 'vue'
import Obelisk from '@/obelisk.js'

const vehicles = ref([])

const DEV_VEHICLES = [
  { id: 1, plate: 'ABC123', display_name: 'My Sultan', model: 'sultan', name: 'Sultan', owner_type: 'character', owner_id: 10, stored: 0, garage_id: null, fuel_level: 62, net_id: 4821 },
  { id: 2, plate: 'XYZ789', display_name: null, model: 'kuruma', name: 'Kuruma', owner_type: 'character', owner_id: 11, stored: 1, garage_id: 2, fuel_level: 100, net_id: null },
]

const onReply = ({ vehicles: next }) => { vehicles.value = next }

const fetchList = () => {
  if (import.meta.env.DEV) { vehicles.value = DEV_VEHICLES; return }
  Obelisk.emit('admin:client:vehicles-list', {})
}

onMounted(() => {
  Obelisk.on('admin:client:vehicles-reply', onReply)
  fetchList()
})
onBeforeUnmount(() => Obelisk.off('admin:client:vehicles-reply', onReply))

const registry = inject('obelisk:globalElementsRegistry', null)
if (registry) {
  watch(() => registry.get('admin')?.visible, (visible) => { if (visible) fetchList() })
}

const teleportToAdmin = (v) => Obelisk.emit('admin:client:vehicles-teleport-to-admin', { vehicleId: v.id })
const deleteVehicle = (v) => Obelisk.emit('admin:client:vehicles-delete', { vehicleId: v.id })
</script>

<template>
  <div class="flex-1 overflow-hidden flex flex-col p-5 gap-3">
    <div class="text-[12.5px] font-medium">Vehicles · {{ vehicles.length }}</div>
    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex-1 overflow-y-auto">
      <div v-for="v in vehicles" :key="v.id" class="px-3.5 py-2.5 flex items-center gap-3 border-b border-white/6">
        <span class="w-2 h-8 rounded-full shrink-0" :style="{ background: v.net_id ? 'var(--ob-accent)' : 'rgba(255,255,255,.15)' }" :title="v.net_id ? 'Spawned' : 'Not spawned'" />
        <span class="min-w-0 flex-1">
          <span class="block text-[12px] truncate">{{ v.display_name || v.name }}</span>
          <span class="block ob-mono text-[9px] text-white/35 truncate">{{ v.plate || '—' }} · {{ v.name }} · owner {{ v.owner_type }}#{{ v.owner_id }}</span>
        </span>
        <button :disabled="!v.net_id" @click="teleportToAdmin(v)" class="ob-mono text-[9px] px-1.5 py-1 rounded border border-white/12 hover:bg-white/8 disabled:opacity-30">GOTO</button>
        <button @click="deleteVehicle(v)" class="ob-mono text-[9px] px-1.5 py-1 rounded border border-white/12 text-red-300 hover:bg-red-500/10">DELETE</button>
      </div>
      <div v-if="!vehicles.length" class="py-6 text-center text-[11.5px] text-white/30">No vehicles.</div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Wire it into AdminPanel.vue**

```diff
 import ModerationTab from './ModerationTab.vue'
+import VehiclesTab from './VehiclesTab.vue'
```

```diff
       <ModerationTab v-else-if="activeTab === 'moderation'" />
+      <VehiclesTab v-else-if="activeTab === 'vehicles'" />
```

- [ ] **Step 3: Manual verification**

Run: dev server as in Task 10, open `/Admin` → Vehicles tab.
Expected: dev-fixture rows render, GOTO is disabled on the non-spawned row and enabled on the spawned one, DELETE is clickable, no console errors.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_admin/web/VehiclesTab.vue plugins/oblsk_admin/web/AdminPanel.vue
git commit -m "feat(admin): add Vehicles tab UI"
```

---

### Task 13: Items tab Vue component

**Files:**
- Create: `core/plugins/oblsk_admin/web/ItemsTab.vue`
- Modify: `core/plugins/oblsk_admin/web/AdminPanel.vue`

**Interfaces:**
- Consumes: `admin:client:items-list` (emit), `admin:client:items-reply` (on) — payload `{ items: [...base_items rows] }`, matching Task 4's `listBaseItems()`.

- [ ] **Step 1: Write the component**

```vue
<!-- core/plugins/oblsk_admin/web/ItemsTab.vue -->
<script setup>
import { ref, computed, onMounted, onBeforeUnmount, inject, watch } from 'vue'
import Obelisk from '@/obelisk.js'

const items = ref([])
const selectedId = ref(null)
const createDraft = ref(null)
const giveDraft = ref(null)

const selected = computed(() => items.value.find(i => i.id === selectedId.value) || null)

const DEV_ITEMS = [
  { id: 1, name: 'water', description: 'A bottle of water', icon: 'water', weight: 0.5, is_takeable: 1, is_giveable: 1, is_dropable: 1, is_container: 0, is_useable: 1, is_stackable: 1, max_stack_amount: 10 },
  { id: 2, name: 'bandage', description: 'Stops bleeding', icon: 'bandage', weight: 0.2, is_takeable: 1, is_giveable: 1, is_dropable: 1, is_container: 0, is_useable: 1, is_stackable: 1, max_stack_amount: 5 },
]

const onReply = ({ items: next }) => { items.value = next }

const fetchList = () => {
  if (import.meta.env.DEV) { items.value = DEV_ITEMS; return }
  Obelisk.emit('admin:client:items-list', {})
}

onMounted(() => {
  Obelisk.on('admin:client:items-reply', onReply)
  fetchList()
})
onBeforeUnmount(() => Obelisk.off('admin:client:items-reply', onReply))

const registry = inject('obelisk:globalElementsRegistry', null)
if (registry) {
  watch(() => registry.get('admin')?.visible, (visible) => { if (visible) fetchList() })
}

const FLAGS = ['is_takeable', 'is_giveable', 'is_dropable', 'is_container', 'is_useable', 'is_stackable']

const updateField = (item, field, value) => {
  Obelisk.emit('admin:client:items-update', { baseItemId: item.id, attributes: { [field]: value } })
}
const toggleFlag = (item, flag) => updateField(item, flag, item[flag] ? 0 : 1)

const openCreate = () => { createDraft.value = { name: '', description: '', weight: 0, max_stack_amount: 1 } }
const submitCreate = () => {
  Obelisk.emit('admin:client:items-create', { attributes: createDraft.value })
  createDraft.value = null
}

const openGive = (item) => { giveDraft.value = { item, targetSource: '', amount: 1 } }
const submitGive = () => {
  Obelisk.emit('admin:client:items-give', { targetSource: Number(giveDraft.value.targetSource), baseItemId: giveDraft.value.item.id, amount: Number(giveDraft.value.amount) })
  giveDraft.value = null
}
</script>

<template>
  <div class="grid gap-3 min-h-0 p-5" style="grid-template-columns: 300px 1fr">
    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex flex-col">
      <div class="px-4 py-2.5 border-b border-white/8 flex items-center justify-between">
        <span class="text-[12.5px] font-medium">Items · {{ items.length }}</span>
        <button @click="openCreate" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">+ NEW</button>
      </div>
      <div class="overflow-y-auto" style="max-height: 520px">
        <button v-for="i in items" :key="i.id" @click="selectedId = i.id"
          class="w-full px-3.5 py-2.5 text-left border-b border-white/6 transition"
          :class="selectedId === i.id ? 'bg-white/[0.07]' : 'hover:bg-white/4'">
          <span class="block text-[12px] truncate">{{ i.name }}</span>
          <span class="block ob-mono text-[9px] text-white/35 truncate">{{ i.weight }}kg · stack {{ i.max_stack_amount || 1 }}</span>
        </button>
        <div v-if="!items.length" class="py-6 text-center text-[11.5px] text-white/30">No items.</div>
      </div>
    </div>

    <div v-if="createDraft" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-3">
      <div class="text-[13px] font-medium">New item</div>
      <input v-model="createDraft.name" placeholder="Name" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
      <input v-model="createDraft.description" placeholder="Description" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
      <input v-model.number="createDraft.weight" type="number" step="0.1" placeholder="Weight" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
      <div class="flex gap-2">
        <button @click="createDraft = null" class="h-9 px-3.5 rounded-lg border border-white/12 text-[12px]">Cancel</button>
        <button @click="submitCreate" class="h-9 px-4 rounded-lg text-black text-[12px] font-medium" style="background: var(--ob-accent)">Create item</button>
      </div>
    </div>

    <div v-else-if="selected" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-3">
      <div>
        <div class="ob-mono text-[9px] tracking-[0.2em] text-white/30 uppercase mb-1.5">Description</div>
        <input :value="selected.description" @change="updateField(selected, 'description', $event.target.value)" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
      </div>
      <div class="flex flex-wrap gap-1.5">
        <button v-for="flag in FLAGS" :key="flag" @click="toggleFlag(selected, flag)"
          class="ob-mono text-[9px] px-2 py-1 rounded border"
          :class="selected[flag] ? 'border-white/30 text-black font-medium' : 'border-white/12 text-white/40'"
          :style="selected[flag] ? { background: 'var(--ob-accent)' } : undefined">{{ flag.replace('is_', '') }}</button>
      </div>
      <div class="pt-2">
        <button @click="openGive(selected)" class="h-9 px-4 rounded-lg text-black text-[12px] font-medium" style="background: var(--ob-accent)">Give to player</button>
      </div>
    </div>

    <div v-else class="grid place-items-center text-white/30 text-[12px]">No item selected.</div>

    <div v-if="giveDraft" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-3 col-span-2">
      <div class="text-[13px] font-medium">Give {{ giveDraft.item.name }}</div>
      <input v-model="giveDraft.targetSource" placeholder="Player server ID" type="number" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
      <input v-model="giveDraft.amount" placeholder="Amount" type="number" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
      <div class="flex gap-2">
        <button @click="giveDraft = null" class="h-9 px-3.5 rounded-lg border border-white/12 text-[12px]">Cancel</button>
        <button @click="submitGive" class="h-9 px-4 rounded-lg text-black text-[12px] font-medium" style="background: var(--ob-accent)">Give</button>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Wire it into AdminPanel.vue**

```diff
 import VehiclesTab from './VehiclesTab.vue'
+import ItemsTab from './ItemsTab.vue'
```

```diff
       <VehiclesTab v-else-if="activeTab === 'vehicles'" />
+      <ItemsTab v-else-if="activeTab === 'items'" />
       <ComingSoon v-else :label="TABS.find(([k]) => k === activeTab)[1]" />
```

(The trailing `ComingSoon` fallback now only covers Blips, Locations, Economy, Server, Audit log — unchanged, still their own future sub-projects.)

- [ ] **Step 3: Manual verification**

Run: dev server as in Task 10, open `/Admin` → Items tab.
Expected: dev-fixture list renders, selecting an item shows its flags, toggling a flag/editing description doesn't error, +NEW opens the create form, "Give to player" opens the give form, no console errors.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_admin/web/ItemsTab.vue plugins/oblsk_admin/web/AdminPanel.vue
git commit -m "feat(admin): add Items tab UI"
```

---

### Task 14: Full test suite + in-game verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run every new/modified Lua spec from `core/`**

```bash
lua5.4 modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua
lua5.4 modules/oblsk_accounts/tests/account_service_moderation_spec.lua
lua5.4 modules/oblsk_accounts/tests/account_service_spec.lua
lua5.4 modules/oblsk_vehicles/tests/vehicle_service_admin_spec.lua
lua5.4 modules/oblsk_items/tests/item_service_admin_spec.lua
```

Expected: every file prints `N passed, 0 failed` and exits 0. Re-running `account_service_spec.lua` (pre-existing) guards against `Character`/`ModerationLog` global leakage from Task 2 breaking the original suite.

- [ ] **Step 2: In-game verification (per repo convention — no automated NUI tests)**

Start the server (existing `docker-compose.yml`/dev workflow), connect as an ace-`admin` player, press `F6`, walk through:
- Players: confirm the online list matches connected players, GOTO/BRING move real entities, KICK drops the target and the reason shows in their disconnect message.
- Moderation: ban a test account (short duration), confirm they're dropped if online and `checkBan` blocks reconnect until it expires/is revoked from the tab; warn and kick a test account, confirm both show up in the log list.
- Vehicles: spawn a vehicle via an existing flow (e.g. Garage), confirm it appears with GOTO enabled, GOTO moves the admin to it, DELETE removes it from the world and the list.
- Items: create a new base item, edit its flags, give it to an online test character, confirm it lands in their inventory (via the Inventory UI).

- [ ] **Step 3: Commit (only if verification turned up fixes)**

If manual verification finds a bug, fix it, re-run the relevant spec(s) from Step 1, and commit the fix on its own:

```bash
git add -A
git commit -m "fix(admin): <describe the fix>"
```
