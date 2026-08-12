-- plugins/oblsk_character-selection/client/main.lua
--- oblsk_character-selection - Client Main
--- Orchestrates the select/creator screen: spawns a preview ped near
--- Config.PreviewCoords on the SpawnManagerService 'connecting' stage,
--- relays list/create/delete/select requests from Vue to the server, and
--- live-applies appearance changes to the preview ped during creation.
print('[oblsk_character-selection] Client loading...')

local previewPed = nil
local previewGender = 'male'

local function spawnPreviewPed(gender)
    if previewPed and DoesEntityExist(previewPed) then
        DeleteEntity(previewPed)
    end
    local model = GetHashKey(gender == 'female' and 'mp_f_freemode_01' or 'mp_m_freemode_01')
    RequestModel(model)
    while not HasModelLoaded(model) do
        Citizen.Wait(0)
    end

    local c = Config.PreviewCoords
    previewPed = CreatePed(4, model, c.x, c.y, c.z - 1.0, c.heading, false, false)
    SetModelAsNoLongerNeeded(model)
    SetEntityInvincible(previewPed, true)
    FreezeEntityPosition(previewPed, true)
    SetBlockingOfNonTemporaryEvents(previewPed, true)
    previewGender = gender
    return previewPed
end

local function despawnPreviewPed()
    if previewPed and DoesEntityExist(previewPed) then
        DeleteEntity(previewPed)
        previewPed = nil
    end
end

AddEventHandler('obelisk:spawnStageChanged', function(stage)
    if stage == 'connecting' then
        spawnPreviewPed('male')
        local c = Config.PreviewCoords
        CharacterCameraService.start(c)
        WebView.focus()
        WebView.showGlobalElement('character-selection')
        WebView.emitServer('character-selection:list')
    elseif stage == 'spawned' then
        CharacterCameraService.stop()
        despawnPreviewPed()
        WebView.hideGlobalElement('character-selection')
        WebView.hide()
    end
end)

-- Vue -> Lua
WebView.on('character-selection:list', function()
    WebView.emitServer('character-selection:list')
end)

WebView.on('character-selection:create', function(data)
    WebView.emitServer('character-selection:create', data)
end)

WebView.on('character-selection:delete', function(data)
    WebView.emitServer('character-selection:delete', data.characterId)
end)

--- Confirming a character is a round trip: the client only asks, and does all
--- the ped work in the 'character-selection:selected' handler below, which is
--- the only place the server's stored appearance AND vitals (last-played
--- position) are actually available.
WebView.on('character-selection:select', function(data)
    WebView.emitServer('character-selection:select', data.characterId)
end)

--- Applies the confirmed character to the REAL player ped: model, appearance,
--- then last-played position from the server's vitals.
--- @param result table|nil { vitals = table|nil, appearance = table|nil }
local function spawnAsSelectedCharacter(result)
    local playerModel = GetHashKey(previewGender == 'female' and 'mp_f_freemode_01' or 'mp_m_freemode_01')
    RequestModel(playerModel)
    while not HasModelLoaded(playerModel) do
        Citizen.Wait(0)
    end
    SetPlayerModel(PlayerId(), playerModel)
    SetModelAsNoLongerNeeded(playerModel)

    -- SetPlayerModel replaces the ped, so the handle must be re-read.
    local ped = PlayerPedId()
    local appearance = Appearance.resolvePresetAppearance(previewGender, result and result.appearance)
    CharacterAppearanceService.apply(ped, appearance, previewGender)

    -- A character that has never been played has no stored position; fall
    -- back to the preview scene's coords, which is where the player already
    -- is. `dimension` is deliberately not applied here: routing buckets are
    -- server-owned (SetEntityRoutingBucket has no client equivalent).
    local vitals = result and result.vitals
    if vitals and vitals.x and vitals.y and vitals.z then
        SetEntityCoords(ped, vitals.x, vitals.y, vitals.z, false, false, false, false)
    else
        local c = Config.PreviewCoords
        SetEntityCoords(ped, c.x, c.y, c.z, false, false, false, false)
    end
end

--- Live preview during creation: { gender?, appearance?, cameraFraming?, cameraAngle?, wardrobeSlot? }
WebView.on('character-selection:preview-update', function(data)
    if not (previewPed and DoesEntityExist(previewPed)) then
        return
    end
    if data.gender and data.gender ~= previewGender then
        local coords = GetEntityCoords(previewPed)
        local heading = GetEntityHeading(previewPed)
        spawnPreviewPed(data.gender)
        SetEntityCoords(previewPed, coords.x, coords.y, coords.z)
        SetEntityHeading(previewPed, heading)
    end
    if data.appearance then
        -- The creator sends preset INDICES, the roster sends an already
        -- resolved stored appearance; resolvePresetAppearance handles both.
        CharacterAppearanceService.apply(previewPed, Appearance.resolvePresetAppearance(previewGender, data.appearance), previewGender)
    end
    if data.wardrobeSlot then
        -- optionIndex is the Vue v-for index (0-based); Lua's WARDROBE arrays
        -- are 1-based. Converted here, at the boundary.
        CharacterAppearanceService.applyWardrobeSlot(previewPed, previewGender, data.wardrobeSlot.key, (data.wardrobeSlot.optionIndex or 0) + 1)
    end
    if data.cameraFraming then
        CharacterCameraService.setFraming(data.cameraFraming)
    end
    if data.cameraAngle ~= nil then
        CharacterCameraService.setAngle(data.cameraAngle)
    end
end)

-- Server -> Lua -> Vue (straight relay).
-- WebView.emit(name, data) already wraps its single argument as
-- SendNUIMessage({ eventname, args = { data } }) and obelisk.js dispatches it
-- as cb(...args), so the payload must be passed through as-is — wrapping it
-- again here would deliver [[entries]] instead of [entries] in Vue.
for _, eventName in ipairs({
    'character-selection:list-result',
    'character-selection:created',
    'character-selection:create-failed',
    'character-selection:deleted',
}) do
    Obelisk.onClient(eventName, function(payload)
        WebView.emit(eventName, payload)
    end)
end

--- The only two-argument response: packed into one table so it still fits
--- WebView.emit's single-payload contract.
Obelisk.onClient('character-selection:selected', function(characterId, result)
    WebView.emit('character-selection:selected', { characterId = characterId, result = result })
    spawnAsSelectedCharacter(result)
end)

print('[oblsk_character-selection] Client loaded successfully!')
