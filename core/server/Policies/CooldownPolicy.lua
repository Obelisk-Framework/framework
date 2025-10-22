--- Cooldown Policy
--- Checks if player is on cooldown for a resource

local cooldowns = {}

--- Policy validator function
--- @param source number Player server ID
--- @param resource table Resource being accessed {type, id}
--- @param config table Configuration from pivot data
--- @return boolean allowed
--- @return string reason Optional denial reason
local function cooldownValidator(source, resource, config)
    local duration = config.duration or 5000 -- milliseconds
    local key = source .. ':' .. resource.type .. ':' .. tostring(resource.id)
    
    local lastUse = cooldowns[key]
    local now = GetGameTimer()
    
    if lastUse and (now - lastUse) < duration then
        local remaining = math.ceil((duration - (now - lastUse)) / 1000)
        return false, 'Please wait ' .. remaining .. ' seconds'
    end
    
    cooldowns[key] = now
    return true
end

-- Register the policy
PolicyService.register('cooldown', cooldownValidator, {
    description = 'Checks if player is on cooldown for a resource'
})

print('[Policy] Registered cooldown policy')
