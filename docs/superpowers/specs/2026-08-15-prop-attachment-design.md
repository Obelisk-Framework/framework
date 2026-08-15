# Prop attachment system design

**Goal:** A generic core mechanism to attach a prop (object) to any entity —
vehicle, ped, player, or other object — at a named, DB-defined attach point,
synced to every client via native `AttachEntityToEntity` (FiveM/OneSync then
handles keeping the prop moving with its parent, e.g. a driving vehicle, with
no hand-rolled position sync). Built as its own plugin, `oblsk_propattach`,
since it's a reusable capability multiple future plugins will depend on — the
first consumer being the hunting plugin (animal carcasses attached to a
transport vehicle's trunk).

## Scope

- Attach-point *definitions* (which bone/offset/rotation a named point on a
  given model resolves to) persisted in the DB, authored via an in-game
  placement tool (raycast-to-nearest-bone + manual offset/rotation nudge).
- Live attachment *instances* (what's attached where right now) also
  persisted in the DB, so state survives a server restart.
- A small server API (`AttachmentService.attach/detach/getAttachments`) any
  other plugin calls — this plugin owns the mechanism, not attachment
  policy (slot limits, what happens on parent despawn, etc. are the
  caller's responsibility).

## Data model

`attach_points` table — one row per named point on a model:

```lua
table:id()
table:string('model', 100)          -- e.g. 'pounder', 'mp_m_freemode_01'
table:string('point_name', 60)      -- e.g. 'trunk_slot'
table:integer('slot_index')         -- default 0; distinguishes multiple
                                     -- slots sharing one point_name
table:integer('bone_index')
table:float('offset_x')
table:float('offset_y')
table:float('offset_z')
table:float('rot_x')
table:float('rot_y')
table:float('rot_z')
table:timestamps()

table:index({'model', 'point_name'})
```

Unique per `(model, point_name, slot_index)` — enforced at the service layer
(check-then-insert; matches this repo's existing convention of app-level
uniqueness checks rather than DB unique constraints elsewhere in the schema).

`attachments` table — one row per currently-live attachment:

```lua
table:id()
table:string('prop_model', 100)
table:enum('parent_entity_type', {'vehicle', 'ped', 'player', 'object'})
table:integer('parent_net_id')      -- FiveM network id, stable across
                                     -- ownership migration
table:string('point_name', 60)
table:integer('slot_index')
table:string('owner_type', 30):nullable()   -- polymorphic, e.g.
table:integer('owner_id'):nullable()        -- 'plugin:oblsk_hunting'
table:json('data'):nullable()       -- caller-defined payload (e.g. animal
                                     -- type/weight for the hunting plugin)
table:timestamps()

table:index({'parent_entity_type', 'parent_net_id'})
```

## Server API (`AttachmentService`)

- `AttachmentService.attach(parentEntityType, parentNetId, propModel, pointName, slotIndex, opts)`
  → looks up the `attach_points` row for `(model, point_name, slot_index)`
  (model resolved from the parent entity type + a model lookup the caller
  provides, since the server doesn't always have a live entity handle for
  a vehicle/ped by net id without a round trip — caller passes the model
  string directly), inserts an `attachments` row, broadcasts
  `core:server:attach-create` to all connected players with the full
  record (bone/offset/rotation resolved server-side, not re-looked-up
  per-client).
- `AttachmentService.detach(attachmentId)` → deletes the row, broadcasts
  `core:server:attach-remove`.
- `AttachmentService.getAttachments(parentEntityType, parentNetId)` → array
  of live attachment rows for a parent (e.g. hunting checks current trunk
  occupancy before allowing another load).
- On player connect: server pushes every current `attachments` row as an
  `attach-create` event, so a late joiner's client attaches everything
  already in the world. Attachment count is expected to stay small
  (dozens, not thousands) so this is a flat snapshot, not chunk-scoped
  like `EntityStreamerService`.

## Client

- `attach-create` handler: `CreateObject` for `prop_model` (always a fresh
  object in v1 — no "attach an existing streamed entity" path), then poll
  `NetworkGetEntityFromNetworkId(parent_net_id)` up to 5s (matches
  `EntityStreamerService.spawnObject`'s existing model-load timeout
  pattern) until the parent entity exists locally, then
  `AttachEntityToEntity(prop, parent, bone_index, offset..., rot..., ...)`.
  If the parent never resolves in time, the prop is deleted and a console
  warning logged (same "skip, don't crash" convention as a bad streamer
  row).
- `attach-remove` handler: `DetachEntity` then `DeleteEntity` on the prop.

## Placement tool

Admin-only, gated by a new `propattach_edit` permission key.

- `/attach-point-edit <model>` while aiming at a live entity matching
  `model`: client raycasts from the camera, finds the hit entity's nearest
  bone to the hit coordinate (sweep all bone indices via
  `GetPedBoneIndex`/the vehicle-bone equivalent, comparing world-space
  bone position to the hit point — vehicles and peds use different bone
  APIs, tool branches on `parent_entity_type`), then spawns a local
  (unnetworked, preview-only) prop attached at that bone with zero
  offset/rotation.
- Arrow keys nudge `offset_x/y`, `PageUp/PageDown` nudge `offset_z`, and a
  modifier held while pressing arrows nudges rotation instead — fixed step
  (0.01 units / 1°) rather than mouse-drag, keeping the tool a single
  client-side input-thread with no new UI screen.
- On-screen text (`DrawText` in the corner) shows the live offset/rotation
  numbers as they're nudged, plus the resolved bone name.
- `Enter` prompts (chat/console input, matching how other admin commands in
  this repo take follow-up input) for `point_name` and `slot_index`
  (default 0), then saves via a new server event that inserts/updates the
  `attach_points` row (update if the same `(model, point_name, slot_index)`
  already exists, insert otherwise). `Esc` cancels and deletes the preview
  prop without saving.

## Testing

- Server unit tests (busted, mirroring `oblsk_licenses`/`oblsk_garage`
  conventions): `attach` inserts a correctly-shaped row and returns an id;
  `detach` removes the row; `getAttachments` filters correctly by parent
  type + net id; point lookup resolves `(model, point_name, slot_index)`
  correctly and returns nil for an unknown combination; the placement
  tool's save command rejects a caller without `propattach_edit`.
- No client-side test file for the raycast/attach/nudge logic (natives,
  matches every other plugin's client code in this repo) — manual
  verification: attach a prop to a stationary ped, attach a prop to a
  vehicle and drive it to confirm the prop follows, place a new attach
  point with the tool and confirm a subsequent `attach()` call using it
  lands in the expected spot, confirm a late-joining player sees existing
  attachments.

## Out of scope

- Attachment *policy* — slot limits, capacity, what happens when a parent
  entity despawns/dies while something is attached — all left to the
  calling plugin (e.g. hunting decides whether a dead truck drops its
  attached animals).
- Reusing an already-streamed/existing prop entity as the attachment
  target instead of always creating a fresh one.
- Any UI beyond the placement tool's on-screen text readout — no NUI
  screen for browsing/editing existing attach points.
