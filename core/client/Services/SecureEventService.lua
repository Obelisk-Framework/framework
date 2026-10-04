-- core/client/Services/SecureEventService.lua
--- Stable client/server secure event names. The compatibility session API is
--- intentionally a no-op: stable names need no handshake or client state.
SecureEventService = SecureEventService or {}

local registeredCallbacks = {}

local function eventName(direction, logicalEvent)
    return 'obelisk:secure:' .. direction .. ':' .. logicalEvent
end

local function validateRegistration(logicalEvent, callback)
    if type(logicalEvent) ~= 'string' or logicalEvent == '' then
        error('SecureEventService event name must be a non-empty string', 3)
    end
    if type(callback) ~= 'function' then
        error('SecureEventService callback must be a function', 3)
    end
end

function SecureEventService.startSession(_ignoredSecret)
    -- Retained for compatibility with callers using the former handshake API.
end

--- Registers exactly one server->client handler for a logical event.
function SecureEventService.onServerSecure(logicalEvent, callback)
    validateRegistration(logicalEvent, callback)

    local alreadyRegistered = registeredCallbacks[logicalEvent] ~= nil
    registeredCallbacks[logicalEvent] = callback
    if alreadyRegistered then return end

    local name = eventName('server_to_client', logicalEvent)
    RegisterNetEvent(name)
    AddEventHandler(name, function(...)
        if source ~= 65535 then
            return
        end

        local ok, err = pcall(registeredCallbacks[logicalEvent], ...)
        if not ok then
            print('[SecureEventService] callback error for ' .. name .. ': ' .. tostring(err))
        end
    end)
end

--- Sends a client->server event immediately using its stable native name.
function SecureEventService.emitServerSecure(logicalEvent, ...)
    if type(logicalEvent) ~= 'string' or logicalEvent == '' then
        error('SecureEventService event name must be a non-empty string', 2)
    end
    TriggerServerEvent(eventName('client_to_server', logicalEvent), ...)
end

return SecureEventService
