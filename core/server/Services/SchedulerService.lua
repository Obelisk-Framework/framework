--- SchedulerService - runs ActionService-registered actions on a schedule
--- (interval or cron) configured via admin-editable scheduled_jobs rows.
--- See docs/superpowers/specs/2026-08-16-scheduler-service-design.md.
--- isDue/tick/startTickLoop are added in Tasks 3-4; this file starts with
--- just the CRUD surface.
SchedulerService = {}

--- @param actionId string an ActionService-registered action_id
--- @param scheduleType string 'interval' | 'cron'
--- @param config table { intervalSeconds = number } or { cronExpression = string }
--- @return number id
function SchedulerService.create(actionId, scheduleType, config)
    config = config or {}
    return QueryBuilder.new('scheduled_jobs'):insert({
        action_id = actionId,
        schedule_type = scheduleType,
        interval_seconds = config.intervalSeconds,
        cron_expression = config.cronExpression,
        enabled = 1,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @param attrs table fields to update (action_id, schedule_type, interval_seconds, cron_expression, enabled)
function SchedulerService.update(id, attrs)
    attrs.updated_at = Database.now()
    QueryBuilder.new('scheduled_jobs'):where('id', id):update(attrs)
end

--- @param id number
function SchedulerService.delete(id)
    QueryBuilder.new('scheduled_jobs'):where('id', id):delete()
end

--- @return table[]
function SchedulerService.list()
    return QueryBuilder.new('scheduled_jobs'):getSync()
end

--- @param row table scheduled_jobs row
--- @param now number unix epoch seconds
--- @return boolean
function SchedulerService.isDue(row, now)
    if row.schedule_type == 'interval' then
        if not row.last_run_at then
            return true
        end
        return (now - row.last_run_at) >= row.interval_seconds
    elseif row.schedule_type == 'cron' then
        if not CronExpression.matches(row.cron_expression, now) then
            return false
        end
        if not row.last_run_at then
            return true
        end
        -- Don't re-fire within the same matching minute: compare against
        -- the start of "now"'s minute.
        local nowMinuteStart = now - (now % 60)
        return row.last_run_at < nowMinuteStart
    end
    return false
end

--- @param now number unix epoch seconds
function SchedulerService.tick(now)
    local rows = QueryBuilder.new('scheduled_jobs'):where('enabled', 1):getSync()
    for _, row in ipairs(rows) do
        if SchedulerService.isDue(row, now) then
            ActionService.execute(nil, row.action_id, {})
            QueryBuilder.new('scheduled_jobs'):where('id', row.id):update({
                last_run_at = now,
                updated_at = Database.now(),
            })
        end
    end
end

local TICK_INTERVAL_MS = 30000

--- Starts the persistent scheduler poll loop. Call exactly once, from
--- bootstrap.lua after the database and core actions are ready -- never
--- call this from a test (see this task's note in the implementation
--- plan for why: the CreateThread test stub runs synchronously, so an
--- infinite loop here would hang any test that dofiles this file).
function SchedulerService.startTickLoop()
    Citizen.CreateThread(function()
        while not Database.isReady() do
            Citizen.Wait(200)
        end
        while true do
            SchedulerService.tick(os.time())
            Citizen.Wait(TICK_INTERVAL_MS)
        end
    end)
end

return SchedulerService
