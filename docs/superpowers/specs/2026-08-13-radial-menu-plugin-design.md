# Radial Menu Plugin Design

Date: 2026-08-13

## Summary

Port the radial interaction wheel from the Obelisk Claude Design prototype (`src/proto/radial.jsx`) into a new `oblsk_radialmenu` plugin. It is a global component, wired the same way as `oblsk_phone`/`oblsk_hud` (`web/globalElements.js`, hidden by default, toggled via `WebView`). Unlike the prototype's single hardcoded tree, this plugin supports multiple named, database-backed menus so any plugin can register its own wheel and any code can open a specific one by key — following the same open/action/close plumbing already used by `NativeMenu.vue`.

## Goals

- Global radial menu component, toggle-shown/hidden like phone/HUD.
- Multiple independent menus, each identified by a `menu_key`, each an arbitrary-depth tree of wedges.
- Menu trees stored in the database; plugins populate them via idempotent seeders (same convention as item bindings / permissions). Admin-panel CRUD authoring is a known future addition — not built here, but the schema must not need to change to support it later.
- A default keybind (`G`) opens a `'default'` menu. Any other plugin can open any menu by key via the same client event, independent of the keybind.
- Selecting a leaf wedge executes an existing `ActionService` action (the entry stores an `action_id`), so permission/policy gating is inherited for free.
- UX ported verbatim from the prototype: pointer-angle hover tracking per ring, click-to-drill into submenus, centre hub = back (or close at root), breadcrumb trail of the current path, footer key hints, icon/label toggle.

## Non-goals

- No admin UI/command for authoring menus (future work; schema supports it).
- No context-sensitive auto-selection of which menu to open (e.g. "near a vehicle → vehicle wheel") — that logic belongs to whichever plugin decides to call open with a given `menu_key`.
- No persistence of the icon/label toggle preference — it's local UI state, reset each session.
- No real leaf actions are wired up as part of this plugin — it ships with a `'default'` seed menu whose entries point at whatever actions already exist (or stub actions), matching the current in-progress state of the framework's other systems (vehicle/inventory/emotes).

## Data model

New plugin migration, two tables:

```
radial_menus
  menu_key      text primary key
  label         text not null

radial_menu_entries
  id                  integer primary key autoincrement
  menu_key            text not null references radial_menus(menu_key)
  entry_key           text not null            -- unique per menu, stable across seeder runs
  parent_entry_key    text null                -- self-referencing within the same menu; null = root-level wedge
  label               text not null
  icon                text not null
  action_id           text null                -- set only on leaves; references ActionService action id
  sort_order          integer not null default 0
  unique (menu_key, entry_key)
```

A row is a branch (submenu) if any other row in the same `menu_key` has `parent_entry_key` equal to its `entry_key`; otherwise it's a leaf and must have `action_id` set. `RadialMenuService.getTree(menuKey)` assembles the flat rows into the nested shape the Vue component expects, ordered by `sort_order`.

## Server: `RadialMenuService`

Lives at `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua`.

- `RadialMenuService.registerMenu(menuKey, label)` — upsert into `radial_menus`. Idempotent, called from seeders.
- `RadialMenuService.addEntry(menuKey, { entryKey, parentEntryKey, label, icon, actionId, sortOrder })` — upsert into `radial_menu_entries` keyed on `(menu_key, entry_key)`. Idempotent, called from seeders.
- `RadialMenuService.getTree(menuKey)` — returns `{ menuKey, label, items: [...] }` with `items` nested per `parent_entry_key`, each item `{ entryKey, label, icon, actionId, items? }`.
- `RadialMenuService.open(source, menuKey)` — loads the tree via `getTree`, errors (server-side log, no-op client-side) if the menu doesn't exist, then `Obelisk.emitClient(source, 'radialmenu:client:open', { menuKey, tree })`.

Bootstrap seeds a `'default'` menu (`RadialMenuService.registerMenu('default', 'Actions')`) with a small set of entries ported from the prototype's tree (Vehicle/Emotes/Inventory/Comms/Self/Job top level), whose leaf `action_id`s point at existing `ActionService` actions where they exist already, and otherwise at placeholder actions registered by this plugin for now.

### Keybind / open wiring

- `ActionService.register('radialmenu:open-default', function(source) RadialMenuService.open(source, 'default') end, { label = 'Open interaction wheel', default_key = 'G' })` — same pattern as `oblsk_phone`'s `phone:toggle-dock`.
- Any other plugin opens a specific menu the same way any code opens the phone: call `RadialMenuService.open(source, menuKey)` directly (it's a plugin-exported service function), no new event needed for that path.

### Selection dispatch

- Client → server event `radialmenu:server:selected` with `{ menuKey, entryKey }`.
- Handler looks up the entry's `action_id` via `RadialMenuService`, then `ActionService.execute(actionId, source)` — inherits the existing policy/permission gating, consistent with the keybind decision made in `2026-08-13-keybind-layering-design.md`.

## Client Lua

`core/plugins/oblsk_radialmenu/client/main.lua` is a thin relay, same shape as `oblsk_phone`'s client:

- `Obelisk.onClient('radialmenu:client:open', function(data) WebView.showGlobalElement('radialmenu'); WebView.pushGlobalElementData('radialmenu', data) end)` — pushes `{menuKey, tree}` to the Vue component. (If `WebView` has no existing "push data to an already-shown global element" primitive, add one following the same naming as `showGlobalElement`/`hideGlobalElement`.)
- NUI → client: `Obelisk.on('radialmenu:client:selected', function(data) Obelisk.emitServer('radialmenu:server:selected', data) end)`.
- NUI → client: `Obelisk.on('radialmenu:client:closed', function() WebView.hideGlobalElement('radialmenu') end)` — fired once the Vue component fully closes (root-level ESC/centre-click), not on each submenu back-step, which stays client-side UI state.

## Vue component

`core/plugins/oblsk_radialmenu/web/RadialMenu.vue`, registered via `web/globalElements.js` as `{ name: 'radialmenu', component: RadialMenu, defaultVisible: false }`.

Ported 1:1 from `src/proto/radial.jsx`:
- Receives `{menuKey, tree}` pushed from Lua on open; local `path` (array of indices/keys) tracks drill-down, entirely client-side — no server round-trip per submenu level since the full tree arrives up front.
- SVG wedge ring (`wedgePath` geometry helper ported as-is), pointer-move handler computes hovered wedge from cursor angle relative to centre.
- Click a branch wedge → push onto `path`. Click a leaf wedge → emit `radialmenu:client:selected` with `{menuKey, entryKey}` via `Obelisk.emit`, then emit `radialmenu:client:closed` and hide locally.
- Centre hub click / ESC: pop `path` if non-empty, else emit `radialmenu:client:closed` and hide.
- Breadcrumb trail rendered from `path`, footer hint row (`MOVE`/`CLICK`/`CENTRE`/`ESC`), icon/label toggle as local `ref`, not persisted.
- Icons: prototype's icon name strings (`car`, `key`, `lock`, `bag`, `user`, `zap`, `alert`, `chevL`, `chevR`, `users`, `refresh`, `pill`, `close`, `download`, `contact`, `radio`, `music`, `phone`, `heart`, `badge`, `search`, `file`) are re-mapped during implementation onto whichever icon set core/`oblsk_phone` already uses — exact mapping resolved when the implementation plan is written, not a design-level decision.

## Testing

- `core/plugins/oblsk_radialmenu/tests/RadialMenuService_spec.lua` using the framework's hand-rolled `lua5.4 ..._spec.lua` runner (`dofile`, `test()`/`eq()`/`truthy()`), covering:
  - `registerMenu`/`addEntry` idempotency (seeding twice produces one row, not duplicates).
  - `getTree` correctly nests multi-level entries and orders by `sort_order`.
  - `open` on a nonexistent `menu_key` fails gracefully server-side without emitting to the client.
  - Selection dispatch resolves `entry_key` → `action_id` → `ActionService.execute` call with the right arguments.
- Vue interaction (hover tracking, drill-down, breadcrumb, close) verified manually in-game, per this framework's existing convention — no headless GTA-native/DOM test harness.
