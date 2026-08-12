-- plugins/oblsk_character-selection/server/main.lua
--- oblsk_character-selection - Server Main
--- Request/response events for the roster UI. Not routed through
--- ActionService (fire-and-forget, no response channel) since the UI needs
--- data back for list/create/select.
print('[oblsk_character-selection] Loading...')

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
    CharacterSelectionService.deleteCharacter(characterId)
    Obelisk.emitClient('character-selection:deleted', source, characterId)
end)

Obelisk.onServer('character-selection:select', function(characterId)
    local source = source
    local result = CharacterSelectionService.selectCharacter(source, characterId)
    Obelisk.emitClient('character-selection:selected', source, characterId, result)
    SpawnManagerService.readyToSpawn(source, characterId)
end)

print('[oblsk_character-selection] Loaded successfully!')
