ScheduledJob = BaseModel:extend('scheduled_jobs')

function ScheduledJob.relations:action()
    return self:belongsTo(Action, 'action_id', 'action_id')
end
