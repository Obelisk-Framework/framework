--- PolicyService - Composable authorization middleware
--- Policies are functions that validate if a player can perform an action
--- Uses database tables for policy attachments: action_policy, interaction_policy
PolicyService = {}
PolicyService.registry = {}

--- Resource types with a backing "<type>_policy" pivot model. The resource
--- type selects which model/column pair to query, so it must never be
--- caller-controlled beyond this allowlist.
local RESOURCE_MODELS = {
    action = { model = ActionPolicy, idColumn = 'action_id' },
    interaction = { model = InteractionPolicy, idColumn = 'interaction_id' },
}

--- Resolve the pivot model and id column for a resource type, rejecting
--- anything outside the allowlist.
--- @param resourceType string
--- @return table model
--- @return string idColumn
local function resolveResourceModel(resourceType)
    local entry = RESOURCE_MODELS[resourceType]
    if not entry then
        error('PolicyService: invalid resource type "' .. tostring(resourceType) .. '"', 2)
    end
    return entry.model, entry.idColumn
end

--- Register a policy validator
--- @param policyId string Unique policy identifier
--- @param validator function function(player, resource, config) return boolean, reason
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
    
    local model, idColumn = resolveResourceModel(resourceType)

    -- Check if already attached
    local existing = model:where(idColumn, resourceId):where('policy_id', policyId):first()

    if existing then
        existing:set('data', config or {})
        existing:save()
        print('[PolicyService] Updated policy ' .. policyId .. ' for ' .. resourceType .. '#' .. tostring(resourceId))
    else
        model:create({
            [idColumn] = resourceId,
            policy_id = policyId,
            data = config or {},
        })
        print('[PolicyService] Attached policy ' .. policyId .. ' to ' .. resourceType .. '#' .. tostring(resourceId))
    end
    
    return true
end

--- Detach a policy from a resource (removes from database)
--- @param resourceType string 'interaction' or 'action'
--- @param resourceId any Resource identifier
--- @param policyId string Optional, detaches all if nil
function PolicyService.detach(resourceType, resourceId, policyId)
    local model, idColumn = resolveResourceModel(resourceType)

    if policyId then
        -- Remove specific policy
        model:where(idColumn, resourceId):where('policy_id', policyId):delete()
        print('[PolicyService] Detached policy ' .. policyId .. ' from ' .. resourceType .. '#' .. tostring(resourceId))
    else
        -- Remove all policies
        model:where(idColumn, resourceId):delete()
        print('[PolicyService] Detached all policies from ' .. resourceType .. '#' .. tostring(resourceId))
    end
end

--- Get all policies attached to a resource (from database)
--- @param resourceType string 'interaction' or 'action'
--- @param resourceId any Resource identifier
--- @return table Array of {policyId, config}
function PolicyService.getPolicies(resourceType, resourceId)
    local model, idColumn = resolveResourceModel(resourceType)

    local rows = model:where(idColumn, resourceId):get()

    local policies = {}
    for _, row in ipairs(rows) do
        table.insert(policies, {
            policyId = row.policy_id,
            config = row.data or {}
        })
    end

    return policies
end

--- Check if player passes all policies for a resource
--- @param player Player
--- @param resourceType string
--- @param resourceId any
--- @param callback function function(allowed, reason)
function PolicyService.check(player, resourceType, resourceId, callback)
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
        local success, allowed, reason = pcall(policy.validator, player, {
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
            print('[PolicyService] Policy ' .. attachment.policyId .. ' denied access for player ' .. player:getSource())
            callback(false, reason or 'Access denied by policy')
            return
        end

        -- Policy passed, check next
        checkNext()
    end

    checkNext()
end

--- Synchronous version of check (for use in sync contexts)
--- @param player Player
--- @param resourceType string
--- @param resourceId any
--- @return boolean allowed
--- @return string reason
function PolicyService.checkSync(player, resourceType, resourceId)
    local policies = PolicyService.getPolicies(resourceType, resourceId)

    if #policies == 0 then
        return true
    end

    for _, attachment in ipairs(policies) do
        local policy = PolicyService.registry[attachment.policyId]

        if policy then
            local success, allowed, reason = pcall(policy.validator, player, {
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