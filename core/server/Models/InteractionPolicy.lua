--- InteractionPolicy - pivot row attaching a PolicyService-registered policy
--- to an interaction (interactions.id). A standalone pivot model, not a
--- belongsToMany off Interaction, since the policy side is a code-only
--- registry (PolicyService.registry), never persisted as its own model/table.
InteractionPolicy = BaseModel:extend('interaction_policy')

InteractionPolicy.primaryKey = 'id'
InteractionPolicy.timestamps = true
InteractionPolicy.fillable = { 'interaction_id', 'policy_id', 'data' }
InteractionPolicy.casts = { data = 'json' }

return InteractionPolicy
