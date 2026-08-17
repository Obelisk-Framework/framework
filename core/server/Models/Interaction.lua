Interaction = BaseModel:extend('interactions')

Interaction.primaryKey = 'id'
Interaction.timestamps = true
Interaction.fillable = {
    'x', 'y', 'z', 'range', 'label', 'action_id', 'options', 'enabled',
    'owner_type', 'owner_id',
}
Interaction.casts = { options = 'json' }

function Interaction:owner()
    return self:morphTo('owner_type', 'owner_id')
end

return Interaction
