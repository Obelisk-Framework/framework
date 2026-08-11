--- Unit tests for the server-side EntityStreamerService.
--- Run from the repository root:  lua5.4 tests/entity_streamer_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

-- EntityStreamerService.lua registers net event handlers via Obelisk.onServer
-- and broadcasts via Obelisk.emitClient at module load time (and from
-- register(), which init() calls immediately via Citizen.CreateThread's
-- synchronous stub -- see fivem_stubs.lua). A minimal stub is enough since
-- these tests never assert on network traffic.
_G.Obelisk = _G.Obelisk or { onServer = function() end, emitClient = function() end }

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
    _G.QueryBuilder = makeFakeQueryBuilderModule(tables or {})
    dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
    dofile(ROOT .. '/core/server/Models/Entity.lua')
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

    -- register() mints its own runtime entityId (entityType_timestamp_rand),
    -- not the DB row id, so look up the registered ped by its coordinates
    -- rather than assuming the id round-trips.
    local foundPed = false
    for _, entity in pairs(Streamer.entities.ped) do
        if entity.x == 10.0 and entity.y == 20.0 then foundPed = true end
    end
    eq(foundPed, true, 'ped from row #1 registered')
    local chunk1 = Streamer.getChunkKey(10.0, 20.0)
    local chunk2 = Streamer.getChunkKey(110.0, 20.0)
    eq(Streamer.chunks[chunk1] ~= nil and Streamer.chunks[chunk1].ped ~= nil, true, 'chunk1 has a ped')
    eq(Streamer.chunks[chunk2] ~= nil and Streamer.chunks[chunk2].object ~= nil, true, 'chunk2 has an object')

    local disabledChunk = Streamer.getChunkKey(999.0, 999.0)
    eq(Streamer.chunks[disabledChunk], nil, 'disabled entity #3 never registered')
end)

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
    -- force tier 3 (current chunk only) throughout via a tiny budget and a
    -- heavy neighbor chunk, so a chunk actually leaving the (single-chunk)
    -- active set is reachable, and boundary hysteresis on that transition
    -- is what's under test
    Streamer.entityBudget = 1
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['1_0'] = { ped = heavy }

    Streamer.updatePlayerChunks(1, 50.0, 50.0, '1_0')
    local firstActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do firstActive[c] = true end
    eq(firstActive['0_0'], true, 'starts with 0_0 active')
    eq(#Streamer.playerChunks[1].activeChunks, 1, 'tier 3 forced by the tiny budget')

    -- move 5 units past the x=100 boundary into chunk 1_0 -- within the
    -- 15-unit margin, so 0_0 must still be active
    Streamer.updatePlayerChunks(1, 105.0, 50.0, '2_0')
    local stillActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do stillActive[c] = true end
    eq(stillActive['0_0'], true, '0_0 stays active within the 15-unit margin')

    -- move 20 units past the boundary -- now it should unload
    Streamer.updatePlayerChunks(1, 120.0, 50.0, '2_0')
    local laterActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do laterActive[c] = true end
    eq(laterActive['0_0'], nil, '0_0 unloads once 20 units past the boundary')
end)

test('updatePlayerChunks only changes tier after 2 consecutive ticks agree', function()
    local Streamer = freshService({ entities = {} })
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['3_0'] = { ped = heavy }

    Streamer.entityBudget = 100000
    Streamer.updatePlayerChunks(1, 50.0, 50.0, '0_0')
    eq(#Streamer.playerChunks[1].activeChunks, 9, 'starts at tier 1 (9 chunks)')

    -- move near the heavy chunk with a budget too small to afford it -- should
    -- NOT downgrade to tier 3 on the first tick
    Streamer.entityBudget = 5
    Streamer.updatePlayerChunks(1, 250.0, 50.0, '3_0')
    eq(#Streamer.playerChunks[1].activeChunks, 9, 'a single spike does not downgrade the tier')

    -- second consecutive tick agreeing -- now it flips
    Streamer.updatePlayerChunks(1, 250.0, 50.0, '3_0')
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

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
