--- PlayerService - server-side registry of Player objects, one per connected
--- source, keyed by source, created on playerJoining and removed on
--- playerDropped. See docs/superpowers/specs/2026-08-15-player-obelisk-foundation-design.md.
PlayerService = {}
PlayerService.registry = {} -- source(number) -> Player

local Player = {}
Player.__index = Player

local IDENTIFIER_TYPES = { 'license', 'discord', 'steam', 'fivem', 'ip' }

function Player.new(source)
    local identifiers = {}
    for _, t in ipairs(IDENTIFIER_TYPES) do
        identifiers[t] = GetPlayerIdentifierByType(source, t)
    end
    return setmetatable({
        source = source,
        name = GetPlayerName(source),
        identifiers = identifiers,
        account = nil,   -- set by the Account-link follow-up spec
        character = nil, -- set by the Character-link follow-up spec
    }, Player)
end

--- @return number the raw FXServer connection id
function Player:getSource()
    return self.source
end

--- @param identifierType string one of 'license', 'discord', 'steam', 'fivem', 'ip'
--- @return string|nil
function Player:getIdentifier(identifierType)
    return self.identifiers[identifierType]
end

--- @return string
function Player:getName()
    return self.name
end

--- @param data table notification payload, see NotificationService
function Player:notify(data)
    NotificationService.notify(self, data)
end

--- @param event string
function Player:emit(event, ...)
    Obelisk.emitClient(event, self, ...)
end

--- @param source number
--- @return Player|nil
function PlayerService.get(source)
    return PlayerService.registry[source]
end

Obelisk.on('playerJoining', function()
    local source = source
    PlayerService.registry[source] = Player.new(source)
    SpawnManagerService.markConnecting(PlayerService.registry[source])
    local secretBytes = {}
    for i = 1, 32 do
        secretBytes[i] = string.char(math.random(0, 255))
    end
    local sessionSecret = table.concat(secretBytes)
    SecureEventService.startSession(source, sessionSecret)
    TriggerClientEvent('obelisk:secureHandshake', source, sessionSecret)
    print('[PlayerService] Player ' .. source .. ' joined')
end)

Obelisk.on('playerDropped', function()
    SecureEventService.endSession(source)
    print('[PlayerService] Player ' .. source .. ' left')
    PlayerService.registry[source] = nil
end)

return PlayerService
