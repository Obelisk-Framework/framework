# Shell Builder Follow-up: object rendering, raycast placement, ownership grant

**Goal:** Close the two gaps parked at the end of the original shell builder
plan (`2026-08-15-shell-builder-plugin-design.md`): shells have no in-game
object rendering and no way to place/remove objects at all (the plan's
`ShellObjectService`/net events were wired end-to-end but nothing triggers
them from the 3D world), and no way to grant shell ownership beyond the
creator. This spec covers three pieces: bucket-aware object streaming,
raycast-driven placement/removal, and a minimal ownership-grant UI.

**Builds on:** `oblsk_shellbuilder` (all 8 original tasks, merged), core
`InstanceService`, core `EntityStreamerService` (currently dead — the
entity-streamer design spec extended it with budget/tiering, but nothing in
the framework has ever called `EntityStreamerService.register`; this is its
first real consumer).

## 1. Object rendering: bucket-aware `EntityStreamerService`

### Why chunk streaming alone doesn't work here

Every shell's interior sits at one shared anchor coordinate
(`ShellBuilderConfig.Anchor`). Chunk-based streaming partitions purely by
`(x, y)` proximity — every shell's objects would land in the same one or two
chunks near the anchor, so a player near the anchor would see every shell's
furniture at once, regardless of which shell's routing bucket they're
actually in. Distance-based partitioning has to be layered under a
bucket filter, not instead of one.

### Data model: reuse `entities`, no new table

`entities` already has a polymorphic owner (`owner_type`, `owner_id`) and a
`data` json column (see the entity-streamer design). `ShellObjectService`
mirrors each `shell_objects` row into a matching `entities` row:

- `entity_type = 'object'`
- `model` = the placeable's bound item's `data.shell_model`
- `x, y, z, heading` = the same coordinates already stored on `shell_objects`
- `networked = false` — shell furniture is static and non-interactive;
  every client in the shell's bucket spawns it independently, no
  cross-client ownership handoff needed (this is exactly the "local-only"
  case the entity-streamer design already describes)
- `enabled = true`
- `owner_type = 'shellbuilder_shell_object'`, `owner_id` = the
  `shell_objects.id` this entity represents — chosen over `owner_id =
  shellId` specifically so a raycast-hit entity resolves directly back to
  the `shell_objects` row `ShellObjectService.remove` needs, with no join.
- `data = { shellId = <shells.id> }` — the shell id lives here (not in
  `owner_id`) since bucket resolution needs the *shell*, not the object.

`ShellObjectService.place` inserts both rows (in the same call, same
transaction posture as everything else in this codebase — sequential
inserts, no explicit transaction wrapper, matching existing convention).
`ShellObjectService.remove` deletes both.

### `InstanceService.getCurrentBucket(source)`

New function: returns the bucket id a player is currently in (via the
existing `playerBucketKey`/bucket-membership tracking `enter`/`leave`
already maintain), or `0` if they're in no tracked bucket (the default
overworld bucket).

### Streamer filter: one new rule, layered under the existing chunk logic

`EntityStreamerService.updatePlayerChunks` (server), for each candidate
entity, resolves an *effective bucket*:

- `owner_type == 'shellbuilder_shell_object'`: effective bucket =
  `InstanceService.getOrCreateBucket('shellbuilder:shell:' ..
  entity.data.shellId)`
- anything else (every entity type that existed before this spec):
  effective bucket = `0`

An entity is only a candidate for a player at all if its effective bucket
equals `InstanceService.getCurrentBucket(source)`. This is a pure filter
applied before the existing chunk/tier logic runs — every non-shell entity
behaves exactly as the entity-streamer design already specifies, unchanged.

**Shell-bucket players bypass tier/budget degradation entirely.** When
`InstanceService.getCurrentBucket(source) ~= 0`, skip the chunk/tier
computation altogether and load every `entities` row for that shell in one
query (`data.shellId` match) — no distance culling, no budget check against
`EntityStreamerService.globalSpawnedCount`. Justification: shell buckets
already have population/traffic disabled, `object_budget` (≤900, enforced
at placement time by `ShellObjectService.place`) already bounds the count
far below the global budget, and a shell's whole footprint is a handful of
meters across — chunk-radius culling provides no value inside one.

### Client: no changes expected

The client `EntityStreamerService` spawns whatever entity payload the
server sends via the existing load/unload diff protocol — it has no
chunk/bucket logic of its own to change. Confirm this during implementation
by reading the file; if the client does anything bucket-unaware that
breaks (e.g. assumes a single global "current chunk" independent of
bucket), fix it minimally to match.

## 2. Raycast placement / removal (client)

`ShellEditor.vue`'s `place`/`removeObject` functions (currently
`defineExpose`d but never called from anywhere real) are replaced as the
trigger mechanism — placement/removal now originates from client-side
world interaction, not a Vue method call. The Vue component keeps its
existing job: rendering the dock, letting the player select a tool/item/
lock-toggle, and reflecting `objects`/`objectPlaced`/`objectRemoved`
state. It communicates the *armed* selection to client Lua via two new NUI
messages (`WebView.on`):

- `shellbuilder:arm` — `{ itemKey, locked }`, sent whenever the selected
  item, or the lock toggle, changes while a tool other than none is
  selected.
- `shellbuilder:disarm` — sent when the player switches away from an item
  selection (e.g. changes tool, opens the save/exit sheet).

New client file `plugins/oblsk_shellbuilder/client/placement.lua`:

- **State:** `armedItemKey`, `armedLocked`, `aiming` (bool), `wreckMode`
  (bool, mirrors the dock's existing wreck toggle via a new
  `shellbuilder:wreck` NUI message `{ enabled }`), `heading` (float, reset
  to the camera's current heading each time aim mode starts).
- **Entering aim mode:** bound to a key (`Enter`/`INPUT_CONTEXT` or similar
  — pick whatever's free per this repo's `KeybindService` conventions;
  check for a collision before hardcoding a control). Only works while
  `armedItemKey` is set (placement) or `wreckMode` is true (removal) AND
  the editor page is the active NUI page. Calls `WebView.hideCursor()`
  (keeps `WebView.state.focus = true` so the ESC watcher and other NUI
  plumbing keep working, only the cursor releases) and sets `aiming =
  true`.
- **Per-frame while aiming:** `Q`/`E` adjust `heading` by a fixed step
  (e.g. 5°) for the pending placement. No ghost/preview prop — out of
  scope for this pass (noted as a follow-up polish item, not attempted).
- **Confirm (left click):**
  - **Placement:** `StartShapeTestRay` from `GetGameplayCamCoord()` along
    the camera's forward vector (derived from `GetGameplayCamRot()`) out to
    a fixed max distance (e.g. 15 units — shells are small); on a hit, use
    the hit coordinates; on no hit, use the point at max distance along the
    ray. Call `Obelisk.emitServer('shellbuilder:client:place', shellId,
    armedItemKey, x, y, z, heading, floorLevel, colorData, armedLocked)` —
    the exact same server event `oblsk_shellbuilder`'s Task 5 already
    handles; no server-side change needed for the placement path itself.
    `floorLevel` defaults to the dock's current floor-level state (already
    tracked client-side per the original editor's floor up/down buttons —
    confirm this value is available to relay, or default to `0` if the
    original plan never wired floor level through to a readable client
    state; note whichever is true in the implementation report).
  - **Removal (wreck mode):** raycast the same way, but resolve the hit
    *entity* (`GetEntityFromShapeTestHit`-equivalent — check FiveM's actual
    ray-test-hit-entity native name during implementation) back to its
    `entities.id` via a handle→id map the client `EntityStreamerService`
    already needs to maintain for despawn bookkeeping (confirm this map
    exists and is accessible; if it's local to that file, expose a small
    accessor rather than duplicating the tracking). From the resolved
    `entities` row, read `owner_id` (== `shell_objects.id`) and call
    `Obelisk.emitServer('shellbuilder:client:removeObject', shellId,
    ownerId)` — again, the existing Task 5 event, unchanged.
- **Cancel (right click or ESC):** `WebView.showCursor()`, `aiming =
  false`. Stays armed (same item still selected) so the player can
  re-aim without reselecting from the dock.

No changes to `ShellObjectService`, `ShellService`, or the
`shellbuilder:client:place`/`removeObject` server handlers — this section
is purely "give the already-built pipeline a real trigger."

## 3. Ownership grant (minimal, staff-only)

Per direction: this is intentionally minimal — a future dedicated
property-agent plugin will own the fuller housing/ownership flow later.
This section only needs to unblock "staff can hand a finished shell to a
player" for now.

### `ShellService.searchCharactersByName(query)`

New function in `plugins/oblsk_shellbuilder/server/services/ShellService.lua`
(scoped to this plugin, not touching `oblsk_characters`'s own
`CharacterService` — this plugin doesn't own that module). Queries the
`characters` table directly (`QueryBuilder.new('characters')`) for rows
where `first_name` or `last_name` contains `query` (case-insensitive
substring match). Since the fake `QueryBuilder` used in tests has no `LIKE`
support, implement the match in Lua after a `getSync()` (fetch all
non-deleted characters, filter with `string.find(name:lower(),
query:lower(), 1, true)`) rather than relying on SQL `LIKE` — keeps this
headless-testable against the existing fake, matching every other service
in this plugin. Returns `{ id, first_name, last_name }` rows, capped at a
small result limit (e.g. 20) to keep the UI usable.

### Server wiring

New `Obelisk.onServer('shellbuilder:client:searchCharacters', ...)` and
`'shellbuilder:client:addOwner'`/`'shellbuilder:client:removeOwner'`
handlers in `server/main.lua`, all gated behind the same
`PolicyService.checkSync(source, 'action', 'shellbuilder:edit')` build-
permission check every other staff-only action in this plugin already
uses. `addOwner`/`removeOwner` call the existing (already-implemented,
previously uncalled) `ShellService.addOwner`/`removeOwner`, then re-sync
the shell's owner list back to the requesting client.

### UI: management section in `ShellBrowser.vue`'s detail pane

Visible only when `permissions.canBuild` is true and a shell is selected.
A collapsible "Manage owners" block: current owner list (character
names — requires the sync payload to include resolved names, not just
ids; extend the `shellbuilder:sync`/shell list payload or add a small
per-shell owners-with-names fetch on selection, whichever is simpler to
wire given the existing `visibleShellsFor` shape — implementer's call,
note the choice in the report), a search input wired to
`searchCharacters`, and Add/Remove buttons per result/owner row. Kept to
this one panel — no separate screen, no bulk operations, no invite/
notification flow (all explicitly future property-agent-plugin scope).

## Testing

- `InstanceService.getCurrentBucket`: new unit tests (source with an active
  `enter`, source with none, source after `leave`).
- `EntityStreamerService`'s bucket filter: this service currently has no
  test file (per the entity-streamer design, it was never wired up, so no
  tests exist yet). Adding full coverage of the pre-existing chunk/tier
  logic is out of scope here — add targeted tests only for the new bucket
  filter behavior (an entity tagged to shell A's bucket is a candidate for
  a player in shell A's bucket, not for a player in shell B's bucket or in
  the overworld; a non-shell entity is a candidate for an overworld player,
  not for a player inside any shell).
- `ShellObjectService.place`/`remove`: extend existing tests to assert the
  mirrored `entities` row is created/deleted alongside the `shell_objects`
  row, with the correct `owner_type`/`owner_id`/`data.shellId`.
- `ShellService.searchCharactersByName`: new unit tests (substring match,
  case-insensitivity, empty query, no matches, result cap).
- No tests for the raycast/aim-mode client code — natives aren't
  unit-testable outside FiveM, matching every other client-side file in
  this codebase. Manual verification only.

## Out of Scope

- Ghost/ preview prop while aiming (polish, not attempted).
- Full property-agent/real-estate ownership flow (explicitly deferred to a
  future dedicated plugin per direction).
- Any change to `EntityStreamerService`'s existing chunk/tier/hysteresis
  logic beyond the bucket filter layered under it.
- Networked (cross-client-authoritative) shell objects — furniture stays
  local-only-spawn per client, matching the entity-streamer design's own
  distinction between local and networked entities.
