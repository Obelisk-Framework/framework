--- ScheduledJob - admin-configured schedule for an ActionService-registered
--- action. `action_id` is that action's string name, not a foreign key
--- to actions.id -- actions can be registered after this row exists (see
--- the scheduled_jobs migration), so there's nothing to FK against.
ScheduledJob = BaseModel:extend('scheduled_jobs')

ScheduledJob.primaryKey = 'id'
ScheduledJob.timestamps = true
ScheduledJob.fillable = {
    'action_id', 'schedule_type', 'interval_seconds', 'cron_expression',
    'enabled', 'last_run_at',
}

--- ownerKey is name (Action's business key), not Action's primaryKey
--- ('id') -- see the comment above on why action_id isn't a numeric FK.
function ScheduledJob.relations:action()
    return self:belongsTo(Action, 'action_id', 'name')
end

return ScheduledJob
