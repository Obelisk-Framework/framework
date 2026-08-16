# oblsk_clothesshop Stock, Register, and Safe Decay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `oblsk_clothesshop` the same missing pieces the `oblsk_shop` slice just added to the 24/7: in-game restocking, a legitimate NPC-owned register-collection path, and Scheduler-consumable fallback actions — plus the ownership column and stock/register concepts this plugin never had at all (unlike `oblsk_shop`, which already had most of the scaffolding).

**Architecture:** Additive changes to the existing `oblsk_clothesshop` plugin, mirroring the `oblsk_shop` slice's shape: new migrations (ownership column, stock columns on the purchasable leaf, a new safes table), new `ClothesShopService` functions, two new `ActionService.register`'d actions with no player. One real behavior change: `ClothesShopService.purchase` becomes stock-limited (it currently has no stock check at all).

**Tech Stack:** Lua 5.4 (FXServer), the framework's ORM (`QueryBuilder`/`Schema`, raw — no `BaseModel`), `lua5.4` CLI for specs.

**Spec:** `core/docs/superpowers/specs/2026-08-16-clothesshop-stock-and-register-design.md`

## Global Constraints

- Stock lives on `clothes_shop_item_variants` (the actual purchasable leaf — each color/texture of a garment sells independently), NOT on `clothes_shop_items`.
- **Lesson from the `oblsk_shop` slice's final review**: that slice's two new scheduler-only actions were initially reachable by any client via `core:client:action-execute` with no gate, and one was exploitable (a looping player could drain every shop's register). This plan's Task 5 builds the `if player then return end` guard in as the FIRST statement of both new handlers from the start — do not ship them unguarded even temporarily.
- **Lesson from the `oblsk_shop` slice's final review**: `max_qty`/similar columns must never be nullable-with-no-default — a NULL there crashed `restock` and silently broke the auto-refill fallback for every shop after the crashing one in iteration order. This plan's Task 1 migration makes `qty`/`max_qty` `NOT NULL DEFAULT 20` from the start (no backfill loop needed at all, unlike `oblsk_shop`, since this column is entirely new — there's no pre-existing `qty` data to preserve).
- Decay is a fixed amount per scheduled run, never touches `last_collected_at` (only `collectRegisterCash` does — decay recurs every scheduled run while uncollected, intentional). Restock is a fixed amount per call, capped at `max_qty`.
- `oblsk_clothingshops`' `clothing_shops` table (a separate plugin) is NOT reused for ownership here — it's an unrelated abstract business-investment record consumed by `oblsk_globalmarket`. This plan adds its own `organization_id` directly to `clothes_shops`, exactly mirroring `oblsk_shop`'s `shops.organization_id` pattern.
- `ActionService`'s registry is global across every plugin in the single Lua state — the two new action ids in this plan (`clothesshop:auto_refill_stale_stock`, `clothesshop:decay_stale_safes`) must not collide with `oblsk_shop`'s `shop:*` ones (they don't — different prefix).
- Follow this plugin's existing conventions exactly: raw `QueryBuilder` (no `BaseModel`), `Schema.table(...)` for column-add migrations, `Database.transaction`/raw SQL `UPDATE` for the stock-decrement-alongside-grant step (mirroring `oblsk_shop`'s `ShopService.grantAndDecrement`), tests as standalone `dofile`-chained spec files using `tests/support/fake_query_builder.lua` from the CORE repo directly (this plugin does not keep its own local copy).
- `server/main.lua`'s `ActionService.register` wiring has no automated test in this plugin (same as `oblsk_shop`) — a `loadfile` syntax check plus the per-task reviewer reading the code is the verification bar for that file, consistent with established convention.

---

## Task 1: Migrations — ownership, stock columns, safes table

**Files:**
- Create: `core/plugins/oblsk_clothesshop/server/migrations/2026_08_16_050000_add_organization_id_to_clothes_shops_table.lua`
- Create: `core/plugins/oblsk_clothesshop/server/migrations/2026_08_16_050001_add_stock_columns_to_clothes_shop_item_variants_table.lua`
- Create: `core/plugins/oblsk_clothesshop/server/migrations/2026_08_16_050002_create_clothes_shop_safes_table.lua`
- Modify: `core/plugins/oblsk_clothesshop/server/migrations.json`
- Modify: `core/plugins/oblsk_clothesshop/tests/clothes_shop_migrations_spec.lua`

**Interfaces:**
- Produces: `clothes_shops.organization_id` (nullable FK, `organizations`, `SET NULL` on delete); `clothes_shop_item_variants.qty`/`max_qty` (integer, `NOT NULL DEFAULT 20`), `restock_amount` (integer, `NOT NULL DEFAULT 10`), `last_restocked_at` (nullable integer, unix epoch); `clothes_shop_safes` table (`shop_id` unique FK, `cash_amount`/`max_cash`/`decay_amount` decimals, `last_collected_at` nullable integer). Later tasks' `ClothesShopService` functions read/write these directly.

- [ ] **Step 1: Write the migrations**

`core/plugins/oblsk_clothesshop/server/migrations/2026_08_16_050000_add_organization_id_to_clothes_shops_table.lua`:

```lua
--- Migration: Add organization_id to clothes_shops table
--- Mirrors oblsk_shop's shops.organization_id exactly -- nil means
--- NPC-owned. NOT the same thing as oblsk_clothingshops' clothing_shops
--- table (an unrelated abstract business-investment record consumed by
--- oblsk_globalmarket) -- this is real per-storefront ownership.
return {
    up = function()
        Schema.table('clothes_shops', function(table)
            table:foreignId('organization_id'):nullable():constrained('organizations'):onDelete('SET NULL')
        end)
        print('[Migration] Added organization_id to clothes_shops table')
    end,

    down = function()
        Schema.table('clothes_shops', function(table)
            table:dropColumn('organization_id')
        end)
        print('[Migration] Dropped organization_id from clothes_shops table')
    end
}
```

`core/plugins/oblsk_clothesshop/server/migrations/2026_08_16_050001_add_stock_columns_to_clothes_shop_item_variants_table.lua`:

```lua
--- Migration: Add stock columns to clothes_shop_item_variants table
--- Deliberately NOT NULL with DB-level defaults (unlike a nullable
--- backfilled column) -- this data is entirely new, there's no pre-existing
--- qty to preserve, so every row (existing or future) gets a real,
--- non-null qty/max_qty from the moment this migration runs. No backfill
--- loop needed.
return {
    up = function()
        Schema.table('clothes_shop_item_variants', function(table)
            table:integer('qty'):default(20)
            table:integer('max_qty'):default(20)
            table:integer('restock_amount'):default(10)
            table:integer('last_restocked_at'):nullable()
        end)
        print('[Migration] Added stock columns to clothes_shop_item_variants table')
    end,

    down = function()
        Schema.table('clothes_shop_item_variants', function(table)
            table:dropColumn('qty')
            table:dropColumn('max_qty')
            table:dropColumn('restock_amount')
            table:dropColumn('last_restocked_at')
        end)
        print('[Migration] Dropped stock columns from clothes_shop_item_variants table')
    end
}
```

`core/plugins/oblsk_clothesshop/server/migrations/2026_08_16_050002_create_clothes_shop_safes_table.lua`:

```lua
--- Migration: Create clothes_shop_safes table
--- Mirrors oblsk_shop's shop_safes. Unlike that plugin, there's no
--- criminal crack path here in this slice -- only legit NPC-owned
--- collection (ClothesShopService.collectRegisterCash) and scheduled
--- decay.
return {
    up = function()
        Schema.create('clothes_shop_safes', function(table)
            table:id()
            table:foreignId('shop_id'):constrained('clothes_shops'):onDelete('CASCADE')
            table:decimal('cash_amount', 12, 2):default(0)
            table:decimal('max_cash', 12, 2):default(15000)
            table:decimal('decay_amount', 10, 2):default(50)
            table:integer('last_collected_at'):nullable()
            table:timestamps()

            table:unique({ 'shop_id' })
        end)
        print('[Migration] Created clothes_shop_safes table')
    end,

    down = function()
        Schema.drop('clothes_shop_safes')
        print('[Migration] Dropped clothes_shop_safes table')
    end
}
```

- [ ] **Step 2: Register the migrations**

Edit `core/plugins/oblsk_clothesshop/server/migrations.json`, append all three names (in this order) after `"2026_08_15_180003_create_character_equipped_clothing_table"`:

```json
{
  "migrations": [
    "2026_08_15_180000_create_clothes_shops_table",
    "2026_08_15_180001_create_clothes_shop_items_table",
    "2026_08_15_180002_create_clothes_shop_item_variants_table",
    "2026_08_15_180003_create_character_equipped_clothing_table",
    "2026_08_16_050000_add_organization_id_to_clothes_shops_table",
    "2026_08_16_050001_add_stock_columns_to_clothes_shop_item_variants_table",
    "2026_08_16_050002_create_clothes_shop_safes_table"
  ]
}
```

- [ ] **Step 3: Write the failing test**

Append to `core/plugins/oblsk_clothesshop/tests/clothes_shop_migrations_spec.lua`, right before the file's final `for _, t in ipairs(tests) do` loop (read the file first — it follows the `test(...)`/`captureStatements`/`contains` pattern shown at the top):

```lua
test('clothes_shops organization_id migration adds the column', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_16_050000_add_organization_id_to_clothes_shops_table.lua')
    local sql = table.concat(captureStatements(migration.up), '\n')
    contains(sql, 'clothes_shops')
    contains(sql, 'organization_id')
end)

test('clothes_shop_item_variants stock-columns migration adds qty/max_qty/restock_amount/last_restocked_at', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_16_050001_add_stock_columns_to_clothes_shop_item_variants_table.lua')
    local sql = table.concat(captureStatements(migration.up), '\n')
    contains(sql, 'clothes_shop_item_variants')
    contains(sql, 'qty')
    contains(sql, 'max_qty')
    contains(sql, 'restock_amount')
    contains(sql, 'last_restocked_at')
end)

test('clothes_shop_safes migration creates the table with a unique shop_id', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_16_050002_create_clothes_shop_safes_table.lua')
    local sql = table.concat(captureStatements(migration.up), '\n')
    contains(sql, 'clothes_shop_safes')
    contains(sql, 'cash_amount')
    contains(sql, 'shop_id')
end)
```

- [ ] **Step 4: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_migrations_spec.lua`
Expected: FAIL — `cannot open .../2026_08_16_050000_add_organization_id_to_clothes_shops_table.lua`.

- [ ] **Step 5: Run test to verify it passes** (after Step 1's files exist)

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_migrations_spec.lua`
Expected: prior count + 3, all passing, no `FAIL:` lines.

- [ ] **Step 6: Commit**

```bash
cd core/plugins/oblsk_clothesshop
git add server/migrations/2026_08_16_050000_add_organization_id_to_clothes_shops_table.lua server/migrations/2026_08_16_050001_add_stock_columns_to_clothes_shop_item_variants_table.lua server/migrations/2026_08_16_050002_create_clothes_shop_safes_table.lua server/migrations.json tests/clothes_shop_migrations_spec.lua
git commit -m "feat(clothesshop): add organization_id, stock columns, and clothes_shop_safes table"
```

---

## Task 2: Purchase becomes stock-limited

**Files:**
- Modify: `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`
- Modify: `core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua`

**Interfaces:**
- Modifies: `ClothesShopService.purchase` — now rejects `'Not enough stock'` when a cart line's variant has `qty <= 0`, and decrements each purchased variant's `qty` by 1 inside a `Database.transaction`, alongside the existing item-grant step. This is a real behavior change — purchase was previously unlimited.
- Produces: a private `decrementAndGrant(source, resolved)` local function replacing the old inline grant loop, mirroring `oblsk_shop`'s `ShopService.grantAndDecrement`.

- [ ] **Step 1: Update the shared test fixture and add the failing tests**

Read `core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua` first — every existing test shares one `withFreshState` fixture with 3 `clothes_shop_item_variants` rows (ids 100, 101, 102). Add `qty = 20` to all three rows in that fixture (so every existing test keeps passing once the stock check exists — none of them are testing depletion, they just need non-zero stock to not spuriously fail):

```lua
clothes_shop_item_variants = {
    { id = 100, item_id = 10, texture_id = 0, color_label = 'White', qty = 20 },
    { id = 101, item_id = 11, texture_id = 1, color_label = 'Blue', qty = 20 },
    { id = 102, item_id = 10, texture_id = 2, color_label = 'Black', qty = 20 },
},
```

Add a `Database.executeQuery` fake right after the file's existing `dofile(scriptDir .. '../server/services/ClothesShopService.lua')` line, mirroring `oblsk_shop`'s `tests/shop_service_purchase_spec.lua` (read that file for the exact pattern — same trick, different table/column names):

```lua
Database.executeQuery = function(query, params)
    if query:find('UPDATE clothes_shop_item_variants', 1, true) then
        local updatedAt, id = params[1], params[2]
        local row = QueryBuilder.new('clothes_shop_item_variants'):where('id', id):firstSync()
        if not row then return { affectedRows = 0 } end
        row.qty = row.qty - 1
        row.updated_at = updatedAt
        return { affectedRows = 1 }
    end
    return {}
end
```

Add these new tests (append near the end, before the file's final test-runner loop):

```lua
test('cash purchase rejected: variant is out of stock, nothing granted or decremented', function()
    withFreshState(function()
        QueryBuilder.new('clothes_shop_item_variants'):where('id', 100):update({ qty = 0 })
        local ok, reason = ClothesShopService.purchase(999, 1, { { itemId = 10, variantId = 100 } }, 'cash')
        eq(ok, false)
        eq(reason, 'Not enough stock')
        eq(#granted, 0)
    end)
end)

test('cash purchase decrements the purchased variant qty by 1', function()
    withFreshState(function()
        ClothesShopService.purchase(999, 1, { { itemId = 10, variantId = 100 } }, 'cash')
        local row = QueryBuilder.new('clothes_shop_item_variants'):where('id', 100):firstSync()
        eq(row.qty, 19)
    end)
end)

test('cash purchase with multiple lines decrements each line\'s own variant independently', function()
    withFreshState(function()
        ClothesShopService.purchase(999, 1, {
            { itemId = 10, variantId = 100 },
            { itemId = 11, variantId = 101 },
        }, 'cash')
        eq(QueryBuilder.new('clothes_shop_item_variants'):where('id', 100):firstSync().qty, 19)
        eq(QueryBuilder.new('clothes_shop_item_variants'):where('id', 101):firstSync().qty, 19)
    end)
end)
```

- [ ] **Step 2: Run test to verify the new tests fail**

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua`
Expected: FAIL — the out-of-stock test fails because `resolveLine` doesn't check `qty` yet (purchase still succeeds), and the decrement tests fail because `qty` never changes.

- [ ] **Step 3: Write the implementation**

In `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`, modify `resolveLine` to add the stock check:

```lua
--- @param shopId number
--- @param itemId number
--- @param variantId number
--- @return table|nil resolved { itemRow, variantRow }, string|nil reason
local function resolveLine(shopId, itemId, variantId)
    local itemRow = QueryBuilder.new('clothes_shop_items'):where('id', itemId):where('shop_id', shopId):firstSync()
    if not itemRow then
        return nil, 'Item no longer available'
    end
    local variantRow = QueryBuilder.new('clothes_shop_item_variants'):where('id', variantId):where('item_id', itemId):firstSync()
    if not variantRow then
        return nil, 'Item no longer available'
    end
    if variantRow.qty <= 0 then
        return nil, 'Not enough stock'
    end
    return { itemRow = itemRow, variantRow = variantRow }, nil
end
```

Add a new local function right after `resolveCart` (before `ClothesShopService.purchase`):

```lua
--- Decrements each line's variant qty and grants the purchased item, both
--- after payment has already succeeded -- this step failing would be a
--- DB-level surprise, not an expected business rejection. Mirrors
--- ShopService.grantAndDecrement in oblsk_shop.
--- @param source number
--- @param resolved table[] from resolveCart
--- @return boolean, string|nil reason
local function decrementAndGrant(source, resolved)
    local ok = Database.transaction(function(tx)
        for _, line in ipairs(resolved) do
            tx:add('UPDATE clothes_shop_item_variants SET qty = qty - 1, updated_at = ? WHERE id = ?',
                { Database.now(), line.variantRow.id })
        end
    end)
    if not ok then return false end

    for _, line in ipairs(resolved) do
        local granted, grantReason = ItemService.add(source, { id = line.itemRow.base_item_id }, 1, {
            componentId = line.itemRow.component_id,
            drawableId = line.itemRow.drawable_id,
            textureId = line.variantRow.texture_id,
            category = line.itemRow.category,
        }, true)
        if not granted then
            print(('[ClothesShop] WARNING: item grant failed after payment for source %s, base_item_id %s: %s')
                :format(tostring(source), tostring(line.itemRow.base_item_id), tostring(grantReason)))
            return false, grantReason or 'Purchase failed'
        end
    end
    return true
end
```

Replace `ClothesShopService.purchase`'s final block — everything from the `-- No Database.transaction here ...` comment through the closing `return true` — with:

```lua
    local ok, grantReason = decrementAndGrant(source, resolved)
    if not ok then
        return false, grantReason or 'Purchase failed'
    end

    return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua`
Expected: all tests pass (prior count + 3), no `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_clothesshop
git add server/services/ClothesShopService.lua tests/clothes_shop_service_spec.lua
git commit -m "feat(clothesshop): make purchase stock-limited"
```

---

## Task 3: Register accrual, safe seeder, restock

**Files:**
- Modify: `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`
- Create: `core/plugins/oblsk_clothesshop/server/services/ClothesShopSafeSeeder.lua`
- Modify: `core/plugins/oblsk_clothesshop/server/main.lua`
- Modify: `core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua`
- Create: `core/plugins/oblsk_clothesshop/tests/clothes_shop_restock_spec.lua`
- Create: `core/plugins/oblsk_clothesshop/tests/clothes_shop_safe_seeder_spec.lua`

**Interfaces:**
- Produces: `ClothesShopService.accrueRevenue(shopId, amount)` — adds to `clothes_shop_safes.cash_amount`, capped at `max_cash`; called by `purchase` on every successful sale (any payment method), mirroring `oblsk_shop`'s `SafeCrackingService.accrueRevenue` call site.
- Produces: `ClothesShopService.restock(shopId)` — tops up every variant row of every item belonging to `shopId`.
- Produces: `ClothesShopSafeSeeder.ensure()` — idempotent, mirrors `oblsk_shop`'s `SafeSeeder.ensure()`. Wired into `server/main.lua`'s boot thread.

- [ ] **Step 1: Write the failing tests**

`core/plugins/oblsk_clothesshop/tests/clothes_shop_restock_spec.lua`:

```lua
-- plugins/oblsk_clothesshop/tests/clothes_shop_restock_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_clothesshop/tests/clothes_shop_restock_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(ROOT .. '/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua')

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

test('restock: tops up every variant of every item in the shop, capped at max_qty', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'Test Shop' })
        local itemId = QueryBuilder.new('clothes_shop_items'):insert({ shop_id = shopId, base_item_id = 1, category = 'tshirt', name = 'Tee', component_id = 8, drawable_id = 1, price = 10 })
        QueryBuilder.new('clothes_shop_item_variants'):insert({ item_id = itemId, texture_id = 0, qty = 5, max_qty = 20, restock_amount = 10 })
        QueryBuilder.new('clothes_shop_item_variants'):insert({ item_id = itemId, texture_id = 1, qty = 15, max_qty = 20, restock_amount = 10 })

        ClothesShopService.restock(shopId)

        eq(tables.clothes_shop_item_variants[1].qty, 15)
        eq(tables.clothes_shop_item_variants[2].qty, 20) -- capped
    end)
end)

test('restock: stamps last_restocked_at', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'Test Shop' })
        local itemId = QueryBuilder.new('clothes_shop_items'):insert({ shop_id = shopId, base_item_id = 1, category = 'tshirt', name = 'Tee', component_id = 8, drawable_id = 1, price = 10 })
        QueryBuilder.new('clothes_shop_item_variants'):insert({ item_id = itemId, texture_id = 0, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })

        ClothesShopService.restock(shopId)

        eq(tables.clothes_shop_item_variants[1].last_restocked_at ~= nil, true)
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

`core/plugins/oblsk_clothesshop/tests/clothes_shop_safe_seeder_spec.lua` — mirror `core/plugins/oblsk_shop/tests/safe_seeder_spec.lua` exactly (read that file first for its precise dofile chain, `test`/`eq` helpers, and the two cases it covers — "creates a safe for every shop missing one" and "ensure is idempotent: calling twice does not duplicate rows or reset an accrued safe"), adapted to `clothes_shops`/`clothes_shop_safes`/`ClothesShopSafeSeeder`.

Add to `core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua` (append near the end, before the final test-runner loop) — this needs a `clothes_shop_safes` fixture row added to `withFreshState`'s seed data first (`{ id = 1, shop_id = 1, cash_amount = 0, max_cash = 15000 }`), then:

```lua
test('cash purchase accrues its total into the shop\'s register', function()
    withFreshState(function()
        ClothesShopService.purchase(999, 1, { { itemId = 10, variantId = 100 } }, 'cash')
        local safe = QueryBuilder.new('clothes_shop_safes'):where('shop_id', 1):firstSync()
        eq(safe.cash_amount, 25) -- $25.00 item price
    end)
end)

test('register accrual caps at max_cash', function()
    withFreshState(function()
        QueryBuilder.new('clothes_shop_safes'):where('shop_id', 1):update({ cash_amount = 14990, max_cash = 15000 })
        ClothesShopService.purchase(999, 1, { { itemId = 10, variantId = 100 } }, 'cash') -- $25 sale
        local safe = QueryBuilder.new('clothes_shop_safes'):where('shop_id', 1):firstSync()
        eq(safe.cash_amount, 15000)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_restock_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'restock')`.

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_safe_seeder_spec.lua`
Expected: FAIL — cannot dofile `ClothesShopSafeSeeder.lua` (doesn't exist yet).

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua`
Expected: FAIL — the two new accrual tests fail (no `clothes_shop_safes` row is written by `purchase` yet).

- [ ] **Step 3: Write the implementations**

Add to `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`, right after `ClothesShopService.list` (before the `resolveLine` local function):

```lua
--- Adds to a shop's register, capped at max_cash. Called after every
--- successful purchase, any payment method. Mirrors
--- SafeCrackingService.accrueRevenue in oblsk_shop.
--- @param shopId number
--- @param amount number
function ClothesShopService.accrueRevenue(shopId, amount)
    if type(amount) ~= 'number' or amount <= 0 then return end

    local safe = QueryBuilder.new('clothes_shop_safes'):where('shop_id', shopId):firstSync()
    if not safe then return end

    local newAmount = math.min(safe.cash_amount + amount, safe.max_cash)
    QueryBuilder.new('clothes_shop_safes'):where('id', safe.id):update({ cash_amount = newAmount, updated_at = Database.now() })
end

--- Refills every clothes_shop_item_variants row belonging to shopId
--- (joined through clothes_shop_items, since variants don't carry
--- shop_id directly) by its own restock_amount, capped at its own
--- max_qty.
--- @param shopId number
function ClothesShopService.restock(shopId)
    local items = QueryBuilder.new('clothes_shop_items'):where('shop_id', shopId):getSync()
    for _, item in ipairs(items) do
        local variants = QueryBuilder.new('clothes_shop_item_variants'):where('item_id', item.id):getSync()
        for _, variant in ipairs(variants) do
            local newQty = math.min(variant.qty + variant.restock_amount, variant.max_qty)
            QueryBuilder.new('clothes_shop_item_variants'):where('id', variant.id):update({
                qty = newQty,
                last_restocked_at = os.time(),
                updated_at = Database.now(),
            })
        end
    end
end
```

In `ClothesShopService.purchase`, add the accrual call right before the final `return true` (after the `decrementAndGrant` success check from Task 2):

```lua
    local ok, grantReason = decrementAndGrant(source, resolved)
    if not ok then
        return false, grantReason or 'Purchase failed'
    end

    ClothesShopService.accrueRevenue(shopId, total)
    return true
end
```

`core/plugins/oblsk_clothesshop/server/services/ClothesShopSafeSeeder.lua`:

```lua
-- plugins/oblsk_clothesshop/server/services/ClothesShopSafeSeeder.lua
--- ClothesShopSafeSeeder - gives every clothes_shops row a
--- clothes_shop_safes row, idempotently. Mirrors oblsk_shop's SafeSeeder:
--- never touches an existing safe's cash_amount, so a restart doesn't
--- silently refill or reset a safe that's since been collected or
--- topped up by sales.
ClothesShopSafeSeeder = {}

local function ensureSafe(shop)
    local existing = QueryBuilder.new('clothes_shop_safes'):where('shop_id', shop.id):firstSync()
    if existing then
        return existing.id
    end

    local safeId = QueryBuilder.new('clothes_shop_safes'):insert({
        shop_id = shop.id,
        cash_amount = 0,
        max_cash = 15000,
        decay_amount = 50,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    print('[ClothesShop] seeded safe for shop #' .. tostring(shop.id))
    return safeId
end

--- Must be called after every clothes_shops row that should have a safe
--- already exists, and after Database.isReady().
function ClothesShopSafeSeeder.ensure()
    local shops = QueryBuilder.new('clothes_shops'):getSync()
    for _, shop in ipairs(shops) do
        ensureSafe(shop)
    end
end

return ClothesShopSafeSeeder
```

In `core/plugins/oblsk_clothesshop/server/main.lua`, edit the boot thread at the bottom (add `ClothesShopSafeSeeder.ensure()` before `registerAllShops()`):

```lua
Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    ClothesShopSafeSeeder.ensure()
    registerAllShops()
    print('[ClothesShop] Loaded successfully!')
end)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_restock_spec.lua`
Expected: `2/2 tests passed`

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_safe_seeder_spec.lua`
Expected: matches `safe_seeder_spec.lua`'s test count (2/2), all passing.

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_service_spec.lua`
Expected: all tests pass (prior count + 2).

Run: `lua5.4 -e "assert(loadfile('core/plugins/oblsk_clothesshop/server/main.lua'))" && echo OK`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_clothesshop
git add server/services/ClothesShopService.lua server/services/ClothesShopSafeSeeder.lua server/main.lua tests/clothes_shop_service_spec.lua tests/clothes_shop_restock_spec.lua tests/clothes_shop_safe_seeder_spec.lua
git commit -m "feat(clothesshop): add register accrual, safe seeder, and restock"
```

---

## Task 4: Legit register collection

**Files:**
- Modify: `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`
- Create: `core/plugins/oblsk_clothesshop/tests/clothes_shop_collect_spec.lua`

**Interfaces:**
- Produces: `ClothesShopService.collectRegisterCash(shopId)` → `boolean ok, string|nil reason`. NPC-owned-only (rejects `'Shop is not NPC-owned'` if `clothes_shops.organization_id` is set), zeroes `clothes_shop_safes.cash_amount`, stamps `last_collected_at = os.time()`. Never grants the caller anything — same "jobs never carry real items" constraint as the `oblsk_shop` slice's equivalent function.

- [ ] **Step 1: Write the failing test**

`core/plugins/oblsk_clothesshop/tests/clothes_shop_collect_spec.lua` — mirror `core/plugins/oblsk_shop/tests/shop_service_collect_spec.lua` exactly (read that file first), adapted to `clothes_shops`/`clothes_shop_safes`/`ClothesShopService`:

```lua
-- plugins/oblsk_clothesshop/tests/clothes_shop_collect_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_clothesshop/tests/clothes_shop_collect_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(ROOT .. '/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua')

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
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'NPC Clothes Shop', organization_id = nil })
        QueryBuilder.new('clothes_shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 15000, decay_amount = 50 })

        local ok = ClothesShopService.collectRegisterCash(shopId)

        eq(ok, true)
        eq(tables.clothes_shop_safes[1].cash_amount, 0)
        eq(tables.clothes_shop_safes[1].last_collected_at ~= nil, true)
    end)
end)

test('collectRegisterCash: rejects an org-owned shop', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'Org Clothes Shop', organization_id = 7 })
        QueryBuilder.new('clothes_shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 15000, decay_amount = 50 })

        local ok, reason = ClothesShopService.collectRegisterCash(shopId)

        eq(ok, false)
        eq(reason, 'Shop is not NPC-owned')
        eq(tables.clothes_shop_safes[1].cash_amount, 300)
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

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_collect_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'collectRegisterCash')`.

- [ ] **Step 3: Write the implementation**

Add to `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`, right after `ClothesShopService.restock`:

```lua
--- Legitimate (non-criminal) register collection for NPC-owned shops
--- only -- there is no crime path for this register in this plugin
--- (unlike oblsk_shop's SafeCrackingService). Never grants the caller
--- any item/cash: this is a state mutation for a future job plugin to
--- call, not a transfer.
--- @param shopId number
--- @return boolean ok
--- @return string|nil reason
function ClothesShopService.collectRegisterCash(shopId)
    local shop = QueryBuilder.new('clothes_shops'):where('id', shopId):firstSync()
    if not shop or shop.organization_id then
        return false, 'Shop is not NPC-owned'
    end

    local safe = QueryBuilder.new('clothes_shop_safes'):where('shop_id', shopId):firstSync()
    if not safe then
        return false, 'This shop has no safe'
    end

    QueryBuilder.new('clothes_shop_safes'):where('id', safe.id):update({
        cash_amount = 0,
        last_collected_at = os.time(),
        updated_at = Database.now(),
    })
    return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_collect_spec.lua`
Expected: `2/2 tests passed`

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_clothesshop
git add server/services/ClothesShopService.lua tests/clothes_shop_collect_spec.lua
git commit -m "feat(clothesshop): add ClothesShopService.collectRegisterCash"
```

---

## Task 5: Scheduler-facing fallback actions

**Files:**
- Modify: `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`
- Modify: `core/plugins/oblsk_clothesshop/server/main.lua`
- Modify: `core/plugins/oblsk_clothesshop/shared/config.lua`
- Create: `core/plugins/oblsk_clothesshop/tests/clothes_shop_scheduled_actions_spec.lua`

**Interfaces:**
- Produces: `ClothesShopService.autoRefillStaleStock()` → `number`; `ClothesShopService.decayStaleSafes()` → `number`. Both read `ClothesShopConfig.Fallback.*` thresholds. `server/main.lua` registers `clothesshop:auto_refill_stale_stock` and `clothesshop:decay_stale_safes` — **both handlers open with `if player then return end` as their literal first statement**, no exception, no temporary unguarded version — this is the exact gap the `oblsk_shop` slice's final review had to fix after the fact.

- [ ] **Step 1: Add config thresholds**

Edit `core/plugins/oblsk_clothesshop/shared/config.lua`, add before the final `return ClothesShopConfig`... there is no `return` statement to find in this file (check — if `ClothesShopConfig.slotFor` is the last thing defined, add after it, at the end of the file):

```lua
-- Thresholds for the two Scheduler-consumable fallback actions
-- (clothesshop:auto_refill_stale_stock, clothesshop:decay_stale_safes)
-- registered in server/main.lua. Neither runs on a default schedule -- an
-- admin wires them up via the Scheduler tab. See
-- docs/superpowers/specs/2026-08-16-clothesshop-stock-and-register-design.md.
ClothesShopConfig.Fallback = {
    AutoRefillStaleAfterSeconds = 21600, -- 6 hours
    SafeDecayAfterSeconds = 43200, -- 12 hours
}
```

- [ ] **Step 2: Write the failing test**

`core/plugins/oblsk_clothesshop/tests/clothes_shop_scheduled_actions_spec.lua`:

```lua
-- plugins/oblsk_clothesshop/tests/clothes_shop_scheduled_actions_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_clothesshop/tests/clothes_shop_scheduled_actions_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(ROOT .. '/plugins/oblsk_clothesshop/shared/config.lua')
dofile(ROOT .. '/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua')

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

test('autoRefillStaleStock: restocks a shop with a never-restocked variant', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'Test Shop' })
        local itemId = QueryBuilder.new('clothes_shop_items'):insert({ shop_id = shopId, base_item_id = 1, category = 'tshirt', name = 'Tee', component_id = 8, drawable_id = 1, price = 10 })
        QueryBuilder.new('clothes_shop_item_variants'):insert({ item_id = itemId, texture_id = 0, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })

        local count = ClothesShopService.autoRefillStaleStock()

        eq(count, 1)
        eq(tables.clothes_shop_item_variants[1].qty, 15)
    end)
end)

test('autoRefillStaleStock: skips a variant restocked recently', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'Test Shop' })
        local itemId = QueryBuilder.new('clothes_shop_items'):insert({ shop_id = shopId, base_item_id = 1, category = 'tshirt', name = 'Tee', component_id = 8, drawable_id = 1, price = 10 })
        QueryBuilder.new('clothes_shop_item_variants'):insert({ item_id = itemId, texture_id = 0, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = os.time() })

        local count = ClothesShopService.autoRefillStaleStock()

        eq(count, 0)
        eq(tables.clothes_shop_item_variants[1].qty, 5)
    end)
end)

test('autoRefillStaleStock: restocks a shop with multiple stale variants only once', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'Test Shop' })
        local item1 = QueryBuilder.new('clothes_shop_items'):insert({ shop_id = shopId, base_item_id = 1, category = 'tshirt', name = 'Tee', component_id = 8, drawable_id = 1, price = 10 })
        local item2 = QueryBuilder.new('clothes_shop_items'):insert({ shop_id = shopId, base_item_id = 2, category = 'jacket', name = 'Jacket', component_id = 11, drawable_id = 2, price = 10 })
        QueryBuilder.new('clothes_shop_item_variants'):insert({ item_id = item1, texture_id = 0, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })
        QueryBuilder.new('clothes_shop_item_variants'):insert({ item_id = item2, texture_id = 0, qty = 5, max_qty = 20, restock_amount = 10, last_restocked_at = nil })

        local count = ClothesShopService.autoRefillStaleStock()

        eq(count, 1)
        eq(tables.clothes_shop_item_variants[1].qty, 15)
        eq(tables.clothes_shop_item_variants[2].qty, 15)
    end)
end)

-- decayStaleSafes

test('decayStaleSafes: decays a never-collected NPC-owned safe', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'NPC Shop', organization_id = nil })
        QueryBuilder.new('clothes_shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 15000, decay_amount = 50, last_collected_at = nil })

        local count = ClothesShopService.decayStaleSafes()

        eq(count, 1)
        eq(tables.clothes_shop_safes[1].cash_amount, 250)
    end)
end)

test('decayStaleSafes: floors at 0 rather than going negative', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'NPC Shop', organization_id = nil })
        QueryBuilder.new('clothes_shop_safes'):insert({ shop_id = shopId, cash_amount = 20, max_cash = 15000, decay_amount = 50, last_collected_at = nil })

        ClothesShopService.decayStaleSafes()

        eq(tables.clothes_shop_safes[1].cash_amount, 0)
    end)
end)

test('decayStaleSafes: skips a safe collected recently', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'NPC Shop', organization_id = nil })
        QueryBuilder.new('clothes_shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 15000, decay_amount = 50, last_collected_at = os.time() })

        local count = ClothesShopService.decayStaleSafes()

        eq(count, 0)
        eq(tables.clothes_shop_safes[1].cash_amount, 300)
    end)
end)

test('decayStaleSafes: skips org-owned shops even if their safe is stale', function()
    withFakeDb(function(tables)
        local shopId = QueryBuilder.new('clothes_shops'):insert({ name = 'Org Shop', organization_id = 7 })
        QueryBuilder.new('clothes_shop_safes'):insert({ shop_id = shopId, cash_amount = 300, max_cash = 15000, decay_amount = 50, last_collected_at = nil })

        local count = ClothesShopService.decayStaleSafes()

        eq(count, 0)
        eq(tables.clothes_shop_safes[1].cash_amount, 300)
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

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_scheduled_actions_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'autoRefillStaleStock')`.

- [ ] **Step 4: Write the implementation**

Add to `core/plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`, right after `ClothesShopService.collectRegisterCash` (before the final `return ClothesShopService`):

```lua
--- Restocks every shop that has at least one stale-or-never-restocked
--- variant, once per shop even if it has several stale variants across
--- multiple items. Designed to be called with no player context (see
--- server/main.lua's clothesshop:auto_refill_stale_stock action) by
--- SchedulerService.tick.
--- @return number count of shops restocked
function ClothesShopService.autoRefillStaleStock()
    local now = os.time()
    local staleShopIds = {}
    local variants = QueryBuilder.new('clothes_shop_item_variants'):getSync()
    for _, variant in ipairs(variants) do
        if not variant.last_restocked_at or (now - variant.last_restocked_at) >= ClothesShopConfig.Fallback.AutoRefillStaleAfterSeconds then
            local item = QueryBuilder.new('clothes_shop_items'):where('id', variant.item_id):firstSync()
            if item then
                staleShopIds[item.shop_id] = true
            end
        end
    end

    local count = 0
    for shopId in pairs(staleShopIds) do
        ClothesShopService.restock(shopId)
        count = count + 1
    end
    return count
end

--- Decays every NPC-owned shop's safe that hasn't been collected within
--- ClothesShopConfig.Fallback.SafeDecayAfterSeconds. Never touches
--- last_collected_at -- only ClothesShopService.collectRegisterCash does
--- -- so an uncollected safe keeps decaying on every scheduled run.
--- Designed to be called with no player context (see server/main.lua's
--- clothesshop:decay_stale_safes action) by SchedulerService.tick.
--- @return number count of safes decayed
function ClothesShopService.decayStaleSafes()
    local now = os.time()
    local safes = QueryBuilder.new('clothes_shop_safes'):getSync()

    local count = 0
    for _, safe in ipairs(safes) do
        local shop = QueryBuilder.new('clothes_shops'):where('id', safe.shop_id):firstSync()
        if shop and not shop.organization_id then
            if not safe.last_collected_at or (now - safe.last_collected_at) >= ClothesShopConfig.Fallback.SafeDecayAfterSeconds then
                local newAmount = math.max(0, safe.cash_amount - safe.decay_amount)
                QueryBuilder.new('clothes_shop_safes'):where('id', safe.id):update({
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

Run: `lua5.4 core/plugins/oblsk_clothesshop/tests/clothes_shop_scheduled_actions_spec.lua`
Expected: `7/7 tests passed`

Also re-run every other spec in this plugin to confirm nothing broke:

Run: `for f in core/plugins/oblsk_clothesshop/tests/*.lua; do lua5.4 "$f"; done`
Expected: every file prints its own full pass count, no `FAIL:` lines anywhere.

- [ ] **Step 6: Wire the two ActionService actions, gated from the start**

In `core/plugins/oblsk_clothesshop/server/main.lua`, add after the existing `ActionService.register('clothesshop:open', ...)` block (before `local function registerAllShops()`):

```lua
--- No player context -- called by SchedulerService.tick's
--- ActionService.execute(nil, actionId, {}) once an admin wires up a
--- scheduled_jobs row for this action_id via the Scheduler tab. Never
--- scheduled by default. The `if player then return end` guard is
--- REQUIRED, not optional -- without it, any connected player could
--- trigger these via the generic core:client:action-execute net event
--- (see the oblsk_shop slice's final review for the exploit this
--- prevents: an unguarded decay action let a player drain every shop's
--- register on demand).
ActionService.register('clothesshop:auto_refill_stale_stock', function(player)
    if player then return end
    local count = ClothesShopService.autoRefillStaleStock()
    print('[ClothesShop] auto_refill_stale_stock: restocked ' .. count .. ' shop(s)')
end, { label = 'Auto-refill stale clothes shop stock' })

ActionService.register('clothesshop:decay_stale_safes', function(player)
    if player then return end
    local count = ClothesShopService.decayStaleSafes()
    print('[ClothesShop] decay_stale_safes: decayed ' .. count .. ' safe(s)')
end, { label = 'Decay uncollected clothes shop safes' })
```

- [ ] **Step 7: Verify main.lua still parses**

Run: `cd core/plugins/oblsk_clothesshop && lua5.4 -e "assert(loadfile('server/main.lua'))" && echo OK`
Expected: `OK`

- [ ] **Step 8: Commit**

```bash
cd core/plugins/oblsk_clothesshop
git add server/services/ClothesShopService.lua server/main.lua shared/config.lua tests/clothes_shop_scheduled_actions_spec.lua
git commit -m "feat(clothesshop): add scheduler-consumable auto-refill and safe-decay actions, gated from client triggering"
```

---

## Plan Self-Review Notes

- **Spec coverage:** ownership column + stock columns + safes table (Task 1), stock-limited purchase (Task 2), register accrual + safe seeder + restock (Task 3), legit collection (Task 4), scheduler fallback actions gated from the start (Task 5) — every section of the spec has a task, including the spec's explicit callback to the `oblsk_shop` slice's final-review lessons (nullable-max_qty crash class avoided via `NOT NULL DEFAULT` in Task 1; unguarded scheduler actions avoided via the `if player then return end` guard built into Task 5 from the first line, not retrofitted).
- **Type consistency:** `ClothesShopService.restock(shopId)`/`collectRegisterCash(shopId)` signatures match the `oblsk_shop` slice's `ShopService.restock`/`collectRegisterCash` exactly (same parameter shape, same two-value `(ok, reason)` return convention). `autoRefillStaleStock`'s dedup-by-shop logic requires an extra join (`clothes_shop_item_variants` → `clothes_shop_items` → `shop_id`) that `oblsk_shop`'s equivalent didn't need (its `shop_stock` carries `shop_id` directly) — Task 5's implementation and tests both account for this.
- **No placeholders:** every step has full code, no TODOs.
