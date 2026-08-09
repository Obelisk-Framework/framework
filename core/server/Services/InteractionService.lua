--- InteractionService - Spatial query system for world interactions
--- Manages interactions with coordinates and range-based queries
InteractionService = {}
InteractionService.registry = {}
InteractionService.nextId = 1

--- Register a new interaction
--- @param data table {x, y, z, range, label, action, options}
--- @return number interactionId
function InteractionService.register(data)
    local id = InteractionService.nextId
    InteractionService.nextId = InteractionService.nextId + 1
    
    InteractionService.registry[id] = {
        id = id,
        x = data.x,
        y = data.y,
        z = data.z,
        range = data.range or 2.0,
        label = data.label or 'Interact',
        action = data.action, -- Action ID to trigger
        options = data.options or {},
        enabled = true
    }
    
    print('[InteractionService] Registered interaction #' .. id .. ' at ' .. data.x .. ',' .. data.y .. ',' .. data.z)
    
    -- Broadcast to clients for streaming
    TriggerClientEvent('core:server:interaction-add', -1, InteractionService.registry[id])
    
    return id
end

--- Unregister an interaction
--- @param interactionId number
function InteractionService.unregister(interactionId)
    if InteractionService.registry[interactionId] then
        InteractionService.registry[interactionId] = nil
        print('[InteractionService] Unregistered interaction #' .. interactionId)
        
        TriggerClientEvent('core:server:interaction-remove', -1, interactionId)
    end
end

--- Get interaction by ID
--- @param interactionId number
--- @return table|nil
function InteractionService.get(interactionId)
    return InteractionService.registry[interactionId]
end

--- Get all interactions
--- @return table
function InteractionService.getAll()
    return InteractionService.registry
end

--- Get interactions within range of coordinates
--- @param x number
--- @param y number
--- @param z number
--- @param range number Optional override range
--- @return table Array of interactions
function InteractionService.getNearby(x, y, z, range)
    local nearby = {}
    
    for id, interaction in pairs(InteractionService.registry) do
        if interaction.enabled then
            local dist = math.sqrt(
                (interaction.x - x)^2 + 
                (interaction.y - y)^2 + 
                (interaction.z - z)^2
            )
            
            local checkRange = range or interaction.range
            if dist <= checkRange then
                table.insert(nearby, interaction)
            end
        end
    end
    
    return nearby
end

--- Update interaction data
--- @param interactionId number
--- @param data table Fields to update
function InteractionService.update(interactionId, data)
    local interaction = InteractionService.registry[interactionId]
    if not interaction then return end
    
    for key, value in pairs(data) do
        interaction[key] = value
    end
    
    TriggerClientEvent('core:server:interaction-update', -1, interaction)
end

--- Enable/disable interaction
--- @param interactionId number
--- @param enabled boolean
function InteractionService.setEnabled(interactionId, enabled)
    local interaction = InteractionService.registry[interactionId]
    if interaction then
        interaction.enabled = enabled
        TriggerClientEvent('core:server:interaction-update', -1, interaction)
    end
end

--- Handle interaction use (triggered from client)
--- @param source number Player server ID
--- @param interactionId number
function InteractionService.use(source, interactionId)
    local interaction = InteractionService.registry[interactionId]
    
    if not interaction then
        print('[InteractionService] Error: Interaction not found: ' .. interactionId)
        return
    end
    
    if not interaction.enabled then
        print('[InteractionService] Error: Interaction disabled: ' .. interactionId)
        return
    end
    
    -- Verify player is in range
    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)
    local dist = #(vector3(playerCoords.x, playerCoords.y, playerCoords.z) - 
                   vector3(interaction.x, interaction.y, interaction.z))
    
    if dist > interaction.range + 1.0 then -- +1.0 tolerance for latency
        print('[InteractionService] Player too far from interaction: ' .. interactionId)
        return
    end
    
    -- Check policies
    PolicyService.check(source, 'interaction', interactionId, function(allowed, reason)
        if not allowed then
            NotificationService.notify(source, {
                type = 'error',
                title = 'Access Denied',
                description = reason or 'You cannot use this interaction'
            })
            return
        end
        
        -- Execute associated action
        if interaction.action then
            ActionService.execute(source, interaction.action, {
                interactionId = interactionId,
                interaction = interaction
            })
        end
        
        -- Run hook for extensibility
        Hooks.runHook('interaction:use', function() end, source, interaction)
    end)
end

--- Net event handlers
RegisterNetEvent('core:client:interaction-use')
AddEventHandler('core:client:interaction-use', function(interactionId)
    local source = source
    InteractionService.use(source, interactionId)
end)

--- Send all interactions to a player (on join)
RegisterNetEvent('core:client:interaction-requestAll')
AddEventHandler('core:client:interaction-requestAll', function()
    local source = source
    TriggerClientEvent('core:server:interaction-syncAll', source, InteractionService.registry)
end)

return InteractionService