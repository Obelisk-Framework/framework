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
    onClient = function() end,
    onStateBag = function() end,
    emitClient = function(eventName, target, data)
        table.insert(emitClientCalls, { eventName = eventName, target = target, data = data })
    end,
}

-- broadcastToChunk resolves a raw numeric playerId into a Player via
-- PlayerService.get before calling player:emit -- these tests never
-- populate playerChunks in a way that exercises that path with a real
-- player, so a stub that always reports "no such player" is enough to let
-- register()/unregister() (which call broadcastToChunk) load without error.
_G.PlayerService = _G.PlayerService or {
    get = function(source) return nil end,
}

-- A minimal fake Player: source/getSource matches PlayerService's real
-- Player, and emit forwards to Obelisk.emitClient the same way the real
-- Player:emit (PlayerService.lua) does, so the emitClientCalls spy above
-- still captures every send.
local function fakePlayer(source)
    return {
        source = source,
        getSource = function(self) return self.source end,
        emit = function(self, event, ...) Obelisk.emitClient(event, self, ...) end,
    }
end

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
local function assert_(cond, msg)
    if not cond then error(msg or 'assertion failed') end
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

test('countEntitiesInChunkByType sums ped/object/pickup per type but ignores marker/blip', function()
    local Streamer = freshService({ entities = {} })
    Streamer.chunks['0_0'] = {
        ped = { a = true, b = true },
        object = { c = true },
        marker = { d = true, e = true, f = true },
        blip = { g = true },
    }
    local counts = Streamer.countEntitiesInChunkByType('0_0')
    eq(counts.ped,    2, '2 peds counted')
    eq(counts.object, 1, '1 object counted')
    eq(counts.pickup, 0, '0 pickups')
    eq(counts.marker, nil, 'marker not tracked')
    eq(counts.blip,   nil, 'blip not tracked')
end)

test('selectTier returns tier 1 (9 chunks) when the budget comfortably fits', function()
    local Streamer = freshService({ entities = {} })
    Streamer.globalBudgets = { ped = 300, object = 300, pickup = 300 }
    Streamer.chunks['0_0'] = { ped = { a = true } }
    local chunks, tier = Streamer.selectTier('0_0', '1_0')
    eq(tier, 1)
    eq(#chunks, 9)
end)

test('selectTier degrades to tier 2 (current+facing) when tier 1 would exceed budget', function()
    local Streamer = freshService({ entities = {} })
    Streamer.globalBudgets = { ped = 5, object = 5, pickup = 5 }
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
    Streamer.globalBudgets = { ped = 1, object = 1, pickup = 1 }
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
    Streamer.globalBudgets = { ped = 0, object = 0, pickup = 0 }
    local heavy = {}
    for i = 1, 5 do heavy['p' .. i] = true end
    Streamer.chunks['0_0'] = { ped = heavy }
    local chunks, tier = Streamer.selectTier('0_0', '1_0')
    eq(tier, 3)
end)

test('selectTier does not double-count a chunk already referenced by another player', function()
    local Streamer = freshService({ entities = {} })
    Streamer.globalBudgets = { ped = 12, object = 12, pickup = 12 }
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['1_1'] = { ped = heavy }
    -- another player already has this chunk loaded, so it must not count
    -- again toward THIS player's projected budget check
    Streamer.chunkPlayerRefs['1_1'] = 1
    Streamer.globalSpawnedCounts.ped = 10
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
    Streamer.globalBudgets = { ped = 1, object = 1, pickup = 1 }
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['1_0'] = { ped = heavy }

    Streamer.updatePlayerChunks(fakePlayer(1), 50.0, 50.0, '1_0')
    local firstActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do firstActive[c] = true end
    eq(firstActive['0_0'], true, 'starts with 0_0 active')
    eq(#Streamer.playerChunks[1].activeChunks, 1, 'tier 3 forced by the tiny budget')

    -- move 5 units past the x=100 boundary into chunk 1_0 -- within the
    -- 15-unit margin, so 0_0 must still be active
    Streamer.updatePlayerChunks(fakePlayer(1), 105.0, 50.0, '2_0')
    local stillActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do stillActive[c] = true end
    eq(stillActive['0_0'], true, '0_0 stays active within the 15-unit margin')

    -- move 20 units past the boundary -- now it should unload
    Streamer.updatePlayerChunks(fakePlayer(1), 120.0, 50.0, '2_0')
    local laterActive = {}
    for _, c in ipairs(Streamer.playerChunks[1].activeChunks) do laterActive[c] = true end
    eq(laterActive['0_0'], nil, '0_0 unloads once 20 units past the boundary')
end)

test('updatePlayerChunks only changes tier after 2 consecutive ticks agree', function()
    local Streamer = freshService({ entities = {} })
    local heavy = {}
    for i = 1, 10 do heavy['p' .. i] = true end
    Streamer.chunks['3_0'] = { ped = heavy }

    Streamer.globalBudgets = { ped = 100000, object = 100000, pickup = 100000 }
    Streamer.updatePlayerChunks(fakePlayer(1), 50.0, 50.0, '0_0')
    eq(#Streamer.playerChunks[1].activeChunks, 9, 'starts at tier 1 (9 chunks)')

    -- move near the heavy chunk with a budget too small to afford it -- should
    -- NOT downgrade to tier 3 on the first tick
    Streamer.globalBudgets = { ped = 5, object = 5, pickup = 5 }
    Streamer.updatePlayerChunks(fakePlayer(1), 250.0, 50.0, '3_0')
    eq(#Streamer.playerChunks[1].activeChunks, 9, 'a single spike does not downgrade the tier')

    -- second consecutive tick agreeing -- now it flips
    Streamer.updatePlayerChunks(fakePlayer(1), 250.0, 50.0, '3_0')
    eq(#Streamer.playerChunks[1].activeChunks, 1, 'two consecutive ticks downgrade to tier 3')
end)

test('chunkPlayerRefs increments when a chunk becomes active and decrements when unloaded', function()
    local Streamer = freshService({ entities = {} })
    Streamer.globalBudgets = { ped = 100000, object = 100000, pickup = 100000 }
    Streamer.updatePlayerChunks(fakePlayer(1), 50.0, 50.0, '0_0')
    eq(Streamer.chunkPlayerRefs['0_0'], 1, 'ref count incremented for the player chunk')

    Streamer.updatePlayerChunks(fakePlayer(1), 1500.0, 1500.0, '16_15')
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

test('init() spreads type-specific data fields (e.g. scenario) onto a non-shell entity, now that get() is model-aware', function()
    -- Regression coverage for the model-aware Entity:get() change: before
    -- that change, `row.data` arrived at the non-shell register() branch as
    -- an undecoded JSON string (Entity:where(...):get() went through the
    -- plain QueryBuilder), so buildEntityRecord's `type(entityData.data) ==
    -- 'table'` check was always false and these fields never spread at
    -- boot. Now that Entity:get() is model-aware (decodes `casts.data ==
    -- 'json'` via BaseModel:newFromQuery), `row.data` arrives pre-decoded
    -- as a table, so the check flips true. This must use the REAL
    -- QueryBuilder's model-aware get() (via `.model` on the fake), not a
    -- hand-decoded fixture, or it wouldn't actually exercise that path.
    local tables = {
        entities = {
            { id = 9, entity_type = 'ped', model = 'a_m_y_business_01', x = 10.0, y = 20.0, z = 30.0,
              heading = 0.0, networked = false, enabled = true,
              data = json.encode({ scenario = 'WORLD_HUMAN_CLIPBOARD', freeze = true }) },
        }
    }
    local Streamer = freshService(tables)

    Streamer.init()

    local entity = Streamer.entities.ped['ped_9']
    eq(entity ~= nil, true, 'ped from row #9 registered')
    eq(entity.scenario, 'WORLD_HUMAN_CLIPBOARD', 'scenario spread onto the record from the decoded data column')
    eq(entity.freeze, true, 'freeze spread onto the record from the decoded data column')
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

    Streamer.loadChunkForPlayer(fakePlayer(1), chunkKey)
    Streamer.loadChunkForPlayer(fakePlayer(2), chunkKey)

    eq(#sentTo, 1, 'only one player was told to spawn the networked entity')
    eq(sentTo[1]:getSource(), 1, 'the first loader became the owner')
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

    Streamer.loadChunkForPlayer(fakePlayer(1), chunkKey)
    Streamer.loadChunkForPlayer(fakePlayer(2), chunkKey)

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

    Streamer.loadChunkForPlayer(fakePlayer(1), chunkKey)
    eq(Streamer.networkedOwners[id], 1)

    source = 1
    Streamer.handlePlayerDropped()
    eq(Streamer.networkedOwners[id], nil, 'owner cleared on disconnect')

    Streamer.loadChunkForPlayer(fakePlayer(2), chunkKey)
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

    Streamer.loadChunkForPlayer(fakePlayer(1), chunkKey)
    eq(Streamer.networkedOwners[id], 1, 'player 1 owns it after loading')

    -- An ordinary chunk-boundary unload (not a disconnect): player 1's client
    -- deletes the entity, so the ownership claim must be released too.
    Streamer.unloadChunkForPlayer(fakePlayer(1), chunkKey)
    eq(Streamer.networkedOwners[id], nil, 'ownership released on ordinary unload')

    Streamer.loadChunkForPlayer(fakePlayer(2), chunkKey)
    eq(Streamer.networkedOwners[id], 2, 'player 2 becomes the new owner')
    eq(sentTo[#sentTo]:getSource(), 2, 'player 2 was told to spawn it')
    _G.Obelisk = savedObelisk
end)

test('unloading a chunk does not steal ownership held by a different player', function()
    local Streamer = freshService({ entities = {} })
    local savedObelisk = _G.Obelisk
    Obelisk = { emitClient = function() end }
    local id = Streamer.register('object', { x = 10, y = 10, z = 0, networked = true })
    local chunkKey = Streamer.getChunkKey(10, 10)

    Streamer.loadChunkForPlayer(fakePlayer(1), chunkKey)
    Streamer.unloadChunkForPlayer(fakePlayer(2), chunkKey)
    eq(Streamer.networkedOwners[id], 1, 'a non-owner unloading leaves the owner intact')
    _G.Obelisk = savedObelisk
end)

test('handlePlayerDropped releases the chunk refs and budget the player held', function()
    local Streamer = freshService({ entities = {} })
    Streamer.globalBudgets = { ped = 100000, object = 100000, pickup = 100000 }
    -- put budget-countable entities in a few of the 9 tier-1 chunks
    Streamer.chunks['0_0'] = { ped = { a = true, b = true } }
    Streamer.chunks['1_0'] = { object = { c = true } }
    Streamer.chunks['-1_-1'] = { pickup = { d = true } }

    Streamer.updatePlayerChunks(fakePlayer(1), 50.0, 50.0, '1_0')
    local activeChunks = Streamer.playerChunks[1].activeChunks
    eq(#activeChunks, 9, 'player reached tier 1')
    eq(Streamer.globalSpawnedCounts.ped,    2, '2 peds counted')
    eq(Streamer.globalSpawnedCounts.object, 1, '1 object counted')
    eq(Streamer.globalSpawnedCounts.pickup, 1, '1 pickup counted')
    for _, chunkKey in ipairs(activeChunks) do
        eq(Streamer.chunkPlayerRefs[chunkKey], 1, 'ref held for ' .. chunkKey)
    end

    local held = {}
    for _, chunkKey in ipairs(activeChunks) do table.insert(held, chunkKey) end

    source = 1
    Streamer.handlePlayerDropped()

    eq(Streamer.globalSpawnedCounts.ped,    0, 'ped budget fully returned on disconnect')
    eq(Streamer.globalSpawnedCounts.object, 0, 'object budget fully returned on disconnect')
    eq(Streamer.globalSpawnedCounts.pickup, 0, 'pickup budget fully returned on disconnect')
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
    service.sendGroupEntitiesTo(fakePlayer(7), 'shellbuilder:shell:1')
    eq(#emitClientCalls, 2)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityAdd')
    eq(emitClientCalls[1].target:getSource(), 7)
    eq(emitClientCalls[2].target:getSource(), 7)
end)

test('despawnGroupEntitiesFor emits entityRemove for every record in the group, to the given source', function()
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 43, x = 4.0, y = 5.0, z = 6.0, model = 'b' })
    emitClientCalls = {}

    service.despawnGroupEntitiesFor(fakePlayer(7), 'shellbuilder:shell:1')

    eq(#emitClientCalls, 2)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityRemove')
    eq(emitClientCalls[1].target:getSource(), 7)
    eq(emitClientCalls[2].eventName, 'core:server:streamer-entityRemove')
    eq(emitClientCalls[2].target:getSource(), 7)
    -- the group's records still exist -- despawn only tells the client to
    -- remove its local copy, it doesn't mutate server-side group state
    eq(#service.getGroupEntityRecords('shellbuilder:shell:1'), 2)
end)

test('despawnGroupEntitiesFor emits nothing for an empty/unknown group', function()
    local service = freshService()
    emitClientCalls = {}
    service.despawnGroupEntitiesFor(fakePlayer(7), 'shellbuilder:shell:does-not-exist')
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

-- ── per-type global budget ────────────────────────────────────────────────────

test('perPlayerCaps has correct values for ped / object / pickup', function()
    local Streamer = freshService()
    eq(Streamer.perPlayerCaps.ped,    256,  'ped cap')
    eq(Streamer.perPlayerCaps.object, 2048, 'object cap')
    eq(Streamer.perPlayerCaps.pickup, 70,   'pickup cap')
end)

test('globalBudgets has correct defaults', function()
    local Streamer = freshService()
    eq(Streamer.globalBudgets.ped,    2048,  'ped global')
    eq(Streamer.globalBudgets.object, 16384, 'object global')
    eq(Streamer.globalBudgets.pickup, 700,   'pickup global')
end)

test('countEntitiesInChunkByType returns per-type counts', function()
    local Streamer = freshService()
    Streamer.register('ped',    { x=0, y=0, z=0, heading=0, model='a', networked=false })
    Streamer.register('ped',    { x=0, y=0, z=0, heading=0, model='b', networked=false })
    Streamer.register('object', { x=0, y=0, z=0, heading=0, model='c', networked=false })
    Streamer.register('pickup', { x=0, y=0, z=0, heading=0, model='d', networked=false })
    local counts = Streamer.countEntitiesInChunkByType('0_0')
    eq(counts.ped,    2, 'ped count')
    eq(counts.object, 1, 'object count')
    eq(counts.pickup, 1, 'pickup count')
end)

test('globalSpawnedCounts increments per type when chunk first referenced', function()
    local Streamer = freshService()
    Streamer.register('ped',    { x=0, y=0, z=0, heading=0, model='a', networked=false })
    Streamer.register('object', { x=0, y=0, z=0, heading=0, model='b', networked=false })
    eq(Streamer.globalSpawnedCounts.ped,    0, 'initial ped')
    eq(Streamer.globalSpawnedCounts.object, 0, 'initial object')
    Streamer.chunkPlayerRefs['0_0'] = 1
    -- simulate what updatePlayerChunks does on first-ref of a chunk:
    local added = Streamer.countEntitiesInChunkByType('0_0')
    for t, n in pairs(added) do
        Streamer.globalSpawnedCounts[t] = (Streamer.globalSpawnedCounts[t] or 0) + n
    end
    eq(Streamer.globalSpawnedCounts.ped,    1, 'ped after ref')
    eq(Streamer.globalSpawnedCounts.object, 1, 'object after ref')
end)

test('releaseChunkRef decrements globalSpawnedCounts per type at zero refs', function()
    local Streamer = freshService()
    Streamer.register('ped', { x=0, y=0, z=0, heading=0, model='a', networked=false })
    -- seed state as if chunk was loaded
    Streamer.chunkPlayerRefs['0_0'] = 1
    Streamer.globalSpawnedCounts.ped = 1
    Streamer.releaseChunkRef('0_0')
    eq(Streamer.chunkPlayerRefs['0_0'], 0,    'ref reaches zero')
    eq(Streamer.globalSpawnedCounts.ped, 0,   'ped count decremented')
end)

test('selectTier downgrades when global budget for a type is at cap', function()
    local Streamer = freshService()
    -- Fill global ped budget to cap
    Streamer.globalSpawnedCounts.ped = Streamer.globalBudgets.ped
    -- Register enough peds in chunk '0_0' that tier1 would exceed ped global budget
    for i = 1, 3 do
        Streamer.register('ped', { x=0, y=0, z=0, heading=0, model='p'..i, networked=false })
    end
    -- tier1 = 3x3 grid around '0_0', projected ped addition > 0, global already at cap
    -- selectTier must not return tier 1
    local _, tier = Streamer.selectTier('0_0', '0_0', 1) -- source=1, Task2 adds per-player gate
    assert_(tier > 1, 'expected tier downgrade, got tier ' .. tier)
end)

-- ── per-player load tracking ──────────────────────────────────────────────────

test('playerLoad initialised to zero counts when player first updates position', function()
    local Streamer = freshService()
    local p = fakePlayer(1)
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')
    assert_(Streamer.playerLoad[1] ~= nil, 'playerLoad[1] missing')
    eq(Streamer.playerLoad[1].ped,    0, 'ped')
    eq(Streamer.playerLoad[1].object, 0, 'object')
    eq(Streamer.playerLoad[1].pickup, 0, 'pickup')
end)

test('playerLoad accumulates entity counts from active chunks', function()
    local Streamer = freshService()
    Streamer.register('ped',    { x=0, y=0, z=0, heading=0, model='a', networked=false })
    Streamer.register('object', { x=0, y=0, z=0, heading=0, model='b', networked=false })
    local p = fakePlayer(1)
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')
    assert_(Streamer.playerLoad[1].ped >= 1,    'ped in load')
    assert_(Streamer.playerLoad[1].object >= 1, 'object in load')
end)

test('playerLoad decrements when chunk unloaded (player moves away)', function()
    local Streamer = freshService()
    Streamer.register('ped', { x=0, y=0, z=0, heading=0, model='a', networked=false })
    local p = fakePlayer(1)
    -- Move player into chunk 0_0
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')
    local pedBefore = Streamer.playerLoad[1].ped
    assert_(pedBefore >= 1, 'ped loaded')
    -- Move player far away so chunk 0_0 drops out of any tier
    -- Use a distance large enough to clear boundary hysteresis (>15 units past boundary)
    Streamer.updatePlayerChunks(p, 5000, 5000, '50_50')
    Streamer.updatePlayerChunks(p, 5000, 5000, '50_50') -- second tick commits tier
    eq(Streamer.playerLoad[1].ped, 0, 'ped after unload')
end)

test('playerLoad cleaned up on player disconnect', function()
    local Streamer = freshService()
    local p = fakePlayer(42)
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')
    assert_(Streamer.playerLoad[42] ~= nil, 'present before drop')
    -- simulate playerDropped with source = 42
    local savedSource = source
    source = 42
    Streamer.handlePlayerDropped()
    source = savedSource
    assert_(Streamer.playerLoad[42] == nil, 'removed after drop')
end)

test('selectTier downgrades when per-player ped cap would be exceeded', function()
    local Streamer = freshService()
    -- Register peds filling chunk 0_0 to just below per-player ped cap
    -- Use a small cap override so we don't need 256 registered peds
    Streamer.perPlayerCaps.ped = 2
    for i = 1, 3 do
        Streamer.register('ped', { x=0, y=0, z=0, heading=0, model='p'..i, networked=false })
    end
    -- player 1 has 2 peds already in load (at cap)
    Streamer.playerLoad[1] = { ped = 2, object = 0, pickup = 0 }
    -- tier1 projected addition includes these 3 peds → would push to 5 > cap of 2
    local _, tier = Streamer.selectTier('0_0', '0_0', 1)
    assert_(tier > 1, 'expected tier downgrade at player ped cap, got ' .. tier)
end)

test('two players sharing a chunk: globalSpawnedCounts increments once, playerLoad increments for both', function()
    local Streamer = freshService()
    Streamer.register('object', { x=0, y=0, z=0, heading=0, model='o', networked=false })
    local p1 = fakePlayer(1)
    local p2 = fakePlayer(2)
    Streamer.updatePlayerChunks(p1, 0, 0, '0_0')
    Streamer.updatePlayerChunks(p2, 0, 0, '0_0')
    eq(Streamer.globalSpawnedCounts.object, 1, 'global count is 1 (shared chunk)')
    assert_(Streamer.playerLoad[1].object >= 1, 'p1 load')
    assert_(Streamer.playerLoad[2].object >= 1, 'p2 load')
end)

test('playerLoad invariant: matches recomputed sum across activeChunks after tier changes', function()
    local Streamer = freshService()
    -- Register entities in two different chunks
    Streamer.register('ped',    { x=0,    y=0,    z=0, heading=0, model='p1', networked=false })
    Streamer.register('object', { x=0,    y=0,    z=0, heading=0, model='o1', networked=false })
    Streamer.register('ped',    { x=5000, y=5000, z=0, heading=0, model='p2', networked=false })

    local p = fakePlayer(7)

    -- Move player to chunk 0_0, commit tier (2 ticks)
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')

    -- Verify invariant: playerLoad matches sum across activeChunks
    local function checkInvariant(label)
        local playerData = Streamer.playerChunks[7]
        assert_(playerData ~= nil, label .. ': no playerData')
        local expected = { ped = 0, object = 0, pickup = 0 }
        for _, chunkKey in ipairs(playerData.activeChunks) do
            local counts = Streamer.countEntitiesInChunkByType(chunkKey)
            for t, n in pairs(counts) do
                expected[t] = (expected[t] or 0) + n
            end
        end
        local load = Streamer.playerLoad[7] or {}
        for t, n in pairs(expected) do
            eq(load[t] or 0, n, label .. ': playerLoad.' .. t)
        end
    end

    checkInvariant('after first position')

    -- Force tier downgrade by capping global ped budget
    Streamer.globalBudgets.ped = Streamer.globalSpawnedCounts.ped
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')
    Streamer.updatePlayerChunks(p, 0, 0, '0_0')
    checkInvariant('after tier downgrade')

    -- Restore budget and move to the second chunk
    Streamer.globalBudgets.ped = 2048
    Streamer.updatePlayerChunks(p, 5000, 5000, '50_50')
    Streamer.updatePlayerChunks(p, 5000, 5000, '50_50')
    checkInvariant('after chunk change')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
