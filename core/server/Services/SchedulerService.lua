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

return SchedulerService
