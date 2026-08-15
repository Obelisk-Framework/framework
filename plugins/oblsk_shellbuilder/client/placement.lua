-- plugins/oblsk_shellbuilder/client/placement.lua
--- Placement - camera-raycast aim mode for the shell editor. Selecting an
--- item in the dock arms it (see ShellEditor.vue); a bind while armed
--- releases the NUI cursor and hands the camera back to the player to aim,
--- confirming placement/removal via the same shellbuilder:client:place/
--- removeObject server events the original plugin already wired end to end.
Placement = {}

local armedItemKey = nil
local armedLocked = false
local wreckMode = false
local aiming = false
local heading = 0.0
local currentShellId = nil

--- Set by ShellEditor.vue's editSync handler relaying the shell id, via a
--- small WebView.on('shellbuilder:setShellId', ...) added alongside arm/
--- disarm/wreck in client/main.lua (Step 1) -- add that handler too:
--- WebView.on('shellbuilder:setShellId', function(data) Placement.setShellId(data.shellId) end)
function Placement.setShellId(shellId)
    currentShellId = shellId
end

function Placement.arm(itemKey, locked)
    armedItemKey = itemKey
    armedLocked = locked and true or false
end

function Placement.disarm()
    armedItemKey = nil
    if aiming then Placement.cancelAim() end
end

function Placement.setWreckMode(enabled)
    wreckMode = enabled and true or false
end

local function rayHitPoint()
    local camCoord = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)
    local rad = vector3(camRot.x * (math.pi / 180.0), camRot.y * (math.pi / 180.0), camRot.z * (math.pi / 180.0))
    local direction = vector3(
        -math.sin(rad.z) * math.abs(math.cos(rad.x)),
        math.cos(rad.z) * math.abs(math.cos(rad.x)),
        math.sin(rad.x)
    )
    local maxDistance = 15.0
    local destination = camCoord + direction * maxDistance

    local rayHandle = StartShapeTestRay(camCoord.x, camCoord.y, camCoord.z, destination.x, destination.y, destination.z, -1, PlayerPedId(), 0)
    local _, hit, endCoords, _, entityHit = GetShapeTestResult(rayHandle)

    if hit == 1 then
        return endCoords.x, endCoords.y, endCoords.z, entityHit
    end
    return destination.x, destination.y, destination.z, 0
end

function Placement.startAim()
    if not currentShellId then return end
    if not armedItemKey and not wreckMode then return end
    WebView.hideCursor()
    aiming = true
    heading = GetEntityHeading(PlayerPedId())
end

function Placement.cancelAim()
    aiming = false
    WebView.showCursor()
end

--- Resolves a hit entity handle back to its shell_objects id via the
--- client EntityStreamerService's spawned-entity map (entityId
--- "<groupKey>:object_<id>" -> handle). See EntityStreamerService.entities
--- on the client (keyed by the same entityId strings
--- EntityStreamerService.registerGroupEntity mints server-side,
--- "<groupKey>:object_<shell_objects.id>" -- namespaced by the shell's group
--- key so it can never collide with an ordinary world object's id in the
--- same flat client-side table). The group key prefix varies per shell, so
--- match the suffix rather than anchoring the whole string.
local function resolveShellObjectId(entityHandle)
    for entityId, entry in pairs(EntityStreamerService.entities) do
        if entry.handle == entityHandle then
            local numericId = entityId:match(':object_(%d+)$')
            if numericId then return tonumber(numericId) end
        end
    end
    return nil
end

function Placement.confirm()
    if not aiming then return end
    local x, y, z, entityHit = rayHitPoint()

    if wreckMode then
        local objectId = resolveShellObjectId(entityHit)
        if objectId then
            Obelisk.emitServer('shellbuilder:client:removeObject', currentShellId, objectId)
        end
    elseif armedItemKey then
        Obelisk.emitServer('shellbuilder:client:place', currentShellId, armedItemKey, x, y, z, heading, 0, nil, armedLocked)
    end
end

-- Controls this mode repurposes: 24 (attack/left-click, confirm), 25
-- (aim/right-click, cancel), 44 (Q, normally cover), 38 (E, normally
-- pickup/vault). Disabled every frame while aiming so their default GTA
-- behavior (firing a weapon, taking cover, vaulting) doesn't also fire
-- alongside the aim-mode action; ESC (322) is left enabled since nothing
-- else in this mode depends on its default behavior being suppressed.
local AIM_CONTROLS = { 24, 25, 44, 38 }

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        if aiming then
            for _, control in ipairs(AIM_CONTROLS) do
                DisableControlAction(0, control, true)
            end

            if IsDisabledControlJustPressed(0, 24) then -- INPUT_ATTACK (left click)
                Placement.confirm()
            elseif IsDisabledControlJustPressed(0, 25) or IsControlJustPressed(0, 322) then -- INPUT_AIM (right click) / ESC
                Placement.cancelAim()
            elseif IsDisabledControlJustPressed(0, 44) then -- INPUT_COVER (Q), rotate left
                heading = (heading - 5.0) % 360.0
            elseif IsDisabledControlJustPressed(0, 38) then -- INPUT_PICKUP (E), rotate right
                heading = (heading + 5.0) % 360.0
            end
        end
    end
end)

return Placement
