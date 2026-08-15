# oblsk_fishing plugin design

Date: 2026-08-16

## Summary

Port the fishing minigame from the Claude Design prototype
(`src/proto/fishing-game.jsx`) into a new plugin, `oblsk_fishing`, living at
`plugins/oblsk_fishing` as its own nested git repo (same convention as
`oblsk_vendingmachine`, `oblsk_terminal`, etc.), pushed to its own remote.

Visually and mechanically the minigame is a 1:1 port: cast → wait for a bite
→ hit SPACE in a 1s window to set the hook → reel through a series of
needle-sweep skill checks → land or lose the fish. The reward is a
BaseItem, granted only on landing.

The critical departure from the prototype is trust: the prototype computes
everything (bite timing, needle position, hit/miss, which fish/reward) in
the browser. None of that can be trusted from a game client. This plugin
makes the server authoritative for every random decision and every
timing judgement; the client only renders what the server tells it to and
reports raw input events (a keypress happened now), never claimed
outcomes.

Two related gaps surfaced during design and are fixed as part of this
work, both scoped to what fishing actually needs:

1. Reward pools must be admin-configurable per fishing spot, per rod, with
   no code-level seeding.
2. There is currently no slot/weight capacity system anywhere in the
   framework — `ItemService.add` always succeeds. Granting a fish must not
   silently blow past reasonable carry limits.

## Non-goals

- No changes to `ItemService.add`'s behavior for any other existing caller.
- No per-character capacity variance (backpack upgrades, etc.) — flat
  config constants for v1.
- No rework of the generic (currently stub) Interactions admin tab —
  `oblsk_fishing` owns its own spot storage and its own admin tab, the same
  way `oblsk_vendingmachine` owns `vendingmachine_shops` instead of using a
  shared generic shop system.
- No location/water-material gating on where a rod can be used — only the
  admin-placed spot's interaction range gates it.

## Architecture

### Trigger & gates

- `fishing_spots` (id, x, y, z, range, label, enabled) — admin-placed,
  world interaction points. On boot, `oblsk_fishing` reads every row and
  calls `InteractionService.register`, exactly like
  `VendingMachineService`'s `registerAllMachines()`.
- Using a spot requires holding the item bound to the `fishing.rod` item
  binding key (`ItemService.binding('fishing.rod')`), registered via
  `ItemService.registerRequirements` at plugin boot. No rod bound
  server-wide → the action fails with a clear notification, same failure
  posture as `VendingMachineService.insertNote`'s missing-`currency.cash`
  case.
- Which BaseItems can be caught, and at what odds, is scoped to
  **(spot, rod item)** — `fishing_rod_pools` (id, spot_id, rod_base_item_id)
  and `fishing_pool_entries` (id, rod_pool_id, base_item_id, weight,
  difficulty, min_amount, max_amount). A rod picked up by the player
  resolves which `fishing_rod_pools` row applies at that spot (rod's
  `base_item_id` must match); no matching pool → cast fails, "this rod
  doesn't work here."
- Casting optionally consumes 1 bait item first, if the spot has a
  `bait_item_id` configured (nullable FK on `fishing_spots`), via
  `ItemService.remove`. Failure to remove (not enough bait) aborts the
  cast before any challenge starts. Bait already spent by the time a catch
  is decided is not refunded on a loss — same "no automatic reversal"
  posture as `VendingMachineService.purchase`'s post-payment item-grant
  failure.

Why (spot, rod) instead of `ItemBinding` for the rod→pool mapping:
`item_bindings.key` is unique — one physical BaseItem per key, framework
-wide. That can express "the one official fishing rod" but not "three rod
tiers, each with a different loot table." Direct FK config sidesteps that
limit entirely; `ItemBinding` is still used, but only for the coarse
"is this a rod at all" gate.

### Server-authoritative minigame

State machine per player session (in-memory, like
`VendingMachineService.credits`), keyed by `source`: `wait → bite → reel
→ landed | lost`. At most one outstanding session per source; starting a
new cast supersedes/clears any prior session, same discipline as
`LockpickChallengeService.issue` superseding an outstanding token.

- **wait**: server rolls a bite delay (1.6–5.4s, matching the prototype's
  range) via its own timer (`SetTimeout`/`Citizen.CreateThread`), then
  emits a `bite` event to the client. A client keypress that arrives before
  this event has no session to match → treated as "struck too early,
  spooked it," ending the attempt. The server, not the client, decides
  when the bite happens.
- **bite**: server starts a 1000ms deadline (+ a small fixed tolerance,
  ~150ms, for round-trip latency) from the moment it sent the `bite`
  event. A `spacePressed` event arriving after that deadline is rejected
  as "too slow." One that arrives in time transitions to `reel` and rolls
  the fish now (weighted pick from the resolved `fishing_pool_entries`),
  so the client only learns what's on the line at this point, never
  before.
- **reel**: repeating skill-check rounds, mirroring
  `FishSkillCheck`/`FishingGame`'s `onResult` in the prototype exactly:
  - Server rolls `startAngle` and `direction`, derives `speed`/`zone` from
    the hooked fish's `difficulty` (same formulas as the prototype:
    `speed = 150 + difficulty * 55`, `zone = max(34, 76 - difficulty *
    16)`), records `GetGameTimer()` as the round's start, and sends
    `{ speed, zone, direction, startAngle, roundId }` to the client for
    rendering only.
  - The client draws the sweeping needle from those parameters (same
    trig as the prototype) and, when the player presses SPACE, sends a
    bare `spacePressed(roundId)` — no claimed result, no timestamp the
    client controls the meaning of.
  - The server recomputes the needle's angle at the moment the event is
    received, using its own elapsed time (`GetGameTimer() - roundStart`)
    through the identical sweep formula, and classifies great/good/miss
    with the same thresholds as the prototype (`rel <= zone`, "great" if
    within the middle 44% of the zone).
  - Progress moves by the same deltas as the prototype (+0.24 great,
    +0.15 good, -0.18 miss), clamped to [0, 1]. A round that never gets a
    response before its own sweep would have wrapped past the ring
    (server-computed, same bound as the client visual) auto-resolves as a
    miss — the server enforces this with its own timer per round, it does
    not wait indefinitely on the client.
  - `progress >= 1` → `landed`; `progress <= 0` → `lost`; otherwise issue
    the next round. One round token outstanding at a time; a stale/replayed
    `roundId` is rejected.
- **landed**: before granting anything, call
  `ItemService.hasCapacity(source, baseItem, amount)`. If it fails, the
  catch is lost to a full inventory — notified explicitly ("your
  inventory is full, the fish slips back"), not silently dropped. If it
  passes, `ItemService.add` grants the rolled amount and the client shows
  the landed-fish summary (name/kg/price display only — no gameplay
  effect from the flavor numbers, same as the prototype).

### Capacity check (`oblsk_items`)

New `ItemService.hasCapacity(source, baseItem, amount, forceNewStack)` in
`modules/oblsk_items`:

- Computes the character's current total carried weight: sum of
  `Item:getWeight()` over every `items` row with `owner_type = 'character'
  ` and `owner_id = characterId`, **plus** recursively every row with
  `owner_type = 'item'` whose `owner_id` chains back to one of those
  (container contents count toward carried weight even though they're
  not directly on the character).
- Computes current slot count: the number of top-level
  (`owner_type = 'character'`) rows — containers count as 1 slot
  regardless of what's inside them, contents don't consume additional
  top-level slots.
- Projects the new grant: if an existing mergeable stack exists (same
  lookup `ItemService.add` itself does, unless `forceNewStack`), only
  weight increases; otherwise both weight and slot count increase by one
  stack.
- Returns `false` if the projection would exceed `Config.MaxSlots` or
  `Config.MaxWeight` (new constants in `modules/oblsk_items/shared/config.lua`),
  `true` otherwise.
- `ItemService.add` itself is unchanged — every existing caller
  (`VendingMachineService`, `TerminalService`, etc.) keeps its current
  unconditional-add behavior. Only `FishingService` calls
  `hasCapacity` before `add`, in this change. Adopting the check
  elsewhere is future work, not part of this plugin.

### Admin UI

Two additions, both minimal, both following existing patterns:

1. **`oblsk_admin` item creation**: `ItemsTab.vue`'s create form gets an
   optional "Binding key" text input. `ItemService.createBaseItem` gains
   a `bindingKey` param; when present, after the item is created it
   upserts the matching `item_bindings` row (insert, or update if the key
   already points elsewhere — this UI is the admin's explicit intent to
   rebind). This is the one generic, non-fishing-specific piece of this
   plugin's work — it makes assigning `fishing.rod` (or any future
   binding key) to an item a form field instead of a manual DB write.
2. **`oblsk_fishing`'s own admin tab**: a new `Fishing` entry added to
   `oblsk_admin`'s hardcoded `TABS` list (same mechanism as `Items`),
   backed by a `FishingTab.vue` that ships inside `oblsk_fishing`'s own
   `web/` dir (imported into `oblsk_admin`'s `AdminPanel.vue`, matching
   how every other tab is already a direct import — there's no dynamic
   plugin-tab registration in this codebase to build a bigger mechanism
   for). The tab: lists/creates `fishing_spots` (position captured from
   the admin's current coordinates, same UX as the in-game placement tool
   used by `oblsk_propattach`), and per spot, lists/creates
   `fishing_rod_pools` (pick a rod BaseItem) and, per rod, lists/creates
   `fishing_pool_entries` (pick a reward BaseItem, weight%, difficulty,
   min/max amount).

## Data model

New tables, all in `oblsk_fishing`'s own migrations except `item_bindings`
which already exists:

```
fishing_spots
  id, x, y, z, range, label, bait_item_id (nullable FK base_items),
  enabled, timestamps

fishing_rod_pools
  id, spot_id (FK fishing_spots), rod_base_item_id (FK base_items),
  timestamps

fishing_pool_entries
  id, rod_pool_id (FK fishing_rod_pools), base_item_id (FK base_items),
  weight (float, relative — normalized at selection time, not required to
    sum to 100), difficulty (float, default 1.0), min_amount, max_amount
    (integers, default 1/1), timestamps
```

## File layout

```
plugins/oblsk_fishing/            (own git repo)
  fxmanifest.lua
  shared/config.lua               MaxCastRange defaults, timing constants
  server/
    main.lua                      boot: register spots, item binding requirement
    migrations/*.lua               fishing_spots, fishing_rod_pools, fishing_pool_entries
    services/
      FishingSpotService.lua      spot/pool/entry CRUD for the admin tab
      FishingChallengeService.lua the authoritative wait/bite/reel state machine
      FishingService.lua          cast entrypoint, pool resolution/weighted pick, reward grant
  web/
    Fishing.vue                   in-game minigame UI (port of fishing-game.jsx)
    FishingTab.vue                admin tab (spots/pools/entries CRUD)
    routes.js
  tests/
    fishing_challenge_service_spec.lua
    fishing_service_spec.lua

modules/oblsk_items/               (existing repo, small additions)
  server/services/ItemService.lua  + hasCapacity, + bindingKey plumbing for createBaseItem
  shared/config.lua                + Config.MaxSlots, Config.MaxWeight

plugins/oblsk_admin/               (existing repo, small additions)
  web/AdminPanel.vue               + Fishing tab entry, import FishingTab from oblsk_fishing
  web/ItemsTab.vue                 + binding key field on create form
  server/items.lua                 + pass bindingKey through on create
```

## Testing

- `FishingChallengeService`: bite-window timing accept/reject at the
  boundary, per-round angle-at-elapsed-time classification (great/good/
  miss) against known parameters, progress accumulation to landed/lost,
  rejection of a stale/replayed `roundId`, rejection of a second
  concurrent session for the same source.
- `FishingService`: weighted pool selection distribution (deterministic
  with a random override, same technique as
  `VENDING_RANDOM_OVERRIDE`), rod→pool resolution (no pool for that rod
  at that spot → cast rejected), bait consumption and its failure path,
  capacity check blocking a grant.
- `ItemService.hasCapacity`: under/at/over weight, under/at/over slots,
  merge-into-existing-stack not counted as a new slot, nested container
  contents counted toward weight.

## Open questions resolved during design

- Rod→pool mapping is direct FK config, not `ItemBinding` (see
  Architecture, "why (spot, rod)").
- No water/location material check for v1 — only the spot's own
  interaction range gates casting.
- Capacity constants are flat (`Config.MaxSlots`, `Config.MaxWeight`),
  not per-character, for v1.
