-- core/server/Services/SecureEventService.lua
--- Stable, authenticated client-to-server event registration.
SecureEventService = SecureEventService or {}

local registrations = {}

local DEFAULT_MAX, DEFAULT_WINDOW = 20, 1000

local function positiveInteger(value)
    return type(value) == 'number' and value > 0 and value < math.huge and value == math.floor(value)
end

local function validName(name)
    return type(name) == 'string' and name ~= ''
end

local function config(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil end
    for _, key in ipairs({'validate', 'authorize'}) do
        if options[key] ~= nil and type(options[key]) ~= 'function' then return nil end
    end
    local limit = options.rateLimit
    if limit ~= nil then
        if type(limit) ~= 'table' or not positiveInteger(limit.max)
            or not positiveInteger(limit.windowMs) then return nil end
    end
    return {
        validate = options.validate,
        authorize = options.authorize,
        max = limit and limit.max or DEFAULT_MAX,
        windowMs = limit and limit.windowMs or DEFAULT_WINDOW,
    }
end

local function allowed(registration, nativeSource)
    local now = GetGameTimer()
    local bucket = registration.buckets[nativeSource]
    if not bucket or now < bucket.started or now - bucket.started >= registration.options.windowMs then
        bucket = { started = now, count = 0 }
        registration.buckets[nativeSource] = bucket
    end
    if bucket.count >= registration.options.max then return false end
    bucket.count = bucket.count + 1
    return true
end

function SecureEventService.startSession(_playerId, _ignoredSecret)
    -- Compatibility only. Stable event registrations are not session based.
end

--- Clears per-player rate buckets on disconnect; handlers stay registered.
--- @param playerId number
function SecureEventService.endSession(playerId)
    for _, registration in pairs(registrations) do
        registration.buckets[playerId] = nil
    end
end

--- Stable client events. The handler/guards must enforce domain rules and replay safety.
--- @param logicalEvent string
--- @param callback function(player, ...)
--- @param options table|nil Synchronous validate/authorize(player, ...) guards must return true;
--- rateLimit = {max = positive integer, windowMs = positive integer} (default 20/1000).
function SecureEventService.onClientSecure(logicalEvent, callback, options)
    assert(validName(logicalEvent), 'logicalEvent must be a non-empty string')
    assert(type(callback) == 'function', 'callback must be a function')
    local normalized = config(options)
    assert(normalized, 'invalid SecureEventService options')

    local registration = registrations[logicalEvent]
    if registration then
        registration.callback = callback
        registration.options = normalized
        return true
    end

    registration = { callback = callback, options = normalized, buckets = {} }
    registrations[logicalEvent] = registration
    local eventName = 'obelisk:secure:client_to_server:' .. logicalEvent
    RegisterNetEvent(eventName)
    AddEventHandler(eventName, function(...)
        -- `source` is the native event source; capture it before any calls.
        local nativeSource = source
        if not positiveInteger(nativeSource) then return end

        local player = PlayerService and PlayerService.get and PlayerService.get(nativeSource) or nil
        if not player then return end
        if not allowed(registration, nativeSource) then return end

        local payload = table.pack(...)
        local current = registration.options
        local callback = registration.callback
        if current.validate then
            local ok, result = pcall(current.validate, player, table.unpack(payload, 1, payload.n))
            if not ok or result ~= true then return end
        end
        if current.authorize then
            local ok, result = pcall(current.authorize, player, table.unpack(payload, 1, payload.n))
            if not ok or result ~= true then return end
        end

        local ok, err = pcall(callback, player, table.unpack(payload, 1, payload.n))
        if not ok then
            print('[SecureEventService] callback error for ' .. logicalEvent .. ': ' .. tostring(err))
        end
    end)
    return true
end

function SecureEventService.emitClientSecure(logicalEvent, player, ...)
    if not validName(logicalEvent) or not player or type(player.getSource) ~= 'function' then return false end
    local playerId = player:getSource()
    if not positiveInteger(playerId) then return false end
    TriggerClientEvent('obelisk:secure:server_to_client:' .. logicalEvent, playerId, ...)
    return true
end

return SecureEventService
