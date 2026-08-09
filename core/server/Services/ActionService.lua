--- ActionService - Registry and execution system for game actions
--- Actions are named operations that can be triggered from various sources
--- (keybinds, interactions, UI, etc.)
ActionService = {}
ActionService.registry = {}

--- Register a new action
--- @param actionId string Unique identifier for the action
--- @param handler function Function to execute: function(source, data)
--- @param options table Optional metadata (description, etc.)
function ActionService.register(actionId, handler, options)
    if ActionService.registry[actionId] then
        print('[ActionService] Warning: Overwriting existing action: ' .. actionId)
    end
    
    ActionService.registry[actionId] = {
        id = actionId,
        handler = handler,
        options = options or {}
    }
    
    print('[ActionService] Registered action: ' .. actionId)
end

--- Execute an action
--- @param source number Player server ID
--- @param actionId string Action to execute
--- @param data table Optional data passed to handler
function ActionService.execute(source, actionId, data)
    local action = ActionService.registry[actionId]
    
    if not action then
        print('[ActionService] Error: Action not found: ' .. actionId)
        return false
    end
    
    -- Runs the hook chain and the action handler. Only reached once the
    -- action's policies (if any) have passed.
    local function runAction()
        Hooks.runHook('action:before:' .. actionId, function(results)
            -- Check if any hook cancelled the action
            for _, result in ipairs(results) do
                if result == false then
                    print('[ActionService] Action cancelled by hook: ' .. actionId)
                    return
                end
            end

            -- Execute the action handler
            local success, err = pcall(action.handler, source, data)

            if not success then
                print('[ActionService] Error executing action ' .. actionId .. ': ' .. tostring(err))
                return
            end

            -- Run after hooks
            Hooks.runHook('action:after:' .. actionId, function()
                -- After hooks complete
            end, source, data)
        end, source, data)
    end

    -- Enforce any policies attached to this action BEFORE running it. This is
    -- the authorization gate for client-triggered actions (the
    -- core:client:action-execute / core:client:keybinds-pressed net events): without
    -- it, any client could invoke any registered action with arbitrary data.
    -- Actions with no attached policies are allowed by default.
    if PolicyService then
        PolicyService.check(source, 'action', actionId, function(allowed, reason)
            if not allowed then
                print('[ActionService] Action denied by policy: ' .. actionId .. ' for player ' .. tostring(source))
                if NotificationService then
                    NotificationService.notify(source, {
                        type = 'error',
                        title = 'Access Denied',
                        description = reason or 'You cannot perform this action'
                    })
                end
                return
            end
            runAction()
        end)
    else
        runAction()
    end

    return true
end

--- Get action by ID
--- @param actionId string
--- @return table|nil
function ActionService.get(actionId)
    return ActionService.registry[actionId]
end

--- Get all registered actions
--- @return table
function ActionService.getAll()
    return ActionService.registry
end

--- Check if action exists
--- @param actionId string
--- @return boolean
function ActionService.exists(actionId)
    return ActionService.registry[actionId] ~= nil
end

--- Unregister an action
--- @param actionId string
function ActionService.unregister(actionId)
    ActionService.registry[actionId] = nil
    print('[ActionService] Unregistered action: ' .. actionId)
end

--- Net event handler for client-triggered actions
RegisterNetEvent('core:client:action-execute')
AddEventHandler('core:client:action-execute', function(actionId, data)
    local source = source
    ActionService.execute(source, actionId, data)
end)

return ActionService