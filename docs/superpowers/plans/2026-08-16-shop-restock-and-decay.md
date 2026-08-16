# oblsk_shop Restock, Register Collection, and Safe Decay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `oblsk_shop` the missing pieces a future delivery/money job (and an unattended-server fallback) need: in-game restocking of `shop_stock`, a legitimate NPC-owned-only register-collection path alongside the existing criminal safe-crack, and two Scheduler-consumable fallback actions (auto-refill stale stock, decay uncollected registers).

**Architecture:** Additive changes to the existing `oblsk_shop` plugin — two migrations (new columns on `shop_stock`/`shop_safes`), new `ShopService` functions, two new `ActionService.register`'d actions with no player (designed for `SchedulerService.tick`'s `ActionService.execute(nil, actionId, {})`). No new plugin, no new module.

**Tech Stack:** Lua 5.4 (FXServer), the framework's ORM (`QueryBuilder`/`Schema`, raw — this plugin doesn't use `BaseModel`), `lua5.4` CLI for specs.

**Spec:** `core/docs/superpowers/specs/2026-08-16-shop-restock-and-decay-design.md`

## Global Constraints

- Jobs that will consume this later never carry real items/cash — these functions are atomic, location-scoped state mutations, not a pickup/deliver pair. Don't design any linkage between `restock`'s or `collectRegisterCash`'s effect and a job's payout; that's the future job plugin's own concern via `oblsk_jobs`' flat-rate `job_tasks`.
- Restock: `qty = min(qty + restock_amount, max_qty)`, both admin-configurable per `shop_stock` row.
- Register collection is NPC-owned-only (`shop.organization_id == nil`) — same predicate `SafeCrackingService.withdrawSafe` already uses for the inverse (org-owned) case at `server/services/SafeCrackingService.lua:150`. It coexists with the existing criminal crack path on the same `shop_safes` row.
- Decay is a fixed amount per scheduled run (`cash_amount = max(0, cash_amount - decay_amount)`), NOT a percentage, NOT an all-at-once zero. It never touches `last_collected_at` — only an actual `collectRegisterCash` call does, so decay recurs on every scheduled run for as long as a register stays uncollected (this is intentional, not a bug to fix).
- Both fallback actions (`shop:auto_refill_stale_stock`, `shop:decay_stale_safes`) are plain `ActionService.register`'d actions with no default schedule — an admin wires them up later via the Scheduler tab. Nothing in this plan creates a `scheduled_jobs` row.
- Follow this plugin's existing conventions exactly: raw `QueryBuilder` (no `BaseModel`), `Schema.table(...)` for column-add migrations (see `server/migrations/2026_08_15_220100_add_organization_id_to_shops_table.lua`), tests as standalone `dofile`-chained spec files using `tests/support/fake_query_builder.lua` from the CORE repo (`core/tests/support/fake_query_builder.lua` — this plugin's tests reference the core repo's shared copy directly, it does not keep its own local copy, unlike `oblsk_jobs`/`oblsk_organizations`).

---

## Task 1: Migrations — `shop_stock`/`shop_safes` columns

**Files:**
- Create: `core/plugins/oblsk_shop/server/migrations/2026_08_16_040000_add_restock_columns_to_shop_stock_table.lua`
- Create: `core/plugins/oblsk_shop/server/migrations/2026_08_16_040001_add_decay_columns_to_shop_safes_table.lua`
- Modify: `core/plugins/oblsk_shop/server/migrations.json`
- Modify: `core/plugins/oblsk_shop/tests/shops_migration_spec.lua`

**Interfaces:**
- Produces: `shop_stock.max_qty` (integer), `shop_stock.restock_amount` (integer, default 10), `shop_stock.last_restocked_at` (nullable integer); `shop_safes.decay_amount` (decimal(10,2), default 50), `shop_safes.last_collected_at` (nullable integer). Later tasks' `ShopService` functions read/write these directly via `QueryBuilder`.

- [ ] **Step 1: Write the migrations**

`core/plugins/oblsk_shop/server/migrations/2026_08_16_040000_add_restock_columns_to_shop_stock_table.lua`:

```lua
--- Migration: Add restock columns to shop_stock table
--- max_qty/restock_amount are admin-configurable per item (a water bottle
--- and a carton of cigarettes don't restock the same way). Existing rows'
--- max_qty is backfilled from their current qty right after the column is
--- added, so a shop that already has stock doesn't suddenly cap at 0.
return {
    up = function()
        Schema.table('shop_stock', function(table)
            table:integer('max_qty'):nullable()
            table:integer('restock_amount'):default(10)
            table:integer('last_restocked_at'):nullable()
        end)

        local rows = QueryBuilder.new('shop_stock'):getSync()
        for _, row in ipairs(rows) do
            QueryBuilder.new('shop_stock'):where('id', row.id):update({ max_qty = row.qty })
        end

        print('[Migration] Added restock columns to shop_stock table')
    end,

    down = function()
        Schema.table('shop_stock', function(table)
            table:dropColumn('max_qty')
            table:dropColumn('restock_amount')
            table:dropColumn('last_restocked_at')
        end)
        print('[Migration] Dropped restock columns from shop_stock table')
    end
}
```

`core/plugins/oblsk_shop/server/migrations/2026_08_16_040001_add_decay_columns_to_shop_safes_table.lua`:

```lua
--- Migration: Add decay columns to shop_safes table
--- decay_amount is admin-configurable per shop. last_collected_at is only
--- ever stamped by ShopService.collectRegisterCash (the legit NPC-owned
--- withdrawal) -- decay itself never touches it, so an uncollected safe
--- keeps decaying on every scheduled run for as long as it stays
--- uncollected. That's intentional, see the design spec.
return {
    up = function()
        Schema.table('shop_safes', function(table)
            table:decimal('decay_amount', 10, 2):default(50)
            table:integer('last_collected_at'):nullable()
        end)
        print('[Migration] Added decay columns to shop_safes table')
    end,

    down = function()
        Schema.table('shop_safes', function(table)
            table:dropColumn('decay_amount')
            table:dropColumn('last_collected_at')
        end)
        print('[Migration] Dropped decay columns from shop_safes table')
    end
}
```

- [ ] **Step 2: Register the migrations**

Edit `core/plugins/oblsk_shop/server/migrations.json`, append both migration names (in this order) after `"2026_08_16_030001_create_shop_safe_cooldowns_table"`:

```json
{
  "migrations": [
    "2026_08_12_140000_create_shops_table",
    "2026_08_12_140001_create_shop_stock_table",
    "2026_08_15_220100_add_organization_id_to_shops_table",
    "2026_08_16_030000_create_shop_safes_table",
    "2026_08_16_030001_create_shop_safe_cooldowns_table",
    "2026_08_16_040000_add_restock_columns_to_shop_stock_table",
    "2026_08_16_040001_add_decay_columns_to_shop_safes_table"
  ]
}
```

- [ ] **Step 3: Write the failing test**

Append to `core/plugins/oblsk_shop/tests/shops_migration_spec.lua`, right before the file's final `for _, t in ipairs(tests) do` loop (read the file first to find that exact spot — it follows the same `test(...)`/`captureStatements`/`contains` pattern as the existing test at the top of the file):

```lua
test('shop_stock restock-columns migration adds max_qty/restock_amount/last_restocked_at', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_16_040000_add_restock_columns_to_shop_stock_table.lua')
    local statements = captureStatements(migration.up)
    local sql = table.concat(statements, '\n')
    contains(sql, 'shop_stock')
    contains(sql, 'max_qty')
    contains(sql, 'restock_amount')
    contains(sql, 'last_restocked_at')
end)

test('shop_safes decay-columns migration adds decay_amount/last_collected_at', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_16_040001_add_decay_columns_to_shop_safes_table.lua')
    local statements = captureStatements(migration.up)
    local sql = table.concat(statements, '\n')
    contains(sql, 'shop_safes')
    contains(sql, 'decay_amount')
    contains(sql, 'last_collected_at')
end)
```

Note: `captureStatements` only mocks `Database.querySync` (the `Schema.table` DDL calls) — the migration's post-`Schema.table` backfill loop (`QueryBuilder.new('shop_stock'):getSync()` / `:update(...)`) runs against whatever `QueryBuilder` is live in the test process. Read the top of `shops_migration_spec.lua` again before writing this: if it doesn't already have a fake `QueryBuilder` installed for other tests in the file, `getSync()` will hit a real (nonexistent in this harness) DB connector and error. If that happens, wrap just the `captureStatements(migration.up)` call in this test with the same `withFakeDb`-style swap the other `oblsk_shop` specs use (see `shop_service_purchase_spec.lua` for the pattern) — install an empty fake `shop_stock` table via `tests/support/fake_query_builder.lua` from the core repo (`dofile(ROOT .. '/tests/support/fake_query_builder.lua')`) before calling `migration.up`, so the backfill loop iterates zero rows instead of hitting a real connector.

- [ ] **Step 4: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_shop/tests/shops_migration_spec.lua`
Expected: FAIL — `cannot open .../2026_08_16_040000_add_restock_columns_to_shop_stock_table.lua` (file doesn't exist yet).

- [ ] **Step 5: Run test to verify it passes** (after Step 1's files exist)

Run: `lua5.4 core/plugins/oblsk_shop/tests/shops_migration_spec.lua`
Expected: all tests in the file pass (the file's own total count plus these 2 new ones — read the existing output to know the prior count, then confirm it's prior+2).

- [ ] **Step 6: Commit**

```bash
cd core/plugins/oblsk_shop
git add server/migrations/2026_08_16_040000_add_restock_columns_to_shop_stock_table.lua server/migrations/2026_08_16_040001_add_decay_columns_to_shop_safes_table.lua server/migrations.json tests/shops_migration_spec.lua
git commit -m "feat(shop): add restock/decay columns to shop_stock and shop_safes"
```

---

## Task 2: ShopService.restock

**Files:**
- Modify: `core/plugins/oblsk_shop/server/services/ShopService.lua`
- Create: `core/plugins/oblsk_shop/tests/shop_service_restock_spec.lua`

**Interfaces:**
- Produces: `ShopService.restock(shopId)` — no return value needed (void); for every `shop_stock` row belonging to `shopId`, sets `qty = min(qty + restock_amount, max_qty)` and stamps `last_restocked_at = os.time()`.

- [ ] **Step 1: Write the failing test**

`core/plugins/oblsk_shop/tests/shop_service_restock_spec.lua`:

```lua
-- plugins/oblsk_shop/tests/shop_service_restock_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_shop/tests/shop_service_restock_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

-- ShopService.purchase (already in this file) needs ItemService/SafeCrackingService/
-- BankingService globals to be present at dofile time only if called -- restock
-- doesn't touch any of them, but the file-level `ShopService = {}` and every
-- other function in it still get defined when this file is dofile'd, so no
-- stubs are needed here beyond what QueryBuilder/Database already provide.
dofile(ROOT .. '/plugins/oblsk_shop/server/services/ShopService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('restock: increases qty by restock_amount, capped at max_qty', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Test Shop' })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopId, base_item_id = 1, price = 1, qty = 5, max_qty = 20, restock_amount = 10 })

        ShopService.restock(shopId)

        eq(tables.shop_stock[1].qty, 15)
    end)
end)

test('restock: caps at max_qty rather than overshooting', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Test Shop' })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopId, base_item_id = 1, price = 1, qty = 15, max_qty = 20, restock_amount = 10 })

        ShopService.restock(shopId)

        eq(tables.shop_stock[1].qty, 20)
    end)
end)

test('restock: stamps last_restocked_at', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Test Shop' })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopId, base_item_id = 1, price = 1, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })

        ShopService.restock(shopId)

        eq(tables.shop_stock[1].last_restocked_at ~= nil, true)
    end)
end)

test('restock: touches only the target shop\'s rows', function()
    withFakeDb(function(tables)
        local shopA = QueryBuilder.new('shops'):insert({ name = 'Shop A' })
        local shopB = QueryBuilder.new('shops'):insert({ name = 'Shop B' })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopA, base_item_id = 1, price = 1, qty = 5, max_qty = 20, restock_amount = 10 })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopB, base_item_id = 1, price = 1, qty = 5, max_qty = 20, restock_amount = 10 })

        ShopService.restock(shopA)

        eq(tables.shop_stock[1].qty, 15)
        eq(tables.shop_stock[2].qty, 5)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
    end
end

print(string.format('%d/%d tests passed', passed, #tests))
if #failures > 0 then
    for _, f in ipairs(failures) do
        print(string.format('FAIL: %s\n  %s', f.name, f.err))
    end
    os.exit(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_shop/tests/shop_service_restock_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'restock')`.

- [ ] **Step 3: Write the implementation**

Add to `core/plugins/oblsk_shop/server/services/ShopService.lua`, right after the `ShopService.list` function (before the `resolveLines` local function):

```lua
--- Refills every shop_stock row belonging to shopId by its own
--- restock_amount, capped at its own max_qty. Called by a future
--- delivery-job plugin, an admin action, or the shop:auto_refill_stale_stock
--- scheduled fallback (Task 4).
--- @param shopId number
function ShopService.restock(shopId)
    local rows = QueryBuilder.new('shop_stock'):where('shop_id', shopId):getSync()
    for _, row in ipairs(rows) do
        local newQty = math.min(row.qty + row.restock_amount, row.max_qty)
        QueryBuilder.new('shop_stock'):where('id', row.id):update({
            qty = newQty,
            last_restocked_at = os.time(),
            updated_at = Database.now(),
        })
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_shop/tests/shop_service_restock_spec.lua`
Expected: `4/4 tests passed`

Also re-run the existing purchase/list specs to confirm nothing broke:

Run: `lua5.4 core/plugins/oblsk_shop/tests/shop_service_purchase_spec.lua && lua5.4 core/plugins/oblsk_shop/tests/shop_service_list_spec.lua`
Expected: both print their existing pass counts with no `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_shop
git add server/services/ShopService.lua tests/shop_service_restock_spec.lua
git commit -m "feat(shop): add ShopService.restock"
```

---

## Task 3: ShopService.collectRegisterCash

**Files:**
- Modify: `core/plugins/oblsk_shop/server/services/ShopService.lua`
- Create: `core/plugins/oblsk_shop/tests/shop_service_collect_spec.lua`

**Interfaces:**
- Produces: `ShopService.collectRegisterCash(shopId)` → `boolean ok, string|nil reason`. Rejects `'Shop is not NPC-owned'` if `shops.organization_id` is set on that shop (same predicate as `SafeCrackingService.withdrawSafe`'s inverse check). On success: zeroes `shop_safes.cash_amount`, stamps `last_collected_at = os.time()`. Never grants the player any item/cash — this is a state mutation only, per the plan's Global Constraints.

- [ ] **Step 1: Write the failing test**

`core/plugins/oblsk_shop/tests/shop_service_collect_spec.lua`:

```lua
-- plugins/oblsk_shop/tests/shop_service_collect_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_shop/tests/shop_service_collect_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(ROOT .. '/plugins/oblsk_shop/server/services/ShopService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('collectRegisterCash: zeroes cash_amount and stamps last_collected_at for an NPC-owned shop', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'NPC Shop', organization_id = nil })
        QueryBuilder.new('shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 1000, decay_amount = 50 })

        local ok = ShopService.collectRegisterCash(shopId)

        eq(ok, true)
        eq(tables.shop_safes[1].cash_amount, 0)
        eq(tables.shop_safes[1].last_collected_at ~= nil, true)
    end)
end)

test('collectRegisterCash: rejects an org-owned shop', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Org Shop', organization_id = 7 })
        QueryBuilder.new('shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 1000, decay_amount = 50 })

        local ok, reason = ShopService.collectRegisterCash(shopId)

        eq(ok, false)
        eq(reason, 'Shop is not NPC-owned')
        eq(tables.shop_safes[1].cash_amount, 300)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
    end
end

print(string.format('%d/%d tests passed', passed, #tests))
if #failures > 0 then
    for _, f in ipairs(failures) do
        print(string.format('FAIL: %s\n  %s', f.name, f.err))
    end
    os.exit(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_shop/tests/shop_service_collect_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'collectRegisterCash')`.

- [ ] **Step 3: Write the implementation**

Add to `core/plugins/oblsk_shop/server/services/ShopService.lua`, right after `ShopService.restock`:

```lua
--- Legitimate (non-criminal) register collection for NPC-owned shops only
--- -- the counterpart to SafeCrackingService.withdrawSafe's org-owned path,
--- on the same shop_safes row. Never grants the caller any item/cash: this
--- is a state mutation for a future job plugin to call, not a transfer (see
--- the design spec's "jobs never carry real items" constraint).
--- @param shopId number
--- @return boolean ok
--- @return string|nil reason
function ShopService.collectRegisterCash(shopId)
    local shop = QueryBuilder.new('shops'):where('id', shopId):firstSync()
    if not shop or shop.organization_id then
        return false, 'Shop is not NPC-owned'
    end

    local safe = QueryBuilder.new('shop_safes'):where('shop_id', shopId):firstSync()
    if not safe then
        return false, 'This shop has no safe'
    end

    QueryBuilder.new('shop_safes'):where('id', safe.id):update({
        cash_amount = 0,
        last_collected_at = os.time(),
        updated_at = Database.now(),
    })
    return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_shop/tests/shop_service_collect_spec.lua`
Expected: `2/2 tests passed`

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_shop
git add server/services/ShopService.lua tests/shop_service_collect_spec.lua
git commit -m "feat(shop): add ShopService.collectRegisterCash"
```

---

## Task 4: Scheduler-facing fallback actions

**Files:**
- Modify: `core/plugins/oblsk_shop/server/services/ShopService.lua`
- Modify: `core/plugins/oblsk_shop/server/main.lua`
- Modify: `core/plugins/oblsk_shop/shared/config.lua`
- Create: `core/plugins/oblsk_shop/tests/shop_service_scheduled_actions_spec.lua`

**Interfaces:**
- Consumes: `ShopService.restock` (Task 2); `ShopConfig` (existing global).
- Produces: `ShopService.autoRefillStaleStock()` → `number` (count of shops restocked); `ShopService.decayStaleSafes()` → `number` (count of safes decayed). Both read `ShopConfig.AutoRefillStaleAfterSeconds`/`ShopConfig.SafeDecayAfterSeconds`. `server/main.lua` registers `shop:auto_refill_stale_stock` and `shop:decay_stale_safes` as thin `ActionService.register` wrappers around these two functions — this is the exact shape `SchedulerService.tick`'s `ActionService.execute(nil, actionId, {})` (built in the prior Scheduler slice) is designed to call.

- [ ] **Step 1: Add config thresholds**

Edit `core/plugins/oblsk_shop/shared/config.lua`, add after the existing `ShopConfig.SafeCracking` table (before `return ShopConfig`):

```lua
-- Thresholds for the two Scheduler-consumable fallback actions
-- (shop:auto_refill_stale_stock, shop:decay_stale_safes) registered in
-- server/main.lua. Neither runs on a default schedule -- an admin wires
-- them up via the Scheduler tab. See
-- docs/superpowers/specs/2026-08-16-shop-restock-and-decay-design.md.
ShopConfig.Fallback = {
    -- A shop_stock row is "stale" (eligible for auto-refill) once this many
    -- seconds have passed since its last_restocked_at (or it's never been
    -- restocked at all).
    AutoRefillStaleAfterSeconds = 21600, -- 6 hours

    -- An NPC-owned shop's safe is "stale" (eligible for decay) once this
    -- many seconds have passed since its last_collected_at (or it's never
    -- been collected at all).
    SafeDecayAfterSeconds = 43200, -- 12 hours
}
```

- [ ] **Step 2: Write the failing test**

`core/plugins/oblsk_shop/tests/shop_service_scheduled_actions_spec.lua`:

```lua
-- plugins/oblsk_shop/tests/shop_service_scheduled_actions_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_shop/tests/shop_service_scheduled_actions_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(ROOT .. '/plugins/oblsk_shop/shared/config.lua')
dofile(ROOT .. '/plugins/oblsk_shop/server/services/ShopService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

-- autoRefillStaleStock

test('autoRefillStaleStock: restocks a shop with a never-restocked row', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Test Shop' })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopId, base_item_id = 1, price = 1, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })

        local count = ShopService.autoRefillStaleStock()

        eq(count, 1)
        eq(tables.shop_stock[1].qty, 15)
    end)
end)

test('autoRefillStaleStock: skips a row restocked recently', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Test Shop' })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopId, base_item_id = 1, price = 1, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = os.time() })

        local count = ShopService.autoRefillStaleStock()

        eq(count, 0)
        eq(tables.shop_stock[1].qty, 5)
    end)
end)

test('autoRefillStaleStock: restocks a shop with multiple stale rows only once', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Test Shop' })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopId, base_item_id = 1, price = 1, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })
        QueryBuilder.new('shop_stock'):insert({ shop_id = shopId, base_item_id = 2, price = 1, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })

        local count = ShopService.autoRefillStaleStock()

        eq(count, 1)
        eq(tables.shop_stock[1].qty, 15)
        eq(tables.shop_stock[2].qty, 15)
    end)
end)

-- decayStaleSafes

test('decayStaleSafes: decays a never-collected NPC-owned safe', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'NPC Shop', organization_id = nil })
        QueryBuilder.new('shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 1000, decay_amount = 50, last_collected_at = nil })

        local count = ShopService.decayStaleSafes()

        eq(count, 1)
        eq(tables.shop_safes[1].cash_amount, 250)
    end)
end)

test('decayStaleSafes: floors at 0 rather than going negative', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'NPC Shop', organization_id = nil })
        QueryBuilder.new('shop_safes'):insert({ shop_id = shopId, cash_amount = 20, max_cash = 1000, decay_amount = 50, last_collected_at = nil })

        ShopService.decayStaleSafes()

        eq(tables.shop_safes[1].cash_amount, 0)
    end)
end)

test('decayStaleSafes: skips a safe collected recently', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'NPC Shop', organization_id = nil })
        QueryBuilder.new('shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 1000, decay_amount = 50, last_collected_at = os.time() })

        local count = ShopService.decayStaleSafes()

        eq(count, 0)
        eq(tables.shop_safes[1].cash_amount, 300)
    end)
end)

test('decayStaleSafes: skips org-owned shops even if their safe is stale', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('shops'):insert({ name = 'Org Shop', organization_id = 7 })
        QueryBuilder.new('shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 1000, decay_amount = 50, last_collected_at = nil })

        local count = ShopService.decayStaleSafes()

        eq(count, 0)
        eq(tables.shop_safes[1].cash_amount, 300)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
    end
end

print(string.format('%d/%d tests passed', passed, #tests))
if #failures > 0 then
    for _, f in ipairs(failures) do
        print(string.format('FAIL: %s\n  %s', f.name, f.err))
    end
    os.exit(1)
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_shop/tests/shop_service_scheduled_actions_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'autoRefillStaleStock')`.

- [ ] **Step 4: Write the implementation**

Add to `core/plugins/oblsk_shop/server/services/ShopService.lua`, right after `ShopService.collectRegisterCash` (before the final `return ShopService`):

```lua
--- Restocks every shop that has at least one stale-or-never-restocked
--- shop_stock row, once per shop even if it has several stale rows.
--- Designed to be called with no player context (see server/main.lua's
--- shop:auto_refill_stale_stock action) by SchedulerService.tick.
--- @return number count of shops restocked
function ShopService.autoRefillStaleStock()
    local now = os.time()
    local staleShopIds = {}
    local rows = QueryBuilder.new('shop_stock'):getSync()
    for _, row in ipairs(rows) do
        if not row.last_restocked_at or (now - row.last_restocked_at) >= ShopConfig.Fallback.AutoRefillStaleAfterSeconds then
            staleShopIds[row.shop_id] = true
        end
    end

    local count = 0
    for shopId in pairs(staleShopIds) do
        ShopService.restock(shopId)
        count = count + 1
    end
    return count
end

--- Decays every NPC-owned shop's safe that hasn't been collected within
--- ShopConfig.Fallback.SafeDecayAfterSeconds. Never touches last_collected_at
--- -- only ShopService.collectRegisterCash does -- so an uncollected safe
--- keeps decaying on every scheduled run. Designed to be called with no
--- player context (see server/main.lua's shop:decay_stale_safes action) by
--- SchedulerService.tick.
--- @return number count of safes decayed
function ShopService.decayStaleSafes()
    local now = os.time()
    local safes = QueryBuilder.new('shop_safes'):getSync()

    local count = 0
    for _, safe in ipairs(safes) do
        local shop = QueryBuilder.new('shops'):where('id', safe.shop_id):firstSync()
        if shop and not shop.organization_id then
            if not safe.last_collected_at or (now - safe.last_collected_at) >= ShopConfig.Fallback.SafeDecayAfterSeconds then
                local newAmount = math.max(0, safe.cash_amount - safe.decay_amount)
                QueryBuilder.new('shop_safes'):where('id', safe.id):update({
                    cash_amount = newAmount,
                    updated_at = Database.now(),
                })
                count = count + 1
            end
        end
    end
    return count
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_shop/tests/shop_service_scheduled_actions_spec.lua`
Expected: `6/6 tests passed`

Also re-run every other spec in this plugin to confirm nothing broke:

Run: `for f in core/plugins/oblsk_shop/tests/*.lua; do lua5.4 "$f"; done`
Expected: every file prints its own full pass count, no `FAIL:` lines anywhere.

- [ ] **Step 6: Wire the two ActionService actions**

In `core/plugins/oblsk_shop/server/main.lua`, add after the existing `ActionService.register('shop:crackSafe', ...)` block (before `local function registerAllShops()`):

```lua
--- No player context -- called by SchedulerService.tick's
--- ActionService.execute(nil, actionId, {}) once an admin wires up a
--- scheduled_jobs row for this action_id via the Scheduler tab. Never
--- scheduled by default (see shared/config.lua's ShopConfig.Fallback
--- comment).
ActionService.register('shop:auto_refill_stale_stock', function()
    local count = ShopService.autoRefillStaleStock()
    print('[Shop] auto_refill_stale_stock: restocked ' .. count .. ' shop(s)')
end, { label = 'Auto-refill stale shop stock' })

ActionService.register('shop:decay_stale_safes', function()
    local count = ShopService.decayStaleSafes()
    print('[Shop] decay_stale_safes: decayed ' .. count .. ' safe(s)')
end, { label = 'Decay uncollected shop safes' })
```

- [ ] **Step 7: Verify main.lua still parses**

Run: `cd core/plugins/oblsk_shop && lua5.4 -e "assert(loadfile('server/main.lua'))" && echo OK`
Expected: `OK`

- [ ] **Step 8: Commit**

```bash
cd core/plugins/oblsk_shop
git add server/services/ShopService.lua server/main.lua shared/config.lua tests/shop_service_scheduled_actions_spec.lua
git commit -m "feat(shop): add scheduler-consumable auto-refill and safe-decay actions"
```

---

## Plan Self-Review Notes

- **Spec coverage:** data model (Task 1), `ShopService.restock` (Task 2), `ShopService.collectRegisterCash` (Task 3), both scheduler-facing actions + config thresholds (Task 4) — every section of the spec has a task. The spec's testing list (restock caps/stamps, collect rejects org-owned/zeroes+stamps for NPC-owned, auto-refill restocks-nil/stale-skips-fresh-dedupes-per-shop, decay decays-nil/stale-skips-fresh-skips-org-owned-floors-at-0) is fully covered across Tasks 1-4's specs.
- **Type consistency:** `ShopService.restock(shopId)` (Task 2) is reused unchanged by `ShopService.autoRefillStaleStock()` (Task 4) — same signature, no drift. `collectRegisterCash`'s `(ok, reason)` return matches the two-value convention used throughout this codebase (`ShopService.purchase`, `Jobs.completeTask`, etc.).
- **No placeholders:** every step has full code, no TODOs.
