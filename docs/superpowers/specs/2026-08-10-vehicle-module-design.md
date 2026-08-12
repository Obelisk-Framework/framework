# Vehicle Module (`oblsk_vehicles`) Design

## Goal

Build the `oblsk_vehicles` module: a `BaseVehicle`/`Vehicle` catalog-and-instance pattern (same shape as the Item module's `BaseItem`/`Item`), a `FuelType` lookup model, an EAV-backed tuning system with a pluggable per-key native-call strategy, EAV-backed handling with model-level defaults and instance-level overrides, real-instance state (engine, locks, health, damage), and simple spawn-on-demand vehicle creation.

This module has no dependency on the Item module's code, only on its *pattern* (base/instance, polymorphic ownership) and, for vehicle keys specifically, on Items actually existing as a concept (a key is a real `Item`).

## Background

Same developer-first, single-source-of-truth principles as the Item module: no second parallel mechanism where a `type -> handler` registry pattern already works (tuning reuses the exact shape `WebViewRelayMethods` and the Item use-pipeline already established), and ownership stays a plain open `owner_type`/`owner_id` string pair rather than a fixed enum.

Two genuinely new problems this module has to solve that Items didn't:
- **Different tuning keys need different FiveM natives to apply** (`SetVehicleCustomPrimaryColour` for paint, `ToggleVehicleMod` for boolean mods like turbo, `SetVehicleMod` for indexed mods like a spoiler variant). A single EAV table can't hardcode which native applies which row; it needs a registry the table's `key` column looks up into.
- **Handling needs two-level defaults**: every vehicle of a given model should share the same physics unless a specific instance was tuned individually (a "race-tuned" version of an otherwise-stock car). This is the same base/instance-override shape as everything else in this framework, just applied to a flat field/value table instead of fixed columns.

## Architecture

> **Revision note:** the original version of this spec had the client-side spawn handler (section 6) call `Vehicle:findSync`, `BaseVehicle:findSync`, and `QueryBuilder` directly, and had a single `VehicleHandling.applyHandling` (section 4) mix a DB query with native calls in one function. Both are bugs: FXServer's `client_scripts` and `server_scripts` run in entirely separate Lua VMs, and `Vehicle`/`BaseVehicle`/`QueryBuilder` only exist server-side, so none of that code could actually run on the client. Sections 4 and 6 below describe the corrected architecture: the server resolves everything (handling merge, tunings, normalized state) and sends one payload to the client, and `VehicleHandling` is split into a pure merge function (server-side) and a pure apply function (client-side).

### 1. Schema

```lua
Schema.create('fuel_types', function(table)
    table:id()
    table:string('name', 100):notNullable():unique()
    table:timestamps()
end)
```

```lua
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
```

`model` is the GTA vehicle model name (e.g. `'sultan'`), unique since it identifies a specific car model, not an arbitrary label; `name` is the display name (e.g. `'Karin Sultan'`), which can differ from the model string and doesn't need to be unique. `trunk_size`/`glove_compartment_size` are weight capacities (same unit as `base_items.weight`, kilograms by convention), `trunk_slots`/`glove_compartment_slots` are slot counts. All four are nullable, meaningless unless the matching `has_trunk`/`has_glove_compartment` flag is set (same "nullable, only meaningful when a flag is set" convention as `base_items.step`/`step_key`).

```lua
Schema.create('vehicles', function(table)
    table:id()
    table:integer('base_vehicle_id'):notNullable()
    table:string('key', 36) -- UUID; nullable
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
```

`key` is a UUID string, nullable (an NPC-owned or key-less vehicle has none). `engine_health`/`body_health` default to `1000` (GTA's own native default range), `body_damage` is a nullable JSON blob for per-panel/window dent detail that's only ever read/written as a whole (no query ever needs to filter by "which specific panel is dented," unlike `engine_health`, which a mechanic-shop feature would plausibly sort/filter by, hence being a real column). `owner_type`/`owner_id` follow the exact same open-string convention `items.owner_type`/`owner_id` already established (`'character'` today, more later, no schema change needed to add one).

```lua
Schema.create('vehicle_tunings', function(table)
    table:id()
    table:integer('vehicle_id'):notNullable()
    table:string('key', 100):notNullable()
    table:json('value')
    table:timestamps()

    table:unique({'vehicle_id', 'key'})
    table:foreign('vehicle_id'):references('id'):on('vehicles'):onDelete('CASCADE')
end)
```

Tuning is always per-instance (each car's own paint job, mods), never a model-level default, so this table has no `owner_type` polymorphism, just a direct `vehicle_id` FK. `onDelete('CASCADE')` here (unlike the `RESTRICT` used everywhere else in this design and in the Item module) is deliberate: a tuning row is meaningless without its vehicle and should disappear when the vehicle does, whereas deleting a `base_vehicle`/`base_item` while instances still reference it is exactly the mistake `RESTRICT` exists to block. The `unique({'vehicle_id', 'key'})` constraint is what makes re-applying the same tuning key an update, not a duplicate row.

```lua
Schema.create('vehicle_handling', function(table)
    table:id()
    table:string('owner_type', 50):notNullable() -- 'base_vehicle' or 'vehicle'
    table:integer('owner_id'):notNullable()
    table:string('field', 100):notNullable()
    table:float('value'):notNullable()
    table:timestamps()

    table:unique({'owner_type', 'owner_id', 'field'})
end)
```

No FK on `owner_id` (it points at either `base_vehicles.id` or `vehicles.id` depending on `owner_type`, same polymorphism rationale as `items`/`vehicles`). `field` is a handling.meta field name (`'fMass'`, `'fBrakeForce'`, etc.); `value` is always stored as a float even for handling fields that are natively integers (see the apply step below, which knows which native to call per field).

### 2. Models

`FuelType` (`server/models/FuelType.lua`): a plain `BaseModel:extend('fuel_types')`, `fillable = {'name'}`, nothing else notable.

`BaseVehicle` (`server/models/BaseVehicle.lua`): `BaseModel:extend('base_vehicles')`, `fillable` listing every column above, no `casts` (nothing on this table is JSON).

`Vehicle` (`server/models/Vehicle.lua`): `BaseModel:extend('vehicles')`, `fillable` listing every column, `casts = { body_damage = 'json' }` (this module depends on the Item module's `BaseModel` casts fix, already merged to core's `main`).

### 3. Tuning: a registry keyed by tuning key, same shape as `WebViewRelayMethods`/the Item use-pipeline

```lua
--- client/services/VehicleTuningService.lua. Tuning natives are client-only
--- in FiveM, so the registry and its apply function live only on the client;
--- the server only reads/writes vehicle_tunings rows and broadcasts "apply
--- this vehicle's state" (see spawning, below).
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
```

Three built-ins, registered once at module load (client-side), demonstrating each of the three native-call shapes named in the requirements:

```lua
VehicleTuningService.register('primaryColor', {
    apply = function(entity, value)
        -- value = { r = 255, g = 0, b = 0 }
        SetVehicleCustomPrimaryColour(entity, value.r, value.g, value.b)
    end
})

VehicleTuningService.register('turbo', {
    apply = function(entity, value)
        -- value = true/false; 18 is GTA's turbo mod slot index
        ToggleVehicleMod(entity, 18, value == true)
    end
})

VehicleTuningService.register('spoiler', {
    apply = function(entity, value)
        -- value = a mod index (integer), or -1 to remove
        SetVehicleMod(entity, 3, value, false)
    end
})
```

`vehicle_tunings` rows never store which native applies them, only `{key, value}`; the registry is the single place that knows. Adding a new tuning type (rims, window tint, anything) is exactly one more `VehicleTuningService.register(...)` call, no schema change, matching the same extensibility story the Item module's action pipeline already has.

### 4. Handling: base defaults merged with instance overrides, split into a pure merge (server) and a pure apply (client)

`VehicleHandling` lives in `shared/`, loaded on both sides, but its two functions each only do one kind of thing: `mergeRows` takes rows the server already queried and returns a plain field/value map (no DB access), `applyMerged` takes that map and calls the native setters (no DB access, since natives only work client-side anyway). Neither function reaches across the client/server Lua VM boundary.

```lua
--- Which handling.meta fields are natively integers vs floats. Not
--- exhaustive here (GTA's handling.meta has ~90 fields); the real
--- implementation needs the complete table, this is a representative
--- subset to establish the pattern.
VehicleHandling.INT_FIELDS = {
    nInitialDriveGears = true,
    nMonetaryValue = true,
}

--- Merges base_vehicle-level default rows with vehicle-level override rows
--- (override wins). Pure data in, pure data out, no DB access; the server
--- calls this after querying both row sets itself (see spawning, below).
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
--- SetVehicleHandlingFloat/Int. The client calls this with the map the
--- server sent over the wire; it never queries vehicle_handling itself.
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
```

### 5. Vehicle keys: a real `Item`, not a separate mechanism

A vehicle key is a `base_item` (e.g. `name = 'Car Key'`, `is_takeable = true`, `is_giveable = true`) whose `data` carries the matching `vehicles.key` UUID (e.g. `{ vehicleKey = '...' }`). Checking whether a player can drive a given `Vehicle` means checking whether they hold an `Item` (`owner_type = 'character'`, `owner_id = <that player's character id>`) whose `data.vehicleKey` matches `vehicle.attributes.key`. This reuses the Item module entirely; nothing in this design introduces a second way to represent "holding a key."

### 6. Spawning: simple, on-demand, no streaming yet; the server resolves everything and sends one payload

The server does all the database work itself (the vehicle/base_vehicle lookup, the handling query, the tuning query and JSON-decode), normalizes the boolean state flags, and sends one fully-resolved payload to the client. The client never queries the ORM at all, since `Vehicle`/`BaseVehicle`/`QueryBuilder` don't exist in its Lua VM.

```lua
--- server/services/VehicleService.lua
VehicleService = {}
VehicleService.activeNetIds = {} -- vehicleId -> netId, runtime only, never persisted

--- MySQL/Postgres return boolean columns as 1/0 (or sometimes real
--- true/false depending on driver), never Lua's own true/false reliably.
--- Normalize explicitly rather than relying on a raw == true check or a
--- plain truthy check (0 is truthy in Lua).
local function isTruthyFlag(v)
    return v == true or v == 1 or v == '1'
end

--- @param vehicleId number
--- @param coords table { x, y, z, heading }
function VehicleService.spawn(vehicleId, coords)
    local vehicle = Vehicle:findSync(vehicleId)
    if not vehicle then return end

    local baseVehicle = BaseVehicle:findSync(vehicle.attributes.base_vehicle_id)
    if not baseVehicle then return end

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
```

```lua
--- client/services/VehicleService.lua
VehicleService = {}

--- The entity may not have replicated to this client the instant the
--- server's CreateVehicleServerSetter callback fires, so retry a bounded
--- number of times (20 x 250ms = 5s) instead of giving up on the first
--- check.
local function waitForEntity(netId, callback, attemptsLeft)
    attemptsLeft = attemptsLeft or 20
    if NetworkDoesNetworkIdExist(netId) then
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity ~= 0 then
            callback(entity)
            return
        end
    end
    if attemptsLeft <= 0 then return end
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
            end
        end
    end)
end)
```

The server broadcasts to `-1` (every client) rather than a specific player because any nearby client could have the vehicle streamed in once `CreateVehicleServerSetter`'s entity exists; `waitForEntity` retries for each client rather than no-oping immediately, since streaming isn't guaranteed to be instant relative to the broadcast.

## Error Handling

- `VehicleTuningService.apply` with an unregistered key: warns and skips, same pattern as `ItemService.use`'s unknown-`action_id` handling.
- `VehicleService.spawn` for a `vehicleId`/`base_vehicle_id` that doesn't resolve: returns early, no error, on the server (the only side that ever looks these ids up now).
- A malformed `vehicle_tunings.value` JSON string: `pcall(json.decode, ...)` on the server falls back to a `nil` value in that tuning's payload entry; the client's apply loop skips (warns and continues) any tuning whose value is `nil` rather than passing it through to `VehicleTuningService.apply` (each handler is still responsible for tolerating whatever shape its own `value` legitimately takes, not a framework-level concern, matches how `item:consume_step`/`item:notify` each handle their own `data` shape).
- `vehicle_handling` rows for a `base_vehicle_id`/`vehicle_id` that no longer exists (base vehicle deleted while somehow bypassing the `RESTRICT` FK on `vehicles`, or a vehicle deleted without cleaning up its handling overrides): `vehicle_handling` has no FK constraint at all (by design, since `owner_id` is polymorphic), so these become silently-ignored orphan rows, never queried again once the parent id no longer resolves in `base_vehicles`/`vehicles`. Not actively cleaned up by anything in this design; acceptable given the same is already true of `items`/`vehicles`' own polymorphic `owner_id`.

## Testing

- `VehicleTuningService.register`/`apply` (the registry lookup and warn-on-unknown-key path) is pure logic with no native/DB dependency, real unit tests belong in a new `tests/vehicle_tuning_spec.lua`, following the same self-contained pattern as `oblsk_items`'s `tests/item_spec.lua`.
- `VehicleHandling.mergeRows` (base rows + override rows, override wins) and `VehicleHandling.applyMerged` (int/float native dispatch on an already-merged map) are both pure logic with no DB access, real unit tests belong in `tests/vehicle_handling_spec.lua`, asserting the merged field map and the native call chosen per field type.
- `VehicleService.spawn`, the client apply handler, and every native call in this design (`CreateVehicleServerSetter`, `SetVehicleCustomPrimaryColour`, `ToggleVehicleMod`, `SetVehicleMod`, `SetVehicleHandlingFloat`/`Int`, `SetVehicleEngineOn`, `SetVehicleDoorsLocked`, `SetVehicleEngineHealth`, `SetVehicleBodyHealth`) have no automated test, matching the existing convention (no FXServer runtime in this test environment). Manual verification (syntax checks, a real-server smoke test) only.

## Out of Scope

- Chunk-based streaming (auto-spawn near players, despawn when far). This design spawns on demand only. Adding streaming later means making `Vehicle` a new `EntityStreamerService` entity type; nothing in this schema needs to change for that.
- Re-applying tuning/handling/state to a client whose view of the vehicle streams in *after* the initial spawn broadcast (e.g. they drive into range five minutes later). The current design applies state once, broadcast at spawn time; a robust version would hook the client's own entity-stream-in event, not built here.
- The full ~90-field handling.meta int/float table. `HANDLING_INT_FIELDS` above is illustrative, not complete. Building the real, complete table is implementation work, not a design question (the pattern is settled: a fixed lookup table, one boolean per field name).
- A CLI generator for scaffolding vehicle catalog content, mirroring the same gap already noted (and left unfixed) in the Item module's design.
- Fuel consumption over time (burning `tank_size` down via `fuel_consumption_rate` while the engine runs). The column exists on `base_vehicles`, but nothing in this design implements the tick-based depletion loop; that's follow-up work once a broader "vehicle running state" tick system exists.
- The vehicle key mechanic (section 5, "Vehicle keys: a real `Item`, not a separate mechanism"). It's described above but has no corresponding code anywhere in this module; deferred, not built.
- Any write path for a mutable `vehicles` column (`key`, `engine_on`, `backdoor_locked`, `alldoors_locked`, `engine_health`, `body_health`, `body_damage`). Nothing in this module ever changes vehicle state after creation, no lock/unlock, no engine toggle, no damage persistence; this is deferred follow-up work.
- Seeders and a vehicle-creation path. There is no way to populate `base_vehicles`/`vehicles` other than by hand (raw SQL or a future CLI generator); they're empty on a fresh install, and `VehicleService.spawn` has nothing to spawn until they're populated. Deferred follow-up work.
- A vehicle type/class column. `CreateVehicleServerSetter` hardcodes `'automobile'`; `base_vehicles` has no column recording vehicle type/class, so non-automobile vehicles (bikes, boats, aircraft) can't be spawned correctly today. This is a schema gap for follow-up work, not just a missing feature.
