--- Client ProgressService - Receives progress bars and displays in NUI
ProgressService = {}
ProgressService.activeProgress = {}

--- Start a progress bar
RegisterNetEvent('core:server:progress-start')
AddEventHandler('core:server:progress-start', function(progressData)
    ProgressService.activeProgress[progressData.id] = progressData
    
    -- Send to NUI
    SendNUIMessage({
        type = 'core:client:progress-start',
        progress = progressData
    })
    
    print('[ProgressService] Started progress: ' .. progressData.label)
end)

--- Complete a progress bar
RegisterNetEvent('core:server:progress-complete')
AddEventHandler('core:server:progress-complete', function(progressId)
    ProgressService.activeProgress[progressId] = nil
    
    -- Send to NUI
    SendNUIMessage({
        type = 'core:client:progress-complete',
        progressId = progressId
    })
    
    print('[ProgressService] Completed progress: ' .. progressId)
end)

--- Cancel a progress bar
RegisterNetEvent('core:server:progress-cancel')
AddEventHandler('core:server:progress-cancel', function(progressId)
    ProgressService.activeProgress[progressId] = nil
    
    -- Send to NUI
    SendNUIMessage({
        type = 'core:client:progress-cancel',
        progressId = progressId
    })
    
    print('[ProgressService] Cancelled progress: ' .. progressId)
end)

--- NUI Callback: Progress cancelled by user
RegisterNUICallback('core:client:progress-userCancel', function(data, cb)
    local progressId = data.progressId
    
    if ProgressService.activeProgress[progressId] then
        -- Notify server
        TriggerServerEvent('core:client:progress-cancel', progressId)
        
        -- Remove locally
        ProgressService.activeProgress[progressId] = nil
    end
    
    cb('ok')
end)

--- NUI Callback: Progress completed
RegisterNUICallback('core:client:progress-completed', function(data, cb)
    local progressId = data.progressId
    
    if ProgressService.activeProgress[progressId] then
        -- Notify server
        TriggerServerEvent('core:client:progress-complete', progressId)
        
        -- Remove locally
        ProgressService.activeProgress[progressId] = nil
    end
    
    cb('ok')
end)

return ProgressService
