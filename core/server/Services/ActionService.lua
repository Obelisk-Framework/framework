--- ActionService - Registry and execution system for game actions
--- Actions are named operations that can be triggered from various sources
--- (keybinds, interactions, UI, etc.)
ActionService = {}
ActionService.registry = {}
ActionService.idToActionId = {}
ActionService.pendingRegistrations = {}

--- Register a new action
--- @param actionId string Unique identifier for the action
--- @param handler function Function to execute: function(player, data)
--- @param options table Optional metadata (description, etc.)
function ActionService.register(actionId, handler, options)
    options = options or {}
    if ActionService.registry[actionId] then
        print('[ActionService] Warning: Overwriting existing action: ' .. actionId)
    end

    ActionService.registry[actionId] = { id = actionId, dbId = ActionService.registry[actionId] and ActionService.registry[actionId].dbId or nil, handler = handler, options = options }
    table.insert(ActionService.pendingRegistrations, actionId)

    if Database.isReady() then
        ActionService.flushPendingRegistrations()
    end
end

--- Persists every queued registration into the `actions` table. Safe to
--- call multiple times; already-persisted entries (entry.dbId already set)
--- are skipped. Called automatically by `register` once Database.isReady()
--- is true, and explicitly by bootstrap.lua right after migrations run, to
--- flush anything that was registered earlier (before the DB existed).
function ActionService.flushPendingRegistrations()
    local stillPending = {}
    for _, actionId in ipairs(ActionService.pendingRegistrations) do
        local entry = ActionService.registry[actionId]
        if entry and not entry.dbId then
            local options = entry.options
            local existing = Action:where('name', actionId):first()
            local dbId
            if existing then
                existing:set('label', options.label)
                existing:set('description', options.description)
                existing:set('options', options)
                existing:save()
                dbId = existing.id
            else
                local action = Action:create({
                    name = actionId,
                    label = options.label,
                    description = options.description,
                    options = options,
                })
                dbId = action.id
            end
            if dbId then
                entry.dbId = dbId
                ActionService.idToActionId[dbId] = actionId
                print('[ActionService] Registered action: ' .. actionId .. ' (db id ' .. dbId .. ')')
            else
                print('[ActionService] ERROR: failed to persist action "' .. actionId .. '" to the actions table')
                table.insert(stillPending, actionId)
            end
        end
    end
    ActionService.pendingRegistrations = stillPending
end

--- @param actionId string
--- @return number|nil
function ActionService.getDbId(actionId)
    local entry = ActionService.registry[actionId]
    return entry and entry.dbId
end

--- @param dbId number
--- @return string|nil
function ActionService.resolveDbId(dbId)
    return ActionService.idToActionId[dbId]
end

--- Execute a registered action, running its policy checks and hook chain.
--- @param player Player
--- @param actionId string Action to execute
--- @param data table Optional data passed to handler
function ActionService.execute(player, actionId, data)
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
            local success, err = pcall(action.handler, player, data)

            if not success then
                print('[ActionService] Error executing action ' .. actionId .. ': ' .. tostring(err))
                return
            end

            -- Run after hooks
            Hooks.runHook('action:after:' .. actionId, function()
                -- After hooks complete
            end, player, data)
        end, player, data)
    end

    -- Enforce any policies attached to this action BEFORE running it. This is
    -- the authorization gate for client-triggered actions (the
    -- core:client:action-execute / core:client:keybinds-pressed net events): without
    -- it, any client could invoke any registered action with arbitrary data.
    -- Actions with no attached policies are allowed by default.
    if PolicyService then
        PolicyService.check(player, 'action', actionId, function(allowed, reason)
            if not allowed then
                print('[ActionService] Action denied by policy: ' .. actionId .. ' for player ' .. tostring(player:getSource()))
                if NotificationService then
                    NotificationService.notify(player, {
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
Obelisk.onClient('core:client:action-execute', function(player, actionId, data)
    ActionService.execute(player, actionId, data)
end)

return ActionService