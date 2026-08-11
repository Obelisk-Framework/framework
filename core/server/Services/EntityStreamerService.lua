--- EntityStreamerService - Chunk-based spatial entity streaming
--- Efficiently manages entities (peds, markers, objects, pickups) based on player position
EntityStreamerService = {}
EntityStreamerService.chunkSize = 100.0 -- Size of each chunk in game units
EntityStreamerService.entities = {} -- {entityType: {entityId: entityData}}
EntityStreamerService.chunks = {} -- {chunkKey: {entityType: {entityId}}}
EntityStreamerService.playerChunks = {} -- {playerId: {currentChunk, activeChunks[]}}
EntityStreamerService.entityTypes = {'ped', 'marker', 'object', 'pickup', 'blip'}
EntityStreamerService.entityBudget = 300 -- global cap on peds/objects/pickups spawned across all players
EntityStreamerService.chunkPlayerRefs = {} -- {chunkKey: number of players with this chunk active}
EntityStreamerService.globalSpawnedCount = 0 -- sum of budget-countable entities across referenced chunks
EntityStreamerService.budgetCountableTypes = { ped = true, object = true, pickup = true }
EntityStreamerService.networkedOwners = {} -- {entityId: source}, who owns a networked entity

--- Initialize the streamer: reset in-memory state, then load every
--- currently-enabled entity from the database and register it.
function EntityStreamerService.init()
    for _, entityType in ipairs(EntityStreamerService.entityTypes) do
        EntityStreamerService.entities[entityType] = {}
    end
    EntityStreamerService.chunks = {}

    local rows = Entity:where('enabled', true):getSync()
    for _, row in ipairs(rows) do
        -- `id = row.id` keys the runtime entity id off the real DB primary key
        -- rather than a timestamp+random pair, which collided in practice when
        -- a whole table's worth of rows registered inside one second.
        EntityStreamerService.register(row.entity_type, {
            id = row.id,
            x = row.x, y = row.y, z = row.z, heading = row.heading,
            model = row.model, networked = row.networked, data = row.data,
        })
    end

    print('[EntityStreamerService] Initialized, loaded ' .. #rows .. ' entities')
end

--- Get chunk key from coordinates
--- @param x number
--- @param y number
--- @return string chunkKey
function EntityStreamerService.getChunkKey(x, y)
    local chunkX = math.floor(x / EntityStreamerService.chunkSize)
    local chunkY = math.floor(y / EntityStreamerService.chunkSize)
    return chunkX .. '_' .. chunkY
end

--- Get surrounding chunk keys
--- @param chunkKey string
--- @param radius number Number of chunks in each direction (default 1)
--- @return table Array of chunk keys
function EntityStreamerService.getSurroundingChunks(chunkKey, radius)
    radius = radius or 1
    local chunks = {}
    
    local baseX, baseY = chunkKey:match('(-?%d+)_(-?%d+)')
    baseX = tonumber(baseX)
    baseY = tonumber(baseY)
    
    for x = -radius, radius do
        for y = -radius, radius do
            table.insert(chunks, (baseX + x) .. '_' .. (baseY + y))
        end
    end
    
    return chunks
end

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

--- Register an entity.
---
--- The stored record is FLAT: `id`/`type`/`x`/`y`/`z`/`networked` are named
--- fields, and every other key of `entityData` (plus every key of its nested
--- `data` json blob, which is where type-specific fields like `scenario`,
--- `sprite` or `markerType` live per the schema) is shallow-copied onto the
--- SAME table. The record is what gets sent to the client as the `data` field
--- of an entityAdd/precache payload, so the client's `data.model` accessor
--- resolves directly -- no extra nesting layer in between.
---
--- @param entityType string Type of entity (ped, marker, object, pickup, blip)
--- @param entityData table Entity data including x, y, z coordinates. An
---        optional `id` (the DB row's primary key) makes the runtime entity id
---        stable and collision-free; without one a timestamp+random id is minted.
--- @return string entityId
function EntityStreamerService.register(entityType, entityData)
    if not EntityStreamerService.entities[entityType] then
        print('[EntityStreamerService] Error: Invalid entity type: ' .. entityType)
        return nil
    end

    -- Prefer a caller-supplied (database) id: unique per type by construction.
    -- The time+random fallback only covers entities registered without one.
    local entityId
    if entityData.id ~= nil then
        entityId = entityType .. '_' .. tostring(entityData.id)
    else
        entityId = entityType .. '_' .. os.time() .. '_' .. math.random(1000, 9999)
    end

    -- Store entity data, flattened.
    local record = {}
    for key, value in pairs(entityData) do
        -- `data` (the json column) is spread rather than nested, so its
        -- type-specific fields are readable at the same level as `model`.
        if key ~= 'data' and key ~= 'id' then record[key] = value end
    end
    if type(entityData.data) == 'table' then
        for key, value in pairs(entityData.data) do
            if key ~= 'id' then record[key] = value end
        end
    end
    record.id = entityId
    record.type = entityType
    record.x = entityData.x
    record.y = entityData.y
    record.z = entityData.z
    record.networked = entityData.networked or false

    EntityStreamerService.entities[entityType][entityId] = record

    -- Add to chunk
    local chunkKey = EntityStreamerService.getChunkKey(entityData.x, entityData.y)
    
    if not EntityStreamerService.chunks[chunkKey] then
        EntityStreamerService.chunks[chunkKey] = {}
    end
    
    if not EntityStreamerService.chunks[chunkKey][entityType] then
        EntityStreamerService.chunks[chunkKey][entityType] = {}
    end
    
    EntityStreamerService.chunks[chunkKey][entityType][entityId] = true
    
    print('[EntityStreamerService] Registered ' .. entityType .. ' #' .. entityId .. ' at chunk ' .. chunkKey)
    
    -- Broadcast to nearby players. Note: this is unreachable today -- register()'s
    -- only caller is init(), which runs at boot before any player has connected,
    -- so playerChunks is always empty here. A future runtime caller would also
    -- need the budget/ref accounting that updatePlayerChunks owns.
    EntityStreamerService.broadcastToChunk(chunkKey, 'core:server:streamer-entityAdd', {
        entityId = entityId,
        entityType = entityType,
        data = EntityStreamerService.entities[entityType][entityId]
    })
    
    return entityId
end

--- Unregister an entity
--- @param entityType string
--- @param entityId string
function EntityStreamerService.unregister(entityType, entityId)
    local entity = EntityStreamerService.entities[entityType][entityId]
    
    if not entity then return end
    
    -- Remove from chunk
    local chunkKey = EntityStreamerService.getChunkKey(entity.x, entity.y)
    
    if EntityStreamerService.chunks[chunkKey] and 
       EntityStreamerService.chunks[chunkKey][entityType] then
        EntityStreamerService.chunks[chunkKey][entityType][entityId] = nil
    end
    
    -- Remove from entities
    EntityStreamerService.entities[entityType][entityId] = nil
    
    -- Broadcast removal
    EntityStreamerService.broadcastToChunk(chunkKey, 'core:server:streamer-entityRemove', {
        entityId = entityId,
        entityType = entityType
    })
    
    print('[EntityStreamerService] Unregistered ' .. entityType .. ' #' .. entityId)
end

--- Drop one player's reference to a chunk, and once nobody references it,
--- give its entities' budget cost back to the global pool. Shared by the
--- ordinary unload path (updatePlayerChunks) and the disconnect path
--- (handlePlayerDropped) so the two can't drift apart.
--- @param chunkKey string
function EntityStreamerService.releaseChunkRef(chunkKey)
    EntityStreamerService.chunkPlayerRefs[chunkKey] = math.max((EntityStreamerService.chunkPlayerRefs[chunkKey] or 1) - 1, 0)
    if EntityStreamerService.chunkPlayerRefs[chunkKey] == 0 then
        EntityStreamerService.globalSpawnedCount = math.max(EntityStreamerService.globalSpawnedCount -
            EntityStreamerService.countBudgetEntitiesInChunk(chunkKey), 0)
    end
end

--- Update player's active chunks, applying tier selection, boundary
--- hysteresis, and tier hysteresis.
--- @param source number Player server ID
--- @param x number
--- @param y number
--- @param facingChunk string the chunk key the player is currently facing
function EntityStreamerService.updatePlayerChunks(source, x, y, facingChunk)
    local currentChunk = EntityStreamerService.getChunkKey(x, y)

    -- facingChunk is nil until Task 4 wires the real caller (which computes
    -- it from heading); fall back to the current chunk so tier 2's candidate
    -- set is still a safe, well-formed chunk pair rather than a nil key.
    facingChunk = facingChunk or currentChunk

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
        EntityStreamerService.releaseChunkRef(chunk)
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

--- Unload a chunk for a player. The client deletes each entity it was told
--- to spawn -- including networked ones it owned, which OneSync destroys for
--- everyone -- so ownership must be released here too, otherwise the
--- spawn-once gate in loadChunkForPlayer would keep pointing at a player who
--- no longer has the entity and nobody could ever respawn it.
--- @param source number
--- @param chunkKey string
function EntityStreamerService.unloadChunkForPlayer(source, chunkKey)
    local chunk = EntityStreamerService.chunks[chunkKey]

    if not chunk then return end

    -- Tell client to remove entities from this chunk
    for entityType, entities in pairs(chunk) do
        for entityId, _ in pairs(entities) do
            if EntityStreamerService.networkedOwners[entityId] == source then
                EntityStreamerService.networkedOwners[entityId] = nil
            end

            Obelisk.emitClient('core:server:streamer-entityRemove', source, {
                entityId = entityId,
                entityType = entityType
            })
        end
    end
end

--- Broadcast event to all players in a chunk
--- @param chunkKey string
--- @param eventName string
--- @param data table
function EntityStreamerService.broadcastToChunk(chunkKey, eventName, data)
    for playerId, playerData in pairs(EntityStreamerService.playerChunks) do
        for _, activeChunk in ipairs(playerData.activeChunks) do
            if activeChunk == chunkKey then
                Obelisk.emitClient(eventName, playerId, data)
                break
            end
        end
    end
end

--- Get all entities in a chunk
--- @param chunkKey string
--- @return table
function EntityStreamerService.getChunkEntities(chunkKey)
    return EntityStreamerService.chunks[chunkKey] or {}
end

--- Resolve a chunk's raw entity-id index into a flat array of full entity
--- records, the same {entityId, entityType, data} shape entityAdd already
--- sends -- so precache payloads and real spawn payloads share one shape.
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

--- Clean up player data on disconnect: release their chunk references (and
--- the budget those chunks were holding), drop their chunk tracking, and
--- release ownership of any networked entities they were responsible for.
function EntityStreamerService.handlePlayerDropped()
    local source = source

    local playerData = EntityStreamerService.playerChunks[source]
    if playerData then
        for _, chunkKey in ipairs(playerData.activeChunks or {}) do
            EntityStreamerService.releaseChunkRef(chunkKey)
        end
    end

    EntityStreamerService.playerChunks[source] = nil

    for entityId, ownerSource in pairs(EntityStreamerService.networkedOwners) do
        if ownerSource == source then
            EntityStreamerService.networkedOwners[entityId] = nil
        end
    end
end

AddEventHandler('playerDropped', EntityStreamerService.handlePlayerDropped)

--- Net events
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

-- NOTE: a 'core:client:streamer-requestChunk' handler used to live here. It
-- called loadChunkForPlayer with a client-supplied chunk key, bypassing the
-- tier/budget/ref-count accounting in updatePlayerChunks entirely and letting
-- a client claim networked-entity ownership for free. Nothing in the codebase
-- ever emitted it, so it was removed rather than retrofitted. Any future
-- client-driven chunk request must go through updatePlayerChunks.

-- Initialize on resource start
Citizen.CreateThread(function()
    EntityStreamerService.init()
end)

return EntityStreamerService
