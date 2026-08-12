# Garage Park-Out Positions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship named, occupancy-checked park-out spawn positions per garage, filter the "out of garage" vehicle list to only vehicles actually near their home garage, and add permission-gated commands for creating garages and authoring positions.

**Architecture:** A new `GarageParkOutPosition` model/table owned entirely by `oblsk_garage` (no cross-repo migration ordering, unlike `garages` itself). `GarageService.parkToggle`'s spawn path picks the first unoccupied position (native world-entity scan) instead of always using the garage's single interaction coordinate. `GarageService.list` filters `stored = false` rows by live entity proximity to the garage. Two new admin commands gate on `PermissionService.can('character', characterId, key)` rather than a blanket ace check, using the already-generic `/org-grant` command for granting.

**Tech Stack:** Lua 5.4 (FXServer), Obelisk ORM (`BaseModel`, `QueryBuilder`, `Schema`), Vue 3 `<script setup>`.

## Global Constraints

- Every mutating call re-derives the caller's character server-side via `CharacterService.getActiveCharacterId(source)` — never trust a client-supplied id (existing plugin-wide rule, see the base garage plan).
- `Schema` columns are **NOT NULL by default** — call `:nullable()` to opt into nullable, never `:notNullable()` (that method does not exist on `Blueprint`; see `core/server/ORM/Schema.lua`).
- Lua test convention (no `busted`): plain `.lua` spec files run via `lua5.4 path/to/x_spec.lua`, hand-rolled `test`/`eq` harness, `dofile()` chains, `tests/support/fake_query_builder.lua`'s `makeFakeQueryBuilderModule(tables)` swapped in for the real global `QueryBuilder`. See `plugins/oblsk_garage/tests/garage_service_spec.lua` for the exact pattern already in use.
- `BaseModel` instances store fields under `instance.attributes.<field>`, not as direct properties. `GarageService` reads/writes plain `QueryBuilder` rows, which are flat tables.
- Commands are not unit-tested anywhere in this codebase (no test file exists for `OrganizationCommands.lua` or `AccountCommands.lua`) — syntax-check only, matching the base garage plan's convention for `server/main.lua`/`client/main.lua`.
- `Character` is already a registered `PermissionService` owner type (`HasPermissions.apply(Character, 'character')` in `oblsk_characters`), and `/org-grant <ownerType> <ownerId> <key>` (in `oblsk_organizations`) is fully generic — no new grant command is needed for `garage_create`/`garage_edit`.

---

### Task 1: `GarageParkOutPosition` model + migration

**Files:**
- Create: `plugins/oblsk_garage/server/migrations/2026_08_12_070000_create_garage_park_out_positions_table.lua`
- Modify: `plugins/oblsk_garage/server/migrations.json`
- Create: `plugins/oblsk_garage/server/models/GarageParkOutPosition.lua`
- Test: `plugins/oblsk_garage/tests/garage_park_out_position_model_spec.lua`

**Interfaces:**
- Produces: `GarageParkOutPosition = BaseModel:extend('garage_park_out_positions')` with `fillable = {'garage_id', 'x', 'y', 'z', 'heading'}`.

- [ ] **Step 1: Write the migration**

```lua
--- Migration: Create garage_park_out_positions table
--- Named spawn slots for a garage's park-out flow. Owned entirely by this
--- plugin (unlike `garages` itself, which oblsk_vehicles has an inverted
--- dependency on) - no cross-repo ordering concerns.
return {
    up = function()
        Schema.create('garage_park_out_positions', function(table)
            table:id()
            table:foreignId('garage_id'):constrained('garages'):onDelete('CASCADE')
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('heading')
            table:timestamps()
        end)

        print('[Migration] Created garage_park_out_positions table')
    end,

    down = function()
        Schema.drop('garage_park_out_positions')
        print('[Migration] Dropped garage_park_out_positions table')
    end
}
```

- [ ] **Step 2: Register the migration**

Add `"2026_08_12_070000_create_garage_park_out_positions_table"` to the end of the `migrations` array in `plugins/oblsk_garage/server/migrations.json`.

- [ ] **Step 3: Write the model**

```lua
--- GarageParkOutPosition Model - a named spawn slot for parking a vehicle
--- out at a garage. Occupancy is checked live (world entity scan), not
--- tracked on this row - see GarageService.isPositionOccupied.
GarageParkOutPosition = BaseModel:extend('garage_park_out_positions')

GarageParkOutPosition.primaryKey = 'id'
GarageParkOutPosition.timestamps = true
GarageParkOutPosition.fillable = { 'garage_id', 'x', 'y', 'z', 'heading' }
GarageParkOutPosition.hidden = {}

return GarageParkOutPosition
```

- [ ] **Step 4: Write the failing model spec**

```lua
-- plugins/oblsk_garage/tests/garage_park_out_position_model_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_garage/tests/garage_park_out_position_model_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(scriptDir .. '../server/models/GarageParkOutPosition.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('GarageParkOutPosition is fillable with garage_id, x, y, z, heading', function()
    local p = GarageParkOutPosition.new({ garage_id = 10, x = 1.0, y = 2.0, z = 3.0, heading = 90.0 })
    eq(p.attributes.garage_id, 10)
    eq(p.attributes.x, 1.0)
    eq(p.attributes.y, 2.0)
    eq(p.attributes.z, 3.0)
    eq(p.attributes.heading, 90.0)
end)

print('\nRunning GarageParkOutPosition model unit tests\n')
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

- [ ] **Step 5: Run the spec, confirm it passes**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_park_out_position_model_spec.lua`
Expected: `1 passed, 0 failed`.

- [ ] **Step 6: Syntax-check the migration**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/server/migrations/2026_08_12_070000_create_garage_park_out_positions_table.lua'))"`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
cd plugins/oblsk_garage
git add server/migrations/2026_08_12_070000_create_garage_park_out_positions_table.lua server/migrations.json server/models/GarageParkOutPosition.lua tests/garage_park_out_position_model_spec.lua
git commit -m "feat: add garage_park_out_positions schema"
```

---

### Task 2: `GarageService.list` — filter "out" vehicles by proximity to their garage

**Files:**
- Modify: `plugins/oblsk_garage/server/services/GarageService.lua`
- Modify: `plugins/oblsk_garage/tests/garage_service_spec.lua`

**Interfaces:**
- Consumes: `distance3d` (private, this file), `VehicleService.activeNetIds` (`oblsk_vehicles`).
- Produces: `GarageService.list(garageId, characterId)` — unchanged signature, but now excludes any `stored = false` row whose live entity isn't within the garage's own interaction range (or has no live entity at all).

- [ ] **Step 1: Extend the test file's world stub to support per-entity coordinates**

The current stub in `garage_service_spec.lua` ignores its `entity` argument and always returns the player's coords — that's only correct for the existing park-toggle-range tests (which check the *player's* position). The new list tests need to check a *vehicle's* position instead. Replace the stub block:

```lua
_G.GetPlayerPed = function(source) return 1000 + source end
_G.GetEntityCoords = function() return world.playerCoords end
```

with:

```lua
_G.GetPlayerPed = function(source) return 1000 + source end
-- Per-entity coords, falling back to the player's coords for anything not
-- explicitly overridden (i.e. any GetPlayerPed(source) handle, which the
-- existing park-toggle range tests never set an override for).
_G.GetEntityCoords = function(entity)
    if world.entityCoords[entity] ~= nil then return world.entityCoords[entity] end
    return world.playerCoords
end
```

And add `entityCoords = {}` to the `world` table declaration:

```lua
local world = {
    playerCoords = { x = 0.0, y = 0.0, z = 0.0 },
    entityCoords = {}, -- entity handle -> {x, y, z}, overrides playerCoords when set
    entities = {}, -- entity handle -> {engineHealth, bodyHealth, fuelLevel}
    deleted = {},
}
```

And reset it inside `withFakeDb`, alongside the existing `world.entities = {}` line:

```lua
    world.entityCoords = {}
```

- [ ] **Step 2: Add the failing tests**

Insert into `garage_service_spec.lua`, right after the existing `'GarageService.list: only vehicles homed at the given garage and owned by the character'` test:

```lua
test('GarageService.list: includes an out vehicle whose live entity is near its garage', function()
    withFakeDb(function(tables)
        local garageId = seedGarage(tables) -- interaction at origin, range 5.0
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = garageId,
              plate = 'ABC123', stored = 0 },
        }
        VehicleService.activeNetIds[100] = 42
        world.entityCoords[42] = { x = 1.0, y = 0.0, z = 0.0 } -- within range 5.0

        local list = GarageService.list(garageId, 5)

        eq(#list, 1)
        eq(list[1].plate, 'ABC123')
    end)
end)

test('GarageService.list: excludes an out vehicle whose live entity is far from its garage', function()
    withFakeDb(function(tables)
        local garageId = seedGarage(tables) -- interaction at origin, range 5.0
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = garageId,
              plate = 'ABC123', stored = 0 },
        }
        VehicleService.activeNetIds[100] = 42
        world.entityCoords[42] = { x = 50.0, y = 0.0, z = 0.0 } -- far outside range

        local list = GarageService.list(garageId, 5)

        eq(#list, 0)
    end)
end)

test('GarageService.list: excludes an out vehicle with no live entity tracked', function()
    withFakeDb(function(tables)
        local garageId = seedGarage(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = garageId,
              plate = 'ABC123', stored = 0 },
        }
        -- Nothing in VehicleService.activeNetIds for vehicle 100.

        local list = GarageService.list(garageId, 5)

        eq(#list, 0)
    end)
end)

test('GarageService.list: still includes a stored (in-garage) vehicle regardless of any entity state', function()
    withFakeDb(function(tables)
        local garageId = seedGarage(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = garageId,
              plate = 'ABC123', stored = 1 },
        }

        local list = GarageService.list(garageId, 5)

        eq(#list, 1)
        eq(list[1].plate, 'ABC123')
    end)
end)
```

- [ ] **Step 3: Run the spec, confirm the new tests fail**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: the 4 new tests FAIL (list still returns every `garage_id`-matching row unconditionally), everything else still passes.

- [ ] **Step 4: Implement the proximity filter**

In `GarageService.lua`, add a new local function right after `distance3d` (before `GarageService.list` - it must be lexically in scope there):

```lua
--- @param vehicle table row with at least `id`
--- @param interaction table {x, y, z, range}
--- @return boolean
local function isVehicleNearInteraction(vehicle, interaction)
    local netId = VehicleService.activeNetIds[vehicle.id]
    if not netId then return false end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or not DoesEntityExist(entity) then return false end

    local coords = GetEntityCoords(entity)
    return distance3d(coords, interaction) <= (interaction.range or 2.0) + RANGE_TOLERANCE
end
```

Then replace `GarageService.list`'s body:

```lua
function GarageService.list(garageId, characterId)
    local vehicles = QueryBuilder.new('vehicles')
        :where('garage_id', garageId)
        :where('owner_type', 'character')
        :where('owner_id', characterId)
        :getSync()

    local garage = QueryBuilder.new('garages'):where('id', garageId):firstSync()
    local interaction = garage and QueryBuilder.new('interactions'):where('id', garage.interaction_id):firstSync() or nil

    local rows = {}
    for _, vehicle in ipairs(vehicles) do
        local include = isTruthyFlag(vehicle.stored)
            or (interaction ~= nil and isVehicleNearInteraction(vehicle, interaction))

        if include then
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
    end

    return rows
end
```

- [ ] **Step 5: Run the spec again, confirm it passes**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: `14 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
cd plugins/oblsk_garage
git add server/services/GarageService.lua tests/garage_service_spec.lua
git commit -m "feat: filter out-of-garage vehicles by proximity to their garage"
```

---

### Task 3: Occupancy-checked park-out positions

**Files:**
- Modify: `plugins/oblsk_garage/server/services/GarageService.lua`
- Modify: `plugins/oblsk_garage/tests/garage_service_spec.lua`
- Modify: `plugins/oblsk_garage/shared/config.lua`
- Modify: `plugins/oblsk_garage/fxmanifest.lua`

**Interfaces:**
- Consumes: `GarageParkOutPosition` table (Task 1).
- Produces: `GarageService.findFreePosition(positions, isOccupiedFn)` — pure, returns the first `position` for which `isOccupiedFn(position)` is falsy, or `nil` if none. `GarageService.isPositionOccupied(position, radius)` — the real world-scanning implementation (not unit tested, see Global Constraints). `GarageService.parkToggle`'s spawn branch now returns `false, 'garage full'` when no position is free.

- [ ] **Step 1: Fix the plugin's fxmanifest to actually load `shared/config.lua`**

The plugin's `fxmanifest.lua` has never included `shared_scripts` — `Config` is defined but was never loaded by either the client or server VM. Add, right after the `dependencies` block (matching `oblsk_character-selection/fxmanifest.lua`'s existing pattern):

```lua
shared_scripts {
    'shared/**/*.lua'
}
```

- [ ] **Step 2: Add the radius config value**

In `plugins/oblsk_garage/shared/config.lua`, add:

```lua
Config = {}

Config.Debug = false

-- Radius (metres) scanned around a park-out position for blocking
-- vehicles/peds/objects before it's considered occupied.
Config.ParkPositionRadius = 2.5

return Config
```

- [ ] **Step 3: Add the failing `findFreePosition` tests**

Insert into `garage_service_spec.lua`, right before the `print('\nRunning GarageService unit tests\n')` line:

```lua
test('GarageService.findFreePosition: returns the first position the occupancy check says is free', function()
    local positions = {
        { id = 1, x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        { id = 2, x = 10.0, y = 0.0, z = 0.0, heading = 0.0 },
        { id = 3, x = 20.0, y = 0.0, z = 0.0, heading = 0.0 },
    }
    local occupied = { [1] = true, [2] = false, [3] = false }

    local position = GarageService.findFreePosition(positions, function(p) return occupied[p.id] end)

    eq(position.id, 2)
end)

test('GarageService.findFreePosition: returns nil when every position is occupied', function()
    local positions = {
        { id = 1, x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        { id = 2, x = 10.0, y = 0.0, z = 0.0, heading = 0.0 },
    }

    local position = GarageService.findFreePosition(positions, function() return true end)

    eq(position, nil)
end)

test('GarageService.findFreePosition: returns nil for an empty position list', function()
    local position = GarageService.findFreePosition({}, function() return false end)

    eq(position, nil)
end)
```

- [ ] **Step 4: Run the spec, confirm the new tests fail**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'findFreePosition')`.

- [ ] **Step 5: Implement `findFreePosition` and `isPositionOccupied`**

Add to `GarageService.lua`, right after `isNearGarage` (before `rename`):

```lua
--- Pure position-picking: given a list of positions and a way to check
--- whether each one is occupied, returns the first free one (or nil). Kept
--- separate from isPositionOccupied so the picking logic is unit-testable
--- without stubbing world-scanning natives.
--- @param positions table[] {id, x, y, z, heading}
--- @param isOccupiedFn function(position) -> boolean
--- @return table|nil
function GarageService.findFreePosition(positions, isOccupiedFn)
    for _, position in ipairs(positions) do
        if not isOccupiedFn(position) then
            return position
        end
    end
    return nil
end

--- Real occupancy check: is there a vehicle, ped, or object within `radius`
--- metres of `position`? Not unit tested - GetAllVehicles/GetAllPeds/
--- GetAllObjects aren't meaningfully fakeable in the existing Lua spec
--- harness (see garage_service_spec.lua's world stub for what already is).
--- @param position table {x, y, z}
--- @param radius number
--- @return boolean
function GarageService.isPositionOccupied(position, radius)
    local function anyWithin(entities)
        for _, entity in ipairs(entities) do
            if DoesEntityExist(entity) then
                local coords = GetEntityCoords(entity)
                if distance3d(coords, position) <= radius then
                    return true
                end
            end
        end
        return false
    end

    return anyWithin(GetAllVehicles()) or anyWithin(GetAllPeds()) or anyWithin(GetAllObjects())
end
```

- [ ] **Step 6: Run the spec again, confirm the new `findFreePosition` tests pass**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: the 3 new tests pass; the existing spawn test (`stored = 1 (integer) parks the vehicle out...`) now FAILS - see next step, it needs updating for the position-based spawn.

- [ ] **Step 7: Update the existing spawn test and add "garage full" coverage**

Replace the existing test `'GarageService.parkToggle: stored = 1 (integer) parks the vehicle out and spawns it at the garage'` with:

```lua
test('GarageService.parkToggle: stored = 1 (integer) parks the vehicle out and spawns it at a free position', function()
    withFakeDb(function(tables)
        local garageId = seedGarage(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = garageId,
              plate = 'ABC123', base_vehicle_id = 1, stored = 1 },
        }
        tables.garage_park_out_positions = {
            { id = 1, garage_id = garageId, x = 3.0, y = 4.0, z = 0.0, heading = 90.0 },
        }
        GarageService.isPositionOccupied = function() return false end

        local ok, reason = GarageService.parkToggle(999, 100)

        eq(ok, true)
        eq(reason, nil)
        eq(findVehicle(tables, 100).stored, 0, 'stored flipped to 0 (out in the world)')
        eq(#VehicleService.spawnCalls, 1, 'spawned exactly once')
        eq(VehicleService.spawnCalls[1].vehicleId, 100)
        eq(VehicleService.spawnCalls[1].coords.x, 3.0, 'spawned at the free position, not the interaction')
        eq(VehicleService.spawnCalls[1].coords.heading, 90.0)
    end)
end)

test('GarageService.parkToggle: rejects park-out when every position is occupied', function()
    withFakeDb(function(tables)
        local garageId = seedGarage(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = garageId,
              plate = 'ABC123', base_vehicle_id = 1, stored = 1 },
        }
        tables.garage_park_out_positions = {
            { id = 1, garage_id = garageId, x = 3.0, y = 4.0, z = 0.0, heading = 90.0 },
        }
        GarageService.isPositionOccupied = function() return true end

        local ok, reason = GarageService.parkToggle(999, 100)

        eq(ok, false)
        eq(reason, 'garage full')
        eq(findVehicle(tables, 100).stored, 1, 'nothing was mutated')
        eq(#VehicleService.spawnCalls, 0)
    end)
end)

test('GarageService.parkToggle: rejects park-out when the garage has no positions configured', function()
    withFakeDb(function(tables)
        local garageId = seedGarage(tables)
        tables.vehicles = {
            { id = 100, owner_type = 'character', owner_id = 5, garage_id = garageId,
              plate = 'ABC123', base_vehicle_id = 1, stored = 1 },
        }
        -- No garage_park_out_positions rows at all.

        local ok, reason = GarageService.parkToggle(999, 100)

        eq(ok, false)
        eq(reason, 'garage full')
        eq(#VehicleService.spawnCalls, 0)
    end)
end)
```

Also reset the `isPositionOccupied` stub between tests so it doesn't leak into
later tests. Right after the `dofile(scriptDir .. '../server/services/GarageService.lua')`
line (near the other module-level test state), capture the real
implementation once:

```lua
local realIsPositionOccupied = GarageService.isPositionOccupied
```

Then inside `withFakeDb`, reset to it every time, alongside the existing
`VehicleService.spawnCalls = {}` reset:

```lua
    GarageService.isPositionOccupied = realIsPositionOccupied
```

- [ ] **Step 8: Implement the position-based spawn in `parkToggle`**

Replace the spawn branch (the `else` of `if nowStored then ... else ... end`) in `GarageService.parkToggle`:

```lua
    if nowStored then
        GarageService.despawnAndStore(vehicleId)
    else
        local positions = QueryBuilder.new('garage_park_out_positions')
            :where('garage_id', vehicle.garage_id)
            :orderBy('id')
            :getSync()

        local position = GarageService.findFreePosition(positions, function(p)
            return GarageService.isPositionOccupied(p, Config.ParkPositionRadius)
        end)
        if not position then
            return false, 'garage full'
        end

        QueryBuilder.new('vehicles'):where('id', vehicleId):update({ stored = flagValue(false) })
        VehicleService.spawn(vehicleId, {
            x = position.x, y = position.y, z = position.z, heading = position.heading,
        })
    end
```

- [ ] **Step 9: Run the full spec, confirm everything passes**

Run: `lua5.4 plugins/oblsk_garage/tests/garage_service_spec.lua`
Expected: `19 passed, 0 failed`.

- [ ] **Step 10: Syntax-check the migration-adjacent files touched**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/shared/config.lua'))"`
Expected: no output.

- [ ] **Step 11: Commit**

```bash
cd plugins/oblsk_garage
git add server/services/GarageService.lua tests/garage_service_spec.lua shared/config.lua fxmanifest.lua
git commit -m "feat: spawn parked-out vehicles at occupancy-checked positions"
```

---

### Task 4: Friendlier "garage full" notification

**Files:**
- Modify: `plugins/oblsk_garage/server/main.lua`

**Interfaces:**
- Consumes: `GarageService.parkToggle`'s `'garage full'` reason (Task 3).

- [ ] **Step 1: Special-case the notification title/description**

Replace the `garage:client:parkToggle` handler in `server/main.lua`:

```lua
Obelisk.onServer('garage:client:parkToggle', function(vehicleId)
    local source = source
    local ok, reason = GarageService.parkToggle(source, vehicleId)
    if not ok then
        if reason == 'garage full' then
            NotificationService.notify(source, {
                type = 'error',
                title = 'Garage full',
                description = 'Every parking spot at this garage is occupied.',
            })
        else
            notifyFailure(source, 'Could not move vehicle', reason)
        end
    end
end)
```

- [ ] **Step 2: Syntax-check**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/server/main.lua'))"`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
cd plugins/oblsk_garage
git add server/main.lua
git commit -m "feat: friendlier notification when a garage has no free position"
```

---

### Task 5: `GaragePermissionSeeder`

**Files:**
- Create: `plugins/oblsk_garage/server/seeders/GaragePermissionSeeder.lua`
- Modify: `plugins/oblsk_garage/server/main.lua`

**Interfaces:**
- Produces: `GaragePermissionSeeder.PERMISSION_KEYS` (`{'garage_create', 'garage_edit'}`), `GaragePermissionSeeder.ensure()`.

- [ ] **Step 1: Write the seeder**

```lua
--- GaragePermissionSeeder - documents the garage plugin's permission keys.
--- Unlike oblsk_mdt's MdtSeedService, there is no organization/rank
--- structure here to auto-grant these to on boot - an admin grants them
--- explicitly, e.g. `/org-grant character <characterId> garage_edit`
--- (oblsk_organizations' PermissionService.grant is fully generic across
--- owner types, not organization-specific despite the command's name).
GaragePermissionSeeder = {}

GaragePermissionSeeder.PERMISSION_KEYS = { 'garage_create', 'garage_edit' }

function GaragePermissionSeeder.ensure()
    print('[Garage] permission keys available: ' .. table.concat(GaragePermissionSeeder.PERMISSION_KEYS, ', '))
end

return GaragePermissionSeeder
```

- [ ] **Step 2: Call it from the boot thread**

In `server/main.lua`, inside the existing `Citizen.CreateThread` boot block, call it alongside `registerAllGarages()`:

```lua
Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    registerAllGarages()
    GaragePermissionSeeder.ensure()
    print('[Garage] Loaded successfully!')
end)
```

- [ ] **Step 3: Syntax-check**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/server/seeders/GaragePermissionSeeder.lua'))"`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
cd plugins/oblsk_garage
git add server/seeders/GaragePermissionSeeder.lua server/main.lua
git commit -m "feat: add garage permission key seeder"
```

---

### Task 6: `/garage-create` and `/garage-addposition` commands

**Files:**
- Create: `plugins/oblsk_garage/server/commands/GarageCommands.lua`

**Interfaces:**
- Consumes: `CharacterService.getActiveCharacterId(source)`, `PermissionService.can('character', characterId, key)` (core), `InteractionService.register` (core), `GaragePermissionSeeder.PERMISSION_KEYS` (Task 5, for the usage-key names only - not a functional dependency).
- Produces: chat commands `/garage-create <name> [type]` (requires `garage_create`) and `/garage-addposition <garageId>` (requires `garage_edit`).

- [ ] **Step 1: Write the commands file**

```lua
--- Garage Plugin - Admin Commands
---
--- Gated by PermissionService, not a blanket ace admin check - Character is
--- already a registered permission owner type (oblsk_characters), and
--- granting is already generic (`/org-grant character <id> <key>`, from
--- oblsk_organizations). Both commands resolve the calling character the
--- same way GarageService does everywhere else - never trust a raw
--- client-supplied id.

--- @param source number
--- @param key string
--- @return boolean allowed, number|nil characterId
local function checkPermission(source, key)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, nil
    end
    return PermissionService.can('character', characterId, key), characterId
end

RegisterCommand('garage-create', function(source, args)
    local allowed = checkPermission(source, 'garage_create')
    if not allowed then return end

    local name = args[1]
    local garageType = args[2] or 'public'
    if not name then
        print('Usage: /garage-create <name> [type]')
        return
    end

    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)

    local interactionId = QueryBuilder.new('interactions'):insert({
        x = coords.x, y = coords.y, z = coords.z,
        range = 2.0, label = name,
        created_at = Database.now(), updated_at = Database.now(),
    })

    local garageId = QueryBuilder.new('garages'):insert({
        name = name, type = garageType, interaction_id = interactionId,
        created_at = Database.now(), updated_at = Database.now(),
    })

    InteractionService.register({
        x = coords.x, y = coords.y, z = coords.z,
        range = 2.0, label = name,
        action = 'garage:open',
        options = { garageId = garageId },
    })

    print('[oblsk_garage] created garage "' .. name .. '" (#' .. garageId .. ')')
end, false)

RegisterCommand('garage-addposition', function(source, args)
    local allowed = checkPermission(source, 'garage_edit')
    if not allowed then return end

    local garageId = tonumber(args[1])
    if not garageId then
        print('Usage: /garage-addposition <garageId>')
        return
    end

    local garage = QueryBuilder.new('garages'):where('id', garageId):firstSync()
    if not garage then
        print('[oblsk_garage] no garage #' .. garageId)
        return
    end

    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    local positionId = QueryBuilder.new('garage_park_out_positions'):insert({
        garage_id = garageId, x = coords.x, y = coords.y, z = coords.z, heading = heading,
        created_at = Database.now(), updated_at = Database.now(),
    })

    print('[oblsk_garage] added park-out position #' .. positionId .. ' to garage #' .. garageId)
end, false)
```

- [ ] **Step 2: Syntax-check**

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_garage/server/commands/GarageCommands.lua'))"`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
cd plugins/oblsk_garage
git add server/commands/GarageCommands.lua
git commit -m "feat: add /garage-create and /garage-addposition commands"
```

---

### Task 7: Widen `Garage.vue` (name truncation)

**Files:**
- Modify: `plugins/oblsk_garage/web/Garage.vue`

**Interfaces:** none (styling only).

- [ ] **Step 1: Widen the panel**

In `web/Garage.vue`, change the panel's width class from `w-[420px]` to `w-[480px]` (keep the 3-column vehicle grid - already decided over dropping to 2-column):

```
class="pointer-events-auto w-[480px] h-full flex flex-col overflow-hidden shadow-2xl"
```

- [ ] **Step 2: Build the core web bundle to confirm the route still compiles**

Run: `cd web && npm run build`
Expected: build succeeds, `Garage-*.js`/`Garage-*.css` chunks emitted.

- [ ] **Step 3: Commit**

```bash
cd plugins/oblsk_garage
git add web/Garage.vue
git commit -m "fix: widen garage panel so vehicle names stop truncating"
```

---

### Task 8: README update

**Files:**
- Modify: `plugins/oblsk_garage/README.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Document positions, proximity filtering, and the new commands**

Replace `README.md`'s content:

```markdown
# oblsk_garage

Named vehicle garages: park in/out, rename, favourite. Each garage
references one core `interactions` row for its coordinates. Vehicle
instance fields (`plate`, `display_name`, `fuel_level`, `stored`,
`garage_id`, `favorite`) live on `oblsk_vehicles`' `vehicles` table —
that module's migration depends on this plugin's `garages` table
existing first.

See [Garage plugin design](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-12-garage-plugin-design.md)
and [park-out positions design](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-12-garage-park-out-positions-design.md).

## Park-out positions

Each garage can have any number of `GarageParkOutPosition` spawn slots.
When a vehicle is parked out, the first slot with nothing (vehicle, ped, or
object) within `Config.ParkPositionRadius` metres is used; if every slot is
occupied, or the garage has none configured, the player is notified and
nothing is spawned. The "out of garage" tab only lists vehicles whose live
entity is actually within the garage's own interaction range — a vehicle
parked out and driven away from its garage stops showing up there until it's
back in range.

## Creating a garage and its positions

Two in-game commands, permission-gated via `PermissionService` (not a
blanket ace admin check):

- `/garage-create <name> [type]` — requires `garage_create`. Creates an
  `interactions` row and a `garages` row at the caller's current position.
- `/garage-addposition <garageId>` — requires `garage_edit`. Adds a
  park-out position at the caller's current position/heading.

Grant these with the existing generic grant command from
`oblsk_organizations`: `/org-grant character <characterId> garage_create`
(or `garage_edit`). There is no admin panel for any of this yet — a full
CRUD UI (including editing/removing positions) is future work.
```

- [ ] **Step 2: Commit**

```bash
cd plugins/oblsk_garage
git add README.md
git commit -m "docs: document park-out positions, proximity filtering, and commands"
```
