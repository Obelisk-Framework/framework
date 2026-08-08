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
    if not Database.init() then
        print('[Obelisk] Startup aborted: no database connector available. See the [Database] FATAL message above.')
        return
    end

    print('[Obelisk] Database initialized')
    
    -- Run migrations
    print('[Obelisk] Running migrations...')

    if not Schema.hasTable('migrations') then
        Schema.create('migrations', function(table)
            table:id()
            table:string('migration', 255):unique()
            table:integer('batch')
            table:timestamp('created_at')
        end)
    end

    local function runMigrationsAt(basePath, label)
        local migrationsJsonContent = LoadResourceFile(GetCurrentResourceName(), basePath .. 'migrations.json')
        local migrationsData = json.decode(migrationsJsonContent or '') or { migrations = {} }
        local migrations = migrationsData.migrations or {}

        for _, migration in ipairs(migrations) do
            local result = Database.querySync('SELECT * FROM migrations WHERE migration = ?', {migration})
            if not result or #result == 0 then
                print('[Obelisk] Running migration (' .. label .. '): ' .. migration)
                local migrationModule = LoadResourceFile(GetCurrentResourceName(), basePath .. 'migrations/' .. migration .. '.lua')
                if migrationModule then
                    local migrationFunc = load(migrationModule)
                    if migrationFunc then
                        local migrationTable = migrationFunc()
                        if migrationTable and migrationTable.up then
                            local success, err = pcall(migrationTable.up)
                            if success then
                                local res = Database.insertSync('INSERT INTO migrations (migration, batch, created_at) VALUES (?, ?, ?)',
                                                  {migration, 1, Database.now()})
                                print("Result: " .. tostring(res))
                                print('[Obelisk] Migration completed (' .. label .. '): ' .. migration)
                            else
                                print('[Obelisk] Migration failed (' .. label .. '): ' .. migration .. ' - ' .. tostring(err))
                            end
                        end
                    end
                end
            end
        end
    end

    local function loadRegistry(path, key)
        local content = LoadResourceFile(GetCurrentResourceName(), path)
        if not content then
            return {}
        end
        local decoded = json.decode(content)
        if not decoded then
            print('[Obelisk] WARNING: could not parse ' .. path)
            return {}
        end
        return decoded[key] or {}
    end

    runMigrationsAt('core/server/database/', 'core')

    for _, name in ipairs(loadRegistry('modules/registry.json', 'modules')) do
        runMigrationsAt('modules/' .. name .. '/server/', name)
    end

    for _, name in ipairs(loadRegistry('plugins/registry.json', 'plugins')) do
        runMigrationsAt('plugins/' .. name .. '/server/', name)
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
