--- Client NotificationService - Receives notifications and sends to NUI
NotificationService = {}
NotificationService.queue = {}

--- Receive notification from server
RegisterNetEvent('obelisk:notification:show')
AddEventHandler('obelisk:notification:show', function(notification)
    NotificationService.show(notification)
end)

--- Show a notification
--- @param notification table {type, title, description, duration, color}
function NotificationService.show(notification)
    -- Add unique ID
    notification.id = 'notif_' .. GetGameTimer() .. '_' .. math.random(1000, 9999)
    
    -- Add to queue
    table.insert(NotificationService.queue, notification)
    
    -- Send to NUI
    SendNUIMessage({
        type = 'notification:show',
        notification = notification
    })
    
    print('[NotificationService] Showing notification: ' .. notification.title)
end

--- Client-side notification (doesn't go through server)
--- @param data table {type, title, description, duration, color}
function NotificationService.notify(data)
    NotificationService.show(data)
end

--- Convenience methods
function NotificationService.success(title, description, duration)
    NotificationService.notify({
        type = 'success',
        title = title,
        description = description,
        duration = duration
    })
end

function NotificationService.error(title, description, duration)
    NotificationService.notify({
        type = 'error',
        title = title,
        description = description,
        duration = duration
    })
end

function NotificationService.warning(title, description, duration)
    NotificationService.notify({
        type = 'warning',
        title = title,
        description = description,
        duration = duration
    })
end

function NotificationService.info(title, description, duration)
    NotificationService.notify({
        type = 'info',
        title = title,
        description = description,
        duration = duration
    })
end

--- NUI Callback: Notification dismissed
RegisterNUICallback('notification:dismissed', function(data, cb)
    -- Remove from queue
    for i, notif in ipairs(NotificationService.queue) do
        if notif.id == data.id then
            table.remove(NotificationService.queue, i)
            break
        end
    end
    
    cb('ok')
end)

return NotificationService
