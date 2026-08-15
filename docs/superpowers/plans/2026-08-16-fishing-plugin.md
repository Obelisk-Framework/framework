# oblsk_fishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `oblsk_fishing`, a plugin that ports the design prototype's fishing minigame (cast → bite → reel → land) into a server-authoritative FiveM plugin, with admin-configurable per-spot/per-rod reward pools and an inventory-capacity guard on the grant.

**Architecture:** The server owns every random decision and every timing judgement (bite delay, needle sweep, hit/miss classification, reward pick) in a pure, unit-testable state machine (`FishingChallengeService`); the client only renders server-sent parameters and reports raw keypress events. A thin DB-aware layer (`FishingService`, `FishingSpotService`) resolves rod→pool config, gates casting on the `fishing.rod` item binding and bait, and grants the catch through a new capacity-checked `ItemService.hasCapacity` + `ItemService.add`. Reward pools are entirely admin-configured (no seeding) via a new admin-panel tab that lives in `oblsk_fishing`'s own `web/` dir and is wired into `oblsk_admin`'s existing tab list.

**Tech Stack:** Lua 5.4 (FXServer runtime), Vue 3 `<script setup>`, the existing Obelisk ORM (`QueryBuilder`/`Schema`/`BaseModel`), `lua5.4` for unit tests (no FiveM server needed for the pure-logic tests).

**Spec:** `docs/superpowers/specs/2026-08-16-fishing-plugin-design.md`

## Global Constraints

- Every plugin/module Lua file must load correctly under the shared single-Lua-state boot (`core/fxmanifest.lua` globs `modules/*/server/**/*.lua` and `plugins/*/server/**/*.lua`) — no two plugins may declare the same global table name.
- `ItemService.add`'s existing behavior must not change for any existing caller — `hasCapacity` is a new, separately-called function, never wired into `add` itself.
- Config globals must be namespaced per plugin (e.g. `FishingConfig`), matching `VendingMachineConfig`/`TerminalConfig` — never a bare `Config` global.
- New plugin binding requirements go in `shared/config.lua`'s `Config.Requires.bindings` table — `core/core/server/bootstrap.lua` auto-registers these from every entry in `plugins/registry.json`, so no manual `ItemService.registerRequirements` call is needed in `main.lua`.
- Pure logic (state machines, weighted-pick math, capacity math) must be unit-testable under vanilla `lua5.4` via `tests/support/fivem_stubs.lua` + `tests/support/fake_query_builder.lua` — anything touching real net events, NUI, or gameplay natives is manual-server-tested only, per `tests/README.md`.
- Run every test with: `lua5.4 <path/to/spec.lua>` from the repository root (`/home/andi/Projects/obelisk-framework/core`).

---

## Task 1: `ItemService.hasCapacity` — inventory slot/weight guard

**Files:**
- Modify: `modules/oblsk_items/server/services/ItemService.lua`
- Test: `modules/oblsk_items/tests/item_service_capacity_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(table):where(col,val):getSync()/:firstSync()` (existing ORM), `CharacterService.getActiveCharacterId(source)` (existing).
- Produces: `ItemService.hasCapacity(source, baseItem, amount, forceNewStack)` → `boolean ok, string|nil reason`. `ItemService.MaxSlots` (number, default `40`), `ItemService.MaxWeight` (number, default `30.0`) — public, mutable fields so tests and future admin tooling can override them, same posture as `LockpickChallengeService.MIN_ELAPSED_MS`.

- [ ] **Step 1: Write the failing test**

```lua
-- modules/oblsk_items/tests/item_service_capacity_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_items/tests/item_service_capacity_spec.lua
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

dofile(scriptDir .. '../server/services/ItemService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local FISH = { id = 10, weight = 2.0 }
local ROD = { id = 11, weight = 1.0, is_container = 1 }

local function withFreshState(seedItems, seedBaseItems, fn)
    local fake = makeFakeQueryBuilderModule({
        items = seedItems or {},
        base_items = seedBaseItems or {
            [1] = { id = 10, weight = 2.0 },
            [2] = { id = 11, weight = 1.0, is_container = 1 },
        },
    })
    QueryBuilder = fake
    ItemService.MaxSlots = 40
    ItemService.MaxWeight = 30.0
    fn(fake)
end

test('hasCapacity: true when well under both limits', function()
    withFreshState({}, nil, function()
        eq(ItemService.hasCapacity(999, FISH, 1), true)
    end)
end)

test('hasCapacity: false when the new stack would exceed MaxWeight', function()
    withFreshState({}, nil, function()
        ItemService.MaxWeight = 1.0
        local ok, reason = ItemService.hasCapacity(999, FISH, 1)
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

test('hasCapacity: false when the new stack would exceed MaxSlots', function()
    withFreshState({}, nil, function()
        ItemService.MaxSlots = 0
        local ok, reason = ItemService.hasCapacity(999, FISH, 1)
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

test('hasCapacity: merging into an existing stack only adds weight, not a slot', function()
    withFreshState({
        [1] = { id = 1, base_item_id = 10, owner_type = 'character', owner_id = 5, amount = 1 },
    }, nil, function()
        ItemService.MaxSlots = 1 -- exactly one slot already used by the existing stack
        eq(ItemService.hasCapacity(999, FISH, 1), true, 'merge must not require a second slot')
    end)
end)

test('hasCapacity: forceNewStack always counts a new slot, even with a mergeable stack present', function()
    withFreshState({
        [1] = { id = 1, base_item_id = 10, owner_type = 'character', owner_id = 5, amount = 1 },
    }, nil, function()
        ItemService.MaxSlots = 1
        eq(ItemService.hasCapacity(999, FISH, 1, true), false)
    end)
end)

test('hasCapacity: weight recurses into container contents', function()
    withFreshState({
        [1] = { id = 1, base_item_id = 11, owner_type = 'character', owner_id = 5, amount = 1 }, -- the rod bag, 1.0kg
        [2] = { id = 2, base_item_id = 10, owner_type = 'item', owner_id = 1, amount = 3 }, -- 3 fish inside it, 6.0kg
    }, nil, function()
        ItemService.MaxWeight = 7.5 -- 1.0 (bag) + 6.0 (contents) + 2.0 (new fish) = 9.0 > 7.5
        eq(ItemService.hasCapacity(999, FISH, 1), false)
        ItemService.MaxWeight = 9.0
        eq(ItemService.hasCapacity(999, FISH, 1), true)
    end)
end)

test('hasCapacity: no active character fails closed', function()
    withFreshState({}, nil, function()
        local ok, reason = ItemService.hasCapacity(1, FISH, 1)
        eq(ok, false)
        eq(reason ~= nil, true)
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

Run: `lua5.4 modules/oblsk_items/tests/item_service_capacity_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'hasCapacity')`

- [ ] **Step 3: Implement `hasCapacity` in `ItemService.lua`**

Add near the top of `modules/oblsk_items/server/services/ItemService.lua`, right after the `ItemService = {}` line:

```lua
--- Flat, framework-wide carry limits (not per-character for v1 — see
--- docs/superpowers/specs/2026-08-16-fishing-plugin-design.md). Public and
--- mutable so tests (and, later, an admin setting) can override them.
ItemService.MaxSlots = 40
ItemService.MaxWeight = 30.0
```

Then add, after `ItemService.remove` (i.e. after its closing `end` and before the `--- Binding registry` comment block):

```lua
--- Per-unit weight of a base_items row, scaled by a depleting item's
--- remaining step data the same way Item:getWeight() computes it for a
--- single instance — duplicated here (rather than reusing the Item model)
--- because hasCapacity works off raw base_items/items rows via
--- QueryBuilder, not loaded Item/BaseItem model instances.
--- @param base table base_items row
--- @param row table items row (may be nil for a not-yet-existing stack)
--- @return number
local function unitWeight(base, row)
    local w = base.weight or 0
    local key = base.step_key
    if key and base.step and row and row.data and base.data and row.data[key] and base.data[key] then
        return w * (row.data[key] / base.data[key])
    end
    return w
end

--- Total weight of everything a character carries: every top-level
--- character-owned stack, plus recursively every item stored inside a
--- container the character owns (owner_type = 'item', chained owner_id).
--- @param characterId number
--- @return number
local function totalCarriedWeight(characterId)
    local baseItemsById = {}
    local function base(id)
        if baseItemsById[id] == nil then
            baseItemsById[id] = QueryBuilder.new('base_items'):where('id', id):firstSync() or false
        end
        return baseItemsById[id] or nil
    end

    local total = 0
    local function sumOwnedBy(ownerType, ownerId)
        local rows = QueryBuilder.new('items'):where('owner_type', ownerType):where('owner_id', ownerId):getSync()
        for _, row in ipairs(rows) do
            local b = base(row.base_item_id)
            if b then
                total = total + unitWeight(b, row) * (row.amount or 1)
                sumOwnedBy('item', row.id) -- recurse into this row's own contents, if any
            end
        end
    end

    sumOwnedBy('character', characterId)
    return total
end

--- Whether granting `amount` of `baseItem` to `source`'s active character
--- would exceed ItemService.MaxSlots or ItemService.MaxWeight. Mirrors the
--- same existing-stack lookup ItemService.add itself does, so the
--- projection matches what add() will actually do.
--- @param source number
--- @param baseItem table base_items row
--- @param amount number
--- @param forceNewStack boolean|nil
--- @return boolean ok
--- @return string|nil reason
function ItemService.hasCapacity(source, baseItem, amount, forceNewStack)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'No active character'
    end

    local existing = not forceNewStack and QueryBuilder.new('items')
        :where('owner_type', 'character')
        :where('owner_id', characterId)
        :where('base_item_id', baseItem.id)
        :firstSync()

    local currentSlots = #QueryBuilder.new('items'):where('owner_type', 'character'):where('owner_id', characterId):getSync()
    local projectedSlots = currentSlots + (existing and 0 or 1)
    if projectedSlots > ItemService.MaxSlots then
        return false, 'Not enough inventory space'
    end

    local projectedWeight = totalCarriedWeight(characterId) + unitWeight(baseItem, nil) * amount
    if projectedWeight > ItemService.MaxWeight then
        return false, 'Too heavy to carry'
    end

    return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 modules/oblsk_items/tests/item_service_capacity_spec.lua`
Expected: `7 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add modules/oblsk_items/server/services/ItemService.lua modules/oblsk_items/tests/item_service_capacity_spec.lua
git commit -m "feat(items): add ItemService.hasCapacity slot/weight guard"
```

---

## Task 2: `ItemService.createBaseItem` — optional binding-key on create

**Files:**
- Modify: `modules/oblsk_items/server/services/ItemService.lua`
- Test: `modules/oblsk_items/tests/item_service_admin_spec.lua`

**Interfaces:**
- Consumes: `BaseItem:createSync(attributes)` (existing), `QueryBuilder.new('item_bindings')`.
- Produces: `ItemService.createBaseItem(attributes, bindingKey)` → `number|nil id, string|nil reason` (signature grows a second, optional param — every existing call site passes only `attributes`, which stays valid since `bindingKey` is `nil` by default).

- [ ] **Step 1: Write the failing test**

Add to `modules/oblsk_items/tests/item_service_admin_spec.lua`, in the `createBaseItem` section (after the existing `'createBaseItem: inserts a new row and returns its id'` test):

```lua
test('createBaseItem: with a bindingKey, upserts item_bindings to point at the new item', function()
    withFakeDb(function(tables)
        local id = ItemService.createBaseItem({ name = 'fishing rod', weight = 1.5 }, 'fishing.rod')
        truthy(id ~= nil)
        eq(#tables.item_bindings, 1)
        eq(tables.item_bindings[1].key, 'fishing.rod')
        eq(tables.item_bindings[1].base_item_id, id)
    end)
end)

test('createBaseItem: bindingKey rebinds an existing key to the new item', function()
    withFakeDb(function(tables)
        tables.base_items = { { id = 1, name = 'old rod', weight = 1.0 } }
        tables.item_bindings = { { id = 1, key = 'fishing.rod', base_item_id = 1 } }
        local id = ItemService.createBaseItem({ name = 'new rod', weight = 1.2 }, 'fishing.rod')
        truthy(id ~= nil)
        eq(#tables.item_bindings, 1, 'must update the existing row, not insert a second one')
        eq(tables.item_bindings[1].base_item_id, id)
    end)
end)

test('createBaseItem: without a bindingKey, leaves item_bindings untouched', function()
    withFakeDb(function(tables)
        local id = ItemService.createBaseItem({ name = 'plain item', weight = 0.5 })
        truthy(id ~= nil)
        eq(tables.item_bindings, nil)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 modules/oblsk_items/tests/item_service_admin_spec.lua`
Expected: FAIL on the first new test — `item_bindings` table missing/nil (createBaseItem doesn't write it yet)

- [ ] **Step 3: Implement**

In `modules/oblsk_items/server/services/ItemService.lua`, replace `ItemService.createBaseItem`:

```lua
--- @param attributes table see BaseItem.fillable for accepted keys
--- @param bindingKey string|nil if given, upserts an item_bindings row
---   pointing that key at the newly created item — the admin-panel
---   equivalent of a plugin calling ItemService.registerRequirements and an
---   operator hand-writing the item_bindings row. Does not check whether
---   any plugin has actually registered bindingKey as required; binding()
---   itself already warns on an unrequired key, that check doesn't need
---   duplicating here.
--- @return number|nil id, string|nil reason
function ItemService.createBaseItem(attributes, bindingKey)
    if not attributes.name or attributes.name == '' then
        return nil, 'Name is required'
    end
    local ok, result = pcall(function() return BaseItem:createSync(attributes) end)
    if not ok then
        return nil, 'Name already in use'
    end
    local id = result.attributes.id

    if bindingKey then
        local existingBinding = QueryBuilder.new('item_bindings'):where('key', bindingKey):firstSync()
        if existingBinding then
            QueryBuilder.new('item_bindings'):where('id', existingBinding.id):update({
                base_item_id = id,
                updated_at = Database.now(),
            })
        else
            QueryBuilder.new('item_bindings'):insert({
                key = bindingKey,
                base_item_id = id,
                updated_at = Database.now(),
            })
        end
        resolved[bindingKey] = nil
    end

    return id, nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 modules/oblsk_items/tests/item_service_admin_spec.lua`
Expected: `10 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add modules/oblsk_items/server/services/ItemService.lua modules/oblsk_items/tests/item_service_admin_spec.lua
git commit -m "feat(items): support binding an item to a key at creation time"
```

---

## Task 3: admin item-creation UI — binding key field

**Files:**
- Modify: `plugins/oblsk_admin/web/ItemsTab.vue`
- Modify: `plugins/oblsk_admin/server/items.lua`

**Interfaces:**
- Consumes: `ItemService.createBaseItem(attributes, bindingKey)` from Task 2.
- Produces: nothing consumed by later tasks — this is a leaf UI change. No unit test (NUI/Vue interaction, per `tests/README.md`'s "not unit-testable" carve-out); verified manually in Task 12's manual pass and via `npm run dev` in `web/`.

- [ ] **Step 1: Add the field to the create form**

In `plugins/oblsk_admin/web/ItemsTab.vue`, change `openCreate`:

```javascript
const openCreate = () => { createDraft.value = { name: '', description: '', weight: 0, max_stack_amount: 1, bindingKey: '' } }
```

And change `submitCreate`:

```javascript
const submitCreate = () => {
  const { bindingKey, ...attributes } = createDraft.value
  Obelisk.emit('admin:client:items-create', { attributes, bindingKey: bindingKey || null })
  createDraft.value = null
}
```

Add the input inside the `v-if="createDraft"` block, right after the weight input:

```html
<input v-model="createDraft.bindingKey" placeholder="Binding key (optional, e.g. fishing.rod)" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
```

- [ ] **Step 2: Pass it through server-side**

In `plugins/oblsk_admin/server/items.lua`, change the create handler:

```lua
Obelisk.onClient('admin:server:items-create', function(player, data)
    if not isAdmin(player) then return end
    local id, reason = ItemService.createBaseItem(data.attributes or {}, data.bindingKey)
    if not id then
        NotificationService.error(player, 'Items', reason)
    end
    replyWithList(player)
end)
```

- [ ] **Step 3: Manual verification**

Run: `cd web && npm run dev`, open the admin panel's Items tab, create an item with a binding key filled in, confirm no console errors. Full end-to-end binding verification (that `item_bindings` actually gets the row) happens live once `oblsk_fishing` registers the `fishing.rod` key in Task 4 — note that here rather than block on it.

- [ ] **Step 4: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_admin/web/ItemsTab.vue plugins/oblsk_admin/server/items.lua
git commit -m "feat(admin): bind an item to a key at creation time"
```

---

## Task 4: scaffold `oblsk_fishing` — repo, migrations, config

**Files:**
- Create: `plugins/oblsk_fishing/fxmanifest.lua`
- Create: `plugins/oblsk_fishing/shared/config.lua`
- Create: `plugins/oblsk_fishing/server/migrations.json`
- Create: `plugins/oblsk_fishing/server/migrations/2026_08_16_090000_create_fishing_spots_table.lua`
- Create: `plugins/oblsk_fishing/server/migrations/2026_08_16_090001_create_fishing_rod_pools_table.lua`
- Create: `plugins/oblsk_fishing/server/migrations/2026_08_16_090002_create_fishing_pool_entries_table.lua`
- Create: `plugins/oblsk_fishing/README.md`
- Modify: `plugins/registry.json`

**Interfaces:**
- Produces: the `fishing_spots`, `fishing_rod_pools`, `fishing_pool_entries` tables every later task's SQL/QueryBuilder calls target; the `fishing.rod` binding requirement declared here is what makes `ItemService.binding('fishing.rod')` resolve once an admin binds an item to it via Task 3's UI.

- [ ] **Step 1: `fxmanifest.lua`**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Fishing'
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

- [ ] **Step 2: `shared/config.lua`**

```lua
-- plugins/oblsk_fishing/shared/config.lua
FishingConfig = {}

FishingConfig.Debug = false

-- Bite window: once the fish bites, the player has this long (ms) to press
-- SPACE and set the hook. Server-enforced, see FishingChallengeService.
FishingConfig.BiteWindowMs = 1000
-- Fixed round-trip-latency allowance added on top of BiteWindowMs and every
-- reel-round deadline, so a legitimate press arriving right at the edge of
-- the window isn't rejected purely for network delay.
FishingConfig.LatencyToleranceMs = 150

-- Randomized delay (ms) before a cast gets a bite.
FishingConfig.CastDelayMinMs = 1600
FishingConfig.CastDelayMaxMs = 5400

FishingConfig.Requires = {
    bindings = {
        ['fishing.rod'] = {
            live = true,
            description = 'The item required to cast at a fishing spot',
            hint = 'Any base item — mark is_useable false, it is checked on cast, not used directly',
        },
    },
}

return FishingConfig
```

- [ ] **Step 3: migrations**

`plugins/oblsk_fishing/server/migrations.json`:

```json
{
  "migrations": [
    "2026_08_16_090000_create_fishing_spots_table",
    "2026_08_16_090001_create_fishing_rod_pools_table",
    "2026_08_16_090002_create_fishing_pool_entries_table"
  ]
}
```

`plugins/oblsk_fishing/server/migrations/2026_08_16_090000_create_fishing_spots_table.lua`:

```lua
-- plugins/oblsk_fishing/server/migrations/2026_08_16_090000_create_fishing_spots_table.lua
--- Migration: Create fishing_spots table
--- One row per admin-placed world spot. bait_item_id is optional — a spot
--- with none configured casts for free.
return {
    up = function()
        Schema.create('fishing_spots', function(table)
            table:id()
            table:string('label', 100)
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('range'):default(2.0)
            table:foreignId('bait_item_id'):nullable():constrained('base_items'):onDelete('SET NULL')
            table:boolean('enabled'):default(1)
            table:timestamps()
        end)

        print('[Migration] Created fishing_spots table')
    end,

    down = function()
        Schema.drop('fishing_spots')
        print('[Migration] Dropped fishing_spots table')
    end
}
```

`plugins/oblsk_fishing/server/migrations/2026_08_16_090001_create_fishing_rod_pools_table.lua`:

```lua
-- plugins/oblsk_fishing/server/migrations/2026_08_16_090001_create_fishing_rod_pools_table.lua
--- Migration: Create fishing_rod_pools table
--- Scopes a reward pool to (spot, rod item) — see design spec's "why
--- (spot, rod) instead of ItemBinding" for the rationale.
return {
    up = function()
        Schema.create('fishing_rod_pools', function(table)
            table:id()
            table:foreignId('spot_id'):constrained('fishing_spots'):onDelete('CASCADE')
            table:foreignId('rod_base_item_id'):constrained('base_items'):onDelete('CASCADE')
            table:timestamps()

            table:unique({'spot_id', 'rod_base_item_id'})
        end)

        print('[Migration] Created fishing_rod_pools table')
    end,

    down = function()
        Schema.drop('fishing_rod_pools')
        print('[Migration] Dropped fishing_rod_pools table')
    end
}
```

`plugins/oblsk_fishing/server/migrations/2026_08_16_090002_create_fishing_pool_entries_table.lua`:

```lua
-- plugins/oblsk_fishing/server/migrations/2026_08_16_090002_create_fishing_pool_entries_table.lua
--- Migration: Create fishing_pool_entries table
--- One row per possible catch within a fishing_rod_pools row. `weight` is
--- relative (not required to sum to 100) — FishingService normalizes at
--- selection time.
return {
    up = function()
        Schema.create('fishing_pool_entries', function(table)
            table:id()
            table:foreignId('rod_pool_id'):constrained('fishing_rod_pools'):onDelete('CASCADE')
            table:foreignId('base_item_id'):constrained('base_items'):onDelete('CASCADE')
            table:float('weight'):default(1.0)
            table:float('difficulty'):default(1.0)
            table:integer('min_amount'):default(1)
            table:integer('max_amount'):default(1)
            table:timestamps()
        end)

        print('[Migration] Created fishing_pool_entries table')
    end,

    down = function()
        Schema.drop('fishing_pool_entries')
        print('[Migration] Dropped fishing_pool_entries table')
    end
}
```

- [ ] **Step 4: README**

`plugins/oblsk_fishing/README.md`:

```markdown
# oblsk_fishing

Server-authoritative fishing minigame. Admins place fishing spots and, per
spot, configure which rod items work there and what each rod can catch (with
relative weights, a difficulty that drives reel-check hardness, and a
min/max reward amount) — all through the admin panel's Fishing tab, no
seeding required.

See `docs/superpowers/specs/2026-08-16-fishing-plugin-design.md` in the core
repo for the full design.

## Setup

1. Create a base item to serve as the rod (Items tab), give it the binding
   key `fishing.rod` at creation (or rebind an existing item to that key
   later by re-creating with the same key).
2. Fishing tab → New spot → stand where you want it → Use my position.
3. On the spot, add a rod pool for that rod item, then add pool entries
   (reward item, weight, difficulty, min/max amount).
```

- [ ] **Step 5: register the plugin**

In `plugins/registry.json`, add `"oblsk_fishing"` to the `plugins` array (alphabetically, between `oblsk_deathscreen` and `oblsk_documentviewer`... actually between `"oblsk_deathscreen"` and `"oblsk_documentviewer"` if inserting alphabetically; the array is already alphabetical, so insert `"oblsk_fishing"` right after `"oblsk_documentviewer"` and before `"oblsk_garage"`):

```json
    "oblsk_deathscreen",
    "oblsk_documentviewer",
    "oblsk_fishing",
    "oblsk_garage",
```

- [ ] **Step 6: Verify migrations load cleanly**

This can't run without a live MySQL connector; instead sanity-check the JSON/Lua parse:

Run: `lua5.4 -e "local f = io.open('plugins/oblsk_fishing/server/migrations.json'); print(f:read('*a'))"`
Expected: prints the JSON unchanged (file exists, readable)

Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_fishing/server/migrations/2026_08_16_090000_create_fishing_spots_table.lua')); assert(loadfile('plugins/oblsk_fishing/server/migrations/2026_08_16_090001_create_fishing_rod_pools_table.lua')); assert(loadfile('plugins/oblsk_fishing/server/migrations/2026_08_16_090002_create_fishing_pool_entries_table.lua')); assert(loadfile('plugins/oblsk_fishing/shared/config.lua')); print('OK')"`
Expected: `OK` (every file parses as valid Lua)

- [ ] **Step 7: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing plugins/registry.json
git commit -m "feat(fishing): scaffold oblsk_fishing plugin"
```

---

## Task 5: `FishingSpotService` — spot/pool/entry CRUD

**Files:**
- Create: `plugins/oblsk_fishing/server/services/FishingSpotService.lua`
- Test: `plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(table)` (existing ORM).
- Produces:
  - `FishingSpotService.listSpots()` → `table[]` every `fishing_spots` row
  - `FishingSpotService.createSpot(attrs)` → `number id` (`attrs`: `label, x, y, z, range, bait_item_id`)
  - `FishingSpotService.updateSpot(id, attrs)` → `boolean`
  - `FishingSpotService.deleteSpot(id)` → `boolean`
  - `FishingSpotService.listRodPools(spotId)` → `table[]` (`fishing_rod_pools` rows for that spot)
  - `FishingSpotService.createRodPool(spotId, rodBaseItemId)` → `number|nil id, string|nil reason` (fails if a pool for that (spot, rod) pair already exists)
  - `FishingSpotService.deleteRodPool(id)` → `boolean`
  - `FishingSpotService.listPoolEntries(rodPoolId)` → `table[]`
  - `FishingSpotService.createPoolEntry(rodPoolId, attrs)` → `number id` (`attrs`: `base_item_id, weight, difficulty, min_amount, max_amount`)
  - `FishingSpotService.updatePoolEntry(id, attrs)` → `boolean`
  - `FishingSpotService.deletePoolEntry(id)` → `boolean`
  - `FishingSpotService.resolvePool(spotId, rodBaseItemId)` → `table|nil { rodPool = row, entries = row[] }` — `nil` if no pool exists for that (spot, rod) pair. Consumed by `FishingService` in Task 7.

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/services/FishingSpotService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local function withFreshState(fn)
    local tables = { fishing_spots = {}, fishing_rod_pools = {}, fishing_pool_entries = {} }
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    fn(tables)
end

test('createSpot then listSpots returns it', function()
    withFreshState(function()
        local id = FishingSpotService.createSpot({ label = 'Pier', x = 1.0, y = 2.0, z = 3.0, range = 2.5 })
        truthy(id ~= nil)
        local spots = FishingSpotService.listSpots()
        eq(#spots, 1)
        eq(spots[1].label, 'Pier')
    end)
end)

test('updateSpot changes fields, deleteSpot removes it', function()
    withFreshState(function()
        local id = FishingSpotService.createSpot({ label = 'Pier', x = 0, y = 0, z = 0 })
        truthy(FishingSpotService.updateSpot(id, { label = 'Dock' }))
        eq(FishingSpotService.listSpots()[1].label, 'Dock')
        truthy(FishingSpotService.deleteSpot(id))
        eq(#FishingSpotService.listSpots(), 0)
    end)
end)

test('createRodPool: succeeds once per (spot, rod) pair, fails on duplicate', function()
    withFreshState(function()
        local spotId = FishingSpotService.createSpot({ label = 'Pier', x = 0, y = 0, z = 0 })
        local poolId, reason = FishingSpotService.createRodPool(spotId, 50)
        truthy(poolId ~= nil)
        eq(reason, nil)
        local dupId, dupReason = FishingSpotService.createRodPool(spotId, 50)
        eq(dupId, nil)
        truthy(dupReason ~= nil)
    end)
end)

test('listRodPools scopes to the given spot', function()
    withFreshState(function()
        local spotA = FishingSpotService.createSpot({ label = 'A', x = 0, y = 0, z = 0 })
        local spotB = FishingSpotService.createSpot({ label = 'B', x = 0, y = 0, z = 0 })
        FishingSpotService.createRodPool(spotA, 50)
        FishingSpotService.createRodPool(spotB, 51)
        eq(#FishingSpotService.listRodPools(spotA), 1)
        eq(#FishingSpotService.listRodPools(spotB), 1)
    end)
end)

test('createPoolEntry then listPoolEntries, updatePoolEntry, deletePoolEntry', function()
    withFreshState(function()
        local spotId = FishingSpotService.createSpot({ label = 'Pier', x = 0, y = 0, z = 0 })
        local poolId = FishingSpotService.createRodPool(spotId, 50)
        local entryId = FishingSpotService.createPoolEntry(poolId, { base_item_id = 10, weight = 5, difficulty = 1.2, min_amount = 1, max_amount = 2 })
        truthy(entryId ~= nil)
        eq(#FishingSpotService.listPoolEntries(poolId), 1)
        truthy(FishingSpotService.updatePoolEntry(entryId, { weight = 9 }))
        eq(FishingSpotService.listPoolEntries(poolId)[1].weight, 9)
        truthy(FishingSpotService.deletePoolEntry(entryId))
        eq(#FishingSpotService.listPoolEntries(poolId), 0)
    end)
end)

test('resolvePool: returns the pool and its entries for a matching (spot, rod)', function()
    withFreshState(function()
        local spotId = FishingSpotService.createSpot({ label = 'Pier', x = 0, y = 0, z = 0 })
        local poolId = FishingSpotService.createRodPool(spotId, 50)
        FishingSpotService.createPoolEntry(poolId, { base_item_id = 10, weight = 5, difficulty = 1.0, min_amount = 1, max_amount = 1 })
        FishingSpotService.createPoolEntry(poolId, { base_item_id = 11, weight = 1, difficulty = 2.0, min_amount = 1, max_amount = 1 })

        local resolved = FishingSpotService.resolvePool(spotId, 50)
        truthy(resolved ~= nil)
        eq(resolved.rodPool.id, poolId)
        eq(#resolved.entries, 2)
    end)
end)

test('resolvePool: nil when no pool exists for that rod at that spot', function()
    withFreshState(function()
        local spotId = FishingSpotService.createSpot({ label = 'Pier', x = 0, y = 0, z = 0 })
        FishingSpotService.createRodPool(spotId, 50)
        eq(FishingSpotService.resolvePool(spotId, 999), nil)
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

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua`
Expected: FAIL — `module 'FishingSpotService' not found` / file doesn't exist

- [ ] **Step 3: Implement**

```lua
-- plugins/oblsk_fishing/server/services/FishingSpotService.lua
--- FishingSpotService - admin-panel CRUD for fishing spots and their
--- per-rod reward pools. No seeding — every row here is created through
--- the Fishing admin tab (see FishingTab.vue / the fishing:server:admin-*
--- handlers in main.lua).
FishingSpotService = {}

--- @return table[] every fishing_spots row
function FishingSpotService.listSpots()
    return QueryBuilder.new('fishing_spots'):getSync()
end

--- @param attrs table label, x, y, z, range, bait_item_id (nullable)
--- @return number id
function FishingSpotService.createSpot(attrs)
    return QueryBuilder.new('fishing_spots'):insert({
        label = attrs.label,
        x = attrs.x,
        y = attrs.y,
        z = attrs.z,
        range = attrs.range or 2.0,
        bait_item_id = attrs.bait_item_id,
        enabled = attrs.enabled == nil and 1 or attrs.enabled,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @param attrs table any of label, x, y, z, range, bait_item_id, enabled
--- @return boolean
function FishingSpotService.updateSpot(id, attrs)
    attrs.updated_at = Database.now()
    QueryBuilder.new('fishing_spots'):where('id', id):update(attrs)
    return true
end

--- @param id number
--- @return boolean
function FishingSpotService.deleteSpot(id)
    QueryBuilder.new('fishing_spots'):where('id', id):delete()
    return true
end

--- @param spotId number
--- @return table[]
function FishingSpotService.listRodPools(spotId)
    return QueryBuilder.new('fishing_rod_pools'):where('spot_id', spotId):getSync()
end

--- @param spotId number
--- @param rodBaseItemId number
--- @return number|nil id, string|nil reason
function FishingSpotService.createRodPool(spotId, rodBaseItemId)
    local existing = QueryBuilder.new('fishing_rod_pools')
        :where('spot_id', spotId)
        :where('rod_base_item_id', rodBaseItemId)
        :firstSync()
    if existing then
        return nil, 'This rod already has a pool at this spot'
    end

    local id = QueryBuilder.new('fishing_rod_pools'):insert({
        spot_id = spotId,
        rod_base_item_id = rodBaseItemId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
    return id, nil
end

--- @param id number
--- @return boolean
function FishingSpotService.deleteRodPool(id)
    QueryBuilder.new('fishing_rod_pools'):where('id', id):delete()
    return true
end

--- @param rodPoolId number
--- @return table[]
function FishingSpotService.listPoolEntries(rodPoolId)
    return QueryBuilder.new('fishing_pool_entries'):where('rod_pool_id', rodPoolId):getSync()
end

--- @param rodPoolId number
--- @param attrs table base_item_id, weight, difficulty, min_amount, max_amount
--- @return number id
function FishingSpotService.createPoolEntry(rodPoolId, attrs)
    return QueryBuilder.new('fishing_pool_entries'):insert({
        rod_pool_id = rodPoolId,
        base_item_id = attrs.base_item_id,
        weight = attrs.weight or 1.0,
        difficulty = attrs.difficulty or 1.0,
        min_amount = attrs.min_amount or 1,
        max_amount = attrs.max_amount or 1,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @param attrs table any of base_item_id, weight, difficulty, min_amount, max_amount
--- @return boolean
function FishingSpotService.updatePoolEntry(id, attrs)
    attrs.updated_at = Database.now()
    QueryBuilder.new('fishing_pool_entries'):where('id', id):update(attrs)
    return true
end

--- @param id number
--- @return boolean
function FishingSpotService.deletePoolEntry(id)
    QueryBuilder.new('fishing_pool_entries'):where('id', id):delete()
    return true
end

--- @param spotId number
--- @param rodBaseItemId number
--- @return table|nil { rodPool = fishing_rod_pools row, entries = fishing_pool_entries row[] }
function FishingSpotService.resolvePool(spotId, rodBaseItemId)
    local rodPool = QueryBuilder.new('fishing_rod_pools')
        :where('spot_id', spotId)
        :where('rod_base_item_id', rodBaseItemId)
        :firstSync()
    if not rodPool then
        return nil
    end
    return { rodPool = rodPool, entries = FishingSpotService.listPoolEntries(rodPool.id) }
end

return FishingSpotService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua`
Expected: `7 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing/server/services/FishingSpotService.lua plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua
git commit -m "feat(fishing): add FishingSpotService CRUD for spots/pools/entries"
```

---

## Task 6: `FishingChallengeService` — the authoritative minigame engine

This is the security-critical piece: every random decision and timing
judgement lives here, driven only by `GetGameTimer()` and `math.random`
(both overridable in tests), never by anything the client sends except a
bare "a keypress happened" or "give me the next round" signal.

**Files:**
- Create: `plugins/oblsk_fishing/server/services/FishingChallengeService.lua`
- Test: `plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua`

**Interfaces:**
- Consumes: `GetGameTimer()` (FiveM global, stubbed in tests), `math.random`.
- Produces:
  - `FishingChallengeService.BITE_WINDOW_MS`, `.LATENCY_TOLERANCE_MS`, `.CAST_DELAY_MIN_MS`, `.CAST_DELAY_MAX_MS` (numbers, mirror `FishingConfig`'s values as defaults, overridable per-instance by whoever wires config in Task 8)
  - `FishingChallengeService.beginWait(source)` → `number biteDelayMs` (also (re)creates the session, superseding any prior one for that source)
  - `FishingChallengeService.announceBite(source)` → `boolean` (true if a `wait`-phase session existed and was advanced to `bite`)
  - `FishingChallengeService.handleEarlyPress(source)` → `boolean ok, string reason` (always `false, 'spooked'` if a `wait` session existed, `false, 'no session'` otherwise; ends the session on `wait`)
  - `FishingChallengeService.handleHookPress(source, poolEntries)` → `boolean ok, string reason|table session` — `poolEntries` is the `fishing_pool_entries` row array from `FishingSpotService.resolvePool(...).entries`; on success, picks the fish and returns the session state for the caller to relay to the client
  - `FishingChallengeService.startRound(source)` → `table|nil { roundId, speed, zone, direction, bandStart }` — `nil` if there's no `reel`-phase session
  - `FishingChallengeService.resolveRound(source, roundId)` → `string result` (`'great'|'good'|'miss'|'landed'|'lost'|'stale'`) — callable either from the keypress net-event handler or from a server-scheduled timeout callback; the second caller for a given round always gets `'stale'`
  - `FishingChallengeService.getSession(source)` → `table|nil` (read-only; `phase`, and once picked, `fish = { baseItemId, amount }`)
  - `FishingChallengeService.clearSource(source)` → `nil` (disconnect cleanup)
  - `FishingChallengeService.resetSessionsForTests()` → `nil`

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')

-- fivem_stubs.lua provides a GetGameTimer() stub; FishingChallengeService
-- uses it, not os.time, to measure elapsed time — same convention as
-- LockpickChallengeService (modules/oblsk_doors).
local fakeNow = 1000
GetGameTimer = function() return fakeNow end

-- Deterministic RNG hook, same technique as VendingMachineService's
-- VENDING_RANDOM_OVERRIDE: when set, math.random calls inside the service
-- return this instead of a real random draw.
FISHING_RANDOM_OVERRIDE = nil
local realRandom = math.random
math.random = function(...)
    if FISHING_RANDOM_OVERRIDE ~= nil then return FISHING_RANDOM_OVERRIDE end
    return realRandom(...)
end

dofile(scriptDir .. '../server/services/FishingChallengeService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local ONE_ENTRY_POOL = { { base_item_id = 10, weight = 1, difficulty = 1.0, min_amount = 2, max_amount = 2 } }

local function reset()
    fakeNow = 1000
    FISHING_RANDOM_OVERRIDE = nil
    FishingChallengeService.resetSessionsForTests()
end

test('beginWait: returns a delay within the configured range and starts a wait session', function()
    reset()
    local delay = FishingChallengeService.beginWait(5)
    truthy(delay >= FishingChallengeService.CAST_DELAY_MIN_MS)
    truthy(delay <= FishingChallengeService.CAST_DELAY_MAX_MS)
    eq(FishingChallengeService.getSession(5).phase, 'wait')
end)

test('beginWait: supersedes any prior session for the same source', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    eq(FishingChallengeService.getSession(5).phase, 'bite')
    FishingChallengeService.beginWait(5)
    eq(FishingChallengeService.getSession(5).phase, 'wait', 'a fresh cast must reset the phase')
end)

test('handleEarlyPress: spooks a wait-phase session and clears it', function()
    reset()
    FishingChallengeService.beginWait(5)
    local ok, reason = FishingChallengeService.handleEarlyPress(5)
    eq(ok, false)
    eq(reason, 'spooked')
    eq(FishingChallengeService.getSession(5), nil)
end)

test('handleEarlyPress: no-op (no session) when nothing is outstanding', function()
    reset()
    local ok, reason = FishingChallengeService.handleEarlyPress(5)
    eq(ok, false)
    eq(reason, 'no session')
end)

test('announceBite: false if the session is not in wait phase (e.g. no session at all)', function()
    reset()
    eq(FishingChallengeService.announceBite(5), false)
end)

test('handleHookPress: fails if not in bite phase', function()
    reset()
    FishingChallengeService.beginWait(5)
    local ok, reason = FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    eq(ok, false)
    eq(reason, 'no active bite')
end)

test('handleHookPress: fails ("too slow") past the bite window + tolerance, and ends the session', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    fakeNow = fakeNow + FishingChallengeService.BITE_WINDOW_MS + FishingChallengeService.LATENCY_TOLERANCE_MS + 1
    local ok, reason = FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    eq(ok, false)
    eq(reason, 'too slow')
    eq(FishingChallengeService.getSession(5), nil)
end)

test('handleHookPress: succeeds within the window, picks a fish, moves to reel phase at 0.28 progress', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    fakeNow = fakeNow + 200
    local ok = FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    eq(ok, true)
    local session = FishingChallengeService.getSession(5)
    eq(session.phase, 'reel')
    eq(session.progress, 0.28)
    eq(session.fish.baseItemId, 10)
    eq(session.fish.amount, 2)
end)

test('startRound: nil when not in reel phase', function()
    reset()
    eq(FishingChallengeService.startRound(5), nil)
end)

test('startRound: returns round params once in reel phase, difficulty 1.0 -> speed 205, zone 60', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    local round = FishingChallengeService.startRound(5)
    truthy(round ~= nil)
    eq(round.speed, 205) -- 150 + 1.0*55
    eq(round.zone, 60)   -- 76 - 1.0*16
    truthy(round.roundId ~= nil)
    truthy(round.bandStart >= 20 and round.bandStart <= 260)
end)

test('resolveRound: a stale/mismatched roundId is rejected without mutating progress', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    FishingChallengeService.startRound(5)
    eq(FishingChallengeService.resolveRound(5, 999999), 'stale')
    eq(FishingChallengeService.getSession(5).progress, 0.28, 'progress must be untouched')
end)

test('resolveRound: a second call for the same round (timeout after a press) is stale', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    local round = FishingChallengeService.startRound(5)
    FishingChallengeService.resolveRound(5, round.roundId)
    eq(FishingChallengeService.resolveRound(5, round.roundId), 'stale')
end)

test('resolveRound: pressing inside the great band (28%-72% of the zone) scores great, +0.24 progress', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL) -- progress starts at 0.28
    local round = FishingChallengeService.startRound(5) -- speed 205 deg/s, zone 60, bandStart known
    -- Land exactly on the middle of the band: traveled = bandStart + zone*0.5
    local traveledDeg = round.bandStart + round.zone * 0.5
    fakeNow = fakeNow + math.floor(traveledDeg / round.speed * 1000)
    local result = FishingChallengeService.resolveRound(5, round.roundId)
    eq(result, 'great')
    eq(FishingChallengeService.getSession(5).progress, 0.28 + 0.24)
end)

test('resolveRound: pressing near the band edge (not the middle 44%) scores good, +0.15 progress', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    local round = FishingChallengeService.startRound(5)
    -- Land right at the start of the band (offset 0, outside the 28%-72% great band).
    local traveledDeg = round.bandStart + 0.01
    fakeNow = fakeNow + math.floor(traveledDeg / round.speed * 1000)
    local result = FishingChallengeService.resolveRound(5, round.roundId)
    eq(result, 'good')
    eq(FishingChallengeService.getSession(5).progress, 0.28 + 0.15)
end)

test('resolveRound: pressing outside the band entirely scores miss, -0.18 progress', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    local round = FishingChallengeService.startRound(5)
    -- Way before the band even starts.
    fakeNow = fakeNow + 1
    local result = FishingChallengeService.resolveRound(5, round.roundId)
    eq(result, 'miss')
    eq(FishingChallengeService.getSession(5).progress, 0.28 - 0.18)
end)

test('resolveRound: a timeout (never pressed, elapsed past the band) also scores miss via the same call', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL)
    local round = FishingChallengeService.startRound(5)
    fakeNow = fakeNow + math.floor((round.bandStart + round.zone) / round.speed * 1000) + 500
    eq(FishingChallengeService.resolveRound(5, round.roundId), 'miss')
end)

test('resolveRound: progress reaching >= 1 lands the fish and ends the session', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL) -- 0.28
    for i = 1, 3 do -- 0.28 + 0.24*3 = 1.0
        local round = FishingChallengeService.startRound(5)
        local traveledDeg = round.bandStart + round.zone * 0.5
        fakeNow = fakeNow + math.floor(traveledDeg / round.speed * 1000)
        local result = FishingChallengeService.resolveRound(5, round.roundId)
        if i < 3 then eq(result, 'great') else eq(result, 'landed') end
    end
    eq(FishingChallengeService.getSession(5), nil, 'a landed session is cleared')
end)

test('resolveRound: progress reaching <= 0 loses the fish and ends the session', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.announceBite(5)
    FishingChallengeService.handleHookPress(5, ONE_ENTRY_POOL) -- 0.28
    local round = FishingChallengeService.startRound(5)
    fakeNow = fakeNow + 1 -- guaranteed miss, -0.18 -> 0.10
    FishingChallengeService.resolveRound(5, round.roundId)
    round = FishingChallengeService.startRound(5)
    fakeNow = fakeNow + 1 -- another miss -> -0.08, <= 0
    local result = FishingChallengeService.resolveRound(5, round.roundId)
    eq(result, 'lost')
    eq(FishingChallengeService.getSession(5), nil)
end)

test('clearSource: drops any outstanding session', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.clearSource(5)
    eq(FishingChallengeService.getSession(5), nil)
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

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua`
Expected: FAIL — file doesn't exist yet

- [ ] **Step 3: Implement**

```lua
-- plugins/oblsk_fishing/server/services/FishingChallengeService.lua
--- FishingChallengeService - the server-authoritative fishing state
--- machine. Every random decision (bite delay, needle sweep parameters,
--- which fish) and every timing judgement (bite-window, reel-round
--- classification) happens here, driven only by GetGameTimer() and
--- math.random. The client is told what to render (speed/zone/direction/
--- bandStart) and reports only bare "a keypress happened" or "give me the
--- next round" events — never a claimed outcome. See
--- docs/superpowers/specs/2026-08-16-fishing-plugin-design.md.
---
--- Sweep model: the prototype (src/proto/fishing-game.jsx) accelerates the
--- needle as it travels, coupled to the browser's per-frame timing. That
--- can't be reproduced deterministically server-side without also being
--- exactly reproducible for a real client's variable frame timing, which
--- is neither meaningful nor securable. This service instead uses a
--- constant-speed sweep: traveled degrees = elapsedMs/1000 * speed. The
--- scoring rule itself (a %-of-zone band, a middle 28%-72% "great" sub-band)
--- is preserved exactly.
FishingChallengeService = {}

FishingChallengeService.BITE_WINDOW_MS = 1000
FishingChallengeService.LATENCY_TOLERANCE_MS = 150
FishingChallengeService.CAST_DELAY_MIN_MS = 1600
FishingChallengeService.CAST_DELAY_MAX_MS = 5400

local SPEED_BASE, SPEED_PER_DIFFICULTY = 150, 55
local ZONE_BASE, ZONE_MIN, ZONE_PER_DIFFICULTY = 76, 34, 16
local BAND_START_MIN, BAND_START_MAX = 20, 260
local PROGRESS_START = 0.28
local PROGRESS_GREAT, PROGRESS_GOOD, PROGRESS_MISS = 0.24, 0.15, -0.18
local GREAT_LOW, GREAT_HIGH = 0.28, 0.72

local sessions = {} -- source -> session table
local roundCounter = 0

--- @param source number
--- @return number biteDelayMs
function FishingChallengeService.beginWait(source)
    local delay = math.random(FishingChallengeService.CAST_DELAY_MIN_MS, FishingChallengeService.CAST_DELAY_MAX_MS)
    sessions[source] = { phase = 'wait' }
    return delay
end

--- @param source number
--- @return boolean
function FishingChallengeService.announceBite(source)
    local session = sessions[source]
    if not session or session.phase ~= 'wait' then
        return false
    end
    session.phase = 'bite'
    session.biteAt = GetGameTimer()
    return true
end

--- @param source number
--- @return boolean ok, string reason
function FishingChallengeService.handleEarlyPress(source)
    local session = sessions[source]
    if not session then
        return false, 'no session'
    end
    if session.phase == 'wait' then
        sessions[source] = nil
        return false, 'spooked'
    end
    return false, 'not waiting'
end

--- Weighted pick from `entries` (fishing_pool_entries rows), using
--- math.random so tests can force a deterministic draw via
--- FISHING_RANDOM_OVERRIDE (see spec file). Total weight need not sum to
--- any particular value — normalized here.
--- @param entries table[]
--- @return table entry
local function pickEntry(entries)
    local totalWeight = 0
    for _, e in ipairs(entries) do totalWeight = totalWeight + (e.weight or 1) end
    local roll = math.random() * totalWeight
    local acc = 0
    for _, e in ipairs(entries) do
        acc = acc + (e.weight or 1)
        if roll <= acc then return e end
    end
    return entries[#entries]
end

--- @param source number
--- @param poolEntries table[] fishing_pool_entries rows for the (spot, rod)
---   the player is casting with — resolved by the caller (FishingService)
---   via FishingSpotService.resolvePool, never trusted from the client.
--- @return boolean ok, string|nil reason
function FishingChallengeService.handleHookPress(source, poolEntries)
    local session = sessions[source]
    if not session or session.phase ~= 'bite' then
        return false, 'no active bite'
    end

    local elapsed = GetGameTimer() - session.biteAt
    if elapsed > FishingChallengeService.BITE_WINDOW_MS + FishingChallengeService.LATENCY_TOLERANCE_MS then
        sessions[source] = nil
        return false, 'too slow'
    end

    local entry = pickEntry(poolEntries)
    local amount = math.random(entry.min_amount or 1, entry.max_amount or 1)

    session.phase = 'reel'
    session.progress = PROGRESS_START
    session.difficulty = entry.difficulty or 1.0
    session.fish = { baseItemId = entry.base_item_id, amount = amount }
    session.round = nil
    return true
end

--- @param source number
--- @return table|nil { roundId, speed, zone, direction, bandStart }
function FishingChallengeService.startRound(source)
    local session = sessions[source]
    if not session or session.phase ~= 'reel' then
        return nil
    end

    roundCounter = roundCounter + 1
    local speed = SPEED_BASE + session.difficulty * SPEED_PER_DIFFICULTY
    local zone = math.max(ZONE_MIN, ZONE_BASE - session.difficulty * ZONE_PER_DIFFICULTY)
    local round = {
        roundId = roundCounter,
        speed = speed,
        zone = zone,
        direction = math.random() < 0.4 and -1 or 1,
        bandStart = math.random(BAND_START_MIN, BAND_START_MAX),
        startedAt = GetGameTimer(),
    }
    session.round = round
    return { roundId = round.roundId, speed = round.speed, zone = round.zone, direction = round.direction, bandStart = round.bandStart }
end

--- Classifies elapsed reel-round time against the round's band. Pure
--- function of already-known round parameters, factored out so both a real
--- keypress and a server-scheduled timeout call the identical logic.
--- @param round table
--- @param elapsedMs number
--- @return string 'great'|'good'|'miss'
local function classify(round, elapsedMs)
    local traveled = (elapsedMs / 1000) * round.speed
    local offset = traveled - round.bandStart
    if offset < 0 or offset > round.zone then
        return 'miss'
    end
    local frac = offset / round.zone
    if frac >= GREAT_LOW and frac <= GREAT_HIGH then
        return 'great'
    end
    return 'good'
end

--- @param source number
--- @param roundId number
--- @return string 'great'|'good'|'miss'|'landed'|'lost'|'stale'
function FishingChallengeService.resolveRound(source, roundId)
    local session = sessions[source]
    if not session or session.phase ~= 'reel' or not session.round or session.round.roundId ~= roundId then
        return 'stale'
    end

    local round = session.round
    session.round = nil -- consume immediately: a second call for this roundId is always stale

    local result = classify(round, GetGameTimer() - round.startedAt)
    local delta = result == 'great' and PROGRESS_GREAT or result == 'good' and PROGRESS_GOOD or PROGRESS_MISS
    session.progress = math.max(0, math.min(1, session.progress + delta))

    if session.progress >= 1 then
        sessions[source] = nil
        return 'landed'
    elseif session.progress <= 0 then
        sessions[source] = nil
        return 'lost'
    end
    return result
end

--- @param source number
--- @return table|nil read-only view of the current session
function FishingChallengeService.getSession(source)
    return sessions[source]
end

--- @param source number
function FishingChallengeService.clearSource(source)
    sessions[source] = nil
end

--- Test-only: clears every in-memory session between spec cases.
function FishingChallengeService.resetSessionsForTests()
    sessions = {}
    roundCounter = 0
end

return FishingChallengeService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua`
Expected: `18 passed, 0 failed`

If the `'landed'`/`'lost'` progress-math tests fail on an off-by-a-fraction float comparison, print the actual progress value and adjust the test's expected literal to match the real float (e.g. `0.5199999999999999` vs `0.52`) — the implementation's arithmetic is correct as specified, `eq` here is exact equality so floats must match exactly; use `0.28 + 0.24 + 0.24` written out rather than a pre-computed literal if this happens, so Lua's own float arithmetic produces the same value on both sides.

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing/server/services/FishingChallengeService.lua plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua
git commit -m "feat(fishing): add server-authoritative FishingChallengeService"
```

---

## Task 7: `FishingService` — cast gating, rod/bait checks, capacity-checked grant

**Files:**
- Create: `plugins/oblsk_fishing/server/services/FishingService.lua`
- Test: `plugins/oblsk_fishing/tests/fishing_service_spec.lua`

**Interfaces:**
- Consumes: `ItemService.binding(key)`, `ItemService.has/remove/add/hasCapacity` (Task 1), `FishingSpotService.resolvePool` (Task 5), `FishingChallengeService.beginWait/handleEarlyPress/handleHookPress` (Task 6), `CharacterService.getActiveCharacterId`.
- Produces:
  - `FishingService.cast(source, spotId)` → `boolean ok, string|table reason` — on success, `reason` is `{ biteDelayMs }` for the caller (`main.lua`) to schedule `announceBite` after; on failure, `reason` is a user-facing string.
  - `FishingService.grantCatch(source, fish)` → `boolean ok, string|nil reason` — `fish` is the `{ baseItemId, amount }` `FishingChallengeService` session carries; called by `main.lua` when `resolveRound` returns `'landed'`.

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_fishing/tests/fishing_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_fishing/tests/fishing_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')

local fakeNow = 1000
GetGameTimer = function() return fakeNow end

-- FishingSpotService stub: source of truth for rod->pool resolution in
-- these tests, so FishingService's own logic (not the DB) is what's under
-- test — same "stub the collaborator" posture as
-- vendingmachine_service_spec.lua stubbing ItemService.
local pools = {}
FishingSpotService = {}
function FishingSpotService.resolvePool(spotId, rodBaseItemId)
    return pools[spotId] and pools[spotId][rodBaseItemId] or nil
end

local ROD_ITEM = { id = 77 }
local BAIT_ITEM = { id = 78 }

local spots = {}
local ledger -- source -> baseItemId -> amount, same shape as vendingmachine_service_spec.lua's

ItemService = {}
function ItemService.binding(key)
    if key == 'fishing.rod' then return ROD_ITEM end
    return nil
end
function ItemService.has(source, baseItem, amount)
    return ((ledger[source] or {})[baseItem.id] or 0) >= amount
end
function ItemService.remove(source, baseItem, amount)
    if not ItemService.has(source, baseItem, amount) then return false, 'Not enough items' end
    ledger[source][baseItem.id] = ledger[source][baseItem.id] - amount
    return true
end
function ItemService.add(source, baseItem, amount)
    ledger[source] = ledger[source] or {}
    ledger[source][baseItem.id] = (ledger[source][baseItem.id] or 0) + amount
    return true
end
local capacityOverride = true
function ItemService.hasCapacity(source, baseItem, amount)
    return capacityOverride
end

dofile(scriptDir .. '../server/services/FishingChallengeService.lua')
dofile(scriptDir .. '../server/services/FishingService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local SOURCE = 5
local SPOT_ID = 1

local function reset()
    fakeNow = 1000
    ledger = {}
    capacityOverride = true
    pools = { [SPOT_ID] = { [ROD_ITEM.id] = {
        rodPool = { id = 1, spot_id = SPOT_ID, rod_base_item_id = ROD_ITEM.id },
        entries = { { base_item_id = 10, weight = 1, difficulty = 1.0, min_amount = 1, max_amount = 1 } },
    } } }
    spots = { [SPOT_ID] = { id = SPOT_ID, bait_item_id = nil } }
    FishingChallengeService.resetSessionsForTests()
end

test('cast: fails with no rod bound at all', function()
    reset()
    ItemService.binding = function() return nil end
    local ok, reason = FishingService.cast(SOURCE, SPOT_ID, spots[SPOT_ID])
    eq(ok, false)
    truthy(reason ~= nil)
    ItemService.binding = function(key) if key == 'fishing.rod' then return ROD_ITEM end return nil end
end)

test('cast: fails when the player does not hold the rod', function()
    reset()
    local ok, reason = FishingService.cast(SOURCE, SPOT_ID, spots[SPOT_ID])
    eq(ok, false)
    truthy(reason ~= nil)
end)

test('cast: fails when no pool is configured for this (spot, rod)', function()
    reset()
    ledger[SOURCE] = { [ROD_ITEM.id] = 1 }
    pools[SPOT_ID][ROD_ITEM.id] = nil
    local ok, reason = FishingService.cast(SOURCE, SPOT_ID, spots[SPOT_ID])
    eq(ok, false)
    truthy(reason ~= nil)
end)

test('cast: succeeds, returns a bite delay, no bait required when spot has none configured', function()
    reset()
    ledger[SOURCE] = { [ROD_ITEM.id] = 1 }
    local ok, result = FishingService.cast(SOURCE, SPOT_ID, spots[SPOT_ID])
    eq(ok, true)
    truthy(result.biteDelayMs >= FishingChallengeService.CAST_DELAY_MIN_MS)
end)

test('cast: consumes bait when the spot has a bait_item_id configured', function()
    reset()
    spots[SPOT_ID].bait_item_id = BAIT_ITEM.id
    ledger[SOURCE] = { [ROD_ITEM.id] = 1, [BAIT_ITEM.id] = 1 }
    local ok = FishingService.cast(SOURCE, SPOT_ID, spots[SPOT_ID])
    eq(ok, true)
    eq(ledger[SOURCE][BAIT_ITEM.id], 0)
end)

test('cast: fails when bait is configured but the player has none', function()
    reset()
    spots[SPOT_ID].bait_item_id = BAIT_ITEM.id
    ledger[SOURCE] = { [ROD_ITEM.id] = 1 }
    local ok, reason = FishingService.cast(SOURCE, SPOT_ID, spots[SPOT_ID])
    eq(ok, false)
    truthy(reason ~= nil)
end)

test('grantCatch: adds the item when capacity allows', function()
    reset()
    capacityOverride = true
    local ok = FishingService.grantCatch(SOURCE, { baseItemId = 10, amount = 2 })
    eq(ok, true)
    eq(ledger[SOURCE][10], 2)
end)

test('grantCatch: fails without adding when capacity does not allow', function()
    reset()
    capacityOverride = false
    local ok, reason = FishingService.grantCatch(SOURCE, { baseItemId = 10, amount = 2 })
    eq(ok, false)
    truthy(reason ~= nil)
    eq((ledger[SOURCE] or {})[10], nil)
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

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_service_spec.lua`
Expected: FAIL — file doesn't exist yet

- [ ] **Step 3: Implement**

```lua
-- plugins/oblsk_fishing/server/services/FishingService.lua
--- FishingService - DB/Item-aware gate in front of FishingChallengeService.
--- Resolves whether a cast is even allowed (rod bound + held, matching
--- pool configured, bait affordable) and, on a landed catch, grants the
--- reward only if ItemService.hasCapacity allows it. Never trusts anything
--- from the client except "I want to cast at spotId" / "I want to press
--- now" — every other decision routes through FishingChallengeService or a
--- fresh DB read.
FishingService = {}

--- @param source number
--- @param spotId number
--- @param spot table the fishing_spots row (caller already looked it up to
---   check range/enabled — see main.lua)
--- @return boolean ok
--- @return table|string result: { biteDelayMs } on success, a user-facing
---   reason string on failure
function FishingService.cast(source, spotId, spot)
    local rod = ItemService.binding('fishing.rod')
    if not rod then
        return false, 'No fishing rod is configured on this server'
    end
    if not ItemService.has(source, rod, 1) then
        return false, 'You need a fishing rod'
    end

    local resolved = FishingSpotService.resolvePool(spotId, rod.id)
    if not resolved or #resolved.entries == 0 then
        return false, 'Nothing bites here with that rod'
    end

    if spot.bait_item_id then
        local baitItem = { id = spot.bait_item_id }
        if not ItemService.has(source, baitItem, 1) then
            return false, 'You need bait'
        end
        local removed, reason = ItemService.remove(source, baitItem, 1)
        if not removed then
            return false, reason
        end
    end

    local biteDelayMs = FishingChallengeService.beginWait(source)
    return true, { biteDelayMs = biteDelayMs }
end

--- @param source number
--- @param fish table { baseItemId, amount } from a landed
---   FishingChallengeService session
--- @return boolean ok, string|nil reason
function FishingService.grantCatch(source, fish)
    local baseItem = { id = fish.baseItemId }
    local ok = ItemService.hasCapacity(source, baseItem, fish.amount)
    if not ok then
        return false, 'Your inventory is full, the fish slips back into the water'
    end
    return ItemService.add(source, baseItem, fish.amount)
end

return FishingService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_service_spec.lua`
Expected: `8 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing/server/services/FishingService.lua plugins/oblsk_fishing/tests/fishing_service_spec.lua
git commit -m "feat(fishing): add FishingService cast gating and capacity-checked grant"
```

---

## Task 8: `server/main.lua` — wiring (interactions, net events, admin CRUD events)

Gameplay-net-event and native-timer code; not unit-testable per
`tests/README.md` — this task is implemented and then manually verified
against a running server in Task 12.

**Files:**
- Create: `plugins/oblsk_fishing/server/main.lua`

**Interfaces:**
- Consumes: everything from Tasks 5-7, plus core services already used identically by `oblsk_vendingmachine`'s `main.lua` (`InteractionService.register`, `ActionService.register`, `Obelisk.onClient`/`emitClient`, `NotificationService`, `WebView`, `CharacterService.getActiveCharacterId`, `PlayerService.get`).
- Produces: the net-event surface `client/main.lua` (Task 9) relays to/from: `fishing:client:cast`, `fishing:client:earlyPress`, `fishing:client:hookPress`, `fishing:client:nextRound`, `fishing:client:roundPress`, `fishing:client:close`, and their `fishing:server:*` reply counterparts; plus `fishing:server:admin-*` handlers for the admin tab (Task 11).

- [ ] **Step 1: Implement**

```lua
-- plugins/oblsk_fishing/server/main.lua
print('[Fishing] Loading...')

local function isAdmin(player)
    local source = player:getSource()
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

--------------------------------------------------------------------------------
-- World spot registration
--------------------------------------------------------------------------------

--- Registers every spot's interaction point. Must run exactly once at boot
--- — InteractionService.register does not dedupe, calling this twice would
--- put duplicate world prompts at every spot. Same posture as
--- VendingMachineService's registerAllMachines().
local function registerAllSpots()
    for _, spot in ipairs(FishingSpotService.listSpots()) do
        if spot.enabled ~= 0 and spot.enabled ~= false then
            InteractionService.register({
                x = spot.x, y = spot.y, z = spot.z,
                range = spot.range, label = spot.label or 'Go fishing',
                action = 'fishing:cast',
                options = { spotId = spot.id },
            })
        end
    end
end

ActionService.register('fishing:cast', function(player, data)
    local spotId = data and data.interaction and data.interaction.options and data.interaction.options.spotId
    if not spotId then return end
    local source = player:getSource()

    local spot = QueryBuilder.new('fishing_spots'):where('id', spotId):firstSync()
    if not spot then return end

    local ok, result = FishingService.cast(source, spotId, spot)
    if not ok then
        NotificationService.error(player, 'Fishing', result)
        return
    end

    WebView.openPage(player, '/Fishing')
    WebView.focus(player)
    Obelisk.emitClient('fishing:server:cast-started', player, {})

    SetTimeout(result.biteDelayMs, function()
        if FishingChallengeService.announceBite(source) then
            Obelisk.emitClient('fishing:server:bite', player, {})
        end
    end)
end, { label = 'Go fishing' })

--------------------------------------------------------------------------------
-- In-minigame net events
--------------------------------------------------------------------------------

Obelisk.onClient('fishing:client:earlyPress', function(player)
    FishingChallengeService.handleEarlyPress(player:getSource())
    player:emit('fishing:server:lost', { reason = 'spooked' })
end)

Obelisk.onClient('fishing:client:hookPress', function(player)
    local source = player:getSource()
    local session = FishingChallengeService.getSession(source)
    if not session then return end

    -- The pool was already resolved once by FishingService.cast; re-resolve
    -- here rather than trust anything cached client-side about which
    -- rod/spot this session is for.
    local rod = ItemService.binding('fishing.rod')
    local spotId = session.spotId
    local ok, reason = FishingChallengeService.handleHookPress(source, session.poolEntries or {})
    if not ok then
        player:emit('fishing:server:lost', { reason = reason })
        return
    end

    local updated = FishingChallengeService.getSession(source)
    player:emit('fishing:server:hooked', { fish = updated.fish })
end)

local function sendNextRound(player, source)
    local round = FishingChallengeService.startRound(source)
    if not round then return end
    player:emit('fishing:server:round', round)

    local timeoutMs = math.floor((round.bandStart + round.zone) / round.speed * 1000)
        + FishingChallengeService.LATENCY_TOLERANCE_MS
    SetTimeout(timeoutMs, function()
        local result = FishingChallengeService.resolveRound(source, round.roundId)
        if result == 'stale' then return end -- already resolved by a real press
        if result == 'landed' or result == 'lost' then
            player:emit('fishing:server:finished', { result = result })
        else
            player:emit('fishing:server:roundResult', { result = result })
            sendNextRound(player, source)
        end
    end)
end

Obelisk.onClient('fishing:client:nextRound', function(player)
    sendNextRound(player, player:getSource())
end)

Obelisk.onClient('fishing:client:roundPress', function(player, roundId)
    local source = player:getSource()
    local result = FishingChallengeService.resolveRound(source, roundId)
    if result == 'stale' then return end

    if result == 'landed' then
        local session = FishingChallengeService.getSession(source) -- already cleared; grab fish before clearing next time
        player:emit('fishing:server:finished', { result = 'landed' })
    elseif result == 'lost' then
        player:emit('fishing:server:finished', { result = 'lost' })
    else
        player:emit('fishing:server:roundResult', { result = result })
        sendNextRound(player, source)
    end
end)

Obelisk.onClient('fishing:client:close', function(player)
    FishingChallengeService.clearSource(player:getSource())
end)

AddEventHandler('playerDropped', function()
    local source = source
    FishingChallengeService.clearSource(source)
end)

--------------------------------------------------------------------------------
-- Admin CRUD net events (used by FishingTab.vue, imported into oblsk_admin's
-- AdminPanel.vue — handlers live here rather than in oblsk_admin, since
-- oblsk_fishing owns fishing_spots/fishing_rod_pools/fishing_pool_entries).
--------------------------------------------------------------------------------

local function replyAdminState(player)
    local spots = FishingSpotService.listSpots()
    for _, spot in ipairs(spots) do
        spot.rodPools = FishingSpotService.listRodPools(spot.id)
        for _, pool in ipairs(spot.rodPools) do
            pool.entries = FishingSpotService.listPoolEntries(pool.id)
        end
    end
    player:emit('fishing:server:admin-state', { spots = spots, items = ItemService.listBaseItems() })
end

Obelisk.onClient('fishing:server:admin-list', function(player)
    if not isAdmin(player) then return end
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-capture-position', function(player)
    if not isAdmin(player) then return end
    Obelisk.emitClient('fishing:server:capture-position', player, {})
end)

Obelisk.onClient('fishing:server:admin-create-spot', function(player, data)
    if not isAdmin(player) then return end
    FishingSpotService.createSpot(data)
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-update-spot', function(player, data)
    if not isAdmin(player) then return end
    FishingSpotService.updateSpot(data.id, data.attrs or {})
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-delete-spot', function(player, data)
    if not isAdmin(player) then return end
    FishingSpotService.deleteSpot(data.id)
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-create-rod-pool', function(player, data)
    if not isAdmin(player) then return end
    local id, reason = FishingSpotService.createRodPool(data.spotId, data.rodBaseItemId)
    if not id then
        NotificationService.error(player, 'Fishing', reason)
    end
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-delete-rod-pool', function(player, data)
    if not isAdmin(player) then return end
    FishingSpotService.deleteRodPool(data.id)
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-create-pool-entry', function(player, data)
    if not isAdmin(player) then return end
    FishingSpotService.createPoolEntry(data.rodPoolId, data.attrs or {})
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-update-pool-entry', function(player, data)
    if not isAdmin(player) then return end
    FishingSpotService.updatePoolEntry(data.id, data.attrs or {})
    replyAdminState(player)
end)

Obelisk.onClient('fishing:server:admin-delete-pool-entry', function(player, data)
    if not isAdmin(player) then return end
    FishingSpotService.deletePoolEntry(data.id)
    replyAdminState(player)
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    registerAllSpots()
    print('[Fishing] Loaded successfully!')
end)
```

**Known simplification, flagged rather than hidden:** `fishing:client:hookPress`
references `session.spotId`/`session.poolEntries`, which
`FishingChallengeService`'s session table (Task 6) does not actually carry —
`handleHookPress` takes `poolEntries` as a parameter, it doesn't read it off
the session. Fix this in Step 2 below by having `FishingService.cast` stash
`spotId` and the resolved `poolEntries` into the session itself so
`main.lua` doesn't need to re-resolve the pool on every hook press. This is
corrected before commit, not left as a bug.

- [ ] **Step 2: Correct the cast→session handoff**

Add a `FishingChallengeService.attachPoolContext(source, spotId, poolEntries)`
function so `FishingService.cast` can stash what `main.lua`'s hook-press
handler needs, without `FishingChallengeService` reaching into the DB itself.

In `plugins/oblsk_fishing/server/services/FishingChallengeService.lua`, add
right after `beginWait`:

```lua
--- Stashes cast-time context (which spot/pool this session's eventual
--- handleHookPress should draw from) onto an already-started wait session.
--- Kept separate from beginWait's signature so beginWait itself stays
--- free of any DB-shaped parameter.
--- @param source number
--- @param spotId number
--- @param poolEntries table[]
function FishingChallengeService.attachPoolContext(source, spotId, poolEntries)
    local session = sessions[source]
    if session then
        session.spotId = spotId
        session.poolEntries = poolEntries
    end
end
```

In `plugins/oblsk_fishing/server/services/FishingService.lua`, change the
end of `FishingService.cast` to:

```lua
    local biteDelayMs = FishingChallengeService.beginWait(source)
    FishingChallengeService.attachPoolContext(source, spotId, resolved.entries)
    return true, { biteDelayMs = biteDelayMs }
```

Add a corresponding test to `fishing_challenge_service_spec.lua` (after
the `'beginWait: supersedes...'` test):

```lua
test('attachPoolContext: stores spotId/poolEntries on the current session', function()
    reset()
    FishingChallengeService.beginWait(5)
    FishingChallengeService.attachPoolContext(5, 3, ONE_ENTRY_POOL)
    local session = FishingChallengeService.getSession(5)
    eq(session.spotId, 3)
    eq(session.poolEntries, ONE_ENTRY_POOL)
end)
```

And update `fishing_service_spec.lua`'s cast-success tests to assert the
context landed — add to the end of the `'cast: succeeds, returns a bite
delay...'` test, before its closing `end)`:

```lua
    eq(FishingChallengeService.getSession(SOURCE).spotId, SPOT_ID)
```

Also change `main.lua`'s `fishing:client:hookPress` handler to read from
the session directly instead of re-resolving:

```lua
Obelisk.onClient('fishing:client:hookPress', function(player)
    local source = player:getSource()
    local session = FishingChallengeService.getSession(source)
    if not session then return end

    local ok, reason = FishingChallengeService.handleHookPress(source, session.poolEntries or {})
    if not ok then
        player:emit('fishing:server:lost', { reason = reason })
        return
    end

    local updated = FishingChallengeService.getSession(source)
    player:emit('fishing:server:hooked', { fish = updated.fish })
end)
```

- [ ] **Step 3: Run the full FishingChallengeService and FishingService suites again**

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua && lua5.4 plugins/oblsk_fishing/tests/fishing_service_spec.lua`
Expected: both report `0 failed` (18+1 = 19 for challenge service, 8 for service — counts increase by the new test each)

- [ ] **Step 4: Also wire the `'landed'` grant into `main.lua`**

The `fishing:client:roundPress` handler above emits `'finished'` on landed
but never calls `FishingService.grantCatch`. Fix: change that branch to:

```lua
    if result == 'landed' then
        local session = FishingChallengeService.getSession(source)
        -- session is already nil here (resolveRound clears on landed) —
        -- capture fish from FishingChallengeService before it clears
        -- instead. Restructure: resolveRound must hand back the fish on
        -- 'landed' so main.lua doesn't need a second, now-stale read.
```

This exposes a real gap: `resolveRound` returns only a string, but the
caller needs the `fish` payload once landed (the session that held it is
already gone). Fix in `FishingChallengeService.lua`: change
`resolveRound`'s landed branch to stash the fish where the caller can still
reach it.

Change `FishingChallengeService.resolveRound`'s landed branch from:

```lua
    if session.progress >= 1 then
        sessions[source] = nil
        return 'landed'
```

to:

```lua
    if session.progress >= 1 then
        local fish = session.fish
        sessions[source] = nil
        FishingChallengeService._lastLanded = FishingChallengeService._lastLanded or {}
        FishingChallengeService._lastLanded[source] = fish
        return 'landed'
```

And add an accessor right after `resolveRound`:

```lua
--- Reads back the fish payload from the most recent 'landed' resolveRound
--- call for `source`, then clears it — one-shot, mirrors how a redeemed
--- token consumes itself elsewhere in this codebase (e.g.
--- LockpickChallengeService.redeem).
--- @param source number
--- @return table|nil { baseItemId, amount }
function FishingChallengeService.takeLastLanded(source)
    local fish = FishingChallengeService._lastLanded and FishingChallengeService._lastLanded[source]
    if FishingChallengeService._lastLanded then
        FishingChallengeService._lastLanded[source] = nil
    end
    return fish
end
```

Add a test in `fishing_challenge_service_spec.lua`, replacing the existing
`'resolveRound: progress reaching >= 1 lands the fish...'` test body to also
assert this (append before its final `end)`):

```lua
    local fish = FishingChallengeService.takeLastLanded(5)
    eq(fish.baseItemId, 10)
    eq(fish.amount, 2)
    eq(FishingChallengeService.takeLastLanded(5), nil, 'one-shot: a second read gets nothing')
```

Now fix `main.lua`'s two landed branches (`fishing:client:roundPress` and
the `sendNextRound` timeout callback) to actually grant. Replace both
occurrences of:

```lua
        if result == 'landed' or result == 'lost' then
            player:emit('fishing:server:finished', { result = result })
```

(in `sendNextRound`) with:

```lua
        if result == 'landed' then
            local fish = FishingChallengeService.takeLastLanded(source)
            local granted, reason = FishingService.grantCatch(source, fish)
            player:emit('fishing:server:finished', { result = 'landed', granted = granted, reason = reason, fish = fish })
        elseif result == 'lost' then
            player:emit('fishing:server:finished', { result = 'lost' })
```

And replace the `fishing:client:roundPress` handler's tail (from `if result == 'landed' then` onward) with:

```lua
    if result == 'landed' then
        local fish = FishingChallengeService.takeLastLanded(source)
        local granted, reason = FishingService.grantCatch(source, fish)
        player:emit('fishing:server:finished', { result = 'landed', granted = granted, reason = reason, fish = fish })
    elseif result == 'lost' then
        player:emit('fishing:server:finished', { result = 'lost' })
    else
        player:emit('fishing:server:roundResult', { result = result })
        sendNextRound(player, source)
    end
end)
```

- [ ] **Step 5: Re-run every fishing test**

Run: `lua5.4 plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua && lua5.4 plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua && lua5.4 plugins/oblsk_fishing/tests/fishing_service_spec.lua`
Expected: all three `0 failed`

- [ ] **Step 6: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing/server plugins/oblsk_fishing/tests
git commit -m "feat(fishing): wire server-side net events, interactions, and admin CRUD handlers"
```

---

## Task 9: `client/main.lua` — NUI relay and admin position capture

Gameplay/NUI code, manually verified in Task 12 (matches
`tests/README.md`'s carve-out for anything touching NUI/gameplay natives).

**Files:**
- Create: `plugins/oblsk_fishing/client/main.lua`

**Interfaces:**
- Consumes: `WebView.on/emit/emitServer` (existing), `Obelisk.onClient` (existing), `GetEntityCoords`, `PlayerPedId` (FiveM natives).
- Produces: the NUI event names `Fishing.vue` (Task 10) and `FishingTab.vue` (Task 11) call `Obelisk.emit`/listen to via `Obelisk.on`.

- [ ] **Step 1: Implement**

```lua
-- plugins/oblsk_fishing/client/main.lua
--- Fishing Plugin - Client Main
---
--- Pure relay between the NUI page and the server, same posture as
--- oblsk_vendingmachine's client/main.lua. All validation/mutation/timing
--- happens server-side in FishingChallengeService/FishingService.

WebView.on('fishing:earlyPress', function(data)
    WebView.emitServer('fishing:client:earlyPress')
end)

WebView.on('fishing:hookPress', function(data)
    WebView.emitServer('fishing:client:hookPress')
end)

WebView.on('fishing:nextRound', function(data)
    WebView.emitServer('fishing:client:nextRound')
end)

WebView.on('fishing:roundPress', function(data)
    WebView.emitServer('fishing:client:roundPress', data.roundId)
end)

WebView.on('fishing:close', function(data)
    WebView.emitServer('fishing:client:close')
end)

Obelisk.onClient('fishing:server:cast-started', function(payload)
    WebView.emit('fishing:cast-started', payload)
end)

Obelisk.onClient('fishing:server:bite', function(payload)
    WebView.emit('fishing:bite', payload)
end)

Obelisk.onClient('fishing:server:hooked', function(payload)
    WebView.emit('fishing:hooked', payload)
end)

Obelisk.onClient('fishing:server:round', function(payload)
    WebView.emit('fishing:round', payload)
end)

Obelisk.onClient('fishing:server:roundResult', function(payload)
    WebView.emit('fishing:roundResult', payload)
end)

Obelisk.onClient('fishing:server:finished', function(payload)
    WebView.emit('fishing:finished', payload)
end)

Obelisk.onClient('fishing:server:lost', function(payload)
    WebView.emit('fishing:lost', payload)
end)

--------------------------------------------------------------------------------
-- Admin tab: capture the admin's current position for "New spot".
--------------------------------------------------------------------------------

WebView.on('fishing:admin-capture-position', function(data)
    WebView.emitServer('fishing:server:admin-capture-position')
end)

Obelisk.onClient('fishing:server:capture-position', function()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    WebView.emit('fishing:admin-position-captured', { x = coords.x, y = coords.y, z = coords.z })
end)
```

- [ ] **Step 2: Manual verification**

Deferred to Task 12's manual pass (needs a running FXServer). No automated
step here — noted rather than skipped silently.

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing/client/main.lua
git commit -m "feat(fishing): add client-side NUI relay"
```

---

## Task 10: `web/Fishing.vue` — the minigame UI

**Files:**
- Create: `plugins/oblsk_fishing/web/Fishing.vue`
- Create: `plugins/oblsk_fishing/web/routes.js`

**Interfaces:**
- Consumes: `Obelisk.on`/`Obelisk.emit` from `@/obelisk.js` (existing, same import every other plugin Vue file uses), the NUI event names from Task 9 (`fishing:cast-started`, `fishing:bite`, `fishing:hooked`, `fishing:round`, `fishing:roundResult`, `fishing:finished`, `fishing:lost`, and outgoing `fishing:earlyPress`, `fishing:hookPress`, `fishing:nextRound`, `fishing:roundPress`, `fishing:close`).
- Produces: the `/Fishing` route `WebView.openPage(player, '/Fishing')` (Task 8) opens.

- [ ] **Step 1: `routes.js`**

```javascript
// plugins/oblsk_fishing/web/routes.js
export default [
  {
    path: '/Fishing',
    name: 'Fishing',
    component: () => import('./Fishing.vue')
  }
]
```

- [ ] **Step 2: `Fishing.vue`**

```vue
<!-- plugins/oblsk_fishing/web/Fishing.vue
     Fishing minigame UI. Visuals inspired by the design reference's
     FishingGame (src/proto/fishing-game.jsx); every timing/outcome
     decision here is purely a render of what the server already decided
     (see FishingChallengeService) — this component never computes a
     result, it only reports raw SPACE presses and displays what the
     server sends back. -->
<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'

const phase = ref('wait') // wait | bite | reel | done
const message = ref('Line in the water — watch the hook')
const round = ref(null) // { roundId, speed, zone, direction, bandStart }
const roundElapsedMs = ref(0)
const lastFlash = ref(null) // 'great' | 'good' | 'miss'
const progress = ref(0.28)
const finished = ref(null) // { result: 'landed'|'lost', granted, fish }

let rafId = null
let roundStartTs = 0

function startRoundClock() {
  roundStartTs = performance.now()
  const tick = (t) => {
    roundElapsedMs.value = t - roundStartTs
    rafId = requestAnimationFrame(tick)
  }
  rafId = requestAnimationFrame(tick)
}
function stopRoundClock() {
  if (rafId) cancelAnimationFrame(rafId)
  rafId = null
}

const needleDeg = computed(() => {
  if (!round.value) return 0
  const traveled = (roundElapsedMs.value / 1000) * round.value.speed
  return (round.value.direction * traveled) % 360
})

function onCastStarted() {
  phase.value = 'wait'
  message.value = 'Line in the water — watch the hook'
  finished.value = null
}
function onBite() {
  phase.value = 'bite'
  message.value = 'SPACE — set the hook'
}
function onHooked(payload) {
  phase.value = 'reel'
  progress.value = 0.28
  message.value = `${payload?.fish ? 'Something' : 'It'}'s on — stop the needle in the band`
  Obelisk.emit('fishing:nextRound', {})
}
function onRound(payload) {
  round.value = payload
  lastFlash.value = null
  startRoundClock()
}
function onRoundResult(payload) {
  lastFlash.value = payload.result
  if (payload.result === 'great') progress.value = Math.min(1, progress.value + 0.24)
  else if (payload.result === 'good') progress.value = Math.min(1, progress.value + 0.15)
  else progress.value = Math.max(0, progress.value - 0.18)
  stopRoundClock()
  round.value = null
}
function onFinished(payload) {
  stopRoundClock()
  phase.value = 'done'
  finished.value = payload
  message.value = payload.result === 'landed'
    ? (payload.granted === false ? (payload.reason || 'Inventory full') : 'Fish on the deck')
    : 'Lost it'
}
function onLost(payload) {
  stopRoundClock()
  phase.value = 'done'
  finished.value = { result: 'lost' }
  message.value = payload?.reason === 'spooked' ? 'Struck too early — you spooked it' : 'Too slow — it spat the hook'
}

function onKeydown(e) {
  if (e.code !== 'Space') return
  e.preventDefault()
  if (phase.value === 'wait') {
    Obelisk.emit('fishing:earlyPress', {})
  } else if (phase.value === 'bite') {
    Obelisk.emit('fishing:hookPress', {})
  } else if (phase.value === 'reel' && round.value) {
    Obelisk.emit('fishing:roundPress', { roundId: round.value.roundId })
  } else if (phase.value === 'done') {
    Obelisk.emit('fishing:close', {})
  }
}

onMounted(() => {
  Obelisk.on('fishing:cast-started', onCastStarted)
  Obelisk.on('fishing:bite', onBite)
  Obelisk.on('fishing:hooked', onHooked)
  Obelisk.on('fishing:round', onRound)
  Obelisk.on('fishing:roundResult', onRoundResult)
  Obelisk.on('fishing:finished', onFinished)
  Obelisk.on('fishing:lost', onLost)
  window.addEventListener('keydown', onKeydown)

  if (import.meta.env.DEV) {
    onCastStarted()
  }
})
onBeforeUnmount(() => {
  Obelisk.off('fishing:cast-started', onCastStarted)
  Obelisk.off('fishing:bite', onBite)
  Obelisk.off('fishing:hooked', onHooked)
  Obelisk.off('fishing:round', onRound)
  Obelisk.off('fishing:roundResult', onRoundResult)
  Obelisk.off('fishing:finished', onFinished)
  Obelisk.off('fishing:lost', onLost)
  window.removeEventListener('keydown', onKeydown)
  stopRoundClock()
})
</script>

<template>
  <div class="absolute" style="width:300px;left:50%;bottom:48px;transform:translateX(-50%);font-family:var(--ob-font-sans)">
    <div class="relative rounded-[10px] overflow-hidden flex flex-col items-center justify-end pb-5"
      style="height:220px;background:linear-gradient(180deg,#0d2430,#07161d 55%,#040e13);border:1px solid rgba(255,255,255,.08)">

      <div class="absolute left-0 right-0 top-0 flex items-center gap-2 px-3 h-[30px] z-10">
        <span class="ob-mono text-[9.5px] tracking-[0.16em] text-white/40 uppercase">{{ message }}</span>
      </div>

      <div v-if="phase === 'wait' || phase === 'bite'" class="flex flex-col items-center">
        <div class="relative grid place-items-center" style="width:132px;height:132px">
          <span class="absolute rounded-full" :style="{
            width: '128px', height: '128px',
            border: `2px solid ${phase === 'bite' ? '#ef4444' : 'rgba(255,255,255,.16)'}`,
            boxShadow: phase === 'bite' ? '0 0 22px rgba(239,68,68,.45)' : 'none',
          }"></span>
        </div>
        <span class="ob-mono text-[10.5px] mt-2" :style="{ color: phase === 'bite' ? '#fca5a5' : 'rgba(255,255,255,.32)' }">
          {{ phase === 'bite' ? 'PRESS SPACE' : 'WAITING FOR A BITE…' }}
        </span>
      </div>

      <div v-else-if="phase === 'reel'" class="flex flex-col items-center">
        <div class="relative grid place-items-center" style="width:146px;height:146px">
          <svg width="148" height="148" viewBox="0 0 148 148">
            <circle cx="74" cy="74" r="60" stroke="rgba(255,255,255,.12)" stroke-width="9" fill="none" />
            <line v-if="round" x1="74" y1="74"
              :x2="74 + 60 * Math.cos((needleDeg - 90) * Math.PI / 180)"
              :y2="74 + 60 * Math.sin((needleDeg - 90) * Math.PI / 180)"
              stroke="#fff" stroke-width="3" stroke-linecap="round" />
            <circle cx="74" cy="74" r="4" fill="#fff" />
          </svg>
          <div v-if="lastFlash" class="absolute inset-0 grid place-items-center pointer-events-none">
            <span class="ob-mono text-[15px] uppercase tracking-[0.18em]"
              :style="{ color: lastFlash === 'miss' ? '#f87171' : lastFlash === 'great' ? 'var(--ob-accent)' : 'rgba(255,255,255,.8)' }">
              {{ lastFlash === 'great' ? 'PERFECT' : lastFlash === 'good' ? 'GOOD' : 'SLIPPED' }}
            </span>
          </div>
        </div>
        <div class="w-[240px] mt-3">
          <div class="flex justify-between ob-mono text-[9px] text-white/40 mb-1">
            <span>REELING</span><span>{{ Math.round(progress * 100) }}%</span>
          </div>
          <div class="h-[8px] rounded-full overflow-hidden" style="background:rgba(255,255,255,.1)">
            <div :style="{ width: (progress * 100) + '%', height: '100%', background: 'var(--ob-accent)', transition: 'width .25s' }"></div>
          </div>
          <div class="ob-mono text-[9px] text-white/30 mt-2 text-center">SPACE WHEN THE NEEDLE IS IN THE BAND</div>
        </div>
      </div>

      <div v-if="phase === 'done'" class="absolute inset-0 flex items-end justify-center pb-5" style="background:rgba(0,0,0,.62)">
        <div class="text-center px-6">
          <div class="text-[16px] font-semibold uppercase" :style="{ color: finished?.result === 'landed' && finished?.granted !== false ? 'var(--ob-accent)' : '#f87171' }">
            {{ finished?.result === 'landed' ? (finished?.granted === false ? 'Couldn\'t keep it' : 'Fish on the deck') : 'Lost it' }}
          </div>
          <button @click="Obelisk.emit('fishing:close', {})" class="mt-2.5 h-[34px] px-5 rounded-[6px] text-[12.5px] font-semibold transition hover:brightness-110"
            style="background:var(--ob-accent);color:#04120d">CLOSE · SPACE</button>
        </div>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Manual verification**

Run: `cd web && npm run dev`, navigate to `/Fishing` in dev mode, confirm the
`wait` phase renders (dev fixture calls `onCastStarted()` on mount) with no
console errors. Full state-machine verification happens live against a
server in Task 12.

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing/web/Fishing.vue plugins/oblsk_fishing/web/routes.js
git commit -m "feat(fishing): add Fishing.vue minigame UI"
```

---

## Task 11: `web/FishingTab.vue` — admin panel spot/pool/entry editor

**Files:**
- Create: `plugins/oblsk_fishing/web/FishingTab.vue`
- Modify: `plugins/oblsk_admin/web/AdminPanel.vue`

**Interfaces:**
- Consumes: `fishing:server:admin-*` handlers from Task 8, `fishing:admin-position-captured` from Task 9.
- Produces: nothing consumed by later tasks — leaf UI, manually verified in Task 12.

- [ ] **Step 1: `FishingTab.vue`**

```vue
<!-- plugins/oblsk_fishing/web/FishingTab.vue
     Admin tab: create fishing spots, and per spot configure which rod
     items work there and what each rod can catch. No seeding anywhere —
     every row here is admin-authored. -->
<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'

const spots = ref([])
const items = ref([])
const selectedSpotId = ref(null)
const capturedPosition = ref(null)
const newSpotDraft = ref(null)

const DEV_STATE = {
  spots: [
    { id: 1, label: 'Pier', x: 1.0, y: 2.0, z: 3.0, range: 2.5, bait_item_id: null, rodPools: [] },
  ],
  items: [
    { id: 50, name: 'Fishing Rod' },
    { id: 51, name: 'Bluegill' },
  ],
}

const selectedSpot = computed(() => spots.value.find(s => s.id === selectedSpotId.value) || null)
const itemName = (id) => items.value.find(i => i.id === id)?.name || `#${id}`

function onAdminState({ spots: nextSpots, items: nextItems }) {
  spots.value = nextSpots
  items.value = nextItems
}
function onPositionCaptured(pos) {
  capturedPosition.value = pos
}

function fetchState() {
  if (import.meta.env.DEV) { onAdminState(DEV_STATE); return }
  Obelisk.emit('fishing:server:admin-list', {})
}

onMounted(() => {
  Obelisk.on('fishing:admin-state', onAdminState)
  Obelisk.on('fishing:admin-position-captured', onPositionCaptured)
  fetchState()
})
onBeforeUnmount(() => {
  Obelisk.off('fishing:admin-state', onAdminState)
  Obelisk.off('fishing:admin-position-captured', onPositionCaptured)
})

function capturePosition() {
  Obelisk.emit('fishing:admin-capture-position', {})
}

function openNewSpot() {
  capturedPosition.value = null
  newSpotDraft.value = { label: '', range: 2.0, bait_item_id: '' }
}
function submitNewSpot() {
  if (!capturedPosition.value) return
  Obelisk.emit('fishing:server:admin-create-spot', {
    label: newSpotDraft.value.label,
    x: capturedPosition.value.x,
    y: capturedPosition.value.y,
    z: capturedPosition.value.z,
    range: Number(newSpotDraft.value.range) || 2.0,
    bait_item_id: newSpotDraft.value.bait_item_id ? Number(newSpotDraft.value.bait_item_id) : null,
  })
  newSpotDraft.value = null
}
function deleteSpot(spot) {
  Obelisk.emit('fishing:server:admin-delete-spot', { id: spot.id })
  if (selectedSpotId.value === spot.id) selectedSpotId.value = null
}

const newRodItemId = ref('')
function addRodPool(spot) {
  if (!newRodItemId.value) return
  Obelisk.emit('fishing:server:admin-create-rod-pool', { spotId: spot.id, rodBaseItemId: Number(newRodItemId.value) })
  newRodItemId.value = ''
}
function deleteRodPool(pool) {
  Obelisk.emit('fishing:server:admin-delete-rod-pool', { id: pool.id })
}

const newEntryDraft = ref({})
function addEntry(pool) {
  const draft = newEntryDraft.value[pool.id]
  if (!draft || !draft.base_item_id) return
  Obelisk.emit('fishing:server:admin-create-pool-entry', {
    rodPoolId: pool.id,
    attrs: {
      base_item_id: Number(draft.base_item_id),
      weight: Number(draft.weight) || 1,
      difficulty: Number(draft.difficulty) || 1,
      min_amount: Number(draft.min_amount) || 1,
      max_amount: Number(draft.max_amount) || 1,
    },
  })
  newEntryDraft.value[pool.id] = {}
}
function deleteEntry(entry) {
  Obelisk.emit('fishing:server:admin-delete-pool-entry', { id: entry.id })
}
</script>

<template>
  <div class="grid gap-3 min-h-0 p-5 overflow-y-auto" style="grid-template-columns: 260px 1fr">
    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex flex-col">
      <div class="px-4 py-2.5 border-b border-white/8 flex items-center justify-between">
        <span class="text-[12.5px] font-medium">Spots · {{ spots.length }}</span>
        <button @click="openNewSpot" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">+ NEW</button>
      </div>
      <div class="overflow-y-auto" style="max-height: 520px">
        <button v-for="s in spots" :key="s.id" @click="selectedSpotId = s.id"
          class="w-full px-3.5 py-2.5 text-left border-b border-white/6 transition"
          :class="selectedSpotId === s.id ? 'bg-white/[0.07]' : 'hover:bg-white/4'">
          <span class="block text-[12px] truncate">{{ s.label }}</span>
          <span class="block ob-mono text-[9px] text-white/35 truncate">{{ (s.rodPools || []).length }} rod pool(s)</span>
        </button>
        <div v-if="!spots.length" class="py-6 text-center text-[11.5px] text-white/30">No spots.</div>
      </div>
    </div>

    <div v-if="newSpotDraft" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-3">
      <div class="text-[13px] font-medium">New spot</div>
      <input v-model="newSpotDraft.label" placeholder="Label" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
      <input v-model.number="newSpotDraft.range" type="number" step="0.5" placeholder="Range" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
      <select v-model="newSpotDraft.bait_item_id" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none">
        <option value="">No bait required</option>
        <option v-for="i in items" :key="i.id" :value="i.id">{{ i.name }}</option>
      </select>
      <button @click="capturePosition" class="h-9 px-4 rounded-lg border border-white/12 text-[12px]">Use my position</button>
      <span v-if="capturedPosition" class="ob-mono text-[10px] text-white/40 block">{{ capturedPosition.x.toFixed(1) }}, {{ capturedPosition.y.toFixed(1) }}, {{ capturedPosition.z.toFixed(1) }}</span>
      <div class="flex gap-2">
        <button @click="newSpotDraft = null" class="h-9 px-3.5 rounded-lg border border-white/12 text-[12px]">Cancel</button>
        <button @click="submitNewSpot" :disabled="!capturedPosition" class="h-9 px-4 rounded-lg text-black text-[12px] font-medium disabled:opacity-40" style="background:var(--ob-accent)">Create spot</button>
      </div>
    </div>

    <div v-else-if="selectedSpot" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-4 overflow-y-auto">
      <div class="flex items-center justify-between">
        <div class="text-[13px] font-medium">{{ selectedSpot.label }}</div>
        <button @click="deleteSpot(selectedSpot)" class="ob-mono text-[9px] px-2 py-1 rounded border border-red-500/40 text-red-400 hover:bg-red-500/10">DELETE SPOT</button>
      </div>

      <div v-for="pool in selectedSpot.rodPools" :key="pool.id" class="rounded-lg border border-white/8 p-3 space-y-2">
        <div class="flex items-center justify-between">
          <span class="ob-mono text-[10px] text-white/60">Rod: {{ itemName(pool.rod_base_item_id) }}</span>
          <button @click="deleteRodPool(pool)" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-red-500/40 text-red-400 hover:bg-red-500/10">REMOVE ROD</button>
        </div>
        <div v-for="entry in pool.entries" :key="entry.id" class="flex items-center justify-between text-[11px] text-white/70">
          <span>{{ itemName(entry.base_item_id) }} · weight {{ entry.weight }} · diff {{ entry.difficulty }} · {{ entry.min_amount }}-{{ entry.max_amount }}</span>
          <button @click="deleteEntry(entry)" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">×</button>
        </div>
        <div class="flex flex-wrap gap-1.5 items-center pt-1">
          <select v-model="newEntryDraft[pool.id].base_item_id" @vue:mounted="newEntryDraft[pool.id] = newEntryDraft[pool.id] || {}" class="h-8 px-2 rounded bg-black/40 border border-white/12 text-[10.5px] outline-none">
            <option value="">Item…</option>
            <option v-for="i in items" :key="i.id" :value="i.id">{{ i.name }}</option>
          </select>
          <input v-model="newEntryDraft[pool.id].weight" placeholder="weight" type="number" class="h-8 w-16 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <input v-model="newEntryDraft[pool.id].difficulty" placeholder="difficulty" type="number" step="0.1" class="h-8 w-20 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <input v-model="newEntryDraft[pool.id].min_amount" placeholder="min" type="number" class="h-8 w-14 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <input v-model="newEntryDraft[pool.id].max_amount" placeholder="max" type="number" class="h-8 w-14 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <button @click="addEntry(pool)" class="h-8 px-2 rounded text-black text-[10.5px] font-medium" style="background:var(--ob-accent)">+ Add</button>
        </div>
      </div>

      <div class="flex gap-1.5 items-center pt-1">
        <select v-model="newRodItemId" class="h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none">
          <option value="">Rod item…</option>
          <option v-for="i in items" :key="i.id" :value="i.id">{{ i.name }}</option>
        </select>
        <button @click="addRodPool(selectedSpot)" class="h-9 px-3 rounded-lg text-black text-[12px] font-medium" style="background:var(--ob-accent)">+ Add rod pool</button>
      </div>
    </div>

    <div v-else class="grid place-items-center text-white/30 text-[12px]">No spot selected.</div>
  </div>
</template>
```

Note: the `@vue:mounted="newEntryDraft[pool.id] = newEntryDraft[pool.id] || {}"` on the item `<select>` is a real but unusual pattern — it exists to lazily initialize `newEntryDraft[pool.id]` before `v-model` binds to it. Simplify this in Step 2.

- [ ] **Step 2: Simplify the entry-draft initialization**

Vue lifecycle hooks on plain elements are unreliable for this; replace with
explicit initialization. Change `pool.entries` block's `v-for` to compute
the draft up front. In the `<script setup>`, replace the `addEntry` function
and add an initializer, right after `const newEntryDraft = ref({})`:

```javascript
function draftFor(poolId) {
  if (!newEntryDraft.value[poolId]) newEntryDraft.value[poolId] = { base_item_id: '', weight: 1, difficulty: 1, min_amount: 1, max_amount: 1 }
  return newEntryDraft.value[poolId]
}
function addEntry(pool) {
  const draft = draftFor(pool.id)
  if (!draft.base_item_id) return
  Obelisk.emit('fishing:server:admin-create-pool-entry', {
    rodPoolId: pool.id,
    attrs: {
      base_item_id: Number(draft.base_item_id),
      weight: Number(draft.weight) || 1,
      difficulty: Number(draft.difficulty) || 1,
      min_amount: Number(draft.min_amount) || 1,
      max_amount: Number(draft.max_amount) || 1,
    },
  })
  newEntryDraft.value[pool.id] = { base_item_id: '', weight: 1, difficulty: 1, min_amount: 1, max_amount: 1 }
}
```

In the template, replace the entry-add row's controls to use `draftFor(pool.id)`:

```html
        <div class="flex flex-wrap gap-1.5 items-center pt-1">
          <select v-model="draftFor(pool.id).base_item_id" class="h-8 px-2 rounded bg-black/40 border border-white/12 text-[10.5px] outline-none">
            <option value="">Item…</option>
            <option v-for="i in items" :key="i.id" :value="i.id">{{ i.name }}</option>
          </select>
          <input v-model="draftFor(pool.id).weight" placeholder="weight" type="number" class="h-8 w-16 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <input v-model="draftFor(pool.id).difficulty" placeholder="difficulty" type="number" step="0.1" class="h-8 w-20 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <input v-model="draftFor(pool.id).min_amount" placeholder="min" type="number" class="h-8 w-14 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <input v-model="draftFor(pool.id).max_amount" placeholder="max" type="number" class="h-8 w-14 px-2 rounded bg-black/40 border border-white/12 ob-mono text-[10.5px] outline-none" />
          <button @click="addEntry(pool)" class="h-8 px-2 rounded text-black text-[10.5px] font-medium" style="background:var(--ob-accent)">+ Add</button>
        </div>
```

- [ ] **Step 3: Wire into `AdminPanel.vue`**

In `plugins/oblsk_admin/web/AdminPanel.vue`, add the import:

```javascript
import FishingTab from '../../oblsk_fishing/web/FishingTab.vue'
```

Add a `fishing` tab entry to `TABS` (after `items`):

```javascript
const TABS = [
  ['players', 'Players'], ['moderation', 'Moderation'], ['organisations', 'Organisations'],
  ['vehicles', 'Vehicles'], ['interactions', 'Interactions'], ['blips', 'Blips'],
  ['locations', 'Locations'], ['items', 'Items'], ['fishing', 'Fishing'], ['economy', 'Economy'],
  ['server', 'Server'], ['audit', 'Audit log'],
]
```

And render it, after the `ItemsTab` line:

```html
      <ItemsTab v-else-if="activeTab === 'items'" />
      <FishingTab v-else-if="activeTab === 'fishing'" />
```

- [ ] **Step 4: Manual verification**

Run: `cd web && npm run dev`, open `/Admin`, click the Fishing tab, confirm
the dev-fixture spot ("Pier") renders with no console errors.

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add plugins/oblsk_fishing/web/FishingTab.vue plugins/oblsk_admin/web/AdminPanel.vue
git commit -m "feat(fishing): add admin Fishing tab for spot/pool/entry config"
```

---

## Task 12: nested repo, manual server verification, final review

**Files:** none new — this task is process, not code.

- [ ] **Step 1: Initialize `oblsk_fishing` as its own nested git repo**

Every other plugin under `plugins/` (`oblsk_vendingmachine`, `oblsk_terminal`,
etc.) is its own nested git repository, gitignored from the core repo's
perspective. Match that:

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_fishing
git init
git add -A
git commit -m "feat: initial oblsk_fishing plugin"
```

- [ ] **Step 2: Ask the user for a remote and push**

This plan does not choose a remote URL or push automatically — creating a
GitHub repo and pushing to it is a visible, hard-to-reverse action the user
should confirm. Ask: "Where should `oblsk_fishing` be pushed — an existing
empty GitHub repo URL, or should I create one via `gh repo create`?" Then:

```bash
git remote add origin <url>
git branch -M main
git push -u origin main
```

- [ ] **Step 3: Run every unit test in the plugin, plus the ones touched in `oblsk_items`**

```bash
cd /home/andi/Projects/obelisk-framework/core
lua5.4 modules/oblsk_items/tests/item_service_capacity_spec.lua
lua5.4 modules/oblsk_items/tests/item_service_admin_spec.lua
lua5.4 modules/oblsk_items/tests/item_service_inventory_spec.lua
lua5.4 modules/oblsk_items/tests/item_service_binding_spec.lua
lua5.4 plugins/oblsk_fishing/tests/fishing_spot_service_spec.lua
lua5.4 plugins/oblsk_fishing/tests/fishing_challenge_service_spec.lua
lua5.4 plugins/oblsk_fishing/tests/fishing_service_spec.lua
```

Expected: every one reports `0 failed`.

- [ ] **Step 4: Manual server verification checklist**

Against a running FXServer with the framework loaded (`server.cfg` per
`SETUP_MYSQL.md`), as an admin:

1. Items tab → create an item named "Fishing Rod", binding key `fishing.rod`. Confirm `[Obelisk] N item binding(s) unbound...` at next boot no longer lists `fishing.rod`.
2. Fishing tab → New spot → Use my position → Create spot.
3. On the spot, add a rod pool for "Fishing Rod", add 2-3 pool entries (existing base items) with different weights/difficulties.
4. Give yourself a "Fishing Rod" via the Items tab's Give flow.
5. Walk to the spot in-game, interact, confirm the `/Fishing` UI opens and the wait/bite/reel/done flow runs to completion (both a landed and a lost run).
6. Confirm a landed catch actually appears in your inventory (or, if you're at `ItemService.MaxSlots`/`MaxWeight`, confirm the "inventory full" message shows and nothing is added).
7. Disconnect mid-`reel` phase (or `/quit`), reconnect, confirm no leftover session blocks a fresh cast (`FishingChallengeService.clearSource` via `playerDropped`).

- [ ] **Step 5: Final commit (if any manual-pass fixes were needed)**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add -A
git commit -m "fix(fishing): address manual server-verification findings"
```

(Skip this step entirely if manual verification found nothing to fix.)
