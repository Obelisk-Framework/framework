# Licenses plugin design

Source design: Claude Design project "FiveM" (`src/proto/licenses.jsx`) — a
citizen wallet UI showing flippable license/ID cards (state ID, driver
licence, first aid cert, firearms permit, plus job-gated service credential
badges) with front/back detail, status badges, and a "present to officer"
overlay.

The mock's browsing wallet screen (left rail + card stage + record panel) is
**not** built as designed — licenses live as inventory items, not a separate
app/screen. Only the flip-card visual and the present overlay are ported.

## Scope

Full plugin: item-backed data model, permission-gated issue/revoke, a
networked "Present" item action reusing the mock's card visuals. Auto-grant
of the state ID on character creation. Deferred to a follow-up plan: the
license printer world-object interaction (form → generates a license item),
weapon-registry linkage for firearms permits, and any self-service
renew/report-lost flow.

## Data model — license = item, not a table

No `licenses` table. Each license type is its own **base item**, and every
issued license is one **item instance** whose `items.data` JSON (existing
column on `oblsk_items`' `Item` model) carries that license's fields.

**Base items** (seeded by this plugin's migration/seeder — first plugin in
the framework to seed `base_items` rows; no prior art to copy, this
establishes the convention):

- `license_state_id` — personal, non-service
- `license_driver` — personal, carries `classes` (vehicle class grants)
- `license_firstaid` — personal
- `license_firearms` — personal, carries `weapons` (manually-set list for
  now, see Out of scope)
- `license_duty` — service credential; `data.dept` distinguishes LSPD /
  LSMD / DOJ etc. rather than one base item per department, since the only
  per-department differences are theme color, authority text, and rank
  labels — all data, not behavior.

Each base item gets a new `is_presentable` flag (see Present action below)
and a `data` blob for **defaults** (theme colors `{a, b, ink, accent}`,
authority string, back-of-card boilerplate text) — the same
definition-vs-instance split `step`/`step_key` already uses for consumable
items (`base_items.data` = shared config, `items.data` = per-instance state).

**Per-instance `items.data` shape** (personal license):

```
{
  no: "DL 3390-1174",
  issued: "2026-06-22",
  expires: "2030-06-22",
  status: "VALID" | "REVIEW" | "REVOKED" | "EXPIRED",
  holder: { name, dob, sex, height, eyes, hair, addr, csn, blood },
  classes: [["C", "Standard car", true], ...],   // driver only
  weapons: [["Vom Feuer Pistol .45", "SN 88-3341-P"], ...], // firearms only
}
```

Service credential (`license_duty`) instance data swaps `holder` for
`{ name, rank, badge, dept }` and drops `classes`/`weapons` — mirrors the
mock's `SERVICE_IDS` shape.

`Item.isStackableWith` already refuses to stack items with differing `data`
(existing behavior, no change needed) — two driver's licenses with different
`no` values never merge into one stack, which is exactly what's wanted here.

## Permissions

Two `PermissionService` keys, no new ACL system:

- `licenses_issue`
- `licenses_revoke`

## Present action (new item-interaction extension point)

`ContextMenu.vue` currently renders a fixed set of flag-gated buttons
(Use/Equip/Open/Split/Give/Drop) with no per-item custom UI hook — confirmed
via codebase exploration, no existing extension point covers "show item's
own detail view." This plugin adds one:

- New base-item boolean flag `is_presentable`. When set, `ContextMenu.vue`
  shows a **Present** button alongside the existing generic ones (additive
  change, not a new menu type).
- Client → server event `oblsk_licenses:present` (item id). Server resolves
  the nearest other player(s) within a short interaction radius (reuse
  whatever proximity helper `oblsk_mdt`/interactions already use for
  "nearest person" checks) and relays a new networked NUI event carrying the
  license's card data to both the presenter and the target(s).
- Both clients render the same overlay: the mock's `LicenseCard` component
  (front/back 3D flip, theme-colored, portrait/seal/hairline decorations)
  centered full-screen, with "Hold up" / "Put away" controls on the
  presenter's side only — the target sees a read-only card that dismisses
  itself when the presenter puts it away or walks out of range.
- This NUI event is intentionally generic (`item:view`-shaped payload: item
  id + rendered fields), so a later plugin (e.g. the printer, or other
  presentable documents) can reuse the same present/view pipeline instead of
  inventing its own.

## Server flow

- **Character-create hook**: grants one `license_state_id` item with
  generated `data` — `holder` populated from the new character's name/dob,
  `csn` generated, `status: "VALID"`, `issued` = today, `expires` = +N years
  (config constant).
- **Admin commands**, gated by the permission keys above:
  - `/license-issue <charId> <type> [key=value ...]` — creates the item
    instance with supplied fields merged over base-item defaults.
  - `/license-revoke <charId> <itemId>` — sets `status: "REVOKED"` in place
    (keeps the item, doesn't delete it — a revoked license is still a
    real-world object the character possesses and can be asked to
    surrender).
- No cron/expiry sweep. `expires` is a stored date; VALID vs EXPIRED is a
  client-side comparison against current time at render. `REVIEW` and
  `REVOKED` stay manual, admin-set states — expiry is the only status
  that's ever computed rather than stored.

## Client

- Port `LicenseCard`, `LicHairline`, `LicSeal`/`LicSealFallback`,
  `LicPortrait`, `LicField`, and `LIC_STATUS` from `src/proto/licenses.jsx`
  into `oblsk_licenses/web/` largely as-is (Vue port of the React mock,
  matching this codebase's existing Vue components) — these are pure
  presentational pieces already decoupled from the mock's wallet-browsing
  shell, which is what's being dropped.
- No `globalElements.js` registration — there's no always-mounted overlay;
  the present overlay only mounts for the duration of a present action,
  triggered via the context-menu/NUI event path above, not the
  globalElements pattern used by HUD/phone.

## Testing

- Server-side service tests (busted, mirroring `oblsk_garage`/`oblsk_mdt`
  conventions): issue creates correctly-shaped item data; revoke sets status
  without deleting; character-create grants exactly one state ID;
  permission checks reject unauthorized issue/revoke.
- Present-flow test: nearest-player resolution picks correct target(s)
  within radius and excludes players out of range.

## Out of scope for this plan

- License printer world-object interaction (form-driven license
  generation) — separate spec, needs its own design for object placement,
  job-gating, and form UX.
- Weapon-registry linkage for firearms permits — `weapons` stays a
  manually-set data field; no live sync with actual owned weapon items.
- Self-service renew / report-lost flows from the mock (buttons exist in
  the mock's record panel, which isn't being built).
- Wallet browsing screen — dropped per design discussion; licenses are
  inventory items, not a separate app or global overlay.
