--- Obelisk Framework Bootstrap (Server)
--- Initializes all core systems and runs migrations/seeders

print([[
  
  ╔═══════════════════════════════════════╗
  ║   OBELISK FRAMEWORK - SERVER INIT    ║
  ║   Modern FiveM Framework v1.0.0      ║
  ╚═══════════════════════════════════════╝
  
]])

-- Initialize Database
Citizen.CreateThread(function()
    Database.init()
    
    print('[Obelisk] Database initialized')
    
    -- Run migrations
    local migrationsPath = GetResourcePath(GetCurrentResourceName()) .. '/core/server/database/migrations/'
    print('[Obelisk] Running migrations...')
    
    -- Check if migrations table exists
    if not Schema.hasTable('migrations') then
        Schema.create('migrations', function(table)
            table:id()
            table:string('migration', 255):unique()
            table:integer('batch')
            table:timestamp('created_at')
        end)
    end
    
    -- Load migrations from migrations.json
    local migrationsJsonPath = GetResourcePath(GetCurrentResourceName()) .. '/core/server/database/migrations.json'
    local migrationsJsonContent = LoadResourceFile(GetCurrentResourceName(), 'core/server/database/migrations.json')
    local migrationsData = json.decode(migrationsJsonContent) or { migrations = {} }
    local migrations = migrationsData.migrations or {}
    
    for _, migration in ipairs(migrations) do
        -- Check if already run
        local result = Database.querySync('SELECT * FROM migrations WHERE migration = ?', {migration})
        
        if not result or #result == 0 then
            print('[Obelisk] Running migration: ' .. migration)
            
            -- Load migration file
            local migrationModule = LoadResourceFile(GetCurrentResourceName(), 'core/server/database/migrations/' .. migration .. '.lua')
            
            if migrationModule then
                local migrationFunc = load(migrationModule)
                if migrationFunc then
                    local migrationTable = migrationFunc()
                    if migrationTable and migrationTable.up then
                        -- Run migration
                        local success, err = pcall(migrationTable.up)
                        if success then
                            -- Record migration
                            local res = Database.insertSync('INSERT INTO migrations (migration, batch, created_at) VALUES (?, ?, ?)', 
                                              {migration, 1, os.time()})
                            print("Result: " .. res)
                            print('[Obelisk] ✓ Migration completed: ' .. migration)
                        else
                            print('[Obelisk] ✗ Migration failed: ' .. migration .. ' - ' .. tostring(err))
                        end
                    end
                end
            end
        end
    end
    
    print('[Obelisk] Migrations complete')
    
    -- Run seeders
    print('[Obelisk] Running seeders...')
    
    local seeders = {
        'DefaultActionsSeeder',
        'DefaultKeybindsSeeder'
    }
    
    for _, seeder in ipairs(seeders) do
        local seederModule = LoadResourceFile(GetCurrentResourceName(), 'core/server/database/seeders/' .. seeder .. '.lua')
        
        if seederModule then
            local seederFunc = load(seederModule)
            if seederFunc then
                local seederTable = seederFunc()
                if seederTable and seederTable.run then
                    local success, err = pcall(seederTable.run)
                    if success then
                        print('[Obelisk] ✓ Seeder completed: ' .. seeder)
                    else
                        print('[Obelisk] ✗ Seeder failed: ' .. seeder .. ' - ' .. tostring(err))
                    end
                end
            end
        end
    end
    
    print('[Obelisk] Seeders complete')
    
    -- Register core actions
    print('[Obelisk] Registering core actions...')
    
    ActionService.register('use_interaction', function(source, data)
        -- This is handled by InteractionService
        print('[Action] use_interaction called by player ' .. source)
    end)
    
    print('[Obelisk] Core actions registered')
    
    print([[
  
  ╔═══════════════════════════════════════╗
  ║     OBELISK FRAMEWORK - READY        ║
  ╚═══════════════════════════════════════╝
  
]])
end)

-- Player connection handler
AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    deferrals.defer()
    
    Wait(0)
    deferrals.update('Loading Obelisk Framework...')
    
    Wait(100)
    deferrals.done()
end)

-- Player joined handler
AddEventHandler('playerJoining', function()
    local source = source
    print('[Obelisk] Player ' .. source .. ' joined, syncing data...')
end)

-- Player dropped handler
AddEventHandler('playerDropped', function(reason)
    local source = source
    print('[Obelisk] Player ' .. source .. ' left (' .. reason .. ')')
end)

-- Resource stop handler
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        print('[Obelisk] Framework stopping...')
    end
end)
