# Vehicles (`oblsk_vehicles`)

A vehicle catalog (`base_vehicles`) and per-instance owned vehicles (`vehicles`), plus EAV-based tuning and handling, and spawn-on-demand. Repository: [Obelisk-Framework/oblsk_vehicles](https://github.com/Obelisk-Framework/oblsk_vehicles).

See [Vehicle module design](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-10-vehicle-module-design.md) for the full rationale behind every decision on this page.

## Schema

`fuel_types` is a simple lookup table (petrol, diesel, electric, etc.), name only:

| Column | Type | Notes |
|---|---|---|
| `name` | string | unique |

`base_vehicles` is the catalog, one row per vehicle model:

| Column | Type | Notes |
|---|---|---|
| `model` | string | unique, the FiveM vehicle model name |
| `name` | string | display name |
| `has_trunk` / `has_glove_compartment` | boolean | default `0` |
| `trunk_size` / `glove_compartment_size` | float | nullable |
| `trunk_slots` / `glove_compartment_slots` | integer | nullable |
| `fuel_type_id` | integer FK | `onDelete('RESTRICT')` |
| `tank_size` | float | nullable |
| `fuel_consumption_rate` | float | nullable, lives here rather than on `FuelType` since consumption varies per vehicle model even within the same fuel type |
| `seats` | integer | default `4` |

`vehicles` is a single owned instance of a `base_vehicle`:

| Column | Type | Notes |
|---|---|---|
| `base_vehicle_id` | integer FK | `onDelete('RESTRICT')` |
| `key` | string(36) | nullable, a key `Item` UUID (see [Keys](#keys)) |
| `owner_type` | string | open, not a fixed enum: `'character'`, more later |
| `owner_id` | integer | no FK, since the target table depends on `owner_type` |
| `engine_on` / `backdoor_locked` / `alldoors_locked` | boolean | default `0` |
| `engine_health` / `body_health` | float | default `1000` |
| `body_damage` | json | nullable, the long tail of damage state beyond the two fixed health columns |

## Models

`FuelType`, `BaseVehicle`, and `Vehicle` (`server/models/*.lua`), all `BaseModel:extend(...)`. `Vehicle.casts = { body_damage = 'json' }`.

- **`BaseVehicle:fuelType()`**: `belongsTo(FuelType, 'fuel_type_id', 'id')`.
- **`Vehicle:baseVehicleRelation()`**: `belongsTo(BaseVehicle, 'base_vehicle_id', 'id')`.

## Tuning

`vehicle_tunings` is EAV: `vehicle_id`, `key`, `value` (json), unique on `(vehicle_id, key)`. Different tuning keys need different native calls (`SetVehicleCustomPrimaryColour` for paint, `ToggleVehicleMod` for a boolean mod like a turbo, `SetVehicleMod` for a leveled mod like a spoiler), so `VehicleTuningService` (`client/services/VehicleTuningService.lua`) is a `key -> handler` registry rather than a single function with a big if/else. Built-in keys:

| Key | Native | Value shape |
|---|---|---|
| `primaryColor` | `SetVehicleCustomPrimaryColour` | `{ r, g, b }` |
| `turbo` | `ToggleVehicleMod` (slot 18) | boolean |
| `spoiler` | `SetVehicleMod` (slot 3) | integer mod index |

`VehicleTuningService.register(key, { apply = function(entity, value) ... end })` adds more at module load time, the same registry pattern the Item module uses for its use pipeline via `ActionService`.

## Handling

`vehicle_handling` is also EAV, but shared by two ownership levels in one table: `owner_type` is `'base_vehicle'` (a default for every vehicle of that model) or `'vehicle'` (an override for one specific instance), `owner_id` points at the corresponding row, `field` is a `handling.meta` field name (e.g. `fInitialDriveForce`), `value` is a float. Unique on `(owner_type, owner_id, field)`.

`VehicleHandling` (`shared/services/VehicleHandling.lua`) is pure and has no DB access and no native calls, so it's safe to require from both Lua VMs:

- **`VehicleHandling.mergeRows(baseRows, overrideRows)`**: merges a `base_vehicle`-level row set with a `vehicle`-level row set, override wins per field. The server queries both row sets and calls this.
- **`VehicleHandling.applyMerged(entity, merged)`**: applies an already-merged `field -> value` map to a live entity via `SetVehicleHandlingFloat`/`SetVehicleHandlingInt` (`VehicleHandling.INT_FIELDS` lists which fields are natively integers; not exhaustive, a representative subset of `handling.meta`'s ~90 fields). The client calls this once it has the server's resolved map.

Splitting the merge (server, needs the DB) from the apply (client, needs the natives) matters because `server_scripts` and `client_scripts` run in separate Lua VMs: `QueryBuilder`/`BaseModel` don't exist client-side, and the handling natives don't exist server-side. Nothing in this module mixes the two in one function.

## Spawning

`VehicleService.spawn(vehicleId, coords)` (server, `server/services/VehicleService.lua`) does all the resolving:

1. Loads `Vehicle` and its `BaseVehicle`.
2. Queries and merges `vehicle_handling` rows via `VehicleHandling.mergeRows`.
3. Loads and JSON-decodes `vehicle_tunings` rows.
4. Normalizes `engine_on`/`alldoors_locked` through an `isTruthyFlag` helper, since a raw DB boolean can come back as `1`/`0`/`'1'`/`'0'`, and `1 == true` is `false` in Lua while `0` is truthy in Lua, so a naive check on the raw value is wrong either way.
5. Calls `CreateVehicleServerSetter`, then broadcasts the fully-resolved payload with `Obelisk.emitClient('vehicles:server:apply-state', -1, netId, state, mergedHandling, tunings)`.

The client (`client/services/VehicleService.lua`) never touches the ORM: it receives the payload already resolved and applies it. Because the broadcast fires from `CreateVehicleServerSetter`'s callback, the entity isn't guaranteed to have replicated to every client yet; the client retries via `waitForEntity` (`Citizen.SetTimeout(250, ...)`, up to 20 attempts) before giving up and logging a warning, rather than applying state to an entity handle that doesn't exist yet.

Vehicle type is currently hardcoded to `'automobile'` in the `CreateVehicleServerSetter` call (see [Known gaps](#known-gaps)).

## Keys

`vehicles.key` stores the UUID of an `Item` (from the [Items module](/modules/items)) rather than inventing a separate key mechanism. A vehicle with no key row (`key IS NULL`) has no key issued yet; matching a presented key to a vehicle is left to whichever interaction layer calls into this module (see [Known gaps](#known-gaps)).

## Known gaps

- No CLI generator for scaffolding new `base_vehicles` content yet (`make:vehicle`).
- No write path for mutable vehicle state (`engine_on`, lock state, health, damage) once spawned; this module resolves and applies state at spawn time, but nothing yet persists a running vehicle's state changes back to `vehicles`.
- No key-issuing or key-matching interaction wiring: `vehicles.key` is a column, not a flow. Locking/unlocking/starting an engine with a key is follow-up work.
- No seeders for `fuel_types` or `base_vehicles`.
- No despawn path: `VehicleService.activeNetIds` is populated on spawn and never cleaned up.
- Vehicle type passed to `CreateVehicleServerSetter` is hardcoded to `'automobile'`; boats, helicopters, etc. aren't handled yet.
