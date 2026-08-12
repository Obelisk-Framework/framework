# Garage plugin design

Source design: Claude Design project "FiveM" (`src/proto/garage.jsx`) — a
tall right-docked panel listing vehicles homed at one garage, with
All/In garage/Out filters, search, rename, favourite/star, and a
park-in/park-out action.

## Scope

Full plugin: DB schema, server service, client vehicle spawn/despawn, Vue UI
wired to real data (not a demo-only port, unlike `nativeMenu`).

## Data model

**`oblsk_garage` (this plugin) — owns `garages`:**

- `garages`: `id`, `name`, `type` (`public`/`house`/`impound`, default
  `public`), `interaction_id` (FK → core `interactions.id`, unique) —
  coordinates live on the `interactions` row (core's existing spatial system
  handles range checks, streaming, prompts); the garage just references it.

**`oblsk_vehicles` (core module) — extend `vehicles` table** (cross-repo
change, same precedent as the MDT+organizations `Character:can()` fix, but
with no cross-repo *dependency* — see the note below):

- `plate` (string, unique) — every vehicle instance needs one regardless of
  which plugin manages it (garage, mechanic, dealer, police lookup, ...).
- `display_name` (string, nullable) — player-chosen name; falls back to the
  base vehicle's name when null.
- `fuel_level` (float, default 100)
- `stored` (boolean, default true) — whether the vehicle currently exists as
  a despawned DB record (`true`) or a spawned entity in the world (`false`).
- `garage_id` (nullable integer, FK → `oblsk_garage`'s `garages.id`) — which
  garage this vehicle is homed at, if any. A null value means the vehicle
  isn't garage-managed (e.g. a mission vehicle).
- `favorite` (boolean, default false) — starred in its garage's UI.

Note — **no inverted dependency**: the column and the constraint are owned by
different repos. `oblsk_vehicles` adds `garage_id` as a plain nullable
integer with no foreign key, so that migration is self-contained and the core
module stays generic — it never references a plugin table. `oblsk_garage`
then adds the `garage_id → garages.id` FK constraint itself, in its own
migration (`2026_08_12_060200_add_garage_fk_to_vehicles_table`), ordered after
its `create_garages_table`.

This is what makes the ordering work at all: `bootstrap.lua` runs every
module's migrations before any plugin's, so a module migration can never
depend on a plugin-owned table existing. Splitting the constraint out means
both required orderings hold automatically — the column exists by the time
plugins run, and `garages` exists by the time the constraint migration runs.
Keeping the FK inside the module migration would have half-applied it (the
`ADD COLUMN`s succeed, the `ADD CONSTRAINT` throws, the migration is never
recorded, and it retries and fails on every subsequent boot).

Filtering in the UI: **All** = every `vehicles` row with `garage_id` equal
to this garage; **In garage** = also `stored = true`; **Out** =
`stored = false`.

## Backend flow

- Plugin boot (`server/main.lua`): for every `Garage` row, register its
  `interaction_id` (if not already registered — interactions persist across
  restarts via the `interactions` table like any other core data) and
  register one shared action `garage:open`, whose handler resolves the
  triggering interaction's owning `Garage` and opens the webview for that
  `source` with that garage's vehicle list.
- `GarageService` (server): `list(garageId, characterId)`,
  `rename(source, vehicleId, name)`, `toggleFavorite(source, vehicleId)`,
  `parkOut(source, vehicleId)`, `parkIn(source, vehicleId, damageState)`.
  Every mutating call re-checks the vehicle's `owner_type/owner_id` against
  the calling character — no trusting client-supplied ownership.
- `parkOut` flips `vehicles.stored = false` and tells the client to spawn
  the entity (base vehicle model, plate, engine/body health) at the
  garage's interaction coords.
- `parkIn` (triggered by the client when the player is near their own
  spawned vehicle and picks "Park In") flips `stored = true`, persists
  current `engine_health`/`body_health`/`fuel_level`/`body_damage`, and
  tells the client to delete the entity.

## Frontend

- `web/Garage.vue` — port of `garage.jsx` 1:1 (search, All/In/Out tabs,
  vehicle grid cards with plate placard, rename-on-double-click, star
  toggle, select + Park In/Out button, toast, esc-to-close slide-out
  animation). Same NUI event pattern as `nativeMenu`: opened via
  `core:client:webview-openPage`, receives its vehicle list over a
  `garage:sync` event, emits `garage:rename` / `garage:toggleFavorite` /
  `garage:parkToggle` back through `Obelisk.emit`, closes through the
  existing `core:client:close` path.

## Out of scope (not in the source design, not adding speculatively)

- Impound flow / release fees.
- Vehicle transfer between garages.
- Fleet-wide (multi-character) shared garages.
