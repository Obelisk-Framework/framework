--- NotificationService - Queue-based notification system
--- Supports server->client and client->client notifications
--- Integrates with Vue 3 UI via NUI messages
NotificationService = {}

--- Notification types
NotificationService.TYPES = {
    INFO = 'info',
    DEFAULT = 'default',
    WARNING = 'warning',
    DANGER = 'danger',
    ERROR = 'error',
    SUCCESS = 'success'
}

--- Send notification to a player
--- @param target number Player server ID or -1 for all
--- @param data table {type, title, description, duration, color}
function NotificationService.notify(target, data)
    local notification = {
        type = data.type or NotificationService.TYPES.DEFAULT,
        title = data.title or 'Notification',
        description = data.description or '',
        duration = data.duration or 5000, -- milliseconds
        color = data.color, -- Optional custom color
        timestamp = os.time()
    }
    
    -- Validate type
    local validType = false
    for _, t in pairs(NotificationService.TYPES) do
        if notification.type == t then
            validType = true
            break
        end
    end
    
    if not validType and not notification.color then
        notification.type = NotificationService.TYPES.DEFAULT
    end
    
    -- Send to client(s)
    Obelisk.emitClient('core:server:notification-show', target, notification)
    
    -- Run hook for extensibility
    if target ~= -1 then
        Hooks.runHook('notification:sent', function() end, target, notification)
    end
end

--- Send success notification
--- @param target number
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.success(target, title, description, duration)
    NotificationService.notify(target, {
        type = NotificationService.TYPES.SUCCESS,
        title = title,
        description = description,
        duration = duration
    })
end

--- Send error notification
--- @param target number
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.error(target, title, description, duration)
    NotificationService.notify(target, {
        type = NotificationService.TYPES.ERROR,
        title = title,
        description = description,
        duration = duration
    })
end

--- Send warning notification
--- @param target number
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.warning(target, title, description, duration)
    NotificationService.notify(target, {
        type = NotificationService.TYPES.WARNING,
        title = title,
        description = description,
        duration = duration
    })
end

--- Send info notification
--- @param target number
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.info(target, title, description, duration)
    NotificationService.notify(target, {
        type = NotificationService.TYPES.INFO,
        title = title,
        description = description,
        duration = duration
    })
end

--- Net event: Client requests to show notification (client-side triggered)
Obelisk.onServer('core:client:notification-show', function(data)
    local source = source
    -- Client is allowed to trigger notifications for themselves
    NotificationService.notify(source, data)
end)

return NotificationService
