# Garage Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `oblsk_garage` — a full plugin (DB, server, client, Vue UI) that lets a player open a named garage, browse the vehicles homed there, rename/favourite them, and park in/out.

**Architecture:** The plugin owns `garages` (each referencing one core `interactions` row for its coords). Core module `oblsk_vehicles` grows five generic instance columns on `vehicles` — `plate`, `display_name`, `fuel_level`, `stored`, `garage_id` (FK → `garages.id`), `favorite` — so `oblsk_vehicles`' migration must run after `oblsk_garage`'s `garages` table exists (an inverted, deliberately-accepted dependency; see the design spec). Server `GarageService` is the only thing that mutates vehicle/garage state — every mutating call re-resolves the caller's active character and checks it against `vehicles.owner_id` before doing anything. NUI wiring mirrors `nativeMenu`: `WebView.openPage` + a sync event in, `Obelisk.emit` calls out, close via the existing `core:client:close` path.

**Tech Stack:** Lua 5.4 (FXServer), Obelisk ORM (`BaseModel`, `QueryBuilder`, `Schema`), Vue 3 `<script setup>`, Tailwind (already configured, no CDN).

## Global Constraints

- `garages` table must be created (Task 1) before the `vehicles` migration that FKs to it (Task 2) — order matters here, unlike most cross-module work.
- No join table: `garage_id` and `favorite` live directly on `vehicles`.
- Every mutating `GarageService` call takes `source` (player server id) and re-derives the character server-side via `CharacterService.getActiveCharacterId(source)` — never trust a client-supplied character/owner id.
- Follow existing model convention: `Model = BaseModel:extend('table_name')`, `fillable`, `timestamps = true` (see `modules/oblsk_organizations/server/models/Organization.lua`).
- Lua test convention (this repo does NOT use `busted`): plain `.lua` spec files run directly via `lua5.4 path/to/x_spec.lua`, with a hand-rolled `test(name, fn)`/`eq(actual, expected)`/`truthy(v)` harness declared at the top of each spec file, `dofile()` chains to load dependencies, and `tests/support/fake_query_builder.lua`'s `makeFakeQueryBuilderModule(tables)` factory swapped in for the real global `QueryBuilder` around each test. See `tests/permission_service_spec.lua` for the exact pattern (`withFakeDb` helper) — write these for `oblsk_garage`.
- `CharacterService.getActiveCharacterId(source)` is backed by an in-memory table (`CharacterService.sessionCharacters[source]`), not the database — stub it in tests by setting that table directly, no QueryBuilder fake needed for it.
- `BaseModel` instances store fields under `instance.attributes.<field>`, NOT as direct properties (`model.attributes.name`, not `model.name`) — confirmed against `tests/orm_spec.lua` and `modules/oblsk_organizations/tests/department_rank_model_spec.lua`. `GarageService` never touches this — it reads/writes plain `QueryBuilder` rows, which ARE flat tables (`row.plate` is correct there).
- Nothing in this plan requires changing shared core ORM files (`core/server/ORM/*`) — they already provide everything needed. If a task's tests seem to require a core ORM change, the test is wrong, not the ORM — fix the test, don't touch shared framework code.

---

### Task 1: `oblsk_garage` schema — `garages`

**Files:**
- Create: `plugins/oblsk_garage/server/migrations/2026_08_12_060000_create_garages_table.lua`
- Create: `plugins/oblsk_garage/server/migrations.json`
- Create: `plugins/oblsk_garage/server/models/Garage.lua`
- Test: `plugins/oblsk_garage/tests/garage_model_spec.lua`
- Test: `plugins/oblsk_garage/tests/support/fake_query_builder.lua`

**Interfaces:**
- Produces: `Garage = BaseModel:extend('garages')` with `fillable = {'name', 'type', 'interaction_id'}`.

- [ ] **Step 1: Write the migration**

```lua
--- Migration: Create garages table
return {
    up = function()
        Schema.create('garages', function(table)
            table:id()
            table:string('name', 100):notNullable()
            table:string('type', 20):default('public')
            table:foreignId('interaction_id'):constrained('interactions'):onDelete('CASCADE'):notNullable()
            table:timestamps()

            table:unique('interaction_id')
        end)

        print('[Migration] Created garages table')
    end,

    down = function()
        Schema.drop('garages')
        print('[Migration] Dropped garages table')
    end
}
```

- [ ] **Step 2: Register the migration**

```json
{
  "migrations": [
    "2026_08_12_060000_create_garages_table"
  ]
}
```

- [ ] **Step 3: Write the model**

```lua
--- Garage Model - a named vehicle garage. Coordinates live on the linked
--- core `interactions` row, not here — the garage just references it.
Garage = BaseModel:extend('garages')

Garage.primaryKey = 'id'
Garage.timestamps = true
Garage.fillable = { 'name', 'type', 'interaction_id' }
Garage.hidden = {}

return Garage
```

- [ ] **Step 4: Copy the fake QueryBuilder test support**

Run: `cp tests/support/fake_query_builder.lua plugins/oblsk_garage/tests/support/fake_query_builder.lua`

- [ ] **Step 5: Write the failing model spec**

```lua
-- plugins/oblsk_garage/tests/garage_model_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_garage/tests/garage_model_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(scriptDir .. '../server/models/Garage.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('Garage is fillable with name, type, interaction_id', function()
    local g = Garage.new({ name = 'Mission Row', type = 'public', interaction_id = 1 })
    eq(g.attributes.name, 'Mission Row')
    eq(g.attributes.type, 'public')
    eq(g.attributes.interaction_id, 1)
end)

print('\nRunning Garage model unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err))
    end
end

print('\n' .. passed .. ' passed, ' .. #failures .. ' failed')
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 6: Run the spec, confirm it passes**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_model_spec.lua`
Expected: `1 passed, 0 failed`.

- [ ] **Step 7: Syntax-check the migration**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/server/migrations/2026_08_12_060000_create_garages_table.lua'))"`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_garage
git add server/migrations server/migrations.json server/models tests
git commit -m "feat: add garages schema"
```

---

### Task 2: Extend `oblsk_vehicles` with instance + garage columns

**Files:**
- Create: `modules/oblsk_vehicles/server/migrations/2026_08_12_060100_add_instance_fields_to_vehicles_table.lua`
- Modify: `modules/oblsk_vehicles/server/migrations.json`
- Modify: `modules/oblsk_vehicles/server/models/Vehicle.lua`

**Interfaces:**
- Consumes: `garages` table (Task 1) — this migration FKs `vehicles.garage_id` to it, so it must run after Task 1's migration is registered.
- Produces: `vehicles.plate` (string, unique), `vehicles.display_name` (string, nullable), `vehicles.fuel_level` (float, default 100), `vehicles.stored` (boolean, default 1), `vehicles.garage_id` (integer, nullable, FK → `garages.id`), `vehicles.favorite` (boolean, default 0). `Vehicle.fillable` includes all six.

- [ ] **Step 1: Write the migration**

```lua
--- Migration: Add instance + garage fields to vehicles table
return {
    up = function()
        Schema.table('vehicles', function(table)
            table:string('plate', 12):unique()
            table:string('display_name', 100):nullable()
            table:float('fuel_level'):default(100)
            table:boolean('stored'):default(1)
            table:foreignId('garage_id'):constrained('garages'):onDelete('SET NULL')
            table:boolean('favorite'):default(0)
        end)

        print('[Migration] Added instance and garage fields to vehicles table')
    end,

    down = function()
        Schema.table('vehicles', function(table)
            table:dropColumn('plate')
            table:dropColumn('display_name')
            table:dropColumn('fuel_level')
            table:dropColumn('stored')
            table:dropColumn('garage_id')
            table:dropColumn('favorite')
        end)

        print('[Migration] Dropped instance and garage fields from vehicles table')
    end
}
```

- [ ] **Step 2: Register the migration**

Add `"2026_08_12_060100_add_instance_fields_to_vehicles_table"` to the end of the `migrations` array in `modules/oblsk_vehicles/server/migrations.json`.

- [ ] **Step 3: Update the model**

In `modules/oblsk_vehicles/server/models/Vehicle.lua`, change:

```lua
Vehicle.fillable = {
    'base_vehicle_id', 'key', 'owner_type', 'owner_id',
    'engine_on', 'backdoor_locked', 'alldoors_locked',
    'engine_health', 'body_health', 'body_damage',
}
```

to:

```lua
Vehicle.fillable = {
    'base_vehicle_id', 'key', 'owner_type', 'owner_id',
    'engine_on', 'backdoor_locked', 'alldoors_locked',
    'engine_health', 'body_health', 'body_damage',
    'plate', 'display_name', 'fuel_level', 'stored', 'garage_id', 'favorite',
}
```

- [ ] **Step 4: Syntax-check the migration**

Run: `lua5.4 -e "assert(loadfile('modules/oblsk_vehicles/server/migrations/2026_08_12_060100_add_instance_fields_to_vehicles_table.lua'))"`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
cd modules/oblsk_vehicles
git add server/migrations/2026_08_12_060100_add_instance_fields_to_vehicles_table.lua server/migrations.json server/models/Vehicle.lua
git commit -m "feat(vehicles): add plate, display_name, fuel_level, stored, garage_id, favorite columns"
```

---

### Task 3: `GarageService` (server) — list, rename, favourite

**Files:**
- Create: `plugins/oblsk_garage/server/services/GarageService.lua`
- Test: `plugins/oblsk_garage/tests/garage_service_spec.lua`

**Interfaces:**
- Consumes: `Garage` (Task 1), `Vehicle` columns from Task 2, `CharacterService.getActiveCharacterId(source)` (from `oblsk_characters`).
- Produces: `GarageService.list(garageId, characterId) -> { vehicle rows }`, `GarageService.rename(source, vehicleId, name) -> boolean, string|nil`, `GarageService.toggleFavorite(source, vehicleId) -> boolean, string|nil`. Both mutating functions return `true` on success or `false, "reason"` on failure (ownership check, not-found).

- [ ] **Step 1: Write the failing service spec**

```lua
-- plugins/oblsk_garage/tests/garage_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

-- Minimal stand-in for oblsk_characters' CharacterService: only the one
-- function GarageService actually calls, backed by a plain lookup table
-- (the real thing is in-memory too, see CharacterService.sessionCharacters).
CharacterService = { sessionCharacters = { [999] = 5 } }
function CharacterService.getActiveCharacterId(source)
    return CharacterService.sessionCharacters[source]
end

dofile(scriptDir .. '../server/services/GarageService.lua')

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

test('GarageService.list: only vehicles homed at the given garage and owned by the character', function()
    withFakeDb(function(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = 10, plate = 'ABC123', display_name = 'My Car', stored = true, favorite = false },
            { id = 200, owner_type = 'character', owner_id = 5, garage_id = 20, plate = 'XYZ999', display_name = 'Other', stored = true, favorite = false },
            { id = 300, owner_type = 'character', owner_id = 9, garage_id = 10, plate = 'NOPE001', display_name = 'Not mine', stored = true, favorite = false },
        }

        local list = GarageService.list(10, 5)

        eq(#list, 1)
        eq(list[1].plate, 'ABC123')
    end)
end)

test('GarageService.rename: rejects renaming a vehicle the character does not own', function()
    withFakeDb(function(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 9, plate = 'ABC123', display_name = 'My Car' },
        }

        -- source 999 resolves to characterId 5 (the CharacterService stub above);
        -- the vehicle is owned by character 9, so this must be rejected.
        local ok, reason = GarageService.rename(999, 100, 'New Name')

        eq(ok, false)
        eq(reason, 'not the owner')
    end)
end)

print('\nRunning GarageService unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err))
    end
end

print('\n' .. passed .. ' passed, ' .. #failures .. ' failed')
os.exit(#failures > 0 and 1 or 0)
```

Note: `source = 999` resolves to `characterId = 5` via the `CharacterService.sessionCharacters` stub defined right in this spec file — Task 4's appended tests reuse the same mapping.

- [ ] **Step 2: Run it, confirm it fails**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: FAIL to even load — `GarageService.lua` doesn't exist yet.

- [ ] **Step 3: Implement `GarageService`**

```lua
--- GarageService - lists and mutates vehicles homed at a garage. Every
--- mutating call re-resolves the caller's active character server-side and
--- checks it against the vehicle's owner before doing anything — never
--- trust a client-supplied owner id.
GarageService = {}

--- @param garageId number
--- @param characterId number
--- @return table[] rows: {id, plate, display_name, fuel_level, stored,
---   engine_health, body_health, favorite, base_vehicle_id}
function GarageService.list(garageId, characterId)
    local vehicles = QueryBuilder.new('vehicles')
        :where('garage_id', garageId)
        :where('owner_type', 'character')
        :where('owner_id', characterId)
        :getSync()

    local rows = {}
    for _, vehicle in ipairs(vehicles) do
        table.insert(rows, {
            id = vehicle.id,
            plate = vehicle.plate,
            display_name = vehicle.display_name,
            fuel_level = vehicle.fuel_level,
            stored = vehicle.stored,
            engine_health = vehicle.engine_health,
            body_health = vehicle.body_health,
            favorite = vehicle.favorite,
            base_vehicle_id = vehicle.base_vehicle_id,
        })
    end

    return rows
end

--- @param source number
--- @param vehicleId number
--- @return boolean, string|nil, table|nil vehicle
local function checkOwnership(source, vehicleId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'no active character', nil
    end

    local vehicle = QueryBuilder.new('vehicles'):where('id', vehicleId):firstSync()
    if not vehicle then
        return false, 'vehicle not found', nil
    end
    if vehicle.owner_type ~= 'character' or vehicle.owner_id ~= characterId then
        return false, 'not the owner', nil
    end

    return true, nil, vehicle
end

--- @param source number
--- @param vehicleId number
--- @param name string
--- @return boolean, string|nil
function GarageService.rename(source, vehicleId, name)
    local ok, reason = checkOwnership(source, vehicleId)
    if not ok then return false, reason end

    QueryBuilder.new('vehicles'):where('id', vehicleId):update({ display_name = name })
    return true, nil
end

--- @param source number
--- @param vehicleId number
--- @return boolean, string|nil
function GarageService.toggleFavorite(source, vehicleId)
    local ok, reason, vehicle = checkOwnership(source, vehicleId)
    if not ok then return false, reason end

    QueryBuilder.new('vehicles'):where('id', vehicleId):update({ favorite = not vehicle.favorite })
    return true, nil
end

return GarageService
```

- [ ] **Step 4: Run the spec again, confirm it passes**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd plugins/oblsk_garage
git add server/services/GarageService.lua tests/garage_service_spec.lua
git commit -m "feat: add GarageService list/rename/toggleFavorite"
```

---

### Task 4: `GarageService.parkToggle` — spawn/despawn coordination

**Files:**
- Modify: `plugins/oblsk_garage/server/services/GarageService.lua`
- Modify: `plugins/oblsk_garage/tests/garage_service_spec.lua`

**Interfaces:**
- Consumes: `checkOwnership` (private, this file, Task 3).
- Produces: `GarageService.parkToggle(source, vehicleId) -> boolean, string|nil, table|nil`. Third return is the payload the caller (net event handler, Task 5) forwards to the client: `{ action = 'spawn'|'despawn', plate, base_vehicle_id, engine_health, body_health, fuel_level }` on success.

- [ ] **Step 1: Add the failing test**

Insert into `plugins/oblsk_garage/tests/garage_service_spec.lua`, right before the `print('\nRunning GarageService unit tests\n')` line:

```lua
test('GarageService.parkToggle: flips stored and returns a spawn payload when parking out', function()
    withFakeDb(function(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, plate = 'ABC123',
              base_vehicle_id = 1, engine_health = 1000, body_health = 1000,
              fuel_level = 80, stored = true },
        }

        local ok, reason, payload = GarageService.parkToggle(999, 100)

        eq(ok, true)
        eq(reason, nil)
        eq(payload.action, 'spawn')
        eq(payload.plate, 'ABC123')
    end)
end)
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'parkToggle')`.

- [ ] **Step 3: Implement it**

Add to `GarageService.lua`:

```lua
--- @param source number
--- @param vehicleId number
--- @return boolean, string|nil, table|nil
function GarageService.parkToggle(source, vehicleId)
    local ok, reason, vehicle = checkOwnership(source, vehicleId)
    if not ok then return false, reason, nil end

    local nowStored = not vehicle.stored
    QueryBuilder.new('vehicles'):where('id', vehicleId):update({ stored = nowStored })

    return true, nil, {
        action = nowStored and 'despawn' or 'spawn',
        plate = vehicle.plate,
        base_vehicle_id = vehicle.base_vehicle_id,
        engine_health = vehicle.engine_health,
        body_health = vehicle.body_health,
        fuel_level = vehicle.fuel_level,
    }
end
```

- [ ] **Step 4: Run the spec again, confirm it passes**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd plugins/oblsk_garage
git add server/services/GarageService.lua tests/garage_service_spec.lua
git commit -m "feat: add GarageService.parkToggle"
```

---

### Task 5: Server wiring — interaction, action, net events

**Files:**
- Create: `plugins/oblsk_garage/server/main.lua`
- Create: `plugins/oblsk_garage/fxmanifest.lua`

**Interfaces:**
- Consumes: `GarageService.list/rename/toggleFavorite/parkToggle` (Tasks 3-4), `InteractionService.register` and `ActionService.register` (core), `WebView.openPage`/`WebView.focus` (core server relay), `Obelisk.emitClient`/`Obelisk.onServer` (core).
- Produces: net events `garage:client:rename`, `garage:client:toggleFavorite`, `garage:client:parkToggle` (client → server); `garage:server:sync`, `garage:server:parkResult` (server → client).

- [ ] **Step 1: Write `server/main.lua`**

```lua
--- Garage Plugin - Server Main
print('[Garage] Loading...')

local function openForSource(source, garageId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    local vehicles = GarageService.list(garageId, characterId)
    local garage = QueryBuilder.new('garages'):where('id', garageId):firstSync()
    if not garage then return end

    WebView.openPage(source, '/Garage')
    WebView.focus(source)
    Obelisk.emitClient('garage:server:sync', source, { garage = garage, vehicles = vehicles })
end

ActionService.register('garage:open', function(source, data)
    local garageId = data and data.interaction and data.interaction.options and data.interaction.options.garageId
    if not garageId then return end
    openForSource(source, garageId)
end, { label = 'Open garage' })

--- Registers every Garage row's interaction point. Safe to call more than
--- once (InteractionService keys by id, garages already have a stable
--- interaction_id from the migration/seed step).
local function registerAllGarages()
    local garages = QueryBuilder.new('garages'):getSync()
    for _, garage in ipairs(garages) do
        local interaction = QueryBuilder.new('interactions'):where('id', garage.interaction_id):firstSync()
        if interaction then
            InteractionService.register({
                x = interaction.x, y = interaction.y, z = interaction.z,
                range = interaction.range, label = interaction.label or garage.name,
                action = 'garage:open',
                options = { garageId = garage.id },
            })
        end
    end
end

Obelisk.onServer('garage:client:rename', function(vehicleId, name)
    local source = source
    GarageService.rename(source, vehicleId, name)
end)

Obelisk.onServer('garage:client:toggleFavorite', function(vehicleId)
    local source = source
    GarageService.toggleFavorite(source, vehicleId)
end)

Obelisk.onServer('garage:client:parkToggle', function(vehicleId)
    local source = source
    local ok, _, payload = GarageService.parkToggle(source, vehicleId)
    if ok then
        Obelisk.emitClient('garage:server:parkResult', source, payload)
    end
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    registerAllGarages()
    print('[Garage] Loaded successfully!')
end)
```

- [ ] **Step 2: Write `fxmanifest.lua`**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Garage'
author ''
version '1.0.0'

dependencies {
    'obelisk'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
    'web/routes.js',
}
```

- [ ] **Step 3: Syntax-check**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/server/main.lua'))"`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
cd plugins/oblsk_garage
git add server/main.lua fxmanifest.lua
git commit -m "feat: wire garage interaction, action, and net events"
```

---

### Task 6: Client — NUI relay + vehicle spawn/despawn

**Files:**
- Create: `plugins/oblsk_garage/client/main.lua`

**Interfaces:**
- Consumes: `WebView.emit`/`WebView.on` (core client), `Obelisk.onClient`/`Obelisk.emitServer` (core client), net events from Task 5 (`garage:server:sync`, `garage:server:parkResult`).
- Produces: NUI events `garage:sync` (relayed to the Vue page), and handles `garage:rename`/`garage:toggleFavorite`/`garage:parkToggle` NUI callbacks (from Task 7's Vue component).

- [ ] **Step 1: Write `client/main.lua`**

```lua
--- Garage Plugin - Client Main
local spawnedByPlate = {}

Obelisk.onClient('garage:server:sync', function(payload)
    WebView.emit('garage:sync', payload)
end)

Obelisk.onClient('garage:server:parkResult', function(payload)
    if payload.action == 'spawn' then
        Citizen.CreateThread(function()
            local coords = GetEntityCoords(PlayerPedId())
            local hash = GetHashKey(payload.base_vehicle_id)
            RequestModel(hash)
            local waited = 0
            while not HasModelLoaded(hash) and waited < 5000 do
                Citizen.Wait(50)
                waited = waited + 50
            end
            if not HasModelLoaded(hash) then return end

            local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, GetEntityHeading(PlayerPedId()), true, false)
            SetVehicleNumberPlateText(vehicle, payload.plate)
            SetVehicleEngineHealth(vehicle, payload.engine_health)
            SetVehicleBodyHealth(vehicle, payload.body_health)
            SetVehicleFuelLevel(vehicle, payload.fuel_level + 0.0)
            spawnedByPlate[payload.plate] = vehicle
            SetModelAsNoLongerNeeded(hash)
        end)
    elseif payload.action == 'despawn' then
        local vehicle = spawnedByPlate[payload.plate]
        if vehicle and DoesEntityExist(vehicle) then
            DeleteEntity(vehicle)
        end
        spawnedByPlate[payload.plate] = nil
    end
end)

WebView.on('garage:rename', function(data)
    Obelisk.emitServer('garage:client:rename', data.vehicleId, data.name)
end)

WebView.on('garage:toggleFavorite', function(data)
    Obelisk.emitServer('garage:client:toggleFavorite', data.vehicleId)
end)

WebView.on('garage:parkToggle', function(data)
    Obelisk.emitServer('garage:client:parkToggle', data.vehicleId)
end)
```

- [ ] **Step 2: Syntax-check**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/client/main.lua'))"`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
cd plugins/oblsk_garage
git add client/main.lua
git commit -m "feat: add garage client relay and vehicle spawn/despawn"
```

---

### Task 7: `Garage.vue` — port of the design

**Files:**
- Create: `plugins/oblsk_garage/web/Garage.vue`
- Create: `plugins/oblsk_garage/web/routes.js`

**Interfaces:**
- Consumes: `Obelisk` singleton (`core/web/src/obelisk.js`, resolved at build time via the plugin glob — import as `../../../web/src/obelisk.js`, same relative pattern `nativeMenu` uses from inside `core/web/src/pages/`).
- Produces: route `/Garage` registered into the core Vue router (via `import.meta.glob('plugins/*/web/routes.js')`, already wired in `core/web/src/router/index.js`).

- [ ] **Step 1: Write `web/routes.js`**

```javascript
export default [
  {
    path: '/Garage',
    name: 'Garage',
    component: () => import('./Garage.vue')
  }
]
```

- [ ] **Step 2: Write `web/Garage.vue`**

```vue
<template>
  <div v-if="garage" class="absolute inset-0 flex justify-end pointer-events-none" style="--ob-accent:#10b981">
    <div
      class="pointer-events-auto w-[520px] h-full flex flex-col overflow-hidden shadow-2xl"
      :class="closing ? 'animate-[ggOut_.28s_cubic-bezier(.4,0,1,1)_forwards]' : 'animate-[ggIn_.42s_cubic-bezier(.16,.84,.24,1)]'"
      style="border-top-left-radius:18px;border-bottom-left-radius:18px;border-left:1px solid rgba(255,255,255,.09);background:linear-gradient(180deg,#121a20 0%,#0e161c 45%,#0b1218 100%)"
    >
      <div class="shrink-0 px-7 pt-7 pb-5 flex items-start gap-5">
        <div class="w-[62px] h-[62px] rounded-[10px] grid place-items-center shrink-0" style="background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12)">
          <svg viewBox="0 0 40 40" width="34" height="34">
            <path d="M6 19 L20 8 L34 19 L34 34 L6 34 Z" fill="color-mix(in oklab, var(--ob-accent) 55%, #0b1a14)" />
            <path d="M4 19.5 L20 6.5 L36 19.5" fill="none" stroke="var(--ob-accent)" stroke-width="3" stroke-linecap="round" />
            <rect x="12" y="24" width="16" height="10" fill="#e9eef2" />
            <path d="M12 27 h16 M12 30 h16" stroke="#9fb3c0" stroke-width="1.2" />
          </svg>
        </div>
        <div class="min-w-0">
          <div class="text-[28px] font-extrabold leading-none tracking-tight" style="color:var(--ob-accent)">{{ garage.name }}</div>
          <div class="text-[18px] leading-none mt-1 italic text-[#e8f2f8]">Garage</div>
        </div>
        <div class="flex-1 min-w-0 pl-3">
          <div class="text-[16px] font-semibold text-white/90">Information</div>
          <div class="text-[12.5px] text-white/45 leading-snug mt-1">Vehicles stored at this garage. Take one out or check its condition before you drive.</div>
        </div>
        <button
          @click="dismiss"
          class="ob-mono text-[10px] px-2 h-6 rounded-md shrink-0 text-white/55 hover:text-white transition"
          style="background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.12)"
        >esc</button>
      </div>

      <div class="shrink-0 px-7 pb-4 flex items-center gap-4">
        <span class="w-9 h-9 rounded-lg grid place-items-center shrink-0" style="background:rgba(255,255,255,.07)">
          <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" class="text-white/70"><path d="M3 12l2-6a2 2 0 0 1 2-1.4h10A2 2 0 0 1 19 6l2 6M4 12h16v6a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1v-1H6v1a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1v-6Z"/><circle cx="7" cy="15" r="1.4"/><circle cx="17" cy="15" r="1.4"/></svg>
        </span>
        <div class="min-w-0">
          <div class="text-[16px] font-semibold leading-tight">Select Vehicle</div>
          <div class="text-[12px] text-white/40 leading-tight">Choose</div>
        </div>
        <div class="ml-auto relative w-[240px]">
          <input
            v-model="query"
            placeholder="Search ..."
            class="w-full h-9 rounded-md pl-3 pr-9 text-[12.5px] outline-none placeholder:text-white/30"
            style="background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.1)"
          />
        </div>
      </div>

      <div class="shrink-0 px-7 pb-3 flex gap-1.5">
        <button
          v-for="tab in tabs"
          :key="tab.key"
          @click="where = tab.key"
          class="h-8 px-3 rounded-md text-[12px] flex items-center gap-1.5 transition"
          :style="where === tab.key
            ? { background: 'color-mix(in oklab, var(--ob-accent) 18%, transparent)', border: '1px solid color-mix(in oklab, var(--ob-accent) 50%, transparent)', color: 'color-mix(in oklab, var(--ob-accent) 40%, #ffffff)' }
            : { background: 'rgba(255,255,255,.05)', border: '1px solid rgba(255,255,255,.08)', color: 'rgba(255,255,255,.5)' }"
        >
          {{ tab.label }}<span class="ob-mono text-[10px] opacity-60">{{ tab.count }}</span>
        </button>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto px-7 pb-4">
        <div v-if="!filtered.length" class="ob-mono text-[11px] text-white/35 py-10 text-center">
          {{ query.trim() ? `NO VEHICLE MATCHES "${query}"` : where === 'out' ? 'EVERY VEHICLE IS PARKED' : 'NOTHING IN THE GARAGE' }}
        </div>
        <div class="grid grid-cols-2 gap-3">
          <div
            v-for="v in filtered"
            :key="v.id"
            class="rounded-[10px] p-3 flex flex-col"
            :style="{
              background: selectedId === v.id ? 'color-mix(in oklab, var(--ob-accent) 12%, transparent)' : 'rgba(255,255,255,.035)',
              border: `1px solid ${selectedId === v.id ? 'color-mix(in oklab, var(--ob-accent) 55%, transparent)' : 'rgba(255,255,255,.07)'}`
            }"
          >
            <div class="flex items-start gap-1.5">
              <div class="min-w-0 flex-1">
                <input
                  v-if="renaming === v.id"
                  v-model="draft"
                  autofocus
                  @blur="commitRename"
                  @keydown.enter="commitRename"
                  @keydown.escape="renaming = null"
                  class="w-full text-[13.5px] font-semibold leading-tight bg-transparent outline-none text-white"
                  style="border-bottom:1px dashed rgba(255,255,255,.35)"
                />
                <div v-else class="text-[13.5px] font-semibold leading-tight truncate" @dblclick="startRename(v)">
                  {{ v.display_name || 'Unnamed' }}
                </div>
                <div class="text-[11.5px] text-white/40 leading-tight mt-0.5">Vehicle</div>
              </div>
              <button
                title="Rename"
                @click="startRename(v)"
                class="w-[18px] h-[18px] rounded grid place-items-center shrink-0 text-white/25 hover:text-white hover:bg-white/10 transition"
              >✎</button>
              <button
                :title="v.favorite ? 'Unstar' : 'Star'"
                @click="toggleFavorite(v)"
                class="w-[18px] h-[18px] rounded grid place-items-center shrink-0 transition hover:bg-white/10"
                :style="{ color: v.favorite ? '#f0b83c' : 'rgba(255,255,255,.25)' }"
              >★</button>
              <span
                class="w-[7px] h-[7px] rounded-full mt-1 shrink-0"
                :style="{ background: v.stored ? '#22c55e' : '#ef4444', boxShadow: `0 0 6px ${v.stored ? 'rgba(34,197,94,.7)' : 'rgba(239,68,68,.7)'}` }"
              />
            </div>
            <div class="relative h-[70px] mt-2 rounded-[6px] grid place-items-center" style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.06)">
              <div class="absolute right-1 bottom-1 rounded-[3px] px-1.5 pt-[3px] pb-[2px] text-center" style="background:#f4f5f6;border:1px solid rgba(0,0,0,.35)">
                <div class="ob-mono text-[11px] font-semibold leading-none" style="color:#2f56b8">{{ v.plate }}</div>
              </div>
            </div>
            <button
              @click="selectedId = v.id"
              class="mt-3 h-[30px] rounded-md flex items-center justify-center gap-1.5 text-[12px] transition"
              :style="selectedId === v.id
                ? { background: 'var(--ob-accent)', color: '#04140e', fontWeight: 600 }
                : { background: 'rgba(255,255,255,.055)', color: 'rgba(255,255,255,.55)' }"
            >Select</button>
          </div>
        </div>
      </div>

      <div class="shrink-0 px-7 pt-4 pb-6" style="border-top:1px solid rgba(255,255,255,.07);background:rgba(0,0,0,.25)">
        <button
          v-if="selected"
          @click="parkToggle"
          class="w-full h-[46px] rounded-md flex items-center justify-center gap-2 text-[14px] font-medium transition hover:brightness-110"
          :style="!selected.stored
            ? { background: 'var(--ob-accent)', color: '#04140e' }
            : { background: '#e0a63c', color: '#241704' }"
        >{{ selected.stored ? 'Park Out' : 'Park In' }}</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'

const garage = ref(null)
const vehicles = ref([])
const query = ref('')
const where = ref('all')
const selectedId = ref(null)
const renaming = ref(null)
const draft = ref('')
const closing = ref(false)

const tabs = computed(() => [
  { key: 'all', label: 'All', count: vehicles.value.length },
  { key: 'in', label: 'In garage', count: vehicles.value.filter(v => v.stored).length },
  { key: 'out', label: 'Out of garage', count: vehicles.value.filter(v => !v.stored).length },
])

const filtered = computed(() => {
  return vehicles.value
    .filter(v => where.value === 'all' || (where.value === 'in' ? v.stored : !v.stored))
    .filter(v => !query.value.trim() || `${v.display_name || ''}${v.plate}`.toLowerCase().includes(query.value.trim().toLowerCase()))
    .sort((a, b) => (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0))
})

const selected = computed(() => vehicles.value.find(v => v.id === selectedId.value) || null)

function onSync(payload) {
  garage.value = payload.garage
  vehicles.value = payload.vehicles
  if (vehicles.value.length) selectedId.value = vehicles.value[0].id
}

function startRename(v) {
  renaming.value = v.id
  draft.value = v.display_name || ''
}

function commitRename() {
  if (renaming.value == null) return
  const name = draft.value.trim()
  const v = vehicles.value.find(x => x.id === renaming.value)
  if (name && v) {
    v.display_name = name
    Obelisk.emit('garage:rename', { vehicleId: v.id, name })
  }
  renaming.value = null
}

function toggleFavorite(v) {
  v.favorite = !v.favorite
  Obelisk.emit('garage:toggleFavorite', { vehicleId: v.id })
}

function parkToggle() {
  if (!selected.value) return
  selected.value.stored = !selected.value.stored
  Obelisk.emit('garage:parkToggle', { vehicleId: selected.value.id })
}

function dismiss() {
  closing.value = true
  setTimeout(() => {
    garage.value = null
    closing.value = false
    Obelisk.emit('core:client:close')
  }, 280)
}

function onKeydown(e) {
  if (e.key === 'Escape' && !renaming.value) dismiss()
}

onMounted(() => {
  Obelisk.on('garage:sync', onSync)
  window.addEventListener('keydown', onKeydown)
})

onBeforeUnmount(() => {
  Obelisk.off('garage:sync', onSync)
  window.removeEventListener('keydown', onKeydown)
})
</script>

<style scoped>
.ob-mono { font-family: 'JetBrains Mono', ui-monospace, monospace; }
@keyframes ggIn { from { transform: translateX(102%); } to { transform: none; } }
@keyframes ggOut { from { transform: none; } to { transform: translateX(102%); } }
</style>
```

- [ ] **Step 3: Build the core web bundle to confirm the route compiles**

Run: `cd web && npm run build`
Expected: build succeeds (this plugin lives under `core/plugins/`, matching the existing glob in `core/web/src/router/index.js`).

- [ ] **Step 4: Commit**

```bash
cd plugins/oblsk_garage
git add web/Garage.vue web/routes.js
git commit -m "feat: add Garage.vue UI"
```

---

### Task 8: README and registry

**Files:**
- Create: `plugins/oblsk_garage/README.md`
- Create: `plugins/oblsk_garage/shared/config.lua`

**Interfaces:** none (docs + empty config placeholder for future tuning, matching the scaffold convention).

- [ ] **Step 1: Write `shared/config.lua`**

```lua
Config = {}

Config.Debug = false

return Config
```

- [ ] **Step 2: Write `README.md`**

```markdown
# oblsk_garage

Named vehicle garages: park in/out, rename, favourite. Each garage
references one core `interactions` row for its coordinates. Vehicle
instance fields (`plate`, `display_name`, `fuel_level`, `stored`,
`garage_id`, `favorite`) live on `oblsk_vehicles`' `vehicles` table —
that module's migration depends on this plugin's `garages` table
existing first.

See [Garage plugin design](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-12-garage-plugin-design.md).

## Seeding a garage

Insert an `interactions` row for the garage door, then a `garages` row
pointing `interaction_id` at it. There is no admin UI for this yet —
insert directly or via a one-off seeder script.
```

- [ ] **Step 3: Run `obelisk registry:generate`**

Run (from the `core/` repo root — NOT inside the plugin repo): `node cli/index.js registry:generate`
Expected: output listing `plugins/registry.json: [..., oblsk_garage, ...]`. Note: `plugins/registry.json` is gitignored in the `core` repo (`plugins/*` in `.gitignore`) — it's a derived, locally-regenerated file, not something to commit. Nothing to add/commit in the `core` repo for this step.

- [ ] **Step 4: Commit**

```bash
cd plugins/oblsk_garage
git add README.md shared/config.lua
git commit -m "docs: add garage plugin README and config"
```
