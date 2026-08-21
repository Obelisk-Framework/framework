Action = BaseModel:extend('actions')

Action.primaryKey = 'id'
Action.timestamps = true
Action.fillable = {
    'name', 'label', 'description', 'options', 'enabled',
}
Action.casts = { options = 'json' }

--- The inverse uses name (the string business key), not Action.id --
--- scheduled_jobs.action_id references this, not a numeric FK (see
--- ScheduledJob's own comment on why).
function Action.relations:scheduledJobs()
    return self:hasMany(ScheduledJob, 'action_id', 'name')
end

return Action
