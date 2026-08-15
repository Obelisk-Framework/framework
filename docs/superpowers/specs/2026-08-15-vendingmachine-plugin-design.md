# Vending Machine Plugin Design

Status: approved
Date: 2026-08-15

## Summary

Port the `vending.jsx` Claude Design prototype 1:1 (including all animations)
to a new `oblsk_vendingmachine` plugin. Machines are world interactions
(reuses core `InteractionService`, like `oblsk_cardealer`). Each machine has
a stock table linking slot codes (A1-E4) to real `base_items`, with per-slot
price and stock. Payment is cash-only, matching the prototype (note
acceptor, no card reader).

## Data Model

### `vendingmachine_shops`
- `id`
- `name` string(100)
- `interaction_id` FK → `interactions`, cascade delete, unique
- timestamps

### `vendingmachine_slots`
- `id`
- `shop_id` FK → `vendingmachine_shops`, cascade delete
- `code` string(2) — e.g. `A1`..`E4`
- `base_item_id` FK → `base_items`, cascade delete
- `price_cents` integer
- `stock` integer, default 0
- timestamps
- unique(`shop_id`, `code`)

`base_item_id` links straight into the shared item catalog — vending
machines sell real items other systems already know about (snacks, drinks,
etc.), not a new logical item-binding role like `currency.cash`. This
mirrors `cardealer_listings.base_vehicle_id`, not `item_bindings`.

## Stocking Config → Seeder

`shared/config.lua` declares machines: interaction location/label + a
slot map (`A1 = { item = 'Chilli Ranch Chaser', price = 1.00, stock = 10 }`,
...). `VendingMachineSeeder.ensure()` runs at boot (idempotent, mirrors
`TerminalItemSeeder`):

- Resolves each `item` name against `base_items` (by name) — errors loudly
  (print) if a configured item doesn't exist yet, skips that slot.
- Creates the `interactions` row + `vendingmachine_shops` row if missing.
- Creates a `vendingmachine_slots` row per configured slot **only if
  missing** (matched by `shop_id` + `code`). Never overwrites an existing
  row — so a restart doesn't reset live stock/price that's since been
  hand-edited in the DB. Config is the seed, the DB row is the live
  authority after that.

This is deliberately admin/config driven, not an in-game admin UI — no
existing plugin in this repo has one for catalog management (cardealer
listings are DB rows, same posture), and building one is out of scope here.

## Payment Flow

No `vendingmachine_sessions` table — credit is ephemeral, in-memory,
keyed by player `source` (same posture as `TerminalService.sessions`,
which is itself keyed by session id but same "in-memory, doesn't survive
restart" rule). Cleared on purchase-flow close or disconnect.

- `insertNote(source, shopId, noteValue)`: checks the player has
  `currency.cash` ≥ `noteValue`, removes it, adds `noteValue*100` to that
  player's credit. 5% chance of rejecting the note instead (matches the
  prototype's reject animation) — cash is not removed on reject.
- `refund(source, shopId)`: returns full credit to the player as cash,
  zeroes credit.
- `purchase(source, shopId, code)`: re-resolves the slot row server-side
  (never trusts client-sent price/stock — same rule as
  `CarDealerService.resolveListing`). Fails if slot missing, stock is 0, or
  credit < price. On success: decrements credit, decrements `stock` by 1,
  grants the item via `ItemService.add(source, baseItem, 1)`.
- Closing the UI (ESC) or disconnect while credit > 0 auto-refunds as cash
  — no dupe, no silent loss.

The delivery-bay animation (item drops from its shelf, rides the belt,
lands in the collection nook) is pure client cosmetics. The item is already
granted to the player's inventory the moment `purchase` succeeds; clicking
the bay item to "take it" just removes the UI card, no further server
round-trip.

## Files

```
oblsk_vendingmachine/
  fxmanifest.lua
  shared/config.lua                       -- machine locations + slot->item/price/stock
  server/
    migrations/
      ..._create_vendingmachine_shops_table.lua
      ..._create_vendingmachine_slots_table.lua
    services/
      VendingMachineService.lua           -- list/insertNote/refund/purchase, headless-testable
      VendingMachineSeeder.lua
    main.lua                              -- interaction registration + relay (mirrors CarDealer)
  client/
    main.lua                              -- pure relay, no client-side logic
  web/
    VendingMachine.vue                    -- 1:1 port of vending.jsx incl. all keyframe animations
    routes.js
  tests/
    vendingmachine_service_spec.lua
  README.md
```

## UI Port Notes

Port every animation from the prototype 1:1:
- note feed-in (`vmFeed`), reader scan sweep (`vmScan`)
- reject slip spit-out (`vmSpit`)
- vend drop from shelf → fall → land → ride the belt → land in nook
  (the `fly` state machine driving `left`/`top` transitions + `vmDrop`/
  `vmChute`/`vmRide`/`vmBelt` keyframes)
- sold-out overlay, active-slot highlight, keypad press feedback

Vue port keeps the same visual structure (shelves/keypad/note acceptor/
delivery bay) and CSS custom properties (`--ob-accent` etc.) already used
by other ported plugins (Terminal.vue, CarDealer.vue) so it inherits the
game's live theme tokens instead of the prototype's hardcoded ones.

## Testing

`tests/vendingmachine_service_spec.lua`, structured like
`cardealer_service_purchase_spec.lua`:
- insertNote: happy path adds credit and removes cash; insufficient cash
  fails cleanly; reject path (force the RNG) leaves cash untouched
- purchase: happy path grants item/decrements stock/decrements credit;
  insufficient credit fails; zero stock fails; unknown slot code fails
- refund: returns credit as cash, zeroes it; refund with 0 credit is a
  no-op
