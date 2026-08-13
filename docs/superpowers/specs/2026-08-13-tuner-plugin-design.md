# Tuner + Tuner Tablet — Design Spec

**Source design:** claude.ai/design project "FiveM", `pages/tuner.html` (+ `src/tuner.jsx`) and `pages/tuner-tablet.html` (+ `src/proto/tuner-tablet.jsx`, `tuner-parts.jsx`, `tuner-service.jsx`).

**Scope decision (user-confirmed):** full fidelity port of both prototypes — self-serve Tuner shop AND the staff Tuner Tablet (work orders, crew assignment, parts-bin stock, invoicing/card-terminal). No feature is cut relative to the prototype's interaction design; only the *data* moves from client-side mock state to real server state.

## What exists today that this reuses

| Concern | Existing system | Reused as-is |
|---|---|---|
| Vehicle mod application on a live entity | `modules/oblsk_vehicles/client/services/VehicleTuningService.lua` (`registry`/`apply`) | Extended with new keys, one existing bug fixed (see Task 2) |
| Persisted "what's fitted" | `vehicle_tunings` table (EAV: vehicle_id, key, value json), already read by `VehicleService.spawn` and sent to the client on every spawn | Tuner writes rows here — no new "installed mods" table |
| World interaction point → NUI | `InteractionService.register` (server) + `ActionService.register` (server) + `WebView.openPage`/`WebView.focus` (server) — pattern copied verbatim from `oblsk_shop/server/main.lua` | Same three-call pattern, two actions (`tuner:open`, `tunertablet:open`) |
| Cash/card payment | `ItemService.binding('currency.cash')` + `.has`/`.remove` for cash, `BankingService.charge(source, cardId, amount, description)` for card — copied from `oblsk_shop/server/services/ShopService.lua` | Same two-branch payment logic |
| Card list for the tablet's payment sheet | `BankingService.listCardsForCharacter(characterId)` + the `banking:server:cardsSync` push pattern (`oblsk_banking/client/main.lua`) | Tuner Tablet gets its own `tunertablet:server:cardsSync` push built the same way — replaces the prototype's mocked global `CARDS` array |
| Crew roster (which player can be assigned a work order) | `OrganizationService.listMembers(orgId)` (`modules/oblsk_organizations`) | `tuner_shops.organization_id` links a shop to an org; the tablet's crew list is that org's members, no new roster table |
| Staff permission gating | `PermissionService.can('character', characterId, key)`, delegated automatically to a character's org rank/department (`modules/oblsk_organizations/server/main.lua`) — doc-only seeder pattern copied from `oblsk_garage/server/seeders/GaragePermissionSeeder.lua` | New keys: `tuner.crew` (assign/carry out/pick up the tablet), `tuner.invoice` (settle a bill) |
| Notifications | `NotificationService.notify(target, {type, title, description})` | Same |

## Data model (new migrations, owned by `oblsk_tuner`)

```
tuner_shops
  id, name, interaction_id (FK interactions, cascade), organization_id (FK organizations, nullable),
  tablet_interaction_id (FK interactions, nullable — separate pickup point for the staff tablet), timestamps

tuner_catalog_items          -- what a customer can buy in the self-serve Tuner screen
  id, tuner_shop_id (FK), category (string — see native mapping table below),
  label, native_index (int, nullable — used for SetVehicleMod-style slots),
  preview_hex (string, nullable — swatch colour for paint categories), price (decimal 10,2),
  active (bool, default true), timestamps

tuner_service_parts          -- the parts bin / shelf (TT_PARTS in the prototype)
  id, tuner_shop_id (FK), key (string, e.g. 'p-engine'), label, price (decimal 10,2),
  qty (int, default 0 — stock), timestamps
  unique(tuner_shop_id, key)

tuner_service_items          -- wear-service catalogue (TT_SERVICE in the prototype)
  id, tuner_shop_id (FK), key (string, e.g. 'engine'), label,
  part_key (string — must match a tuner_service_parts.key for the same shop),
  labour_price (decimal 10,2), timestamps
  unique(tuner_shop_id, key)

vehicle_component_wear       -- condition tracking (new concept, not covered by vehicle_tunings)
  id, vehicle_id (FK vehicles, cascade), key (string, e.g. 'engine'), value (int 0-100),
  timestamps
  unique(vehicle_id, key)
  -- a missing row for a given key reads as 100 ("as new") — rows are only written
  -- once something has actually worn the part down or a service has reset it,
  -- same lazy-default posture as vehicle_tunings.

tuner_work_orders
  id, tuner_shop_id (FK), vehicle_id (FK vehicles), status (string: open|progress|awaiting|closed|void),
  crew_character_id (FK characters, nullable), total (decimal 10,2), timestamps

tuner_work_order_lines
  id, work_order_id (FK tuner_work_orders, cascade), kind (string: part|service),
  ref_key (string — category for a part line, service key for a service line),
  label, price (decimal 10,2), stock_part_key (string, nullable — which tuner_service_parts
  row this line consumes), timestamps
```

`tuner_shops.organization_id` is nullable: a shop with no linked org has no assignable crew (the tablet's "Pick a mechanic" step has nobody to offer) — that's an accepted degraded state, not an error, since not every server wants org-gated staff.

## Native mod mapping (client, `VehicleTuningService.registry`)

GTA's `SetVehicleMod`/`ToggleVehicleMod`/dedicated setters, one registry key per `tuner_catalog_items.category`:

| category | native | notes |
|---|---|---|
| `primaryColor` | `SetVehicleCustomPrimaryColour(entity, r, g, b)` | already registered, unchanged |
| `secondaryColor` | `SetVehicleCustomSecondaryColour(entity, r, g, b)` | new |
| `pearlescent` | `SetVehicleExtraColours(entity, pearlescentId, wheelId)` | new — `native_index` on the catalog row is the GTA pearlescent colour id (0-159), *not* derived from `preview_hex` at runtime; `preview_hex` is UI-only |
| `spoiler` | `SetVehicleMod(entity, 0, index, false)` | **fixes an existing bug**: currently registered against mod type `3` (side skirt), should be `0` |
| `bumperF` | `SetVehicleMod(entity, 1, index, false)` | new |
| `bumperR` | `SetVehicleMod(entity, 2, index, false)` | new |
| `skirt` | `SetVehicleMod(entity, 3, index, false)` | new |
| `exhaust` | `SetVehicleMod(entity, 4, index, false)` | new |
| `hood` | `SetVehicleMod(entity, 7, index, false)` | new |
| `roof` | `SetVehicleMod(entity, 10, index, false)` | new |
| `wheels` | `SetVehicleMod(entity, 23, index, false)` then `SetVehicleWheelType(entity, wheelType)` | new — value is `{ wheelType, index }` |
| `window` | `SetVehicleWindowTint(entity, index)` | new — not a `SetVehicleMod` slot |
| `engine` | `SetVehicleMod(entity, 11, index, false)` | new |
| `brakes` | `SetVehicleMod(entity, 12, index, false)` | new |
| `suspension` | `SetVehicleMod(entity, 15, index, false)` | new |
| `turbo` | `ToggleVehicleMod(entity, 18, value == true)` | already registered, unchanged |
| `horn` | `SetVehicleMod(entity, 14, index, false)` | new |
| `neon` | `SetVehicleNeonLightsColour(entity, r, g, b)` + `SetVehicleNeonLightEnabled(entity, i, true)` for `i` in 0-3 | new — value is `{ r, g, b }`, all four corners toggle together |
| `livery` | `SetVehicleLivery(entity, index)` | new — dedicated native, not a mod slot |

Mod-type indices above are the commonly-documented GTA values; **Task 2 ends with an in-game verification pass** (spawn a car, apply each category through the shop, confirm the right part changes) since a couple of vehicles have per-model quirks (motorcycles/planes lack several slots entirely — `SetVehicleMod` on a slot the vehicle doesn't have is a documented no-op, not an error, so this degrades safely).

## Work order lifecycle (Tuner Tablet)

Mirrors the prototype's `raise` → `assign` → `markDone` → `settle` flow, moved server-side:

1. **`raise(shopId, vehicleId, lines)`** — creates one `tuner_work_orders` row (status `open`) per line (matches the prototype: one work order per cart line, not one order for the whole cart), with lines' prices re-resolved from `tuner_catalog_items`/`tuner_service_items` server-side (never trusts a client-sent price — same rule as `ShopService.resolveLines`). No stock check yet, no payment yet.
2. **`assign(orderId, crewCharacterId)`** — requires `tuner.crew` on `crewCharacterId`'s character, and that character not already `crew_character_id` on another `progress` order at the same shop (mirrors the prototype's `busy()`). Moves `open` → `progress`.
3. **`complete(orderId)`** — re-checks the line's stock is still available (mirrors the prototype's "Parts missing" short-circuit — stock can run out between assign and complete if another order consumed it first), moves `progress` → `awaiting`.
4. **`settle(shopId, vehicleId, method, cardId, source)`** — bundles every `awaiting` order for that vehicle at that shop (mirrors the prototype's bundled-invoice / card-terminal step), in one pass: charges cash or card for the summed total, decrements `tuner_service_parts.qty` per line's `stock_part_key`, upserts `vehicle_tunings` for `kind = 'part'` lines and `vehicle_component_wear = 100` for `kind = 'service'` lines, marks the orders `closed`. If the vehicle is currently spawned (`VehicleService.activeNetIds`), broadcasts a live `VehicleTuningService.apply` to the owning client so the customer sees the change immediately instead of only on next spawn.

## Out of scope (explicitly deferred, not built by this plan)

- An admin UI for editing `tuner_catalog_items`/`tuner_service_items` prices — seeded by hand via SQL/README instructions, same posture as `oblsk_shop`'s `shops`/`shop_stock` (no admin UI exists for those either).
- "On duty" presence tracking for crew — the tablet's crew list is simply every member of the linked organization; busyness is derived from open work orders, not a duty toggle (the prototype doesn't have one either).
- Multi-shop franchise pricing overrides beyond the existing per-`tuner_shop_id` scoping.
