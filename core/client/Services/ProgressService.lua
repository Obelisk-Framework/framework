--- Client ProgressService - Receives progress bars and displays in NUI
ProgressService = {}
ProgressService.activeProgress = {}

--- Start a progress bar
RegisterNetEvent('obelisk:progress:start')
AddEventHandler('obelisk:progress:start', function(progressData)
    ProgressService.activeProgress[progressData.id] = progressData
    
    -- Send to NUI
    SendNUIMessage({
        type = 'progress:start',
        progress = progressData
    })
    
    print('[ProgressService] Started progress: ' .. progressData.label)
end)

--- Complete a progress bar
RegisterNetEvent('obelisk:progress:complete')
AddEventHandler('obelisk:progress:complete', function(progressId)
    ProgressService.activeProgress[progressId] = nil
    
    -- Send to NUI
    SendNUIMessage({
        type = 'progress:complete',
        progressId = progressId
    })
    
    print('[ProgressService] Completed progress: ' .. progressId)
end)

--- Cancel a progress bar
RegisterNetEvent('obelisk:progress:cancel')
AddEventHandler('obelisk:progress:cancel', function(progressId)
    ProgressService.activeProgress[progressId] = nil
    
    -- Send to NUI
    SendNUIMessage({
        type = 'progress:cancel',
        progressId = progressId
    })
    
    print('[ProgressService] Cancelled progress: ' .. progressId)
end)

--- NUI Callback: Progress cancelled by user
RegisterNUICallback('progress:userCancel', function(data, cb)
    local progressId = data.progressId
    
    if ProgressService.activeProgress[progressId] then
        -- Notify server
        TriggerServerEvent('obelisk:progress:clientCancel', progressId)
        
        -- Remove locally
        ProgressService.activeProgress[progressId] = nil
    end
    
    cb('ok')
end)

--- NUI Callback: Progress completed
RegisterNUICallback('progress:completed', function(data, cb)
    local progressId = data.progressId
    
    if ProgressService.activeProgress[progressId] then
        -- Notify server
        TriggerServerEvent('obelisk:progress:clientComplete', progressId)
        
        -- Remove locally
        ProgressService.activeProgress[progressId] = nil
    end
    
    cb('ok')
end)

return ProgressService
