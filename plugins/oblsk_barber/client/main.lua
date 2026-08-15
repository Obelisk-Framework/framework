-- plugins/oblsk_barber/client/main.lua
--- Barber Plugin - Client Main
print('[Barber] Client loading...')

local currentGender = 'male'
local currentChairId = nil

--- @return string 'male' | 'female' — best-effort guess from the player's
---   current ped model; oblsk_character-selection doesn't expose the
---   active character's stored gender directly, so this reads it off the
---   live ped the same way CharacterAppearanceService callers already do.
local function currentPlayerGender()
    local model = GetEntityModel(PlayerPedId())
    return model == GetHashKey('mp_f_freemode_01') and 'female' or 'male'
end

Obelisk.onClient('barber:server:sync', function(data)
    currentChairId = data.chairId
    currentGender = currentPlayerGender()
    local hairStyles = exports['oblsk_character-selection']:getHairStyles(currentGender)
    WebView.emit('barber:sync', {
        chairId = data.chairId,
        gender = currentGender,
        hairStyles = hairStyles,
        sections = data.sections,
        hairPrice = data.hairPrice,
    })
end)

Obelisk.onClient('barber:server:chargeResult', function(result)
    WebView.emit('barber:chargeResult', result)
end)

--- Live preview as the player picks a style in the UI, before paying.
--- @param data table { appearance table partial keys }
WebView.on('barber:preview', function(data)
    local ped = PlayerPedId()
    local Appearance = exports['oblsk_character-selection']
    -- getHairStyles above already gave the UI real drawables/labels; the UI
    -- sends back a full appearance-shaped partial (native-valued, not
    -- preset indices) so this can apply it directly without re-resolving.
    local current = data.appearance or {}
    exports['oblsk_character-selection']:applyAppearance(ped, current, currentGender)
end)

WebView.on('barber:charge', function(data)
    WebView.emitServer('barber:client:charge', data.touchedSectionIds, data.method, data.cardId, currentGender, data.appearanceChanges)
end)

WebView.on('barber:applyFree', function(data)
    WebView.emitServer('barber:client:applyFree', currentGender, data.appearanceChanges)
end)

print('[Barber] Client loaded successfully!')
