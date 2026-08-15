-- plugins/oblsk_barber/client/main.lua
--- Barber Plugin - Client Main
print('[Barber] Client loading...')

local currentGender = 'male'
local currentChairId = nil
local currentAppearance = {}

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
    currentAppearance = data.appearance or {}
    -- Appearance is oblsk_character-selection's shared/appearance.lua
    -- global: every plugin is globbed into one Lua state by
    -- core/fxmanifest.lua (AGENTS.md), so it's directly readable here --
    -- barber never keeps its own copy of the hair catalog.
    local hairStyles = Appearance.HAIR_STYLES[currentGender]
    WebView.emit('barber:sync', {
        chairId = data.chairId,
        gender = currentGender,
        hairStyles = hairStyles,
        sections = data.sections,
        hairPrice = data.hairPrice,
    })
end)

--- Applies the server's authoritative, freshly-persisted appearance to the
--- live ped before relaying to the NUI. Without this, non-hair purchases
--- (and any pick the server clamped/rejected) were charged and stored but
--- never actually shown on the player until the next respawn.
Obelisk.onClient('barber:server:chargeResult', function(result)
    if result and result.ok and result.appearance then
        currentAppearance = result.appearance
        CharacterAppearanceService.apply(PlayerPedId(), currentAppearance, currentGender)
    end
    WebView.emit('barber:chargeResult', result)
end)

--- Live preview as the player picks a style in the UI, before paying.
--- @param data table { appearance table partial keys }
WebView.on('barber:preview', function(data)
    local ped = PlayerPedId()
    local partial = data.appearance or {}
    for key, value in pairs(partial) do
        currentAppearance[key] = value
    end
    CharacterAppearanceService.apply(ped, currentAppearance, currentGender)
end)

WebView.on('barber:charge', function(data)
    WebView.emitServer('barber:client:charge', data.touchedSectionIds, data.method, data.cardId, currentGender, data.appearanceChanges, data.mult)
end)

WebView.on('barber:applyFree', function(data)
    WebView.emitServer('barber:client:applyFree', currentGender, data.appearanceChanges)
end)

print('[Barber] Client loaded successfully!')
