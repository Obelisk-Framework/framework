--- ProgressService - Queue-based progress bar system
--- Server triggers progress bars on client with Vue UI display
ProgressService = {}
ProgressService.activeProgress = {} -- Track active progress by player

--- Start a progress bar for a player
--- @param target number Player server ID
--- @param data table {label, duration, canCancel}
--- @param onComplete function Optional callback on completion
--- @param onCancel function Optional callback on cancellation
--- @return string progressId
function ProgressService.start(target, data, onComplete, onCancel)
    local progressId = 'progress_' .. target .. '_' .. os.time() .. '_' .. math.random(1000, 9999)
    
    local progress = {
        id = progressId,
        label = data.label or 'Progress...',
        duration = data.duration or 5000, -- milliseconds
        canCancel = data.canCancel ~= false, -- default true
        startTime = GetGameTimer(),
        target = target,
        onComplete = onComplete,
        onCancel = onCancel
    }
    
    -- Store active progress
    if not ProgressService.activeProgress[target] then
        ProgressService.activeProgress[target] = {}
    end
    
    ProgressService.activeProgress[target][progressId] = progress
    
    -- Send to client
    Obelisk.emitClient('core:server:progress-start', target, {
        id = progressId,
        label = progress.label,
        duration = progress.duration,
        canCancel = progress.canCancel
    })
    
    -- Set up auto-complete timer (server-side tracking)
    SetTimeout(progress.duration, function()
        if ProgressService.activeProgress[target] and
           ProgressService.activeProgress[target][progressId] then
            local player = PlayerService.get(target)
            if player then
                ProgressService.complete(player, progressId)
            end
        end
    end)
    
    print('[ProgressService] Started progress ' .. progressId .. ' for player ' .. target)
    
    return progressId
end

--- Complete a progress bar
--- @param player Player
--- @param progressId string
function ProgressService.complete(player, progressId)
    if not ProgressService.activeProgress[player:getSource()] then return end

    local progress = ProgressService.activeProgress[player:getSource()][progressId]
    if not progress then return end

    -- Remove from active
    ProgressService.activeProgress[player:getSource()][progressId] = nil

    -- Notify client
    Obelisk.emitClient('core:server:progress-complete', player, progressId)

    -- Call completion callback
    if progress.onComplete then
        progress.onComplete(player)
    end

    print('[ProgressService] Completed progress ' .. progressId .. ' for player ' .. player:getSource())
end

--- Cancel a progress bar
--- @param player Player
--- @param progressId string
function ProgressService.cancel(player, progressId)
    if not ProgressService.activeProgress[player:getSource()] then return end

    local progress = ProgressService.activeProgress[player:getSource()][progressId]
    if not progress then return end

    -- Remove from active
    ProgressService.activeProgress[player:getSource()][progressId] = nil

    -- Notify client
    Obelisk.emitClient('core:server:progress-cancel', player, progressId)

    -- Call cancellation callback
    if progress.onCancel then
        progress.onCancel(player)
    end

    print('[ProgressService] Cancelled progress ' .. progressId .. ' for player ' .. player:getSource())
end

--- Cancel all progress bars for a player
--- @param target number Player server ID
function ProgressService.cancelAll(target)
    if not ProgressService.activeProgress[target] then return end

    local player = PlayerService.get(target)
    if not player then return end

    for progressId, _ in pairs(ProgressService.activeProgress[target]) do
        ProgressService.cancel(player, progressId)
    end
end

--- Get active progress for a player
--- @param target number Player server ID
--- @return table
function ProgressService.getActive(target)
    return ProgressService.activeProgress[target] or {}
end

--- Net event: Client reports progress completion
Obelisk.onClient('core:client:progress-complete', function(player, progressId)
    ProgressService.complete(player, progressId)
end)

--- Net event: Client reports progress cancellation
Obelisk.onClient('core:client:progress-cancel', function(player, progressId)
    ProgressService.cancel(player, progressId)
end)

--- Clean up on player disconnect
Obelisk.on('playerDropped', function()
    local source = source
    ProgressService.activeProgress[source] = nil
end)

return ProgressService
