--- IsAdmin Policy
--- Checks if player has admin permission

--- Policy validator function
--- @param source number Player server ID
--- @param resource table Resource being accessed {type, id}
--- @param config table Configuration from pivot data
--- @return boolean allowed
--- @return string reason Optional denial reason
local function isAdminValidator(source, resource, config)
    -- This integrates with FiveM's ACE permission system
    if IsPlayerAceAllowed(source, 'admin') then
        return true
    end
    
    return false, 'Admin permission required'
end

-- Register the policy
PolicyService.register('isAdmin', isAdminValidator, {
    description = 'Checks if player has admin permission'
})

print('[Policy] Registered isAdmin policy')
