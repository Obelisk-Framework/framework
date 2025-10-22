--- WithinDistance Policy
--- Checks if player is within distance of coordinates

--- Policy validator function
--- @param source number Player server ID
--- @param resource table Resource being accessed {type, id}
--- @param config table Configuration from pivot data
--- @return boolean allowed
--- @return string reason Optional denial reason
local function withinDistanceValidator(source, resource, config)
    local maxDist = config.distance or 5.0
    local coords = config.coords -- {x, y, z}
    
    if not coords then
        return false, 'Invalid distance check configuration'
    end
    
    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)
    local dist = #(vector3(playerCoords.x, playerCoords.y, playerCoords.z) - 
                   vector3(coords.x, coords.y, coords.z))
    
    if dist > maxDist then
        return false, 'You are too far away'
    end
    
    return true
end

-- Register the policy
PolicyService.register('withinDistance', withinDistanceValidator, {
    description = 'Checks if player is within distance of coordinates'
})

print('[Policy] Registered withinDistance policy')
