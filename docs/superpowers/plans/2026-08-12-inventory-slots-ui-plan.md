# Inventory (slot-based) UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `oblsk_inventory` placeholder (fake local Vue arrays, no server) with a real slot-based inventory: main grid (45), hotbar (5), clothing (5 equip slots), up to 2 open containers stacked alongside, backed by `oblsk_items`' existing `Item`/`BaseItem` tables.

**Architecture:** Server owns all placement truth (`InventoryService`, pure functions over `QueryBuilder`, unit-testable with the project's `fake_query_builder` harness). Client Lua is a thin relay (`WebView.on` → `Obelisk.emitServer` → ... → `Obelisk.emitClient` → `WebView.emit`), mirroring `oblsk_garage` exactly. Vue is presentation + optimistic drag preview only; every move is server-validated and can be corrected by the next `inventory:sync`.

**Tech Stack:** Lua 5.4 (FXServer), Obelisk ORM (`QueryBuilder`/`Schema`), Vue 3 `<script setup>`, Tailwind (project-wide config, not CDN), no external DnD library — pointer events + `data-drop` attribute matching, same technique as the source prototype's `useDnd`.

## Global Constraints

- Only `'obelisk'` goes in `fxmanifest.lua`'s `dependencies {}` — `oblsk_items`' `Item`/`BaseItem` globals are available because core folds in all `modules/*` before plugins load (do not add `oblsk_items` as a dependency).
- Every mutating server function takes `source` first, re-resolves the caller's active character via `CharacterService.getActiveCharacterId(source)`, and re-validates ownership before writing — never trust a client-supplied owner id (same rule `GarageService` follows).
- DB boolean columns come back as `1`/`0`, never Lua `true`/`false`; any check against a raw DB row must normalize first (`isTruthyFlag`/`flagValue` helpers, copied from `GarageService.lua`).
- `Blueprint:dropColumn()` does not exist — column drops use the static `Schema.dropColumn(table, column)`, never a chained Blueprint method.
- Item data-shape convention this plan establishes (no prior precedent exists): equipable `BaseItem`s carry `data.equip` (string, one of `shirt`/`jacket`/`vest`/`shoes`/`bag`); container `BaseItem`s carry `data.slots` (integer slot count) and `data.capacity` (float kg). These are read, never written, by this plugin.
- Test specs run individually with `lua5.4 <path>` from the `core/` repo root (no aggregate runner covers plugin/module tests) — e.g. `lua5.4 plugins/oblsk_inventory/tests/inventory_service_spec.lua`.

---

### Task 1: Schema migration + remove the placeholder model

**Files:**
- Create: `core/plugins/oblsk_inventory/server/migrations/2026_08_12_070000_add_slot_fields_to_items_table.lua`
- Create: `core/plugins/oblsk_inventory/server/migrations.json`
- Delete: `core/plugins/oblsk_inventory/server/models/Inventory.lua`

**Interfaces:**
- Produces: `items.container` (string, default `'main'`), `items.slot` (nullable integer), `items.cloth_slot` (nullable string) — every later task reads/writes these three columns via `QueryBuilder.new('items')`.

- [ ] **Step 1: Write the migration**

```lua
-- core/plugins/oblsk_inventory/server/migrations/2026_08_12_070000_add_slot_fields_to_items_table.lua
--- Migration: Add slot placement fields to items table
--- Plugin-owned columns on the oblsk_items module's `items` table, same
--- cross-repo pattern as oblsk_garage's `garage_id` column on `vehicles`:
--- the module table stays generic, the plugin adds the columns whose
--- meaning it owns.
return {
    up = function()
        Schema.table('items', function(table)
            table:string('container', 20):default('main'):nullable()
            table:integer('slot'):nullable()
            table:string('cloth_slot', 20):nullable()
        end)
        print('[Migration] Added container/slot/cloth_slot fields to items table')
    end,
    down = function()
        Schema.dropColumn('items', 'container')
        Schema.dropColumn('items', 'slot')
        Schema.dropColumn('items', 'cloth_slot')
    end
}
```

- [ ] **Step 2: Register it**

```json
{ "migrations": [ "2026_08_12_070000_add_slot_fields_to_items_table" ] }
```

Write this to `core/plugins/oblsk_inventory/server/migrations.json`.

- [ ] **Step 3: Delete the placeholder model**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git rm server/models/Inventory.lua
```

- [ ] **Step 4: Commit**

```bash
git add server/migrations/2026_08_12_070000_add_slot_fields_to_items_table.lua server/migrations.json
git commit -m "Add slot placement columns to items, drop placeholder Inventory model"
```

---

### Task 2: InventoryService — placement logic (unit-tested, no NUI involved)

**Files:**
- Create: `core/plugins/oblsk_inventory/server/services/InventoryService.lua`
- Test: `core/plugins/oblsk_inventory/tests/inventory_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(table)` (`:where`, `:whereNull`, `:getSync`, `:firstSync`, `:insert`, `:update`, `:delete`) — global, real in production, faked in tests exactly like `GarageService`'s tests do.
- Produces (used by Task 3's event handlers):
  - `InventoryService.REGIONS` — `{ main = {slots=45}, hotbar = {slots=5}, ground = {slots=40} }`
  - `InventoryService.buildCharacterSync(characterId)` → `{ main = rows[], hotbar = rows[], cloth = {shirt=row|nil, jacket=row|nil, vest=row|nil, shoes=row|nil, bag=row|nil} }`
  - `InventoryService.buildContainerSync(containerItemId)` → `rows[]`
  - `InventoryService.move(source, itemId, toContainer, toSlot, toClothSlot, toOwnerType, toOwnerId)` → `boolean ok, string|nil reason`
  - `InventoryService.split(source, itemId, amount, toSlot)` → `boolean ok, string|nil reason, number|nil newItemId`
  - `InventoryService.use(source, itemId)` → `boolean ok, string|nil reason`
  - `InventoryService.equip(source, itemId, clothSlot)` → `boolean ok, string|nil reason`
  - `InventoryService.drop(source, itemId)` → `boolean ok, string|nil reason`
  - Each row shape: `{ id, base_item_id, name, icon, weight, is_stackable, max_stack_amount, is_container, data, amount, container, slot, cloth_slot }`

- [ ] **Step 1: Write the failing test**

```lua
-- core/plugins/oblsk_inventory/tests/inventory_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_inventory/tests/inventory_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

CharacterService = { sessionCharacters = { [999] = 5 } }
function CharacterService.getActiveCharacterId(source)
    return CharacterService.sessionCharacters[source]
end

dofile(scriptDir .. '../server/services/InventoryService.lua')

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

local function findItem(tables, id)
    for _, row in ipairs(tables.items) do
        if row.id == id then return row end
    end
end

local function seedBaseItems(tables)
    tables.base_items = {
        { id = 1, name = 'Pistol', icon = 'pistol.png', weight = 1.2, is_stackable = 0, max_stack_amount = 1, is_container = 0, data = {} },
        { id = 2, name = 'Bandage', icon = 'bandage.png', weight = 0.1, is_stackable = 1, max_stack_amount = 15, is_container = 0, data = {} },
        { id = 3, name = 'Backpack', icon = 'backpack.png', weight = 2.0, is_stackable = 0, max_stack_amount = 1, is_container = 1, data = { slots = 12, capacity = 20 } },
        { id = 4, name = 'T-Shirt', icon = 'tshirt.png', weight = 0.3, is_stackable = 0, max_stack_amount = 1, is_container = 0, data = { equip = 'shirt' } },
    }
end

test('InventoryService.move: moves an item into an empty main slot', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 1, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 1, data = {} },
        }

        local ok, reason = InventoryService.move(999, 100, 'main', 3, nil, 'character', 5)

        eq(ok, true)
        eq(reason, nil)
        eq(findItem(tables, 100).slot, 3)
    end)
end)

test('InventoryService.move: rejects a slot already occupied by a different item', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 1, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 1, data = {} },
            { id = 101, base_item_id = 1, owner_type = 'character', owner_id = 5, container = 'main', slot = 3, amount = 1, data = {} },
        }

        local ok, reason = InventoryService.move(999, 100, 'main', 3, nil, 'character', 5)

        eq(ok, false)
        eq(reason, 'slot occupied')
        eq(findItem(tables, 100).slot, 0, 'unchanged on rejection')
    end)
end)

test('InventoryService.move: merges into a same-item stackable slot up to max_stack_amount', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 2, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 10, data = {} },
            { id = 101, base_item_id = 2, owner_type = 'character', owner_id = 5, container = 'main', slot = 1, amount = 8, data = {} },
        }

        local ok, reason = InventoryService.move(999, 100, 'main', 1, nil, 'character', 5)

        eq(ok, true)
        eq(reason, nil)
        eq(findItem(tables, 101).amount, 15, 'capped at max_stack_amount (10+8=18, capped to 15)')
        eq(findItem(tables, 100).amount, 3, 'leftover 3 stays behind in its original slot')
    end)
end)

test('InventoryService.move: rejects moving a container into itself', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 3, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 1, data = {} },
        }

        local ok, reason = InventoryService.move(999, 100, 'main', 0, nil, 'item', 100)

        eq(ok, false)
        eq(reason, 'cannot hold itself')
    end)
end)

test('InventoryService.move: rejects equipping to a cloth slot the item is not made for', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 1, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 1, data = {} },
        }

        local ok, reason = InventoryService.move(999, 100, 'cloth', nil, 'shirt', 'character', 5)

        eq(ok, false)
        eq(reason, 'cannot be worn there')
    end)
end)

test('InventoryService.move: equips a shirt to the matching cloth slot', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 4, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 1, data = {} },
        }

        local ok, reason = InventoryService.move(999, 100, 'cloth', nil, 'shirt', 'character', 5)

        eq(ok, true)
        eq(reason, nil)
        local row = findItem(tables, 100)
        eq(row.container, 'cloth')
        eq(row.cloth_slot, 'shirt')
        eq(row.slot, nil)
    end)
end)

test('InventoryService.split: splits a stack, creating a new item row in the target slot', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 2, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 10, data = {} },
        }

        local ok, reason, newItemId = InventoryService.split(999, 100, 4, 1)

        eq(ok, true)
        eq(reason, nil)
        eq(findItem(tables, 100).amount, 6)
        local created = findItem(tables, newItemId)
        eq(created.amount, 4)
        eq(created.slot, 1)
        eq(created.base_item_id, 2)
    end)
end)

test('InventoryService.split: rejects splitting more than the stack holds', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 2, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 10, data = {} },
        }

        local ok, reason = InventoryService.split(999, 100, 10, 1)

        eq(ok, false)
        eq(reason, 'not enough to split')
    end)
end)

test('InventoryService.buildCharacterSync: groups items by container and cloth slot', function()
    withFakeDb(function(tables)
        seedBaseItems(tables)
        tables.items = {
            { id = 100, base_item_id = 1, owner_type = 'character', owner_id = 5, container = 'main', slot = 0, amount = 1, data = {} },
            { id = 101, base_item_id = 2, owner_type = 'character', owner_id = 5, container = 'hotbar', slot = 0, amount = 3, data = {} },
            { id = 102, base_item_id = 4, owner_type = 'character', owner_id = 5, container = 'cloth', slot = nil, cloth_slot = 'shirt', amount = 1, data = {} },
        }

        local sync = InventoryService.buildCharacterSync(5)

        eq(#sync.main, 1)
        eq(sync.main[1].id, 100)
        eq(#sync.hotbar, 1)
        eq(sync.hotbar[1].id, 101)
        eq(sync.cloth.shirt.id, 102)
        eq(sync.cloth.jacket, nil)
    end)
end)

local totalPassed = 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        totalPassed = totalPassed + 1
        print('  ok   - ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL - ' .. t.name)
    end
end

print('')
print(totalPassed .. ' passed, ' .. #failures .. ' failed')
if #failures > 0 then
    for _, f in ipairs(failures) do
        print('')
        print('FAIL: ' .. f.name)
        print(f.err)
    end
    os.exit(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/andi/Projects/obelisk-framework/core && lua5.4 plugins/oblsk_inventory/tests/inventory_service_spec.lua`
Expected: FAIL — `attempt to call a nil value (global 'InventoryService')` or file-not-found on the `dofile` of `InventoryService.lua`.

- [ ] **Step 3: Write InventoryService.lua**

```lua
-- core/plugins/oblsk_inventory/server/services/InventoryService.lua
--- InventoryService - placement logic for items in a character's main
--- grid, hotbar, clothing slots, and opened containers. Every mutating
--- call re-resolves the caller's active character server-side; never
--- trust a client-supplied owner id.
InventoryService = {}

InventoryService.REGIONS = {
    main = { slots = 45 },
    hotbar = { slots = 5 },
    ground = { slots = 40 },
}

local CLOTH_SLOTS = { shirt = true, jacket = true, vest = true, shoes = true, bag = true }

--- MySQL/Postgres return boolean columns as 1/0, never reliably as Lua
--- true/false. See GarageService.lua for the same convention.
local function isTruthyFlag(v)
    return v == true or v == 1 or v == '1'
end

--- @param itemRow table raw items row
--- @param baseItemRow table raw base_items row
--- @return table the client-facing row shape
local function toSyncRow(itemRow, baseItemRow)
    return {
        id = itemRow.id,
        base_item_id = itemRow.base_item_id,
        name = baseItemRow.name,
        icon = baseItemRow.icon,
        weight = baseItemRow.weight,
        is_stackable = isTruthyFlag(baseItemRow.is_stackable),
        max_stack_amount = baseItemRow.max_stack_amount,
        is_container = isTruthyFlag(baseItemRow.is_container),
        data = itemRow.data,
        amount = itemRow.amount,
        container = itemRow.container,
        slot = itemRow.slot,
        cloth_slot = itemRow.cloth_slot,
    }
end

--- @param itemRows table[] raw items rows
--- @return table[] sync rows, base_items joined in one batch query
local function joinBaseItems(itemRows)
    if #itemRows == 0 then return {} end
    local baseItemIds = {}
    for _, row in ipairs(itemRows) do baseItemIds[row.base_item_id] = true end
    local ids = {}
    for id in pairs(baseItemIds) do table.insert(ids, id) end

    local baseItems = QueryBuilder.new('base_items'):whereIn('id', ids):getSync()
    local byId = {}
    for _, b in ipairs(baseItems) do byId[b.id] = b end

    local rows = {}
    for _, item in ipairs(itemRows) do
        local baseItem = byId[item.base_item_id]
        if baseItem then table.insert(rows, toSyncRow(item, baseItem)) end
    end
    return rows
end

--- @param characterId number
--- @return table { main = rows[], hotbar = rows[], cloth = {slotKey -> row|nil} }
function InventoryService.buildCharacterSync(characterId)
    local rows = QueryBuilder.new('items')
        :where('owner_type', 'character')
        :where('owner_id', characterId)
        :getSync()

    local byContainer = { main = {}, hotbar = {}, cloth = {} }
    for _, row in ipairs(rows) do
        table.insert(byContainer[row.container] or byContainer.main, row)
    end

    local cloth = {}
    for slotKey in pairs(CLOTH_SLOTS) do cloth[slotKey] = nil end
    local clothSync = joinBaseItems(byContainer.cloth)
    for i, row in ipairs(clothSync) do
        cloth[byContainer.cloth[i].cloth_slot] = row
    end

    return {
        main = joinBaseItems(byContainer.main),
        hotbar = joinBaseItems(byContainer.hotbar),
        cloth = cloth,
    }
end

--- @param containerItemId number
--- @return table[] sync rows of everything owned by that container item
function InventoryService.buildContainerSync(containerItemId)
    local rows = QueryBuilder.new('items')
        :where('owner_type', 'item')
        :where('owner_id', containerItemId)
        :getSync()
    return joinBaseItems(rows)
end

--- @param itemId number
--- @return table|nil item, table|nil baseItem
local function loadItemAndBase(itemId)
    local item = QueryBuilder.new('items'):where('id', itemId):firstSync()
    if not item then return nil, nil end
    local baseItem = QueryBuilder.new('base_items'):where('id', item.base_item_id):firstSync()
    return item, baseItem
end

--- @param source number
--- @param itemId number
--- @return boolean ok, string|nil reason, table|nil item, table|nil baseItem
local function checkOwnership(source, itemId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return false, 'no active character', nil, nil end

    local item, baseItem = loadItemAndBase(itemId)
    if not item then return false, 'item not found', nil, nil end
    if not baseItem then return false, 'base item not found', nil, nil end

    -- Character-owned directly, or inside a container ultimately owned by
    -- this character — walk up at most one level (containers cannot nest
    -- inside containers in v1, matching the source prototype).
    if item.owner_type == 'character' and item.owner_id == characterId then
        return true, nil, item, baseItem
    end
    if item.owner_type == 'item' then
        local parent = QueryBuilder.new('items'):where('id', item.owner_id):firstSync()
        if parent and parent.owner_type == 'character' and parent.owner_id == characterId then
            return true, nil, item, baseItem
        end
    end
    return false, 'not the owner', nil, nil
end

--- @param toContainer string
--- @param toOwnerType string
--- @param toOwnerId number
--- @param slot number|nil
--- @param excludeItemId number
--- @return table|nil occupant row
local function findOccupant(toOwnerType, toOwnerId, toContainer, slot, excludeItemId)
    local rows = QueryBuilder.new('items')
        :where('owner_type', toOwnerType)
        :where('owner_id', toOwnerId)
        :where('container', toContainer)
        :where('slot', slot)
        :getSync()
    for _, row in ipairs(rows) do
        if row.id ~= excludeItemId then return row end
    end
    return nil
end

--- Move (or equip) an item. Validated server-side regardless of what the
--- client's optimistic drag preview showed.
--- @param source number
--- @param itemId number
--- @param toContainer string 'main' | 'hotbar' | 'ground' | 'cloth' | any opened container key
--- @param toSlot number|nil required unless toContainer == 'cloth'
--- @param toClothSlot string|nil required when toContainer == 'cloth'
--- @param toOwnerType string 'character' | 'item'
--- @param toOwnerId number characterId or the container item's id
--- @return boolean ok, string|nil reason
function InventoryService.move(source, itemId, toContainer, toSlot, toClothSlot, toOwnerType, toOwnerId)
    local ok, reason, item, baseItem = checkOwnership(source, itemId)
    if not ok then return false, reason end

    if isTruthyFlag(baseItem.is_container) and toOwnerType == 'item' and toOwnerId == itemId then
        return false, 'cannot hold itself'
    end

    if toContainer == 'cloth' then
        local equipSlot = baseItem.data and baseItem.data.equip
        if equipSlot ~= toClothSlot then return false, 'cannot be worn there' end
        local occupant = findOccupant(toOwnerType, toOwnerId, 'cloth', nil, itemId)
        if occupant then return false, 'slot occupied' end
        QueryBuilder.new('items'):where('id', itemId):update({
            container = 'cloth', slot = Database.NULL, cloth_slot = toClothSlot,
            owner_type = toOwnerType, owner_id = toOwnerId,
        })
        return true, nil
    end

    local occupant = findOccupant(toOwnerType, toOwnerId, toContainer, toSlot, itemId)
    if occupant then
        if occupant.base_item_id == item.base_item_id and isTruthyFlag(baseItem.is_stackable) then
            local room = baseItem.max_stack_amount - occupant.amount
            if room <= 0 then return false, 'slot occupied' end
            local moved = math.min(room, item.amount)
            local leftover = item.amount - moved
            QueryBuilder.new('items'):where('id', occupant.id):update({ amount = occupant.amount + moved })
            if leftover > 0 then
                QueryBuilder.new('items'):where('id', itemId):update({ amount = leftover })
            else
                QueryBuilder.new('items'):where('id', itemId):delete()
            end
            return true, nil
        end
        return false, 'slot occupied'
    end

    QueryBuilder.new('items'):where('id', itemId):update({
        container = toContainer, slot = toSlot, cloth_slot = Database.NULL,
        owner_type = toOwnerType, owner_id = toOwnerId,
    })
    return true, nil
end

--- @param source number
--- @param itemId number
--- @param amount number how many to move into the new stack (must be < current amount)
--- @param toSlot number
--- @return boolean ok, string|nil reason, number|nil newItemId
function InventoryService.split(source, itemId, amount, toSlot)
    local ok, reason, item = checkOwnership(source, itemId)
    if not ok then return false, reason, nil end
    if amount <= 0 or amount >= item.amount then return false, 'not enough to split', nil end

    local occupant = findOccupant(item.owner_type, item.owner_id, item.container, toSlot, itemId)
    if occupant then return false, 'slot occupied', nil end

    QueryBuilder.new('items'):where('id', itemId):update({ amount = item.amount - amount })
    local newItemId = QueryBuilder.new('items'):insert({
        base_item_id = item.base_item_id, owner_type = item.owner_type, owner_id = item.owner_id,
        container = item.container, slot = toSlot, cloth_slot = Database.NULL,
        amount = amount, data = item.data,
    })
    return true, nil, newItemId
end

--- @param source number
--- @param itemId number
--- @return boolean ok, string|nil reason
function InventoryService.use(source, itemId)
    local ok, reason, item, baseItem = checkOwnership(source, itemId)
    if not ok then return false, reason end
    if not isTruthyFlag(baseItem.is_useable) then return false, 'cannot be used' end

    if item.amount > 1 then
        QueryBuilder.new('items'):where('id', itemId):update({ amount = item.amount - 1 })
    else
        QueryBuilder.new('items'):where('id', itemId):delete()
    end
    return true, nil
end

--- @param source number
--- @param itemId number
--- @param clothSlot string
--- @return boolean ok, string|nil reason
function InventoryService.equip(source, itemId, clothSlot)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return false, 'no active character' end
    return InventoryService.move(source, itemId, 'cloth', nil, clothSlot, 'character', characterId)
end

--- @param source number
--- @param itemId number
--- @return boolean ok, string|nil reason
function InventoryService.drop(source, itemId)
    local ok, reason, item, baseItem = checkOwnership(source, itemId)
    if not ok then return false, reason end
    if not isTruthyFlag(baseItem.is_dropable) then return false, 'cannot be dropped' end

    local slot = nil
    for i = 0, InventoryService.REGIONS.ground.slots - 1 do
        if not findOccupant('ground', 0, 'ground', i, itemId) then slot = i break end
    end
    if slot == nil then return false, 'ground is full' end

    QueryBuilder.new('items'):where('id', itemId):update({
        container = 'ground', slot = slot, cloth_slot = Database.NULL,
        owner_type = 'ground', owner_id = 0,
    })
    return true, nil
end

--- Not implemented in v1 — needs real player-proximity data this plugin
--- doesn't have. See the design spec's Scope section.
--- @return boolean ok, string reason
function InventoryService.give(source, itemId, targetSource)
    return false, 'not implemented'
end

return InventoryService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/andi/Projects/obelisk-framework/core && lua5.4 plugins/oblsk_inventory/tests/inventory_service_spec.lua`
Expected: `9 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add server/services/InventoryService.lua tests/inventory_service_spec.lua
git commit -m "Add InventoryService: server-validated slot placement"
```

---

### Task 3: Server event wiring + open action

**Files:**
- Modify: `core/plugins/oblsk_inventory/server/main.lua` (create — currently doesn't exist beyond the deleted model)
- Modify: `core/plugins/oblsk_inventory/fxmanifest.lua` (verify `server_scripts { 'server/**/*.lua' }` already covers `main.lua` and `services/*.lua` — no change needed, confirm by reading the file)

**Interfaces:**
- Consumes: `InventoryService.*` (Task 2), `Obelisk.onServer`/`Obelisk.emitClient` (core), `ActionService.register` (core), `KeybindService.registerGlobal` (core), `WebView.openPage`/`WebView.focus` (core server-side proxy), `CharacterService.getActiveCharacterId` (oblsk_characters, loaded as a module before plugins).
- Produces: net events `inventory:client:move`, `inventory:client:split`, `inventory:client:use`, `inventory:client:equip`, `inventory:client:drop`, `inventory:client:give`, `inventory:client:openContainer`; pushes `inventory:server:sync` and `inventory:server:containerSync` to the client.

- [ ] **Step 1: Write server/main.lua**

```lua
-- core/plugins/oblsk_inventory/server/main.lua
local function notifyFailure(source, title, reason)
    NotificationService.notify(source, { type = 'error', title = title, description = reason })
end

local function pushSync(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    Obelisk.emitClient('inventory:server:sync', source, InventoryService.buildCharacterSync(characterId))
end

ActionService.register('inventory:open', function(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    WebView.openPage(source, '/Inventory')
    WebView.focus(source)
    pushSync(source)
end, { label = 'Open inventory' })

KeybindService.registerGlobal('TAB', 'inventory:open')

Obelisk.onServer('inventory:client:move', function(itemId, toContainer, toSlot, toClothSlot, toOwnerType, toOwnerId)
    local source = source
    local ok, reason = InventoryService.move(source, itemId, toContainer, toSlot, toClothSlot, toOwnerType, toOwnerId)
    if not ok then notifyFailure(source, 'Cannot move item', reason) end
    pushSync(source)
end)

Obelisk.onServer('inventory:client:split', function(itemId, amount, toSlot)
    local source = source
    local ok, reason = InventoryService.split(source, itemId, amount, toSlot)
    if not ok then notifyFailure(source, 'Cannot split', reason) end
    pushSync(source)
end)

Obelisk.onServer('inventory:client:use', function(itemId)
    local source = source
    local ok, reason = InventoryService.use(source, itemId)
    if not ok then notifyFailure(source, 'Cannot use item', reason) end
    pushSync(source)
end)

Obelisk.onServer('inventory:client:equip', function(itemId, clothSlot)
    local source = source
    local ok, reason = InventoryService.equip(source, itemId, clothSlot)
    if not ok then notifyFailure(source, 'Cannot equip', reason) end
    pushSync(source)
end)

Obelisk.onServer('inventory:client:drop', function(itemId)
    local source = source
    local ok, reason = InventoryService.drop(source, itemId)
    if not ok then notifyFailure(source, 'Cannot drop item', reason) end
    pushSync(source)
end)

Obelisk.onServer('inventory:client:give', function(itemId, targetSource)
    local source = source
    local ok, reason = InventoryService.give(source, itemId, targetSource)
    notifyFailure(source, 'Cannot give item', reason)
end)

Obelisk.onServer('inventory:client:openContainer', function(containerItemId)
    local source = source
    Obelisk.emitClient('inventory:server:containerSync', source, {
        containerItemId = containerItemId,
        items = InventoryService.buildContainerSync(containerItemId),
    })
end)
```

- [ ] **Step 2: Verify fxmanifest.lua needs no change**

Read `core/plugins/oblsk_inventory/fxmanifest.lua` and confirm `server_scripts { 'server/**/*.lua' }` is present (it already is, per Task 1's untouched file) — `main.lua` and `services/InventoryService.lua` are both picked up by the glob, no edit needed.

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add server/main.lua
git commit -m "Wire inventory server events and open action"
```

---

### Task 4: Client relay + keybind

**Files:**
- Create: `core/plugins/oblsk_inventory/client/main.lua`

**Interfaces:**
- Consumes: `WebView.on`/`WebView.emit` (core client Services), `Obelisk.emitServer`/`Obelisk.onClient` (core).
- Produces: nothing consumed by later tasks — this is the last backend link before the Vue side (Task 5+).

- [ ] **Step 1: Write client/main.lua**

```lua
-- core/plugins/oblsk_inventory/client/main.lua
WebView.on('inventory:move', function(data)
    Obelisk.emitServer('inventory:client:move', data.itemId, data.toContainer, data.toSlot, data.toClothSlot, data.toOwnerType, data.toOwnerId)
end)

WebView.on('inventory:split', function(data)
    Obelisk.emitServer('inventory:client:split', data.itemId, data.amount, data.toSlot)
end)

WebView.on('inventory:use', function(data)
    Obelisk.emitServer('inventory:client:use', data.itemId)
end)

WebView.on('inventory:equip', function(data)
    Obelisk.emitServer('inventory:client:equip', data.itemId, data.clothSlot)
end)

WebView.on('inventory:drop', function(data)
    Obelisk.emitServer('inventory:client:drop', data.itemId)
end)

WebView.on('inventory:give', function(data)
    Obelisk.emitServer('inventory:client:give', data.itemId, data.targetSource)
end)

WebView.on('inventory:openContainer', function(data)
    Obelisk.emitServer('inventory:client:openContainer', data.containerItemId)
end)

Obelisk.onClient('inventory:server:sync', function(payload)
    WebView.emit('inventory:sync', payload)
end)

Obelisk.onClient('inventory:server:containerSync', function(payload)
    WebView.emit('inventory:containerSync', payload)
end)
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add client/main.lua
git commit -m "Add inventory client NUI relay"
```

---

### Task 5: dnd.js — pointer-based drag composable

**Files:**
- Create: `core/plugins/oblsk_inventory/web/dnd.js`

**Interfaces:**
- Produces: `useDnd()` composable — `{ drag: Ref<{itemId, from, over}|null>, start(itemId, from, event) }`, consumed by Task 6 (`InventorySlot.vue`) and Task 8 (`PlayerBody.vue`).

- [ ] **Step 1: Write dnd.js**

```js
// core/plugins/oblsk_inventory/web/dnd.js
// Pointer-based drag/drop shared across every slot in the inventory. Native
// HTML5 DnD doesn't play well with overlapping floating panels (open
// containers stack beside the main grid), so this tracks pointer position
// directly and resolves the element under the cursor via elementFromPoint,
// reading each candidate's `data-drop` JSON attribute.
import { ref } from 'vue'

const drag = ref(null) // { itemId, from: {container, ownerType, ownerId}, over: object|null }

function resolveDropTarget(clientX, clientY) {
  const el = document.elementFromPoint(clientX, clientY)
  const target = el && el.closest('[data-drop]')
  if (!target) return null
  try { return JSON.parse(target.dataset.drop) } catch { return null }
}

export function useDnd() {
  function start(itemId, from, event) {
    if (event.button !== undefined && event.button !== 0) return
    drag.value = { itemId, from, over: null }

    const onMove = (e) => {
      drag.value = { ...drag.value, over: resolveDropTarget(e.clientX, e.clientY) }
    }
    const onUp = (e) => {
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      const finalOver = resolveDropTarget(e.clientX, e.clientY)
      const finished = { ...drag.value, over: finalOver }
      drag.value = null
      onUp.resolve && onUp.resolve(finished)
    }
    return new Promise((resolve) => {
      onUp.resolve = resolve
      window.addEventListener('pointermove', onMove)
      window.addEventListener('pointerup', onUp)
    })
  }

  return { drag, start }
}
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add web/dnd.js
git commit -m "Add pointer-based drag composable for inventory slots"
```

---

### Task 6: InventorySlot.vue — single slot

**Files:**
- Modify (full rewrite): `core/plugins/oblsk_inventory/web/InventorySlot.vue`

**Interfaces:**
- Consumes: `useDnd()` (Task 5).
- Produces: emits `context-menu(item, event)`, `drag-end(dropTarget)` — consumed by Task 8 (`Inventory.vue`).
- Props: `item: Object|null`, `dropInfo: Object` (`{container, ownerType, ownerId, slot|clothSlot}` — this slot's own drop-target identity).

- [ ] **Step 1: Write InventorySlot.vue**

```vue
<!-- core/plugins/oblsk_inventory/web/InventorySlot.vue -->
<template>
  <div
    class="relative rounded-md border flex items-center justify-center transition"
    :class="item ? 'border-white/15 bg-white/[0.07] hover:border-white/30 cursor-grab active:cursor-grabbing' : 'border-white/[0.06] bg-white/[0.02]'"
    :data-drop="JSON.stringify(dropInfo)"
    style="width:56px;height:56px"
    @pointerdown="onPointerDown"
    @contextmenu.prevent="item && $emit('context-menu', item, $event)"
  >
    <template v-if="item">
      <img v-if="item.icon" :src="item.icon" class="max-w-[85%] max-h-[85%] pointer-events-none" :alt="item.name" />
      <span v-else class="ob-mono text-[9px] text-white/40 pointer-events-none px-1 text-center leading-tight">{{ item.name }}</span>
      <span v-if="item.amount > 1" class="absolute bottom-0.5 right-1 ob-mono text-[10px] font-semibold bg-black/70 px-1 rounded">{{ item.amount }}</span>
    </template>
  </div>
</template>

<script setup>
import { useDnd } from './dnd.js'

const props = defineProps({
  item: { type: Object, default: null },
  dropInfo: { type: Object, required: true },
})
const emit = defineEmits(['context-menu', 'drag-end'])

const { start } = useDnd()

async function onPointerDown(e) {
  if (!props.item) return
  const from = { ...props.dropInfo }
  const result = await start(props.item.id, from, e)
  emit('drag-end', result)
}
</script>
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add web/InventorySlot.vue
git commit -m "Rewrite InventorySlot to match real item data shape"
```

---

### Task 7: ContextMenu.vue + SplitDialog.vue

**Files:**
- Create: `core/plugins/oblsk_inventory/web/ContextMenu.vue`
- Create: `core/plugins/oblsk_inventory/web/SplitDialog.vue`

**Interfaces:**
- Produces: `ContextMenu` emits `action(actionName, item)` — one of `'use'|'equip'|'split'|'drop'|'open'`; `close`. `SplitDialog` emits `confirm(amount)`, `cancel`. Both consumed by Task 8.
- Props: `ContextMenu` — `menu: {item, x, y}|null`. `SplitDialog` — `split: {item, max}|null`.

- [ ] **Step 1: Write ContextMenu.vue**

```vue
<!-- core/plugins/oblsk_inventory/web/ContextMenu.vue -->
<template>
  <div v-if="menu" class="fixed inset-0 z-[9998]" @click="$emit('close')" @contextmenu.prevent="$emit('close')">
    <div
      class="absolute rounded-md overflow-hidden shadow-2xl border border-white/12 bg-[#0b0e10] w-[160px]"
      :style="{ left: `${Math.min(menu.x, 1900 - 160)}px`, top: `${Math.min(menu.y, 1000 - 200)}px` }"
      @click.stop
    >
      <div class="px-3 py-2 border-b border-white/8 text-[12.5px] font-medium truncate">{{ menu.item.name }}</div>
      <button v-if="menu.item.is_useable" class="w-full text-left px-3 py-2 text-[12px] hover:bg-white/8" @click="act('use')">Use</button>
      <button v-if="menu.item.data && menu.item.data.equip" class="w-full text-left px-3 py-2 text-[12px] hover:bg-white/8" @click="act('equip')">Equip</button>
      <button v-if="menu.item.is_container" class="w-full text-left px-3 py-2 text-[12px] hover:bg-white/8" @click="act('open')">Open</button>
      <button v-if="menu.item.amount > 1" class="w-full text-left px-3 py-2 text-[12px] hover:bg-white/8" @click="act('split')">Split</button>
      <button class="w-full text-left px-3 py-2 text-[12px] hover:bg-white/8" @click="act('drop')">Drop</button>
    </div>
  </div>
</template>

<script setup>
const props = defineProps({ menu: { type: Object, default: null } })
const emit = defineEmits(['action', 'close'])
function act(name) {
  emit('action', name, props.menu.item)
  emit('close')
}
</script>
```

- [ ] **Step 2: Write SplitDialog.vue**

```vue
<!-- core/plugins/oblsk_inventory/web/SplitDialog.vue -->
<template>
  <div v-if="split" class="fixed inset-0 z-[9999] grid place-items-center bg-black/60" @click="$emit('cancel')">
    <div class="w-[280px] rounded-xl border border-white/12 bg-[#0b0e10] p-4 shadow-2xl" @click.stop>
      <div class="text-[13.5px] font-medium mb-1">Split {{ split.item.name }}</div>
      <div class="ob-mono text-[10px] text-white/35 mb-3">STACK OF {{ split.item.amount }}</div>
      <input
        type="number" min="1" :max="split.item.amount - 1" v-model.number="amount"
        class="w-full h-9 rounded-lg bg-black/45 border border-white/12 text-center ob-mono text-[14px] outline-none focus:border-[var(--ob-accent)]"
      />
      <div class="grid grid-cols-2 gap-2 mt-3">
        <button class="h-9 rounded-lg border border-white/12 text-[12.5px] hover:bg-white/8" @click="$emit('cancel')">Cancel</button>
        <button class="h-9 rounded-lg text-black text-[12.5px] font-semibold" style="background:var(--ob-accent)" @click="confirm">Split</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, watch } from 'vue'

const props = defineProps({ split: { type: Object, default: null } })
const emit = defineEmits(['confirm', 'cancel'])
const amount = ref(1)

watch(() => props.split, (s) => { if (s) amount.value = Math.floor(s.item.amount / 2) })

function confirm() {
  const max = props.split.item.amount - 1
  const clamped = Math.max(1, Math.min(max, amount.value || 1))
  emit('confirm', clamped)
}
</script>
```

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add web/ContextMenu.vue web/SplitDialog.vue
git commit -m "Add inventory context menu and split dialog"
```

---

### Task 8: PlayerBody.vue — clothing slots

**Files:**
- Create: `core/plugins/oblsk_inventory/web/PlayerBody.vue`

**Interfaces:**
- Props: `cloth: {shirt, jacket, vest, shoes, bag}` (each `Object|null`, the sync row shape from Task 2).
- Produces: emits `context-menu(item, event)`, `drag-end(dropTarget)` — same shape as `InventorySlot.vue`, consumed by Task 9.

- [ ] **Step 1: Write PlayerBody.vue**

```vue
<!-- core/plugins/oblsk_inventory/web/PlayerBody.vue -->
<template>
  <div class="relative w-full h-full grid place-items-center">
    <div class="w-40 h-72 rounded-full opacity-10 bg-white" style="clip-path:ellipse(45% 50% at 50% 50%)" />
    <div class="absolute inset-0 grid" style="grid-template-columns:1fr 1fr;grid-template-rows:repeat(3,1fr);gap:8px;padding:12px">
      <div class="flex flex-col items-center justify-center gap-1">
        <span class="ob-mono text-[9px] text-white/35">Shirt</span>
        <InventorySlot :item="cloth.shirt" :drop-info="{ container: 'cloth', clothSlot: 'shirt', ownerType: 'character', ownerId }" @context-menu="(...a) => $emit('context-menu', ...a)" @drag-end="(d) => $emit('drag-end', d)" />
      </div>
      <div class="flex flex-col items-center justify-center gap-1">
        <span class="ob-mono text-[9px] text-white/35">Jacket</span>
        <InventorySlot :item="cloth.jacket" :drop-info="{ container: 'cloth', clothSlot: 'jacket', ownerType: 'character', ownerId }" @context-menu="(...a) => $emit('context-menu', ...a)" @drag-end="(d) => $emit('drag-end', d)" />
      </div>
      <div class="flex flex-col items-center justify-center gap-1">
        <span class="ob-mono text-[9px] text-white/35">Vest</span>
        <InventorySlot :item="cloth.vest" :drop-info="{ container: 'cloth', clothSlot: 'vest', ownerType: 'character', ownerId }" @context-menu="(...a) => $emit('context-menu', ...a)" @drag-end="(d) => $emit('drag-end', d)" />
      </div>
      <div class="flex flex-col items-center justify-center gap-1">
        <span class="ob-mono text-[9px] text-white/35">Shoes</span>
        <InventorySlot :item="cloth.shoes" :drop-info="{ container: 'cloth', clothSlot: 'shoes', ownerType: 'character', ownerId }" @context-menu="(...a) => $emit('context-menu', ...a)" @drag-end="(d) => $emit('drag-end', d)" />
      </div>
      <div class="flex flex-col items-center justify-center gap-1">
        <span class="ob-mono text-[9px] text-white/35">Bag</span>
        <InventorySlot :item="cloth.bag" :drop-info="{ container: 'cloth', clothSlot: 'bag', ownerType: 'character', ownerId }" @context-menu="(...a) => $emit('context-menu', ...a)" @drag-end="(d) => $emit('drag-end', d)" />
      </div>
    </div>
  </div>
</template>

<script setup>
import InventorySlot from './InventorySlot.vue'

defineProps({
  cloth: { type: Object, required: true },
  ownerId: { type: Number, required: true },
})
defineEmits(['context-menu', 'drag-end'])
</script>
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add web/PlayerBody.vue
git commit -m "Add clothing slots panel"
```

---

### Task 9: Inventory.vue — root composition

**Files:**
- Modify (full rewrite): `core/plugins/oblsk_inventory/web/Inventory.vue`

**Interfaces:**
- Consumes: `InventorySlot.vue` (Task 6), `ContextMenu.vue`/`SplitDialog.vue` (Task 7), `PlayerBody.vue` (Task 8), `Obelisk` (`core/web/src/obelisk.js`, same import path `oblsk_garage` uses: `'../../../web/src/obelisk.js'`).
- Wire format from server (Task 3/4): `Obelisk.on('inventory:sync', payload)` where `payload = { main, hotbar, cloth }` (Task 2's `buildCharacterSync` shape); `Obelisk.on('inventory:containerSync', {containerItemId, items})`.

- [ ] **Step 1: Write Inventory.vue**

```vue
<!-- core/plugins/oblsk_inventory/web/Inventory.vue -->
<template>
  <div class="absolute inset-0 flex items-center justify-center" style="--ob-accent:#10b981" @keydown.esc="dismiss" tabindex="0">
    <div class="grid gap-3" :style="{ gridTemplateColumns: openContainers.length ? 'auto auto auto' : 'auto auto' }">
      <Panel>
        <PanelHead title="On person" :right="`${carriedWeight} kg`" />
        <div class="p-2.5 grid gap-1.5" style="grid-template-columns:repeat(9, 56px)">
          <InventorySlot
            v-for="i in 45" :key="`main-${i}`"
            :item="mainBySlot[i - 1] || null"
            :drop-info="{ container: 'main', slot: i - 1, ownerType: 'character', ownerId: characterId }"
            @context-menu="openMenu" @drag-end="onDragEnd"
          />
        </div>
        <div class="border-t border-white/8 p-2.5 flex gap-1.5 justify-center">
          <InventorySlot
            v-for="i in 5" :key="`hotbar-${i}`"
            :item="hotbarBySlot[i - 1] || null"
            :drop-info="{ container: 'hotbar', slot: i - 1, ownerType: 'character', ownerId: characterId }"
            @context-menu="openMenu" @drag-end="onDragEnd"
          />
        </div>
      </Panel>

      <Panel>
        <PanelHead title="Character" right="" />
        <div class="p-3" style="width:220px;height:340px">
          <PlayerBody :cloth="cloth" :owner-id="characterId" @context-menu="openMenu" @drag-end="onDragEnd" />
        </div>
      </Panel>

      <div v-if="openContainers.length" class="flex flex-col gap-3">
        <Panel v-for="c in openContainers" :key="c.containerItemId">
          <PanelHead :title="containerName(c.containerItemId)" right="" :closable="true" @close="closeContainer(c.containerItemId)" />
          <div class="p-2.5 grid gap-1.5" style="grid-template-columns:repeat(4, 56px)">
            <InventorySlot
              v-for="i in containerSlotCount(c.containerItemId)" :key="`c-${c.containerItemId}-${i}`"
              :item="byContainerSlot(c, i - 1)"
              :drop-info="{ container: 'container', slot: i - 1, ownerType: 'item', ownerId: c.containerItemId }"
              @context-menu="openMenu" @drag-end="onDragEnd"
            />
          </div>
        </Panel>
      </div>
    </div>

    <ContextMenu :menu="menu" @action="doAction" @close="menu = null" />
    <SplitDialog :split="split" @confirm="confirmSplit" @cancel="split = null" />
    <div v-if="toast" class="fixed left-1/2 -translate-x-1/2 bottom-10 z-[9997] rounded-lg border border-white/12 bg-black/85 px-4 py-2 text-[12px] shadow-2xl">{{ toast }}</div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'
import InventorySlot from './InventorySlot.vue'
import PlayerBody from './PlayerBody.vue'
import ContextMenu from './ContextMenu.vue'
import SplitDialog from './SplitDialog.vue'

const characterId = ref(null)
const main = ref([])
const hotbar = ref([])
const cloth = ref({ shirt: null, jacket: null, vest: null, shoes: null, bag: null })
const openContainers = ref([]) // [{ containerItemId, items }], max 2
const menu = ref(null)
const split = ref(null)
const toast = ref(null)

const mainBySlot = computed(() => Object.fromEntries(main.value.map(i => [i.slot, i])))
const hotbarBySlot = computed(() => Object.fromEntries(hotbar.value.map(i => [i.slot, i])))
const carriedWeight = computed(() => {
  const all = [...main.value, ...hotbar.value, ...Object.values(cloth.value).filter(Boolean)]
  return all.reduce((sum, i) => sum + i.weight * i.amount, 0).toFixed(1)
})

function flash(msg) { toast.value = msg; setTimeout(() => { toast.value = null }, 1600) }

function findAnyItem(id) {
  return main.value.find(i => i.id === id) || hotbar.value.find(i => i.id === id)
    || Object.values(cloth.value).find(i => i && i.id === id)
    || openContainers.value.flatMap(c => c.items).find(i => i.id === id) || null
}

function containerName(containerItemId) {
  const item = findAnyItem(containerItemId)
  return item ? item.name : 'Container'
}
function containerSlotCount(containerItemId) {
  const item = findAnyItem(containerItemId)
  return (item && item.data && item.data.slots) || 12
}
function byContainerSlot(c, slot) {
  return c.items.find(i => i.slot === slot) || null
}

function openMenu(item, event) {
  menu.value = { item, x: event.clientX, y: event.clientY }
}

function onDragEnd(result) {
  if (!result || !result.over || !result.from) return
  const item = findAnyItem(result.itemId)
  if (!item) return
  if (result.over.container === 'cloth') {
    Obelisk.emit('inventory:move', { itemId: result.itemId, toContainer: 'cloth', toClothSlot: result.over.clothSlot, toOwnerType: result.over.ownerType, toOwnerId: result.over.ownerId })
    return
  }
  Obelisk.emit('inventory:move', {
    itemId: result.itemId, toContainer: result.over.container, toSlot: result.over.slot,
    toOwnerType: result.over.ownerType, toOwnerId: result.over.ownerId,
  })
}

function doAction(action, item) {
  if (action === 'use') Obelisk.emit('inventory:use', { itemId: item.id })
  else if (action === 'equip') Obelisk.emit('inventory:equip', { itemId: item.id, clothSlot: item.data.equip })
  else if (action === 'drop') Obelisk.emit('inventory:drop', { itemId: item.id })
  else if (action === 'split') split.value = { item }
  else if (action === 'open') openContainer(item.id)
}

function confirmSplit(amount) {
  const item = split.value.item
  Obelisk.emit('inventory:split', { itemId: item.id, amount, toSlot: findFreeMainSlot() })
  split.value = null
}
function findFreeMainSlot() {
  const used = new Set(main.value.map(i => i.slot))
  for (let i = 0; i < 45; i++) if (!used.has(i)) return i
  return 0
}

function openContainer(containerItemId) {
  if (openContainers.value.some(c => c.containerItemId === containerItemId)) return
  openContainers.value = [...openContainers.value.slice(-1), { containerItemId, items: [] }]
  Obelisk.emit('inventory:openContainer', { containerItemId })
}
function closeContainer(containerItemId) {
  openContainers.value = openContainers.value.filter(c => c.containerItemId !== containerItemId)
}

function onSync(payload) {
  main.value = payload.main
  hotbar.value = payload.hotbar
  cloth.value = payload.cloth
  if (payload.main[0]) characterId.value = payload.main[0].owner_id
}
function onContainerSync(payload) {
  const existing = openContainers.value.find(c => c.containerItemId === payload.containerItemId)
  if (existing) existing.items = payload.items
}

function dismiss() {
  Obelisk.emit('core:client:close')
}

onMounted(() => {
  Obelisk.on('inventory:sync', onSync)
  Obelisk.on('inventory:containerSync', onContainerSync)
})
onBeforeUnmount(() => {
  Obelisk.off('inventory:sync', onSync)
  Obelisk.off('inventory:containerSync', onContainerSync)
})
</script>

<script>
// Small local components shared only within this file's template.
import { defineComponent, h } from 'vue'
export const Panel = defineComponent({
  props: ['className'],
  render() { return h('div', { class: 'rounded-xl border border-white/10 bg-black/45 backdrop-blur-xl flex flex-col overflow-hidden' }, this.$slots.default()) },
})
export const PanelHead = defineComponent({
  props: ['title', 'right', 'closable'],
  emits: ['close'],
  render() {
    return h('div', { class: 'h-10 px-3.5 flex items-center justify-between border-b border-white/8' }, [
      h('span', { class: 'text-[12.5px] font-medium' }, this.title),
      h('div', { class: 'flex items-center gap-2' }, [
        h('span', { class: 'ob-mono text-[10px] text-white/35' }, this.right),
        this.closable ? h('button', { class: 'text-white/35 hover:text-white', onClick: () => this.$emit('close') }, '✕') : null,
      ]),
    ])
  },
})
</script>

<style scoped>
.ob-mono { font-family: 'JetBrains Mono', ui-monospace, monospace; }
</style>
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_inventory
git add web/Inventory.vue
git commit -m "Rewrite Inventory.vue: real data, drag-drop, containers, context menu"
```

---

### Task 10: Manual verification

**Files:** none — this task is verification only.

- [ ] **Step 1: Run all new/changed Lua specs**

```bash
cd /home/andi/Projects/obelisk-framework/core
lua5.4 plugins/oblsk_inventory/tests/inventory_service_spec.lua
```
Expected: `9 passed, 0 failed`

- [ ] **Step 2: Run the full core test suite to confirm no regressions**

```bash
cd /home/andi/Projects/obelisk-framework/core
npm test
```
Expected: all existing `core/tests/*.lua` specs still pass (this plan touches no files under `core/tests/` or `core/server/ORM/`).

- [ ] **Step 3: Boot the dev stack and manually verify in the FXServer client**

Using this repo's Docker FXServer setup (`docker-compose.yml` at repo root), start the server, seed at least one character-owned item row per region (`main`, `hotbar`, one `cloth` shirt, one container item), press `TAB` in-game, and confirm:
- Grid renders items in their seeded slots, hotbar likewise, shirt shows in the cloth panel.
- Dragging an item to an empty main slot moves it; dragging onto an occupied slot with a different item swaps; dragging a stackable item onto a same-item stack merges up to `max_stack_amount`.
- Right-click → Split opens the dialog; confirming creates a second stack.
- Right-click → Open on a container item opens a third panel with that container's contents; opening a second container closes the first (max 2 open, per `openContainer`'s slice(-1)).
- Right-click → Equip on the shirt moves it into the cloth panel; right-click → Drop removes it from `main`/`hotbar`/`cloth` and it reappears via a `ground` container query (manually queryable via `QueryBuilder.new('items'):where('owner_type','ground'):getSync()` from an admin console, since the ground panel itself isn't wired to auto-open in this plan — flagged below).
- An invalid move (e.g. dragging a shirt onto a non-cloth slot with `toContainer: 'cloth'` bypassed) is rejected server-side and the next `inventory:sync` snaps it back.

**Known gap to flag, not fixed by this plan:** the ground container never auto-opens the way `oblsk_garage`'s design opens on proximity — the design spec scoped ground drops as a single unlocated bucket, but this plan doesn't wire a UI entry point to view it (no "nearby ground" panel is opened automatically). Follow-up: either auto-open the `ground` container on `inventory:open` (cheap, matches the source prototype's default-open ground panel) or leave it queryable-only until position-aware ground drops replace the bucket. Flag this for the user before considering the feature fully done.
