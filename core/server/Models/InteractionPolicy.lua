InteractionPolicy = BaseModel:extend('interaction_policy')
InteractionPolicy.casts = { data = 'json' }
