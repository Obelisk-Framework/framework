Action = BaseModel:extend('actions')

Action.primaryKey = 'id'
Action.timestamps = true
Action.fillable = {
    'action_id', 'label', 'description', 'options', 'enabled',
}
Action.casts = { options = 'json' }

return Action
