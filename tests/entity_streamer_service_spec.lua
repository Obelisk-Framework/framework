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
-- A spy that records emitClient calls, so group-entity broadcast tests can
-- assert on them. Existing tests never inspect these calls, so this is a
-- behavior-preserving upgrade, not a breaking change.
local emitClientCalls = {}
_G.Obelisk = _G.Obelisk or {
    on = function(eventName, callback) AddEventHandler(eventName, callback) end,
    onServer = function() end,
    emitClient = function(eventName, target, data)
        table.insert(emitClientCalls, { eventName = eventName, target = target, data = data })
    end,
}

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

    -- The runtime entityId is keyed off the DB row id, so it round-trips.
    eq(Streamer.entities.ped['ped_1'] ~= nil, true, 'ped from row #1 registered under its row id')
    eq(Streamer.entities.ped['ped_1'].x, 10.0)
    eq(Streamer.entities.ped['ped_1'].model, 'a_m_y_business_01', 'model is flat on the record')
    eq(Streamer.entities.object['object_2'] ~= nil, true, 'object from row #2 registered under its row id')
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

test('getChunkEntityRecords resolves a chunk index into full entity records', function()
    local Streamer = freshService({ entities = {} })
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, model = 'prop_box' })
    local chunkKey = Streamer.getChunkKey(10, 10)

    local records = Streamer.getChunkEntityRecords(chunkKey)

    eq(#records, 1)
    eq(records[1].entityId, id)
    eq(records[1].entityType, 'object')
    eq(records[1].data.x, 10)
    -- The client reads entity.data.model straight off this payload (both for
    -- precache's RequestModel and for the real spawnObject path), so `model`
    -- has to be flat on the record rather than nested one level deeper.
    eq(records[1].data.model, 'prop_box', 'model resolves at data.model, not data.data.model')
end)

test('register flattens ped fields (heading/scenario) onto the entity record', function()
    local Streamer = freshService({ entities = {} })
    local id = Streamer.register('ped', {
        x = 10, y = 10, z = 0, model = 'a_m_y_business_01',
        heading = 90.0, data = { scenario = 'WORLD_HUMAN_CLIPBOARD', freeze = true },
    })

    local entity = Streamer.entities.ped[id]
    eq(entity.model, 'a_m_y_business_01')
    eq(entity.heading, 90.0)
    -- scenario/freeze live in the DB's json `data` column; they must be spread
    -- onto the same record so the client's spawnPed(data) reads them directly.
    eq(entity.scenario, 'WORLD_HUMAN_CLIPBOARD')
    eq(entity.freeze, true)

    local records = Streamer.getChunkEntityRecords(Streamer.getChunkKey(10, 10))
    eq(records[1].data.heading, 90.0)
    eq(records[1].data.scenario, 'WORLD_HUMAN_CLIPBOARD')
end)

test('init() gives two DB rows registered in the same tick distinct entity ids', function()
    local tables = {
        entities = {
            { id = 41, entity_type = 'ped', model = 'a_m_y_business_01', x = 10.0, y = 20.0, z = 30.0,
              heading = 0.0, networked = false, enabled = true },
            { id = 42, entity_type = 'ped', model = 'a_m_y_business_02', x = 11.0, y = 21.0, z = 30.0,
              heading = 0.0, networked = false, enabled = true },
        }
    }
    local Streamer = freshService(tables)
    Streamer.init()

    local count = 0
    for _ in pairs(Streamer.entities.ped) do count = count + 1 end
    eq(count, 2, 'two rows registered in one tick produce two records, never a collision')
    eq(Streamer.entities.ped['ped_41'].model, 'a_m_y_business_01')
    eq(Streamer.entities.ped['ped_42'].model, 'a_m_y_business_02')
end)

test('getOffsetChunk never returns its own input chunk key, across a spread of headings', function()
    local Streamer = freshService({ entities = {} })
    -- dx = -sin(heading), dy = cos(heading); dx^2 + dy^2 = 1 always, so at
    -- least one axis magnitude is >= 1/sqrt(2) (~0.707) and clears the 0.5
    -- threshold that picks a direction -- getOffsetChunk can never return
    -- its own input. This is what makes tier2's { currentChunk, facingChunk }
    -- (selectTier, Task 2) safe from double-loading without dedup logic,
    -- since facingChunk always comes from getOffsetChunk.
    local headings = { 0, 45, 90, 135, 180, 225, 270, 315 }
    for _, heading in ipairs(headings) do
        local offset = Streamer.getOffsetChunk('0_0', heading)
        if offset == '0_0' then
            error('getOffsetChunk(\'0_0\', ' .. heading .. ') returned its own input chunk')
        end
    end
end)

test('register stores the networked flag, defaulting to false', function()
    local Streamer = freshService({ entities = {} })
    local id1 = Streamer.register('object', { x = 10, y = 10, z = 0 })
    local id2 = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    eq(Streamer.entities.object[id1].networked, false)
    eq(Streamer.entities.object[id2].networked, true)
end)

test('loadChunkForPlayer sends a networked entity to only the first player who loads its chunk', function()
    local Streamer = freshService({ entities = {} })
    local savedObelisk = _G.Obelisk
    local sentTo = {}
    Obelisk = { emitClient = function(eventName, source, data) table.insert(sentTo, source) end }
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    local chunkKey = Streamer.getChunkKey(10, 10)

    Streamer.loadChunkForPlayer(1, chunkKey)
    Streamer.loadChunkForPlayer(2, chunkKey)

    eq(#sentTo, 1, 'only one player was told to spawn the networked entity')
    eq(sentTo[1], 1, 'the first loader became the owner')
    eq(Streamer.networkedOwners[id], 1)
    _G.Obelisk = savedObelisk
end)

test('loadChunkForPlayer still sends a local-only entity to every loader', function()
    local Streamer = freshService({ entities = {} })
    local savedObelisk = _G.Obelisk
    local sentTo = {}
    Obelisk = { emitClient = function(eventName, source, data) table.insert(sentTo, source) end }
    Streamer.register('object', { x = 10, y = 10, z = 0, networked = false })
    local chunkKey = Streamer.getChunkKey(10, 10)

    Streamer.loadChunkForPlayer(1, chunkKey)
    Streamer.loadChunkForPlayer(2, chunkKey)

    eq(#sentTo, 2, 'both players spawn their own local copy')
    _G.Obelisk = savedObelisk
end)

test('a disconnecting owner frees the networked entity for a future owner', function()
    local Streamer = freshService({ entities = {} })
    local savedObelisk = _G.Obelisk
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
    _G.Obelisk = savedObelisk
end)

test('unloading a chunk frees the networked entity for whoever loads it next', function()
    local Streamer = freshService({ entities = {} })
    local savedObelisk = _G.Obelisk
    local sentTo = {}
    Obelisk = { emitClient = function(eventName, source, data)
        if eventName == 'core:server:streamer-entityAdd' then table.insert(sentTo, source) end
    end }
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    local chunkKey = Streamer.getChunkKey(10, 10)

    Streamer.loadChunkForPlayer(1, chunkKey)
    eq(Streamer.networkedOwners[id], 1, 'player 1 owns it after loading')

    -- An ordinary chunk-boundary unload (not a disconnect): player 1's client
    -- deletes the entity, so the ownership claim must be released too.
    Streamer.unloadChunkForPlayer(1, chunkKey)
    eq(Streamer.networkedOwners[id], nil, 'ownership released on ordinary unload')

    Streamer.loadChunkForPlayer(2, chunkKey)
    eq(Streamer.networkedOwners[id], 2, 'player 2 becomes the new owner')
    eq(sentTo[#sentTo], 2, 'player 2 was told to spawn it')
    _G.Obelisk = savedObelisk
end)

test('unloading a chunk does not steal ownership held by a different player', function()
    local Streamer = freshService({ entities = {} })
    local savedObelisk = _G.Obelisk
    Obelisk = { emitClient = function() end }
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    local chunkKey = Streamer.getChunkKey(10, 10)

    Streamer.loadChunkForPlayer(1, chunkKey)
    Streamer.unloadChunkForPlayer(2, chunkKey)
    eq(Streamer.networkedOwners[id], 1, 'a non-owner unloading leaves the owner intact')
    _G.Obelisk = savedObelisk
end)

test('handlePlayerDropped releases the chunk refs and budget the player held', function()
    local Streamer = freshService({ entities = {} })
    Streamer.entityBudget = 100000
    -- put budget-countable entities in a few of the 9 tier-1 chunks
    Streamer.chunks['0_0'] = { ped = { a = true, b = true } }
    Streamer.chunks['1_0'] = { object = { c = true } }
    Streamer.chunks['-1_-1'] = { pickup = { d = true } }

    Streamer.updatePlayerChunks(1, 50.0, 50.0, '1_0')
    local activeChunks = Streamer.playerChunks[1].activeChunks
    eq(#activeChunks, 9, 'player reached tier 1')
    eq(Streamer.globalSpawnedCount, 4, '2 peds + 1 object + 1 pickup counted')
    for _, chunkKey in ipairs(activeChunks) do
        eq(Streamer.chunkPlayerRefs[chunkKey], 1, 'ref held for ' .. chunkKey)
    end

    local held = {}
    for _, chunkKey in ipairs(activeChunks) do table.insert(held, chunkKey) end

    source = 1
    Streamer.handlePlayerDropped()

    eq(Streamer.globalSpawnedCount, 0, 'budget fully returned on disconnect')
    for _, chunkKey in ipairs(held) do
        eq(Streamer.chunkPlayerRefs[chunkKey] or 0, 0, 'ref released for ' .. chunkKey)
    end
end)

test('registerGroupEntity stores a flattened record retrievable via getGroupEntityRecords', function()
    emitClientCalls = {}
    local service = freshService()
    local entityId = service.registerGroupEntity('shellbuilder:shell:1', 'object', {
        id = 42, x = 1.0, y = 2.0, z = 3.0, heading = 90.0, model = 'prop_sofa_01', networked = false,
    })
    local records = service.getGroupEntityRecords('shellbuilder:shell:1')
    eq(#records, 1)
    eq(records[1].entityId, entityId)
    eq(records[1].entityType, 'object')
    eq(records[1].data.model, 'prop_sofa_01')
    eq(records[1].data.x, 1.0)
end)

test('registerGroupEntity broadcasts entityAdd to every target source', function()
    emitClientCalls = {}
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'prop_sofa_01' }, { 7, 9 })
    eq(#emitClientCalls, 2)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityAdd')
    eq(emitClientCalls[1].target, 7)
    eq(emitClientCalls[2].target, 9)
end)

test('registerGroupEntity with no targetSources broadcasts nothing', function()
    emitClientCalls = {}
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'prop_sofa_01' })
    eq(#emitClientCalls, 0)
end)

test('different groupKeys keep entirely separate entity lists', function()
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    service.registerGroupEntity('shellbuilder:shell:2', 'object', { id = 43, x = 1.0, y = 2.0, z = 3.0, model = 'b' })
    eq(#service.getGroupEntityRecords('shellbuilder:shell:1'), 1)
    eq(#service.getGroupEntityRecords('shellbuilder:shell:2'), 1)
end)

test('registerGroupEntity namespaces its entityId with the groupKey so it cannot collide with a chunk entityId', function()
    local service = freshService()
    local entityId = service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    eq(entityId, 'shellbuilder:shell:1:object_42')
end)

test('unregisterGroupEntity removes the record and broadcasts entityRemove', function()
    emitClientCalls = {}
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    emitClientCalls = {}
    -- unregisterGroupEntity takes the BARE id (entityType_id), the same
    -- format ShellObjectService.remove already constructs -- it namespaces
    -- internally to match what registerGroupEntity minted.
    service.unregisterGroupEntity('shellbuilder:shell:1', 'object', 'object_42', { 7 })
    eq(#service.getGroupEntityRecords('shellbuilder:shell:1'), 0)
    eq(#emitClientCalls, 1)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityRemove')
    eq(emitClientCalls[1].target, 7)
    eq(emitClientCalls[1].data.entityId, 'shellbuilder:shell:1:object_42')
end)

test('sendGroupEntitiesTo emits entityAdd for every record in that group to one source', function()
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 43, x = 4.0, y = 5.0, z = 6.0, model = 'b' })
    emitClientCalls = {}
    service.sendGroupEntitiesTo(7, 'shellbuilder:shell:1')
    eq(#emitClientCalls, 2)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityAdd')
    eq(emitClientCalls[1].target, 7)
    eq(emitClientCalls[2].target, 7)
end)

test('despawnGroupEntitiesFor emits entityRemove for every record in the group, to the given source', function()
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 43, x = 4.0, y = 5.0, z = 6.0, model = 'b' })
    emitClientCalls = {}

    service.despawnGroupEntitiesFor(7, 'shellbuilder:shell:1')

    eq(#emitClientCalls, 2)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityRemove')
    eq(emitClientCalls[1].target, 7)
    eq(emitClientCalls[2].eventName, 'core:server:streamer-entityRemove')
    eq(emitClientCalls[2].target, 7)
    -- the group's records still exist -- despawn only tells the client to
    -- remove its local copy, it doesn't mutate server-side group state
    eq(#service.getGroupEntityRecords('shellbuilder:shell:1'), 2)
end)

test('despawnGroupEntitiesFor emits nothing for an empty/unknown group', function()
    local service = freshService()
    emitClientCalls = {}
    service.despawnGroupEntitiesFor(7, 'shellbuilder:shell:does-not-exist')
    eq(#emitClientCalls, 0)
end)

test('init() reloads a persisted shellbuilder_shell_object row into the group registry, keyed by owner_id, not the chunk registry', function()
    local tables = {
        entities = {
            {
                id = 5, entity_type = 'object', model = 'prop_sofa_01',
                x = 100.0, y = 200.0, z = 30.0, heading = 0.0,
                networked = false, enabled = true,
                owner_type = 'shellbuilder_shell_object', owner_id = 42,
                data = json.encode({ shellId = 7, freeze = true }),
            },
        }
    }
    local Streamer = freshService(tables)

    Streamer.init()

    local records = Streamer.getGroupEntityRecords('shellbuilder:shell:7')
    eq(#records, 1, 'reloaded row appears in the shell group')
    eq(records[1].entityId, 'shellbuilder:shell:7:object_42', 'entityId minted off owner_id, namespaced by group')
    eq(records[1].data.model, 'prop_sofa_01')
    eq(records[1].data.freeze, true, 'freeze flag survives a reload, matching the live placement path')

    -- must NOT also land in the chunk registry at the shared anchor chunk
    local chunkKey = Streamer.getChunkKey(100.0, 200.0)
    eq(Streamer.chunks[chunkKey], nil, 'reloaded shell object never registers into the chunk registry')
    eq(Streamer.entities.object['object_42'], nil, 'reloaded shell object never keys into the flat chunk entities table')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
