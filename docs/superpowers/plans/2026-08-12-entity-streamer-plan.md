# Entity Streamer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing (currently dead-code) `EntityStreamerService` with DB-backed persistence, a global entity budget with three-tier degradation, anti-thrash hysteresis, facing-direction look-ahead precache, and per-entity networked/local-only spawning.

**Architecture:** Every change is additive to the two existing `EntityStreamerService.lua` files (`core/core/server/Services/` and `core/core/client/Services/`) — no rewrite, no new service files. A new `entities` table + `Entity` model (matching the existing `Organization`/`Interaction` model convention) replaces the current in-memory-only registration with real persistence.

**Tech Stack:** Lua 5.4 (FiveM server/client), this repo's ORM (`Schema`/`BaseModel`/`QueryBuilder`), `lua5.4` as the server-side test runner (plain scripts, fake `QueryBuilder`), no client-side automated tests (natives aren't testable outside FiveM).

## Global Constraints

- Every column defaults to NOT NULL now; `:nullable()` must be used explicitly wherever a column is optional. `:notNullable()` does not exist — do not use it anywhere in this plan's migration.
- Budget only counts `ped`/`object`/`pickup` entities — `marker`/`blip` are always free (no entity handle, no budget impact).
- Tier 3 (current chunk only) is never rejected — it's the guaranteed minimum every player gets regardless of budget pressure.
- Boundary hysteresis: a chunk only unloads once the player is 15 units past its boundary. Tier hysteresis: a tier change only takes effect after 2 consecutive position-update ticks agree (ticks are the existing 500ms client interval).
- Facing chunk is recomputed only when the heading has changed more than 20° since the value last used to pick it.
- Networked entities (`entities.networked = true`) are spawned exactly once, by whichever client's active-chunk set first includes them; local-only entities (`networked = false`, the default) are spawned independently by every client that has the owning chunk active.
- No Claude co-authorship in any commit. Minimize em/en dashes in prose (commit messages, docs), not code/SQL.
- `core/fxmanifest.lua` already globs `core/server/Services/*.lua`, `core/server/Models/**/*.lua`, and `core/client/Services/**/*.lua` — no manifest changes needed for any file this plan touches or adds.

---

## File Structure

```
core/core/
  server/
    database/
      migrations/
        2026_08_12_070000_create_entities_table.lua   -- new
      migrations.json                                  -- modified: append the above
    Models/
      Entity.lua                                        -- new
    Services/
      EntityStreamerService.lua                          -- modified throughout (see tasks)
  client/
    Services/
      EntityStreamerService.lua                          -- modified throughout (see tasks)
core/tests/
  entity_streamer_service_spec.lua                        -- new
```

---

## Task 1: `entities` table, `Entity` model, DB-backed `init()`

**Files:**
- Create: `core/server/database/migrations/2026_08_12_070000_create_entities_table.lua`
- Modify: `core/server/database/migrations.json` (append the migration name)
- Create: `core/server/Models/Entity.lua`
- Modify: `core/server/Services/EntityStreamerService.lua:11-17` (`init()`)
- Test: `core/tests/entity_streamer_service_spec.lua` (new file, this task's tests)

**Interfaces:**
- Produces: `Entity` model (`Entity = BaseModel:extend('entities')`), `fillable = { 'entity_type', 'model', 'x', 'y', 'z', 'heading', 'networked', 'enabled', 'owner_type', 'owner_id', 'data' }`. `EntityStreamerService.init()` now loads every `enabled = true` row via `Entity:where('enabled', true):getSync()` and calls the existing `EntityStreamerService.register(entityType, entityData)` for each.
- Consumes: `EntityStreamerService.register` (already exists, unchanged signature — `register(entityType, entityData)` where `entityData` has `x`/`y`/`z` plus whatever the entity type needs).

- [ ] **Step 1: Write the migration**

`core/server/database/migrations/2026_08_12_070000_create_entities_table.lua`:
```lua
--- Migration: Create entities table
return {
    up = function()
        Schema.create('entities', function(table)
            table:id()
            table:enum('entity_type', {'ped', 'object', 'pickup', 'marker', 'blip'})
            table:string('model', 100):nullable()
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('heading'):nullable()
            table:boolean('networked'):default(0)
            table:boolean('enabled'):default(1)
            table:string('owner_type', 30):nullable()
            table:integer('owner_id'):nullable()
            table:json('data'):nullable()
            table:timestamps()

            table:index({'x', 'y'})
        end)

        print('[Migration] Created entities table')
    end,

    down = function()
        Schema.drop('entities')
        print('[Migration] Dropped entities table')
    end
}
```

- [ ] **Step 2: Register the migration**

Append `"2026_08_12_070000_create_entities_table"` to the `"migrations"` array in `core/server/database/migrations.json` (last entry, after `"2026_08_11_070000_create_permissions_table"`).

- [ ] **Step 3: Write the model**

`core/server/Models/Entity.lua`:
```lua
--- Entity Model - a streamable world entity (ped/object/pickup/marker/blip)
--- placed by an admin or a plugin. See
--- docs/superpowers/specs/2026-08-12-entity-streamer-design.md.
Entity = BaseModel:extend('entities')

Entity.primaryKey = 'id'
Entity.timestamps = true
Entity.fillable = {
    'entity_type', 'model', 'x', 'y', 'z', 'heading',
    'networked', 'enabled', 'owner_type', 'owner_id', 'data',
}
Entity.hidden = {}

return Entity
```

- [ ] **Step 4: Write the failing test**

`core/tests/entity_streamer_service_spec.lua`:
```lua
--- Unit tests for the server-side EntityStreamerService.
--- Run from the repository root:  lua5.4 tests/entity_streamer_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'mismatch') .. ' -- expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    end
end

local function freshService(tables)
    QueryBuilder = makeFakeQueryBuilderModule(tables or {})
    dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
    dofile(ROOT .. '/core/server/Models/Entity.lua')
    package.loaded = package.loaded or {}
    return dofile(ROOT .. '/core/server/Services/EntityStreamerService.lua')
end

test('init() loads enabled entities from the Entity model and registers each one', function()
    local tables = {
        entities = {
            { id = 1, entity_type = 'ped', model = 'a_m_y_business_01', x = 10.0, y = 20.0, z = 30.0,
              heading = 0.0, networked = false, enabled = true },
            { id = 2, entity_type = 'object', model = 'prop_box', x = 110.0, y = 20.0, z = 30.0,
              heading = 0.0, networked = false, enabled = true },
            { id = 3, entity_type = 'ped', model = 'a_m_y_business_02', x = 999.0, y = 999.0, z = 30.0,
              heading = 0.0, networked = false, enabled = false },
        }
    }
    local Streamer = freshService(tables)

    Streamer.init()

    eq(Streamer.entities.ped['1'] ~= nil or Streamer.entities.ped[1] ~= nil, true, 'ped #1 registered')
    local chunk1 = Streamer.getChunkKey(10.0, 20.0)
    local chunk2 = Streamer.getChunkKey(110.0, 20.0)
    eq(Streamer.chunks[chunk1] ~= nil and Streamer.chunks[chunk1].ped ~= nil, true, 'chunk1 has a ped')
    eq(Streamer.chunks[chunk2] ~= nil and Streamer.chunks[chunk2].object ~= nil, true, 'chunk2 has an object')

    local disabledChunk = Streamer.getChunkKey(999.0, 999.0)
    eq(Streamer.chunks[disabledChunk], nil, 'disabled entity #3 never registered')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 5: Run test to verify it fails**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: FAIL — `init()` still just zeroes `entityTypes` tables, never queries `Entity`.

- [ ] **Step 6: Implement `init()`**

Replace `core/server/Services/EntityStreamerService.lua`'s `init()` function (currently lines 11-17):
```lua
--- Initialize the streamer: reset in-memory state, then load every
--- currently-enabled entity from the database and register it.
function EntityStreamerService.init()
    for _, entityType in ipairs(EntityStreamerService.entityTypes) do
        EntityStreamerService.entities[entityType] = {}
    end
    EntityStreamerService.chunks = {}

    local rows = Entity:where('enabled', true):getSync()
    for _, row in ipairs(rows) do
        EntityStreamerService.register(row.entity_type, {
            x = row.x, y = row.y, z = row.z, heading = row.heading,
            model = row.model, networked = row.networked, data = row.data,
        })
    end

    print('[EntityStreamerService] Initialized, loaded ' .. #rows .. ' entities')
end
```

- [ ] **Step 7: Run test to verify it passes**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: `All tests passed`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add core/server/database/migrations/2026_08_12_070000_create_entities_table.lua core/server/database/migrations.json core/server/Models/Entity.lua core/server/Services/EntityStreamerService.lua tests/entity_streamer_service_spec.lua
git commit -m "Load streamed entities from the database instead of staying empty"
```

---

## Task 2: Global entity budget and tier selection

**Files:**
- Modify: `core/server/Services/EntityStreamerService.lua` (add budget state + `selectTier`)
- Test: `core/tests/entity_streamer_service_spec.lua`

**Interfaces:**
- Produces:
  - `EntityStreamerService.entityBudget = 300` (module-level constant).
  - `EntityStreamerService.chunkPlayerRefs` — `{chunkKey: number}`, how many players currently have that chunk in their active set.
  - `EntityStreamerService.globalSpawnedCount` — running total of budget-countable (`ped`/`object`/`pickup`) entities across every chunk with `chunkPlayerRefs[chunkKey] > 0`.
  - `EntityStreamerService.countBudgetEntitiesInChunk(chunkKey) -> number` — sums `ped`/`object`/`pickup` entity counts in `EntityStreamerService.chunks[chunkKey]` (ignores `marker`/`blip`).
  - `EntityStreamerService.selectTier(currentChunk, facingChunk) -> chunkList, tierNumber` — tries the 9-chunk set (tier 1), then the 2-chunk `{currentChunk, facingChunk}` set (tier 2), then `{currentChunk}` (tier 3, always succeeds), returning the first whose *projected* addition to `globalSpawnedCount` (only counting chunks not already referenced by any other player) stays within `entityBudget`.
- Consumes: `EntityStreamerService.getSurroundingChunks` (existing), `EntityStreamerService.chunks` (existing, populated by Task 1's `init()`/`register`).

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/entity_streamer_service_spec.lua` (before the final `if #failures > 0` block):
```lua
test('countBudgetEntitiesInChunk sums ped/object/pickup but ignores marker/blip', function()
    local Streamer = freshService({ entities = {} })
    Streamer.chunks['0_0'] = {
        ped = { a = true, b = true },
        object = { c = true },
        marker = { d = true, e = true, f = true },
        blip = { g = true },
    }
    eq(Streamer.countBudgetEntitiesInChunk('0_0'), 3, 'only 2 peds + 1 object counted')
end)

test('selectTier returns tier 1 (9 chunks) when the budget comfortably fits', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 300
    Streamer.chunks['0_0'] = { ped = { a = true } }
    local chunks, tier = Streamer.selectTier('0_0', '1_0')
    eq(tier, 1)
    eq(#chunks, 9)
end)

test('selectTier degrades to tier 2 (current+facing) when tier 1 would exceed budget', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 5
    -- 9 surrounding chunks, one of them (a neighbor, not current/facing) has 10 peds
    Streamer.chunks['0_0'] = { ped = { a = true } }
    Streamer.chunks['1_0'] = { ped = { a = true } }
    Streamer.chunks['1_1'] = {}
    for i = 1, 10 do Streamer.chunks['1_1'].ped = Streamer.chunks['1_1'].ped or {} end
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['1_1'].ped = heavy
    local chunks, tier = Streamer.selectTier('0_0', '1_0')
    eq(tier, 2)
    eq(#chunks, 2)
end)

test('selectTier falls back to tier 3 (current chunk only) when even tier 2 exceeds budget', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 1
    Streamer.chunks['0_0'] = { ped = { a = true } }
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['1_0'] = { ped = heavy }
    local chunks, tier = Streamer.selectTier('0_0', '1_0')
    eq(tier, 3)
    eq(#chunks, 1)
    eq(chunks[1], '0_0')
end)

test('selectTier never rejects tier 3 even at zero budget', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 0
    local heavy = {}
    for i = 1, 5 do heavy['p' .. i] = true end
    Streamer.chunks['0_0'] = { ped = heavy }
    local chunks, tier = Streamer.selectTier('0_0', '1_0')
    eq(tier, 3)
end)

test('selectTier does not double-count a chunk already referenced by another player', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 12
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['1_1'] = { ped = heavy }
    -- another player already has this chunk loaded, so it must not count
    -- again toward THIS player's projected budget check
    Streamer.chunkPlayerRefs['1_1'] = 1
    Streamer.globalSpawnedCount = 10
    Streamer.chunks['0_0'] = { ped = { a = true } }
    local chunks, tier = Streamer.selectTier('0_0', '1_0')
    eq(tier, 1, 'tier 1 fits because 1_1 is already loaded, not counted again')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: FAIL — `entityBudget`, `chunkPlayerRefs`, `globalSpawnedCount`, `countBudgetEntitiesInChunk`, `selectTier` don't exist yet.

- [ ] **Step 3: Add budget state**

In `core/server/Services/EntityStreamerService.lua`, after the existing state declarations (after line 8, `EntityStreamerService.entityTypes = {...}`):
```lua
EntityStreamerService.entityBudget = 300 -- global cap on peds/objects/pickups spawned across all players
EntityStreamerService.chunkPlayerRefs = {} -- {chunkKey: number of players with this chunk active}
EntityStreamerService.globalSpawnedCount = 0 -- sum of budget-countable entities across referenced chunks
EntityStreamerService.budgetCountableTypes = { ped = true, object = true, pickup = true }
```

- [ ] **Step 4: Implement `countBudgetEntitiesInChunk` and `selectTier`**

Add after `getSurroundingChunks` (after the existing function ending around line 48):
```lua
--- Count only budget-relevant entities (ped/object/pickup) in a chunk.
--- Markers and blips never consume an entity handle, so they're free.
--- @param chunkKey string
--- @return number
function EntityStreamerService.countBudgetEntitiesInChunk(chunkKey)
    local chunk = EntityStreamerService.chunks[chunkKey]
    if not chunk then return 0 end

    local count = 0
    for entityType, isCountable in pairs(EntityStreamerService.budgetCountableTypes) do
        if isCountable and chunk[entityType] then
            for _ in pairs(chunk[entityType]) do
                count = count + 1
            end
        end
    end
    return count
end

--- Project how much a candidate chunk set would add to the global budget,
--- counting only chunks no other player already has referenced (a chunk
--- shared by two nearby players is one real cost, not two).
--- @param chunkList string[]
--- @return number
local function projectedAddition(chunkList)
    local addition = 0
    for _, chunkKey in ipairs(chunkList) do
        if (EntityStreamerService.chunkPlayerRefs[chunkKey] or 0) == 0 then
            addition = addition + EntityStreamerService.countBudgetEntitiesInChunk(chunkKey)
        end
    end
    return addition
end

--- Pick the highest tier (widest chunk set) that fits within the global
--- entity budget. Tier 3 (current chunk only) always succeeds.
--- @param currentChunk string
--- @param facingChunk string
--- @return string[] chunkList, number tier
function EntityStreamerService.selectTier(currentChunk, facingChunk)
    local tier1 = EntityStreamerService.getSurroundingChunks(currentChunk, 1)
    if EntityStreamerService.globalSpawnedCount + projectedAddition(tier1) <= EntityStreamerService.entityBudget then
        return tier1, 1
    end

    local tier2 = { currentChunk, facingChunk }
    if EntityStreamerService.globalSpawnedCount + projectedAddition(tier2) <= EntityStreamerService.entityBudget then
        return tier2, 2
    end

    return { currentChunk }, 3
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: `All tests passed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add core/server/Services/EntityStreamerService.lua tests/entity_streamer_service_spec.lua
git commit -m "Add global entity budget and three-tier chunk selection"
```

---

## Task 3: Hysteresis (chunk-boundary and tier)

**Files:**
- Modify: `core/server/Services/EntityStreamerService.lua` (`updatePlayerChunks`, `loadChunkForPlayer`/`unloadChunkForPlayer` callers, `chunkPlayerRefs` bookkeeping)
- Test: `core/tests/entity_streamer_service_spec.lua`

**Interfaces:**
- Produces:
  - `EntityStreamerService.getChunkBounds(chunkKey) -> minX, minY, maxX, maxY`.
  - `EntityStreamerService.distancePastBoundary(x, y, chunkKey) -> number` — 0 if `(x,y)` is still inside `chunkKey`'s bounds, else the distance from `(x,y)` to the nearest edge of that chunk.
  - `EntityStreamerService.updatePlayerChunks(source, x, y, facingChunk)` — signature extended with a `facingChunk` parameter (computed in Task 4; for this task's own tests, pass any chunk key). Chunks are only unloaded once `distancePastBoundary(x, y, oldChunkKey) > 15`. A tier change (from `selectTier`) only takes effect once the same tier has been selected on 2 consecutive calls — tracked via `playerData.pendingTier`/`playerData.pendingTierTicks`.
  - `EntityStreamerService.chunkPlayerRefs` (from Task 2) is now actually maintained: incremented when a chunk becomes active for a player, decremented when it's unloaded for them.
- Consumes: `EntityStreamerService.selectTier` (Task 2), `EntityStreamerService.chunkSize` (existing).

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/entity_streamer_service_spec.lua`:
```lua
test('getChunkBounds returns the axis-aligned box for a chunk key', function()
    local Streamer = freshService({ entities = {} })
    local minX, minY, maxX, maxY = Streamer.getChunkBounds('1_2')
    eq(minX, 100.0)
    eq(minY, 200.0)
    eq(maxX, 200.0)
    eq(maxY, 300.0)
end)

test('distancePastBoundary is 0 while still inside the chunk', function()
    local Streamer = freshService({ entities = {} })
    eq(Streamer.distancePastBoundary(150.0, 250.0, '1_2'), 0)
end)

test('distancePastBoundary is positive once outside the chunk', function()
    local Streamer = freshService({ entities = {} })
    -- chunk 1_2 spans x:[100,200) y:[200,300); 210,250 is 10 units past the x=200 edge
    eq(Streamer.distancePastBoundary(210.0, 250.0, '1_2'), 10.0)
end)

test('updatePlayerChunks keeps a chunk active until the player is 15 units past its boundary', function()
    local Streamer = freshService({ entities = {} })
    -- start inside chunk 0_0, tier 3 only (huge budget so tier stays wide, but
    -- force via a tiny facing offset so the test is about boundary hysteresis,
    -- not tier hysteresis)
    Streamer.entityBudget = 100000
    Streamer.updatePlayerChunks(1, 50.0, 50.0, '0_0')
    local firstActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do firstActive[c] = true end
    eq(firstActive['0_0'], true, 'starts with 0_0 active')

    -- move 5 units past the x=100 boundary into chunk 1_0 -- within the 15-unit
    -- margin, so 0_0 must still be active
    Streamer.updatePlayerChunks(1, 105.0, 50.0, '1_0')
    local stillActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do stillActive[c] = true end
    eq(stillActive['0_0'], true, '0_0 stays active within the 15-unit margin')

    -- move 20 units past the boundary -- now it should unload
    Streamer.updatePlayerChunks(1, 120.0, 50.0, '1_0')
    local laterActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do laterActive[c] = true end
    eq(laterActive['0_0'], nil, '0_0 unloads once 20 units past the boundary')
end)

test('updatePlayerChunks only changes tier after 2 consecutive ticks agree', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 100000
    Streamer.updatePlayerChunks(1, 50.0, 50.0, '0_0')
    eq(#Streamer.playerChunks[1].activeChunks, 9, 'starts at tier 1 (9 chunks)')

    -- one tick where the budget suddenly can't fit tier 1 -- should NOT flip yet
    Streamer.entityBudget = 0
    Streamer.updatePlayerChunks(1, 50.0, 50.0, '0_0')
    eq(#Streamer.playerChunks[1].activeChunks, 9, 'a single spike does not downgrade the tier')

    -- second consecutive tick agreeing -- now it flips
    Streamer.updatePlayerChunks(1, 50.0, 50.0, '0_0')
    eq(#Streamer.playerChunks[1].activeChunks, 1, 'two consecutive ticks downgrade to tier 3')
end)

test('chunkPlayerRefs increments when a chunk becomes active and decrements when unloaded', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 100000
    Streamer.updatePlayerChunks(1, 50.0, 50.0, '0_0')
    eq(Streamer.chunkPlayerRefs['0_0'], 1, 'ref count incremented for the player chunk')

    Streamer.updatePlayerChunks(1, 1500.0, 1500.0, '16_15')
    eq(Streamer.chunkPlayerRefs['0_0'] or 0, 0, 'ref count decremented after moving far away')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: FAIL — `getChunkBounds`/`distancePastBoundary` don't exist, `updatePlayerChunks` doesn't accept a `facingChunk` arg or apply hysteresis yet.

- [ ] **Step 3: Implement `getChunkBounds` and `distancePastBoundary`**

Add after `getSurroundingChunks` (before Task 2's additions, or right after them — either position works, keep them grouped with the other chunk-math helpers):
```lua
--- Axis-aligned bounds of a chunk.
--- @param chunkKey string
--- @return number minX, number minY, number maxX, number maxY
function EntityStreamerService.getChunkBounds(chunkKey)
    local chunkX, chunkY = chunkKey:match('(-?%d+)_(-?%d+)')
    chunkX, chunkY = tonumber(chunkX), tonumber(chunkY)
    local size = EntityStreamerService.chunkSize
    return chunkX * size, chunkY * size, (chunkX + 1) * size, (chunkY + 1) * size
end

--- How far (x, y) is outside chunkKey's bounds. 0 if still inside.
--- @param x number
--- @param y number
--- @param chunkKey string
--- @return number
function EntityStreamerService.distancePastBoundary(x, y, chunkKey)
    local minX, minY, maxX, maxY = EntityStreamerService.getChunkBounds(chunkKey)
    local dx = math.max(minX - x, 0, x - maxX)
    local dy = math.max(minY - y, 0, y - maxY)
    return math.max(dx, dy)
end
```

- [ ] **Step 4: Rewrite `updatePlayerChunks` with hysteresis and ref-counting**

Replace `core/server/Services/EntityStreamerService.lua`'s existing `updatePlayerChunks` function in full:
```lua
--- Update player's active chunks, applying tier selection, boundary
--- hysteresis, and tier hysteresis.
--- @param source number Player server ID
--- @param x number
--- @param y number
--- @param facingChunk string the chunk key the player is currently facing
function EntityStreamerService.updatePlayerChunks(source, x, y, facingChunk)
    local currentChunk = EntityStreamerService.getChunkKey(x, y)

    if not EntityStreamerService.playerChunks[source] then
        EntityStreamerService.playerChunks[source] = {
            currentChunk = currentChunk,
            activeChunks = {},
            pendingTier = nil,
            pendingTierTicks = 0,
        }
    end
    local playerData = EntityStreamerService.playerChunks[source]

    local candidateChunks, candidateTier = EntityStreamerService.selectTier(currentChunk, facingChunk)

    -- Tier hysteresis: only commit a tier change after 2 consecutive ticks agree.
    if playerData.pendingTier == candidateTier then
        playerData.pendingTierTicks = playerData.pendingTierTicks + 1
    else
        playerData.pendingTier = candidateTier
        playerData.pendingTierTicks = 1
    end

    local committedTier = playerData.committedTier
    if committedTier == nil or playerData.pendingTierTicks >= 2 then
        committedTier = candidateTier
        playerData.committedTier = candidateTier
    end
    local newActiveChunks = committedTier == candidateTier and candidateChunks
        or select(1, EntityStreamerService.selectTierChunksForTier(currentChunk, facingChunk, committedTier))

    local oldActiveChunks = playerData.activeChunks

    -- Chunks to load: in the new set, not already active.
    local chunksToLoad = {}
    for _, chunk in ipairs(newActiveChunks) do
        local alreadyActive = false
        for _, oldChunk in ipairs(oldActiveChunks) do
            if oldChunk == chunk then alreadyActive = true break end
        end
        if not alreadyActive then table.insert(chunksToLoad, chunk) end
    end

    -- Chunks to unload: in the old set, not in the new set, AND the player
    -- is more than 15 units past that chunk's boundary (boundary hysteresis).
    local chunksToUnload = {}
    for _, oldChunk in ipairs(oldActiveChunks) do
        local stillActive = false
        for _, chunk in ipairs(newActiveChunks) do
            if chunk == oldChunk then stillActive = true break end
        end
        if not stillActive and EntityStreamerService.distancePastBoundary(x, y, oldChunk) > 15 then
            table.insert(chunksToUnload, oldChunk)
        end
    end

    for _, chunk in ipairs(chunksToLoad) do
        EntityStreamerService.chunkPlayerRefs[chunk] = (EntityStreamerService.chunkPlayerRefs[chunk] or 0) + 1
        if EntityStreamerService.chunkPlayerRefs[chunk] == 1 then
            EntityStreamerService.globalSpawnedCount = EntityStreamerService.globalSpawnedCount +
                EntityStreamerService.countBudgetEntitiesInChunk(chunk)
        end
        EntityStreamerService.loadChunkForPlayer(source, chunk)
    end

    for _, chunk in ipairs(chunksToUnload) do
        EntityStreamerService.chunkPlayerRefs[chunk] = math.max((EntityStreamerService.chunkPlayerRefs[chunk] or 1) - 1, 0)
        if EntityStreamerService.chunkPlayerRefs[chunk] == 0 then
            EntityStreamerService.globalSpawnedCount = math.max(EntityStreamerService.globalSpawnedCount -
                EntityStreamerService.countBudgetEntitiesInChunk(chunk), 0)
        end
        EntityStreamerService.unloadChunkForPlayer(source, chunk)
    end

    -- Rebuild the active set: kept-old (not unloaded) + newly loaded.
    local rebuiltActive = {}
    for _, oldChunk in ipairs(oldActiveChunks) do
        local wasUnloaded = false
        for _, unloaded in ipairs(chunksToUnload) do
            if unloaded == oldChunk then wasUnloaded = true break end
        end
        if not wasUnloaded then table.insert(rebuiltActive, oldChunk) end
    end
    for _, chunk in ipairs(chunksToLoad) do table.insert(rebuiltActive, chunk) end

    playerData.currentChunk = currentChunk
    playerData.activeChunks = rebuiltActive
end

--- Re-derive the chunk list for an already-committed tier, without
--- re-running budget projection (used only when the committed tier
--- differs from this tick's freshly-selected candidate tier).
--- @param currentChunk string
--- @param facingChunk string
--- @param tier number
--- @return string[]
function EntityStreamerService.selectTierChunksForTier(currentChunk, facingChunk, tier)
    if tier == 1 then return EntityStreamerService.getSurroundingChunks(currentChunk, 1) end
    if tier == 2 then return { currentChunk, facingChunk } end
    return { currentChunk }
end
```

- [ ] **Step 5: Update the two call sites that invoke `updatePlayerChunks`**

`core/server/Services/EntityStreamerService.lua`'s `Obelisk.onServer('core:client:streamer-updatePosition', ...)` handler currently reads:
```lua
Obelisk.onServer('core:client:streamer-updatePosition', function(x, y)
    local source = source
    EntityStreamerService.updatePlayerChunks(source, x, y)
end)
```
This is fully replaced by Task 4 (which adds facing-chunk computation server-side) — leave it as-is for this task; Task 4 updates it. For THIS task's own manual sanity check only, you may temporarily pass a placeholder facing chunk (e.g. `EntityStreamerService.getChunkKey(x, y)`, same as current) when running anything outside the unit tests — the real facing-chunk wiring is Task 4's job, not this one's.

- [ ] **Step 6: Run tests to verify they pass**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: `All tests passed`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add core/server/Services/EntityStreamerService.lua tests/entity_streamer_service_spec.lua
git commit -m "Add chunk-boundary and tier-change hysteresis"
```

---

## Task 4: Server-side facing chunk, look-ahead chunk, and precache push

**Files:**
- Modify: `core/server/Services/EntityStreamerService.lua` (facing/lookahead chunk math, precache push, the `streamer-updatePosition` handler)
- Test: `core/tests/entity_streamer_service_spec.lua`

**Interfaces:**
- Produces:
  - `EntityStreamerService.getOffsetChunk(chunkKey, heading) -> string` — the chunk one step away from `chunkKey` in the direction `heading` points (0-360°, standard FiveM heading convention: 0 = north/+Y, 90 = west, etc. — matches `GetEntityHeading`'s convention, +X/+Y quadrant math derived from `math.sin`/`math.cos` of the heading in radians).
  - `EntityStreamerService.getPrecacheChunk(currentChunk, heading) -> facingChunk, lookaheadChunk` — `facingChunk = getOffsetChunk(currentChunk, heading)`, `lookaheadChunk = getOffsetChunk(facingChunk, heading)`.
  - `EntityStreamerService.getChunkEntityRecords(chunkKey) -> table[]` — resolves a chunk's raw `{entityType: {entityId: true}}` index into a flat array of `{entityId, entityType, data}` records, the same shape the existing `core:server:streamer-entityAdd` event already sends.
  - The `core:client:streamer-updatePosition` handler now reads `(x, y, heading)` from the client (heading added), computes `facingChunk`/`lookaheadChunk`, calls `updatePlayerChunks(source, x, y, facingChunk)` (wiring Task 3's parameter), then pushes a precache event: `Obelisk.emitClient('core:server:streamer-precache', source, { entities = EntityStreamerService.getChunkEntityRecords(lookaheadChunk), chunkKey = lookaheadChunk })`.
- Consumes: `EntityStreamerService.updatePlayerChunks` (Task 3, now takes a `facingChunk` param), `EntityStreamerService.getChunkEntities` (existing).

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/entity_streamer_service_spec.lua`:
```lua
test('getOffsetChunk moves one chunk north (heading 0) when facing north', function()
    local Streamer = freshService({ entities = {} })
    -- heading 0 = facing +Y (north) in FiveM's convention
    eq(Streamer.getOffsetChunk('0_0', 0.0), '0_1')
end)

test('getOffsetChunk moves one chunk east (heading 270) when facing east', function()
    local Streamer = freshService({ entities = {} })
    eq(Streamer.getOffsetChunk('0_0', 270.0), '1_0')
end)

test('getPrecacheChunk returns facing and lookahead two chunks apart in the same direction', function()
    local Streamer = freshService({ entities = {} })
    local facing, lookahead = Streamer.getPrecacheChunk('0_0', 0.0)
    eq(facing, '0_1')
    eq(lookahead, '0_2')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: FAIL — `getOffsetChunk`/`getPrecacheChunk` don't exist.

- [ ] **Step 3: Implement the chunk-offset math**

Add near `getChunkBounds`/`distancePastBoundary`:
```lua
--- The chunk one step away from chunkKey in the direction `heading` points.
--- FiveM heading convention: 0 = north (+Y), 90 = west (-X), 180 = south
--- (-Y), 270 = east (+X).
--- @param chunkKey string
--- @param heading number degrees, 0-360
--- @return string
function EntityStreamerService.getOffsetChunk(chunkKey, heading)
    local chunkX, chunkY = chunkKey:match('(-?%d+)_(-?%d+)')
    chunkX, chunkY = tonumber(chunkX), tonumber(chunkY)

    local rad = math.rad(heading)
    local dx = -math.sin(rad)
    local dy = math.cos(rad)

    local offsetX = dx > 0.5 and 1 or (dx < -0.5 and -1 or 0)
    local offsetY = dy > 0.5 and 1 or (dy < -0.5 and -1 or 0)

    return (chunkX + offsetX) .. '_' .. (chunkY + offsetY)
end

--- The facing chunk (one step from currentChunk toward heading) and the
--- look-ahead chunk (one further step past that, same direction).
--- @param currentChunk string
--- @param heading number
--- @return string facingChunk, string lookaheadChunk
function EntityStreamerService.getPrecacheChunk(currentChunk, heading)
    local facingChunk = EntityStreamerService.getOffsetChunk(currentChunk, heading)
    local lookaheadChunk = EntityStreamerService.getOffsetChunk(facingChunk, heading)
    return facingChunk, lookaheadChunk
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: `All tests passed`, exit 0.

- [ ] **Step 5: Wire the `streamer-updatePosition` handler**

Add a helper that resolves a chunk's raw index (`{entityType: {entityId: true}}`, `getChunkEntities`'s existing return shape) into a flat array of full entity records — the same `{entityId, entityType, data}` shape the existing `core:server:streamer-entityAdd` event already sends, so the client's precache handler (Task 7) can reuse that shape directly instead of learning a second one:
```lua
--- Resolve a chunk's raw entity-id index into a flat array of full entity
--- records, the same {entityId, entityType, data} shape entityAdd already
--- sends — so precache payloads and real spawn payloads share one shape.
--- @param chunkKey string
--- @return table[]
function EntityStreamerService.getChunkEntityRecords(chunkKey)
    local records = {}
    for entityType, entityIds in pairs(EntityStreamerService.getChunkEntities(chunkKey)) do
        for entityId, _ in pairs(entityIds) do
            local entityData = EntityStreamerService.entities[entityType][entityId]
            if entityData then
                table.insert(records, { entityId = entityId, entityType = entityType, data = entityData })
            end
        end
    end
    return records
end
```

Replace the existing handler (currently near the bottom of the file):
```lua
Obelisk.onServer('core:client:streamer-updatePosition', function(x, y, heading)
    local source = source
    local currentChunk = EntityStreamerService.getChunkKey(x, y)
    local facingChunk, lookaheadChunk = EntityStreamerService.getPrecacheChunk(currentChunk, heading or 0.0)

    EntityStreamerService.updatePlayerChunks(source, x, y, facingChunk)

    Obelisk.emitClient('core:server:streamer-precache', source, {
        chunkKey = lookaheadChunk,
        entities = EntityStreamerService.getChunkEntityRecords(lookaheadChunk),
    })
end)
```
This is not unit-testable in isolation (it's a live `Obelisk.onServer` handler) — its correctness is covered by the fact that every function it calls (`getChunkKey`, `getPrecacheChunk`, `updatePlayerChunks`, `getChunkEntityRecords`) is already unit-tested (or, for `getChunkEntityRecords`, trivially composes two already-tested functions), and by this task's manual verification pass (Task 8).

- [ ] **Step 6: Write the failing test for `getChunkEntityRecords`**

Append to `core/tests/entity_streamer_service_spec.lua`:
```lua
test('getChunkEntityRecords resolves a chunk index into full entity records', function()
    local Streamer = freshService({ entities = {} })
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, model = 'prop_box' })
    local chunkKey = Streamer.getChunkKey(10, 10)

    local records = Streamer.getChunkEntityRecords(chunkKey)

    eq(#records, 1)
    eq(records[1].entityId, id)
    eq(records[1].entityType, 'object')
    eq(records[1].data.x, 10)
end)
```

- [ ] **Step 7: Run all tests to verify they pass**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: `All tests passed`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add core/server/Services/EntityStreamerService.lua tests/entity_streamer_service_spec.lua
git commit -m "Add facing/look-ahead chunk math and server-side precache push"
```

---

## Task 5: Networked-entity spawn-once ownership

**Files:**
- Modify: `core/server/Services/EntityStreamerService.lua` (`register`, `loadChunkForPlayer`, `playerDropped` handler)
- Test: `core/tests/entity_streamer_service_spec.lua`

**Interfaces:**
- Produces:
  - `EntityStreamerService.networkedOwners` — `{entityId: source}`, tracks which player's client is responsible for creating a given networked entity.
  - `EntityStreamerService.register(entityType, entityData)` — unchanged signature, but now stores `entityData.networked` (defaulting to `false`) on the entity record.
  - `EntityStreamerService.loadChunkForPlayer(source, chunkKey)` — for a `networked = true` entity, only emits the spawn instruction to the FIRST player whose load claims it (`networkedOwners[entityId] == nil`), setting `networkedOwners[entityId] = source`; every subsequent player who loads that chunk does NOT get a spawn instruction for that entity (relies on OneSync to replicate it to them). `networked = false` (or unset) entities are unaffected — every loader gets the spawn instruction, exactly as today.
  - `playerDropped` handler (existing) also clears any `networkedOwners` entries owned by the disconnecting player, so a future loader can become the new owner.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/entity_streamer_service_spec.lua`:
```lua
test('register stores the networked flag, defaulting to false', function()
    local Streamer = freshService({ entities = {} })
    local id1 = Streamer.register('object', { x = 10, y = 10, z = 0 })
    local id2 = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    eq(Streamer.entities.object[id1].networked, false)
    eq(Streamer.entities.object[id2].networked, true)
end)

test('loadChunkForPlayer sends a networked entity to only the first player who loads its chunk', function()
    local Streamer = freshService({ entities = {} })
    local sentTo = {}
    Obelisk = { emitClient = function(eventName, source, data) table.insert(sentTo, source) end }
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    local chunkKey = Streamer.getChunkKey(10, 10)

    Streamer.loadChunkForPlayer(1, chunkKey)
    Streamer.loadChunkForPlayer(2, chunkKey)

    eq(#sentTo, 1, 'only one player was told to spawn the networked entity')
    eq(sentTo[1], 1, 'the first loader became the owner')
    eq(Streamer.networkedOwners[id], 1)
end)

test('loadChunkForPlayer still sends a local-only entity to every loader', function()
    local Streamer = freshService({ entities = {} })
    local sentTo = {}
    Obelisk = { emitClient = function(eventName, source, data) table.insert(sentTo, source) end }
    Streamer.register('object', { x = 10, y = 10, z = 0, networked = false })
    local chunkKey = Streamer.getChunkKey(10, 10)

    Streamer.loadChunkForPlayer(1, chunkKey)
    Streamer.loadChunkForPlayer(2, chunkKey)

    eq(#sentTo, 2, 'both players spawn their own local copy')
end)

test('a disconnecting owner frees the networked entity for a future owner', function()
    local Streamer = freshService({ entities = {} })
    local sentTo = {}
    Obelisk = { emitClient = function(eventName, source, data) table.insert(sentTo, source) end }
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    local chunkKey = Streamer.getChunkKey(10, 10)
    Streamer.playerChunks[1] = { currentChunk = chunkKey, activeChunks = {} }

    Streamer.loadChunkForPlayer(1, chunkKey)
    eq(Streamer.networkedOwners[id], 1)

    source = 1
    Streamer.handlePlayerDropped()
    eq(Streamer.networkedOwners[id], nil, 'owner cleared on disconnect')

    Streamer.loadChunkForPlayer(2, chunkKey)
    eq(Streamer.networkedOwners[id], 2, 'a new player can become owner after the old one drops')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: FAIL — `networked` isn't stored, `networkedOwners` doesn't exist, every loader still gets the spawn instruction.

- [ ] **Step 3: Store the `networked` flag in `register`**

In `EntityStreamerService.register` (existing function), the entity record construction currently reads:
```lua
    EntityStreamerService.entities[entityType][entityId] = {
        id = entityId,
        type = entityType,
        x = entityData.x,
        y = entityData.y,
        z = entityData.z,
        data = entityData
    }
```
Add one field:
```lua
    EntityStreamerService.entities[entityType][entityId] = {
        id = entityId,
        type = entityType,
        x = entityData.x,
        y = entityData.y,
        z = entityData.z,
        networked = entityData.networked or false,
        data = entityData
    }
```

- [ ] **Step 4: Add `networkedOwners` state and extract `handlePlayerDropped`**

Add near the other module-level state declarations (with Task 2/3's additions):
```lua
EntityStreamerService.networkedOwners = {} -- {entityId: source}, who owns a networked entity
```

The existing `playerDropped` handler is currently:
```lua
--- Clean up player data on disconnect
AddEventHandler('playerDropped', function()
    local source = source
    EntityStreamerService.playerChunks[source] = nil
end)
```
Refactor into a named function (so it's callable from tests without a real FiveM event) plus a thin event registration:
```lua
--- Clean up player data on disconnect: their chunk tracking, and release
--- ownership of any networked entities they were responsible for.
function EntityStreamerService.handlePlayerDropped()
    local source = source
    EntityStreamerService.playerChunks[source] = nil

    for entityId, ownerSource in pairs(EntityStreamerService.networkedOwners) do
        if ownerSource == source then
            EntityStreamerService.networkedOwners[entityId] = nil
        end
    end
end

AddEventHandler('playerDropped', EntityStreamerService.handlePlayerDropped)
```

- [ ] **Step 5: Gate networked entities in `loadChunkForPlayer`**

Replace the existing `loadChunkForPlayer` function:
```lua
--- Load a chunk for a player. Local-only entities are sent to every
--- player who loads the chunk; networked entities are sent only to
--- whichever player becomes their owner (first loader), relying on
--- OneSync to replicate the resulting networked game entity to everyone
--- else nearby.
--- @param source number
--- @param chunkKey string
function EntityStreamerService.loadChunkForPlayer(source, chunkKey)
    local chunk = EntityStreamerService.chunks[chunkKey]

    if not chunk then return end

    for entityType, entities in pairs(chunk) do
        for entityId, _ in pairs(entities) do
            local entityData = EntityStreamerService.entities[entityType][entityId]

            if entityData then
                local shouldSend = true
                if entityData.networked then
                    if EntityStreamerService.networkedOwners[entityId] then
                        shouldSend = false
                    else
                        EntityStreamerService.networkedOwners[entityId] = source
                    end
                end

                if shouldSend then
                    Obelisk.emitClient('core:server:streamer-entityAdd', source, {
                        entityId = entityId,
                        entityType = entityType,
                        data = entityData
                    })
                end
            end
        end
    end
end
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
lua5.4 tests/entity_streamer_service_spec.lua
```
Expected: `All tests passed`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add core/server/Services/EntityStreamerService.lua tests/entity_streamer_service_spec.lua
git commit -m "Add spawn-once ownership for networked entities"
```

---

## Task 6: Client-side facing-chunk heading (camera, debounced) in the position tick

**Files:**
- Modify: `core/client/Services/EntityStreamerService.lua` (position-update thread)

**Interfaces:**
- Produces: the existing position-update `Citizen.CreateThread` now also reads `GetGameplayCamRelativeHeading() + GetEntityHeading(playerPed)` (normalized to 0-360), and only recomputes/sends a new heading value when it differs from the last-sent heading by more than 20°. `Obelisk.emitServer('core:client:streamer-updatePosition', coords.x, coords.y, heading)` — third argument added, matching Task 4's server handler.
- Consumes: nothing new (natives only). No unit test — this is pure native-call glue, unverifiable outside FiveM, matching this repo's established convention for client-side code.

- [ ] **Step 1: Replace the position-update thread**

`core/client/Services/EntityStreamerService.lua` currently has:
```lua
--- Update player position to server
Citizen.CreateThread(function()
    while true do
        Wait(EntityStreamerService.updateInterval)
        
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)
        
        -- Send position to server for chunk management
        Obelisk.emitServer('core:client:streamer-updatePosition', coords.x, coords.y)
    end
end)
```
Replace it with:
```lua
--- Track the last heading value actually sent, so small camera jitter
--- doesn't recompute/resend the facing chunk every tick.
EntityStreamerService.lastSentHeading = 0.0

--- Normalize a heading to the 0-360 range.
--- @param heading number
--- @return number
local function normalizeHeading(heading)
    heading = heading % 360.0
    if heading < 0 then heading = heading + 360.0 end
    return heading
end

--- Update player position (and facing heading) to server
Citizen.CreateThread(function()
    while true do
        Wait(EntityStreamerService.updateInterval)

        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)

        local heading = normalizeHeading(GetEntityHeading(playerPed) + GetGameplayCamRelativeHeading())

        local delta = math.abs(heading - EntityStreamerService.lastSentHeading)
        if delta > 180.0 then delta = 360.0 - delta end
        if delta > 20.0 then
            EntityStreamerService.lastSentHeading = heading
        end

        -- Send position + the last-committed facing heading to the server
        -- for chunk management (heading only updates when it moved > 20°,
        -- position is sent every tick regardless).
        Obelisk.emitServer('core:client:streamer-updatePosition', coords.x, coords.y, EntityStreamerService.lastSentHeading)
    end
end)
```

- [ ] **Step 2: Manual syntax check**

```bash
lua5.4 -e "local f = loadfile('core/client/Services/EntityStreamerService.lua'); assert(f, 'syntax error')"
```
Expected: no error (this only checks the file parses — it can't execute, since it calls FiveM natives that don't exist outside the game).

- [ ] **Step 3: Commit**

```bash
git add core/client/Services/EntityStreamerService.lua
git commit -m "Send camera-heading-derived facing direction, debounced, in the position tick"
```

---

## Task 7: Client-side precache handling and tier-aware despawn

**Files:**
- Modify: `core/client/Services/EntityStreamerService.lua` (add the precache event handler)

**Interfaces:**
- Produces: a new `Obelisk.onClient('core:server:streamer-precache', ...)` handler that calls `RequestModel` for every entity in the pushed look-ahead chunk WITHOUT spawning them (no `CreatePed`/`CreateObject` call) — just primes the streaming system so the model is already resident when the player's real chunk membership later includes that chunk and a real `core:server:streamer-entityAdd` arrives.
- Consumes: nothing new. Existing `core:server:streamer-entityAdd`/`-entityRemove` handlers (unchanged) already handle the actual spawn/despawn once a chunk becomes genuinely active — Task 3's server-side hysteresis and tier logic drive those exactly as before, no client-side change needed for the despawn path itself (it already despawns whatever the server tells it to, and Tasks 2-3 already changed what the server tells it, not how the client reacts).

- [ ] **Step 1: Add the precache handler**

In `core/client/Services/EntityStreamerService.lua`, add near the existing `Obelisk.onClient('core:server:streamer-entityAdd', ...)`/`-entityRemove` handlers:
```lua
--- Precache: pre-request models for entities in the look-ahead chunk
--- (one step past the facing chunk) without spawning them, so when the
--- player's real chunk membership later includes it, spawning is just
--- CreatePed/CreateObject against an already-loaded model instead of
--- waiting on RequestModel's up-to-5-second stream-in.
EntityStreamerService.precachedModels = {} -- {modelHash: true}, avoids redundant RequestModel calls

Obelisk.onClient('core:server:streamer-precache', function(data)
    for _, entity in ipairs(data.entities or {}) do
        local entityData = entity.data
        if entityData and entityData.model then
            local modelHash = GetHashKey(entityData.model)
            if not EntityStreamerService.precachedModels[modelHash] then
                EntityStreamerService.precachedModels[modelHash] = true
                RequestModel(modelHash)
            end
        end
    end
end)
```
`data.entities` is Task 4's `EntityStreamerService.getChunkEntityRecords(lookaheadChunk)` result — an array of `{entityId, entityType, data}` records (the same shape the existing `core:server:streamer-entityAdd` event already sends), not the raw `{entityType: {entityId: true}}` chunk index. Each record's `data` is the full entity table (`x`/`y`/`z`/`model`/etc.), so `entity.data.model` is always the right accessor.

- [ ] **Step 2: Manual syntax check**

```bash
lua5.4 -e "local f = loadfile('core/client/Services/EntityStreamerService.lua'); assert(f, 'syntax error')"
```
Expected: no error.

- [ ] **Step 3: Commit**

```bash
git add core/client/Services/EntityStreamerService.lua core/server/Services/EntityStreamerService.lua
git commit -m "Precache look-ahead chunk models on the client without spawning"
```

---

## Task 8: Manual verification (live server, not a test file)

This task has no automated tests — it verifies the end-to-end behavior of Tasks 1-7 against a real FiveM server, which this repo's test suite cannot do (no live game client, no live database in CI).

- [ ] **Step 1: Run the migration against a real dev database**

Start the dev stack (`docker compose up -d`), run the framework's migration runner, confirm the `entities` table is created with the expected columns (`\d entities` on Postgres, `DESCRIBE entities` on MySQL/MariaDB).

- [ ] **Step 2: Seed a handful of test entities spanning multiple chunks**

Via the framework's admin tooling or a one-off script, `Entity:create({...})` at least 12-15 ped/object entities spread across more than 9 chunks (some clustered near a chunk boundary, at least one path where two chunks in a straight line from a spawn point can be used to test facing/lookahead).

- [ ] **Step 3: Confirm tier degradation**

Temporarily set `EntityStreamerService.entityBudget` very low (e.g. `2`) via a server console command or a direct edit, join with a character standing where several ped/object entities are nearby, confirm only the current chunk's entities spawn (tier 3) rather than the full 3×3 grid. Restore the budget to `300` and confirm the wider grid spawns once the tier hysteresis's 2-tick window passes.

- [ ] **Step 4: Confirm boundary hysteresis**

Stand near a chunk boundary between two chunks, one of which has entities the other doesn't. Walk back and forth across the boundary in small steps (well under 15 units each way) and confirm entities do NOT flicker spawn/despawn. Walk fully across (more than 15 units past) and confirm the far chunk's entities correctly despawn.

- [ ] **Step 5: Confirm look-ahead precache**

With a `print`/log statement temporarily added to the client's precache handler (or FiveM's dev console model-request logging), walk toward a chunk with entities and confirm `RequestModel` calls for that chunk's entities are logged BEFORE the player's actual chunk membership includes it — i.e., before any `core:server:streamer-entityAdd` for those entities arrives.

- [ ] **Step 6: Confirm networked vs. local-only spawning**

Register one entity with `networked = true` and one with `networked = false` in the same chunk (via `Entity:create`), have two characters both enter that chunk (two game clients, or one + a spectator/second session if available), confirm the local-only entity visibly exists independently for both (two separate handles, checkable via each client's own `EntityStreamerService.entities` table having its own entry), and the networked one exists once and is visible to both via normal FiveM/OneSync replication (not two separately-created handles).

- [ ] **Step 7: Record the outcome**

No commit needed for this task (nothing in the repo changes) — note in the plan's tracking (or PR description, if this work goes through one) that manual verification was performed and what was observed, especially any deviation from expected behavior that surfaced only at runtime.
