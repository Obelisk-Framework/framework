--- Obelisk Framework Bootstrap (Server)
--- Initializes all core systems and runs migrations/seeders

print([[
  
  ╔═══════════════════════════════════════╗
  ║   OBELISK FRAMEWORK - SERVER INIT    ║
  ║   Modern FiveM Framework v1.0.0      ║
  ╚═══════════════════════════════════════╝
  
]])

-- Initialize Storage (no DB dependency, so this doesn't need to wait on the
-- Database.init() thread below).
if not Storage.init() then
    print('[Obelisk] WARNING: storage service failed to initialize. See the [Storage] FATAL message above. Continuing without file storage.')
end

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
        local ok, migrationsData = pcall(json.decode, migrationsJsonContent or '')
        if not ok or not migrationsData then
            migrationsData = { migrations = {} }
        end
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
        local ok, decoded = pcall(json.decode, content)
        if not ok or not decoded then
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

    -- Load each plugin's Config.Requires.bindings and register with ItemService,
    -- then report anything unbound (setup checklist) or stale (assigned but no
    -- loaded plugin needs it) — see docs/superpowers/specs/2026-08-12-banking-plugin-design.md §3.6.
    local pluginNames = loadRegistry('plugins/registry.json', 'plugins')
    for _, pluginName in ipairs(pluginNames) do
        local configPath = 'plugins/' .. pluginName .. '/shared/config.lua'
        local configContent = LoadResourceFile(GetCurrentResourceName(), configPath)
        if configContent then
            local chunk = load(configContent, configPath, 't', {})
            if chunk then
                local ok, pluginConfig = pcall(chunk)
                if ok and pluginConfig and pluginConfig.Requires and pluginConfig.Requires.bindings then
                    ItemService.registerRequirements(pluginName, pluginConfig.Requires.bindings)
                end
            end
        end
    end

    do
        local unbound = {}
        for _, key in ipairs(ItemService.getRequiredBindingKeys and ItemService.getRequiredBindingKeys() or {}) do
            if not ItemService.hasBinding(key) then
                table.insert(unbound, key)
            end
        end
        if #unbound > 0 then
            print('[Obelisk] ' .. #unbound .. ' item binding(s) unbound, dependent features inactive: ' .. table.concat(unbound, ', '))
        end
    end

    -- Flush any actions that were registered by modules/plugins during the
    -- synchronous script-load pass, before Database.init() had run. Must
    -- happen before seeders, since a seeder may need to resolve an action
    -- string to its db id.
    ActionService.flushPendingRegistrations()

    -- Run seeders
    print('[Obelisk] Running seeders...')
    
    local seeders = {
        'DefaultActionsSeeder'
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
    
    ActionService.register('use_interaction', function(player, data)
        -- This is handled by InteractionService
        print('[Action] use_interaction called by player ' .. player:getSource())
    end, { label = 'Interact', default_key = 'E' })
    
    print('[Obelisk] Core actions registered')

    -- Start the scheduler's poll loop last, once every other boot step
    -- (migrations, seeders, core actions) has completed -- scheduled jobs
    -- may reference actions that were only just registered above.
    SchedulerService.startTickLoop()

    print([[
  
  ╔═══════════════════════════════════════╗
  ║     OBELISK FRAMEWORK - READY        ║
  ╚═══════════════════════════════════════╝
  
]])
end)

-- Player connection handler
Obelisk.on('playerConnecting', function(name, setKickReason, deferrals)
    deferrals.defer()

    Wait(0)
    deferrals.update('Loading Obelisk Framework...')

    Wait(100)
    deferrals.done()
end)

-- Resource stop handler
Obelisk.on('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        print('[Obelisk] Framework stopping...')
    end
end)
