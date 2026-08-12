# Garage park-out positions + proximity filtering design

Follow-up to [`2026-08-12-garage-plugin-design.md`](2026-08-12-garage-plugin-design.md).
The shipped `oblsk_garage` spawns every parked-out vehicle at the garage's
single `interactions` coordinate with `heading = 0.0`, which stacks vehicles
on top of each other with no collision handling, and lists every
`stored = false` vehicle regardless of whether it's actually near the garage
it's homed at.

## Scope

- Filter the `Out of garage` tab (and `All`) to only vehicles physically near
  their home garage.
- Add named, explicit park-out spawn slots per garage (`GarageParkOutPosition`),
  each checked for real-world occupancy before a vehicle spawns into it.
- Notify the player when a garage has no free slot.
- Permission-gated in-game commands for garage creation (`garage_create`)
  and park-out position authoring (`garage_edit`) — there was previously no
  in-game way to do either.

Not in scope: admin-panel authoring UI (command-based for now, panel is
future work), garage removal/editing commands beyond creation, impound/
transfer flows (already out of scope per the base design).

## Proximity filter (list)

`GarageService.list(garageId, characterId)` currently returns every vehicle
row matching `garage_id`/`owner_type`/`owner_id`. For rows with
`stored = false`, additionally resolve the live entity via
`VehicleService.activeNetIds[vehicleId]` → `NetworkGetEntityFromNetworkId` →
`GetEntityCoords`, and only include the row if that position is within
`interaction.range + RANGE_TOLERANCE` of the garage's own `interactions` row
(the same tolerance and coordinate source `isNearGarage` already uses for the
park-in range check — no new config).

If `activeNetIds` has no entry, or the entity no longer exists, the vehicle
is excluded. This is a knowingly-accepted edge case: it means a vehicle whose
entity was destroyed by some other system (exploded, admin-deleted, server
restart lost track of it) stops appearing until an out-of-band fix re-syncs
`stored`. No new recovery mechanism is being built for that here.

## `GarageParkOutPosition` model

New table, this plugin (`oblsk_garage`) owns it — no cross-repo migration
ordering concerns, unlike `garages` itself:

- `id`
- `garage_id` — FK → `garages.id`, `onDelete('CASCADE')`, not nullable
- `x`, `y`, `z` — float, not nullable
- `heading` — float, not nullable
- `timestamps()`

```lua
GarageParkOutPosition = BaseModel:extend('garage_park_out_positions')
GarageParkOutPosition.fillable = { 'garage_id', 'x', 'y', 'z', 'heading' }
```

A garage can have zero, one, or many positions. Zero positions means every
park-out attempt is treated as "full" (see below) until at least one is
added.

## Authoring: garage creation + positions

Gated by `PermissionService`, not a blanket ace admin check — `Character` is
already a registered permission owner type
(`HasPermissions.apply(Character, 'character')` in `oblsk_characters`), and
granting is already generic: `oblsk_organizations`' `/org-grant <ownerType>
<ownerId> <key>` works for any `ownerType`, including `character`, so no new
grant command is needed here (an admin runs
`/org-grant character <characterId> garage_edit`, etc.).

Both commands resolve the calling character the same way `GarageService`
already does (`CharacterService.getActiveCharacterId(source)`), then check
`PermissionService.can('character', characterId, key)`.

```
/garage-create <name> [type]
```

Requires `garage_create`. There was previously no in-game way to create a
garage at all (README: "insert directly or via a one-off seeder script").
This command: inserts an `Interaction` row at the caller's current
`GetEntityCoords` (default `range = 2.0`, `label = name`), inserts a `Garage`
row referencing it (`type` defaults to `'public'`), and calls
`InteractionService.register(...)` immediately so it's live without a
restart — the same registration `registerAllGarages()` does at boot.

```
/garage-addposition <garageId>
```

Requires `garage_edit`. Captures the caller's current
`GetEntityCoords`/`GetEntityHeading` and inserts a `GarageParkOutPosition`
row. No removal command in this pass (rows can be deleted directly if a
position needs retiring) — kept minimal since full CRUD authoring is a
placeholder for the future admin panel, noted in the README as a follow-up.

## Occupancy check + spawn

`GarageService.parkToggle`'s spawn branch changes from "spawn at the
interaction's coords" to "find a free position, spawn there":

1. Fetch all `GarageParkOutPosition` rows for the vehicle's `garage_id`, in
   `id` order.
2. For each, check a radius (`Config.ParkPositionRadius`, default `2.5`)
   around `(x, y, z)` for any blocking entity: `GetAllVehicles()`,
   `GetAllPeds()`, `GetAllObjects()`, each filtered by `DoesEntityExist` and
   a 3D distance check against the position. Any hit marks the position
   occupied.
3. First unoccupied position wins; the vehicle spawns there (`x, y, z,
   heading` from the row) instead of the interaction's coordinates.
4. If every position is occupied, or the garage has none configured,
   `parkToggle` returns `false, 'garage full'` without touching the
   `vehicles` row, and the caller (`server/main.lua`'s
   `garage:client:parkToggle` handler) calls
   `NotificationService.notify(source, { type = 'error', title = 'Garage
   full', description = 'Every parking spot at this garage is occupied.' })`
   — same pattern as `oblsk_shop`'s `notifyFailure`.

The park-in (despawn) path is unaffected — it already deletes whatever
entity `activeNetIds` points at, independent of positions.

## Testing

- `GarageService.list` proximity filtering: extend the existing spec's fake
  `QueryBuilder` + a fake `VehicleService.activeNetIds`/entity-coords stub
  to cover "out vehicle near its garage → included" and "out vehicle far
  from its garage → excluded".
- Occupancy selection: unit-test the position-picking logic in isolation
  (given N positions and a stubbed occupancy check per position, returns the
  first free one / `nil` when all occupied) rather than stubbing
  `GetAllVehicles`/`GetAllPeds`/`GetAllObjects` directly — those natives
  aren't meaningfully fakeable in the existing Lua spec harness, so the
  occupancy *scan* itself stays server-only/untested-in-CI, same as other
  native-heavy code in this codebase (e.g. `despawnAndStore`'s entity health
  reads).
