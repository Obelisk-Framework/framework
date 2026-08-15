-- plugins/oblsk_propattach/client/PlacementTool.lua
--- Admin-only tool: aim at a live entity, raycast to find the nearest bone,
--- preview a prop attached there, nudge offset/rotation with the keyboard,
--- save. No NUI screen — on-screen DrawText readout + chat/console input
--- for the final point_name/slot_index, matching this repo's existing
--- admin-command input pattern (see oblsk_licenses' console-args commands).
local session = nil -- { entity, entityType, model, propHandle, boneIndex, boneName, offset, rotation }
local PendingSave = nil -- staged { model, boneIndex, offset, rotation } awaiting /attach-point-save

--- Minimal on-screen text helper (this repo has no shared DrawText3D
--- utility today per a codebase search during design) -- kept local to this
--- file since no other plugin needs it yet.
local function DrawText3D(x, y, z, text)
    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(x, y, z)
    if onScreen then
        SetTextFont(4)
        SetTextScale(0.3, 0.3)
        SetTextColour(255, 255, 255, 215)
        SetTextEntry("STRING")
        SetTextCentre(true)
        AddTextComponentString(text)
        DrawText(sx, sy)
    end
end

--- World-space position of `boneIndex` on `entity`.
local function boneWorldPos(entity, boneIndex)
    return GetWorldPositionOfEntityBone(entity, boneIndex)
end

--- Sweep the candidate bone-name list for `entityType`, returning the bone
--- index/name closest to `hitCoords`.
--- @param entity number
--- @param entityType string 'vehicle'|'ped'
--- @param hitCoords vector3
--- @return number boneIndex, string boneName
local function nearestBone(entity, entityType, hitCoords)
    local names = entityType == 'vehicle' and PropAttachConfig.VehicleBoneNames or PropAttachConfig.PedBoneNames

    local bestIndex, bestName, bestDist = 0, 'root', nil
    for _, name in ipairs(names) do
        local index = GetEntityBoneIndexByName(entity, name)
        if index ~= -1 then
            local pos = boneWorldPos(entity, index)
            local dist = #(pos - hitCoords)
            if not bestDist or dist < bestDist then
                bestIndex, bestName, bestDist = index, name, dist
            end
        end
    end
    return bestIndex, bestName
end

--- Raycast from the camera, returning (entity, entityType, hitCoords) or
--- nil if nothing was hit.
local function raycastEntity()
    local camCoords = GetGameplayCamCoord()
    local forward = GetGameplayCamRot(2)
    local rad = vector3(forward.x * (math.pi / 180), forward.y * (math.pi / 180), forward.z * (math.pi / 180))
    local direction = vector3(
        -math.sin(rad.z) * math.abs(math.cos(rad.x)),
        math.cos(rad.z) * math.abs(math.cos(rad.x)),
        math.sin(rad.x)
    )
    local destination = camCoords + direction * 10.0

    local ray = StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z, destination.x, destination.y, destination.z, 16, PlayerPedId(), 0)
    local _, hit, hitCoords, _, entity = GetShapeTestResult(ray)
    if not hit or entity == 0 then return nil end

    local entityType = 'ped'
    if GetEntityType(entity) == 2 then entityType = 'vehicle' end
    if GetEntityType(entity) == 3 then entityType = 'object' end

    return entity, entityType, hitCoords
end

local function startSession(model)
    local entity, entityType, hitCoords = raycastEntity()
    if not entity then
        print('[PropAttach] No entity in view to aim at.')
        return
    end
    if GetEntityModel(entity) ~= GetHashKey(model) then
        print('[PropAttach] Aimed entity does not match model "' .. model .. '".')
        return
    end
    if entityType == 'object' then
        print('[PropAttach] Object targets have no bones to sweep in v1 -- aim at a ped or vehicle.')
        return
    end

    local boneIndex, boneName = nearestBone(entity, entityType, hitCoords)

    local propModel = GetHashKey('prop_cs_burger_01') -- neutral preview prop, no gameplay meaning
    RequestModel(propModel)
    local waited = 0
    while not HasModelLoaded(propModel) and waited < 5000 do
        Citizen.Wait(10)
        waited = waited + 10
    end
    if not HasModelLoaded(propModel) then
        print('[PropAttach] Failed to load preview prop model, aborting placement session.')
        SetModelAsNoLongerNeeded(propModel)
        return
    end
    local prop = CreateObject(propModel, 0.0, 0.0, 0.0, false, false, true)
    SetModelAsNoLongerNeeded(propModel)
    AttachEntityToEntity(prop, entity, boneIndex, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)

    session = {
        entity = entity, entityType = entityType, model = model,
        propHandle = prop, boneIndex = boneIndex, boneName = boneName,
        offset = { x = 0.0, y = 0.0, z = 0.0 },
        rotation = { x = 0.0, y = 0.0, z = 0.0 },
    }
    print('[PropAttach] Editing "' .. model .. '" at bone "' .. boneName .. '" (#' .. boneIndex .. '). Arrows nudge X/Y, PageUp/PageDown nudge Z, hold Shift for rotation. Enter to save, Esc to cancel.')
end

local function applyOffset()
    if not session then return end
    AttachEntityToEntity(session.propHandle, session.entity, session.boneIndex,
        session.offset.x, session.offset.y, session.offset.z,
        session.rotation.x, session.rotation.y, session.rotation.z,
        false, false, false, false, 2, true)
end

local function endSession(save)
    if not session then return end
    if DoesEntityExist(session.propHandle) then
        DetachEntity(session.propHandle, true, true)
        DeleteEntity(session.propHandle)
    end

    if save then
        -- Chat/console input for the follow-up fields, matching this
        -- repo's existing admin-command convention of taking arguments
        -- rather than opening a form UI. Assigned synchronously (NOT inside
        -- a Citizen.CreateThread) -- `session` is set to nil right below,
        -- on this same tick, so a queued thread body would see it as nil.
        -- Simplest correct v1: prompt on the F8 console rather than
        -- building a chat suggestion/input box. A follow-up plugin can
        -- upgrade this to an NUI form without changing the save event.
        PendingSave = {
            model = session.model, boneIndex = session.boneIndex,
            offset = session.offset, rotation = session.rotation,
        }
        print('[PropAttach] Run: /attach-point-save <point_name> [slot_index] to save this placement.')
    end

    session = nil
end

RegisterCommand('attach-point-edit', function(_, args)
    local model = args[1]
    if not model then
        print('Usage: /attach-point-edit <model>')
        return
    end
    startSession(model)
end, false)

RegisterCommand('attach-point-save', function(_, args)
    if not PendingSave then
        print('[PropAttach] No pending placement -- run /attach-point-edit first, then Enter to stage a save.')
        return
    end
    local pointName = args[1]
    local slotIndex = tonumber(args[2]) or 0
    if not pointName then
        print('Usage: /attach-point-save <point_name> [slot_index]')
        return
    end

    Obelisk.emitServer('propattach:server:savePoint', PendingSave.model, pointName, slotIndex,
        PendingSave.boneIndex, PendingSave.offset, PendingSave.rotation)
    PendingSave = nil
end, false)

RegisterCommand('attach-point-cancel', function()
    endSession(false)
    PendingSave = nil
    print('[PropAttach] Cancelled.')
end, false)

RegisterKeyMapping('attach-point-cancel', 'Cancel attach point placement', 'keyboard', 'BACK')

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if session then
            local step = PropAttachConfig.OffsetStep
            local rotStep = PropAttachConfig.RotationStep
            local shift = IsControlPressed(0, 21) -- INPUT_SPRINT, doubles as the modifier here

            if IsDisabledControlJustPressed(0, 174) then -- INPUT_FRONTEND_LEFT
                if shift then session.rotation.z = session.rotation.z - rotStep else session.offset.x = session.offset.x - step end
                applyOffset()
            elseif IsDisabledControlJustPressed(0, 175) then -- INPUT_FRONTEND_RIGHT
                if shift then session.rotation.z = session.rotation.z + rotStep else session.offset.x = session.offset.x + step end
                applyOffset()
            elseif IsDisabledControlJustPressed(0, 172) then -- INPUT_FRONTEND_UP
                if shift then session.rotation.x = session.rotation.x + rotStep else session.offset.y = session.offset.y + step end
                applyOffset()
            elseif IsDisabledControlJustPressed(0, 173) then -- INPUT_FRONTEND_DOWN
                if shift then session.rotation.x = session.rotation.x - rotStep else session.offset.y = session.offset.y - step end
                applyOffset()
            elseif IsControlJustPressed(0, 10) then -- INPUT_FRONTEND_UP (PageUp equivalent varies by binding; documented via keymapping instead if this proves unreliable)
                session.offset.z = session.offset.z + step
                applyOffset()
            elseif IsControlJustPressed(0, 11) then
                session.offset.z = session.offset.z - step
                applyOffset()
            elseif IsControlJustPressed(0, 191) then -- INPUT_FRONTEND_ACCEPT (Enter)
                endSession(true)
            elseif IsControlJustPressed(0, 194) then -- INPUT_FRONTEND_CANCEL (Esc/Backspace)
                endSession(false)
            end

            local propCoords = GetEntityCoords(session.propHandle)
            DrawText3D(propCoords.x, propCoords.y, propCoords.z + 0.3, string.format(
                'bone: %s\noffset: %.2f, %.2f, %.2f\nrot: %.1f, %.1f, %.1f',
                session.boneName, session.offset.x, session.offset.y, session.offset.z,
                session.rotation.x, session.rotation.y, session.rotation.z))
        else
            Citizen.Wait(200)
        end
    end
end)

--- Clean up a live preview prop on resource stop (e.g. hot-restart), same
--- guard convention as core/server/bootstrap.lua's onResourceStop handler.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    endSession(false)
end)
