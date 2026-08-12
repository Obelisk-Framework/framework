# Banking Plugin — Design

## 1. Scope

A new `oblsk_banking` plugin (repo already scaffolded, empty) adding a full economy
foundation — no cash/balance system exists anywhere in the framework today — plus three
entry points onto it: a phone app, physical ATMs, and walk-in bank branches.

**In scope for v1:**
- Personal bank accounts (one per character) and organization bank accounts (shared,
  permission-gated by rank), both plain balance accounts — no checking/savings/credit
  distinction, no APY, no credit limit.
- Deposit, withdraw, transfer between accounts, transaction history.
- Cards: freeze, PIN, spend limit — persisted, but with no consumer yet (no POS/shop
  system exists to check card state against). Built now as a forward hook.
- Item bindings — a general `oblsk_items` module feature this plugin is the first
  consumer of, resolving which base item is "cash" without hardcoding an item name
  anywhere.

**Explicitly out of scope for v1:**
- Bills/invoices/standing orders.
- Cash stored as a DB balance — cash is the bound `currency.cash` item living in the
  player's inventory. Only bank balances live in the database.
- Any POS/shop system consuming card freeze/limit state.
- NPC/ped spawning for branch tellers — see §5.

## 2. Reference prototype

Pulled from the shared Claude Design "FiveM" project (`019de78f-9966-77d9-90c0-73b12ead46cd`):
- `src/proto/banking.jsx` — desktop "e-Banking" web app: Overview / Transfer / Cards /
  Bills / Statements tabs. Bills tab is dropped for v1 (see scope above); the rest is
  the reference for the branch-teller UI and the source to adapt for the phone app.
- `src/proto/atm.jsx` — full physical ATM machine simulation: card insert, PIN pad,
  bezel-key menu, cash tray. Menu is Withdraw / Deposit / Balance / Statement only — no
  transfer at the ATM. This is the reference for the ATM UI, ported close to 1:1.
- No finished phone-sized banking app exists in the prototype library. `phone.jsx`
  routes to an `AppBank` component that is never defined anywhere in the project, and
  `phone-widgets.jsx` has only a home-screen `WidgetBank` balance card. The phone app's
  mobile layout is therefore original work, following the `AppBar` + scrollable-panel
  convention used by sibling phone apps (`AppWeather`, `AppBleeter`).

## 3. Item bindings (lives in `oblsk_items` module)

### 3.1 Problem

Banking needs to say "remove 500 cash" somewhere in code. Hardcoding an item name
breaks the moment a server owner renames it, and doesn't generalize — shops need the
same "which item is money" answer, without depending on banking.

The wrong layer is the item itself: an `is_currency` flag on `base_items` fails because
(a) it's not a behavioral capability the way `is_useable`/`is_stackable` are, it's an
identity reference, and (b) nothing stops it being set on more than one row, leaving no
way to say which one wins.

### 3.2 Design

A **binding** is a 1:1 map from a logical key used in plugin code (`currency.cash`) to
a concrete base item chosen by the server administrator. Plugin code never names an
item; it names a role, resolved at runtime. Three premises:

1. All base items are created by an administrator (admin panel, out of scope here). No
   plugin ships item definitions.
2. A binding may be unset. Plugins degrade gracefully — an unbound `currency.cash`
   behaves exactly like every player having zero cash. Never a player-facing error,
   never an exception.
3. Keys exist because a plugin consumes them. There is no declaration step independent
   of a consumer, and no way to define a key nobody uses.

This lives in `oblsk_items` (a core-loaded module, folded into core per the
fold-modules-plugins architecture — see `ItemService.lua`'s own header comment) rather
than in `oblsk_banking`, because shops and other future plugins need "which item is
cash" without depending on the banking plugin.

### 3.3 Data model

No change to `base_items`. Per the earlier decision in this same session, add a
migration giving `base_items.name` a unique constraint — general data hygiene,
independent of bindings (bindings reference `id`, not `name`).

New table, via the project's `Schema` DSL (matches every other migration in the
codebase — no raw `CREATE TABLE`):

```lua
-- oblsk_items/server/migrations/..._create_item_bindings_table.lua
Schema.create('item_bindings', function(table)
    table:id()
    table:string('key', 64):unique()
    table:foreignId('base_item_id'):constrained('base_items')   -- onDelete defaults to RESTRICT
    table:string('updated_by', 64):nullable()
    table:timestamp('updated_at'):nullable()
end)
```

`base_item_id` is a real FK (`ON DELETE RESTRICT`, `Blueprint:constrained()`'s default —
see `core/core/server/ORM/Schema.lua`) to `base_items.id` — bindings reference the
definition, never an inventory instance. Deleting an item that a binding depends on is
blocked, not cascaded. `key` is a unique string column, not the primary key — the ORM's
`:id()` is the only primary-key mechanism available (auto-increment integer only, no
string-primary-key support), so lookups by `key` go through `:where('key', ...)`.

New model, `oblsk_items/server/models/ItemBinding.lua`, following `BaseItem.lua`'s
shape:

```lua
ItemBinding = BaseModel:extend('item_bindings')
ItemBinding.primaryKey = 'id'
ItemBinding.timestamps = false
ItemBinding.fillable = { 'key', 'base_item_id', 'updated_by', 'updated_at' }
```

**An empty table is a valid, fully functional state.** A fresh server boots with every
key unbound and every dependent feature dormant. Rows are never deleted automatically —
disabling a plugin and re-enabling it later restores its assignment untouched. Such rows
become *stale* (assigned but no loaded plugin currently requires that key) and are
surfaced separately by the (out-of-scope, future) admin panel, never silently dropped.

### 3.4 Requirements declaration

Reuses the existing per-plugin `shared/config.lua` convention already used by
`oblsk_garage` and `oblsk_character-selection`, rather than inventing a new manifest
file format:

```lua
-- oblsk_banking/shared/config.lua
Config.Requires = {
    bindings = {
        ['currency.cash'] = {
            live = false,
            description = 'Deposits and withdrawals',
            hint = 'A stackable item without metadata',
        },
    },
}
```

| Field | Type | Meaning |
|---|---|---|
| `live` | bool | Whether an admin may swap the item at runtime without a restart. Default `true`. |
| `description` | string | What *this plugin* uses the key for. Kept per-consumer, never collapsed when merged. |
| `hint` | string | Optional. What kind of item suits this key. First non-nil across consumers wins. |

No `item` field (the plugin can't know what exists on this server) and no `required`
field (nothing about a binding can fail a boot — see §3.6).

Merge rule for `live` when multiple plugins request the same key: logical AND. Any
consumer saying `false` makes the key non-live — `live` is a property of how the item is
*used* (banking holds a balance in it), not one plugin's opinion.

### 3.5 `ItemService` additions

All queries go through the project's `QueryBuilder`/model layer (matches
`ActionService.lua`'s `QueryBuilder.new('actions'):where(...):firstSync()` style — no
raw SQL anywhere in this plugin or module):

```lua
-- oblsk_items/server/services/ItemService.lua (additions)

local registry = {}    -- key -> { live, hint, uses = { [pluginName] = description } }
local resolved = {}    -- key -> base item row | false  (false = confirmed unbound)

--- Called once per plugin at boot (see §3.6) with that plugin's Config.Requires.bindings.
function ItemService.registerRequirements(pluginName, bindingsTbl)
    for key, def in pairs(bindingsTbl or {}) do
        local entry = registry[key] or { live = true, uses = {} }
        entry.live = entry.live and (def.live ~= false)
        entry.hint = entry.hint or def.hint
        entry.uses[pluginName] = def.description or true
        registry[key] = entry
    end
end

--- Returns the bound base item row, or nil if the key is unbound (or unrequired).
--- Misses are cached as `false`, not `nil`, so an unbound lookup doesn't re-hit the
--- registry/DB on every call. `resolved[key] ~= nil` is the presence check.
function ItemService.binding(key)
    local hit = resolved[key]
    if hit ~= nil then return hit or nil end

    if not registry[key] then
        print('[ItemService] WARNING: binding "' .. key .. '" is not required by any plugin')
        resolved[key] = false
        return nil
    end

    local row = QueryBuilder.new('item_bindings'):where('key', key):firstSync()
    if not row then
        resolved[key] = false
        return nil
    end

    local base = BaseItem:findSync(row.base_item_id)
    if not base then
        print('[ItemService] ERROR: binding "' .. key .. '" points at missing item #' .. tostring(row.base_item_id))
        resolved[key] = false
        return nil
    end

    resolved[key] = base
    return base
end

function ItemService.hasBinding(key)
    return ItemService.binding(key) ~= nil
end
```

The registry check (not just the assignment table) matters: a stale assignment alone
never satisfies a lookup, and calling `binding()` for a key your plugin never declared
in `Config.Requires.bindings` resolves to `nil` forever — the one hard rule for plugin
authors (mirrors §9.2 of the source design this section is adapted from).

Convenience wrappers, so every call site doesn't hand-write the nil guard:

```lua
function ItemService.countBinding(source, key)
    local base = ItemService.binding(key)
    if not base then return 0 end
    return ItemService.count(source, base)   -- delegates to inventory, out of this plugin's scope
end
```

`countBinding` returning `0` for an unbound key is the point of premise 2: indistinguishable
from a player who simply has none.

### 3.6 Boot sequence

Extends the existing `bootstrap.lua` registry loop (it already walks `registry.json`'s
plugin list to run each plugin's migrations — see `loadRegistry`/`runMigrationsAt`) with
one more step per plugin, after all migrations run and before plugins start handling
traffic:

```
1. modules load (folded into core, includes oblsk_items)
2. run migrations for every module + plugin (existing step)
3. for each plugin in registry.json: load its shared/config.lua,
   call ItemService.registerRequirements(pluginName, Config.Requires and Config.Requires.bindings)
4. report binding status (log only — unbound keys are a setup checklist, never a boot failure)
5. plugins start
```

Nothing calls `ItemService.binding()` until step 5, so no plugin observes a
half-populated registry. A fresh install logs every unbound key at warn level, listing
which plugins need it — that list is the setup checklist, not an error.

### 3.7 Usage in this plugin

```lua
-- oblsk_banking/server/services/BankingService.lua
function BankingService.deposit(source, accountId, amount)
    local cash = ItemService.binding('currency.cash')
    if not cash then
        return false, 'Cash deposits are not available on this server'
    end
    if not ItemService.has(source, cash, amount) then
        return false, 'Not enough cash'
    end
    ItemService.remove(source, cash, amount)
    -- credit the account, log the transaction (see §4)
    return true
end
```

Resolve once per operation and pass the resolved base item down — never call
`ItemService.binding(key)` twice within the same transfer, since a live re-bind between
two calls could straddle the swap.

## 4. Database (`oblsk_banking`)

Polymorphic owner, mirroring the existing `vehicles.owner_type`/`owner_id` pattern
(`oblsk_vehicles`) rather than inventing a new convention:

```lua
Schema.create('bank_accounts', function(table)
    table:id()
    table:string('owner_type', 20)   -- 'character' | 'organization'
    table:integer('owner_id')
    table:string('bank', 32)         -- 'fleeca' | 'pacific' | 'maze' — display/flavor only
    table:string('account_number', 20):unique()
    table:string('label', 100)
    table:decimal('balance', 12, 2):default(0)
    table:timestamps()
end)

Schema.create('bank_cards', function(table)
    table:id()
    table:foreignId('bank_account_id'):constrained('bank_accounts'):onDelete('CASCADE')
    table:string('label', 100)
    table:string('last4', 4)
    table:string('pin_hash', 255)
    table:boolean('frozen'):default(0)
    table:boolean('contactless'):default(1)
    table:decimal('spend_limit', 12, 2):nullable()
    table:decimal('spent_this_cycle', 12, 2):default(0)
    table:string('exp', 5)
    table:timestamps()
end)

Schema.create('bank_transactions', function(table)
    table:id()
    table:foreignId('bank_account_id'):constrained('bank_accounts'):onDelete('CASCADE')
    table:integer('counterparty_account_id'):nullable()
    table:string('direction', 4)     -- 'in' | 'out'
    table:decimal('amount', 12, 2)
    table:string('kind', 20)         -- 'deposit' | 'withdraw' | 'transfer_in' | 'transfer_out'
    table:string('description', 255):nullable()
    table:timestamps()
end)
```

`BankingService.transfer(fromAccountId, toAccountId, amount)` debits and credits inside
one DB transaction (matching the transactional-safety expectations already established
by `GarageService`'s ownership-checked mutations) and writes both `bank_transactions`
rows.

## 5. Permissions

Five keys, checked via `Character:can(key)` (`HasPermissions` trait, already applied to
`Character` in `oblsk_characters`) — **not** `Rank:can(key)` directly. `Character` has a
delegate registered (`oblsk_organizations`, `PermissionService.addDelegate('character', ...)`)
that walks the character's `OrganizationMembership` → `Rank`/`Department` grants
automatically, so a single `Character:can(key)` call on the acting character is both the
correct and the established way to check this — see
`docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md` and
`modules/oblsk_organizations/tests/character_delegate_spec.lua`.

- `banking.view` — see balance and statements
- `banking.deposit`
- `banking.withdraw`
- `banking.transfer`
- `banking.cards` — freeze/PIN/limit management

For an organization-owned account, `BankingService` resolves the caller's active
character, then calls `character:can('banking.<action>')`; a `true` result means some
rank/department grant in the org chain authorizes it. Personal accounts are always fully
usable by their owning character with no permission check — these keys only ever gate
organization accounts. Granting is out of scope here (existing `PermissionService.grant`
API, exercised by whatever org-management UI/command already grants other keys).

## 6. Physical interaction points — no new subsystem

ATMs and branch tellers are point-in-world interactions, not NPCs. This project already
has a core, DB-backed registry for exactly that — `InteractionService`/`ActionService`
(`core/core/server/Services/InteractionService.lua`, `ActionService.lua`,
`actions`/`interactions` tables). Neither the ATM nor the branch teller spawns a ped or
implements its own targeting/zone logic; both register through this existing service.
See `[[project-zones-npcs-service]]` memory — NPC/ped spawning specifically has no
dedicated service yet as of this design and is out of scope; point/marker interactions
(what both ATM and branch need) are already solved.

```lua
InteractionService.register({
    x = ..., y = ..., z = ..., range = 1.5,
    label = 'Use ATM',
    action = 'banking:atm-use',
})
ActionService.register('banking:atm-use', function(source, data)
    -- opens the ATM UI (see §7.2)
end)
```

Branch tellers register the same way at each bank's map location (Fleeca, Maze Bank,
Pacific Standard), with `action = 'banking:branch-use'` opening the full desktop layout
instead.

## 7. Three entry points, one `BankingService`

All three call the same server RPCs (list accounts, transactions, transfer, deposit,
withdraw, card freeze/PIN/limit) — no UI-specific server logic.

### 7.1 Phone app

Registered into `oblsk_phone` the way `oblsk_mdt` registers `PhoneAppRegistry` — but
`oblsk_phone` is a **soft** dependency (see §8), not hard. Mobile-adapted layout
(stacked nav, not the prototype's sidebar): Overview, Transfer, Cards, Statements. No
Bills tab. Built fresh per §2 — no phone mockup to port.

### 7.2 ATM

Fullscreen UI opened via `banking:atm-use`, ported close to 1:1 from `src/proto/atm.jsx`
— card insert animation, PIN pad, bezel-key menu, physical cash tray. Menu: Withdraw,
Deposit, Balance, Statement. No transfer at the ATM, matching the prototype exactly.

### 7.3 Branch teller

Full desktop layout opened via `banking:branch-use`, ported from `src/proto/banking.jsx`
(minus the Bills tab) — Overview, Transfer, Cards, Statements, sidebar nav. This is the
one entry point with parity to every feature in scope.

## 8. Module vs. plugin dependencies

Two different guarantees, handled two different ways:

- **`oblsk_items` (module) — hard dependency.** Modules are folded into core (per the
  fold-modules-plugins architecture); `oblsk_banking`'s `fxmanifest.lua` already
  declares `dependencies { 'obelisk' }` like every other plugin, which structurally
  guarantees `ItemService` exists. No runtime existence check needed — there's no
  code path where it could be absent.
- **`oblsk_phone` (plugin) — soft dependency.** `oblsk_phone` is a separate,
  independently-installable plugin that may not be present on every server. Guard the
  registration call the same way `ActionService.execute` already guards its own
  optional `PolicyService` dependency (`if PolicyService then ... else runAction() end`
  — see `core/core/server/Services/ActionService.lua`):

  ```lua
  AddEventHandler('onResourceStart', function(resourceName)
      if GetCurrentResourceName() ~= resourceName then return end
      if PhoneAppRegistry then
          PhoneAppRegistry.register({ app_key = 'banking', name = 'Banking', mandatory = false })
      end
  end)
  ```

  Absent `oblsk_phone`, banking simply doesn't add a phone app — ATM and branch teller
  are unaffected. (Note: `oblsk_mdt`'s existing registration call has no such guard —
  out of scope to fix here, but this plugin should not repeat that gap.)

## 9. Testing

Unit specs per service, following the existing `tests/*_spec.lua` +
`tests/support/fake_query_builder.lua` pattern used by every other plugin/module in this
codebase (`oblsk_garage`, `oblsk_mdt`, `oblsk_organizations`): `BankingService` (deposit,
withdraw, transfer atomicity, permission gating on org accounts), `ItemService.binding`
additions (unbound → nil, stale key never resolves, live-AND merge rule, cache
invalidation on rebind).
