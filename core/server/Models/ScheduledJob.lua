ScheduledJob = BaseModel:extend('scheduled_jobs')

function ScheduledJob:actionRelation()
    return self:belongsTo(Action, 'action_id', 'action_id')
end
