# oblsk_clothesshop stock, register, and safe decay — design spec

Date: 2026-08-16
Status: approved for implementation planning

## Context

Second slice of the world-economy-state-model decomposition (jobs →
scheduler → 24/7 store `oblsk_shop` → **clothes shop** → petrol stations →
trashbins → individual job plugins). `oblsk_clothesshop` is the real
storefront (`clothes_shops` + `clothes_shop_items` +
`clothes_shop_item_variants`), today an unlimited catalog with no
ownership concept and no revenue accrual — `ClothesShopService.purchase`
has an explicit comment noting there's deliberately no stock table to
decrement. `oblsk_clothingshops`' `clothing_shops` table (a separate
plugin) is NOT what it appears to be for this purpose: it's an abstract
"clothes business" investment slot consumed by `oblsk_globalmarket`
(`clothes = 'clothing_shops'`), not linked to any specific
`clothes_shops.id` row — irrelevant to this slice, not reused.

This slice mirrors the `oblsk_shop` slice (restock, legit NPC-owned
register collection, scheduler-consumable fallback actions for both) for
`oblsk_clothesshop`, plus the ownership column that plugin never had.

## Scope decisions

- Add `organization_id` to `clothes_shops` (nullable, FK to
  `organizations`, `onDelete('SET NULL')`) — exact same pattern as
  `oblsk_shop`'s `shops.organization_id`. Reconciling this with
  `oblsk_globalmarket`'s separate `clothing_shops` investment record is
  explicitly out of scope for this slice.
- Stock lives on `clothes_shop_item_variants` (the actual purchasable
  leaf — each color/texture of a garment sells independently), not on
  `clothes_shop_items`.
- **Behavior change**: `ClothesShopService.purchase` becomes
  stock-limited. It currently has no stock check at all (infinite
  purchases per variant) — this slice adds a check-and-decrement inside a
  `Database.transaction`, matching `oblsk_shop`'s `grantAndDecrement`
  pattern, rejecting `'Not enough stock'` when a line's variant is
  depleted.
- Add a register (`clothes_shop_safes`), accruing from every successful
  purchase (cash or card, matching `oblsk_shop`'s
  `SafeCrackingService.accrueRevenue` call site — unconditional on
  payment method) via a new `ClothesShopSafeSeeder` that ensures every
  `clothes_shops` row has a matching safe row. No crime/crack path for
  this register in this slice — only legit NPC-owned-only collection
  (`ClothesShopService.collectRegisterCash`) and scheduled decay.
- Same fallback-action shape as the `oblsk_shop` slice:
  `ClothesShopService.autoRefillStaleStock()` /
  `ClothesShopService.decayStaleSafes()`, wired as
  `ActionService.register`'d actions with distinct ids
  (`clothesshop:auto_refill_stale_stock`,
  `clothesshop:decay_stale_safes` — `ActionService`'s registry is global
  across every plugin in the single Lua state, so these must not collide
  with `oblsk_shop`'s `shop:*` ids). Both handlers gate
  `if player then return end` as the FIRST statement, from the start —
  the `oblsk_shop` slice's final review found the equivalent actions
  there were client-triggerable and exploitable before that gate was
  added as a fix; this slice builds it in from day one.
- Same restock/decay semantics as `oblsk_shop`: fixed amount per call
  (`qty = min(qty + restock_amount, max_qty)`), fixed decay per scheduled
  run (`cash_amount = max(0, cash_amount - decay_amount)`, never touches
  `last_collected_at` itself), neither action gets a default schedule.
- Migration backfill for pre-existing `clothes_shop_item_variants` rows:
  floor `max_qty` at `math.max(<a seed default>, restock_amount)` since
  there's no existing `qty` to backfill from at all (unlike `oblsk_shop`,
  which had real `qty` data already) — seed every existing variant row
  with a starting `qty`/`max_qty` (e.g. 20) rather than 0, so this
  migration doesn't instantly empty every shelf in an already-running
  server.

## Data model

- `clothes_shops`: + `organization_id` (nullable FK)
- `clothes_shop_item_variants`: + `qty` (integer, default 20), `max_qty`
  (integer, default 20), `restock_amount` (integer, default 10),
  `last_restocked_at` (nullable integer, unix epoch)
- `clothes_shop_safes` (new table): `shop_id` (FK `clothes_shops`, unique),
  `cash_amount` (decimal(12,2), default 0), `max_cash` (decimal(12,2),
  default 15000 — matching `oblsk_shop`'s `SafeCracking.DefaultMaxCash`),
  `decay_amount` (decimal(10,2), default 50), `last_collected_at`
  (nullable integer, unix epoch)

## Server API (ClothesShopService)

- `ClothesShopService.restock(shopId)` — tops up every variant row of
  that shop.
- `ClothesShopService.collectRegisterCash(shopId)` → `boolean ok,
  string|nil reason` — NPC-owned-only (`clothes_shops.organization_id`
  nil), zeroes the safe, stamps `last_collected_at`.
- `ClothesShopService.autoRefillStaleStock()` → `number` — dedup-by-shop
  fallback.
- `ClothesShopService.decayStaleSafes()` → `number` — NPC-owned-only
  fallback decay.
- `ClothesShopService.purchase` (modified): after resolving the cart and
  before granting items, checks each line's variant has `qty >= 1`
  (rejects `'Not enough stock'` otherwise); on success, decrements each
  line's variant `qty` by 1 inside the same transaction that grants
  items; after payment succeeds, calls a new
  `ClothesShopService.accrueRevenue(shopId, total)` (writes into
  `clothes_shop_safes`, capped at `max_cash` — same clamp math as
  `oblsk_shop`'s `SafeCrackingService.accrueRevenue`).

`ClothesShopSafeSeeder.ensure()` — idempotent, creates a
`clothes_shop_safes` row for every `clothes_shops` row missing one
(mirrors `oblsk_shop`'s `SafeSeeder.ensure()`).

## Scheduler-facing actions

- `clothesshop:auto_refill_stale_stock`, `clothesshop:decay_stale_safes`
  — registered in `server/main.lua`, gated `if player then return end`,
  no default schedule.

## Testing

- Migration/backfill specs (organization_id column, variant stock
  columns with a non-zero seed default, `clothes_shop_safes` table)
- `ClothesShopService.purchase` stock-check/decrement specs (rejects
  depleted variant, decrements on success, existing purchase specs still
  pass)
- `ClothesShopService.restock`/`collectRegisterCash`/`accrueRevenue`
  specs (same shape as the `oblsk_shop` slice's)
- `autoRefillStaleStock`/`decayStaleSafes` specs, including the
  org-owned-exclusion and dedup-by-shop cases
- A spec proving both new `ActionService.register`'d actions ignore a
  non-nil `player` argument (the exact gap the `oblsk_shop` slice's final
  review had to add after the fact — this slice's plan should build the
  test in from Task 1, not retrofit it)
