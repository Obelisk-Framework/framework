# Shop + Payment Plugins — Design

## 1. Scope

Two new plugins:

- **`oblsk_shop`** — walk-in shops (general store, liquor store, etc). Interaction
  point → catalogue UI → cash or card checkout → items granted to inventory.
- **`oblsk_payment`** — a global HUD element holding the card-picker/checkout UI,
  extracted so any plugin needing "pay by card" (shop now; ATM, vending, mechanic,
  dealer, etc. later) reuses one component and one server-side charge path instead of
  each owning its own card UI and balance logic.

**In scope for v1:**
- Shops with DB-backed stock (`shops` + `shop_stock`), one interaction per shop,
  registered at boot the same way `oblsk_garage` registers garage interactions.
- Cash checkout (existing `ItemService` / bound `currency.cash` item, same mechanism
  `BankingService.deposit`/`withdraw` already use).
- Card checkout via the new `oblsk_payment` plugin: card list + charge, calling into
  `oblsk_banking`'s `BankCard`/`bank_accounts` tables.
- `BankingService.listCards` and `BankingService.charge` — new methods `oblsk_banking`
  needs to support any card-paying consumer, not just shop.
- Real stock: a purchase decrements `shop_stock.qty`; insufficient stock rejects the
  purchase (or the specific line).

**Explicitly out of scope for v1:**
- In-game restocking UI/mechanic (deliveries, supplier NPCs). Stock is DB-seeded/admin-
  edited only, same posture as garage vehicle spawn config today.
- PIN entry / contactless toggle enforcement at checkout — `bank_cards.pin_hash` and
  `contactless` exist in the schema already but aren't checked by `charge` in v1 (the
  player having the card "in their wallet," i.e. it shows up in `listCards`, is the
  only gate). Revisit if/when a theft/cloning feature needs it.
- NPC/ped clerks — see the zones/NPCs deferral already established for garage/banking.
- Any UI for managing `shops`/`shop_stock` rows in-game (admin does it via migration/DB
  for now, consistent with how garages are seeded).

## 2. Reference prototype

From the shared Claude Design "FiveM" project (`019de78f-9966-77d9-90c0-73b12ead46cd`):
`src/proto/shop.jsx` (mounted via `pages/shop.html`) — compact windowed catalogue +
cart, "Cash" or "Card" checkout. Card checkout slides a fan of `BankCard` components up
from the bottom; picking one and confirming shows a receipt. This is the direct source
for both plugins: the catalogue/cart chrome becomes `oblsk_shop`'s `Shop.vue`, and the
card-fan/`BankCard`/receipt subtree becomes `oblsk_payment`'s `Payment.vue`.

## 3. Data model

### `oblsk_shop` migrations

```
shops
  id
  name            string
  interaction_id  FK -> interactions.id
  timestamps

shop_stock
  id
  shop_id         FK -> shops.id, onDelete CASCADE
  base_item_id    FK -> base_items.id, onDelete CASCADE
  price           decimal(10,2)
  qty             integer
  timestamps
```

`shop_stock.qty` is real inventory, decremented on purchase. `price` lives on the stock
row (per-shop pricing), not on `base_items` — the same item can cost differently at
different shops.

### `oblsk_banking` additions

No new tables — `bank_cards` (already exists: `frozen`, `spend_limit`,
`spent_this_cycle`, `pin_hash`, `contactless`) is sufficient for charge/list. Two new
`BankingService` functions and one new permission key (`banking.charge`, checked via
the existing `checkAccountPermission` helper, same shape as `banking.transfer`).

## 4. Server flow

### Shop

Boot: `registerAllShops()` (mirrors `registerAllGarages`) reads `shops`, resolves each
row's `interactions` row, and calls `InteractionService.register` with
`action = 'shop:open'`, `options = { shopId }`.

`ActionService.register('shop:open', ...)`: resolves the active character, calls
`ShopService.list(shopId)`, opens `WebView.openPage(source, '/Shop')`, syncs stock via
`Obelisk.emitClient('shop:server:sync', source, { shop, stock })`.

`ShopService.list(shopId)` — joins `shop_stock` to `base_items` for display (name,
price, qty, item metadata).

`ShopService.purchase(source, shopId, lines, method, cardId)` where `lines` is
`[{ shopStockId, qty }]`:
1. Re-fetch each `shop_stock` row fresh (never trust client-sent price/qty), reject if
   any line's `qty` requested exceeds `shop_stock.qty` on hand.
2. Compute `total` server-side from the fetched rows.
3. Pay:
   - `method == 'cash'`: same shape as `BankingService.deposit`'s cash leg —
     `ItemService.has(source, cash, total)` then `ItemService.remove`.
   - `method == 'card'`: `BankingService.charge(source, cardId, total, 'Purchase at ' ..
     shop.name)`. Propagates `false, reason` on failure (frozen/limit/balance).
4. On successful payment, inside one `Database.transaction`: decrement each
   `shop_stock.qty` by its line qty, and `ItemService.add` each purchased item to the
   player's inventory.
5. Any failure at any step returns `false, reason` with no DB mutation and no payment
   taken (cash/card charge only happens after stock is confirmed available; DB stock
   decrement + item grant are atomic together).

### Payment

`BankingService.listCards(characterId)` — cards on the character's personal account,
plus cards on any organization account where `Character:can('banking.charge')`
succeeds (same permission-chain walk `checkAccountPermission` already does for
transfer). Returns each card with its bank name, last4, type, exp, and the *current
available balance* of its backing account (so the picker can show/disable
insufficient-funds cards exactly like the prototype does) — never the raw account
balance for cards the character doesn't own outright (org cards still show balance;
that's an intentional existing pattern, e.g. shared department card in the prototype).

`BankingService.charge(source, cardId, amount, description)`:
1. Load the card; 404 if missing.
2. Reject if `card.frozen`.
3. Reject if `card.spend_limit` is set and `card.spent_this_cycle + amount >
   card.spend_limit`.
4. Load the backing account; reject if `balance < amount`.
5. `Database.transaction`: debit the account balance, bump
   `card.spent_this_cycle += amount`, insert a `bank_transactions` row
   (`kind = 'purchase'`, `description`).
6. Returns `true` on success, `false, reason` otherwise — same convention as every
   other `BankingService` mutator.

`oblsk_payment` has no server-side entry point of its own beyond forwarding to
`BankingService.charge`/`listCards` — it's a thin UI + the one cross-plugin call,
consistent with plugins sharing one Lua VM (fold-modules-plugins).

## 5. Web flow

### Registry, not direct import

`oblsk_payment` needs to be callable from any plugin's Vue code without those plugins
importing `oblsk_payment`'s files directly (plugins stay decoupled). Core's `App.vue`
already does exactly this shape for global elements
(`provide('obelisk:globalElementsRegistry', registry)`); this adds one more slot:

```js
// core/web/src/App.vue
const paymentApi = reactive({ requestPayment: null })
provide('obelisk:payment', paymentApi)
```

`oblsk_payment/web/Payment.vue`, on `setup()`, injects the same key and fills in the
function:

```js
const paymentApi = inject('obelisk:payment')
paymentApi.requestPayment = ({ amount, description }) => new Promise((resolve) => {
  // show self, fetch cards via 'payment:client:listCards' (or reuse a cached list),
  // resolve({ ok:true, method:'card', cardId }) on confirm,
  // resolve({ ok:false }) on cancel.
})
```

Any consumer:

```js
const payment = inject('obelisk:payment')
const result = await payment.requestPayment({ amount: total, description: `Purchase at ${shop.name}` })
if (result.ok) { /* tell server to finalize with cardId */ }
```

The actual money movement is still server-authoritative: `requestPayment` only
resolves *which card was picked*; `Shop.vue` then sends `shopId, lines, 'card',
cardId` to the server exactly like it would for cash, and the server is the one that
calls `BankingService.charge`. The web-side promise never itself moves money — this
avoids a client-trusted "payment succeeded" flag.

### `oblsk_shop/web/Shop.vue`

Routed page (`/Shop`, `web/routes.js`), not a global element — same category as
`Garage.vue`/`Phone.vue`. Catalogue grid + cart panel port directly from
`src/proto/shop.jsx`'s non-card-picker markup (category filters, item hover card, cart
line qty controls, cash/card buttons). The card-fan JSX (`BankCard`, the sliding
picker, the receipt overlay) is deleted from this component entirely — it moves to
`oblsk_payment` unchanged in visual design.

### `oblsk_payment/web/Payment.vue`

Global element (`globalElements.js`, `defaultVisible: false`). Visibility is driven by
`requestPayment` itself (sets a local `open` ref true/false) rather than the
show/hide/toggle NUI events other global elements use — those are for player-toggled
HUD pieces (health, minimap); Payment is request-driven from other Vue code in the same
SPA instance. Contains the card-fan picker + amount header + confirm/cancel + receipt,
ported from `src/proto/shop.jsx`'s `BankCard`/picker/receipt JSX.

## 6. Error handling

Every service mutator returns `true` or `false, reason` (existing framework
convention). `Shop.vue` and `Payment.vue` surface failures via
`NotificationService.notify(source, { type: 'error', ... })` server-side, same
`notifyFailure` pattern `oblsk_garage/server/main.lua` already uses — never a bare
silent failure in the UI.

Stock check happens before payment is attempted (so a card is never charged for an
out-of-stock item), and stock decrement + item grant happen in the same DB transaction
(so a crash between them can't grant items without decrementing stock, or vice versa).

## 7. Testing

`ShopService` specs (mirrors `banking_service_*_spec.lua` style):
- Purchase succeeds, decrements stock, grants items (cash and card paths).
- Purchase rejected: insufficient stock, insufficient cash, insufficient card funds.
- Stock/grant atomicity: a failure partway through the transaction leaves both stock
  and inventory unchanged.

`BankingService.charge`/`listCards` specs:
- Charge rejected: frozen card, spend-limit would be exceeded, insufficient balance.
- Charge succeeds: balance debited, `spent_this_cycle` bumped, transaction logged.
- `listCards` returns the character's personal-account cards plus org-account cards
  only when `banking.charge` permission is granted; omits org cards otherwise.
