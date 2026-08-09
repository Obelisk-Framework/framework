--- EntityStreamerService - Chunk-based spatial entity streaming
--- Efficiently manages entities (peds, markers, objects, pickups) based on player position
EntityStreamerService = {}
EntityStreamerService.chunkSize = 100.0 -- Size of each chunk in game units
EntityStreamerService.entities = {} -- {entityType: {entityId: entityData}}
EntityStreamerService.chunks = {} -- {chunkKey: {entityType: {entityId}}}
EntityStreamerService.playerChunks = {} -- {playerId: {currentChunk, activeChunks[]}}
EntityStreamerService.entityTypes = {'ped', 'marker', 'object', 'pickup', 'blip'}

--- Initialize the streamer
function EntityStreamerService.init()
    for _, entityType in ipairs(EntityStreamerService.entityTypes) do
        EntityStreamerService.entities[entityType] = {}
    end
    
    print('[EntityStreamerService] Initialized')
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

--- Register an entity
--- @param entityType string Type of entity (ped, marker, object, pickup, blip)
--- @param entityData table Entity data including x, y, z coordinates
--- @return string entityId
function EntityStreamerService.register(entityType, entityData)
    if not EntityStreamerService.entities[entityType] then
        print('[EntityStreamerService] Error: Invalid entity type: ' .. entityType)
        return nil
    end
    
    -- Generate unique ID
    local entityId = entityType .. '_' .. os.time() .. '_' .. math.random(1000, 9999)
    
    -- Store entity data
    EntityStreamerService.entities[entityType][entityId] = {
        id = entityId,
        type = entityType,
        x = entityData.x,
        y = entityData.y,
        z = entityData.z,
        data = entityData
    }
    
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
    
    -- Broadcast to nearby players
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

--- Update player's active chunks
--- @param source number Player server ID
--- @param x number Player X coordinate
--- @param y number Player Y coordinate
function EntityStreamerService.updatePlayerChunks(source, x, y)
    local currentChunk = EntityStreamerService.getChunkKey(x, y)
    local newActiveChunks = EntityStreamerService.getSurroundingChunks(currentChunk, 1)
    
    -- Initialize player data if needed
    if not EntityStreamerService.playerChunks[source] then
        EntityStreamerService.playerChunks[source] = {
            currentChunk = currentChunk,
            activeChunks = {}
        }
    end
    
    local playerData = EntityStreamerService.playerChunks[source]
    local oldActiveChunks = playerData.activeChunks
    
    -- Find chunks to load (new chunks)
    local chunksToLoad = {}
    for _, chunk in ipairs(newActiveChunks) do
        local alreadyActive = false
        for _, oldChunk in ipairs(oldActiveChunks) do
            if oldChunk == chunk then
                alreadyActive = true
                break
            end
        end
        
        if not alreadyActive then
            table.insert(chunksToLoad, chunk)
        end
    end
    
    -- Find chunks to unload (chunks no longer active)
    local chunksToUnload = {}
    for _, oldChunk in ipairs(oldActiveChunks) do
        local stillActive = false
        for _, chunk in ipairs(newActiveChunks) do
            if chunk == oldChunk then
                stillActive = true
                break
            end
        end
        
        if not stillActive then
            table.insert(chunksToUnload, oldChunk)
        end
    end
    
    -- Load new chunks
    for _, chunk in ipairs(chunksToLoad) do
        EntityStreamerService.loadChunkForPlayer(source, chunk)
    end
    
    -- Unload old chunks
    for _, chunk in ipairs(chunksToUnload) do
        EntityStreamerService.unloadChunkForPlayer(source, chunk)
    end
    
    -- Update player data
    playerData.currentChunk = currentChunk
    playerData.activeChunks = newActiveChunks
end

--- Load a chunk for a player
--- @param source number
--- @param chunkKey string
function EntityStreamerService.loadChunkForPlayer(source, chunkKey)
    local chunk = EntityStreamerService.chunks[chunkKey]
    
    if not chunk then return end
    
    -- Send all entities in this chunk to the player
    for entityType, entities in pairs(chunk) do
        for entityId, _ in pairs(entities) do
            local entityData = EntityStreamerService.entities[entityType][entityId]
            
            if entityData then
                TriggerClientEvent('core:server:streamer-entityAdd', source, {
                    entityId = entityId,
                    entityType = entityType,
                    data = entityData
                })
            end
        end
    end
end

--- Unload a chunk for a player
--- @param source number
--- @param chunkKey string
function EntityStreamerService.unloadChunkForPlayer(source, chunkKey)
    local chunk = EntityStreamerService.chunks[chunkKey]
    
    if not chunk then return end
    
    -- Tell client to remove entities from this chunk
    for entityType, entities in pairs(chunk) do
        for entityId, _ in pairs(entities) do
            TriggerClientEvent('core:server:streamer-entityRemove', source, {
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
                TriggerClientEvent(eventName, playerId, data)
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

--- Clean up player data on disconnect
AddEventHandler('playerDropped', function()
    local source = source
    EntityStreamerService.playerChunks[source] = nil
end)

--- Net events
RegisterNetEvent('core:client:streamer-updatePosition')
AddEventHandler('core:client:streamer-updatePosition', function(x, y)
    local source = source
    EntityStreamerService.updatePlayerChunks(source, x, y)
end)

RegisterNetEvent('core:client:streamer-requestChunk')
AddEventHandler('core:client:streamer-requestChunk', function(chunkKey)
    local source = source
    EntityStreamerService.loadChunkForPlayer(source, chunkKey)
end)

-- Initialize on resource start
Citizen.CreateThread(function()
    EntityStreamerService.init()
end)

return EntityStreamerService
