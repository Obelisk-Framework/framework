-- plugins/oblsk_auditlog/server/main.lua
--- oblsk_auditlog boot: register configured hooks once the DB and all
--- models are ready. There's no Database.onReady callback API in this
--- codebase; the established pattern (see
--- core/server/Services/SchedulerService.lua:startTickLoop) is to poll
--- Database.isReady() from a CreateThread loop.
Citizen.CreateThread(function()
    while not Database.isReady() do
        Citizen.Wait(200)
    end

    AuditLogService.init()
    print('[AuditLog] Watching ' .. (function()
        local n = 0
        for _ in pairs(AuditLogConfig.Watch) do n = n + 1 end
        return n
    end)())
end)
