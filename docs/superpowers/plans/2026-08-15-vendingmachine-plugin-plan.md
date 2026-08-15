# Vending Machine Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `oblsk_vendingmachine`, a new plugin that ports the `vending.jsx` Claude Design prototype 1:1 (all animations) into a game-usable vending machine wired to real inventory items, config-driven stocking, and cash payment.

**Architecture:** Standard Obelisk plugin shape (mirrors `oblsk_cardealer`/`oblsk_terminal`): two DB tables (`vendingmachine_shops`, `vendingmachine_slots`), a headless `VendingMachineService` doing all mutation/validation server-side, a config-driven idempotent seeder, `server/main.lua` wiring interactions + net events, a pure-relay `client/main.lua`, and a full-bleed `VendingMachine.vue` page ported from the prototype.

**Tech Stack:** Lua 5.4 (FiveM server/client), Vue 3 `<script setup>`, existing Obelisk core services (`InteractionService`, `ActionService`, `ItemService`, `NotificationService`, `QueryBuilder`/`Schema`, `WebView`, `Obelisk` net-event wrapper).

**Spec:** `core/docs/superpowers/specs/2026-08-15-vendingmachine-plugin-design.md`

## Global Constraints

- Plugin lives at `core/plugins/oblsk_vendingmachine/`, is its own git repo (every plugin dir here is — `git init` it), and is added to `core/plugins/registry.json`'s `"plugins"` array.
- Server never trusts client-sent price/stock/slot data — every purchase/insert-note/refund call re-resolves everything from the DB by ids the server already validated (same rule as `CarDealerService.resolveListing`).
- `vendingmachine_slots.base_item_id` FKs straight into `base_items` (shared catalog) — no new `item_bindings` key, matches `cardealer_listings.base_vehicle_id`.
- Credit is in-memory only, keyed by player `source`, cleared on purchase-flow close/disconnect — never persisted to DB.
- Seeder never overwrites an existing `vendingmachine_slots` row (config is seed-only, DB row is live authority after first boot).
- All animations from `src/proto/vending.jsx` (already fetched into this conversation) must be ported into `VendingMachine.vue`'s `<style>` block verbatim in behavior: `vmDrop`, `vmSpit`, `vmScan`, `vmChute`, `vmRide`, `vmBelt`, `vmFeed`, plus the JS-driven `fly` state machine (fall → land → ride) for the vend animation.
- Money is integer cents everywhere in Lua (`price_cents`), formatted to display via the existing `formatCurrency` composable client-side (same as `CarDealer.vue`).

---

## File Map

```
core/plugins/oblsk_vendingmachine/
  fxmanifest.lua
  shared/config.lua
  server/
    migrations.json
    migrations/
      2026_08_15_150000_create_vendingmachine_shops_table.lua
      2026_08_15_150001_create_vendingmachine_slots_table.lua
    services/
      VendingMachineService.lua
      VendingMachineSeeder.lua
    main.lua
  client/
    main.lua
  web/
    VendingMachine.vue
    routes.js
  tests/
    vendingmachine_service_spec.lua
  README.md
```

---

### Task 1: Plugin skeleton, manifest, config

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/fxmanifest.lua`
- Create: `core/plugins/oblsk_vendingmachine/shared/config.lua`
- Modify: `core/plugins/registry.json`

**Interfaces:**
- Produces: `Config.Machines` — array of `{ name, x, y, z, range, label, slots = { [code] = { item, price, stock } } }`. Later tasks (seeder, service) consume this shape.

- [ ] **Step 1: Create the plugin directory and init its own git repo**

```bash
mkdir -p core/plugins/oblsk_vendingmachine/{shared,server/migrations,server/services,client,web,tests}
cd core/plugins/oblsk_vendingmachine && git init
```

- [ ] **Step 2: Write `fxmanifest.lua`**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'VendingMachine'
author ''
version '1.0.0'

dependencies {
    'obelisk'
}

shared_scripts {
    'shared/**/*.lua'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
    'web/routes.js',
}
```

- [ ] **Step 3: Write `shared/config.lua`**

One entry per physical machine. `slots` keys are `A1`-`E4` (row `A`-`E`, column `1`-`4`), matching the prototype's `VM_ROWS`/`VM_SLOTS` layout. `item` is looked up by `base_items.name` at seed time (Task 4). `price` is dollars (converted to cents by the seeder), `stock` is the initial fill.

```lua
-- core/plugins/oblsk_vendingmachine/shared/config.lua
Config = {}

Config.Debug = false

-- One entry per physical machine. `slots` keys are A1-E4 (5 rows x 4
-- columns, matches the design prototype's shelf layout). `item` is resolved
-- against base_items.name by VendingMachineSeeder at boot — if the name
-- doesn't exist yet that slot is skipped with a warning, not a hard crash.
Config.Machines = {
    {
        name = 'Break Room Vending',
        x = 215.0, y = -800.0, z = 30.7,
        range = 1.5,
        label = 'Vending Machine',
        slots = {
            A1 = { item = 'Chilli Ranch Chaser', price = 1.00, stock = 10 },
            A2 = { item = 'Big Cheese Chaser', price = 1.00, stock = 10 },
            A3 = { item = 'Smoky Rib Chaser', price = 1.00, stock = 10 },
            A4 = { item = 'Sticky BBQ Chaser', price = 1.00, stock = 10 },
            B1 = { item = 'Salt & Vinegar Chaser', price = 1.00, stock = 10 },
            B2 = { item = 'Sour Cream Chaser', price = 1.00, stock = 10 },
            B3 = { item = 'Big Cheese Chaser', price = 1.00, stock = 10 },
            B4 = { item = 'Hot Paprika Chaser', price = 1.00, stock = 10 },
            C1 = { item = 'Zebra Bar', price = 0.75, stock = 10 },
            C2 = { item = 'Meteorite Bar', price = 0.75, stock = 10 },
            C3 = { item = 'Cherry Pop Cola', price = 0.75, stock = 10 },
            C4 = { item = 'Sprunk Bar', price = 0.75, stock = 10 },
            D1 = { item = 'Candy Box Original', price = 0.75, stock = 10 },
            D2 = { item = 'Candy Box Berry Mix', price = 0.75, stock = 10 },
            D3 = { item = 'Candy Box Toffee', price = 0.75, stock = 10 },
            D4 = { item = 'Candy Box Mint', price = 0.75, stock = 10 },
            E1 = { item = 'Release Energy', price = 0.75, stock = 10 },
            E2 = { item = 'Release Ice Blue', price = 0.75, stock = 10 },
            E3 = { item = 'Release Citrus', price = 0.75, stock = 10 },
            E4 = { item = 'Candy Box Dark', price = 0.75, stock = 10 },
        },
    },
}

return Config
```

- [ ] **Step 4: Register the plugin in `core/plugins/registry.json`**

Add `"oblsk_vendingmachine"` to the `"plugins"` array (alphabetically, after `"oblsk_tuner"`):

```json
    "oblsk_terminal",
    "oblsk_tuner",
    "oblsk_vendingmachine"
```

- [ ] **Step 5: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Scaffold oblsk_vendingmachine plugin"
git -C core add plugins/registry.json
git -C core commit -m "Register oblsk_vendingmachine plugin"
```

---

### Task 2: Migrations

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/server/migrations/2026_08_15_150000_create_vendingmachine_shops_table.lua`
- Create: `core/plugins/oblsk_vendingmachine/server/migrations/2026_08_15_150001_create_vendingmachine_slots_table.lua`
- Create: `core/plugins/oblsk_vendingmachine/server/migrations.json`

**Interfaces:**
- Produces: `vendingmachine_shops(id, name, interaction_id, created_at, updated_at)`, `vendingmachine_slots(id, shop_id, code, base_item_id, price_cents, stock, created_at, updated_at)`. Later tasks (seeder, service, tests) read/write these tables by these exact column names.

- [ ] **Step 1: Write the shops migration**

```lua
-- core/plugins/oblsk_vendingmachine/server/migrations/2026_08_15_150000_create_vendingmachine_shops_table.lua
--- Migration: Create vendingmachine_shops table
--- One row per physical machine. interaction_id is the world prompt point,
--- same relationship as cardealer_shops.interaction_id.
return {
    up = function()
        Schema.create('vendingmachine_shops', function(table)
            table:id()
            table:string('name', 100)
            table:foreignId('interaction_id'):constrained('interactions'):onDelete('CASCADE')
            table:timestamps()

            table:unique('interaction_id')
        end)

        print('[Migration] Created vendingmachine_shops table')
    end,

    down = function()
        Schema.drop('vendingmachine_shops')
        print('[Migration] Dropped vendingmachine_shops table')
    end
}
```

- [ ] **Step 2: Write the slots migration**

```lua
-- core/plugins/oblsk_vendingmachine/server/migrations/2026_08_15_150001_create_vendingmachine_slots_table.lua
--- Migration: Create vendingmachine_slots table
--- One row per shelf slot (A1-E4). base_item_id links straight into the
--- shared item catalog - vending machines sell real items other systems
--- already know about, not a new item_bindings logical role (that pattern
--- is for singleton system-wide items like currency.cash, not a catalog).
return {
    up = function()
        Schema.create('vendingmachine_slots', function(table)
            table:id()
            table:foreignId('shop_id'):constrained('vendingmachine_shops'):onDelete('CASCADE')
            table:string('code', 2)
            table:foreignId('base_item_id'):constrained('base_items'):onDelete('CASCADE')
            table:integer('price_cents')
            table:integer('stock'):default(0)
            table:timestamps()

            table:unique({'shop_id', 'code'})
        end)

        print('[Migration] Created vendingmachine_slots table')
    end,

    down = function()
        Schema.drop('vendingmachine_slots')
        print('[Migration] Dropped vendingmachine_slots table')
    end
}
```

- [ ] **Step 3: Write `migrations.json`**

Check the exact format cardealer uses first:

```bash
cat core/plugins/oblsk_cardealer/server/migrations.json
```

Mirror that format, listing both new migration files (this repo's migrations.json is just an ordered filename list — copy the shape exactly, substituting these two filenames).

- [ ] **Step 4: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Add vendingmachine_shops and vendingmachine_slots migrations"
```

---

### Task 3: VendingMachineService (core logic, headless-testable)

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/server/services/VendingMachineService.lua`
- Test: `core/plugins/oblsk_vendingmachine/tests/vendingmachine_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(table):where(col,val):firstSync()/getSync()/insert()/update()`, `CharacterService.getActiveCharacterId(source)`, `ItemService.binding('currency.cash')`, `ItemService.has(source, baseItem, amount)`, `ItemService.remove(source, baseItem, amount)`, `ItemService.add(source, baseItem, amount)`.
- Produces (consumed by Task 5's `server/main.lua`):
  - `VendingMachineService.list(shopId) -> table[]` — one row per slot: `{ code, baseItemId, itemName, priceCents, stock }`.
  - `VendingMachineService.insertNote(source, shopId, noteValue) -> ok:boolean, result:table` — `result = { credit, rejected }` on success/reject, `result` is a reason string on hard failure (e.g. not enough cash).
  - `VendingMachineService.refund(source, shopId) -> ok:boolean, creditReturned:number`
  - `VendingMachineService.purchase(source, shopId, code) -> ok:boolean, result:table|string` — `result = { itemName, remainingCredit }` on success, reason string on failure.
  - `VendingMachineService.getCredit(source, shopId) -> number` (cents)
  - `VendingMachineService.clearSession(source, shopId)` — zeroes in-memory credit without refunding (used by `main.lua`'s auto-refund-then-clear on close).

- [ ] **Step 1: Write the failing test file**

```lua
-- core/plugins/oblsk_vendingmachine/tests/vendingmachine_service_spec.lua
-- Run from the repository root:  lua5.4 core/plugins/oblsk_vendingmachine/tests/vendingmachine_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    if source == 999 then return 5 end
    return nil
end

-- In-memory character->baseItemId->amount ledger, same shape/posture as
-- cardealer_service_purchase_spec.lua's ItemService stub.
local ledger
local CASH_ITEM_ID = 999
ItemService = {}
function ItemService.binding(key)
    if key == 'currency.cash' then return { id = CASH_ITEM_ID } end
    return nil
end
function ItemService.has(source, baseItem, amount)
    local owned = (ledger[5] or {})[baseItem.id] or 0
    return owned >= amount
end
function ItemService.remove(source, baseItem, amount)
    if not ItemService.has(source, baseItem, amount) then return false, 'Not enough items' end
    ledger[5][baseItem.id] = ledger[5][baseItem.id] - amount
    return true
end
function ItemService.add(source, baseItem, amount)
    ledger[5] = ledger[5] or {}
    ledger[5][baseItem.id] = (ledger[5][baseItem.id] or 0) + amount
    return true
end

-- Deterministic RNG hook for the note-reject path — see Step 3's
-- implementation note on VendingMachineService._random.
VENDING_RANDOM_OVERRIDE = nil

dofile(scriptDir .. '../server/services/VendingMachineService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        vendingmachine_shops = {
            [1] = { id = 1, name = 'Break Room Vending', interaction_id = 1 },
        },
        base_items = {
            [50] = { id = 50, name = 'Chilli Ranch Chaser' },
        },
        vendingmachine_slots = {
            [1] = { id = 1, shop_id = 1, code = 'A1', base_item_id = 50, price_cents = 100, stock = 3 },
            [2] = { id = 2, shop_id = 1, code = 'A2', base_item_id = 50, price_cents = 100, stock = 0 },
        },
    })
    QueryBuilder = fake
    ledger = { [5] = { [CASH_ITEM_ID] = 10000 } } -- character 5 starts with $100 cash
    VENDING_RANDOM_OVERRIDE = nil
    VendingMachineService.resetSessionsForTests()
    fn(fake)
end

test('list returns every slot with resolved item name', function()
    withFreshState(function()
        local rows = VendingMachineService.list(1)
        eq(#rows, 2)
        eq(rows[1].code, 'A1')
        eq(rows[1].itemName, 'Chilli Ranch Chaser')
        eq(rows[1].priceCents, 100)
        eq(rows[1].stock, 3)
    end)
end)

test('insertNote: happy path adds credit and removes cash', function()
    withFreshState(function()
        VENDING_RANDOM_OVERRIDE = 0.5 -- above the 5% reject threshold
        local ok, result = VendingMachineService.insertNote(999, 1, 5)
        eq(ok, true)
        eq(result.credit, 500)
        eq(result.rejected, false)
        eq(ledger[5][CASH_ITEM_ID], 10000 - 500)
    end)
end)

test('insertNote: insufficient cash fails cleanly, no credit added', function()
    withFreshState(function()
        ledger[5][CASH_ITEM_ID] = 0
        local ok, reason = VendingMachineService.insertNote(999, 1, 5)
        eq(ok, false)
        eq(reason, 'Not enough cash')
        eq(VendingMachineService.getCredit(999, 1), 0)
    end)
end)

test('insertNote: forced reject leaves cash untouched and credit unchanged', function()
    withFreshState(function()
        VENDING_RANDOM_OVERRIDE = 0.0 -- below the 5% reject threshold
        local ok, result = VendingMachineService.insertNote(999, 1, 5)
        eq(ok, true)
        eq(result.rejected, true)
        eq(result.credit, 0)
        eq(ledger[5][CASH_ITEM_ID], 10000)
    end)
end)

test('purchase: happy path grants item, decrements stock and credit', function()
    withFreshState(function(fake)
        VENDING_RANDOM_OVERRIDE = 0.5
        VendingMachineService.insertNote(999, 1, 5) -- 500 credit
        local ok, result = VendingMachineService.purchase(999, 1, 'A1')
        eq(ok, true)
        eq(result.itemName, 'Chilli Ranch Chaser')
        eq(result.remainingCredit, 400)
        eq(ledger[5][50], 1)
        local slot = fake.new('vendingmachine_slots'):where('code', 'A1'):firstSync()
        eq(slot.stock, 2)
    end)
end)

test('purchase: insufficient credit fails, nothing mutated', function()
    withFreshState(function(fake)
        local ok, reason = VendingMachineService.purchase(999, 1, 'A1')
        eq(ok, false)
        eq(reason, 'ADD $1.00 MORE')
        eq(ledger[5][50], nil)
        local slot = fake.new('vendingmachine_slots'):where('code', 'A1'):firstSync()
        eq(slot.stock, 3)
    end)
end)

test('purchase: zero stock fails even with enough credit', function()
    withFreshState(function()
        VENDING_RANDOM_OVERRIDE = 0.5
        VendingMachineService.insertNote(999, 1, 5)
        local ok, reason = VendingMachineService.purchase(999, 1, 'A2')
        eq(ok, false)
        eq(reason, 'A2 SOLD OUT')
    end)
end)

test('purchase: unknown slot code fails', function()
    withFreshState(function()
        local ok, reason = VendingMachineService.purchase(999, 1, 'Z9')
        eq(ok, false)
        eq(reason, 'UNKNOWN CODE')
    end)
end)

test('refund: returns credit as cash and zeroes it', function()
    withFreshState(function()
        VENDING_RANDOM_OVERRIDE = 0.5
        VendingMachineService.insertNote(999, 1, 20)
        local ok, returned = VendingMachineService.refund(999, 1)
        eq(ok, true)
        eq(returned, 2000)
        eq(ledger[5][CASH_ITEM_ID], 10000)
        eq(VendingMachineService.getCredit(999, 1), 0)
    end)
end)

test('refund: no-op with 0 credit', function()
    withFreshState(function()
        local ok, returned = VendingMachineService.refund(999, 1)
        eq(ok, false)
        eq(returned, 0)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run it to confirm it fails (service file doesn't exist yet)**

```bash
lua5.4 core/plugins/oblsk_vendingmachine/tests/vendingmachine_service_spec.lua
```

Expected: error loading the `dofile` for `VendingMachineService.lua` (file not found).

- [ ] **Step 3: Implement `VendingMachineService.lua`**

```lua
-- core/plugins/oblsk_vendingmachine/server/services/VendingMachineService.lua
--- VendingMachineService - stock reads and credit/purchase mutations for
--- oblsk_vendingmachine. Re-resolves every slot server-side on every call
--- (never trusts a client-sent price/stock/code) — same rule as
--- CarDealerService.resolveListing / TunerService.resolveItems.
VendingMachineService = {}

--- source -> shopId -> credit in cents. In-memory, ephemeral - same posture
--- as TerminalService.sessions. Cleared by refund/purchase-to-zero or
--- explicit clearSession (main.lua calls this on UI close/disconnect after
--- auto-refunding whatever's left).
local credits = {}

local REJECT_CHANCE = 0.05

--- Wrapped so tests can force deterministic outcomes via
--- VENDING_RANDOM_OVERRIDE instead of stubbing math.random globally.
local function roll()
    if VENDING_RANDOM_OVERRIDE ~= nil then return VENDING_RANDOM_OVERRIDE end
    return math.random()
end

local function vmPrice(cents)
    if cents >= 100 then
        return string.format('$%.2f', cents / 100)
    end
    return cents .. '\194\162' -- cent sign, matches the prototype's '¢'
end

--- @param shopId number
--- @return table[] one row per vendingmachine_slots entry for this shop,
---   joined with its base_items display name.
function VendingMachineService.list(shopId)
    local slots = QueryBuilder.new('vendingmachine_slots'):where('shop_id', shopId):getSync()
    local rows = {}
    for _, row in ipairs(slots) do
        local baseItem = QueryBuilder.new('base_items'):where('id', row.base_item_id):firstSync()
        table.insert(rows, {
            code = row.code,
            baseItemId = row.base_item_id,
            itemName = baseItem and baseItem.name or 'Unknown item',
            priceCents = row.price_cents,
            stock = row.stock,
        })
    end
    return rows
end

--- @param shopId number
--- @param code string
--- @return table|nil resolved slot row, string|nil reason
local function resolveSlot(shopId, code)
    local row = QueryBuilder.new('vendingmachine_slots'):where('shop_id', shopId):where('code', code):firstSync()
    if not row then
        return nil, 'UNKNOWN CODE'
    end
    return row, nil
end

--- @param source number
--- @param shopId number
--- @return number credit in cents (0 if none)
function VendingMachineService.getCredit(source, shopId)
    return (credits[source] or {})[shopId] or 0
end

local function setCredit(source, shopId, amount)
    credits[source] = credits[source] or {}
    credits[source][shopId] = amount
end

--- @param source number
--- @param shopId number
--- @param noteValue number dollar denomination (1, 5, 10, 20, 50)
--- @return boolean ok
--- @return table|string { credit, rejected } on success, reason on failure
function VendingMachineService.insertNote(source, shopId, noteValue)
    if type(noteValue) ~= 'number' or noteValue <= 0 then
        return false, 'Invalid note'
    end

    local cash = ItemService.binding('currency.cash')
    if not cash then
        return false, 'Cash purchases are not available on this server'
    end

    local cents = math.floor(noteValue * 100 + 0.5)
    if not ItemService.has(source, cash, cents) then
        return false, 'Not enough cash'
    end

    if roll() < REJECT_CHANCE then
        return true, { credit = VendingMachineService.getCredit(source, shopId), rejected = true }
    end

    local removed, reason = ItemService.remove(source, cash, cents)
    if not removed then
        return false, reason
    end

    local newCredit = VendingMachineService.getCredit(source, shopId) + cents
    setCredit(source, shopId, newCredit)
    return true, { credit = newCredit, rejected = false }
end

--- @param source number
--- @param shopId number
--- @return boolean ok (false if there was nothing to refund)
--- @return number amount refunded in cents
function VendingMachineService.refund(source, shopId)
    local credit = VendingMachineService.getCredit(source, shopId)
    if credit <= 0 then
        return false, 0
    end

    local cash = ItemService.binding('currency.cash')
    if cash then
        ItemService.add(source, cash, credit)
    end
    setCredit(source, shopId, 0)
    return true, credit
end

--- Zeroes credit without refunding — for callers that already refunded (or
--- deliberately want to drop it) and just need the ledger cleared.
--- @param source number
--- @param shopId number
function VendingMachineService.clearSession(source, shopId)
    setCredit(source, shopId, 0)
end

--- @param source number
--- @param shopId number scopes resolveSlot - a security boundary: without
---   it a client could buy any machine's slot while claiming to stand at
---   another
--- @param code string e.g. 'A1'
--- @return boolean ok
--- @return table|string { itemName, remainingCredit } on success, reason on failure
function VendingMachineService.purchase(source, shopId, code)
    local slot, reason = resolveSlot(shopId, code)
    if not slot then
        return false, reason
    end

    if slot.stock <= 0 then
        return false, slot.code .. ' SOLD OUT'
    end

    local credit = VendingMachineService.getCredit(source, shopId)
    if credit < slot.price_cents then
        return false, 'ADD ' .. vmPrice(slot.price_cents - credit) .. ' MORE'
    end

    local baseItem = QueryBuilder.new('base_items'):where('id', slot.base_item_id):firstSync()
    if not baseItem then
        return false, 'Item no longer available'
    end

    local added, addReason = ItemService.add(source, baseItem, 1)
    if not added then
        return false, addReason
    end

    QueryBuilder.new('vendingmachine_slots'):where('id', slot.id):update({ stock = slot.stock - 1 })
    local remainingCredit = credit - slot.price_cents
    setCredit(source, shopId, remainingCredit)

    return true, { itemName = baseItem.name, remainingCredit = remainingCredit }
end

--- Test-only: clears the in-memory credit ledger between spec cases.
function VendingMachineService.resetSessionsForTests()
    credits = {}
end

return VendingMachineService
```

- [ ] **Step 4: Run the tests and confirm all pass**

```bash
lua5.4 core/plugins/oblsk_vendingmachine/tests/vendingmachine_service_spec.lua
```

Expected: `10 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Add VendingMachineService with full test coverage"
```

---

### Task 4: VendingMachineSeeder

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/server/services/VendingMachineSeeder.lua`

**Interfaces:**
- Consumes: `Config.Machines` (Task 1), `QueryBuilder`, `Database.now()`, `Database.isReady()`.
- Produces: `VendingMachineSeeder.ensure()` — called once at boot by `server/main.lua` (Task 5) after `Database.isReady()`, same trigger pattern as `registerAllDealers()` in `oblsk_cardealer/server/main.lua`.

- [ ] **Step 1: Write `VendingMachineSeeder.lua`**

```lua
-- core/plugins/oblsk_vendingmachine/server/services/VendingMachineSeeder.lua
--- VendingMachineSeeder - creates interactions/vendingmachine_shops/
--- vendingmachine_slots rows from Config.Machines at boot, idempotently.
--- Never overwrites an existing vendingmachine_slots row - config is the
--- seed, the DB row is the live authority after that (so a restart doesn't
--- reset stock/price an admin has since hand-edited). Mirrors
--- TerminalItemSeeder's check-then-insert style.
VendingMachineSeeder = {}

local function ensureShop(machine)
    local existingShop = QueryBuilder.new('vendingmachine_shops'):where('name', machine.name):firstSync()
    if existingShop then
        return existingShop.id
    end

    local interactionId = QueryBuilder.new('interactions'):insert({
        x = machine.x, y = machine.y, z = machine.z,
        range = machine.range or 1.5,
        label = machine.label or machine.name,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    local shopId = QueryBuilder.new('vendingmachine_shops'):insert({
        name = machine.name,
        interaction_id = interactionId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    print('[VendingMachine] seeded shop: ' .. machine.name .. ' (#' .. tostring(shopId) .. ')')
    return shopId
end

local function ensureSlot(shopId, code, slotConfig)
    local existing = QueryBuilder.new('vendingmachine_slots'):where('shop_id', shopId):where('code', code):firstSync()
    if existing then
        return
    end

    local baseItem = QueryBuilder.new('base_items'):where('name', slotConfig.item):firstSync()
    if not baseItem then
        print('[VendingMachine] WARNING: slot ' .. code .. ' references unknown base_item "' .. tostring(slotConfig.item) .. '", skipping')
        return
    end

    QueryBuilder.new('vendingmachine_slots'):insert({
        shop_id = shopId,
        code = code,
        base_item_id = baseItem.id,
        price_cents = math.floor((slotConfig.price or 0) * 100 + 0.5),
        stock = slotConfig.stock or 0,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- Must be called exactly once, at boot, after Database.isReady() — see
--- server/main.lua. Not idempotent-safe to call twice per process for the
--- interaction registration side (InteractionService.register doesn't
--- dedupe), but the DB rows it creates are checked first every time.
function VendingMachineSeeder.ensure()
    for _, machine in ipairs(Config.Machines or {}) do
        local shopId = ensureShop(machine)
        for code, slotConfig in pairs(machine.slots or {}) do
            ensureSlot(shopId, code, slotConfig)
        end
    end
end

return VendingMachineSeeder
```

- [ ] **Step 2: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Add VendingMachineSeeder"
```

---

### Task 5: server/main.lua — interaction registration, action, net events

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/server/main.lua`

**Interfaces:**
- Consumes: `VendingMachineService.*` (Task 3), `VendingMachineSeeder.ensure()` (Task 4), `InteractionService.register`, `ActionService.register`, `WebView.openPage`/`WebView.focus`, `Obelisk.onServer`/`Obelisk.emitClient`, `NotificationService.notify`, `QueryBuilder`, `Database.isReady()`.
- Produces net events the client (Task 6) relays to/from: server listens on `vendingmachine:client:insertNote`, `vendingmachine:client:purchase`, `vendingmachine:client:refund`, `vendingmachine:client:close`; emits `vendingmachine:server:sync`, `vendingmachine:server:insertNoteResult`, `vendingmachine:server:purchaseResult`, `vendingmachine:server:refundResult`.

- [ ] **Step 1: Write `server/main.lua`**

```lua
-- core/plugins/oblsk_vendingmachine/server/main.lua
print('[VendingMachine] Loading...')

local function openForSource(source, shopId)
    local shop = QueryBuilder.new('vendingmachine_shops'):where('id', shopId):firstSync()
    if not shop then return end

    local slots = VendingMachineService.list(shopId)
    local credit = VendingMachineService.getCredit(source, shopId)

    WebView.openPage(source, '/VendingMachine')
    WebView.focus(source)
    Obelisk.emitClient('vendingmachine:server:sync', source, { shop = shop, slots = slots, credit = credit })
end

ActionService.register('vendingmachine:open', function(source, data)
    local shopId = data and data.interaction and data.interaction.options and data.interaction.options.shopId
    if not shopId then return end
    openForSource(source, shopId)
end, { label = 'Use vending machine' })

--- Registers every configured machine's interaction point. Must be called
--- exactly once, at boot, after VendingMachineSeeder.ensure() has created
--- the rows this reads. InteractionService.register does NOT dedupe, so
--- calling this twice would put duplicate world prompts at every machine.
local function registerAllMachines()
    local shops = QueryBuilder.new('vendingmachine_shops'):getSync()
    for _, shop in ipairs(shops) do
        local interaction = QueryBuilder.new('interactions'):where('id', shop.interaction_id):firstSync()
        if interaction then
            InteractionService.register({
                x = interaction.x, y = interaction.y, z = interaction.z,
                range = interaction.range, label = interaction.label or shop.name,
                action = 'vendingmachine:open',
                options = { shopId = shop.id },
            })
        end
    end
end

local function notifyFailure(source, title, reason)
    NotificationService.notify(source, {
        type = 'error',
        title = title,
        description = reason or 'Something went wrong',
    })
end

Obelisk.onServer('vendingmachine:client:insertNote', function(shopId, noteValue)
    local source = source
    local ok, result = VendingMachineService.insertNote(source, shopId, noteValue)
    if ok then
        Obelisk.emitClient('vendingmachine:server:insertNoteResult', source, { ok = true, credit = result.credit, rejected = result.rejected, noteValue = noteValue })
    else
        notifyFailure(source, 'Note not accepted', result)
        Obelisk.emitClient('vendingmachine:server:insertNoteResult', source, { ok = false, reason = result })
    end
end)

Obelisk.onServer('vendingmachine:client:purchase', function(shopId, code)
    local source = source
    local ok, result = VendingMachineService.purchase(source, shopId, code)
    if ok then
        Obelisk.emitClient('vendingmachine:server:purchaseResult', source, { ok = true, code = code, itemName = result.itemName, remainingCredit = result.remainingCredit })
    else
        Obelisk.emitClient('vendingmachine:server:purchaseResult', source, { ok = false, code = code, reason = result })
    end
end)

Obelisk.onServer('vendingmachine:client:refund', function(shopId)
    local source = source
    local ok, amount = VendingMachineService.refund(source, shopId)
    Obelisk.emitClient('vendingmachine:server:refundResult', source, { ok = ok, amount = amount })
end)

-- Fired when the UI closes (ESC / dismiss) so any leftover credit is
-- returned instead of silently vanishing - see spec's "no dupe, no silent
-- loss" rule.
Obelisk.onServer('vendingmachine:client:close', function(shopId)
    local source = source
    VendingMachineService.refund(source, shopId)
end)

AddEventHandler('playerDropped', function()
    local source = source
    for _, shop in ipairs(QueryBuilder.new('vendingmachine_shops'):getSync()) do
        VendingMachineService.refund(source, shop.id)
    end
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    VendingMachineSeeder.ensure()
    registerAllMachines()
    print('[VendingMachine] Loaded successfully!')
end)
```

- [ ] **Step 2: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Wire vendingmachine server main: interactions, action, net events"
```

---

### Task 6: client/main.lua — pure relay

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/client/main.lua`

**Interfaces:**
- Consumes: `WebView.on`, `WebView.emitServer`, `WebView.emit`, `Obelisk.onClient`.
- Produces: NUI-facing events the Vue page (Task 7) listens for: `vendingmachine:sync`, `vendingmachine:insertNoteResult`, `vendingmachine:purchaseResult`, `vendingmachine:refundResult`. Listens for NUI-emitted `vendingmachine:insertNote`, `vendingmachine:purchase`, `vendingmachine:refund`, `vendingmachine:close`.

- [ ] **Step 1: Write `client/main.lua`**

```lua
-- core/plugins/oblsk_vendingmachine/client/main.lua
--- VendingMachine Plugin - Client Main
---
--- Pure relay between the NUI page and the server, same posture as
--- oblsk_cardealer's client/main.lua. All validation/mutation happens
--- server-side in VendingMachineService.

WebView.on('vendingmachine:insertNote', function(data)
    WebView.emitServer('vendingmachine:client:insertNote', data.shopId, data.noteValue)
end)

WebView.on('vendingmachine:purchase', function(data)
    WebView.emitServer('vendingmachine:client:purchase', data.shopId, data.code)
end)

WebView.on('vendingmachine:refund', function(data)
    WebView.emitServer('vendingmachine:client:refund', data.shopId)
end)

WebView.on('vendingmachine:close', function(data)
    WebView.emitServer('vendingmachine:client:close', data.shopId)
end)

Obelisk.onClient('vendingmachine:server:sync', function(payload)
    WebView.emit('vendingmachine:sync', payload)
end)

Obelisk.onClient('vendingmachine:server:insertNoteResult', function(payload)
    WebView.emit('vendingmachine:insertNoteResult', payload)
end)

Obelisk.onClient('vendingmachine:server:purchaseResult', function(payload)
    WebView.emit('vendingmachine:purchaseResult', payload)
end)

Obelisk.onClient('vendingmachine:server:refundResult', function(payload)
    WebView.emit('vendingmachine:refundResult', payload)
end)
```

- [ ] **Step 2: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Add vendingmachine client relay"
```

---

### Task 7: VendingMachine.vue — 1:1 UI port with all animations

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/web/VendingMachine.vue`
- Create: `core/plugins/oblsk_vendingmachine/web/routes.js`

**Interfaces:**
- Consumes: `Obelisk.emit`/`Obelisk.on`/`Obelisk.off` (web-side net wrapper, same import path as `CarDealer.vue`: `'../../../web/src/obelisk.js'`), `loadFormatSettings`/`formatCurrency` from `'../../../web/src/composables/useFormatSettings.js'`.
- Produces: mounts at route `/VendingMachine` (Task 5's `WebView.openPage(source, '/VendingMachine')` opens this).

- [ ] **Step 1: Write `web/routes.js`**

```js
// plugins/oblsk_vendingmachine/web/routes.js
export default [
  {
    path: '/VendingMachine',
    name: 'VendingMachine',
    component: () => import('./VendingMachine.vue')
  }
]
```

- [ ] **Step 2: Write `web/VendingMachine.vue`**

Port every visual element and animation from `src/proto/vending.jsx` (already in this conversation's context — the shelves grid, keypad, note acceptor with feed/scan/reject-spit, delivery bay with belt + collection nook, and the `fly` state machine driving the vend item's fall→land→ride sequence) into Vue `<script setup>` idiom, following `CarDealer.vue`'s structure (dev-fixture-under-`import.meta.env.DEV`, `Obelisk.emit`/`on`/`off` for the net bridge, `formatCurrency`/`loadFormatSettings` for money display, ESC-key dismiss, ported CSS keyframes in a `<style>` block using the same class-name-to-keyframe convention as the prototype).

Key behavioral differences from the prototype (server-authoritative, per this plan's Task 3/5 wiring — implementer must wire these, not the prototype's local-only `useState` simulation):
- `slots` and `credit` come from the `vendingmachine:sync` event (server truth), not a local `VM_SLOTS` constant.
- Pressing a note button (`insert(v)` in the prototype) emits `Obelisk.emit('vendingmachine:insertNote', { shopId, noteValue: v })` instead of mutating local credit directly; the feed/scan animation plays optimistically while waiting for `vendingmachine:insertNoteResult`, then resolves to either the credit bump or the reject-spit animation based on `result.rejected`.
- Pressing VEND (`buy()` in the prototype) emits `Obelisk.emit('vendingmachine:purchase', { shopId, code: entry })`; the drop/fall/ride animation plays optimistically, then `vendingmachine:purchaseResult` either confirms (bay gets the item card) or the UI shows the failure message from `result.reason` (e.g. `'ADD $1.00 MORE'`, `'A2 SOLD OUT'`) without adding anything to the bay.
- RETURN (`refund()`) emits `Obelisk.emit('vendingmachine:refund', { shopId })`, resolves via `vendingmachine:refundResult`.
- ESC/dismiss emits `Obelisk.emit('vendingmachine:close', { shopId })` then `Obelisk.emit('core:client:close')`, mirroring `CarDealer.vue`'s `dismiss()`.
- Local `slots` state is patched from `vendingmachine:purchaseResult`'s implied stock decrement (or simply re-synced — either approach is fine; re-syncing the single affected slot's stock down by 1 client-side on success is simplest and matches what the server actually did).

Write the full component now, structurally mirroring `CarDealer.vue` (imports, dev fixture pattern, `onMounted`/`onBeforeUnmount` event wiring, ESC handling) and visually/animation-wise mirroring `src/proto/vending.jsx` exactly — same DOM structure, same Tailwind utility classes, same inline styles, same `@keyframes` block (`vmDrop`, `vmSpit`, `vmScan`, `vmChute`, `vmRide`, `vmBelt`, `vmFeed`), same `fly` ref-based state machine for the vend animation (using `faceRef`/`nookRef` template refs + `getBoundingClientRect()` exactly as the prototype does, translated from React refs to Vue `ref()` + `template ref`).

- [ ] **Step 3: Start the web dev server and visually smoke-test**

```bash
cd core/web && npm run dev
```

Navigate to `/VendingMachine` in the browser (dev fixture renders since `import.meta.env.DEV` is true). Confirm:
- All 5 shelf rows (A-E) render with correct codes/prices.
- Pressing a note button plays the feed animation and updates CREDIT.
- Entering a code (click a product or press A-E then 1-4) highlights it, VEND enables.
- VEND plays the full fall→land→ride animation and the item lands in the delivery bay.
- SOLD OUT slot shows the overlay and can't be selected/bought.
- RETURN clears credit.
- ESC closes.

- [ ] **Step 4: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Port VendingMachine.vue with full animation set"
```

---

### Task 8: README and final integration check

**Files:**
- Create: `core/plugins/oblsk_vendingmachine/README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# oblsk_vendingmachine

Vending machine plugin for the Obelisk framework, ported 1:1 from the `claude.ai/design` prototype (`src/proto/vending.jsx`). Loads as part of `core`; restart `core` (or the whole server) to pick up changes.

## Setup

Machines are entirely config-driven — edit `shared/config.lua`'s `Config.Machines`:

```lua
Config.Machines = {
    {
        name = 'Break Room Vending',
        x = 215.0, y = -800.0, z = 30.7,
        range = 1.5,
        label = 'Vending Machine',
        slots = {
            A1 = { item = 'Chilli Ranch Chaser', price = 1.00, stock = 10 },
            -- ...
        },
    },
}
```

`item` must match an existing `base_items.name` (see `oblsk_items`) — machines sell real catalog items, not a new item type. On boot, `VendingMachineSeeder` creates the `interactions` + `vendingmachine_shops` + `vendingmachine_slots` rows for any machine/slot that doesn't already exist. It **never overwrites** an existing slot row, so live stock/price you've since changed in the DB survives restarts — edit the DB directly (or add an admin tool later) to restock/reprice after first boot, not the config.

## Notes

- Payment is cash-only (matches the design prototype — no card reader). Credit is tracked server-side, in-memory, per player+machine, and is never persisted; any leftover credit is auto-refunded when the UI closes or the player disconnects.
- Every purchase re-resolves the slot server-side (never trusts client-sent price/stock/code) and grants the item straight to inventory via `ItemService.add` the moment it succeeds — the delivery-bay "collect" animation is cosmetic, not a second transaction.
```

- [ ] **Step 2: Run the full test suite once more to confirm nothing regressed**

```bash
lua5.4 core/plugins/oblsk_vendingmachine/tests/vendingmachine_service_spec.lua
```

Expected: `10 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git -C core/plugins/oblsk_vendingmachine add -A
git -C core/plugins/oblsk_vendingmachine commit -m "Add oblsk_vendingmachine README"
```
