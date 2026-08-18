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
--- @param player Player
--- @param data table {type, title, description, duration, color}
function NotificationService.notify(player, data)
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

    -- Send to client
    player:emit('core:server:notification-show', notification)

    -- Run hook for extensibility
    Hooks.runHook('notification:sent', function() end, player, notification)
end

--- Send success notification
--- @param player Player
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.success(player, title, description, duration)
    NotificationService.notify(player, {
        type = NotificationService.TYPES.SUCCESS,
        title = title,
        description = description,
        duration = duration
    })
end

--- Send error notification
--- @param player Player
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.error(player, title, description, duration)
    NotificationService.notify(player, {
        type = NotificationService.TYPES.ERROR,
        title = title,
        description = description,
        duration = duration
    })
end

--- Send warning notification
--- @param player Player
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.warning(player, title, description, duration)
    NotificationService.notify(player, {
        type = NotificationService.TYPES.WARNING,
        title = title,
        description = description,
        duration = duration
    })
end

--- Send info notification
--- @param player Player
--- @param title string
--- @param description string
--- @param duration number Optional
function NotificationService.info(player, title, description, duration)
    NotificationService.notify(player, {
        type = NotificationService.TYPES.INFO,
        title = title,
        description = description,
        duration = duration
    })
end

--- Net event: Client requests to show notification (client-side triggered)
Obelisk.onClient('core:client:notification-show', function(player, data)
    NotificationService.notify(player, data)
end)

return NotificationService
