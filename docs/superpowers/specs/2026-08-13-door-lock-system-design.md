# Door lock system

**Goal:** A `core/modules/oblsk_doors` module letting doors be locked/unlocked
by four independent methods — direct permission grant, org/rank/department
license rules, a bound key item, or a lockpick minigame — reusing existing
core infrastructure (`InteractionService`, `EntityStreamerService`,
`PermissionService`, `oblsk_organizations`) rather than building parallel
proximity/permission systems. Touches two repos: `core` (the module itself)
and `oblsk_licenses` (a small addendum to make duty-license rank/org data
structured and queryable).

**Non-goals:** no generic zone/prop-interaction engine (deferred to a future
dedicated service per prior decision — this module solves door locks only,
narrowly); no vehicle doors (`oblsk_vehicles` already owns
`alldoors_locked`); no rank-CRUD UI in MDT (out of scope — see open item at
the end).

## Data model

Migrations in `core/modules/oblsk_doors/server/migrations/`:

- **`doors`**: `id, pos_x/y/z (float), heading (float), radius (float),
  model_hash (string, nullable), locked (bool, default true), created_at`.
  A door is a coordinate + heading pair, not tied to any specific GTA map
  object — `model_hash` is optional, only needed if the door should also
  spawn a visual prop (see Interaction & prop below).
- **`door_items`**: `id, door_id (FK), binding_key (string)`. Many-to-many:
  one binding key can be attached to several doors (a master key opening
  the house door and the bathroom), and a door can accept several distinct
  binding keys (front gate key ≠ house key). `binding_key` is a *logical*
  role name (e.g. `door.key.house_42.front`), never a raw item name —
  resolved through `ItemService`'s existing binding registry
  (`ItemService.registerRequirements`/`.binding`/`.hasBinding`), the same
  mechanism already used for tool-item requirements elsewhere. If a
  binding key has no item bound to it, that row simply never grants
  access — fail closed, no fallback guess at an item name.
- **`door_access_rules`**: `id, door_id (FK), organization_id (FK
  oblsk_organizations.organizations), rank_id (FK
  oblsk_organizations.ranks, nullable), department_id (FK
  oblsk_organizations.departments, nullable)`. Rows are **OR'd** per door;
  within a row, `rank_id`/`department_id` are **AND'd** when both set, and
  "any" when null. A character passes a row if they hold a valid duty
  license for `organization_id` AND (`rank_id` null or matches their
  membership's `rank_id`) AND (`department_id` null or present in their
  membership's `department_ids`). This expresses arbitrary allow-lists
  (e.g. "Lieutenant and Chief, not Captain" — two rows, one per rank) that
  a single min-rank threshold couldn't.

Individual person access ("give this one person a key regardless of
rank/org") is **not** a new table — it's the existing
`PermissionService.can('character', characterId, doorKey)` grant path,
independent of the license/org system entirely.

## Server: `DoorService`

`core/modules/oblsk_doors/server/services/DoorService.lua`, following the
`oblsk_vehicles`/`oblsk_items` module shape (migrations + models + service,
server owns all DB work). `DoorService.canUnlock(source, doorId)` checks,
in order, stopping at the first method that grants access:

1. **Permission grant** — `PermissionService.can('character', characterId,
   'door:'..doorId)`.
2. **Access rule** — for each `door_access_rules` row on this door: confirm
   `ItemService.hasBinding('license.duty')` (see License integration
   below) resolves to something, then check license validity + rank/dept
   as described above. If the `license.duty` binding is unset, this whole
   method is skipped for every door, not just this one — fails closed.
3. **Key item** — for each `door_items` row: `ItemService.hasBinding(row.binding_key)`
   resolves to an item name; if the player's inventory holds it, unlock.
   Unbound rows are skipped.
4. **Lockpick** — see below; this path doesn't go through `canUnlock`
   directly, it's a separate challenge/result exchange that calls
   `DoorService.unlock(source, doorId)` once the client proves a valid
   completion.

Admin commands: `/door-create`, `/door-grant <charId> <doorId>` (wraps the
permission grant), `/door-revoke`. Creating a door's `door_items`/
`door_access_rules` rows is data entry, not a chat command — left to a
future admin UI or direct seed/migration, matching how other modules seed
config-heavy data today.

## License integration (`oblsk_licenses` — companion repo change)

Two changes to `oblsk_licenses`, mirroring the smallest precedent for
cross-resource structure in the codebase:

- **Structured fields.** `license_duty` instance `data` currently stores
  `holder = { name, rank, badge, dept }` with `rank`/`dept` as free text
  (`core/docs/superpowers/specs/2026-08-12-licenses-plugin-design.md:62-64`).
  Replace with `rank_id` (FK `oblsk_organizations.ranks.id`) and
  `organization_id` (FK `oblsk_organizations.organizations.id`); the
  presentable card still renders a name/department string, looked up from
  those ids at render time rather than stored redundantly. Issuing a duty
  license only lets an org leader pick a rank from **their own**
  organization's rank list (`ranks.organization_id = <their org>`) — MDT's
  issuance flow filters the rank picker accordingly. (MDT has no
  rank-*management* UI yet, only seed-time `OrganizationService.addRank`
  calls — creating that CRUD screen is a real prerequisite, called out as
  an open item below rather than silently assumed to exist.)
- **Item binding registration.** At boot, `oblsk_licenses` registers its
  duty-credential base item under the logical role `license.duty` via
  `ItemService.registerRequirements`/`.binding` — same pattern as any
  other bound item role, so nothing outside `oblsk_licenses` ever
  hardcodes the literal item name.
- **Export.** `fxmanifest.lua` gets an `exports` block (mirroring
  `oblsk_connector/fxmanifest.lua:10-14`, the only existing cross-resource
  exports precedent) with `hasValidLicense(characterId, organizationId)` —
  a boolean, checking `license.duty` binding + `data.organization_id` +
  `data.status == 'VALID'` + not expired. It deliberately does **not**
  return rank/department — `oblsk_doors` already has to call
  `OrganizationService.getMembership` for the rule check, so rank/dept
  logic lives once, in `oblsk_organizations`, not duplicated inside
  `oblsk_licenses`.

## Interaction & prop

Doors register with the existing `InteractionService`
(`core/core/server/Services/InteractionService.lua`) at `range = door.radius`
instead of a custom client-side proximity poller — this gives the
interact prompt, the `core:client:interaction-use` net event, and the
`interaction:use` hook for free. `ActionService`'s action for a door
interaction calls `DoorService.canUnlock`/`toggle`.

If `model_hash` is set, the same door additionally registers as an
`object`-type entity via `EntityStreamerService` purely so the physical
prop exists/despawns at render distance across chunks. The streamer has no
state or animation concept (confirmed — chunk-based spawn/despawn only,
no per-entity interact hook), so lock state and open/close rotation are
handled entirely by `DoorClientService` acting on the streamed object's
live handle, independent of the streamer's own lifecycle. `locked` state
changes broadcast via `doors:server:state-changed` to all clients in
range, same as the general event list below.

## Lockpicking minigame

Source: Claude Design project "FiveM"
(`019de78f-9966-77d9-90c0-73b12ead46cd`), `src/proto/minigames.jsx`,
`LockpickGame` component. Mechanics: 3-pin tumbler, `A`/`D` sweep the pick
angle, hold `Space` for tension; each pin has a randomized "sweet spot"
angle and a shrinking tolerance window; holding tension off-target accrues
pick "wear/strain" (0–100), hitting 100 breaks the current pick (3 picks
per attempt, all broken = fail); in-tolerance tension accrues per-pin
progress toward 100, completing all 3 pins opens the lock.

Ported to Vue (core's NUI stack, matching the `Keybinds.vue`/
`RadialMenu.vue` precedent) as `core/web/src/components/doors/
LockpickGame.vue` — same state machine and tuning constants, React
`useState`/`useEffect` loops replaced with Vue `ref`/`watch` and a
`requestAnimationFrame` loop identical in structure to the source.

**Security**: the client cannot simply claim success. Server issues a
one-time challenge token on `doors:client:lockpick-start` (rate-limited
per player, one outstanding challenge at a time); client runs the
minigame locally and submits the result with that token on
`doors:client:lockpick-result`; server validates token + a minimum
elapsed-time floor (reject implausibly fast completions) before calling
`DoorService.unlock`. No lock-outcome logic ever trusts an unvalidated
client claim.

## Events (`module:server/client:action` convention)

- `doors:server:sync` — full door list, sent on resource start / player
  join (positions, radius, current locked state; access-rule data stays
  server-side).
- `doors:client:toggle` — request lock/unlock at a door (routes through
  `canUnlock`).
- `doors:client:lockpick-start` / `doors:server:lockpick-challenge` /
  `doors:client:lockpick-result` — challenge/response exchange above.
- `doors:server:state-changed` — broadcast to nearby clients on any lock
  state change, for the prop animation.

## Testing

Server-side `DoorService.canUnlock` unit tests per method (permission,
access-rule row OR/AND semantics including the "two ranks, not a
threshold" case, key-item binding present/absent, lockpick token
validation including a forged/stale-token rejection case) — standard
`tests/*_spec.lua` per the existing module convention. Manual verification
for the Vue minigame UI and the visual prop toggle (no automated coverage
for NUI interaction, matching how other minigame-style UIs in the
framework are verified).

## Open items (not solved by this spec)

- **MDT rank-management UI** doesn't exist yet (org leaders currently have
  no in-game way to create/edit ranks — only seed-time calls exist). This
  spec assumes it either already exists by implementation time or gets
  built alongside; if scoped separately, duty-license issuance and
  `door_access_rules` administration both stay blocked on it until org
  leaders can actually create the ranks/departments being referenced.
- **Door admin UI** for authoring `door_items`/`door_access_rules` rows —
  out of scope, assumed to be direct data entry (seed/migration or a
  future admin panel) for now.
