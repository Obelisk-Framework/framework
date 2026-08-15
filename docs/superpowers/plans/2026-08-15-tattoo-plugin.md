# oblsk_tattoo Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `oblsk_tattoo`, a new nested-repo plugin porting the Claude Design "Tattoo Studio" prototype (zone-book browsing, ink/laser minigames, DB-backed persistence, cash/card checkout) into the Obelisk framework, mirroring `oblsk_terminal`/`oblsk_cardealer`'s file layout.

**Architecture:** Server owns the design catalog and applied-ink state in three tables (`tattoo_shops`, `tattoo_designs`, `tattoo_applied`); `TattooService` resolves prices server-side on every apply/remove (never trusts client-sent price, same rule as `CarDealerService`/`TunerService`). Client is a single Vue page (`Tattoo.vue`) with two child minigame components, browsing/searching purely client-side and only round-tripping to the server on ink/laser completion.

**Tech Stack:** Lua 5.4 (FXServer server/client scripts), Obelisk's own QueryBuilder/Schema ORM, Vue 3 `<script setup>` SFCs, existing `obelisk:payment` injection for card checkout.

**Spec:** `core/docs/superpowers/specs/2026-08-15-tattoo-plugin-design.md`

## Global Constraints

- New repo: `git@github.com:Obelisk-Framework/oblsk_tattoo.git`, nested at `core/plugins/oblsk_tattoo` (own `.git`, own remote — same posture as `oblsk_terminal`).
- File layout mirrors `oblsk_terminal`/`oblsk_cardealer`: `fxmanifest.lua`, `client/main.lua`, `server/main.lua`, `server/services/`, `server/seeders/`, `server/migrations/` + `migrations.json`, `shared/config.lua`, `tests/*_spec.lua`, `web/*.vue`, `web/routes.js`.
- Every purchase/apply/remove path re-resolves price server-side from the DB catalog — never trust a client-sent price (spec "Error handling").
- Tests run via `lua5.4 <path>` from repo root, following the exact bootstrap block used in `oblsk_terminal/tests/terminal_service_spec.lua` (dofile chain: fivem_stubs → ORM → fake_query_builder → plugin's own config/service files).
- `tattoo_applied` has one row per `(character_id, zone)` — applying a new design on an occupied zone replaces the row (spec "Data model").
- `free_mode` is a `tattoo_shops` column, not a client-controlled toggle (spec "Error handling").

---

### Task 1: Repo scaffold — fxmanifest, config, README

**Files:**
- Create: `core/plugins/oblsk_tattoo/fxmanifest.lua`
- Create: `core/plugins/oblsk_tattoo/shared/config.lua`
- Create: `core/plugins/oblsk_tattoo/README.md`
- Create: `core/plugins/oblsk_tattoo/.gitignore`

**Interfaces:**
- Produces: `TattooConfig` global table (read by `server/main.lua`, `TattooService.lua`) with fields `SessionTimeout` (unused placeholder removed — see below), `RemovalPriceRatio` (number, fraction of original price charged for laser removal, prototype used 0.55), `MinCoverage` / `MinSteady` (numbers, prototype's 95/95 minigame accept gate).

- [ ] **Step 1: Create the plugin directory and git repo**

```bash
mkdir -p /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
git init -q
```

- [ ] **Step 2: Write `fxmanifest.lua`**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Tattoo'
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
    'web/tattoo/*.vue',
    'web/routes.js',
}
```

- [ ] **Step 3: Write `shared/config.lua`**

```lua
--- plugins/oblsk_tattoo/shared/config.lua
TattooConfig = {
    -- Removal price = round(original apply price * this ratio). Ported from
    -- the prototype's `Math.max(180, Math.round((d.price || 400) * 0.55))`
    -- floor — the floor lives in TattooService, this is just the ratio.
    RemovalPriceRatio = 0.55,
    RemovalPriceFloor = 180,

    -- Minigame accept gate, ported 1:1 from TtNeedleGame's disabled-button
    -- condition (`result.coverage < 95 || (100 - result.slip) < 95`).
    MinCoverage = 95,
    MinSteady = 95,
}
```

- [ ] **Step 4: Write `README.md`**

```markdown
# oblsk_tattoo

Tattoo studio plugin for the Obelisk Framework — zone-book browsing, an
ink-tracing minigame, a laser-removal minigame, and DB-persisted ink per
character. Ported from the Claude Design "Tattoo Studio" prototype.

## Data flow

See `core/docs/superpowers/specs/2026-08-15-tattoo-plugin-design.md` in the
main framework repo for the full design.
```

- [ ] **Step 5: Write `.gitignore`**

```
node_modules/
.DS_Store
```

- [ ] **Step 6: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
git add fxmanifest.lua shared/config.lua README.md .gitignore
git commit -m "scaffold: oblsk_tattoo plugin skeleton" -q
```

---

### Task 2: Migrations — tattoo_shops, tattoo_designs, tattoo_applied

**Files:**
- Create: `core/plugins/oblsk_tattoo/server/migrations/2026_08_15_180000_create_tattoo_shops_table.lua`
- Create: `core/plugins/oblsk_tattoo/server/migrations/2026_08_15_180001_create_tattoo_designs_table.lua`
- Create: `core/plugins/oblsk_tattoo/server/migrations/2026_08_15_180002_create_tattoo_applied_table.lua`
- Create: `core/plugins/oblsk_tattoo/server/migrations.json`

**Interfaces:**
- Produces: `tattoo_shops(id, business_name, interaction_id, free_mode)`, `tattoo_designs(id, shop_id nullable, name, zone, price)`, `tattoo_applied(id, character_id, zone, design_name, ink_hex, quality, grade, price_paid, unique(character_id, zone))` — consumed by `TattooService` (Task 4) and `TattooDesignSeeder` (Task 3).

- [ ] **Step 1: Write the `tattoo_shops` migration**

```lua
--- Migration: Create tattoo_shops table
--- One row per tattoo parlor. free_mode makes every apply/remove no-charge
--- for that shop — a staff/self-serve booth — same posture as the design
--- spec's "not a client toggle" rule.
return {
    up = function()
        Schema.create('tattoo_shops', function(table)
            table:id()
            table:string('business_name', 100)
            table:foreignId('interaction_id'):constrained('interactions'):onDelete('CASCADE')
            table:boolean('free_mode'):default(false)
            table:timestamps()
        end)

        print('[Migration] Created tattoo_shops table')
    end,

    down = function()
        Schema.drop('tattoo_shops')
        print('[Migration] Dropped tattoo_shops table')
    end
}
```

- [ ] **Step 2: Write the `tattoo_designs` migration**

```lua
--- Migration: Create tattoo_designs table
--- The book. shop_id nullable = global catalog entry available at every
--- shop (the seeded default book); a non-null shop_id scopes a design to
--- one shop's exclusive flash, same pattern as cardealer_listings scoping
--- vehicles to one dealer.
return {
    up = function()
        Schema.create('tattoo_designs', function(table)
            table:id()
            table:foreignId('shop_id'):nullable():constrained('tattoo_shops'):onDelete('CASCADE')
            table:string('name', 100)
            table:string('zone', 20)
            table:decimal('price', 10, 2)
            table:timestamps()
        end)

        print('[Migration] Created tattoo_designs table')
    end,

    down = function()
        Schema.drop('tattoo_designs')
        print('[Migration] Dropped tattoo_designs table')
    end
}
```

- [ ] **Step 3: Write the `tattoo_applied` migration**

```lua
--- Migration: Create tattoo_applied table
--- What's currently on a character's skin. One row per (character_id,
--- zone) - applying a new piece on an occupied zone replaces the row
--- (TattooService.apply does the delete+insert, not this schema).
return {
    up = function()
        Schema.create('tattoo_applied', function(table)
            table:id()
            table:foreignId('character_id'):constrained('characters'):onDelete('CASCADE')
            table:string('zone', 20)
            table:string('design_name', 100)
            table:string('ink_hex', 20)
            table:integer('quality')
            table:string('grade', 20)
            table:decimal('price_paid', 10, 2):default(0)
            table:timestamps()
            table:unique({ 'character_id', 'zone' })
        end)

        print('[Migration] Created tattoo_applied table')
    end,

    down = function()
        Schema.drop('tattoo_applied')
        print('[Migration] Dropped tattoo_applied table')
    end
}
```

- [ ] **Step 4: Write `migrations.json`**

```json
{
  "migrations": [
    "2026_08_15_180000_create_tattoo_shops_table",
    "2026_08_15_180001_create_tattoo_designs_table",
    "2026_08_15_180002_create_tattoo_applied_table"
  ]
}
```

- [ ] **Step 5: Verify Lua syntax on all three migrations**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
luac5.4 -p server/migrations/*.lua && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 6: Commit**

```bash
git add server/migrations server/migrations.json
git commit -m "feat: tattoo_shops/tattoo_designs/tattoo_applied migrations" -q
```

---

### Task 3: TattooDesignSeeder — seed the 23-entry book

**Files:**
- Create: `core/plugins/oblsk_tattoo/server/seeders/TattooDesignSeeder.lua`
- Test: `core/plugins/oblsk_tattoo/tests/tattoo_design_seeder_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(tableName)` with `:where(...)`, `:getSync()`, `:insert(data)`.
- Produces: `TattooDesignSeeder.ensure()` — idempotent, inserts the 23 global-book rows (`shop_id = nil`) into `tattoo_designs` only if that table is currently empty. Called from `server/main.lua` boot thread (Task 5).

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_tattoo/tests/tattoo_design_seeder_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_tattoo/tests/tattoo_design_seeder_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/seeders/TattooDesignSeeder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

test('ensure seeds 23 global designs into an empty table', function()
    local fake = makeFakeQueryBuilderModule({})
    QueryBuilder = fake
    TattooDesignSeeder.ensure()
    local rows = fake.new('tattoo_designs'):getSync()
    eq(#rows, 23)
    eq(rows[1].shop_id, nil)
end)

test('ensure is a no-op when tattoo_designs already has rows', function()
    local fake = makeFakeQueryBuilderModule({
        tattoo_designs = { [1] = { id = 1, name = 'Existing', zone = 'head', price = 100 } },
    })
    QueryBuilder = fake
    TattooDesignSeeder.ensure()
    local rows = fake.new('tattoo_designs'):getSync()
    eq(#rows, 1)
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_tattoo/tests/tattoo_design_seeder_spec.lua` (from repo root `/home/andi/Projects/obelisk-framework/core`)
Expected: FAIL — `TattooDesignSeeder.lua` does not exist yet (dofile error)

- [ ] **Step 3: Write `TattooDesignSeeder.lua`**

```lua
--- plugins/oblsk_tattoo/server/seeders/TattooDesignSeeder.lua
--- Seeds the prototype's 23-entry book as global designs (shop_id = nil,
--- available everywhere) exactly once — mirrors TerminalItemSeeder's
--- "only if empty" idempotency check.
TattooDesignSeeder = {}

local BOOK = {
    { 'Thunder Runner', 'torso', 13200 }, { 'Ash Reaper', 'torso', 18100 }, { 'Winged Crest', 'torso', 16480 },
    { 'Wreckage', 'larm', 11985 }, { 'Hot Air', 'torso', 10000000 }, { 'Paratrooper', 'torso', 15200 },
    { 'Fly Away', 'torso', 12520 }, { 'Screaming Eagle', 'torso', 922450 }, { 'Anchor Lamp', 'torso', 7251 },
    { 'Deep Water', 'torso', 5800 }, { 'Hammerhead', 'torso', 5900 }, { 'One Eye', 'head', 12000 },
    { 'Surf Script', 'head', 1450 }, { 'Marlin', 'head', 1850 }, { 'Mandala', 'lleg', 4450 },
    { 'Tiki Mask', 'rleg', 6500 }, { 'Sleeve Weave', 'rarm', 6200 }, { 'Blank Slate', 'larm', 4800 },
    { 'Barbed Band', 'rarm', 3200 }, { 'Crown', 'head', 2600 }, { 'Bar Code', 'head', 900 },
    { 'Serpent', 'lleg', 7400 }, { 'Compass Rose', 'torso', 8900 }, { 'Twin Swallow', 'rleg', 5400 },
}

function TattooDesignSeeder.ensure()
    local existing = QueryBuilder.new('tattoo_designs'):getSync()
    if existing and #existing > 0 then
        return
    end

    for _, entry in ipairs(BOOK) do
        QueryBuilder.new('tattoo_designs'):insert({
            shop_id = nil,
            name = entry[1],
            zone = entry[2],
            price = entry[3],
        })
    end

    print('[Tattoo] Seeded ' .. #BOOK .. ' designs')
end

return TattooDesignSeeder
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_tattoo/tests/tattoo_design_seeder_spec.lua`
Expected: `2 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add server/seeders/TattooDesignSeeder.lua tests/tattoo_design_seeder_spec.lua
git commit -m "feat: seed the 23-entry tattoo design book" -q
```

---

### Task 4: TattooService — list, apply, remove

**Files:**
- Create: `core/plugins/oblsk_tattoo/server/services/TattooService.lua`
- Test: `core/plugins/oblsk_tattoo/tests/tattoo_service_spec.lua`

**Interfaces:**
- Consumes: `ItemService.binding('currency.cash')`, `ItemService.has(source, binding, amount)`, `ItemService.remove(source, binding, amount)` (cash path, same as `CarDealerService.purchase`); `BankingService.charge(source, cardId, amount, description)` (card path); `CharacterService.getActiveCharacterId(source)`; `TattooConfig.RemovalPriceRatio`, `TattooConfig.RemovalPriceFloor` (Task 1).
- Produces:
  - `TattooService.catalog(shopId)` → array of `{ id, name, zone, price }` (global book + shop-scoped rows).
  - `TattooService.applied(characterId)` → array of `{ zone, designName, inkHex, quality, grade, pricePaid }`.
  - `TattooService.apply(source, shopId, designId, inkHex, quality, grade, method, cardId)` → `boolean, string|table` (reason on failure, `{ zone, designName, pricePaid }` on success). Recomputes price from `quality`/the design's `price` exactly like the prototype's `Math.round(game.price * res.mult)` — `mult` is derived server-side from `grade`, never trusted from the client.
  - `TattooService.remove(source, characterId, zone, method, cardId)` → `boolean, string|table` (reason on failure, `{ zone }` on success). Charges `round(max(RemovalPriceFloor, appliedRow.price_paid * RemovalPriceRatio))`, free when the shop (looked up via the applied row's original design, or 0 if shop is unknown) has `free_mode`.
  - `TattooService.resetForTests()` — no-op placeholder for parity with other services' test harness convention (this service holds no in-memory state, only DB rows, but the symbol keeps the spec's `withFreshState` helper uniform with `terminal_service_spec.lua`).

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_tattoo/tests/tattoo_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_tattoo/tests/tattoo_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    if source == 1 then return 100 end
    return nil
end

CASH_BALANCE = 0
ItemService = {}
function ItemService.binding(key)
    if key == 'currency.cash' then return { id = 1 } end
    return nil
end
function ItemService.has(source, binding, amount) return CASH_BALANCE >= amount end
function ItemService.remove(source, binding, amount)
    if CASH_BALANCE < amount then return false, 'Not enough cash' end
    CASH_BALANCE = CASH_BALANCE - amount
    return true
end

BANKING_CHARGE_RESULT = { ok = true }
BankingService = {}
function BankingService.charge(source, cardId, amount, description)
    return BANKING_CHARGE_RESULT.ok, BANKING_CHARGE_RESULT.reason
end

dofile(scriptDir .. '../server/services/TattooService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(seed, fn)
    local fake = makeFakeQueryBuilderModule(seed or {})
    QueryBuilder = fake
    CASH_BALANCE = 100000
    BANKING_CHARGE_RESULT = { ok = true }
    fn(fake)
end

local DESIGN = { id = 1, shop_id = nil, name = 'Crown', zone = 'head', price = 2600 }

test('apply fails without an active character', function()
    withFreshState({ tattoo_designs = { [1] = DESIGN } }, function()
        local ok, reason = TattooService.apply(999, nil, 1, '#000000', 90, 'CRISP', 'cash', nil)
        eq(ok, false)
        eq(reason, 'No active character')
    end)
end)

test('apply charges cash at full quality and writes the applied row', function()
    withFreshState({ tattoo_designs = { [1] = DESIGN } }, function(fake)
        local ok, result = TattooService.apply(1, nil, 1, '#000000', 90, 'CRISP', 'cash', nil)
        eq(ok, true)
        eq(result.zone, 'head')
        eq(result.designName, 'Crown')
        eq(result.pricePaid, 2600)
        eq(CASH_BALANCE, 100000 - 2600)

        local rows = fake.new('tattoo_applied'):where('character_id', 100):getSync()
        eq(#rows, 1)
        eq(rows[1].design_name, 'Crown')
        eq(rows[1].zone, 'head')
    end)
end)

test('apply fails on insufficient cash and writes nothing', function()
    withFreshState({ tattoo_designs = { [1] = DESIGN } }, function(fake)
        CASH_BALANCE = 100
        local ok, reason = TattooService.apply(1, nil, 1, '#000000', 90, 'CRISP', 'cash', nil)
        eq(ok, false)
        eq(reason, 'Not enough cash')
        eq(#fake.new('tattoo_applied'):getSync(), 0)
    end)
end)

test('apply declines when BankingService.charge fails', function()
    withFreshState({ tattoo_designs = { [1] = DESIGN } }, function(fake)
        BANKING_CHARGE_RESULT = { ok = false, reason = 'Card is frozen' }
        local ok, reason = TattooService.apply(1, nil, 1, '#000000', 90, 'CRISP', 'card', 42)
        eq(ok, false)
        eq(reason, 'Card is frozen')
        eq(#fake.new('tattoo_applied'):getSync(), 0)
    end)
end)

test('apply on a free_mode shop charges nothing', function()
    withFreshState({
        tattoo_shops = { [1] = { id = 1, business_name = 'Ink Free', free_mode = true } },
        tattoo_designs = { [1] = DESIGN },
    }, function(fake)
        local ok, result = TattooService.apply(1, 1, 1, '#000000', 90, 'CRISP', 'cash', nil)
        eq(ok, true)
        eq(result.pricePaid, 0)
        eq(CASH_BALANCE, 100000)
    end)
end)

test('apply replaces an existing row on the same zone', function()
    withFreshState({ tattoo_designs = { [1] = DESIGN } }, function(fake)
        TattooService.apply(1, nil, 1, '#000000', 90, 'CRISP', 'cash', nil)
        local ok = TattooService.apply(1, nil, 1, '#111111', 60, 'SHAKY', 'cash', nil)
        eq(ok, true)
        local rows = fake.new('tattoo_applied'):where('character_id', 100):getSync()
        eq(#rows, 1)
        eq(rows[1].ink_hex, '#111111')
    end)
end)

test('remove charges the removal price and deletes the row', function()
    withFreshState({ tattoo_designs = { [1] = DESIGN } }, function(fake)
        TattooService.apply(1, nil, 1, '#000000', 90, 'CRISP', 'cash', nil)
        local balanceAfterApply = CASH_BALANCE
        local ok, result = TattooService.remove(1, 100, 'head', 'cash', nil)
        eq(ok, true)
        eq(result.zone, 'head')
        -- 2600 * 0.55 = 1430
        eq(CASH_BALANCE, balanceAfterApply - 1430)
        eq(#fake.new('tattoo_applied'):where('character_id', 100):getSync(), 0)
    end)
end)

test('remove fails when the zone has nothing applied', function()
    withFreshState({}, function()
        local ok, reason = TattooService.remove(1, 100, 'head', 'cash', nil)
        eq(ok, false)
        eq(reason, 'Nothing applied there')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_tattoo/tests/tattoo_service_spec.lua`
Expected: FAIL — `TattooService.lua` does not exist yet

- [ ] **Step 3: Write `TattooService.lua`**

```lua
--- plugins/oblsk_tattoo/server/services/TattooService.lua
--- Catalog reads and apply/remove mutations. Re-resolves the design and its
--- price server-side on every call (never trusts a client-sent price) —
--- same rule as CarDealerService.purchase and TunerService.resolveItems.
TattooService = {}

function TattooService.resetForTests() end

--- @param shopId number|nil when nil, only the global book is returned
--- @return table[] { id, shop_id, name, zone, price }
function TattooService.catalog(shopId)
    local rows = QueryBuilder.new('tattoo_designs'):whereNull('shop_id'):getSync()
    if shopId then
        local scoped = QueryBuilder.new('tattoo_designs'):where('shop_id', shopId):getSync()
        for _, row in ipairs(scoped) do table.insert(rows, row) end
    end
    return rows
end

--- @param characterId number
--- @return table[] { zone, design_name, ink_hex, quality, grade, price_paid }
function TattooService.applied(characterId)
    return QueryBuilder.new('tattoo_applied'):where('character_id', characterId):getSync()
end

local function resolveDesign(designId)
    local row = QueryBuilder.new('tattoo_designs'):where('id', designId):firstSync()
    if not row then
        return nil, 'Design no longer available'
    end
    return row, nil
end

local function isFreeShop(shopId)
    if not shopId then return false end
    local shop = QueryBuilder.new('tattoo_shops'):where('id', shopId):firstSync()
    return shop ~= nil and shop.free_mode == true
end

--- Quality→price multiplier, ported 1:1 from the prototype's ttGrade table
--- (src/proto/tattoo-game.jsx). The client sends grade as a hint for the
--- toast copy; the multiplier itself is recomputed here from quality so a
--- forged grade can't buy a discount.
local function multiplierFor(quality)
    if quality >= 88 then return 1 end
    if quality >= 70 then return 1 end
    if quality >= 48 then return 0.7 end
    return 0.45
end

local function charge(source, method, cardId, amount, description)
    if amount <= 0 then return true end
    if method == 'cash' then
        local cash = ItemService.binding('currency.cash')
        if not cash then
            return false, 'Cash purchases are not available on this server'
        end
        local cashAmount = math.floor(amount + 0.5)
        if not ItemService.has(source, cash, cashAmount) then
            return false, 'Not enough cash'
        end
        return ItemService.remove(source, cash, cashAmount)
    elseif method == 'card' then
        return BankingService.charge(source, cardId, amount, description)
    end
    return false, 'Unknown payment method'
end

--- @param source number
--- @param shopId number|nil which shop the player is standing at (nil = not
---   tied to a specific shop's free_mode, always priced)
--- @param designId number
--- @param inkHex string '#rrggbb'
--- @param quality number 0-100, from the needle minigame
--- @param grade string display grade, informational only
--- @param method string 'cash'|'card'
--- @param cardId number|nil
--- @return boolean, string|table
function TattooService.apply(source, shopId, designId, inkHex, quality, grade, method, cardId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'No active character'
    end

    local design, reason = resolveDesign(designId)
    if not design then
        return false, reason
    end

    local free = isFreeShop(shopId)
    local price = free and 0 or math.round and math.round(design.price * multiplierFor(quality)) or math.floor(design.price * multiplierFor(quality) + 0.5)

    local ok, chargeReason = charge(source, method, cardId, price, 'Tattoo: ' .. design.name)
    if not ok then
        return false, chargeReason
    end

    local existing = QueryBuilder.new('tattoo_applied'):where('character_id', characterId):where('zone', design.zone):firstSync()
    if existing then
        QueryBuilder.new('tattoo_applied'):where('id', existing.id):update({
            design_name = design.name, ink_hex = inkHex, quality = quality, grade = grade, price_paid = price,
        })
    else
        QueryBuilder.new('tattoo_applied'):insert({
            character_id = characterId, zone = design.zone, design_name = design.name,
            ink_hex = inkHex, quality = quality, grade = grade, price_paid = price,
        })
    end

    return true, { zone = design.zone, designName = design.name, pricePaid = price }
end

--- @param source number
--- @param characterId number
--- @param zone string
--- @param method string 'cash'|'card'
--- @param cardId number|nil
--- @return boolean, string|table
function TattooService.remove(source, characterId, zone, method, cardId)
    local applied = QueryBuilder.new('tattoo_applied'):where('character_id', characterId):where('zone', zone):firstSync()
    if not applied then
        return false, 'Nothing applied there'
    end

    local shopId = nil -- removal isn't scoped to a specific shop's free_mode; always priced off the original charge
    local base = (applied.price_paid or 0) * TattooConfig.RemovalPriceRatio
    local price = applied.price_paid and applied.price_paid > 0
        and math.floor(math.max(TattooConfig.RemovalPriceFloor, base) + 0.5)
        or 0

    local ok, chargeReason = charge(source, method, cardId, price, 'Tattoo removal: ' .. applied.design_name)
    if not ok then
        return false, chargeReason
    end

    QueryBuilder.new('tattoo_applied'):where('id', applied.id):delete()

    return true, { zone = zone }
end

return TattooService
```

- [ ] **Step 4: Fix the `math.round` typo and rerun**

`math.round` does not exist in Lua 5.4 — remove that dead branch. Replace the `price` line in `TattooService.apply` with:

```lua
    local price = free and 0 or math.floor(design.price * multiplierFor(quality) + 0.5)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_tattoo/tests/tattoo_service_spec.lua`
Expected: `8 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add server/services/TattooService.lua tests/tattoo_service_spec.lua
git commit -m "feat: TattooService apply/remove with server-resolved pricing" -q
```

---

### Task 5: server/main.lua — wiring

**Files:**
- Create: `core/plugins/oblsk_tattoo/server/main.lua`

**Interfaces:**
- Consumes: `TattooService.catalog`, `TattooService.applied`, `TattooService.apply`, `TattooService.remove` (Task 4); `TattooDesignSeeder.ensure` (Task 3); `ActionService.register`, `InteractionService.register`, `WebView.openPage`, `WebView.focus`, `Obelisk.onServer`, `Obelisk.emitClient`, `NotificationService.notify`, `QueryBuilder`, `CharacterService.getActiveCharacterId`, `Database.isReady` (framework globals, same as `oblsk_terminal/server/main.lua`).
- Produces: server event handlers for `tattoo:client:apply` and `tattoo:client:remove`, action `tattoo:open`.

- [ ] **Step 1: Write `server/main.lua`**

```lua
--- Tattoo Plugin - Server Main
print('[Tattoo] Loading...')

local function notifyFailure(source, title, reason)
    NotificationService.notify(source, {
        type = 'error',
        title = title,
        description = reason or 'Something went wrong',
    })
end

local function openForSource(source, shopId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    local shop = shopId and QueryBuilder.new('tattoo_shops'):where('id', shopId):firstSync() or nil
    local catalog = TattooService.catalog(shopId)
    local applied = TattooService.applied(characterId)

    WebView.openPage(source, '/Tattoo')
    WebView.focus(source)
    Obelisk.emitClient('tattoo:server:sync', source, {
        shop = shop,
        catalog = catalog,
        applied = applied,
    })
end

ActionService.register('tattoo:open', function(source, data)
    local shopId = data and data.interaction and data.interaction.options and data.interaction.options.shopId
    openForSource(source, shopId)
end, { label = 'Use tattoo studio' })

--- Registers every shop row's interaction point. Must be called exactly
--- once, at boot - see oblsk_terminal/server/main.lua's registerAllTerminals
--- for why (InteractionService.register does not deduplicate).
local function registerAllShops()
    local shops = QueryBuilder.new('tattoo_shops'):getSync()
    for _, shop in ipairs(shops) do
        local interaction = QueryBuilder.new('interactions'):where('id', shop.interaction_id):firstSync()
        if interaction then
            InteractionService.register({
                x = interaction.x, y = interaction.y, z = interaction.z,
                range = interaction.range, label = interaction.label or shop.business_name,
                action = 'tattoo:open',
                options = { shopId = shop.id },
            })
        end
    end
end

Obelisk.onServer('tattoo:client:apply', function(shopId, designId, inkHex, quality, grade, method, cardId)
    local source = source
    local ok, result = TattooService.apply(source, shopId, designId, inkHex, quality, grade, method, cardId)
    if ok then
        Obelisk.emitClient('tattoo:server:applyResult', source, { ok = true, zone = result.zone, designName = result.designName, pricePaid = result.pricePaid })
    else
        notifyFailure(source, 'Tattoo failed', result)
        Obelisk.emitClient('tattoo:server:applyResult', source, { ok = false, reason = result })
    end
end)

Obelisk.onServer('tattoo:client:remove', function(zone, method, cardId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    local ok, result = TattooService.remove(source, characterId, zone, method, cardId)
    if ok then
        Obelisk.emitClient('tattoo:server:removeResult', source, { ok = true, zone = result.zone })
    else
        notifyFailure(source, 'Removal failed', result)
        Obelisk.emitClient('tattoo:server:removeResult', source, { ok = false, reason = result })
    end
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    TattooDesignSeeder.ensure()
    registerAllShops()
    print('[Tattoo] Loaded successfully!')
end)
```

- [ ] **Step 2: Verify Lua syntax**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
luac5.4 -p server/main.lua && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: Commit**

```bash
git add server/main.lua
git commit -m "feat: wire tattoo:open action and apply/remove events" -q
```

---

### Task 6: client/main.lua

**Files:**
- Create: `core/plugins/oblsk_tattoo/client/main.lua`

**Interfaces:**
- Consumes: `WebView.on`, `WebView.emitServer`, `Obelisk.onClient` (framework client globals, same as `oblsk_terminal/client/main.lua`).
- Produces: forwards `tattoo:apply`/`tattoo:remove` NUI events to the server and `tattoo:server:sync`/`applyResult`/`removeResult` server events back to the NUI as `WebView.emit('tattoo:sync' | 'tattoo:applyResult' | 'tattoo:removeResult', ...)`.

- [ ] **Step 1: Write `client/main.lua`**

```lua
--- Tattoo Plugin - Client Main
print('[Tattoo] Client loading...')

Obelisk.onClient('tattoo:server:sync', function(payload)
    WebView.emit('tattoo:sync', payload)
end)

Obelisk.onClient('tattoo:server:applyResult', function(payload)
    WebView.emit('tattoo:applyResult', payload)
end)

Obelisk.onClient('tattoo:server:removeResult', function(payload)
    WebView.emit('tattoo:removeResult', payload)
end)

WebView.on('tattoo:apply', function(data)
    WebView.emitServer('tattoo:client:apply', data.shopId, data.designId, data.inkHex, data.quality, data.grade, data.method, data.cardId)
end)

WebView.on('tattoo:remove', function(data)
    WebView.emitServer('tattoo:client:remove', data.zone, data.method, data.cardId)
end)
```

- [ ] **Step 2: Verify Lua syntax**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
luac5.4 -p client/main.lua && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: Commit**

```bash
git add client/main.lua
git commit -m "feat: client-side NUI event bridge" -q
```

---

### Task 7: web/tattoo/TtMark.vue — procedural ink art

**Files:**
- Create: `core/plugins/oblsk_tattoo/web/tattoo/TtMark.vue`

**Interfaces:**
- Produces: `<TtMark :name :box :ink :preview :q />` component, rendered inside an `<svg>` by its parent. `box` is `{ x, y, w, h }`. Port of `TtMark`/`TtMarkShape` from `src/proto/tattoo.jsx` — same seeded-shape selection so the same design always draws the same mark.

- [ ] **Step 1: Write `TtMark.vue`**

```vue
<!-- plugins/oblsk_tattoo/web/tattoo/TtMark.vue
     Procedural line-art per design, ported 1:1 from src/proto/tattoo.jsx's
     TtMark/TtMarkShape — the shape is derived from the design's name so the
     same design always draws the same mark, no image assets needed. -->
<template>
  <g :style="groupStyle">
    <g v-if="layers.length > 1" :transform="altTransform" opacity="0.7">
      <ttMarkShape :kind="alt" :x="x" :y="y" :w="box.w" :h="box.h" :c="c" />
    </g>
    <ttMarkShape :kind="kind" :x="x" :y="y" :w="box.w" :h="box.h" :c="c" />
  </g>
</template>

<script setup>
import { computed, h } from 'vue'

const props = defineProps({
  name: { type: String, required: true },
  box: { type: Object, required: true }, // { x, y, w, h }
  ink: { type: String, required: true },
  preview: { type: Boolean, default: false },
  q: { type: Number, default: 100 },
})

const x = computed(() => props.box.x)

const seed = computed(() => props.name.length + props.name.charCodeAt(0) + props.name.charCodeAt(props.name.length - 1))
const rough = computed(() => Math.max(0, (100 - props.q) / 100))
const c = computed(() => ({
  stroke: props.ink,
  fill: 'none',
  'stroke-width': (props.preview ? 1.7 : 1.3) * (1 + rough.value * 0.9),
  'stroke-linecap': 'round',
  'stroke-linejoin': 'round',
  opacity: (props.preview ? 0.95 : 0.85) * (1 - rough.value * 0.28),
  filter: rough.value > 0.2 ? `blur(${(rough.value * 0.8).toFixed(2)}px)` : 'none',
}))
const kind = computed(() => seed.value % 6)
const alt = computed(() => (seed.value >> 2) % 6)
const spin = computed(() => ((seed.value * 7) % 31) - 15)
const layers = computed(() => [kind.value, alt.value].filter((k, i, a) => i === 0 || k !== a[0]))

const groupStyle = computed(() => ({
  animation: 'ttInk .5s ease both',
  transform: `rotate(${(rough.value > 0.2 ? rough.value * 4 : 0) + spin.value * 0.35}deg)`,
  transformOrigin: `${props.box.x}px ${props.box.y}px`,
}))
const altTransform = computed(() => {
  const scale = seed.value % 2 ? -0.6 : 0.6
  return `translate(${props.box.x} ${props.box.y}) scale(${scale}) translate(${-props.box.x} ${-props.box.y})`
})

// Functional sub-component: one of six abstract line-art shapes, ported
// verbatim from TtMarkShape's per-kind SVG path/circle combinations.
const ttMarkShape = (_, { attrs }) => {
  const { kind, x, y, w, h, c } = attrs
  const parts = []
  if (kind === 0) {
    parts.push(h('path', { d: `M${x - w / 2} ${y + h / 3} q${w / 4} ${-h} ${w / 2} 0 q${w / 4} ${h} ${w / 2} 0`, ...c }))
    parts.push(h('path', { d: `M${x - w / 3} ${y + h / 2} h${w * 0.66}`, ...c }))
  } else if (kind === 1) {
    parts.push(h('path', { d: `M${x} ${y - h / 2} l${w / 2} ${h / 2} l${-w / 2} ${h / 2} l${-w / 2} ${-h / 2} z`, ...c }))
    parts.push(h('circle', { cx: x, cy: y, r: Math.min(w, h) / 5, ...c }))
  } else if (kind === 2) {
    for (let i = 0; i < 3; i++) {
      parts.push(h('path', { key: i, d: `M${x - w / 2} ${y - h / 3 + i * (h / 3)} q${w / 2} ${i % 2 ? h / 4 : -h / 4} ${w} 0`, ...c }))
    }
  } else if (kind === 3) {
    parts.push(h('circle', { cx: x, cy: y, r: Math.min(w, h) / 2.2, ...c }))
    parts.push(h('path', { d: `M${x} ${y - h / 2} v${h}M${x - w / 2} ${y} h${w}`, ...c }))
  } else if (kind === 4) {
    parts.push(h('path', { d: `M${x} ${y - h / 2} q${w / 2} ${h / 3} ${w / 2} ${h / 2} q${-w / 2} ${-h / 6} ${-w / 2} ${h / 2} q0 ${-h / 3} ${-w / 2} ${-h / 2} q${w / 2} ${-h / 6} ${w / 2} ${-h / 2} z`, ...c }))
  } else if (kind === 5) {
    parts.push(h('path', { d: `M${x - w / 2} ${y + h / 2} l${w / 3} ${-h} l${w / 3} ${h * 0.7} l${w / 3} ${-h * 0.55}`, ...c }))
    parts.push(h('path', { d: `M${x - w / 2} ${y + h / 2} h${w}`, ...c }))
  }
  return h('g', parts)
}
</script>
```

- [ ] **Step 2: Commit**

```bash
git add web/tattoo/TtMark.vue
git commit -m "feat: port TtMark procedural ink-art component" -q
```

---

### Task 8: web/tattoo/TtNeedleGame.vue

**Files:**
- Create: `core/plugins/oblsk_tattoo/web/tattoo/TtNeedleGame.vue`

**Interfaces:**
- Consumes: `TattooConfig`-equivalent gate values passed as props from `Tattoo.vue` (`minCoverage`, `minSteady` — the server's `TattooConfig.MinCoverage`/`MinSteady` values, kept in sync by hardcoding 95/95 client-side same as the prototype since the client can't read Lua config; the server independently re-validates via `TattooService.apply`'s own price/quality trust boundary, so a stale client constant only affects UX, not payment correctness).
- Produces: `<TtNeedleGame :design :ink :price :free @done="(result) => {}" @cancel="() => {}" />` where `result` is `{ q, grade, mult }`. Direct Vue port of `TtNeedleGame` from `src/proto/tattoo-game.jsx`, same stencil-tracing mechanics, same `ttGrade` thresholds.

- [ ] **Step 1: Write `TtNeedleGame.vue`**

```vue
<!-- plugins/oblsk_tattoo/web/tattoo/TtNeedleGame.vue
     Trace-the-stencil minigame, ported 1:1 from src/proto/tattoo-game.jsx's
     TtNeedleGame. Distance off the line and jerky pointer speed both cost
     quality; the traced coverage is what determines the payout multiplier. -->
<template>
  <div class="absolute inset-0 z-50 grid place-items-center" style="background:rgba(0,0,0,.72)">
    <div class="rounded-[12px] overflow-hidden" style="width:560px;background:rgba(9,12,12,.95);border:1px solid rgba(255,255,255,.12);animation:ttGameIn .34s cubic-bezier(.16,.84,.24,1) both">
      <div class="px-4 h-[46px] flex items-center gap-2" style="border-bottom:1px solid rgba(255,255,255,.08);background:rgba(255,255,255,.03)">
        <span class="w-[7px] h-[7px] rounded-full" :style="{ background: down ? '#ef4444' : 'rgba(255,255,255,.25)', boxShadow: down ? '0 0 8px rgba(239,68,68,.8)' : 'none' }" />
        <span class="tt-d text-[13px] uppercase">{{ design }}</span>
        <span class="ob-mono text-[11px] text-white/35 ml-auto">HOLD &amp; TRACE THE STENCIL</span>
        <button @click="$emit('cancel')" title="Walk away (Esc)"
          class="ml-2 w-[24px] h-[24px] rounded-[5px] grid place-items-center text-white/45 transition hover:text-white hover:bg-white/10"
          style="border:1px solid rgba(255,255,255,.14)">✕</button>
      </div>

      <div class="p-4">
        <div class="relative rounded-[8px] overflow-hidden" style="background:linear-gradient(160deg,#1b1512,#120e0c);border:1px solid rgba(255,255,255,.09)">
          <svg ref="svgRef" :viewBox="`0 0 ${W} ${H}`" class="w-full block"
            :style="{ touchAction: 'none', cursor: result ? 'default' : 'crosshair', animation: buzz && down ? 'ttBuzz .08s linear infinite' : 'none' }"
            @pointerdown="onDown" @pointermove="move" @pointerup="onUp" @pointerleave="onUp">
            <path v-for="i in 9" :key="i" :d="`M0 ${18 + (i - 1) * 32} q110 ${(i - 1) % 2 ? 12 : -12} 220 0 t220 0`" stroke="rgba(255,255,255,.03)" stroke-width="1" fill="none" />

            <path ref="pathRef" :d="stencil" fill="none" stroke="rgba(150,120,220,.5)" :stroke-width="TOL * 2" stroke-linecap="round" stroke-linejoin="round" opacity="0.14" />
            <path :d="stencil" fill="none" stroke="rgba(168,140,235,.75)" stroke-width="2" stroke-dasharray="7 6" stroke-linecap="round" />

            <path v-if="pts.length" :d="inkedPath" fill="none" :stroke="ink" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round" opacity="0.95" />

            <template v-if="trail.length > 1">
              <polyline :points="trail.map(p => `${p.x},${p.y}`).join(' ')" fill="none" stroke="rgba(255,255,255,.14)" stroke-width="1.2" />
              <circle v-for="(p, i) in trail.filter(p => p.bad)" :key="i" :cx="p.x" :cy="p.y" r="2.4" fill="rgba(239,68,68,.55)" />
            </template>

            <g v-if="last && down">
              <circle :cx="last.x" :cy="last.y" :r="TOL" fill="none" :stroke="buzz ? 'rgba(239,68,68,.5)' : 'rgba(16,185,129,.6)'" stroke-width="1" />
              <circle :cx="last.x" :cy="last.y" r="3" fill="#fff" />
            </g>
          </svg>

          <div v-if="!down && !result" class="absolute inset-0 grid place-items-center pointer-events-none">
            <div class="text-center">
              <div class="tt-d text-[15px] uppercase">Hold the needle down</div>
              <div class="text-[12px] text-white/45 mt-1">follow the dashed transfer, slow and steady</div>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3 mt-3">
          <div v-for="m in meters" :key="m.k">
            <div class="flex justify-between ob-mono text-[10px] text-white/40 mb-1"><span>{{ m.k }}</span><span>{{ m.v }}%</span></div>
            <div class="h-[6px] rounded-full overflow-hidden" style="background:rgba(255,255,255,.09)">
              <div :style="{ width: `${m.v}%`, height: '100%', background: m.c, transition: 'width .12s linear' }" />
            </div>
          </div>
        </div>

        <div v-if="result" class="mt-4 rounded-[8px] p-4 text-center" style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.1)">
          <div class="tt-d text-[22px] uppercase" :style="{ color: result.q >= 70 ? 'var(--ob-accent)' : '#f59e0b' }">{{ grade }}</div>
          <div class="text-[12.5px] text-white/55 mt-1">{{ blurb }}</div>
          <div class="ob-mono text-[11px] text-white/35 mt-2">QUALITY {{ result.q }}% · COVERAGE {{ result.coverage }}% · SLIPS {{ result.slip }}%</div>
          <div class="flex gap-2 mt-4">
            <button @click="reset" class="flex-1 h-[40px] rounded-[6px] tt-d text-[12.5px] transition hover:bg-white/[0.08]" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.75)">WIPE &amp; REDO</button>
            <button @click="$emit('cancel')" class="h-[40px] px-4 rounded-[6px] tt-d text-[12.5px] transition hover:bg-white/[0.08]" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.6)">LEAVE</button>
            <button @click="finishAccept" :disabled="!accepted"
              class="flex-1 h-[40px] rounded-[6px] tt-d text-[12.5px] disabled:opacity-30 disabled:cursor-not-allowed transition hover:brightness-110"
              style="background:var(--ob-accent);color:#04120d">
              {{ !accepted ? 'NOT CLEAN ENOUGH' : (free ? 'KEEP IT' : `KEEP IT · $${Math.round(price * mult).toLocaleString()}`) }}
            </button>
          </div>
        </div>
        <div v-else class="flex gap-2 mt-3">
          <button @click="$emit('cancel')" class="flex-1 h-[40px] rounded-[6px] tt-d text-[12.5px] transition hover:bg-white/[0.08]" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.7)">PUT THE GUN DOWN</button>
          <button @click="reset" class="h-[40px] px-4 rounded-[6px] tt-d text-[12.5px] transition hover:bg-white/[0.08]" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.7)">WIPE</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount, nextTick } from 'vue'

const props = defineProps({
  design: { type: String, required: true },
  ink: { type: String, required: true },
  price: { type: Number, required: true },
  free: { type: Boolean, default: false },
  minCoverage: { type: Number, default: 95 },
  minSteady: { type: Number, default: 95 },
})
const emit = defineEmits(['done', 'cancel'])

const STENCILS = [
  'M40 150 C 90 40, 190 40, 240 150 S 340 260, 390 150',
  'M60 60 L 200 60 L 200 200 L 340 200 M200 60 L 340 60',
  'M215 40 C 120 60, 90 170, 215 250 C 340 170, 310 60, 215 40 Z',
  'M50 200 C 120 60, 180 260, 250 100 S 350 220, 400 90',
  'M215 45 l 48 100 l 108 8 l -84 70 l 28 105 l -100 -58 l -100 58 l 28 -105 l -84 -70 l 108 -8 z',
]
const grade = (q) =>
  q >= 88 ? ['CRISP', 'The lines are dead clean.', 1] :
  q >= 70 ? ['CLEAN', 'Solid work, barely a wobble.', 1] :
  q >= 48 ? ['SHAKY', 'It reads, but the hand shook.', 0.7] :
            ['BOTCHED', 'That is a scar with ambitions.', 0.45]

const W = 440, H = 290, TOL = 17
const seed = props.design.length + props.design.charCodeAt(0)
const stencil = STENCILS[seed % STENCILS.length]

const svgRef = ref(null)
const pathRef = ref(null)
const pts = ref([])
const hit = ref([])
const last = ref(null)
const slip = ref(0)
const samp = ref(0)
const trail = ref([])
const down = ref(false)
const cover = ref(0)
const steady = ref(100)
const buzz = ref(false)
const result = ref(null)

const inkedPath = computed(() => pts.value.map((p, i) => (hit.value[i] ? `${i && hit.value[i - 1] ? 'L' : 'M'}${p.x} ${p.y}` : '')).join(''))
const meters = computed(() => [
  { k: 'COVERAGE', v: cover.value, c: 'var(--ob-accent)' },
  { k: 'STEADY HAND', v: steady.value, c: steady.value > 70 ? 'var(--ob-accent)' : '#ef4444' },
])
const gradeInfo = computed(() => (result.value ? grade(result.value.q) : [null, null, null]))
const blurb = computed(() => gradeInfo.value[1])
const mult = computed(() => gradeInfo.value[2])
const accepted = computed(() => !!result.value && result.value.coverage >= props.minCoverage && (100 - result.value.slip) >= props.minSteady)

function onKeydown(e) { if (e.key === 'Escape') { e.stopPropagation(); emit('cancel') } }
onMounted(() => {
  window.addEventListener('keydown', onKeydown, true)
  nextTick(() => {
    const p = pathRef.value
    if (!p) return
    const len = p.getTotalLength()
    const n = 240
    pts.value = Array.from({ length: n + 1 }, (_, i) => {
      const q = p.getPointAtLength((i / n) * len)
      return { x: q.x, y: q.y }
    })
    hit.value = new Array(n + 1).fill(false)
  })
})
onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown, true))

function toLocal(e) {
  const r = svgRef.value.getBoundingClientRect()
  return { x: ((e.clientX - r.left) / r.width) * W, y: ((e.clientY - r.top) / r.height) * H }
}

function finish() {
  const hits = hit.value.filter(Boolean).length
  const coverage = (hits / hit.value.length) * 100
  const slipRate = samp.value ? (slip.value / samp.value) * 100 : 100
  const q = Math.max(0, Math.round(coverage * 0.78 + (100 - slipRate) * 0.22))
  result.value = { q: Math.min(100, q), coverage: Math.round(coverage), slip: Math.round(slipRate) }
  down.value = false
}

function onDown(e) {
  if (result.value) return
  e.currentTarget.setPointerCapture(e.pointerId)
  last.value = null
  down.value = true
}
function onUp() { if (down.value) finish() }

function move(e) {
  if (!down.value || result.value) return
  const p = toLocal(e)
  const t = performance.now()

  let best = 1e9, bi = -1
  pts.value.forEach((s, i) => {
    const dd = (s.x - p.x) ** 2 + (s.y - p.y) ** 2
    if (dd < best) { best = dd; bi = i }
  })
  const dist = Math.sqrt(best)
  const on = dist <= TOL

  samp.value += 1
  if (on) {
    hit.value[bi] = true
    const prev = last.value?.i
    if (prev != null && Math.abs(prev - bi) < 24) {
      for (let i = Math.min(prev, bi); i <= Math.max(prev, bi); i++) hit.value[i] = true
    }
  } else {
    slip.value += 1
  }

  let fast = false
  if (last.value) {
    const dt = Math.max(8, t - last.value.t)
    const v = Math.hypot(p.x - last.value.x, p.y - last.value.y) / dt * 1000
    fast = v > 620
    if (fast) { slip.value += 1; samp.value += 1 }
  }
  last.value = { ...p, t, i: bi }

  buzz.value = !on || fast
  if (trail.value.length <= 700) trail.value = [...trail.value, { x: p.x, y: p.y, bad: !on || fast }]

  const hits = hit.value.filter(Boolean).length
  cover.value = Math.round((hits / hit.value.length) * 100)
  steady.value = Math.max(0, Math.round(100 - (slip.value / Math.max(1, samp.value)) * 100))

  if (hits / hit.value.length > 0.985) finish()
}

function reset() {
  hit.value = hit.value.map(() => false)
  slip.value = 0; samp.value = 0; last.value = null
  trail.value = []; cover.value = 0; steady.value = 100; result.value = null; buzz.value = false
}

function finishAccept() {
  if (!accepted.value) return
  emit('done', { q: result.value.q, grade: gradeInfo.value[0], mult: mult.value })
}
</script>
```

- [ ] **Step 2: Commit**

```bash
git add web/tattoo/TtNeedleGame.vue
git commit -m "feat: port TtNeedleGame ink-tracing minigame" -q
```

---

### Task 9: web/tattoo/TtLaserGame.vue

**Files:**
- Create: `core/plugins/oblsk_tattoo/web/tattoo/TtLaserGame.vue`

**Interfaces:**
- Produces: `<TtLaserGame :design :ink :price :free @done="(result) => {}" @cancel="() => {}" />` where `result` is `{ q, grade, mult }`. Direct Vue port of `TtLaserGame` from `src/proto/tattoo-game.jsx`.

- [ ] **Step 1: Write `TtLaserGame.vue`**

```vue
<!-- plugins/oblsk_tattoo/web/tattoo/TtLaserGame.vue
     Laser-removal minigame, ported 1:1 from src/proto/tattoo-game.jsx's
     TtLaserGame. Holding the trigger heats the head and clears ink cells
     under the cursor; overheating scars the skin and tanks the grade. -->
<template>
  <div class="absolute inset-0 z-[60] grid place-items-center" style="background:rgba(0,0,0,.72)">
    <div class="rounded-[12px] overflow-hidden" style="width:560px;background:rgba(9,12,12,.95);border:1px solid rgba(255,255,255,.12);animation:ttGameIn .34s cubic-bezier(.16,.84,.24,1) both">
      <div class="px-4 h-[46px] flex items-center gap-2" style="border-bottom:1px solid rgba(255,255,255,.08);background:rgba(255,255,255,.03)">
        <span class="w-[7px] h-[7px] rounded-full" :style="{ background: firing ? '#38bdf8' : 'rgba(255,255,255,.25)', boxShadow: firing ? '0 0 8px rgba(56,189,248,.85)' : 'none' }" />
        <span class="tt-d text-[13px] uppercase">Laser removal · {{ design }}</span>
        <span class="ob-mono text-[11px] text-white/35 ml-auto">HOLD TO FIRE · RELEASE TO COOL</span>
        <button @click="$emit('cancel')" title="Walk away (Esc)"
          class="ml-2 w-[24px] h-[24px] rounded-[5px] grid place-items-center text-white/45 transition hover:text-white hover:bg-white/10"
          style="border:1px solid rgba(255,255,255,.14)">✕</button>
      </div>

      <div class="p-4">
        <div class="relative rounded-[8px] overflow-hidden" style="background:linear-gradient(160deg,#1b1512,#120e0c);border:1px solid rgba(255,255,255,.09)">
          <svg ref="svgRef" :viewBox="`0 0 ${W} ${H}`" class="w-full block"
            :style="{ touchAction: 'none', cursor: result ? 'default' : 'none' }"
            @pointerdown="onDown" @pointerup="onUp" @pointerleave="onUp" @pointermove="onMove">
            <path v-for="i in 9" :key="i" :d="`M0 ${18 + (i - 1) * 32} q110 ${(i - 1) % 2 ? 12 : -12} 220 0 t220 0`" stroke="rgba(255,255,255,.03)" stroke-width="1" fill="none" />
            <circle v-for="(c, i) in visibleCells" :key="i" :cx="c.x" :cy="c.y" :r="c.r" :fill="ink" opacity="0.8" />
            <g v-for="(b, i) in burns" :key="'b' + i">
              <circle :cx="b.x" :cy="b.y" r="13" fill="rgba(180,60,40,.45)" />
              <circle :cx="b.x" :cy="b.y" r="7" fill="rgba(120,30,20,.75)" />
            </g>
            <g v-if="!result">
              <circle :cx="pos.x" :cy="pos.y" :r="R" :fill="firing ? 'rgba(56,189,248,.16)' : 'transparent'" :stroke="heat > 80 ? 'rgba(239,68,68,.9)' : 'rgba(56,189,248,.75)'" stroke-width="1.4" />
              <circle :cx="pos.x" :cy="pos.y" r="2.5" fill="#fff" />
              <circle v-if="firing" :cx="pos.x" :cy="pos.y" :r="R * 0.55" fill="rgba(255,255,255,.18)" />
            </g>
          </svg>
        </div>

        <div class="grid grid-cols-2 gap-3 mt-3">
          <div v-for="m in meters" :key="m.k">
            <div class="flex justify-between ob-mono text-[10px] text-white/40 mb-1"><span>{{ m.k }}</span><span>{{ m.v }}%</span></div>
            <div class="h-[6px] rounded-full overflow-hidden" style="background:rgba(255,255,255,.09)">
              <div :style="{ width: `${m.v}%`, height: '100%', background: m.c, transition: 'width .1s linear' }" />
            </div>
          </div>
        </div>
        <div v-if="burns.length && !result" class="ob-mono text-[10.5px] mt-2" style="color:#f87171">{{ burns.length }} BURN{{ burns.length > 1 ? 'S' : '' }} — LET THE HEAD COOL</div>

        <div v-if="result" class="mt-4 rounded-[8px] p-4 text-center" style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.1)">
          <div class="tt-d text-[22px] uppercase" :style="{ color: result.q >= 70 ? 'var(--ob-accent)' : '#f59e0b' }">{{ result.grade }}</div>
          <div class="text-[12.5px] text-white/55 mt-1">{{ result.blurb }}</div>
          <div class="ob-mono text-[11px] text-white/35 mt-2">REMOVED {{ result.removed }}% · BURNS {{ result.burns }}</div>
          <div class="flex gap-2 mt-4">
            <button @click="reset" class="flex-1 h-[40px] rounded-[6px] tt-d text-[12.5px] transition hover:bg-white/[0.08]" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.75)">RUN IT AGAIN</button>
            <button @click="$emit('cancel')" class="h-[40px] px-4 rounded-[6px] tt-d text-[12.5px] transition hover:bg-white/[0.08]" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.6)">LEAVE</button>
            <button @click="finishAccept" :disabled="result.burns > 0"
              class="flex-1 h-[40px] rounded-[6px] tt-d text-[12.5px] disabled:opacity-30 disabled:cursor-not-allowed transition hover:brightness-110"
              style="background:var(--ob-accent);color:#04120d">
              {{ result.burns > 0 ? 'BURNT — REDO' : (free ? 'DONE' : `DONE · $${Math.round(price * result.mult).toLocaleString()}`) }}
            </button>
          </div>
        </div>
        <div v-else class="flex gap-2 mt-3">
          <button @click="$emit('cancel')" class="flex-1 h-[40px] rounded-[6px] tt-d text-[12.5px] transition hover:bg-white/[0.08]" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.7)">LEAVE IT ON</button>
          <button @click="finish" class="h-[40px] px-4 rounded-[6px] tt-d text-[12.5px] transition hover:brightness-110" style="background:var(--ob-accent);color:#04120d">THAT'LL DO</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'

const props = defineProps({
  design: { type: String, required: true },
  ink: { type: String, required: true },
  price: { type: Number, required: true },
  free: { type: Boolean, default: false },
})
const emit = defineEmits(['done', 'cancel'])

const W = 440, H = 290, R = 26
const seed = props.design.length + props.design.charCodeAt(0)

let s2 = seed * 9301 + 49297
const rnd = () => ((s2 = (s2 * 9301 + 49297) % 233280) / 233280)
const cells = Array.from({ length: 130 }, () => ({
  x: 70 + rnd() * (W - 140), y: 55 + rnd() * (H - 110), r: 5 + rnd() * 7,
}))
const gone = ref(new Array(130).fill(false))
const visibleCells = computed(() => cells.filter((_, i) => !gone.value[i]))

const svgRef = ref(null)
const pos = ref({ x: W / 2, y: H / 2 })
const firing = ref(false)
const heat = ref(0)
const burns = ref([])
const clear = ref(0)
const result = ref(null)

const meters = computed(() => [
  { k: 'INK REMOVED', v: clear.value, c: 'var(--ob-accent)' },
  { k: 'HEAD TEMP', v: Math.min(100, heat.value), c: heat.value > 80 ? '#ef4444' : '#38bdf8' },
])

function onKeydown(e) { if (e.key === 'Escape') { e.stopPropagation(); emit('cancel') } }

function toLocal(e) {
  const r = svgRef.value.getBoundingClientRect()
  return { x: ((e.clientX - r.left) / r.width) * W, y: ((e.clientY - r.top) / r.height) * H }
}
function onDown(e) {
  if (result.value) return
  e.currentTarget.setPointerCapture(e.pointerId)
  firing.value = true
}
function onUp() { firing.value = false }
function onMove(e) { pos.value = toLocal(e) }

let raf = null
function tick() {
  if (result.value) return
  if (firing.value) {
    heat.value = Math.min(120, heat.value + 1.5)
    const p = pos.value
    let hitAny = false
    cells.forEach((c, i) => {
      if (gone.value[i]) return
      if (Math.hypot(c.x - p.x, c.y - p.y) < R) { gone.value[i] = true; hitAny = true }
    })
    if (hitAny) clear.value = Math.round((gone.value.filter(Boolean).length / cells.length) * 100)
    if (heat.value >= 100) {
      if (burns.value.length <= 40) burns.value = [...burns.value, { x: p.x, y: p.y }]
      heat.value = 55
    }
  } else {
    heat.value = Math.max(0, heat.value - 1.1)
  }
  raf = requestAnimationFrame(tick)
}

onMounted(() => {
  window.addEventListener('keydown', onKeydown, true)
  raf = requestAnimationFrame(tick)
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKeydown, true)
  if (raf) cancelAnimationFrame(raf)
})

function finish() {
  firing.value = false
  const removed = (gone.value.filter(Boolean).length / cells.length) * 100
  const scarPenalty = Math.min(45, burns.value.length * 4)
  const q = Math.max(0, Math.round(removed - scarPenalty))
  const [grade, blurb, mult] =
    q >= 90 ? ['CLEAN SKIN', 'Not a trace left behind.', 1] :
    q >= 70 ? ['FADED', 'A ghost of it, nothing more.', 1] :
    q >= 45 ? ['PATCHY', 'Half gone, half still there.', 0.8] :
              ['SCARRED', 'Worse than the tattoo was.', 0.6]
  result.value = { q, removed: Math.round(removed), burns: burns.value.length, grade, blurb, mult }
}

function reset() {
  gone.value = gone.value.map(() => false)
  heat.value = 0; burns.value = []; clear.value = 0; result.value = null
}

function finishAccept() {
  if (result.value.burns > 0) return
  emit('done', { q: result.value.q, grade: result.value.grade, mult: result.value.mult })
}
</script>
```

- [ ] **Step 2: Commit**

```bash
git add web/tattoo/TtLaserGame.vue
git commit -m "feat: port TtLaserGame removal minigame" -q
```

---

### Task 10: web/Tattoo.vue, Icon.vue, routes.js

**Files:**
- Create: `core/plugins/oblsk_tattoo/web/Tattoo.vue`
- Create: `core/plugins/oblsk_tattoo/web/Icon.vue`
- Create: `core/plugins/oblsk_tattoo/web/routes.js`

**Interfaces:**
- Consumes: `Obelisk` event bus (`../../../web/src/obelisk.js`, same relative import as `CarDealer.vue`), `obelisk:payment` injection, `TtMark`/`TtNeedleGame`/`TtLaserGame` (Tasks 7-9), `Icon.vue` (this task).
- Produces: mounted route `/Tattoo`, listens for `tattoo:sync`/`tattoo:applyResult`/`tattoo:removeResult`, emits `tattoo:apply`/`tattoo:remove` (consumed by `client/main.lua`, Task 6).

- [ ] **Step 1: Write `Icon.vue`**

```vue
<!-- plugins/oblsk_tattoo/web/Icon.vue -->
<template>
  <svg :width="size" :height="size" viewBox="0 0 24 24" fill="none" stroke="currentColor" :stroke-width="sw" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <component :is="shape.tag" v-for="(shape, i) in shapes" :key="i" v-bind="shape.attrs" />
  </svg>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  name: { type: String, required: true },
  size: { type: [Number, String], default: 16 },
  sw: { type: [Number, String], default: 1.6 },
})

const ICONS = {
  search: [
    { tag: 'circle', attrs: { cx: 11, cy: 11, r: 7 } },
    { tag: 'path', attrs: { d: 'M20 20l-3.5-3.5' } },
  ],
  close: [
    { tag: 'path', attrs: { d: 'M18 6 6 18' } },
    { tag: 'path', attrs: { d: 'M6 6l12 12' } },
  ],
  check: [{ tag: 'path', attrs: { d: 'M20 6 9 17l-5-5' } }],
  bank: [
    { tag: 'path', attrs: { d: 'M3 10 12 4l9 6' } },
    { tag: 'path', attrs: { d: 'M5 10v8M9 10v8M15 10v8M19 10v8M3 21h18' } },
  ],
}

const shapes = computed(() => ICONS[props.name] || ICONS.close)
</script>
```

- [ ] **Step 2: Write `routes.js`**

```js
// plugins/oblsk_tattoo/web/routes.js
export default [
  {
    path: '/Tattoo',
    name: 'Tattoo',
    component: () => import('./Tattoo.vue')
  }
]
```

- [ ] **Step 3: Write `Tattoo.vue`**

```vue
<!-- plugins/oblsk_tattoo/web/Tattoo.vue
     Full port of TattooUI (src/proto/tattoo.jsx): zone rail on the left,
     searchable book on the right. Card payment is delegated to the shared
     oblsk_payment picker (obelisk:payment) rather than reimplementing its
     own card fan, same as CarDealer.vue/Shop.vue. -->
<template>
  <div v-if="shop || catalog.length" class="absolute inset-0" style="font-family:var(--ob-font-sans)">
    <style>
      .tt-d{font-family:'Oswald','Geist',sans-serif;letter-spacing:.04em;font-weight:600}
      @keyframes ttIn{from{opacity:0;transform:translateX(-18px)}to{opacity:1;transform:none}}
      @keyframes ttUp{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}
      @keyframes ttInk{from{opacity:0;stroke-dasharray:120;stroke-dashoffset:120}to{opacity:1;stroke-dashoffset:0}}
    </style>

    <div class="absolute left-8 top-5 flex items-center gap-2.5" style="animation:ttIn .4s cubic-bezier(.16,.84,.24,1) both">
      <span class="ob-mono text-[11px] px-1.5 h-[22px] flex items-center rounded-[3px]" style="background:color-mix(in oklab, var(--ob-accent) 20%, transparent);border:1px solid var(--ob-accent);color:var(--ob-accent)">E</span>
      <span class="tt-d text-[16px] uppercase text-white/80">Tattoo Shop</span>
      <span v-if="shop?.free_mode" class="ml-3 ob-mono text-[10px] tracking-[0.16em] px-2.5 h-[24px] flex items-center rounded-[4px]" style="background:color-mix(in oklab, var(--ob-accent) 24%, transparent);border:1px solid var(--ob-accent);color:var(--ob-accent)">FREE INK</span>
    </div>
    <div class="absolute right-8 top-5 flex items-center gap-2 rounded-[6px] px-3 h-[34px]" style="background:rgba(9,12,12,.85);border:1px solid rgba(255,255,255,.12);animation:ttIn .4s cubic-bezier(.16,.84,.24,1) both">
      <span class="ob-mono text-[10.5px] px-1.5 h-[20px] flex items-center rounded-[3px]" style="background:rgba(255,255,255,.09);border:1px solid rgba(255,255,255,.18);color:#fff">ESC</span>
      <span class="text-[12px] text-white/55">Leave the studio</span>
    </div>

    <div class="absolute left-8 top-[68px] bottom-6 flex gap-3" style="width:700px;animation:ttIn .4s cubic-bezier(.16,.84,.24,1) both">
      <div class="shrink-0 flex flex-col gap-2" style="width:124px">
        <button v-for="[id, label] in ZONES" :key="id" @click="zone = id; mode = 'book'"
          class="relative h-[54px] rounded-[6px] grid place-items-center tt-d text-[12px] uppercase transition"
          :style="{
            background: zone === id ? 'color-mix(in oklab, var(--ob-accent) 22%, transparent)' : 'rgba(9,12,12,.78)',
            border: `1px solid ${zone === id ? 'var(--ob-accent)' : 'rgba(255,255,255,.09)'}`,
            color: zone === id ? '#fff' : 'rgba(255,255,255,.62)',
          }">{{ label }}</button>
        <button @click="mode = mode === 'preview' ? 'book' : 'preview'; zone = 'all'; sel = null"
          class="mt-auto h-[54px] rounded-[6px] grid place-items-center tt-d text-[12px] uppercase transition hover:brightness-125"
          :style="{
            background: mode === 'preview' ? 'color-mix(in oklab, var(--ob-accent) 22%, transparent)' : 'rgba(9,12,12,.78)',
            border: `1px solid ${mode === 'preview' ? 'var(--ob-accent)' : 'rgba(255,255,255,.09)'}`,
            color: mode === 'preview' ? 'var(--ob-accent)' : 'rgba(255,255,255,.62)',
          }">
          <span class="text-center leading-tight">Preview<br /><span class="ob-mono text-[10px] text-white/45">{{ previewCount }} held</span></span>
        </button>
        <button @click="mode = mode === 'body' ? 'book' : 'body'; zone = 'all'; sel = null"
          class="h-[54px] rounded-[6px] grid place-items-center tt-d text-[12px] uppercase transition hover:brightness-125"
          :style="{
            background: mode === 'body' ? 'color-mix(in oklab, var(--ob-accent) 22%, transparent)' : 'rgba(9,12,12,.78)',
            border: `1px solid ${mode === 'body' ? 'var(--ob-accent)' : 'rgba(255,255,255,.09)'}`,
            color: mode === 'body' ? 'var(--ob-accent)' : 'rgba(255,255,255,.62)',
          }">
          <span class="text-center leading-tight">On the body<br /><span class="ob-mono text-[10px] text-white/45">{{ Object.keys(applied).length }} piece{{ Object.keys(applied).length === 1 ? '' : 's' }}</span></span>
        </button>
      </div>

      <div class="flex-1 min-w-0 rounded-[10px] flex flex-col overflow-hidden" style="background:rgba(9,12,12,.78);border:1px solid rgba(255,255,255,.09)">
        <div class="shrink-0 p-4 flex gap-3 items-center" style="border-bottom:1px solid rgba(255,255,255,.07)">
          <div class="relative flex-1">
            <span class="absolute left-3 top-1/2 -translate-y-1/2 text-white/30"><Icon name="search" :size="14" /></span>
            <input v-model="q" :placeholder="mode === 'body' ? 'Search your ink…' : 'Search tattoos…'"
              class="w-full h-[42px] rounded-[6px] pl-9 pr-3 text-[14px] outline-none text-white"
              style="background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.11)" />
          </div>
        </div>

        <div class="flex-1 min-h-0 overflow-y-auto p-4">
          <template v-if="mode === 'preview'">
            <div v-if="previewCount === 0" class="h-full grid place-items-center text-center">
              <div>
                <div class="tt-d text-[15px] uppercase text-white/70">Nothing held against the skin</div>
                <div class="text-[12.5px] text-white/40 mt-1">pick a piece in the book and hit Preview — several can sit on the body at once</div>
              </div>
            </div>
            <template v-else>
              <div class="flex items-center mb-3">
                <span class="ob-mono text-[10px] tracking-[0.2em] text-white/40">HELD AGAINST THE SKIN · {{ previewCount }}</span>
                <button @click="previews = {}; mode = 'book'; zone = 'all'" class="ml-auto ob-mono text-[10px] tracking-[0.16em] px-2 h-[24px] rounded-[4px] text-white/60 transition hover:text-white hover:bg-white/10" style="border:1px solid rgba(255,255,255,.14)">CLEAR ALL</button>
              </div>
              <div class="grid gap-3.5" style="grid-template-columns:repeat(3, minmax(0, 1fr))">
                <div v-for="d in previewDesigns" :key="d.zone + d.name" class="relative rounded-[7px] overflow-hidden" style="background:rgba(255,255,255,.03);border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent)">
                  <div class="relative" style="height:150px;background:linear-gradient(160deg,rgba(255,255,255,.05),transparent)">
                    <svg viewBox="0 0 200 150" class="w-full h-full">
                      <TtMark :name="d.name" :box="{ x: 100, y: 75, w: 112, h: 84 }" ink="color-mix(in oklab, var(--ob-accent) 55%, #ffffff)" preview />
                    </svg>
                    <span class="absolute left-2 top-2 w-[16px] h-[16px] rounded-full" :style="{ background: ink, border: '1px solid rgba(255,255,255,.35)' }" />
                    <div class="absolute right-2 bottom-2 ob-mono text-[9.5px] tracking-[0.14em] px-1.5 h-[19px] flex items-center rounded-[3px]" style="background:rgba(0,0,0,.75);color:rgba(255,255,255,.72)">{{ zoneLabel(d.zone) }}</div>
                  </div>
                  <div class="p-2.5" style="border-top:1px solid rgba(255,255,255,.08)">
                    <div class="text-[13px] font-semibold truncate">{{ d.name }}</div>
                    <div class="flex gap-1.5 mt-2">
                      <button @click="togglePreview(d)" class="h-[32px] px-3 rounded-[5px] tt-d text-[11.5px] uppercase transition hover:bg-white/[0.09]" style="border:1px solid rgba(255,255,255,.16);color:rgba(255,255,255,.75)">Drop</button>
                      <button @click="start(d)" class="flex-1 h-[32px] rounded-[5px] tt-d text-[11.5px] uppercase transition hover:brightness-110" style="background:var(--ob-accent);color:#04120d">
                        {{ isFree ? 'Apply' : `Ink · $${d.price.toLocaleString()}` }}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </template>
          </template>

          <template v-else-if="mode === 'body'">
            <div v-if="Object.keys(applied).length === 0" class="h-full grid place-items-center text-[13px] text-white/35">No ink on you yet.</div>
            <div v-else class="grid gap-3.5" style="grid-template-columns:repeat(3, minmax(0, 1fr))">
              <div v-for="[z, d] in appliedFiltered" :key="z" class="relative rounded-[7px] overflow-hidden" style="background:rgba(255,255,255,.035);border:1px solid rgba(255,255,255,.09)">
                <div class="relative" style="height:150px;background:linear-gradient(160deg,rgba(255,255,255,.05),transparent)">
                  <svg viewBox="0 0 200 150" class="w-full h-full">
                    <TtMark :name="d.designName" :box="{ x: 100, y: 75, w: 112, h: 84 }" ink="rgba(255,255,255,.85)" :q="d.quality" preview />
                  </svg>
                  <span class="absolute right-2 top-7 w-[16px] h-[16px] rounded-full" :style="{ background: d.inkHex, border: '1px solid rgba(255,255,255,.35)' }" />
                  <div class="absolute left-2 top-2 ob-mono text-[9.5px] tracking-[0.14em] px-1.5 h-[19px] flex items-center rounded-[3px]" style="background:rgba(0,0,0,.75);color:rgba(255,255,255,.72)">{{ zoneLabel(z) }}</div>
                  <div v-if="d.grade" class="absolute right-2 top-2 ob-mono text-[9.5px] tracking-[0.14em] px-1.5 h-[19px] flex items-center rounded-[3px]" :style="{ background: 'rgba(0,0,0,.75)', color: (d.quality ?? 100) >= 70 ? 'var(--ob-accent)' : '#f59e0b' }">{{ d.grade }}</div>
                </div>
                <div class="p-2.5" style="border-top:1px solid rgba(255,255,255,.08)">
                  <div class="text-[13px] font-semibold truncate">{{ d.designName }}</div>
                  <button @click="laser = { zone: z, name: d.designName, ink: d.inkHex, price: removalPrice(d) }"
                    class="w-full h-[32px] mt-2 rounded-[5px] tt-d text-[11.5px] uppercase transition hover:brightness-110" style="background:rgba(120,26,30,.5);border:1px solid rgba(206,62,68,.5);color:#ffd9da">
                    {{ isFree ? 'Laser it off' : `Laser · $${removalPrice(d).toLocaleString()}` }}
                  </button>
                </div>
              </div>
            </div>
          </template>

          <template v-else>
            <div v-if="!list.length" class="h-full grid place-items-center text-[13px] text-white/35">Nothing in the book matches.</div>
            <div v-else class="grid gap-3.5" style="grid-template-columns:repeat(3, minmax(0, 1fr))">
              <div v-for="d in list" :key="d.name" @click="sel = sel === d.name ? null : d.name"
                class="relative rounded-[7px] overflow-hidden cursor-pointer transition"
                :style="{
                  background: sel === d.name ? 'color-mix(in oklab, var(--ob-accent) 8%, transparent)' : 'rgba(255,255,255,.035)',
                  border: `1px solid ${sel === d.name || previews[pvKey(d)] ? 'var(--ob-accent)' : 'rgba(255,255,255,.09)'}`,
                }">
                <div class="relative" style="height:150px;background:linear-gradient(160deg,rgba(255,255,255,.05),transparent)">
                  <svg viewBox="0 0 200 150" class="w-full h-full">
                    <TtMark :name="d.name" :box="{ x: 100, y: 75, w: 112, h: 84 }" ink="color-mix(in oklab, var(--ob-accent) 55%, #ffffff)" preview />
                  </svg>
                  <div class="absolute left-2 top-2 ob-mono text-[12px] px-1.5 h-[22px] flex items-center rounded-[4px]" :style="{ background: 'rgba(0,0,0,.72)', color: isFree ? 'var(--ob-accent)' : '#fff' }">
                    {{ isFree ? 'FREE' : `${d.price.toLocaleString()}$` }}
                  </div>
                  <div class="absolute right-2 bottom-2 ob-mono text-[9.5px] tracking-[0.14em] px-1.5 h-[19px] flex items-center rounded-[3px]" style="background:rgba(0,0,0,.75);color:rgba(255,255,255,.72)">{{ zoneLabel(d.zone) }}</div>
                  <div v-if="applied[d.zone]?.designName === d.name" class="absolute left-2 bottom-2 w-[20px] h-[20px] rounded-full grid place-items-center" style="background:var(--ob-accent);color:#04120d"><Icon name="check" :size="12" /></div>
                  <div v-if="previews[pvKey(d)]" class="absolute inset-0 grid place-items-center ob-mono text-[10px] tracking-[0.2em]" style="background:color-mix(in oklab, var(--ob-accent) 16%, rgba(0,0,0,.35));color:var(--ob-accent)">PREVIEWING</div>
                </div>
                <div class="px-2.5 py-2 flex items-baseline gap-2" style="border-top:1px solid rgba(255,255,255,.08)">
                  <span class="text-[12.5px] font-semibold truncate">{{ d.name }}</span>
                </div>
                <div v-if="sel === d.name" class="flex gap-1.5 p-2 pt-0">
                  <button @click.stop="togglePreview(d)" class="flex-1 h-[32px] rounded-[5px] tt-d text-[11.5px] uppercase transition hover:bg-white/[0.09]" style="border:1px solid rgba(255,255,255,.16);color:rgba(255,255,255,.8)">
                    {{ previews[pvKey(d)] ? 'Stop preview' : 'Preview' }}
                  </button>
                  <button @click.stop="start(d)" class="flex-1 h-[32px] rounded-[5px] tt-d text-[11.5px] uppercase transition hover:brightness-110" style="background:var(--ob-accent);color:#04120d">
                    {{ isFree ? 'Apply' : `Ink · $${d.price.toLocaleString()}` }}
                  </button>
                </div>
              </div>
            </div>
          </template>
        </div>
      </div>
    </div>

    <TtLaserGame v-if="laser" :design="laser.name" :ink="laser.ink" :price="laser.price" :free="isFree"
      @cancel="laser = null" @done="onLaserDone" />
    <TtNeedleGame v-if="game" :design="game.design" :ink="game.ink" :price="game.price" :free="isFree"
      @done="onNeedleDone" @cancel="game = null" />

    <div v-if="pay && bill" class="absolute inset-0 z-[60] flex items-end justify-center" style="background:rgba(0,0,0,.66)" @click.self="cancelBill">
      <div class="w-full max-w-[880px] pb-10" @click.stop>
        <div class="text-center mb-5">
          <div class="ob-mono text-[10px] tracking-[0.25em]" style="color:var(--ob-accent)">HOW ARE YOU PAYING?</div>
          <div class="tt-d text-[19px] mt-1.5 uppercase">{{ bill.name }} · {{ bill.grade }} · ${{ bill.paid.toLocaleString() }}</div>
        </div>
        <div class="flex justify-center gap-3">
          <button @click="payCash" class="w-[210px] h-[52px] rounded-[8px] tt-d text-[14px] flex items-center justify-center gap-2 transition hover:bg-white/[0.09]" style="background:rgba(9,12,12,.85);border:1px solid rgba(255,255,255,.16);color:#fff">
            <span class="ob-mono text-[13px]">$</span> CASH
          </button>
          <button @click="payCard" class="w-[210px] h-[52px] rounded-[8px] tt-d text-[14px] flex items-center justify-center gap-2 transition hover:brightness-110" style="background:var(--ob-accent);color:#04120d">
            <Icon name="bank" :size="16" /> CARD
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, inject, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'
import TtMark from './tattoo/TtMark.vue'
import TtNeedleGame from './tattoo/TtNeedleGame.vue'
import TtLaserGame from './tattoo/TtLaserGame.vue'
import Icon from './Icon.vue'

const payment = inject('obelisk:payment')

const ZONES = [
  ['all', 'All tattoos'], ['head', 'Head'], ['torso', 'Torso'],
  ['larm', 'Left Arm'], ['rarm', 'Right Arm'], ['lleg', 'Left Leg'], ['rleg', 'Right Leg'],
]
const ZLABEL = Object.fromEntries(ZONES.map(([id, l]) => [id, l.toUpperCase()]))
const INKS = ['#0b0f10', 'var(--ob-accent)', '#9f1239', '#4338ca', '#e7e5e4']

const shop = ref(null)
const catalog = ref([])
const appliedRows = ref([])
const zone = ref('all')
const q = ref('')
const ink = ref(INKS[0])
const sel = ref(null)
const previews = ref({})
const mode = ref('book')
const laser = ref(null)
const game = ref(null)
const bill = ref(null)
const pay = ref(null)

const isFree = computed(() => !!shop.value?.free_mode)
const applied = computed(() => Object.fromEntries(appliedRows.value.map(r => [r.zone, r])))
const appliedFiltered = computed(() => Object.entries(applied.value).filter(([z, d]) => !q.value.trim() || (d.designName + ZLABEL[z]).toLowerCase().includes(q.value.trim().toLowerCase())))
const previewCount = computed(() => Object.keys(previews.value).length)
const previewDesigns = computed(() => Object.values(previews.value).map(p => catalog.value.find(c => c.name === p.name && c.zone === p.zone)).filter(Boolean))
const list = computed(() => catalog.value.filter(d => (zone.value === 'all' || d.zone === zone.value) && (!q.value.trim() || d.name.toLowerCase().includes(q.value.trim().toLowerCase()))))

function zoneLabel(z) { return ZLABEL[z] || z.toUpperCase() }
function pvKey(d) { return `${d.zone}|${d.name}` }
function togglePreview(d) {
  const n = { ...previews.value }
  const k = pvKey(d)
  if (n[k]) delete n[k]; else n[k] = { zone: d.zone, name: d.name }
  previews.value = n
  if (!Object.keys(n).length) { mode.value = 'book'; zone.value = 'all' }
}
function removalPrice(d) { return Math.max(180, Math.round((d.pricePaid || 400) * 0.55)) }

function start(d) { game.value = { design: d.name, ink: ink.value, price: isFree.value ? 0 : d.price, zone: d.zone, designId: d.id } }

function onNeedleDone(res) {
  const paid = isFree.value ? 0 : Math.round(game.value.price * res.mult)
  if (!isFree.value && paid > 0) {
    bill.value = { kind: 'apply', name: game.value.design, zone: game.value.zone, designId: game.value.designId, inkHex: ink.value, quality: res.q, grade: res.grade, paid }
    game.value = null
    pay.value = 'method'
    return
  }
  submitApply({ ...game.value, quality: res.q, grade: res.grade }, 'cash', null)
  game.value = null
}

function onLaserDone(res) {
  const paid = isFree.value ? 0 : Math.round(laser.value.price * res.mult)
  if (!isFree.value && paid > 0) {
    bill.value = { kind: 'remove', name: laser.value.name, zone: laser.value.zone, paid }
    laser.value = null
    pay.value = 'method'
    return
  }
  submitRemove(laser.value.zone, 'cash', null)
  laser.value = null
}

function submitApply(g, method, cardId) {
  Obelisk.emit('tattoo:apply', { shopId: shop.value?.id, designId: g.designId, inkHex: g.ink || ink.value, quality: g.quality, grade: g.grade, method, cardId })
}
function submitRemove(z, method, cardId) {
  Obelisk.emit('tattoo:remove', { zone: z, method, cardId })
}

function payCash() {
  if (!bill.value) return
  if (bill.value.kind === 'apply') submitApply({ designId: bill.value.designId, ink: bill.value.inkHex, quality: bill.value.quality, grade: bill.value.grade }, 'cash', null)
  else submitRemove(bill.value.zone, 'cash', null)
  pay.value = null; bill.value = null
}
async function payCard() {
  if (!bill.value || !payment?.requestPayment) return
  const result = await payment.requestPayment({ amount: bill.value.paid, description: bill.value.name })
  if (!result.ok) return
  if (bill.value.kind === 'apply') submitApply({ designId: bill.value.designId, ink: bill.value.inkHex, quality: bill.value.quality, grade: bill.value.grade }, 'card', result.cardId)
  else submitRemove(bill.value.zone, 'card', result.cardId)
  pay.value = null; bill.value = null
}
function cancelBill() { pay.value = null; bill.value = null }

function onSync(payload) {
  shop.value = payload.shop
  catalog.value = payload.catalog
  appliedRows.value = payload.applied
}
function onApplyResult(result) {
  if (result.ok) {
    appliedRows.value = appliedRows.value.filter(r => r.zone !== result.zone)
    appliedRows.value.push({ zone: result.zone, designName: result.designName, inkHex: ink.value, quality: 100, grade: '', pricePaid: result.pricePaid })
    if (game.value) previews.value = {}
    sel.value = null
  }
}
function onRemoveResult(result) {
  if (result.ok) {
    appliedRows.value = appliedRows.value.filter(r => r.zone !== result.zone)
  }
}

function dismiss() { Obelisk.emit('core:client:close') }
function onKeydown(e) {
  if (e.key !== 'Escape') return
  if (game.value || laser.value) return
  if (pay.value) { pay.value = null; bill.value = null; return }
  if (previewCount.value) { previews.value = {}; return }
  dismiss()
}

onMounted(() => {
  Obelisk.on('tattoo:sync', onSync)
  Obelisk.on('tattoo:applyResult', onApplyResult)
  Obelisk.on('tattoo:removeResult', onRemoveResult)
  window.addEventListener('keydown', onKeydown)
})
onBeforeUnmount(() => {
  Obelisk.off('tattoo:sync', onSync)
  Obelisk.off('tattoo:applyResult', onApplyResult)
  Obelisk.off('tattoo:removeResult', onRemoveResult)
  window.removeEventListener('keydown', onKeydown)
})
</script>
```

- [ ] **Step 4: Commit**

```bash
git add web/Tattoo.vue web/Icon.vue web/routes.js
git commit -m "feat: port TattooUI as Tattoo.vue with DB-backed catalog/applied ink" -q
```

---

### Task 11: Register plugin, push repo, final verification

**Files:**
- Modify: `core/plugins/registry.json`

**Interfaces:** none (integration task).

- [ ] **Step 1: Register the plugin**

Edit `core/plugins/registry.json`, inserting `"oblsk_tattoo"` alphabetically between `"oblsk_speedometer"` and `"oblsk_terminal"`:

```json
{
  "plugins": [
    "oblsk_admin",
    "oblsk_banking",
    "oblsk_character-selection",
    "oblsk_deathscreen",
    "oblsk_garage",
    "oblsk_cardealer",
    "oblsk_hud",
    "oblsk_inventory",
    "oblsk_keybinds",
    "oblsk_licenses",
    "oblsk_mdt",
    "oblsk_notebook",
    "oblsk_notifications",
    "oblsk_payment",
    "oblsk_phone",
    "oblsk_phonebooth",
    "oblsk_progressbar",
    "oblsk_radialmenu",
    "oblsk_shop",
    "oblsk_speedometer",
    "oblsk_tattoo",
    "oblsk_terminal",
    "oblsk_tuner",
    "oblsk_vendingmachine"
  ]
}
```

- [ ] **Step 2: Run every test in the new plugin**

```bash
cd /home/andi/Projects/obelisk-framework/core
lua5.4 plugins/oblsk_tattoo/tests/tattoo_design_seeder_spec.lua
lua5.4 plugins/oblsk_tattoo/tests/tattoo_service_spec.lua
```

Expected: both report `N passed, 0 failed`

- [ ] **Step 3: Syntax-check every Lua file in the plugin**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
find . -name '*.lua' -not -path './tests/*' | xargs luac5.4 -p && echo "all syntax OK"
```

Expected: `all syntax OK`

- [ ] **Step 4: Commit the registry change (in the `core` repo)**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/registry.json
git commit -m "feat: register oblsk_tattoo plugin" -q
```

- [ ] **Step 5: Create the GitHub repo and push**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo
gh repo create Obelisk-Framework/oblsk_tattoo --private --source=. --remote=origin --push
```

Expected: repo created under the `Obelisk-Framework` org, `main` pushed with all task commits. If the org name differs from `Obelisk-Framework`, confirm the correct org before running (check `git -C ../oblsk_terminal remote -v` for the exact org slug).

- [ ] **Step 6: Verify the push**

```bash
git -C /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo log --oneline -5
git -C /home/andi/Projects/obelisk-framework/core/plugins/oblsk_tattoo remote -v
```

Expected: remote `origin` points at `git@github.com:Obelisk-Framework/oblsk_tattoo.git`, all commits from Tasks 1-10 present.
