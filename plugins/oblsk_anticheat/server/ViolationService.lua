-- plugins/oblsk_anticheat/server/ViolationService.lua
--- Records anticheat violations and drives the escalation policy:
--- log + notify always, immediate kick on hard violations, ban once the
--- player crosses Config.Anticheat.violationsBeforeBan within
--- Config.Anticheat.violationWindowSeconds. See
--- docs/superpowers/specs/2026-08-20-anticheat-design.md
--- ("Response / escalation").
ViolationService = ViolationService or {}

local function recentViolationCount(playerId)
    local rows = Database.executeQuery(
        'SELECT player_id FROM `anticheat_violations` WHERE player_id = ? AND created_at >= ?',
        {playerId, os.date('%Y-%m-%d %H:%M:%S', os.time() - Config.Anticheat.violationWindowSeconds)}
    )
    return #rows
end

local function insertViolation(playerId, category, detail, severity)
    Database.executeQuery(
        'INSERT INTO `anticheat_violations` (player_id, category, detail, severity, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        {playerId, category, detail, severity, os.date('%Y-%m-%d %H:%M:%S'), os.date('%Y-%m-%d %H:%M:%S')}
    )
end

--- Notifies every currently-connected admin (ACE 'admin' allowed), not the
--- violating player — the escalation spec is "log + notify online admins".
local function notifyOnlineAdmins(title, description)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if IsPlayerAceAllowed(playerId, 'admin') then
            local admin = PlayerService.get(playerId)
            if admin then
                NotificationService.error(admin, title, description)
            end
        end
    end
end

local function dropAllSessionsFor(accountId, reason)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if AccountService.getAccountId(playerId) == accountId then
            DropPlayer(playerId, reason)
        end
    end
end

--- @param player Player
--- @param category string e.g. 'movement', 'health', 'spawn', 'event'
--- @param detail string human-readable detail for the admin/log
--- @param severity 'soft'|'hard'
function ViolationService.record(player, category, detail, severity)
    local source = player:getSource()

    insertViolation(source, category, detail, severity)
    notifyOnlineAdmins('Anticheat', category .. ': ' .. detail .. ' (player ' .. tostring(source) .. ')')

    local accountId = AccountService.getAccountId(source)
    local recentCount = recentViolationCount(source)

    if recentCount >= Config.Anticheat.violationsBeforeBan then
        AccountService.ban({accountId = accountId}, 'Anticheat: ' .. category .. ' (' .. detail .. ')', 'anticheat', nil)
        dropAllSessionsFor(accountId, 'Banned: automated anticheat')
        return
    end

    if severity == 'hard' then
        AccountService.logKick(accountId, 'Anticheat: ' .. category .. ' (' .. detail .. ')', 'anticheat')
        dropAllSessionsFor(accountId, 'Kicked: automated anticheat (' .. category .. ')')
    end
end

return ViolationService
