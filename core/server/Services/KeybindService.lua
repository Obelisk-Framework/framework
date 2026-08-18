--- KeybindService - resolves the key bound to an action via a three-tier
--- model: action-declared default -> account override -> character
--- override. Overrides are stored in oblsk_preferences (`keybind:<actionId>`
--- preference keys); the default lives on `actions.options.default_key`,
--- set by whichever plugin calls ActionService.register. See
--- docs/superpowers/specs/2026-08-13-keybind-layering-design.md.
KeybindService = {}

local VALID_SCOPES = { account = true, character = true }

--- @param actionId string
--- @param accountId number|nil
--- @param characterId number|nil
--- @return string|nil key
function KeybindService.resolve(actionId, accountId, characterId)
    local action = ActionService.get(actionId)
    local key = action and action.options and action.options.default_key or nil

    if accountId then
        local override = PreferenceService.get('account', accountId, 'keybind:' .. actionId)
        if override ~= nil then key = override end
    end

    if characterId then
        local override = PreferenceService.get('character', characterId, 'keybind:' .. actionId)
        if override ~= nil then key = override end
    end

    return key
end

--- @param accountId number|nil
--- @param characterId number|nil
--- @return table {actionId -> key}
function KeybindService.resolveAll(accountId, characterId)
    local resolved = {}
    for actionId in pairs(ActionService.getAll()) do
        resolved[actionId] = KeybindService.resolve(actionId, accountId, characterId)
    end
    return resolved
end

--- @param scope string 'account'|'character'
--- @param ownerId number
--- @param actionId string
--- @param key string
function KeybindService.setOverride(scope, ownerId, actionId, key)
    if not VALID_SCOPES[scope] then
        error('KeybindService.setOverride: invalid scope "' .. tostring(scope) .. '"')
    end
    PreferenceService.set(scope, ownerId, 'keybind:' .. actionId, key)
end

--- @param scope string 'account'|'character'
--- @param ownerId number
--- @param actionId string
function KeybindService.clearOverride(scope, ownerId, actionId)
    if not VALID_SCOPES[scope] then
        error('KeybindService.clearOverride: invalid scope "' .. tostring(scope) .. '"')
    end
    PreferenceService.clear(scope, ownerId, 'keybind:' .. actionId)
end

--- Resolve source -> accountId/characterId softly: AccountService/
--- CharacterService are optional modules, so a core-only server (or one
--- mid-boot before they've loaded) still resolves default-only keybinds.
--- @param source number
--- @return number|nil accountId, number|nil characterId
local function resolveIdsForSource(source)
    local accountId = AccountService and AccountService.getAccountId(source) or nil
    local characterId = CharacterService and CharacterService.getActiveCharacterId(source) or nil
    return accountId, characterId
end

--- Send this player's fully-resolved keybind map to their client.
--- @param player Player
function KeybindService.syncToClient(player)
    local accountId, characterId = resolveIdsForSource(player:getSource())
    local resolved = KeybindService.resolveAll(accountId, characterId)
    player:emit('core:server:keybinds-sync', resolved)
end

--- Client pressed a key already known (client-side) to map to this action.
--- @param player Player
--- @param actionId string
function KeybindService.handlePress(player, actionId)
    if not ActionService.exists(actionId) then
        print('[KeybindService] Error: Action not found: ' .. tostring(actionId))
        return
    end
    ActionService.execute(player, actionId, {})
end

--- Net event: Client requests keybind sync
Obelisk.onClient('core:client:keybinds-requestSync', function(player)
    KeybindService.syncToClient(player)
end)

--- Net event: Client pressed a keybind
Obelisk.onClient('core:client:keybinds-pressed', function(player, actionId)
    KeybindService.handlePress(player, actionId)
end)

--- On player connect, sync keybinds
Obelisk.on('playerJoining', function()
    local source = source
    SetTimeout(1000, function()
        local player = PlayerService.get(source)
        if player then
            KeybindService.syncToClient(player)
        end
    end)
end)

return KeybindService
