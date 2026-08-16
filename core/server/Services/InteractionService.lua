--- InteractionService - Spatial query system for world interactions
--- Manages interactions with coordinates and range-based queries
InteractionService = {}
InteractionService.registry = {}
InteractionService.nextId = 1

--- dbInteractionId -> array of live registry ids. Lets a persisted
--- `interactions` DB row be found and mutated/removed live, without a
--- server restart. One DB row can back more than one live registration
--- (e.g. oblsk_shop's registerAllShops registers both `shop:open` and
--- `shop:crackSafe` at the same row's coords) -- see registerFromDb.
InteractionService.byDbId = {}

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
    Obelisk.emitClient('core:server:interaction-add', -1, InteractionService.registry[id])
    
    return id
end

--- Like register(), but also records which persisted `interactions` row this
--- live registration came from, so it can later be found and mutated/removed
--- by that DB id via updateByDbId/setEnabledByDbId/unregisterByDbId. One DB
--- row can back more than one live registration (see oblsk_shop's
--- registerAllShops) -- this appends to byDbId[dbId], it doesn't overwrite.
--- @param dbId number the `interactions` table row id this registration came from
--- @param data table same shape as register()
--- @return number interactionId (the live registry id, same as register())
function InteractionService.registerFromDb(dbId, data)
    local liveId = InteractionService.register(data)
    InteractionService.registry[liveId].dbInteractionId = dbId
    InteractionService.byDbId[dbId] = InteractionService.byDbId[dbId] or {}
    table.insert(InteractionService.byDbId[dbId], liveId)
    return liveId
end

--- Unregister an interaction
--- @param interactionId number
function InteractionService.unregister(interactionId)
    local interaction = InteractionService.registry[interactionId]
    if interaction then
        -- Clean up byDbId bookkeeping if this entry came from registerFromDb,
        -- so a direct unregister() (bypassing unregisterByDbId) doesn't leave
        -- a stale array entry pointing at a now-dead registry id.
        local dbId = interaction.dbInteractionId
        if dbId and InteractionService.byDbId[dbId] then
            local liveIds = InteractionService.byDbId[dbId]
            for i = #liveIds, 1, -1 do
                if liveIds[i] == interactionId then
                    table.remove(liveIds, i)
                end
            end
            if #liveIds == 0 then
                InteractionService.byDbId[dbId] = nil
            end
        end

        InteractionService.registry[interactionId] = nil
        print('[InteractionService] Unregistered interaction #' .. interactionId)

        Obelisk.emitClient('core:server:interaction-remove', -1, interactionId)
    end
end

--- Unregisters every live registration tied to dbId (see registerFromDb).
--- Safe to call even if some/all of those live ids were already individually
--- unregistered (e.g. via unregister()) -- no double-free, no crash.
--- @param dbId number
function InteractionService.unregisterByDbId(dbId)
    local liveIds = InteractionService.byDbId[dbId]
    if not liveIds then return end
    -- Copy first: unregister() mutates InteractionService.byDbId[dbId] (the
    -- same array/reference we'd otherwise be iterating), including clearing
    -- it entirely on the last removal.
    local toRemove = {}
    for _, liveId in ipairs(liveIds) do
        table.insert(toRemove, liveId)
    end
    for _, liveId in ipairs(toRemove) do
        InteractionService.unregister(liveId)
    end
    InteractionService.byDbId[dbId] = nil
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
    
    Obelisk.emitClient('core:server:interaction-update', -1, interaction)
end

--- Enable/disable interaction
--- @param interactionId number
--- @param enabled boolean
function InteractionService.setEnabled(interactionId, enabled)
    local interaction = InteractionService.registry[interactionId]
    if interaction then
        interaction.enabled = enabled
        Obelisk.emitClient('core:server:interaction-update', -1, interaction)
    end
end

--- Applies `data` (a shallow field patch, same shape as update()'s) to every
--- live registration tied to dbId. Callers whose dbId backs more than one
--- live registration with DIFFERENT per-registration fields (e.g. distinct
--- `label`/`action`/`options`, like oblsk_shop's two-registrations-per-row
--- case) must only pass fields that are actually shared/safe to apply to all
--- of them (typically just x/y/z/range) -- this function has no way to know
--- which fields are shared vs per-registration, it just patches everything
--- tied to dbId uniformly.
--- @param dbId number
--- @param data table
function InteractionService.updateByDbId(dbId, data)
    local liveIds = InteractionService.byDbId[dbId]
    if not liveIds then return end
    for _, liveId in ipairs(liveIds) do
        InteractionService.update(liveId, data)
    end
end

--- Same fan-out as updateByDbId, for enabled/disabled.
--- @param dbId number
--- @param enabled boolean
function InteractionService.setEnabledByDbId(dbId, enabled)
    local liveIds = InteractionService.byDbId[dbId]
    if not liveIds then return end
    for _, liveId in ipairs(liveIds) do
        InteractionService.setEnabled(liveId, enabled)
    end
end

--- Handle interaction use (triggered from client)
--- @param player Player
--- @param interactionId number
function InteractionService.use(player, interactionId)
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
    local playerPed = GetPlayerPed(player:getSource())
    local playerCoords = GetEntityCoords(playerPed)
    local dist = #(vector3(playerCoords.x, playerCoords.y, playerCoords.z) -
                   vector3(interaction.x, interaction.y, interaction.z))

    if dist > interaction.range + 1.0 then -- +1.0 tolerance for latency
        print('[InteractionService] Player too far from interaction: ' .. interactionId)
        return
    end

    -- Check policies
    PolicyService.check(player, 'interaction', interactionId, function(allowed, reason)
        if not allowed then
            NotificationService.notify(player, {
                type = 'error',
                title = 'Access Denied',
                description = reason or 'You cannot use this interaction'
            })
            return
        end

        -- Execute associated action
        if interaction.action then
            ActionService.execute(player, interaction.action, {
                interactionId = interactionId,
                interaction = interaction
            })
        end

        -- Run hook for extensibility
        Hooks.runHook('interaction:use', function() end, player, interaction)
    end)
end

--- Net event handlers
Obelisk.onClient('core:client:interaction-use', function(player, interactionId)
    InteractionService.use(player, interactionId)
end)

--- Send all interactions to a player (on join)
Obelisk.onClient('core:client:interaction-requestAll', function(player)
    Obelisk.emitClient('core:server:interaction-syncAll', player, InteractionService.registry)
end)

return InteractionService