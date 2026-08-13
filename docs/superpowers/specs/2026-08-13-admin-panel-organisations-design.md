# Admin Panel — Sub-project 1: Panel Shell + Organisations Tab

**Repositories:** new plugin `oblsk_admin` (Vue NUI shell, all future admin tabs live here), `modules/oblsk_organizations` (schema + service additions).

**Goal:** Port the "Staff Panel" from the `claude_design` admin mockup (`pages/admin.html` / `src/proto/admin.jsx` / `src/proto/admin-tools.jsx`) into the framework, as the first of several sub-projects. This slice ships the panel shell (header, 11-tab bar, open/close/access-gate) with only the **Organisations** tab functional; the other ten tabs (Players, Moderation, Vehicles, Interactions, Blips, Locations, Items, Economy, Server, Audit log) render as "Coming soon" placeholders and are each their own future sub-project.

Organisations was chosen to go first because Interactions' and Blips' access-policy pickers (a later sub-project) need real org/department/rank data to restrict against, rather than being built against fake mock data.

## Why this extends `oblsk_organizations` instead of creating a new org concept

`core/modules/oblsk_organizations` already models orgs, departments (`HasPermissions.apply(Department, 'department')`), ranks (`HasPermissions.apply(Rank, 'rank')`), and memberships, backed by `OrganizationService` (`create/rename/delete`, `addDepartment/removeDepartment`, `addRank/removeRank`, `join/leave/setRank`, `joinDepartment/leaveDepartment`). The mockup's org shape needs three fields this schema doesn't have yet (`short_code`, `colour`, `type`) plus a contact-numbers list. This design adds those additively rather than modeling organisations twice.

The mockup's short-code-based lookup (`AT_policyLabel`, `ORG_SEED[].short`) currently exists ad hoc in `oblsk_mdt`'s `MdtAuthService` (which maps org names to `'lspd'`/`'lsmd'`/`'doj'` itself). Once `short_code` is a real column here, that duplication can be cleaned up as a follow-on — not part of this slice, since `oblsk_mdt` isn't in scope.

## Schema changes (`modules/oblsk_organizations`)

One migration, additive only:

`organizations` — add columns:

| Column | Type | Notes |
|---|---|---|
| `short_code` | string(10), nullable | e.g. `'LSPD'`. Not unique at the DB level (matches mockup behavior of deriving a fallback from the name); `OrganizationService` enforces uniqueness at write time and surfaces a validation error if taken. |
| `colour` | string(7), nullable | hex, e.g. `'#3b82f6'` |
| `type` | string(20), default `'Government'` | `'Government'` \| `'Business'`, enforced in `OrganizationService.setDetails`, not a DB enum (consistent with how `kind`/`type` string columns are handled elsewhere in this codebase) |

New table `organization_contact_numbers`:

| Column | Type | Notes |
|---|---|---|
| `id` | pk | |
| `organization_id` | fk → `organizations.id`, cascade delete | |
| `number` | string(20) | e.g. `'911'`, `'555-0140'` |
| `label` | string(50) | e.g. `'Emergency'` |
| `enabled` | boolean, default true | |
| (timestamps) | | |

### `OrganizationService` additions

- `setDetails(orgId, { shortCode, colour, type })` — validates `type` is one of the two allowed values and `shortCode` (if provided and non-empty) isn't already used by a different org; updates the row.
- `addContactNumber(orgId, number, label)` / `removeContactNumber(contactId)` / `toggleContactNumber(contactId, enabled)`.
- `list()` — every org, with departments/ranks/contact numbers eager-loaded (the admin list view needs department/rank counts and the top enabled contact number per org, matching the mockup's org list row).

## `oblsk_admin` plugin

New sibling repo, symlinked in like `oblsk_phone`/`oblsk_licenses`. Follows the `oblsk_phone` NUI pattern (`web/globalElements.js` + `WebView.showGlobalElement`), **not** `make-plugin.js`'s Vue scaffold — that generator only stubs a bare component file and predates the real `core/web` glob-based architecture.

### Access control

Reuses the existing `IsPlayerAceAllowed(source, 'admin')` check, but via the inline-guard convention this codebase actually uses everywhere admin-gating happens today (`OrganizationCommands.lua`, `AccountCommands.lua`) — not `PolicyService`/`ActionService`'s `options.policies`, which nothing in the framework currently reads or enforces (`PolicyService.attach('action', ...)` has zero call sites; `ActionService.execute`'s policy check passes by default when no policy was ever attached). `IsAdminPolicy.lua` stays unused by this plugin; wiring `options.policies` up to something real is out of scope here.

```lua
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

ActionService.register('admin:toggle-panel', function(source, data)
    if not isAdmin(source) then return end
    Obelisk.emitClient(source, 'admin:client:toggle-panel')
end, { label = 'Toggle admin panel', default_key = Config.keybind })
```

Every `Obelisk.onServer('admin:organisations:...')` handler the panel registers calls the same `isAdmin(source)` guard itself — the client-side gate on opening the panel is a UX convenience, not the security boundary; a player who never sees the panel could still fire these server events by hand.

### Open/close flow

1. Player presses keybind (or runs a command, both resolve to the same `admin:toggle-panel` action per `KeybindService`'s existing resolver).
2. Server validates `isAdmin`, relays to the requesting client via `Obelisk.emitClient`.
3. Client: `WebView.showGlobalElement('admin')` + `WebView.focus()`.
4. Close: ESC (`WebView.closeAll`, already ESC-safe framework-wide) or an in-panel close button that emits `Obelisk.emit('admin:close')`, handled client-side by `WebView.hideGlobalElement('admin')` (no server round-trip needed to close).

### Web structure

- `web/globalElements.js` — exports `{ name: 'AdminPanel', component: AdminPanel, defaultVisible: false }`.
- `web/AdminPanel.vue` — shell: header (title, online count placeholder, noclip/god toggles as visual-only stubs for now — those are Players/Server tab territory), 11-tab bar matching the mockup's `TABS` list, tab-switch state. Ten tabs render a shared `ComingSoon.vue` placeholder; `organisations` renders `OrganisationsTab.vue`.
- `web/OrganisationsTab.vue` — 1:1 port of `AdminOrgs` from `src/proto/admin-tools.jsx`: org list (left, colour swatch + short-code + dept/rank counts + enabled contact numbers), detail panel (right: name, short code, colour picker with custom-colour input, type choice, departments add/remove list, ranks reorderable add/remove list, contact numbers add/remove/toggle list), "+ New" create-organisation flow.
- NUI bridge: `WebView.on` always acks the NUI callback with a bare `'ok'` (it cannot return data), so this follows the same three-hop push pattern every real plugin in this codebase uses (`oblsk_keybinds`, `oblsk_phone`), not a request/response round trip:
  1. Vue: `Obelisk.emit('admin:client:organisations-list' | '-create' | '-setDetails' | '-addDepartment' | '-removeDepartment' | '-addRank' | '-removeRank' | '-addContactNumber' | '-removeContactNumber' | '-toggleContactNumber', payload)`.
  2. Client `oblsk_admin/client/main.lua`: `WebView.on('admin:client:organisations-*', function(data) Obelisk.emitServer('admin:server:organisations-*', data) end)` — thin relay only.
  3. Server `oblsk_admin/server/main.lua`: `Obelisk.onServer('admin:server:organisations-*', function(...) local source = source; if not isAdmin(source) then return end; <call OrganizationService method>; Obelisk.emitClient('admin:client:organisations-reply', source, result) end)`.
  4. Client: `Obelisk.onClient('admin:client:organisations-reply', function(result) SendNUIMessage({ eventname = 'admin:client:organisations-reply', args = { result } }) end)`.
  5. Vue: `Obelisk.on('admin:client:organisations-reply', handler)` registered in `onMounted`, updates local state.

### Config

`oblsk_admin/shared/config.lua` (declared via `shared_scripts` in `fxmanifest.lua`, matching every other plugin's config location): `Config.keybind` (default key for `admin:toggle-panel`, read by `KeybindService` off the action's `options.default_key`).

## Out of scope for this slice

- The `org-rank` `PolicyService` validator (restrict an interaction/blip to org+dept+rank) — registered as part of the Interactions sub-project, which is where it's actually consumed. Nothing here needs it.
- The other ten tabs' functionality (they're placeholders only).
- Cleaning up `oblsk_mdt`'s ad-hoc short-code mapping to use the new `short_code` column — separate, optional follow-on.

## Testing

- Busted specs for `OrganizationService.setDetails/addContactNumber/removeContactNumber/toggleContactNumber/list` (`modules/oblsk_organizations/tests/`), covering the type-validation and short-code-uniqueness error paths.
- Migration test (up/down, column defaults).
- `oblsk_admin` server spec: `admin:toggle-panel` action registration carries the `isAdmin` policy; a `WebView.on('admin:organisations:...')` handler rejects a non-admin `source` (mirroring the existing `isAdmin(source)` guard pattern used in `OrganizationCommands.lua`/`AccountCommands.lua`).
- No client-side (Vue) automated tests exist elsewhere in this codebase for NUI components; manual in-game verification of the panel shell + Organisations CRUD substitutes, per repo convention.
