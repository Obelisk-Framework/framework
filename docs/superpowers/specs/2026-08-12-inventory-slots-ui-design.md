# Inventory (slot-based) plugin design

Source design: Claude Design project "FiveM" (`pages/inventory-slots.html`,
`src/proto/inventory-v1.jsx`, `src/proto/slot.jsx`) — a semi-transparent
near-fullscreen overlay: 45-slot main grid + 5-slot hotbar on the left,
a character panel with worn clothing in the middle, and up to two open
containers (ground + one carried bag/box) stacked on the right. Right-click
context menu (use/equip/split/drop/give), drag-drop with merge/swap/split.

This replaces the current `oblsk_inventory` plugin scaffold (`Inventory.vue`,
`InventorySlot.vue`), which is a demo-only port with fake local arrays, no
server wiring, and its own half-built `Inventory` model that duplicates
concepts `oblsk_items` already owns.

## Scope

Full plugin: schema additions on the existing `items` table, server sync,
Vue UI wired to real data. Not a demo-only visual port.

**Cut for v1** (flagged, not built):
- Injury overlay on the body model — cosmetic only in the prototype, no
  medical-system hook exists yet. Body panel renders clothing slots only.
- "Give to nearby player" — needs real player-proximity data this plugin
  doesn't have. The context-menu action stays but is stubbed server-side
  (returns "not implemented" toast) until a proximity source exists.
- Ground drops are a single global bucket (`owner_type='ground', owner_id=0`),
  not position-filtered. Real world-position ground drops need the entity
  streamer service (see `2026-08-12-entity-streamer-design.md`) — noted as
  follow-up, not blocking this plugin.

## Data model

No new table. `oblsk_items` already models ownership polymorphically
(`items.owner_type` + `owner_id`), which covers nested containers for free:
a backpack's contents are just `Item` rows with `owner_type='item'` and
`owner_id=<the backpack Item's id>`. This plugin only needs to add
placement columns to `items`, following the same FK-less cross-repo pattern
used by `oblsk_garage`'s `vehicles.garage_id` (module table stays generic,
plugin owns the meaning of the columns it adds):

- `container` (string, nullable, default `'main'`) — which sub-region of the
  owner this item sits in: `main` | `hotbar` | `cloth`. Needed because a
  single `owner_type='character'` owns all three regions.
- `slot` (integer, nullable) — grid index within `container` (main/hotbar/
  any opened container's grid). Null for `container='cloth'`.
- `cloth_slot` (string, nullable) — equip slot key (`shirt`/`jacket`/`vest`/
  `shoes`/`bag`) when `container='cloth'`.

Delete `oblsk_inventory/server/models/Inventory.lua` — superseded by using
`Item`/`BaseItem` directly.

Stacking reuses `Item.isStackableWith` (already exists, unchanged) and
`max_stack_amount` from `BaseItem`.

## Backend flow

**Sync (on open):** client calls `inventory:open` → server loads the
character's `items` rows (`owner_type='character', owner_id=charId`, all
three containers) plus any items in currently-open containers, plus the
ground bucket, joins each to its `BaseItem`, and pushes one `inventory:sync`
payload: `{ main: [...], hotbar: [...], cloth: {...}, openContainers: {key:
[...]} }`. Container items are loaded lazily — only when a container is
opened (`inventory:openContainer` → server queries `owner_type='item',
owner_id=<container item id>` and pushes `inventory:containerSync`).

**Mutations** — one event per action, mirroring the prototype's action set,
each validated server-side before the DB write (never trust client-side
placement):
- `inventory:move` — `{ itemId, toContainer, toSlot, toClothSlot? }`. Server
  re-checks stack/collision rules (same rules the client used for its
  optimistic preview) and either commits or replies with a correction.
- `inventory:split` — `{ itemId, amount, toSlot }`
- `inventory:use`, `inventory:equip`, `inventory:drop`, `inventory:give` —
  as in the prototype; `give` replies with a "not implemented" toast (see
  Scope).
- `inventory:openContainer` / `inventory:closeContainer`

Client applies moves optimistically (matches prototype feel — drag/drop
must not wait on a round trip) and reconciles on the next `inventory:sync`
if the server rejects a move.

## Frontend

New/rewritten files in `oblsk_inventory/web/`, following `oblsk_garage`'s
pattern (single Obelisk.on/emit bridge, plain `ref`s, no state library,
scoped Tailwind classes, no external DnD lib — pointer-based drag like the
prototype's `useDnd`, not native HTML5 DnD):

- `Inventory.vue` — root: layout (nearby-players rail cut, since "give" is
  stubbed; grid+hotbar panel, character panel, up to 2 open-container
  panels), weight bar, toast, keeps `openConts` (max 2) exactly like the
  prototype.
- `InventorySlot.vue` — rewritten: fixed slot size, item glyph/image, qty
  badge, fill/durability bar, drag start/drop, context-menu emit. Drops the
  current placeholder's imgur image URLs — icon comes from `BaseItem.icon`.
- `PlayerBody.vue` — new: silhouette + 5 clothing drop targets (shirt,
  jacket, vest, shoes, bag), no injury rendering (cut).
- `ContextMenu.vue`, `SplitDialog.vue` — small, split out of `Inventory.vue`
  rather than inlined, since both are reused (split dialog also needed for
  container-to-container splits).
- `dnd.js` — composable: pointer capture, ghost element, `data-drop` target
  resolution, matches prototype's `useDnd`/`DndProvider` behavior.

Item art: `BaseItem.icon` is a stored string today (existing column) — this
plugin doesn't change how icons resolve, just renders whatever `icon` holds
via the same convention other plugins already use for item icons (checked:
none exist yet, so this plugin establishes it — plain `<img :src>` for now,
consistent with the prototype's `ItemGlyph`).

## Testing

- ORM: `Item.isStackableWith` already covered; add coverage for the new
  `container`/`slot`/`cloth_slot` columns via a slot-assignment spec (place,
  move, collide, merge, split) at the service layer — mirrors how
  `oblsk_garage`'s service tests were structured.
- No frontend test harness exists in this project (Vue components are
  hand-verified in the FXServer dev client, same as every other plugin) —
  verification is manual: open inventory, drag between all regions, split,
  equip, open/close containers, confirm `inventory:sync` reconciliation
  after a rejected move.
