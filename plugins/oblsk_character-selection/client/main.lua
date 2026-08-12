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

TriggerEvent('obelisk:spawnStageChanged', nil) -- no-op registration guard, real handler below

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

WebView.on('character-selection:select', function(data)
    if previewPed and DoesEntityExist(previewPed) then
        local appearance = data.appearance or Appearance.DEFAULT_APPEARANCE(previewGender)
        local pedCoords = GetEntityCoords(previewPed)
        SetEntityCoords(PlayerPedId(), pedCoords.x, pedCoords.y, pedCoords.z)
        SetPlayerModel(PlayerId(), GetHashKey(previewGender == 'female' and 'mp_f_freemode_01' or 'mp_m_freemode_01'))
        CharacterAppearanceService.apply(PlayerPedId(), appearance, previewGender)
    end
    WebView.emitServer('character-selection:select', data.characterId)
end)

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
        CharacterAppearanceService.apply(previewPed, data.appearance, previewGender)
    end
    if data.wardrobeSlot then
        CharacterAppearanceService.applyWardrobeSlot(previewPed, previewGender, data.wardrobeSlot.key, data.wardrobeSlot.optionIndex)
    end
    if data.cameraFraming then
        CharacterCameraService.setFraming(data.cameraFraming)
    end
    if data.cameraAngle ~= nil then
        CharacterCameraService.setAngle(data.cameraAngle)
    end
end)

-- Server -> Lua -> Vue (straight relay)
for _, eventName in ipairs({
    'character-selection:list-result',
    'character-selection:created',
    'character-selection:create-failed',
    'character-selection:deleted',
    'character-selection:selected',
}) do
    Obelisk.onClient(eventName, function(...)
        WebView.emit(eventName, { ... })
    end)
end

print('[oblsk_character-selection] Client loaded successfully!')
