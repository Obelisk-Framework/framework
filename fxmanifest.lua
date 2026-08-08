fx_version 'cerulean'
game 'gta5'

author 'Obelisk Framework'
description 'Modern FiveM Framework with Lua, Vue 3, and MariaDB'
version '1.0.0'

-- Dependencies
dependencies {
    '/server:5848',
    '/onesync'
}

-- UI
ui_page 'core/html/index.html'

files {
    'core/html/**/*'
}

-- Shared scripts (load order matters)
shared_scripts {
    'core/shared/**/*.lua'
}

-- Server scripts
server_scripts {
    -- ORM Layer
    'core/server/ORM/Dialects/Init.lua',
    'core/server/ORM/Dialects/MySQL.lua',
    'core/server/ORM/Dialects/Postgres.lua',
    'core/server/ORM/Database.lua',
    'core/server/ORM/QueryBuilder.lua',
    'core/server/ORM/Schema.lua',
    'core/server/ORM/BaseModel.lua',
    
    -- Core Services
    'core/server/Services/Hooks.lua',
    'core/server/Services/ActionService.lua',
    'core/server/Services/InteractionService.lua',
    'core/server/Services/PolicyService.lua',
    'core/server/Services/NotificationService.lua',
    'core/server/Services/ProgressService.lua',
    'core/server/Services/KeybindService.lua',
    'core/server/Services/*.lua',
    
    -- Models
    'core/server/Models/**/*.lua',
    
    -- Policies
    'core/server/Policies/**/*.lua',
    
    -- Bootstrap
    'core/server/bootstrap.lua'
}

-- Client scripts
client_scripts {
    -- Client Services
    'core/client/Services/KeybindService.lua',
    'core/client/Services/InteractionService.lua',
    'core/client/Services/NotificationService.lua',
    'core/client/Services/ProgressService.lua',
    'core/client/Services/**/*.lua',
    
    -- Client Actions
    'core/client/actions/**/*.lua',
    
    -- Bootstrap
    'core/client/bootstrap.lua'
}
