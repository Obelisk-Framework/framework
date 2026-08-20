-- plugins/oblsk_anticheat/server/EventGuardService.lua
--- Validates net-event args against a declared schema and enforces a
--- per-player-per-event rate limit, before the real handler ever runs.
--- Pure logic — no net event registration lives here; callers (the
--- AnticheatService wiring task) call EventGuardService.validate() as the
--- first line of any Obelisk.onClient handler they want guarded.
EventGuardService = EventGuardService or {}

-- [playerId..':'..eventName] = { second = integer, count = integer }
EventGuardService._rateState = EventGuardService._rateState or {}

local function validateArg(value, fieldSchema)
    if type(value) ~= fieldSchema.type then
        return false, 'expected ' .. fieldSchema.type .. ', got ' .. type(value)
    end
    if fieldSchema.type == 'number' then
        if fieldSchema.min and value < fieldSchema.min then
            return false, 'value below min ' .. tostring(fieldSchema.min)
        end
        if fieldSchema.max and value > fieldSchema.max then
            return false, 'value above max ' .. tostring(fieldSchema.max)
        end
    end
    return true
end

local function checkRateLimit(playerId, eventName, nowSeconds)
    local key = tostring(playerId) .. ':' .. eventName
    local state = EventGuardService._rateState[key]
    local currentSecond = math.floor(nowSeconds)

    if not state or state.second ~= currentSecond then
        state = {second = currentSecond, count = 0}
        EventGuardService._rateState[key] = state
    end

    state.count = state.count + 1
    if state.count > Config.Anticheat.eventRateLimitPerSecond then
        return false, 'rate limit exceeded for ' .. eventName
    end
    return true
end

--- @param playerId number
--- @param eventName string
--- @param schema table list of {type, min?, max?}, matched positionally against args
--- @param args table positional args as received by the event handler
--- @param nowSeconds number|nil defaults to os.time(); pass explicitly in tests for determinism
--- @return boolean ok
--- @return string|nil reason set when ok is false
function EventGuardService.validate(playerId, eventName, schema, args, nowSeconds)
    for i, fieldSchema in ipairs(schema) do
        local value = args[i]
        if value == nil then
            return false, 'missing required arg #' .. i
        end
        local ok, reason = validateArg(value, fieldSchema)
        if not ok then
            return false, 'arg #' .. i .. ': ' .. reason
        end
    end

    return checkRateLimit(playerId, eventName, nowSeconds or os.time())
end

return EventGuardService
