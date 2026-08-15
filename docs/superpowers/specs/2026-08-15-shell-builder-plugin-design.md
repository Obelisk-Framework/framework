# Shell Builder: player-enterable interiors via routing-bucket dimensions

**Goal:** A new `oblsk_shellbuilder` plugin that lets staff build "shells" —
enterable interiors (houses, hideouts, workshops) — either fully furnished or
left empty for the owning character(s) to furnish themselves, plus a new
core `InstanceService` that gives any shell (and, later, any other
instanced space) its own non-colliding, non-visible dimension via FiveM
routing buckets.

**Source design:** Claude Design project `FiveM`, `pages/shell-builder.html`
+ `src/proto/shell-builder.jsx` / `shell-browser.jsx` / `shell-art.jsx`
(browser screen, in-world editor with bottom dock, isometric room art).
`src/housing.jsx` / `src/proto/housing.jsx` are a *future*, separate
housing/purchase layer that would sit on top of this plugin — not built
here.

## Architecture

Two pieces, split by ownership per this repo's module/plugin convention
(`core/docs/concepts/modules-and-plugins.md`):

- **`core/core/server/Services/InstanceService.lua`** (new core service) —
  generic dimension allocation via FiveM routing buckets. Not
  shellbuilder-specific; any future plugin needing an isolated instance
  (a robbery, a private event) reuses it.
- **`plugins/oblsk_shellbuilder/`** (new plugin) — shell CRUD, ownership,
  placed-object persistence, the editor/browser UI, and the world
  interaction that opens it.

### InstanceService: routing buckets as dimensions

FiveM's `SetPlayerRoutingBucket` isolates players (and, with matching
entity buckets, entities) into non-colliding, mutually invisible buckets.
A shell can have multiple owning characters who *should* see each other
inside it, so a bucket is assigned **per shell, not per player-session** —
deterministic, not pooled from a free-list.

New table `instance_buckets`: `id`, `key` (unique string, e.g.
`shellbuilder:shell:42`), `bucket_id` (int), timestamps. `bucket_id` is
simply `id + 1000` (an offset clear of FiveM's default bucket `0`) —
no separate allocator, no free-list bookkeeping, and it's stable across
restarts since it's derived from the row's own id.

API:

- `InstanceService.getOrCreateBucket(key)` — returns `bucket_id`, creating
  the row if `key` is new.
- `InstanceService.enter(source, key, opts)` — resolves `key`'s bucket,
  calls `SetPlayerRoutingBucket(source, bucketId)`, and applies
  `SetRoutingBucketPopulationEnabled(bucketId, false)` +
  `SetRoutingBucketEntityLockdownMode(bucketId, 'strict')` the first time
  that bucket is used in the session (ambient traffic/peds have no reason
  to exist inside a shell interior).
- `InstanceService.leave(source)` — `SetPlayerRoutingBucket(source, 0)`,
  back to the shared overworld.
- `InstanceService.getPlayersIn(key)` — for "who's inside right now"
  queries (multiple owners together, staff editing while an owner is
  also inside).

### Shared underground anchor

Every shell's interior geometry is placed at one fixed, shared coordinate
far below the map. Routing buckets already make two different shells'
buckets invisible and non-colliding to each other at identical
coordinates, so there's no need to hunt for or allocate a free map slot
per shell — the bucket alone provides isolation. This mirrors how
existing FiveM housing resources solve the same problem.

## Data Model

```lua
-- shells: the interior + its overworld door
Schema.create('shells', function(table)
    table:id()
    table:string('name', 100)
    table:float('entry_x')
    table:float('entry_y')
    table:float('entry_z')
    table:float('entry_heading'):default(0)
    table:float('interior_heading'):default(0)
    table:integer('object_budget'):default(900)
    table:string('timecycle', 40):default('Neutral')
    table:integer('created_by_character_id')
    table:timestamps()
end)

-- shell_owners: many-to-many, multiple owning characters per shell
Schema.create('shell_owners', function(table)
    table:id()
    table:integer('shell_id')
    table:integer('character_id')
    table:timestamps()

    table:index({'shell_id'})
    table:index({'character_id'})
end)

-- shell_objects: every placed piece, staff-fixed or owner-placed
Schema.create('shell_objects', function(table)
    table:id()
    table:integer('shell_id')
    table:string('item_key', 60)      -- resolves via oblsk_items
    table:float('x')
    table:float('y')
    table:float('z')
    table:float('heading'):default(0)
    table:integer('floor_level'):default(0)
    table:boolean('locked'):default(0)
    table:integer('placed_by_character_id'):nullable()
    table:json('color_data'):nullable()
    table:timestamps()

    table:index({'shell_id'})
end)

-- instance_buckets: core, key -> deterministic routing bucket
Schema.create('instance_buckets', function(table)
    table:id()
    table:string('key', 120):unique()
    table:integer('bucket_id')
    table:timestamps()
end)
```

`shell_objects.locked` is the whole mechanism for "comes with interior,
not removable" vs "empty, owner furnishes it": staff (build permission)
place walls/floors/doors via the Construction/Style tools — always
`locked = true`, owners never get those tools at all. Staff *optionally*
also pre-place decor and lock it — that's a furnished shell. An empty
shell simply has no locked decor rows, leaving the Decorate tool fully
open for the owner. One shell can mix locked and unlocked pieces (a
locked kitchen counter next to the owner's own unlocked couch).

`item_key` resolves through `oblsk_items` rather than a static prop list
(per the item-binding convention used elsewhere in this framework) —
placing an object consumes/binds the corresponding item.

## Entry Flow

A world interaction at each shell's `entry_x/y/z` (registered via core
`InteractionService`, the same proximity-interaction pattern
`oblsk_terminal`/`oblsk_cardealer` already use) opens a new NUI screen —
the shell browser/enter view, ported from the design's `SbBrowser`,
trimmed to what a given player can actually do:

- **Owner** (row exists in `shell_owners`): sees **Enter**.
- **Staff with build permission**: also sees **Edit** (opens the
  Construction/Style/Decorate editor), plus shell management (rename,
  change coordinates, delete) and **Create new shell**.

Selecting Enter or Edit calls `InstanceService.enter(source,
'shellbuilder:shell:'..shellId)`, then teleports the player to the shared
underground anchor at `interior_heading`. Exiting reverses both:
`InstanceService.leave` + teleport back to `entry_x/y/z`.

## Build Permission

Creating shells and entering edit mode is gated by `PolicyService`
against a staff/build permission — the same org/rank-gated convention
already used elsewhere (e.g. `oblsk_doors`' org/rank/department rules).
Ownership (who may *enter*, independent of build permission) is purely
`shell_owners` membership, checked separately.

## Editor UI

Ported from `shell-builder.jsx` / `shell-browser.jsx` / `shell-art.jsx`:
bottom-dock editor with a tool rail (Construction / Style / Decorate),
category chips + search, an item filmstrip drawing from `oblsk_items`,
the OKLCH palette + custom color mixer, an object-count budget bar
(`shell_objects` count for that shell vs `shells.object_budget`), undo,
delete ("wreck") mode, and floor up/down. Owner-mode simply hides the
Construction/Style rail entries and filters `wreck`/placement to
`locked = false` rows only — one component, permission-gated rendering,
not a second UI.

## Walkthrough Preview

No separate preview instance. The design's existing `walk` toggle
already switches the player from build-cursor/raycast placement mode to
normal ped movement inside the same shell dimension — reused as-is.
Walking through it *is* the preview; there's nothing else to build here.

## Error Handling

- Placing an object beyond `object_budget` is rejected server-side with
  an `error`-type `NotificationService.notify`, mirroring how other
  budget/limit checks in this framework surface to the player.
- An `item_key` that doesn't resolve via `oblsk_items` at placement time
  skips that placement with a `print` warning, matching this framework's
  "don't let one bad row take down the flow" convention (see the entity
  streamer design's malformed-row handling).
- A player attempting `Edit` without build permission, or `Enter` without
  an owner row, is denied by `PolicyService`/an explicit ownership check
  before any teleport happens.

## Testing

Server-side specs (fake `QueryBuilder`, matching
`terminal_service_spec.lua`'s style):

- `InstanceService`: bucket determinism (`getOrCreateBucket` returns the
  same id for the same key across calls), new-key allocation, `enter`/
  `leave` state.
- `ShellService`: shell CRUD, `shell_owners` add/remove, object
  placement respecting `object_budget`, `locked` filtering on
  remove/move (an owner cannot remove a `locked = true` row).
- Lua syntax validation across all new files.

No client-side test file — natives (`SetEntityCoords`,
`SetPlayerRoutingBucket`, raycasting for placement) aren't unit-testable
outside FiveM, matching every other plugin in this repo. Manual
verification: create a shell, place both locked (staff) and unlocked
(owner) objects, confirm two different shells' buckets don't see each
other at the shared anchor, confirm an owner without build permission
only ever sees the Decorate tool and can't touch locked pieces, confirm
walk-toggle preview.

## Out of Scope

- Purchase/economy/listing flow (`src/housing.jsx`/`housing.jsx`'s
  browse-and-buy screens) — a future `oblsk_housing` plugin layered on
  top of `shell_owners`.
- CCTV, doorbell, keys-as-items, bills — all housing-layer concerns from
  the same design file, not shellbuilder's.
- Per-shell coordinate allocation in the overworld interior space — the
  shared underground anchor makes this unnecessary.
- A generic pooled/ephemeral instance mode on `InstanceService` (e.g. a
  private per-session bucket that expires) — YAGNI until a future
  consumer actually needs it; today's only consumer needs deterministic
  per-shell buckets.
