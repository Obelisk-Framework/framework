# Obelisk Framework - Documentation Index

## Getting Started

| File | Purpose |
|------|---------|
| **README_FIRST.txt** | Start here! Overview and quick commands |
| **QUICK_START.md** | Step-by-step setup checklist |
| **README.md** | Complete framework documentation |

## Development

| File | Purpose |
|------|---------|
| **AGENTS.md** | Development guidelines for agents/AI |
| **core/server/ORM/** | Database ORM documentation |
| **cli/commands/** | Code generator CLI tools |

## MySQL & Database

| File | Purpose |
|------|---------|
| **SETUP_MYSQL.md** | Detailed MySQL configuration guide |
| **MYSQL_CONNECTOR_SETUP.txt** | Quick MySQL troubleshooting |
| **resources/oblsk_connector/** | MySQL connector documentation |
| **core/server/database/migrations.json** | Migration registry |

## Framework Architecture

### Server-Side (Lua)
```
core/server/
├── ORM/
│   ├── Database.lua          # Database manager
│   ├── BaseModel.lua         # Base model class
│   ├── QueryBuilder.lua      # Query builder
│   └── Schema.lua            # Schema builder
├── Services/
│   ├── ActionService.lua     # Action registry
│   ├── InteractionService.lua # World interactions
│   ├── KeybindService.lua    # Keybind management
│   ├── PolicyService.lua     # Authorization
│   ├── NotificationService.lua # Notifications
│   └── Others...
├── Policies/                 # Authorization policies
├── database/
│   ├── migrations/           # Database migrations
│   ├── migrations.json       # Migration registry
│   └── seeders/              # Database seeders
└── bootstrap.lua             # Server initialization
```

### Client-Side (Lua)
```
core/client/
├── Services/                 # Client services
├── actions/                  # Action handlers
└── bootstrap.lua             # Client initialization
```

### Frontend (Vue 3)
```
web/src/
├── components/
│   └── global/               # Global components
├── composables/
│   └── useNui.js            # NUI integration
├── pages/                    # Page components
├── router/                   # Vue Router config
└── main.js                   # Vue entry point
```

### Code Generators (CLI)
```
cli/
├── commands/
│   ├── make-module.js        # Module generator
│   ├── make-plugin.js        # Plugin generator
│   ├── make-model.js         # Model generator
│   ├── make-migration.js     # Migration generator
│   ├── make-action.js        # Action generator
│   ├── make-policy.js        # Policy generator
│   └── Others...
└── stubs/                    # Template files
```

### MySQL Connector
```
resources/oblsk_connector/
├── fxmanifest.lua           # Resource manifest
├── server.lua               # Connector wrapper
├── README.md                # Connector docs
└── INSTALL.txt              # Installation guide
```

## Common Tasks

### Database Setup
1. Read: **SETUP_MYSQL.md**
2. Install MySQL library (ghmattimysql recommended)
3. Update server.cfg
4. Start MariaDB: `docker-compose up -d`

### Create a Module
```bash
npm run make:module MyModule
# See: modules/MyModule/
```

### Create a Database Model
```bash
npm run make:model User
# See: core/server/Models/User.lua
```

### Create a Migration
```bash
npm run make:migration create_users_table
# See: core/server/database/migrations/
```

### Build Vue Frontend
```bash
cd web
npm run build
# Output: core/html/
```

## Code Style & Conventions

See **AGENTS.md** for:
- Lua naming conventions (CamelCase functions, snake_case IDs)
- Vue 3 composition API patterns
- Import/require conventions
- Error handling practices
- Type hints and annotations
- Hook system usage

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No MySQL connector found" | Read MYSQL_CONNECTOR_SETUP.txt |
| "Connection refused" | Check MariaDB is running: `docker ps` |
| "Build failed" | See QUICK_START.md § Build fails |
| Import errors | Check vite.config.js alias configuration |

## External Resources

- **FiveM Documentation**: https://docs.fivem.net
- **Lua Guide**: https://www.lua.org/manual/5.4/
- **Vue 3 Guide**: https://vuejs.org/
- **TailwindCSS**: https://tailwindcss.com/

## Framework Features

### ORM
- Active Record pattern (Laravel-inspired)
- Relationships: hasOne, hasMany, belongsTo, belongsToMany
- Query builder with method chaining
- Migrations and seeders
- Schema builder with fluent API

### Services
- Action system with event hooks
- Interaction service for world interactions
- Keybind management with persistence
- Policy-based authorization
- Notification queue system
- Progress bar system

### Frontend
- Vue 3 with Composition API
- TailwindCSS v3 styling
- Vue Router for navigation
- NUI integration for Lua ↔ Vue communication
- Global notification system

### CLI Generators
- Interactive prompts
- Boilerplate generation
- Stub templates
- Automatic file organization

## License

MIT - See LICENSE file

---

**Last Updated**: October 22, 2025
**Framework Version**: 1.0.0
