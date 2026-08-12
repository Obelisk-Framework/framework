-- plugins/oblsk_character-selection/server/main.lua
--- oblsk_character-selection - Server Main
--- Request/response events for the roster UI. Not routed through
--- ActionService (fire-and-forget, no response channel) since the UI needs
--- data back for list/create/select.
print('[oblsk_character-selection] Loading...')

--- characterId arrives straight from the client, so every handler acting on
--- one must confirm the calling player's account actually owns it —
--- otherwise any connected player could delete or "become" an arbitrary
--- character just by sending its id.
--- @param source number
--- @param characterId number
--- @return boolean
local function ownsCharacter(source, characterId)
    local accountId = AccountService.getAccountId(source)
    if not accountId or characterId == nil then
        return false
    end
    return CharacterSelectionService.getOwningAccountId(characterId) == accountId
end

Obelisk.onServer('character-selection:list', function()
    local source = source
    local accountId = AccountService.getAccountId(source)
    if not accountId then
        return
    end
    Obelisk.emitClient('character-selection:list-result', source, CharacterSelectionService.listWithAppearance(accountId))
end)

Obelisk.onServer('character-selection:create', function(attributes)
    local source = source
    local accountId = AccountService.getAccountId(source)
    if not accountId then
        return
    end

    local character, err = CharacterSelectionService.createCharacter(accountId, attributes)
    if not character then
        Obelisk.emitClient('character-selection:create-failed', source, err)
        return
    end

    Obelisk.emitClient('character-selection:created', source, character.attributes)
end)

Obelisk.onServer('character-selection:delete', function(characterId)
    local source = source
    if not ownsCharacter(source, characterId) then
        return
    end
    CharacterSelectionService.deleteCharacter(characterId)
    Obelisk.emitClient('character-selection:deleted', source, characterId)
end)

Obelisk.onServer('character-selection:select', function(characterId)
    local source = source
    if not ownsCharacter(source, characterId) then
        return
    end
    local result = CharacterSelectionService.selectCharacter(source, characterId)
    Obelisk.emitClient('character-selection:selected', source, characterId, result)
    SpawnManagerService.readyToSpawn(source, characterId)
end)

print('[oblsk_character-selection] Loaded successfully!')
