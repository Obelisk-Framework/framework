Action = BaseModel:extend('actions')
Action.casts = { options = 'json' }

function Action:scheduledJobsRelation()
    return self:hasMany(ScheduledJob, 'action_id', 'action_id')
end

return Action
