-- plugins/oblsk_propattach/client/main.lua
--- Spawns a fresh prop and attaches it to a parent entity resolved from a
--- network id. Mirrors EntityStreamerService.spawnObject's model-load
--- timeout pattern for the parent-resolve wait.
PropAttach = {}
PropAttach.active = {} -- {attachmentId: propHandle}

local function resolveParentEntity(netId, timeoutMs)
    local waited = 0
    while waited < timeoutMs do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local entity = NetworkGetEntityFromNetworkId(netId)
            if DoesEntityExist(entity) then return entity end
        end
        Citizen.Wait(50)
        waited = waited + 50
    end
    return nil
end

Obelisk.onServer('core:server:propattach-create', function(data)
    if PropAttach.active[data.attachmentId] then return end

    local model = GetHashKey(data.propModel)
    RequestModel(model)
    local waited = 0
    while not HasModelLoaded(model) and waited < 5000 do
        Citizen.Wait(10)
        waited = waited + 10
    end
    if not HasModelLoaded(model) then
        print('[PropAttach] Failed to load prop model: ' .. tostring(data.propModel))
        return
    end

    local parent = resolveParentEntity(data.parentNetId, PropAttachConfig.ParentResolveTimeoutMs)
    if not parent then
        print('[PropAttach] Parent entity ' .. tostring(data.parentNetId) .. ' never resolved, dropping attachment #' .. tostring(data.attachmentId))
        SetModelAsNoLongerNeeded(model)
        return
    end

    local prop = CreateObject(model, 0.0, 0.0, 0.0, false, false, true)
    SetModelAsNoLongerNeeded(model)

    local offset = data.offset or { x = 0, y = 0, z = 0 }
    local rotation = data.rotation or { x = 0, y = 0, z = 0 }
    AttachEntityToEntity(prop, parent, data.boneIndex or 0,
        offset.x, offset.y, offset.z,
        rotation.x, rotation.y, rotation.z,
        false, false, false, false, 2, true)

    PropAttach.active[data.attachmentId] = prop
end)

Obelisk.onServer('core:server:propattach-remove', function(data)
    local prop = PropAttach.active[data.attachmentId]
    if not prop then return end

    if DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        DeleteEntity(prop)
    end
    PropAttach.active[data.attachmentId] = nil
end)

--- Clean up every locally-spawned attachment prop when this resource stops
--- (e.g. hot-restart), matching core/server/bootstrap.lua's
--- `if resourceName == GetCurrentResourceName()` guard convention.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    for attachmentId, prop in pairs(PropAttach.active) do
        if DoesEntityExist(prop) then
            DetachEntity(prop, true, true)
            DeleteEntity(prop)
        end
        PropAttach.active[attachmentId] = nil
    end
end)
