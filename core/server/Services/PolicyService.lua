--- PolicyService - Composable authorization middleware
--- Policies are functions that validate if a player can perform an action
--- Uses database tables for policy attachments: action_policy, interaction_policy
PolicyService = {}
PolicyService.registry = {}

--- Register a policy validator
--- @param policyId string Unique policy identifier
--- @param validator function function(source, resource, config) return boolean, reason
--- @param options table Optional metadata
function PolicyService.register(policyId, validator, options)
    if PolicyService.registry[policyId] then
        print('[PolicyService] Warning: Overwriting existing policy: ' .. policyId)
    end
    
    PolicyService.registry[policyId] = {
        id = policyId,
        validator = validator,
        options = options or {}
    }
    
    print('[PolicyService] Registered policy: ' .. policyId)
end

--- Attach a policy to a resource (stores in database)
--- @param resourceType string 'interaction' or 'action'
--- @param resourceId any Resource identifier (interaction_id or action_id)
--- @param policyId string Policy to attach
--- @param config table Optional pivot data for policy configuration
function PolicyService.attach(resourceType, resourceId, policyId, config)
    if not PolicyService.registry[policyId] then
        print('[PolicyService] Error: Policy not found: ' .. policyId)
        return false
    end
    
    local table_name = resourceType .. '_policy'
    local id_column = resourceType .. '_id'
    
    -- Check if already attached
    local existing = Database.querySync(
        'SELECT * FROM ' .. table_name .. ' WHERE ' .. id_column .. ' = ? AND policy_id = ?',
        {resourceId, policyId}
    )
    
    if existing and #existing > 0 then
        -- Update existing
        Database.updateSync(
            'UPDATE ' .. table_name .. ' SET data = ?, updated_at = ? WHERE ' .. id_column .. ' = ? AND policy_id = ?',
            {json.encode(config or {}), Database.now(), resourceId, policyId}
        )
        print('[PolicyService] Updated policy ' .. policyId .. ' for ' .. resourceType .. '#' .. tostring(resourceId))
    else
        -- Insert new
        Database.insertSync(
            'INSERT INTO ' .. table_name .. ' (' .. id_column .. ', policy_id, data, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
            {resourceId, policyId, json.encode(config or {}), Database.now(), Database.now()}
        )
        print('[PolicyService] Attached policy ' .. policyId .. ' to ' .. resourceType .. '#' .. tostring(resourceId))
    end
    
    return true
end

--- Detach a policy from a resource (removes from database)
--- @param resourceType string 'interaction' or 'action'
--- @param resourceId any Resource identifier
--- @param policyId string Optional, detaches all if nil
function PolicyService.detach(resourceType, resourceId, policyId)
    local table_name = resourceType .. '_policy'
    local id_column = resourceType .. '_id'
    
    if policyId then
        -- Remove specific policy
        Database.deleteSync(
            'DELETE FROM ' .. table_name .. ' WHERE ' .. id_column .. ' = ? AND policy_id = ?',
            {resourceId, policyId}
        )
        print('[PolicyService] Detached policy ' .. policyId .. ' from ' .. resourceType .. '#' .. tostring(resourceId))
    else
        -- Remove all policies
        Database.deleteSync(
            'DELETE FROM ' .. table_name .. ' WHERE ' .. id_column .. ' = ?',
            {resourceId}
        )
        print('[PolicyService] Detached all policies from ' .. resourceType .. '#' .. tostring(resourceId))
    end
end

--- Get all policies attached to a resource (from database)
--- @param resourceType string 'interaction' or 'action'
--- @param resourceId any Resource identifier
--- @return table Array of {policyId, config}
function PolicyService.getPolicies(resourceType, resourceId)
    local table_name = resourceType .. '_policy'
    local id_column = resourceType .. '_id'
    
    local results = Database.querySync(
        'SELECT policy_id, data FROM ' .. table_name .. ' WHERE ' .. id_column .. ' = ?',
        {resourceId}
    )
    
    if not results then return {} end
    
    local policies = {}
    for _, row in ipairs(results) do
        local config = {}
        if row.data and row.data ~= '' then
            local success, decoded = pcall(json.decode, row.data)
            if success then
                config = decoded
            end
        end
        
        table.insert(policies, {
            policyId = row.policy_id,
            config = config
        })
    end
    
    return policies
end

--- Check if player passes all policies for a resource
--- @param source number Player server ID
--- @param resourceType string
--- @param resourceId any
--- @param callback function function(allowed, reason)
function PolicyService.check(source, resourceType, resourceId, callback)
    local policies = PolicyService.getPolicies(resourceType, resourceId)
    
    -- No policies = allow by default
    if #policies == 0 then
        callback(true)
        return
    end
    
    local index = 1
    
    local function checkNext()
        if index > #policies then
            -- All policies passed
            callback(true)
            return
        end
        
        local attachment = policies[index]
        index = index + 1
        
        local policy = PolicyService.registry[attachment.policyId]
        
        if not policy then
            print('[PolicyService] Warning: Policy not found: ' .. attachment.policyId)
            checkNext()
            return
        end
        
        -- Execute policy validator
        local success, allowed, reason = pcall(policy.validator, source, {
            type = resourceType,
            id = resourceId
        }, attachment.config)
        
        if not success then
            print('[PolicyService] Error in policy ' .. attachment.policyId .. ': ' .. tostring(allowed))
            callback(false, 'Policy check failed')
            return
        end
        
        if not allowed then
            -- Policy failed - abort
            print('[PolicyService] Policy ' .. attachment.policyId .. ' denied access for player ' .. source)
            callback(false, reason or 'Access denied by policy')
            return
        end
        
        -- Policy passed, check next
        checkNext()
    end
    
    checkNext()
end

--- Synchronous version of check (for use in sync contexts)
--- @param source number
--- @param resourceType string
--- @param resourceId any
--- @return boolean allowed
--- @return string reason
function PolicyService.checkSync(source, resourceType, resourceId)
    local policies = PolicyService.getPolicies(resourceType, resourceId)
    
    if #policies == 0 then
        return true
    end
    
    for _, attachment in ipairs(policies) do
        local policy = PolicyService.registry[attachment.policyId]
        
        if policy then
            local success, allowed, reason = pcall(policy.validator, source, {
                type = resourceType,
                id = resourceId
            }, attachment.config)
            
            if not success then
                print('[PolicyService] Error in policy ' .. attachment.policyId .. ': ' .. tostring(allowed))
                return false, 'Policy check failed'
            end
            
            if not allowed then
                return false, reason or 'Access denied by policy'
            end
        end
    end
    
    return true
end

return PolicyService