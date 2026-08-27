-- core/client/Services/SecureEventService.lua
--- Client half of the one-time event naming scheme. Mirrors the server's
--- counter bookkeeping so both sides derive the same next name without
--- ever transmitting the counter itself. See
--- core/server/Services/SecureEventService.lua for the receive-side
--- rolling registration this mirrors, and
--- docs/superpowers/specs/2026-08-20-anticheat-design.md for the design.
SecureEventService = SecureEventService or {}

local session = nil -- { secret, counters = {[direction..':'..logicalEvent]=n}, pendingHandlers = {...} }
local registeredCallbacks = {}

local function counterKey(direction, logicalEvent)
    return direction .. ':' .. logicalEvent
end

function SecureEventService.startSession(sessionSecret)
    session = { secret = sessionSecret, counters = {}, pendingHandlers = {} }
    for logicalEvent, callback in pairs(registeredCallbacks) do
        SecureEventService._armNext(logicalEvent, callback)
    end
end

function SecureEventService._armNext(logicalEvent, callback)
    if not session then return end

    local key = counterKey('server_to_client', logicalEvent)
    local counter = session.counters[key] or 0
    local name = EventNaming.deriveName(session.secret, logicalEvent, 'server_to_client', counter)

    local previousRef = session.pendingHandlers[key]
    if previousRef then
        RemoveEventHandler(previousRef)
    end

    RegisterNetEvent(name)
    local handlerRef
    handlerRef = AddEventHandler(name, function(...)
        session.counters[key] = counter + 1
        SecureEventService._armNext(logicalEvent, callback)
        callback(...)
    end)
    session.pendingHandlers[key] = handlerRef
end

--- Registers a handler for a server->client logical event. Client only.
function SecureEventService.onServerSecure(logicalEvent, callback)
    registeredCallbacks[logicalEvent] = callback
    if session then
        SecureEventService._armNext(logicalEvent, callback)
    end
end

--- Sends to the server using the current one-time name for this logical
--- event, then advances the counter.
function SecureEventService.emitServerSecure(logicalEvent, ...)
    if not session then
        print('[SecureEventService] emitServerSecure: no active session yet')
        return
    end

    local key = counterKey('client_to_server', logicalEvent)
    local counter = session.counters[key] or 0
    local name = EventNaming.deriveName(session.secret, logicalEvent, 'client_to_server', counter)
    session.counters[key] = counter + 1

    TriggerServerEvent(name, ...)
end

return SecureEventService
