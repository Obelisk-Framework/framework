# CLI Reference

Obelisk ships a code generator CLI (`core/cli/index.js`, built on `commander` and `inquirer`) with `make:*` commands for scaffolding modules, plugins, and the pieces that go inside them.

## Running the CLI

There are two ways to invoke it:

```bash
node cli/index.js make:module MyModule
```

or, after `npm link` (see [`/guide/installation`](/guide/installation)):

```bash
obelisk make:module MyModule
```

Every command resolves its generated paths relative to the current working directory (via `process.cwd()`), so **run these from inside `core/`** — that's where `modules/` and `plugins/` live. Running from anywhere else will create a `modules/` or `plugins/` folder wherever your shell happens to be.

The full command list, in the order `core/cli/index.js` registers them:

| Command | Description |
| --- | --- |
| `make:module [name]` | Create a new module |
| `make:plugin [name]` | Create a new plugin |
| `make:model [name]` | Create a new ORM model |
| `make:migration [name]` | Create a new database migration |
| `make:seeder [name]` | Create a new database seeder |
| `make:action [name]` | Create a new action handler |
| `make:interaction [name]` | Create a new interaction |
| `make:policy [name]` | Create a new policy |

## `make:module`

**Usage:** `obelisk make:module [name]`

If `name` is omitted, you're prompted:

```
Module name:
```
(required — `input.length > 0 || 'Module name is required'`)

The command then always asks:

```
Select features to include:
```
as a checkbox list — `Database Model` (checked), `Database Migration` (checked), `Database Seeder`, `Actions` (checked), `Interactions`, `Keybinds`, `Policies`, `Vue Component`, `Client Services` (checked), `Server Services` (checked).

**What it generates**, under `modules/<ModuleName>/` (the name with only its first letter capitalized, e.g. `myModule` → `MyModule`):

- No `fxmanifest.lua` of its own: the module's scripts load as part of `core`'s own resource, via the `modules/*/...` globs in the root `fxmanifest.lua`. Its name is appended to `modules/registry.json` instead (used by `core/server/bootstrap.lua` to run its migrations alongside core's).
- `README.md`
- `server/`, `client/`, `shared/` directories (always created)
- if `Database Model` selected: `server/models/<ModuleName>.lua`
- if `Database Migration` selected: `server/migrations/<timestamp>_create_<modulename>s_table.lua`
- if `Database Seeder` selected: `server/seeders/<ModuleName>Seeder.lua`
- if `Server Services` selected: `server/services/<ModuleName>Service.lua`
- if `Client Services` selected: `client/services/<ModuleName>Service.lua`
- if `Actions` selected: `server/actions/Example.lua`

**Example:**

```bash
obelisk make:module Garage
```

```
modules/Garage/
├── README.md
├── server/
│   ├── actions/
│   │   └── Example.lua
│   ├── models/
│   │   └── Garage.lua
│   ├── migrations/
│   │   └── 1723190400000_create_garages_table.lua
│   └── services/
│       └── GarageService.lua
├── client/
│   └── services/
│       └── GarageService.lua
└── shared/
```

## `make:plugin`

**Usage:** `obelisk make:plugin [name]`

If `name` is omitted:

```
Plugin name:
```
(required)

It then always prompts for:

```
Plugin description:
```
(default: `<PluginName> plugin for Obelisk`)

```
Author name:
```
(default: `Your Name`)

```
Select features to include:
```
checkbox — `Database Tables` (checked), `Actions` (checked), `Interactions`, `Keybinds`, `Commands`, `Vue UI Page` (checked), `API Endpoints`.

**What it generates**, under `plugins/<PluginName>/`:

- No `fxmanifest.lua` of its own: the plugin's scripts load as part of `core`'s own resource, via the `plugins/*/...` globs in the root `fxmanifest.lua`. Its name is appended to `plugins/registry.json` instead (used by `core/server/bootstrap.lua` to run its migrations alongside core's).
- `shared/config.lua`
- `README.md`
- `server/main.lua` and `client/main.lua` (always created)
- if `Database Tables` selected: `server/migrations/<timestamp>_create_<pluginname>_table.lua` (creates a `<pluginname>_data` table)
- if `Actions` selected: `server/actions/ExampleAction.lua`
- if `Commands` selected: `server/commands/ExampleCommand.lua`
- if `Vue UI Page` selected: `web/package.json` (Vite + Vue 3 + Tailwind) and `web/src/components/<PluginName>.vue`

**Example:**

```bash
obelisk make:plugin Garage
```

```
plugins/Garage/
├── README.md
├── shared/
│   └── config.lua
├── server/
│   ├── main.lua
│   ├── migrations/
│   │   └── 1723190400000_create_garage_table.lua
│   └── actions/
│       └── ExampleAction.lua
├── client/
│   └── main.lua
└── web/
    ├── package.json
    └── src/
        └── components/
            └── Garage.vue
```

## `make:model`

**Usage:** `obelisk make:model [name]`

If `name` is omitted:

```
Model name (singular, e.g., User):
```
(required)

Always prompted:

```
Table name (plural):
```
(default: `<modelname>s`)

```
Where should the model be created?
```
list — `Core`, `Module`, `Plugin`. Choosing `Module` or `Plugin` prompts `Select module:` / `Select plugin:` from the existing directories under `modules/` / `plugins/` (and aborts with "No modules found." / "No plugins found." if none exist).

**What it generates:**

- `Core` → `core/server/Models/<ModelName>.lua`
- `Module` → `modules/<module>/server/models/<ModelName>.lua`
- `Plugin` → `plugins/<plugin>/server/models/<ModelName>.lua`

**Example:**

```bash
obelisk make:model Vehicle
# Table name (plural): vehicles
# Where should the model be created? Module
# Select module: Garage
```

```
modules/Garage/server/models/Vehicle.lua
```

## `make:migration`

**Usage:** `obelisk make:migration [name]`

If `name` is omitted:

```
Migration name (e.g., create_users_table):
```
(required)

Always prompted:

```
Where should the migration be created?
```
list — `Core`, `Module`, `Plugin` (same module/plugin selection behavior as `make:model`).

**What it generates:** a file named `<yyyy>_<mm>_<dd>_<HHMMSS>_<name>.lua`, plus an updated `migrations.json` alongside it (the migration name is appended to a `migrations` array):

- `Core` → `core/server/database/migrations/` and `core/server/database/migrations.json`
- `Module` → `modules/<module>/server/migrations/` and `modules/<module>/server/migrations.json`
- `Plugin` → `plugins/<plugin>/server/migrations/` and `plugins/<plugin>/server/migrations.json`

If the migration name matches `create_<table>_table`, the generated content is a ready-made `Schema.create(...)` migration for that table; otherwise it's a generic `Schema.table(...)` stub.

**Example:**

```bash
obelisk make:migration create_garages_table
# Where should the migration be created? Core
```

```
core/server/database/migrations/2026_08_09_143022_create_garages_table.lua
core/server/database/migrations.json   (updated)
```

## `make:seeder`

**Usage:** `obelisk make:seeder [name]`

If `name` is omitted:

```
Seeder name (e.g., UsersSeeder):
```
(required — the CLI appends `Seeder` to the name if it doesn't already end with it)

Always prompted:

```
Where should the seeder be created?
```
list — `Core`, `Module`, `Plugin`.

**What it generates:**

- `Core` → `core/server/database/seeders/<Name>Seeder.lua`
- `Module` → `modules/<module>/server/seeders/<Name>Seeder.lua`
- `Plugin` → `plugins/<plugin>/server/seeders/<Name>Seeder.lua`

**Example:**

```bash
obelisk make:seeder Garages
# Where should the seeder be created? Module
# Select module: Garage
```

```
modules/Garage/server/seeders/GaragesSeeder.lua
```

## `make:action`

**Usage:** `obelisk make:action [name]`

If `name` is omitted:

```
Action name (e.g., OpenDoor):
```
(required)

Always prompted:

```
Action ID (snake_case):
```
(default: derived by converting `PascalCase`/`camelCase` to `snake_case`)

```
Where should the action be created?
```
list — `Core`, `Module`, `Plugin`.

**What it generates:**

- `Core` → `core/server/actions/<Name>.lua`
- `Module` → `modules/<module>/server/actions/<Name>.lua`
- `Plugin` → `plugins/<plugin>/server/actions/<Name>.lua`

The generated file is a `return function(source, data) ... end` handler with player-existence checks and `NotificationService` calls already stubbed in, and the command prints a reminder to register it with `ActionService.register('<actionId>', require('<path>'))`.

**Example:**

```bash
obelisk make:action OpenGarageDoor
# Action ID (snake_case): open_garage_door
# Where should the action be created? Module
# Select module: Garage
```

```
modules/Garage/server/actions/OpenGarageDoor.lua
```

## `make:interaction`

**Usage:** `obelisk make:interaction [name]`

If `name` is omitted:

```
Interaction name (e.g., ATM):
```
(required)

Always prompted:

```
Interaction label (shown to player):
```
(default: `Use <name>`)

```
Action ID to trigger:
```
(default: the name lowercased with spaces replaced by underscores)

```
Where should the interaction be created?
```
list — **`Module`, `Plugin` only** (no `Core` option, unlike the other generators).

**What it generates:**

- `Module` → `modules/<module>/server/interactions/<Name>Interaction.lua`
- `Plugin` → `plugins/<plugin>/server/interactions/<Name>Interaction.lua`

The file registers one or more interaction points via `InteractionService.register(...)` inside a `Citizen.CreateThread`, with placeholder `x/y/z` coordinates you're expected to fill in — the command prints a reminder to update the coordinates and to make sure the target action exists.

**Example:**

```bash
obelisk make:interaction Garage
# Interaction label (shown to player): Use Garage
# Action ID to trigger: garage
# Where should the interaction be created? Module
# Select module: Garage
```

```
modules/Garage/server/interactions/GarageInteraction.lua
```

## `make:policy`

**Usage:** `obelisk make:policy [name]`

If `name` is omitted:

```
Policy name (e.g., HasPermission):
```
(required)

Always prompted:

```
Policy ID (camelCase):
```
(default: the name with its first letter lowercased)

```
Policy description:
```
(default: `Checks if <name> requirement is met`)

```
Where should the policy be created?
```
list — `Core`, `Module`, `Plugin`.

**What it generates:**

- `Core` → `core/server/Policies/<Name>Policy.lua`
- `Module` → `modules/<module>/server/policies/<Name>Policy.lua`
- `Plugin` → `plugins/<plugin>/server/policies/<Name>Policy.lua`

The generated file defines a validator function and calls `PolicyService.register('<policyId>', validator, { description = '...' })`; the command prints a usage example showing `PolicyService.attach('interaction', interactionId, '<policyId>', { ... })`.

**Example:**

```bash
obelisk make:policy OwnsVehicle
# Policy ID (camelCase): ownsVehicle
# Policy description: Checks if ownsvehicle requirement is met
# Where should the policy be created? Module
# Select module: Garage
```

```
modules/Garage/server/policies/OwnsVehiclePolicy.lua
```
