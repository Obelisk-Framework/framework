--- Seeder: Default Actions
return {
    run = function()
        print('[Seeder] Seeding default actions...')

        local Action = BaseModel:extend('actions')

        local actions = {
            {
                action_id = 'use_interaction',
                label = 'Use Interaction',
                description = 'Triggers the closest interaction point',
                options = json.encode({}),
                enabled = 1
            }
        }

        for _, action in ipairs(actions) do
            Action:firstOrCreate({action_id = action.action_id}, action)
        end

        print('[Seeder] Seeded ' .. #actions .. ' default action(s) (idempotent)')
    end
}
