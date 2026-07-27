--- Seeder: Default Actions
return {
    run = function()
        print('[Seeder] Seeding default actions...')
        
        -- Check if actions already exist
        local existing = Database.querySync('SELECT COUNT(*) as count FROM actions', {})
        if existing and existing[1] and existing[1].count > 0 then
            print('[Seeder] Actions already seeded, skipping')
            return
        end
        
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
            Database.insertSync(
                'INSERT INTO actions (action_id, label, description, options, enabled, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                {action.action_id, action.label, action.description, action.options, action.enabled, Database.now(), Database.now()}
            )
        end
        
        print('[Seeder] Seeded ' .. #actions .. ' default actions')
    end
}
