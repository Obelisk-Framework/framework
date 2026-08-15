# Admin Panel — Sub-projects 2-5: Players, Moderation, Vehicles, Items tabs

**Repositories:** `oblsk_admin` (new tabs, handlers), `modules/oblsk_accounts` (moderation additions), `modules/oblsk_vehicles` (no schema change, admin ops only), `modules/oblsk_items` (no schema change, admin ops only).

**Goal:** Wire up four of the remaining "Coming soon" tabs from the Admin Panel shell (`2026-08-13-admin-panel-organisations-design.md`), following the same panel-shell conventions Organisations established. Combined into one spec since all four share the identical wiring pattern and were scoped together.

## Shared conventions (apply to all four tabs)

- **Access control**: every new `Obelisk.onServer('admin:server:*')` handler starts with the same inline guard already used by `organisations.lua`:
  ```lua
  local function isAdmin(source)
      return source == 0 or IsPlayerAceAllowed(source, 'admin')
  end
  ```
  Each tab's handler file (`server/players.lua`, `server/moderation.lua`, `server/vehicles.lua`, `server/items.lua`) declares its own local copy, matching `organisations.lua` — no shared-guard module exists in this plugin yet and introducing one is out of scope here.
- **NUI bridge**: same three-hop push pattern as Organisations (Vue `Obelisk.emit('admin:client:<tab>-<verb>', payload)` → `client/main.lua` thin relay → server handler → `Obelisk.emitClient('admin:client:<tab>-reply', source, result)` → Vue `Obelisk.on` in `onMounted`). `client/main.lua` needs one relay line per new event name, following its existing `organisations-*` block.
- **List-refresh style**: mutations reply with the full refreshed list for that tab (same reasoning as Organisations — data sets here are small: online players, open ban/warning rows, garage-scale vehicle counts, base item catalog).
- **New Vue files**: `web/PlayersTab.vue`, `web/ModerationTab.vue`, `web/VehiclesTab.vue`, `web/ItemsTab.vue`, each replacing its `ComingSoon` fallback in `AdminPanel.vue`'s tab switch (`v-if="activeTab === 'players'"` etc., same pattern as the existing `OrganisationsTab` line).
- **Dev fixtures**: each new tab component gets an `import.meta.env.DEV` fixture branch for its list state, matching `OrganisationsTab.vue`'s existing dev-mode seed — there's no game client answering `Obelisk.emit` in `vite dev`.

## Players tab

No new table — reads live server state, not the database.

- **List**: `Obelisk.onServer('admin:server:players-list')` iterates `GetPlayers()`, for each source resolves account/character via `CharacterService.sessionCharacters[source]` → `Character:findSync`, plus `GetPlayerPing(source)` and `GetEntityCoords(GetPlayerPed(source))`. Returns `{ source, name, characterName, ping, coords }[]`.
- **Actions** (each a new `Obelisk.onServer('admin:server:players-<verb>')` handler, all admin-gated, none persisted):
  - `teleport-to-player` — `SetEntityCoords(GetPlayerPed(adminSource), targetCoords)`.
  - `bring-player` — teleports target ped to admin's current coords.
  - `kick` — `DropPlayer(targetSource, reason)`; also inserts a `moderation_logs` row (type `kick`) via the Moderation service below, so a kick from the Players tab shows up in the Moderation tab's history without a second lookup.
  - `spectate` — toggle only; out of scope to implement full spectate camera logic (needs client-side `NetworkSetInSpectatorMode`, non-trivial ped/collision handling) — this action stub emits a "not yet implemented" notification client-side. Flagged explicitly rather than silently half-built.
- No schema changes.

## Moderation tab

Reuses the existing `bans` table and `AccountService.ban/unban/checkBan` (`modules/oblsk_accounts`) as-is — bans already persist with reason/issued_by/expires_at/revoked_at, and `checkBan` is already enforced at connect. Only bans; warnings and kicks have nowhere to live today, so this adds one table for those two.

### Schema (`modules/oblsk_accounts`, additive migration)

New table `moderation_logs`:

| Column | Type | Notes |
|---|---|---|
| `id` | pk | |
| `account_id` | fk → `accounts.id`, cascade delete | |
| `type` | string(10) | `'warn'` \| `'kick'`, enforced at the service layer (not a DB enum, same convention as `organizations.type`) |
| `reason` | text | |
| `issued_by` | string(255) | matches `bans.issued_by`'s convention (identifier string, not a FK) |
| (timestamps) | | |

### `AccountService` additions

- `listBans()` — all bans, not-revoked first, newest first; joins `accounts` for a display name where `account_id` is set (falls back to showing the raw identifier for identifier-only bans).
- `listModerationLogs()` — all `moderation_logs` rows, newest first, joined to `accounts` the same way.
- `warn(accountId, reason, issuedBy)` — inserts a `moderation_logs` row with `type = 'warn'`.
- `logKick(accountId, reason, issuedBy)` — inserts a `moderation_logs` row with `type = 'kick'`; called both by the Moderation tab's own kick action and by the Players tab's kick action (§ above), so kicks always land in one history regardless of entry point.

### Moderation tab handlers (`oblsk_admin/server/moderation.lua`)

- `list` → `{ bans = AccountService.listBans(), logs = AccountService.listModerationLogs() }`.
- `ban` — payload `{ accountId, reason, durationHours|null }`; computes `expiresAt` from `durationHours` (null = permanent) and calls `AccountService.ban({ accountId }, reason, adminIdentifier, expiresAt)`. If the target is currently online, also `DropPlayer` them with the ban reason (a ban that doesn't kick the still-connected player is a broken ban).
- `unban` — `AccountService.unban(banId)`.
- `warn` — `AccountService.warn(accountId, reason, adminIdentifier)`; if online, notify the target client via `NotificationService`.
- `kick` — `AccountService.logKick(...)` + `DropPlayer` (same underlying action as the Players tab's kick, exposed here too since Moderation is where staff go specifically to moderate).

`adminIdentifier` = the acting admin's license identifier, resolved the same way `OrganizationCommands.lua`/`AccountCommands.lua` already do it for `issued_by`-style fields (existing helper, no new code needed beyond calling it).

## Vehicles tab

No schema change — reads/mutates the existing `vehicles` + `base_vehicles` tables (`modules/oblsk_vehicles`).

### `VehicleService` additions

- `listAll()` — all `vehicles` rows joined to `base_vehicles` for `model`/`name`; returns `{ id, plate, display_name, model, owner_type, owner_id, stored, garage_id, fuel_level, netId|nil }[]`. `netId` is populated only for currently-spawned vehicles (cross-referenced against the module's existing runtime spawn-tracking used by `findVehicleIdByNetId`, inverted).
- `deleteById(vehicleId)` — despawns if currently spawned (`DeleteEntity` on its network entity), then deletes the `vehicles` row.
- `teleportToCoords(vehicleId, coords)` — only valid for a currently-spawned vehicle; no-ops (with a reason returned) if not spawned, since spawning a vehicle from the admin panel just to move it is Garage-tab territory, not this slice.

### Vehicles tab handlers (`oblsk_admin/server/vehicles.lua`)

- `list` → `VehicleService.listAll()`.
- `delete` → `VehicleService.deleteById(vehicleId)`, replies with refreshed list.
- `teleport-to-admin` → `VehicleService.teleportToCoords(vehicleId, adminCoords)`, replies with a not-spawned notice if applicable.

## Items tab

No schema change — reads/mutates the existing `base_items` table (`modules/oblsk_items`).

### `ItemService` additions

- `listBaseItems()` — all `base_items` rows (id, name, description, icon, weight, all the `is_*` flags, max_stack_amount).
- `updateBaseItem(baseItemId, attributes)` — whitelist-updates the editable fields (`description`, `icon`, `weight`, the `is_*` flags, `max_stack_amount`); `name` is excluded from edits since it's the lookup key `ItemService.binding()` and plugin configs reference by string — renaming here would silently break every `Config.Requires`/binding reference elsewhere, out of scope to reconcile.
- `createBaseItem(attributes)` — thin wrapper over `BaseItem:createSync`, reuses `base_items.name`'s existing unique constraint for the duplicate-name error path (no new validation needed).
- `giveToPlayer(source, baseItemId, amount)` — resolves the base item's `name`, calls the existing `ItemService.add(source, baseItem, amount)`.

### Items tab handlers (`oblsk_admin/server/items.lua`)

- `list` → `ItemService.listBaseItems()`.
- `update` → `ItemService.updateBaseItem(...)`, replies with refreshed list.
- `create` → `ItemService.createBaseItem(...)`, replies with refreshed list (or an error notification on duplicate name).
- `give` — payload `{ targetSource, baseItemId, amount }`; calls `ItemService.giveToPlayer`, notifies both admin (confirmation) and target (received item) via `NotificationService`.

## Out of scope for this slice

- Full spectate mode (Players tab) — stubbed with a "not implemented" notice, real implementation needs client-side camera/collision work that's its own piece of scope.
- Vehicle spawning from the admin panel (Garage tab / dealership territory, not this slice).
- Editing `base_items.name` or `data`/`actions` JSON columns from the UI — those are config-shaped, not admin-panel-shaped; out of scope.
- Blips, Interactions, Locations, Economy, Server, Audit log tabs — remain their own future sub-projects.

## Testing

- Busted specs for `AccountService.listBans/listModerationLogs/warn/logKick`, `VehicleService.listAll/deleteById/teleportToCoords`, `ItemService.listBaseItems/updateBaseItem/createBaseItem/giveToPlayer`.
- Migration test for `moderation_logs` (up/down).
- `oblsk_admin` server specs: each new handler rejects a non-admin `source`, mirroring the existing Organisations handler tests.
- No Vue automated tests (repo convention) — manual in-panel verification substitutes, per Organisations spec.
