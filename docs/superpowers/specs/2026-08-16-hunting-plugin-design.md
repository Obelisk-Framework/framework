# oblsk_hunting plugin design

Date: 2026-08-16

## Summary

A new plugin, `oblsk_hunting`, living at `plugins/oblsk_hunting` as its own
nested git repo (same convention as `oblsk_fishing`, `oblsk_vendingmachine`,
etc.). Admin-configured zones spawn roaming animal peds; a player kills one
with a bound hunting weapon, skins the carcass (timed action), carries it
(attached to the player, not an inventory item), optionally loads it into a
vehicle for transport, hands it over at a butcher to be processed into
sellable items over time, then sells those items at a separate sell point.
All world points (zones, butcher, sell points) are admin-placed and
configured, no hardcoded seed data — same posture as `oblsk_fishing`.

This design has two parts:

1. A small, general enhancement to the existing `oblsk_crafting` plugin
   (queueing + configurable pickup policy), needed because the butcher is
   implemented as an ordinary crafting point.
2. The `oblsk_hunting` plugin itself.

## Non-goals

- No per-species weapon tiers — a single `hunting.weapon` binding gate for
  v1 (extendable later, not needed now).
- No stalking/tracking mechanic — animals are ambient roaming spawns within
  admin-defined zones, not a trail-following minigame.
- No water/terrain gating beyond the zone radius itself.
- No wholesale rework of `CraftingService`'s existing input-deduction model
  (`ItemService.remove` per recipe input) — the butcher's recipes simply
  declare zero inputs; carcass consumption is handled entirely by
  `oblsk_hunting` before it calls `CraftingService.start()`.
- No attachment-based crafting inputs as a generic `oblsk_crafting` feature
  — out of scope, sidestepped by the zero-input recipe approach above.
- No per-character carry-capacity variance — flat config constant for how
  many carcasses a player can carry at once (v1: 1).

## Part 1: oblsk_crafting queueing + pickup policy

### Problem

`CraftingService.start()` currently has no check for an existing job at a
point — a character can already have multiple concurrent jobs running at
the same `crafting_point_id` (no uniqueness constraint on `crafting_jobs`).
Output auto-grants directly to the starting character's `character_id` the
moment a job's `remaining_seconds` hits zero, inside `advance()` — there is
no notion of output waiting anywhere to be collected by someone else. The
hunting butcher needs: only one job active at a point at a time (optionally
shared across all players, not just per-character), and optionally lets
anyone (or any org member) collect finished output, not only whoever
started it.

AFK crafting already works today — `advance()` ticks every persisted
`crafting_jobs` row server-wide every tick regardless of player presence,
and no proximity/leave-range check exists anywhere in the client or
server code. Nothing changes there.

### Changes

- `crafting_points` gains:
  - `queue_mode` enum (`'per_character'`, `'shared'`), default
    `'per_character'` (matches today's per-character-only concurrency,
    now made explicit and queued instead of unbounded).
  - `pickup_policy` enum (`'starter_only'`, `'anyone'`, `'org'`), default
    `'starter_only'` (matches today's auto-grant-to-starter behavior).
  - `org_id` (nullable FK `organizations`), required when `pickup_policy =
    'org'`, unused otherwise.
- `crafting_jobs` gains `status` enum (`'queued'`, `'active'`, `'ready'`),
  default `'active'` for backward compatibility with any existing rows
  (there are none in practice yet, but the migration sets a sane default
  regardless). `character_id` keeps meaning "who started this job" in
  every mode — it's the value `pickup_policy = 'starter_only'` checks
  against, not a claim of ownership over the finished output under other
  policies.
- `CraftingService.start(source, craftingPointId, recipeId, batch)`:
  - Resolves the point's `queue_mode`. Under `per_character`: counts this
    character's non-`'ready'` jobs at this point; the first becomes
    `'active'`, subsequent ones insert as `'queued'` (no cap on queue
    depth — same "no artificial limit" posture as the existing `batch <=
    99` check, which already bounds a single job's size).
  - Under `shared`: counts *any* character's `'active'` job at this
    point; if one exists, the new job inserts as `'queued'` regardless of
    who started it; otherwise `'active'`.
  - Input deduction (`ItemService.remove` per recipe input) happens at
    insert time regardless of `queued`/`active`, exactly as today — a
    queued job's materials are already spent, matching the existing
    "materials are spent on start, refunded on cancel" contract.
- `CraftingService.advance(deltaSeconds)`:
  - Only ticks jobs where `status = 'active'`.
  - A job whose `remaining_seconds` reaches zero: `runs_remaining`
    decrements exactly as today for multi-run batches (still auto-loops
    through remaining runs while `active`). When `runs_remaining` hits
    zero, instead of granting output directly to `character_id`, the job
    flips to `status = 'ready'` and output stays unclaimed. Then, if
    `queue_mode = 'shared'`, the oldest `'queued'` job at that
    `crafting_point_id` (if any) is promoted to `'active'` with a fresh
    `started_at`/`remaining_seconds`. Under `per_character`, the same
    promotion happens scoped to that job's `character_id` only.
- New `CraftingService.collect(source, jobId)`:
  - Requires `status = 'ready'`.
  - Policy check: `starter_only` → `job.character_id` must equal the
    caller's active character id; `anyone` → no check; `org` → caller's
    active character must have a truthy
    `OrganizationService.getMembership(characterId, point.org_id)`.
  - On success: grants `recipe.outputBaseItem` × `recipe.outputQty` to
    the caller (via the existing `grantToCharacter` helper), deletes the
    job row, returns `true`. On policy failure: returns `false, 'Not
    yours to collect'` (or equivalent), job row untouched.
- `CraftingService.cancel()`: unchanged in spirit — refunds inputs,
  deletes the row — but now also must promote the next queued job if it
  cancels an `'active'` one (same promotion logic as completion, so a
  queue doesn't stall on a cancel).
- `Crafting.vue` / admin `CraftingTab` (if one exists) gain minimal UI:
  a "ready to collect" state per job the player can see, a collect
  button, and (admin side) the two new per-point config fields.

## Part 2: oblsk_hunting plugin

### Zones & spawning

- `hunting_zones` (id, x, y, z, radius, max_concurrent, label, enabled) —
  admin-placed, position captured from the admin's current coordinates
  (same UX as `oblsk_fishing`'s spot placement and `oblsk_propattach`'s
  placement tool).
- `hunting_zone_species` (id, zone_id FK, species_label, carcass_prop_model,
  weight, base_health) — which animal species can spawn in a zone, their
  relative spawn weight, and the carcass prop model that species produces
  when skinned.
- `HuntingSpawnerService`, ticked from the same `Citizen.CreateThread` loop
  pattern as `oblsk_crafting`'s `advance()`: for each enabled zone below its
  `max_concurrent` live-animal count, picks a random point within the
  zone's radius and a weighted species pick from `hunting_zone_species`,
  then `EntityStreamerService.register('ped', { x, y, z, model = ...,
  networked = true, data = { huntingZoneId, species, health = base_health }
  })`. Tracks `{ entityId -> currentHealth }` in memory, keyed by the
  streamer's own entity id (mirrors `VendingMachineService.credits`-style
  in-memory session state).

### Kill detection

- Killing requires the killing blow to come from a weapon item bound via
  `ItemService.binding('hunting.weapon')`, registered at boot through
  `ItemService.registerRequirements('oblsk_hunting', { 'hunting.weapon' })`
  — same posture as `oblsk_fishing`'s rod-binding gate. No bound weapon
  server-wide → any hit-report is rejected outright.
- Client reports raw hit events only (`entityId`, `weaponHash`, `damage`,
  reported at the moment of impact) — never a claimed kill. Server looks up
  the tracked ped by `entityId`, verifies it's a live hunting-spawned
  entity, verifies the reporting player is holding the bound weapon item,
  and decrements its tracked health by the reported `damage` (clamped to
  the weapon's configured max-damage-per-hit, to prevent an inflated
  client-reported value). Health reaching zero server-side is the only kill
  condition — the server unregisters the ped from `EntityStreamerService`
  (despawns it) and registers a "Skin" `InteractionService` point at its
  last known position, carrying `{ huntingZoneId, species,
  carcassPropModel }` as interaction options.

### Skinning & carry

- The "Skin" interaction triggers a timed client-side action (progress
  bar, `Config.SkinSeconds`). On server-confirmed completion:
  `AttachmentService.attach('ped', playerNetId, playerModel,
  carcassPropModel, 'carry_point', 0, { ownerType: 'plugin:oblsk_hunting',
  data: { species, weight } })`. The interaction point is unregistered
  once skinned (one-time, not reusable).
- Requires a `carry_point` attach point pre-defined (via
  `oblsk_propattach`'s in-game placement tool) on each player ped model in
  use (`mp_m_freemode_01`, `mp_f_freemode_01`) — new admin/content
  prerequisite, not new code in `oblsk_propattach`.
- Carry capacity is a flat config constant (`Config.MaxCarried`, v1: 1) —
  `HuntingService` checks `AttachmentService.getAttachments('ped',
  playerNetId)` filtered to `ownerType = 'plugin:oblsk_hunting'` before
  allowing another skin to complete; at capacity, the skin action is
  refused up front with a notification ("you can't carry any more").

### Loading onto a vehicle

- Near a vehicle with a `trunk_slot` attach point defined for its model
  (same propattach placement-tool prerequisite as above, per relevant
  vehicle model), an interact action lets the player move a carried
  carcass from themselves onto the vehicle:
  `AttachmentService.detach(attachmentId)` on the player's carcass, then
  `AttachmentService.attach('vehicle', vehicleNetId, vehicleModel,
  carcassPropModel, 'trunk_slot', nextFreeSlot, sameOwnerOpts)`. Slot
  choice and the vehicle's max-slot check both come from
  `getAttachments('vehicle', vehicleNetId)`'s current count against a
  `Config.MaxPerVehicle` constant (flat for v1, not per-vehicle-model).
- Loading is optional — a player can walk a single carcass straight to the
  butcher on foot if capacity allows; a vehicle only matters for carrying
  more than `Config.MaxCarried` at once across multiple trips consolidated
  into one drive.

### Butcher (crafting point)

- The butcher is an ordinary `crafting_points` row (admin-created through
  `oblsk_crafting`'s existing point/recipe CRUD, exposed via
  `oblsk_hunting`'s admin tab for convenience — no new crafting-side admin
  UI needed). Admin sets its `queue_mode`/`pickup_policy` like any other
  point (a community butcher would typically be `shared` +
  `anyone`/`org`).
- Recipes are per species, e.g. "Process Deer Carcass": zero
  `ItemService`-backed inputs, one or more configured outputs (reusing
  `oblsk_crafting`'s existing single-output-per-recipe shape — a species
  yielding both meat and a pelt needs two recipes, or `oblsk_crafting`'s
  recipe model needs multi-output support; **v1 assumes single output per
  recipe**, i.e. a species maps to one sellable item, matching
  `oblsk_crafting`'s current schema without changing it).
- Hand-over is a new `HuntingButcherService.handOver(source, craftingPointId,
  vehicleNetId)`: reads every attachment on `vehicleNetId` with `ownerType
  = 'plugin:oblsk_hunting'`, tallies by `species`, detaches each one, and
  for each species with a matching recipe at that point calls
  `CraftingService.start(source, craftingPointId, recipeId, batch =
  tally[species])`. A species present with no matching recipe at that
  point is left attached (not silently discarded) and the player is
  notified which ones couldn't be processed there.
- The player later returns to `CraftingService.collect()` (via the normal
  crafting UI) to claim the processed meat/pelt items, subject to the
  point's pickup policy.

### Selling

- `hunting_sell_points` (id, x, y, z, range, label, enabled) — separate
  admin-placed interaction, hunting-owned (own table, not routed through
  `oblsk_shop` — same "plugin owns its own simple mechanism" posture as
  `oblsk_fishing` owning its spots instead of a generic system).
- `hunting_sell_point_items` (id, sell_point_id FK, base_item_id FK,
  cash_per_unit) — which processed items are sellable there and at what
  price.
- Interact at a sell point lists the player's owned amount of each
  sellable item (mirrors `CraftingService.ownedCounts`'s "server resolves
  ownership, client never computes it" rule); selling calls
  `ItemService.remove` then grants cash via the existing `currency.cash`
  item binding, same pattern as every other cash-handling service in the
  codebase (`BankingService`, `ShopService`, etc.).

## Data model

New tables:

```
hunting_zones
  id, x, y, z, radius, max_concurrent, label, enabled, timestamps

hunting_zone_species
  id, zone_id (FK hunting_zones), species_label, carcass_prop_model,
  weight (float), base_health (integer), timestamps

hunting_sell_points
  id, x, y, z, range, label, enabled, timestamps

hunting_sell_point_items
  id, sell_point_id (FK hunting_sell_points), base_item_id (FK base_items),
  cash_per_unit (integer), timestamps
```

`oblsk_crafting` migrations (additive, existing tables):

```
crafting_points
  + queue_mode enum('per_character','shared') default 'per_character'
  + pickup_policy enum('starter_only','anyone','org') default 'starter_only'
  + org_id nullable FK organizations

crafting_jobs
  + status enum('queued','active','ready') default 'active'
```

Carried/loaded carcasses have **no `oblsk_hunting` table** — they live
entirely in `oblsk_propattach`'s existing `attachments` table, scoped by
`owner_type = 'plugin:oblsk_hunting'`.

## File layout

```
plugins/oblsk_hunting/             (own git repo)
  fxmanifest.lua
  shared/config.lua                SkinSeconds, MaxCarried, MaxPerVehicle,
                                    weapon max-damage-per-hit
  server/
    main.lua                       boot: register zones/sell points, item
                                    binding requirement, spawner tick loop
    migrations/*.lua                hunting_zones, hunting_zone_species,
                                    hunting_sell_points, hunting_sell_point_items
    services/
      HuntingZoneService.lua       zone/species CRUD for the admin tab
      HuntingSpawnerService.lua    weighted spawn, per-zone cap, health tracking
      HuntingKillService.lua       hit-report validation, health decrement,
                                    death -> skin-interaction registration
      HuntingCarryService.lua      skin completion -> attach, carry-capacity
                                    gate, load-onto-vehicle
      HuntingButcherService.lua    hand-over: detach + tally + CraftingService.start
      HuntingSellService.lua       sell-point CRUD + sell transaction
  web/
    HuntingTab.vue                 admin tab: zones/species, sell points,
                                    weapon binding, links into crafting's
                                    existing point/recipe CRUD for the butcher
    routes.js
  tests/
    hunting_spawner_service_spec.lua
    hunting_kill_service_spec.lua
    hunting_carry_service_spec.lua
    hunting_butcher_service_spec.lua
    hunting_sell_service_spec.lua

plugins/oblsk_crafting/            (existing repo, additions)
  server/migrations/*.lua           + queue_mode/pickup_policy/org_id,
                                     + status column
  server/services/CraftingService.lua
                                     start(): queue_mode-aware active/queued
                                     insert; advance(): active-only ticking,
                                     ready-not-granted, promotion on
                                     completion/cancel; + collect()
  web/Crafting.vue                  + ready/collect UI
  tests/crafting_service_spec.lua   + queueing, promotion, collect-policy
                                     tests

plugins/oblsk_propattach/          (existing repo, content-only prerequisite)
  no code changes — admin must place `carry_point` on player ped models
  and `trunk_slot` on relevant vehicle models via the existing placement
  tool before oblsk_hunting can function
```

## Testing

- `CraftingService`: `per_character` queueing (2nd start queues, promotes
  on completion), `shared` queueing (any character's start queues behind
  another's active job), `collect()` under each `pickup_policy`
  (starter_only rejects a non-starter, anyone allows any caller, org
  checks `OrganizationService.getMembership`), cancel promotes the next
  queued job, AFK ticking unaffected (regression check that `advance()`
  still processes jobs with no player nearby).
- `HuntingSpawnerService`: zone `max_concurrent` respected, weighted
  species selection distribution (deterministic random override, same
  technique as `VENDING_RANDOM_OVERRIDE`).
- `HuntingKillService`: damage accumulation to zero triggers death exactly
  once, damage clamped to configured max-per-hit, hit report rejected
  without the bound weapon, hit report against an unknown/already-dead
  `entityId` rejected.
- `HuntingCarryService`: skin completion attaches to the player, carry-cap
  refusal at `Config.MaxCarried`, load-onto-vehicle respects
  `Config.MaxPerVehicle` and correctly detaches-then-reattaches.
- `HuntingButcherService`: species tally across mixed-species vehicle
  load, detach happens for every tallied carcass, missing-recipe species
  left attached and reported, correct `batch` passed to
  `CraftingService.start()` per species.
- `HuntingSellService`: sell removes the correct amount and grants the
  configured `cash_per_unit` total, refusal when the player doesn't own
  enough.

## Open questions resolved during design

- Carcasses are attachment-only (propattach), never an `ItemService` item
  — carried on the player, optionally loaded onto a vehicle, consumed
  directly by the butcher hand-off.
- The butcher is implemented as an ordinary `oblsk_crafting` point with
  zero-input recipes, not a bespoke processing service — avoids building
  a second timed-job system.
- Crafting queueing/pickup-policy is a general `oblsk_crafting` capability
  (configurable per point), not a hunting-only special case, since other
  future plugins (or crafting itself) benefit from shared/org-collectible
  points.
- v1 assumes one output per butcher recipe (matches `oblsk_crafting`'s
  existing schema) — a species yielding both meat and a pelt needs two
  recipes rather than a multi-output recipe.
