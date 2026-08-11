--- Client EntityStreamerService - Handles entity spawning/despawning based on chunks
EntityStreamerService = {}
EntityStreamerService.entities = {} -- {entityId: {type, handle, data}}
EntityStreamerService.updateInterval = 500 -- Update position every 500ms
EntityStreamerService.lastUpdateTime = 0

--- Initialize the streamer
function EntityStreamerService.init()
    print('[EntityStreamerService] Client initialized')
end

--- Spawn an entity based on type
--- @param entityId string
--- @param entityType string
--- @param entityData table
function EntityStreamerService.spawnEntity(entityId, entityType, entityData)
    -- Don't spawn if already exists
    if EntityStreamerService.entities[entityId] then
        return
    end
    
    local handle = nil
    
    if entityType == 'ped' then
        handle = EntityStreamerService.spawnPed(entityData)
    elseif entityType == 'marker' then
        handle = EntityStreamerService.spawnMarker(entityData)
    elseif entityType == 'object' then
        handle = EntityStreamerService.spawnObject(entityData)
    elseif entityType == 'pickup' then
        handle = EntityStreamerService.spawnPickup(entityData)
    elseif entityType == 'blip' then
        handle = EntityStreamerService.spawnBlip(entityData)
    end
    
    if handle then
        EntityStreamerService.entities[entityId] = {
            type = entityType,
            handle = handle,
            data = entityData
        }
        
        print('[EntityStreamerService] Spawned ' .. entityType .. ' #' .. entityId)
    end
end

--- Despawn an entity
--- @param entityId string
function EntityStreamerService.despawnEntity(entityId)
    local entity = EntityStreamerService.entities[entityId]
    
    if not entity then return end
    
    if entity.type == 'ped' then
        if DoesEntityExist(entity.handle) then
            DeleteEntity(entity.handle)
        end
    elseif entity.type == 'object' then
        if DoesEntityExist(entity.handle) then
            DeleteObject(entity.handle)
        end
    elseif entity.type == 'pickup' then
        if DoesEntityExist(entity.handle) then
            RemovePickup(entity.handle)
        end
    elseif entity.type == 'blip' then
        if DoesBlipExist(entity.handle) then
            RemoveBlip(entity.handle)
        end
    end
    -- Markers don't need cleanup as they're drawn each frame
    
    EntityStreamerService.entities[entityId] = nil
    
    print('[EntityStreamerService] Despawned ' .. entity.type .. ' #' .. entityId)
end

--- Spawn a ped
--- @param data table
--- @return number pedHandle
function EntityStreamerService.spawnPed(data)
    local model = GetHashKey(data.model or 'a_m_y_business_01')
    
    RequestModel(model)
    local timeout = 0
    while not HasModelLoaded(model) and timeout < 5000 do
        Wait(10)
        timeout = timeout + 10
    end
    
    if not HasModelLoaded(model) then
        print('[EntityStreamerService] Failed to load ped model: ' .. data.model)
        return nil
    end
    
    local ped = CreatePed(4, model, data.x, data.y, data.z, data.heading or 0.0, false, true)
    
    if data.freeze then
        FreezeEntityPosition(ped, true)
    end
    
    if data.invincible then
        SetEntityInvincible(ped, true)
    end
    
    if data.scenario then
        TaskStartScenarioInPlace(ped, data.scenario, 0, true)
    end
    
    SetModelAsNoLongerNeeded(model)
    
    return ped
end

--- Spawn an object
--- @param data table
--- @return number objectHandle
function EntityStreamerService.spawnObject(data)
    local model = GetHashKey(data.model)
    
    RequestModel(model)
    local timeout = 0
    while not HasModelLoaded(model) and timeout < 5000 do
        Wait(10)
        timeout = timeout + 10
    end
    
    if not HasModelLoaded(model) then
        print('[EntityStreamerService] Failed to load object model: ' .. data.model)
        return nil
    end
    
    local object = CreateObject(model, data.x, data.y, data.z, false, false, true)
    
    if data.heading then
        SetEntityHeading(object, data.heading)
    end
    
    if data.freeze then
        FreezeEntityPosition(object, true)
    end
    
    SetModelAsNoLongerNeeded(model)
    
    return object
end

--- Spawn a pickup
--- @param data table
--- @return number pickupHandle
function EntityStreamerService.spawnPickup(data)
    local pickupHash = GetHashKey(data.pickupType or 'PICKUP_MONEY_CASE')
    
    local pickup = CreatePickup(
        pickupHash,
        data.x, data.y, data.z,
        0, -- flags
        data.amount or 0,
        data.model or 0,
        false,
        true
    )
    
    return pickup
end

--- Spawn a blip
--- @param data table
--- @return number blipHandle
function EntityStreamerService.spawnBlip(data)
    local blip = AddBlipForCoord(data.x, data.y, data.z)
    
    if data.sprite then
        SetBlipSprite(blip, data.sprite)
    end
    
    if data.color then
        SetBlipColour(blip, data.color)
    end
    
    if data.scale then
        SetBlipScale(blip, data.scale)
    end
    
    if data.label then
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(data.label)
        EndTextCommandSetBlipName(blip)
    end
    
    if data.shortRange then
        SetBlipAsShortRange(blip, true)
    end
    
    return blip
end

--- Register marker (drawn each frame, no handle needed)
--- @param data table
--- @return string marker_id
function EntityStreamerService.spawnMarker(data)
    return 'marker_' .. os.time()
end

--- Draw markers each frame
Citizen.CreateThread(function()
    while true do
        Wait(0)
        
        for entityId, entity in pairs(EntityStreamerService.entities) do
            if entity.type == 'marker' then
                local data = entity.data
                
                DrawMarker(
                    data.markerType or 1, -- type
                    data.x, data.y, data.z, -- position
                    0.0, 0.0, 0.0, -- direction
                    0.0, 0.0, 0.0, -- rotation
                    data.scaleX or 1.0, data.scaleY or 1.0, data.scaleZ or 1.0, -- scale
                    data.r or 255, data.g or 0, data.b or 0, data.a or 100, -- color
                    data.bobUpAndDown or false,
                    data.faceCamera or true,
                    2,
                    data.rotate or false,
                    nil,
                    nil,
                    false
                )
            end
        end
    end
end)

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

--- Net event handlers
Obelisk.onClient('core:server:streamer-entityAdd', function(data)
    EntityStreamerService.spawnEntity(data.entityId, data.entityType, data.data)
end)

Obelisk.onClient('core:server:streamer-entityRemove', function(data)
    EntityStreamerService.despawnEntity(data.entityId)
end)

--- Initialize on resource start
Citizen.CreateThread(function()
    EntityStreamerService.init()
end)

return EntityStreamerService
