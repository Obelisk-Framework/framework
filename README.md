# Obelisk Framework

**Modern FiveM Framework** built with advanced design patterns, Eloquent-inspired ORM, Vue 3 UI, and MariaDB.

## 🌟 Features

### Core Systems
- **Eloquent-Style ORM** - Laravel-inspired models with relationships (hasOne, hasMany, belongsTo, belongsToMany)
- **Query Builder** - Fluent SQL query construction with method chaining
- **Schema Builder** - Migration-based database schema management
- **Action System** - Registry pattern for game actions with hook integration
- **Interaction System** - Spatial query system for world interactions
- **Keybind System** - Database-persisted keybinds with action composition
- **Policy System** - Composable authorization middleware with n-n relationships
- **Notification Service** - Queue-based cross-context notifications
- **Progress Service** - Queue-based progress bars with Vue UI
- **Hook System** - Extensibility points throughout the framework

### UI/UX
- **Vue 3** with Composition API
- **TailwindCSS** for styling
- **Global Components** - Always-visible notifications and progress bars
- **Route Management** - Dynamic page navigation from Lua
- **NUI Integration** - Seamless Lua ↔ Vue communication

### Developer Experience
- **Interactive CLI** - Code generators for modules, plugins, models, migrations, etc.
- **Hot Module Replacement** - Vue dev server with live reload
- **Comprehensive Logging** - Debug-friendly console output
- **Type Hints** - LuaLS annotations for better IDE support

## 📁 Project Structure

```
obelisk/
├── core/                      # Framework core
│   ├── server/
│   │   ├── ORM/              # Database abstraction layer
│   │   ├── Services/         # Core services
│   │   ├── Models/           # ORM models
│   │   ├── Policies/         # Authorization policies
│   │   ├── Commands/         # FiveM commands
│   │   └── database/         # Migrations & seeders
│   ├── client/
│   │   ├── services/         # Client services
│   │   └── actions/          # Client action handlers
│   └── shared/               # Shared utilities
├── modules/                   # Core game modules
│   ├── Items/
│   ├── Vehicles/
│   └── Organizations/
├── plugins/                   # Feature plugins
│   ├── Garage/
│   ├── Inventory/
│   └── Banking/
├── web/                       # Vue 3 UI
│   └── src/
│       ├── components/
│       │   └── global/       # Global components
│       ├── composables/      # Vue composables
│       └── router/           # Vue Router
├── cli/                       # Code generators
│   ├── commands/
│   └── stubs/
└── docker-compose.yml         # MariaDB container
```

## 🚀 Quick Start

### Prerequisites
- FiveM Server (artifacts 5848+)
- Node.js 18+ and npm
- Docker & Docker Compose (for database) - optional, can use external MySQL

### Installation

1. **Clone the framework**
   ```bash
   cd resources
   git clone <repository-url> obelisk
   cd obelisk
   ```

2. **Install Node dependencies**
   ```bash
   npm install
   ```

3. **Install Vue dependencies**
   ```bash
   cd web
   npm install
   npm run build
   cd ..
   ```

4. **Start MariaDB**
   ```bash
   docker-compose up -d
   ```

5. **Configure database connection**
   
   Add to your `server.cfg`:
   ```cfg
   set mysql_connection_string "mysql://obelisk:obelisk_password@localhost:3306/fivem"
   set db_debug 0
   
   ensure obelisk
   ```
   
   **Note:** Obelisk has its own built-in database manager. If you have oxmysql, mysql-async, or ghmattimysql installed, it will automatically use them for better performance. Otherwise, it uses an in-memory fallback for development.

6. **Start your server**
   
   Migrations and seeders run automatically on first start.

## 🛠️ CLI Usage

The Obelisk CLI provides interactive code generators:

### Create a Module
```bash
npm run make:module
# Or with name:
npm run make:module Items
```

### Create a Plugin
```bash
npm run make:plugin
# Or:
npm run make:plugin Banking
```

### Create a Model
```bash
npm run make:model User
```

### Create a Migration
```bash
npm run make:migration create_users_table
```

### Create a Seeder
```bash
npm run make:seeder UsersSeeder
```

### Create an Action
```bash
npm run make:action OpenDoor
```

### Create an Interaction
```bash
npm run make:interaction ATM
```

### Create a Policy
```bash
npm run make:policy HasPermission
```

## 📚 Core Concepts

### ORM Models

Define models that extend `BaseModel`:

```lua
User = {}
setmetatable(User, { __index = BaseModel })

User.table = 'users'
User.primaryKey = 'id'
User.timestamps = true
User.fillable = {'name', 'email'}
User.hidden = {'password'}

function User.new(attributes)
    local instance = BaseModel.new(attributes)
    setmetatable(instance, { __index = User })
    instance.table = User.table
    instance.primaryKey = User.primaryKey
    instance.timestamps = User.timestamps
    return instance
end

-- Define relationships
function User:posts()
    return self:hasMany(Post, 'user_id', 'id')
end

function User:profile()
    return self:hasOne(Profile, 'user_id', 'id')
end

return User
```

**Usage:**
```lua
-- Create
local user = User:createSync({name = 'John', email = 'john@example.com'})

-- Find
local user = User:findSync(1)

-- Query
local users = User:newQuery():where('active', 1):getSync()

-- Update
user:set('name', 'Jane')
user:saveSync()

-- Relationships
local posts = user:loadSync('posts')
```

### Actions

Register actions that can be triggered from keybinds, interactions, or UI:

```lua
ActionService.register('open_door', function(source, data)
    local doorId = data.doorId
    
    -- Your logic
    NotificationService.success(source, 'Door', 'Door opened!')
end)
```

### Interactions

Create world interaction points:

```lua
local interactionId = InteractionService.register({
    x = 123.45,
    y = -456.78,
    z = 28.50,
    range = 2.0,
    label = 'Open Door',
    action = 'open_door'
})
```

### Policies

Create reusable authorization policies:

```lua
PolicyService.register('hasKey', function(source, resource, config)
    local hasKey = Inventory.hasItem(source, config.keyId)
    
    if not hasKey then
        return false, 'You need a key'
    end
    
    return true
end)

-- Attach to interaction
PolicyService.attach('interaction', interactionId, 'hasKey', {
    keyId = 5
})
```

### Keybinds

Register global or player-specific keybinds:

```lua
-- Global keybind (all players)
KeybindService.registerGlobal('E', 'use_interaction')

-- Player-specific
KeybindService.registerPlayer(source, 'F', 'custom_action')
```

### Notifications

Send notifications to players:

```lua
-- Server-side
NotificationService.success(source, 'Title', 'Description', 5000)
NotificationService.error(source, 'Error', 'Something went wrong')
NotificationService.warning(source, 'Warning', 'Be careful')
NotificationService.info(source, 'Info', 'Good to know')

-- Client-side
NotificationService.success('Title', 'Description')
```

### Progress Bars

Display progress bars:

```lua
-- Server-side
local progressId = ProgressService.start(source, {
    label = 'Opening door...',
    duration = 5000,
    canCancel = true
}, function(source)
    -- On complete
    print('Progress completed')
end, function(source)
    -- On cancel
    print('Progress cancelled')
end)
```

### Migrations

Create database tables with fluent syntax:

```lua
return {
    up = function()
        Schema.create('users', function(table)
            table:id()
            table:string('name', 255):notNullable()
            table:string('email', 255):unique()
            table:integer('level'):default(1)
            table:boolean('active'):default(1)
            table:timestamps()
            
            table:index({'email'})
        end)
    end,
    
    down = function()
        Schema.drop('users')
    end
}
```

### Vue 3 Components

Global components are always mounted:

```vue
<template>
  <div class="my-component">
    <Notifications />
    <ProgressBars />
  </div>
</template>

<script setup>
import { useNui } from '@/composables/useNui'

const { sendCallback } = useNui()

const handleClick = () => {
  sendCallback('myCallback', { data: 'value' })
}
</script>
```

## 🔧 Configuration

### Database

Edit `docker-compose.yml` to change database credentials.

Set connection string in `server.cfg`:
```cfg
set mysql_connection_string "mysql://user:pass@host:port/database"
```

### Debug Mode

Enable debug logging:
```cfg
set db_debug 1
```

## 📖 Advanced Usage

### Custom Module Example

```bash
npm run make:module Banking
```

This creates:
- `modules/Banking/` directory
- Server/client services
- Database migration
- Model class
- Example actions

### Custom Plugin Example

```bash
npm run make:plugin Garage
```

Creates a complete plugin structure with:
- Server/client logic
- Vue UI (optional)
- Database tables (optional)
- Actions and commands

## 🏗️ Architecture

### Design Patterns

- **Active Record** (ORM Models)
- **Repository Pattern** (Database abstraction)
- **Service Layer** (Business logic)
- **Policy Pattern** (Authorization)
- **Observer Pattern** (Hooks)
- **Command Pattern** (Actions)
- **Strategy Pattern** (Policies)

### Data Flow

```
Client → KeybindService → ActionService → PolicyService → Business Logic
                ↓
         InteractionService → PolicyService → ActionService
                ↓
         NotificationService ← Server/Client
```

## 🤝 Contributing

Contributions welcome! Please follow these guidelines:

1. Use the CLI generators for consistency
2. Follow existing code style
3. Add comments for complex logic
4. Test migrations up and down
5. Update documentation

## 📄 License

MIT License - See LICENSE file for details

## 🙏 Credits

Built with modern FiveM development practices and inspired by Laravel's elegant syntax.

## 📞 Support

- GitHub Issues: [Create an issue]
- Discord: [Join our server]
- Documentation: [Read the docs]

---

**Happy Coding! 🚀**
