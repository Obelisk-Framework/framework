-- core/server/Services/SecureEventService.lua
--- Server half of the one-time event naming scheme. Every logical event
--- registered via onClientSecure gets exactly one live net event handler
--- PER SESSION at any moment — the name for the next expected send — and
--- that handler re-registers the following name before invoking the
--- caller's callback, so the window where no handler is registered is zero.
--- See docs/superpowers/specs/2026-08-20-anticheat-design.md
--- ("Event-name randomization") for the full design rationale.
SecureEventService = SecureEventService or {}

-- [playerId] = { secret, counters = {[direction..':'..logicalEvent]=n}, pendingHandlers = {...} }
SecureEventService._sessions = SecureEventService._sessions or {}

-- Registered once per logicalEvent via onClientSecure; replayed for every
-- session (including sessions that start after the call).
local registeredCallbacks = {}

local function counterKey(direction, logicalEvent)
    return direction .. ':' .. logicalEvent
end

function SecureEventService.startSession(playerId, sessionSecret)
    SecureEventService._sessions[playerId] = {
        secret = sessionSecret,
        counters = {},
        pendingHandlers = {},
    }
    for logicalEvent, callback in pairs(registeredCallbacks) do
        SecureEventService._armNext(playerId, logicalEvent, callback)
    end
end

function SecureEventService.endSession(playerId)
    local session = SecureEventService._sessions[playerId]
    if not session then return end
    for _, handlerRef in pairs(session.pendingHandlers) do
        RemoveEventHandler(handlerRef)
    end
    SecureEventService._sessions[playerId] = nil
end

--- Registers the net event handler for the NEXT expected one-time name for
--- this (playerId, logicalEvent) pair, removing whatever was registered
--- before it. Exposed as a module function (not local) so both
--- startSession and the rolling re-arm after receipt can call it.
function SecureEventService._armNext(playerId, logicalEvent, callback)
    local session = SecureEventService._sessions[playerId]
    if not session then return end

    local key = counterKey('client_to_server', logicalEvent)
    local counter = session.counters[key] or 0
    local name = EventNaming.deriveName(session.secret, logicalEvent, 'client_to_server', counter)

    local previousRef = session.pendingHandlers[key]
    if previousRef then
        RemoveEventHandler(previousRef)
    end

    RegisterNetEvent(name)
    local handlerRef
    -- Net events are registered by NAME only — FXServer will invoke this
    -- handler for whichever client actually triggers `name`, not
    -- necessarily the `playerId` this name was armed for. Always resolve
    -- the player from the FXServer-native global `source` (matching
    -- Obelisk.onClient's convention exactly), never from the closure —
    -- otherwise a client who learns/guesses another player's one-time name
    -- would have their payload misattributed to the intended player.
    handlerRef = AddEventHandler(name, function(...)
        session.counters[key] = counter + 1
        -- Re-arm the next name before invoking the callback: if the
        -- callback yields or triggers further events, the next expected
        -- name must already be live.
        SecureEventService._armNext(playerId, logicalEvent, callback)

        local player = PlayerService.get(source)
        if not player then
            print('[SecureEventService] dropped ' .. logicalEvent .. ': no Player for source ' .. tostring(source))
            return
        end
        callback(player, ...)
    end)
    session.pendingHandlers[key] = handlerRef
end

--- Registers a handler for a client->server logical event across every
--- current and future session. Server only.
function SecureEventService.onClientSecure(logicalEvent, callback)
    registeredCallbacks[logicalEvent] = callback
    for playerId in pairs(SecureEventService._sessions) do
        SecureEventService._armNext(playerId, logicalEvent, callback)
    end
end

--- Sends to one client using its current one-time name for this logical
--- event, then advances the counter so the next send gets a fresh name.
function SecureEventService.emitClientSecure(logicalEvent, player, ...)
    local playerId = player:getSource()
    local session = SecureEventService._sessions[playerId]
    if not session then
        print('[SecureEventService] emitClientSecure: no session for player ' .. tostring(playerId))
        return
    end

    local key = counterKey('server_to_client', logicalEvent)
    local counter = session.counters[key] or 0
    local name = EventNaming.deriveName(session.secret, logicalEvent, 'server_to_client', counter)
    session.counters[key] = counter + 1

    TriggerClientEvent(name, playerId, ...)
end

return SecureEventService
