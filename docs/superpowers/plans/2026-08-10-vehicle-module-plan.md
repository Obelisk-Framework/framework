# Vehicle Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `oblsk_vehicles` module: `FuelType`/`BaseVehicle`/`Vehicle` catalog-and-instance pattern, EAV tuning with a pluggable per-key native strategy, EAV handling with base-defaults/instance-overrides, and simple spawn-on-demand vehicle creation.

**Architecture:** See `docs/superpowers/specs/2026-08-10-vehicle-module-design.md` for full rationale. Unlike the Item module, this plan needs **no core-side fixes** (`BaseModel` JSON casts and the `ActionService` DB-backing are already merged to core's `main`); every task lives in the separate `oblsk_vehicles` repository, except one one-line registry edit in core.

**Tech Stack:** Lua (FXServer resource scripts, both `server_scripts`/`client_scripts`), the existing ORM (`BaseModel`/`QueryBuilder`/`Schema`), `lua5.4` for the pure-logic unit tests.

## Global Constraints

- `oblsk_vehicles` is a **separate git repository** (`core/modules/oblsk_vehicles/`, remote `git@github.com:Obelisk-Framework/oblsk_vehicles.git`, currently empty, no commits, same situation the Item module's `oblsk_items` repo was in). Work directly on `master`, no worktree, per the same reasoning already used for `oblsk_items`: nothing exists yet to protect.
- `core`'s repo already has everything this module depends on merged to `main` (verify with `grep -n "encodeJsonCasts" core/server/ORM/BaseModel.lua` from the `core` repo root before starting Task 2, which relies on it for `Vehicle.casts = {body_damage = 'json'}`).
- No FXServer runtime exists in this repo's test environment. Anything touching real natives (`SetVehicleCustomPrimaryColour`, `ToggleVehicleMod`, `SetVehicleMod`, `SetVehicleHandlingFloat`/`Int`, `CreateVehicleServerSetter`, `SetVehicleEngineOn`, `SetVehicleDoorsLocked`, `SetVehicleEngineHealth`, `SetVehicleBodyHealth`, `NetworkGetNetworkIdFromEntity`, `NetworkDoesNetworkIdExist`, `NetworkGetEntityFromNetworkId`) gets manual verification only (syntax checks), matching the existing convention. Pure Lua logic (the tuning registry's lookup/dispatch, the handling merge) gets real unit tests, stubbing out the specific natives each test needs locally (the test defines its own fake native as a global, same pattern `tests/obelisk_spec.lua` already uses for `RegisterNetEvent`/`TriggerEvent`).
- No Claude co-authorship in any commit.
- Minimize em/en dashes in prose (project owner's stated preference); applies to commit messages and docs prose, not code/SQL.

---

## Task 1: `oblsk_vehicles` module scaffold, full schema

**Repository:** `oblsk_vehicles`, working directly on `master`.

**Files:**
- Create: `README.md`
- Create: `server/migrations/<timestamp1>_create_fuel_types_table.lua`
- Create: `server/migrations/<timestamp2>_create_base_vehicles_table.lua`
- Create: `server/migrations/<timestamp3>_create_vehicles_table.lua`
- Create: `server/migrations/<timestamp4>_create_vehicle_tunings_table.lua`
- Create: `server/migrations/<timestamp5>_create_vehicle_handling_table.lua`
- Create: `server/migrations.json`
- Modify (in **core's** repo, at `/home/andi/Projects/obelisk-framework/core`, directly on `main`): `modules/registry.json`

**Interfaces:**
- Produces: the `fuel_types`, `base_vehicles`, `vehicles`, `vehicle_tunings`, `vehicle_handling` tables. Every later task depends on these existing.

- [ ] **Step 1: Determine migration timestamps**

Run `date -u +%Y_%m_%d_%H%M%S` five times (a few seconds apart, or increment the seconds by hand) for five distinct timestamps in the existing `YYYY_MM_DD_HHMMSS` format.

- [ ] **Step 2: Write the `fuel_types` migration**

```lua
--- Migration: Create fuel_types table
return {
    up = function()
        Schema.create('fuel_types', function(table)
            table:id()
            table:string('name', 100):notNullable():unique()
            table:timestamps()
        end)

        print('[Migration] Created fuel_types table')
    end,

    down = function()
        Schema.drop('fuel_types')
        print('[Migration] Dropped fuel_types table')
    end
}
```

- [ ] **Step 3: Write the `base_vehicles` migration**

```lua
--- Migration: Create base_vehicles table
return {
    up = function()
        Schema.create('base_vehicles', function(table)
            table:id()
            table:string('model', 100):notNullable():unique()
            table:string('name', 255):notNullable()
            table:boolean('has_trunk'):default(0)
            table:float('trunk_size')
            table:integer('trunk_slots')
            table:boolean('has_glove_compartment'):default(0)
            table:float('glove_compartment_size')
            table:integer('glove_compartment_slots')
            table:integer('fuel_type_id')
            table:float('tank_size')
            table:float('fuel_consumption_rate')
            table:integer('seats'):notNullable():default(4)
            table:timestamps()

            table:foreign('fuel_type_id'):references('id'):on('fuel_types'):onDelete('RESTRICT')
        end)

        print('[Migration] Created base_vehicles table')
    end,

    down = function()
        Schema.drop('base_vehicles')
        print('[Migration] Dropped base_vehicles table')
    end
}
```

- [ ] **Step 4: Write the `vehicles` migration**

```lua
--- Migration: Create vehicles table
return {
    up = function()
        Schema.create('vehicles', function(table)
            table:id()
            table:integer('base_vehicle_id'):notNullable()
            table:string('key', 36)
            table:string('owner_type', 50):notNullable()
            table:integer('owner_id'):notNullable()
            table:boolean('engine_on'):default(0)
            table:boolean('backdoor_locked'):default(0)
            table:boolean('alldoors_locked'):default(0)
            table:float('engine_health'):default(1000)
            table:float('body_health'):default(1000)
            table:json('body_damage')
            table:timestamps()

            table:index({'owner_type', 'owner_id'})
            table:foreign('base_vehicle_id'):references('id'):on('base_vehicles'):onDelete('RESTRICT')
        end)

        print('[Migration] Created vehicles table')
    end,

    down = function()
        Schema.drop('vehicles')
        print('[Migration] Dropped vehicles table')
    end
}
```

- [ ] **Step 5: Write the `vehicle_tunings` migration**

```lua
--- Migration: Create vehicle_tunings table
return {
    up = function()
        Schema.create('vehicle_tunings', function(table)
            table:id()
            table:integer('vehicle_id'):notNullable()
            table:string('key', 100):notNullable()
            table:json('value')
            table:timestamps()

            table:unique({'vehicle_id', 'key'})
            table:foreign('vehicle_id'):references('id'):on('vehicles'):onDelete('CASCADE')
        end)

        print('[Migration] Created vehicle_tunings table')
    end,

    down = function()
        Schema.drop('vehicle_tunings')
        print('[Migration] Dropped vehicle_tunings table')
    end
}
```

- [ ] **Step 6: Write the `vehicle_handling` migration**

```lua
--- Migration: Create vehicle_handling table
return {
    up = function()
        Schema.create('vehicle_handling', function(table)
            table:id()
            table:string('owner_type', 50):notNullable()
            table:integer('owner_id'):notNullable()
            table:string('field', 100):notNullable()
            table:float('value'):notNullable()
            table:timestamps()

            table:unique({'owner_type', 'owner_id', 'field'})
        end)

        print('[Migration] Created vehicle_handling table')
    end,

    down = function()
        Schema.drop('vehicle_handling')
        print('[Migration] Dropped vehicle_handling table')
    end
}
```

- [ ] **Step 7: Register all five migrations**

Create `server/migrations.json`, in this exact order (dependency order: `fuel_types` before `base_vehicles`, `base_vehicles` before `vehicles`, `vehicles` before `vehicle_tunings`; `vehicle_handling` has no FK so its position relative to the others doesn't matter, but keep it last for readability):

```json
{
  "migrations": [
    "<timestamp1>_create_fuel_types_table",
    "<timestamp2>_create_base_vehicles_table",
    "<timestamp3>_create_vehicles_table",
    "<timestamp4>_create_vehicle_tunings_table",
    "<timestamp5>_create_vehicle_handling_table"
  ]
}
```

- [ ] **Step 8: Write the module README**

```markdown
# oblsk_vehicles

Vehicle catalog (`base_vehicles`), per-instance vehicles (`vehicles`), fuel types, EAV tuning, and EAV handling (model defaults + instance overrides) for the Obelisk framework. Loads as part of `core`; restart `core` (or the whole server) to pick up changes.

See [Vehicle module design](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-10-vehicle-module-design.md) for the full architecture.
```

- [ ] **Step 9: Register the module in core's registry**

In **core's** repo (`/home/andi/Projects/obelisk-framework/core`, directly on `main`, not this task's `oblsk_vehicles` repo), change `modules/registry.json` from:

```json
{
  "modules": ["oblsk_items"]
}
```

to:

```json
{
  "modules": ["oblsk_items", "oblsk_vehicles"]
}
```

- [ ] **Step 10: Manual verification**

Run `lua5.4 -e "assert(loadfile('server/migrations/<file>.lua'))"` for each of the five migration files, all must parse.
Run `node -e "require('./server/migrations.json')"` from the `oblsk_vehicles` repo root, confirms valid JSON.
Run `node -e "require('/home/andi/Projects/obelisk-framework/core/modules/registry.json')"`, confirms valid JSON.

- [ ] **Step 11: Commit (two repos)**

In `oblsk_vehicles`:

```bash
git add README.md server/migrations server/migrations.json
git commit -m "feat: add fuel_types/base_vehicles/vehicles/vehicle_tunings/vehicle_handling schema"
```

In `core`:

```bash
git add modules/registry.json
git commit -m "feat: register oblsk_vehicles module"
```

---

## Task 2: `FuelType`/`BaseVehicle`/`Vehicle` models

**Repository:** `oblsk_vehicles`, `master`.

**Files:**
- Create: `server/models/FuelType.lua`
- Create: `server/models/BaseVehicle.lua`
- Create: `server/models/Vehicle.lua`

**Interfaces:**
- Produces: the three models, `fillable`/`casts` configured. Every later task's Lua code constructs/queries through these.

- [ ] **Step 1: Confirm core's `BaseModel` casts fix is present**

Run (from core's repo root, `/home/andi/Projects/obelisk-framework/core`): `grep -n "encodeJsonCasts\|decodeJsonCasts" core/server/ORM/BaseModel.lua`
Expected: both names appear (this was merged as part of the Item module's work). If either is missing, stop and report back rather than guessing why; do not proceed with `Vehicle.casts` until this is confirmed present.

- [ ] **Step 2: Write `FuelType.lua`**

```lua
--- FuelType Model - a simple lookup table (petrol, diesel, electric, etc.)
FuelType = BaseModel:extend('fuel_types')

FuelType.primaryKey = 'id'
FuelType.timestamps = true

FuelType.fillable = { 'name' }

FuelType.hidden = {}

return FuelType
```

- [ ] **Step 3: Write `BaseVehicle.lua`**

```lua
--- BaseVehicle Model - the vehicle catalog/template. One row per vehicle
--- model (e.g. 'sultan'). See tests/vehicle_handling_spec.lua and
--- tests/vehicle_tuning_spec.lua for how base_vehicle_id-scoped rows in
--- vehicle_handling relate to this table.
BaseVehicle = BaseModel:extend('base_vehicles')

BaseVehicle.primaryKey = 'id'
BaseVehicle.timestamps = true

BaseVehicle.fillable = {
    'model', 'name',
    'has_trunk', 'trunk_size', 'trunk_slots',
    'has_glove_compartment', 'glove_compartment_size', 'glove_compartment_slots',
    'fuel_type_id', 'tank_size', 'fuel_consumption_rate',
    'seats',
}

BaseVehicle.hidden = {}

function BaseVehicle:fuelType()
    return self:belongsTo(FuelType, 'fuel_type_id', 'id')
end

return BaseVehicle
```

- [ ] **Step 4: Write `Vehicle.lua`**

```lua
--- Vehicle Model - a single owned instance of a BaseVehicle. Ownership is
--- polymorphic: owner_type is an open string ('character', more later),
--- owner_id points at whatever that type's table primary key is. No FK
--- constraint on owner_id since the target table varies (same convention
--- as the Item module's items.owner_type/owner_id).
Vehicle = BaseModel:extend('vehicles')

Vehicle.primaryKey = 'id'
Vehicle.timestamps = true

Vehicle.fillable = {
    'base_vehicle_id', 'key', 'owner_type', 'owner_id',
    'engine_on', 'backdoor_locked', 'alldoors_locked',
    'engine_health', 'body_health', 'body_damage',
}

Vehicle.hidden = {}

Vehicle.casts = {
    body_damage = 'json',
}

function Vehicle:baseVehicleRelation()
    return self:belongsTo(BaseVehicle, 'base_vehicle_id', 'id')
end

return Vehicle
```

- [ ] **Step 5: Manual verification**

Run `lua5.4 -e "assert(loadfile('server/models/FuelType.lua'))"`, and the same for `BaseVehicle.lua`/`Vehicle.lua`, all three must parse.

- [ ] **Step 6: Commit**

```bash
git add server/models/FuelType.lua server/models/BaseVehicle.lua server/models/Vehicle.lua
git commit -m "feat: add FuelType/BaseVehicle/Vehicle models"
```

---

## Task 3: `VehicleTuningService` (client), the tuning strategy registry

**Repository:** `oblsk_vehicles`, `master`.

**Files:**
- Create: `client/services/VehicleTuningService.lua`
- Create: `tests/vehicle_tuning_spec.lua`

**Interfaces:**
- Produces: `VehicleTuningService.register(key, handlers)`, `VehicleTuningService.apply(entity, key, value)`. Task 5's client apply-state handler calls `apply` in a loop over a vehicle's `vehicle_tunings` rows.

- [ ] **Step 1: Write the failing tests**

Create `tests/vehicle_tuning_spec.lua`:

```lua
--- Unit tests for VehicleTuningService's registry/dispatch logic and its
--- three built-in tuning handlers. Run from the repository root:
--- lua5.4 tests/vehicle_tuning_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'

dofile(scriptDir .. '../client/services/VehicleTuningService.lua')

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

test('register + apply: calls the registered handler with entity and value', function()
    local capturedEntity, capturedValue
    VehicleTuningService.register('test:key', {
        apply = function(entity, value)
            capturedEntity = entity
            capturedValue = value
        end
    })

    VehicleTuningService.apply(1234, 'test:key', { foo = 'bar' })

    eq(capturedEntity, 1234)
    eq(capturedValue.foo, 'bar')
end)

test('apply: an unregistered key warns and does not error', function()
    local ok = pcall(VehicleTuningService.apply, 1234, 'test:never-registered', {})
    truthy(ok, 'apply did not error for an unknown key')
end)

test('built-in primaryColor: calls SetVehicleCustomPrimaryColour with r/g/b', function()
    local captured
    _G.SetVehicleCustomPrimaryColour = function(entity, r, g, b) captured = {entity, r, g, b} end

    VehicleTuningService.apply(42, 'primaryColor', { r = 255, g = 0, b = 0 })

    eq(captured[1], 42)
    eq(captured[2], 255)
    eq(captured[3], 0)
    eq(captured[4], 0)
end)

test('built-in turbo: calls ToggleVehicleMod with the turbo slot index and a real boolean', function()
    local captured
    _G.ToggleVehicleMod = function(entity, modIndex, enabled) captured = {entity, modIndex, enabled} end

    VehicleTuningService.apply(42, 'turbo', true)

    eq(captured[1], 42)
    eq(captured[2], 18)
    eq(captured[3], true)
end)

test('built-in spoiler: calls SetVehicleMod with the mod type and index', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end

    VehicleTuningService.apply(42, 'spoiler', 3)

    eq(captured[1], 42)
    eq(captured[2], 3)
    eq(captured[3], 3)
    eq(captured[4], false)
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running VehicleTuningService unit tests\n')
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

Run: `lua5.4 tests/vehicle_tuning_spec.lua`
Expected: fails immediately, `client/services/VehicleTuningService.lua` doesn't exist yet.

- [ ] **Step 3: Write `VehicleTuningService.lua`**

Create `client/services/VehicleTuningService.lua`:

```lua
--- VehicleTuningService (client) - a registry mapping a tuning key to the
--- specific native call needed to apply it. vehicle_tunings rows only ever
--- store {key, value}; this registry is the single place that knows which
--- native each key maps to. See docs/superpowers/specs/2026-08-10-vehicle-module-design.md.
VehicleTuningService = {}
VehicleTuningService.registry = {}

--- @param key string
--- @param handlers table { apply = function(entity, value) }
function VehicleTuningService.register(key, handlers)
    VehicleTuningService.registry[key] = handlers
end

--- @param entity number Vehicle entity handle
--- @param key string
--- @param value any Already-decoded (not a JSON string)
function VehicleTuningService.apply(entity, key, value)
    local handlers = VehicleTuningService.registry[key]
    if not handlers then
        print('[VehicleTuningService] WARNING: no handler registered for tuning key "' .. key .. '", skipping')
        return
    end
    handlers.apply(entity, value)
end

VehicleTuningService.register('primaryColor', {
    apply = function(entity, value)
        SetVehicleCustomPrimaryColour(entity, value.r, value.g, value.b)
    end
})

VehicleTuningService.register('turbo', {
    apply = function(entity, value)
        ToggleVehicleMod(entity, 18, value == true)
    end
})

VehicleTuningService.register('spoiler', {
    apply = function(entity, value)
        SetVehicleMod(entity, 3, value, false)
    end
})

return VehicleTuningService
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `lua5.4 tests/vehicle_tuning_spec.lua`
Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add client/services/VehicleTuningService.lua tests/vehicle_tuning_spec.lua
git commit -m "feat: add VehicleTuningService tuning-key registry with 3 built-in handlers"
```

---

## Task 4: Handling merge logic

**Repository:** `oblsk_vehicles`, `master`.

**Files:**
- Create: `shared/services/VehicleHandling.lua`
- Create: `tests/vehicle_handling_spec.lua`

**Interfaces:**
- Produces: `VehicleHandling.mergeRows(baseRows, overrideRows)` and `VehicleHandling.applyMerged(entity, merged)`. Task 5's server spawn path calls `mergeRows` after querying both row sets itself; Task 5's client apply-state handler calls `applyMerged` on the map the server sends over the wire.
- Consumes: none new. Note that `VehicleHandling` itself no longer uses `QueryBuilder` (a final review found the original single `applyHandling` function mixed a DB query, server-only, with native calls, client-only, in one function, which cannot work across FXServer's separate client/server Lua VMs; the server now does the querying and passes rows in).

This lives in `shared/`, not `server/services/`, because Task 5's client-side code needs to call it too, and `client_scripts`/`server_scripts` run in entirely separate Lua VMs in FXServer, a server-only global is invisible to client code. `shared/**/*.lua` is loaded on both sides by `core`'s `fxmanifest.lua` glob for `modules/*/shared/**/*.lua`, the same convention `core/shared/WebViewRelay.lua` already established for exactly this "both sides need the same lookup/logic" situation.

- [ ] **Step 1: Write the failing test**

Create `tests/vehicle_handling_spec.lua`:

```lua
--- Unit tests for VehicleHandling.mergeRows (base defaults + overrides) and
--- VehicleHandling.applyMerged (int/float native dispatch on an
--- already-merged map). Run from the repository root:
--- lua5.4 tests/vehicle_handling_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'

dofile(scriptDir .. '../shared/services/VehicleHandling.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('mergeRows: a base row applies when there is no override', function()
    local merged = VehicleHandling.mergeRows(
        { { field = 'fMass', value = 1500.0 } },
        {}
    )
    eq(merged.fMass, 1500.0)
end)

test('mergeRows: an override row wins over the base default', function()
    local merged = VehicleHandling.mergeRows(
        { { field = 'fMass', value = 1500.0 } },
        { { field = 'fMass', value = 2000.0 } }
    )
    eq(merged.fMass, 2000.0)
end)

test('mergeRows: an empty base and empty override merge to an empty table', function()
    local merged = VehicleHandling.mergeRows({}, {})
    eq(next(merged), nil)
end)

test('applyMerged: a float-typed field calls SetVehicleHandlingFloat', function()
    local captured
    _G.SetVehicleHandlingFloat = function(entity, class, field, value) captured = {entity, class, field, value} end
    _G.SetVehicleHandlingInt = function() error('should not be called for a float field') end

    VehicleHandling.applyMerged(1, { fMass = 1500.0 })

    eq(captured[1], 1)
    eq(captured[3], 'fMass')
    eq(captured[4], 1500.0)
end)

test('applyMerged: an int-typed field calls SetVehicleHandlingInt, not Float', function()
    local floatCalled, intCalled = false, false
    _G.SetVehicleHandlingFloat = function() floatCalled = true end
    _G.SetVehicleHandlingInt = function() intCalled = true end

    VehicleHandling.applyMerged(1, { nInitialDriveGears = 6 })

    eq(floatCalled, false)
    eq(intCalled, true)
end)

test('applyMerged: an empty map calls no natives', function()
    local called = false
    _G.SetVehicleHandlingFloat = function() called = true end
    _G.SetVehicleHandlingInt = function() called = true end

    VehicleHandling.applyMerged(1, {})

    eq(called, false)
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running VehicleHandling unit tests\n')
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

Unlike the Item module's equivalent tests, this file stubs no ORM at all: `mergeRows` and `applyMerged` are both pure functions over plain tables, so the test only needs to load `shared/services/VehicleHandling.lua` and fake the two native setters.

- [ ] **Step 2: Run the test to confirm it fails**

Run: `lua5.4 tests/vehicle_handling_spec.lua`
Expected: fails, `shared/services/VehicleHandling.lua` doesn't exist yet.

- [ ] **Step 3: Write `VehicleHandling.lua`**

Create `shared/services/VehicleHandling.lua`:

```lua
--- VehicleHandling (shared) - pure handling-map merge logic and the
--- int/float field-type lookup. No DB access, no natives: the server calls
--- mergeRows() with rows it already queried itself; the client calls
--- applyMerged() with the map the server sent over the network. Neither
--- function touches anything that only exists in one Lua VM.
VehicleHandling = {}

--- Which handling.meta fields are natively integers vs floats. Not
--- exhaustive (GTA's handling.meta has ~90 fields); representative subset.
VehicleHandling.INT_FIELDS = {
    nInitialDriveGears = true,
    nMonetaryValue = true,
}

--- Merges base_vehicle-level default rows with vehicle-level override rows
--- (override wins). Pure data in, pure data out; no DB access.
--- @param baseRows table[] rows with .field and .value
--- @param overrideRows table[] rows with .field and .value
--- @return table field -> value
function VehicleHandling.mergeRows(baseRows, overrideRows)
    local merged = {}
    for _, row in ipairs(baseRows) do
        merged[row.field] = row.value
    end
    for _, row in ipairs(overrideRows) do
        merged[row.field] = row.value
    end
    return merged
end

--- Applies an already-merged field->value map to a live entity via
--- SetVehicleHandlingFloat/Int.
--- @param entity number
--- @param merged table field -> value
function VehicleHandling.applyMerged(entity, merged)
    for field, value in pairs(merged) do
        if VehicleHandling.INT_FIELDS[field] then
            SetVehicleHandlingInt(entity, 'CHandlingData', field, math.floor(value))
        else
            SetVehicleHandlingFloat(entity, 'CHandlingData', field, value)
        end
    end
end

return VehicleHandling
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `lua5.4 tests/vehicle_handling_spec.lua`
Expected: `6 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/services/VehicleHandling.lua tests/vehicle_handling_spec.lua
git commit -m "feat: add VehicleHandling.mergeRows/applyMerged (base defaults + instance overrides)"
```

---

## Task 5: Spawning

**Repository:** `oblsk_vehicles`, `master`.

**Files:**
- Create: `server/services/VehicleService.lua`
- Create: `client/services/VehicleService.lua`

**Interfaces:**
- Consumes: `Obelisk.emitClient`/`Obelisk.onClient` (core, already merged), `VehicleTuningService.apply` (Task 3), `VehicleHandling.mergeRows`/`applyMerged` (Task 4), `BaseVehicle`/`Vehicle` models (Task 2).
- Produces: `VehicleService.spawn(vehicleId, coords)` (server).

The server does all the database work itself, normalizes the boolean state flags, and sends one fully-resolved payload to the client (handling already merged, tunings already JSON-decoded). The client never touches the ORM: `Vehicle`/`BaseVehicle`/`QueryBuilder` only exist server-side, and an earlier version of this task had the client call them directly, which cannot work across FXServer's separate client/server Lua VMs. The client also retries a bounded number of times waiting for the spawned entity to stream in, rather than no-oping on the first check.

- [ ] **Step 1: Write the server-side `VehicleService.lua`**

Create `server/services/VehicleService.lua`:

```lua
--- VehicleService (server) - simple spawn-on-demand vehicle creation. Does
--- all database work itself and sends a fully-resolved payload to clients;
--- the client-side VehicleService never touches the ORM.
VehicleService = {}
VehicleService.activeNetIds = {} -- vehicleId -> netId, runtime only, never persisted

--- MySQL/Postgres return boolean columns as 1/0 (or sometimes real
--- true/false depending on driver), never Lua's own true/false reliably.
--- Normalize explicitly.
local function isTruthyFlag(v)
    return v == true or v == 1 or v == '1'
end

--- @param vehicleId number
--- @param coords table { x, y, z, heading }
function VehicleService.spawn(vehicleId, coords)
    local vehicle = Vehicle:findSync(vehicleId)
    if not vehicle then
        print('[VehicleService] Error: vehicle #' .. vehicleId .. ' not found')
        return
    end

    local baseVehicle = BaseVehicle:findSync(vehicle.attributes.base_vehicle_id)
    if not baseVehicle then
        print('[VehicleService] Error: base_vehicle #' .. vehicle.attributes.base_vehicle_id .. ' not found')
        return
    end

    local baseRows = QueryBuilder.new('vehicle_handling')
        :where('owner_type', 'base_vehicle'):where('owner_id', baseVehicle.attributes.id):getSync()
    local overrideRows = QueryBuilder.new('vehicle_handling')
        :where('owner_type', 'vehicle'):where('owner_id', vehicleId):getSync()
    local mergedHandling = VehicleHandling.mergeRows(baseRows, overrideRows)

    local tunings = {}
    for _, row in ipairs(QueryBuilder.new('vehicle_tunings'):where('vehicle_id', vehicleId):getSync()) do
        local ok, decoded = pcall(json.decode, row.value or '')
        local value = nil
        if ok then value = decoded end
        table.insert(tunings, { key = row.key, value = value })
    end

    local state = {
        engineOn = isTruthyFlag(vehicle.attributes.engine_on),
        allDoorsLocked = isTruthyFlag(vehicle.attributes.alldoors_locked),
        engineHealth = vehicle.attributes.engine_health,
        bodyHealth = vehicle.attributes.body_health,
    }

    CreateVehicleServerSetter(baseVehicle.attributes.model, 'automobile', coords.x, coords.y, coords.z, coords.heading or 0.0, function(entity)
        local netId = NetworkGetNetworkIdFromEntity(entity)
        VehicleService.activeNetIds[vehicleId] = netId

        Obelisk.emitClient('vehicles:server:apply-state', -1, netId, state, mergedHandling, tunings)
    end)
end

return VehicleService
```

- [ ] **Step 2: Write the client-side `VehicleService.lua`**

Create `client/services/VehicleService.lua`:

```lua
--- VehicleService (client) - receives the server's fully-resolved "apply
--- state" broadcast for a freshly-spawned vehicle and applies it to the
--- local entity once it has actually streamed in for this client. Contains
--- no ORM references.
VehicleService = {}

local function waitForEntity(netId, callback, attemptsLeft)
    attemptsLeft = attemptsLeft or 20
    if NetworkDoesNetworkIdExist(netId) then
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity ~= 0 then
            callback(entity)
            return
        end
    end
    if attemptsLeft <= 0 then
        print('[VehicleService] WARNING: gave up waiting for netId ' .. tostring(netId) .. ' to stream in')
        return
    end
    Citizen.SetTimeout(250, function()
        waitForEntity(netId, callback, attemptsLeft - 1)
    end)
end

Obelisk.onClient('vehicles:server:apply-state', function(netId, state, mergedHandling, tunings)
    waitForEntity(netId, function(entity)
        SetVehicleEngineOn(entity, state.engineOn, true, false)
        SetVehicleDoorsLocked(entity, state.allDoorsLocked and 2 or 1)
        SetVehicleEngineHealth(entity, state.engineHealth)
        SetVehicleBodyHealth(entity, state.bodyHealth)

        VehicleHandling.applyMerged(entity, mergedHandling)

        for _, tuning in ipairs(tunings) do
            if tuning.value ~= nil then
                VehicleTuningService.apply(entity, tuning.key, tuning.value)
            else
                print('[VehicleService] WARNING: skipping tuning "' .. tostring(tuning.key) .. '" with unparseable/nil value')
            end
        end
    end)
end)

return VehicleService
```

`VehicleHandling.applyMerged` (from `shared/services/VehicleHandling.lua`, Task 4) is a global loaded on both server and client, so this client file can call it without any cross-VM issue; it never calls `VehicleHandling.mergeRows`, that's the server's job now.

- [ ] **Step 3: Manual verification**

Run `lua5.4 -e "assert(loadfile('server/services/VehicleService.lua'))"` and the same for `client/services/VehicleService.lua`, both must parse.
Grep `client/services/VehicleService.lua` for `Vehicle:findSync`, `BaseVehicle:findSync`, `QueryBuilder`, confirm zero matches.
Re-run `lua5.4 tests/vehicle_handling_spec.lua`, still `6 passed, 0 failed` (unaffected by this task, included as a regression guard since this task's client file calls the function that test covers).

- [ ] **Step 4: Commit**

```bash
git add server/services/VehicleService.lua client/services/VehicleService.lua shared/services/VehicleHandling.lua tests/vehicle_handling_spec.lua
git commit -m "feat: add vehicle spawning (server) and apply-state on stream-in (client)"
```
