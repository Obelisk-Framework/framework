# oblsk_shop restock, register collection, and safe decay — design spec

Date: 2026-08-16
Status: approved for implementation planning

## Context

This is the "24/7 store" slice of the world-economy-state-model
decomposition (jobs module → scheduler → **world economy state** →
trashbins → individual job plugins). `oblsk_shop` already covers most of
what a 24/7 needs: `shops` + `shop_stock` (qty depletes on purchase,
NPC-vs-org ownership via `organization_id`) + `shop_safes`
(`cash_amount`/`max_cash`, accrues from every cash sale, already clamped).
What's missing, per the plugin's own README ("no in-game restock UI in
v1") and the money-job's stated need for a legitimate (non-criminal)
register-collection path: restocking and legit collection, plus a
scheduled fallback for both so an unattended server's economy doesn't
grind to a halt if no one runs the future delivery/money jobs.

**Explicitly out of scope**: the delivery/money job plugins themselves
(future slices — they'll call the functions this spec builds), ATM
auto-refill fallback (belongs to `oblsk_banking`, separate slice),
clothes-shop stock (separate slice).

## Scope decisions

- Jobs that consume this (built later) never carry real items or cash —
  purely cosmetic (an animation), per explicit instruction. This spec's
  functions are atomic, location-scoped state mutations, not a
  pickup-here/deliver-there transfer — `restock` and
  `collectRegisterCash` don't need to know or care what the collecting
  job plugin does with the (imaginary) proceeds.
- Restock is a fixed amount per call: `qty = min(qty + restock_amount,
  max_qty)`, both admin-configurable per `shop_stock` row (`max_qty`
  seeded from the row's initial `qty`).
- Register collection is legitimate-only, NPC-owned-only (`shop.
  organization_id == nil`, same predicate `SafeCrackingService` already
  uses for its crime-path gate) — zeroes `cash_amount`. It coexists with
  the existing criminal `SafeCrackingService` crack path on the same
  `shop_safes` row; both are independently usable, different actors.
- Uncollected register cash decays by a fixed amount per scheduled run
  (not a percentage, not an all-at-once zero-out) once
  `last_collected_at` is older than a configured threshold — floored at
  0.
- Both fallback mechanisms (auto-refill stale stock, decay stale safes)
  are `ActionService`-registered actions with no default schedule — an
  admin wires them up via the Scheduler tab (built in the prior slice),
  same "DB-defined, admin-editable, no default seeding" posture as
  everything else scheduled so far.

## Data model changes

`shop_stock` (new columns, migration adds to existing table):
- `max_qty` (integer) — restock ceiling, seeded from the row's `qty` at
  migration time for existing rows
- `restock_amount` (integer, default a sane positive value e.g. 10) —
  admin-configurable per item
- `last_restocked_at` (nullable integer, unix epoch) — staleness marker

`shop_safes` (new columns):
- `decay_amount` (decimal(10,2), default a sane positive value e.g. 50)
  — admin-configurable per shop
- `last_collected_at` (nullable integer, unix epoch) — staleness marker

`shared/config.lua` (new `ShopConfig` fields):
- `AutoRefillStaleAfterSeconds` — how stale `last_restocked_at` must be
  before the fallback action restocks a row
- `SafeDecayAfterSeconds` — how stale `last_collected_at` must be before
  the fallback action decays a safe

## Server API (ShopService)

- `ShopService.restock(shopId)` — for every `shop_stock` row belonging
  to `shopId`: `qty = min(qty + restock_amount, max_qty)`, stamp
  `last_restocked_at = os.time()` on each row touched.
- `ShopService.collectRegisterCash(shopId)` → `boolean ok, string|nil
  reason` — rejects with `'Shop is not NPC-owned'` if
  `shop.organization_id` is set; otherwise zeroes `shop_safes.
  cash_amount`, stamps `last_collected_at = os.time()`.

## Scheduler-facing actions (registered in `server/main.lua`, no player)

- `shop:auto_refill_stale_stock` — for every `shop_stock` row where
  `last_restocked_at` is nil or `os.time() - last_restocked_at >=
  ShopConfig.AutoRefillStaleAfterSeconds`, calls `ShopService.restock`
  on that row's shop (dedupe by shop so a multi-item shop isn't restocked
  once per stale row).
- `shop:decay_stale_safes` — for every NPC-owned shop's `shop_safes` row
  where `last_collected_at` is nil or `os.time() - last_collected_at >=
  ShopConfig.SafeDecayAfterSeconds`, `cash_amount = max(0, cash_amount -
  decay_amount)`.

Both are plain `ActionService.register(actionId, handler)` calls at boot,
callable by an admin's Scheduler-tab-configured `scheduled_jobs` row via
`ActionService.execute(nil, actionId, {})` — no code changes needed in
the Scheduler service itself, this is exactly the consumption pattern it
was built for.

## Testing

- `ShopService.restock` spec: caps at `max_qty`, stamps
  `last_restocked_at`, touches only the target shop's rows
- `ShopService.collectRegisterCash` spec: rejects org-owned shops,
  zeroes `cash_amount` and stamps `last_collected_at` for NPC-owned ones
- `shop:auto_refill_stale_stock` action spec: restocks nil/stale rows,
  skips fresh ones, restocks each stale shop once even with multiple
  stale stock rows
- `shop:decay_stale_safes` action spec: decays nil/stale NPC-owned
  safes, skips fresh ones and org-owned ones, floors at 0
