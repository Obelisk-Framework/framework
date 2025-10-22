--- Seeder: Default Keybinds
--- Creates global keybinds like E = Interact
return {
    run = function()
        print('[Seeder] Seeding default keybinds...')
        
        -- Check if keybinds already exist
        local existing = Database.querySync('SELECT COUNT(*) as count FROM keybinds WHERE is_global = 1', {})
        if existing and existing[1] and existing[1].count > 0 then
            print('[Seeder] Global keybinds already seeded, skipping')
            return
        end
        
        local keybinds = {
            {
                key_code = 'E',
                action_id = 'use_interaction',
                data = json.encode({}),
                is_global = 1,
                player_identifier = nil,
                enabled = 1
            }
        }
        
        for _, keybind in ipairs(keybinds) do
            Database.insertSync(
                [[INSERT INTO keybinds (key_code, action_id, data, is_global, player_identifier, enabled, created_at, updated_at) 
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
                {keybind.key_code, keybind.action_id, keybind.data, keybind.is_global, keybind.player_identifier, keybind.enabled, os.time(), os.time()}
            )
        end
        
        print('[Seeder] Seeded ' .. #keybinds .. ' default keybinds')
    end
}
