--- ActionPolicy - pivot row attaching a PolicyService-registered policy to
--- an action. `action_id` is the action's string action_id (not actions.id)
--- so a policy can be attached before the action has a DB row -- see
--- ActionService's pending-registration flow -- which is why this is a
--- standalone pivot model rather than a belongsToMany off Action (whose
--- primary key is the numeric `id`, not `action_id`).
ActionPolicy = BaseModel:extend('action_policy')

ActionPolicy.primaryKey = 'id'
ActionPolicy.timestamps = true
ActionPolicy.fillable = { 'action_id', 'policy_id', 'data' }
ActionPolicy.casts = { data = 'json' }

return ActionPolicy
