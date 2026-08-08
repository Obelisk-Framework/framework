# Building a Plugin

This is a full, end-to-end walkthrough: scaffold a plugin, add a model, a migration, an action, and a policy, then load it on a running server and confirm it starts. It builds on the CLI commands documented in the [CLI Reference](/cli/index) and the concepts covered in [ORM](/concepts/orm) and [Services](/concepts/services) — read those first if any of the vocabulary here (`Schema.create`, `ActionService.register`, `PolicyService`) is unfamiliar.

The example plugin is `TownHall` — a minimal town-hall building players can be assigned as mayor of. It's deliberately small; for two more fleshed-out, production-style plugins, see [Existing Plugins](/reference/existing-plugins) once you're done here.

All commands below are run from inside `core/` (see [Installation](/guide/installation) for why — the CLI resolves generated paths relative to `process.cwd()`), using `obelisk` after `npm link`. If you haven't linked the CLI, substitute `node cli/index.js` for `obelisk` in every command.

## 1. Scaffold the plugin

```bash
obelisk make:plugin TownHall
```

If you don't pass a name on the command line, the CLI prompts for one:

```
Plugin name:
```

It then always asks two more questions:

```
Plugin description: (TownHall plugin for Obelisk)
Author name: (Your Name)
```

Press enter to accept the defaults, or type your own. Finally, a checkbox list of features:

```
Select features to include:
 ◉ Database Tables
 ◉ Actions
 ◯ Interactions
 ◯ Keybinds
 ◯ Commands
 ◉ Vue UI Page
 ◯ API Endpoints
```

`Database Tables`, `Actions`, and `Vue UI Page` are checked by default. For this tutorial, keep `Database Tables` and `Actions` checked, and uncheck `Vue UI Page` (space to toggle) — we won't be touching the UI layer here.

That generates:

```
plugins/TownHall/
├── fxmanifest.lua
├── README.md
├── shared/
│   └── config.lua
├── server/
│   ├── main.lua
│   ├── migrations/
│   │   └── <timestamp>_create_townhall_table.lua
│   └── actions/
│       └── ExampleAction.lua
└── client/
    └── main.lua
```

`server/main.lua` is the file worth looking at now, since we'll come back to it in Step 6 — it's what prints to the server console when the plugin loads:

```lua
--- TownHall Plugin - Server Main
print('[TownHall] Loading...')

-- Initialize plugin
Citizen.CreateThread(function()
    -- Run migrations
    -- Add migration runner here

    print('[TownHall] Loaded successfully!')
end)

-- Register actions
ActionService.register('townhall_example', function(source, data)
    print('[TownHall] Action triggered')
end)
```

The generated migration (`server/migrations/<timestamp>_create_townhall_table.lua`) creates a generic `townhall_data` table with a `player_identifier` and a JSON `data` blob — a reasonable default for "some plugin needs to store per-player state," but not what we want for TownHall's own domain data. We'll leave that generated migration alone and write a purpose-built one in Step 3.

## 2. Add a model

```bash
obelisk make:model TownHall
```

Since `TownHall` was passed on the command line, the CLI skips straight to:

```
Table name (plural): (townhalls)
```

Type `town_halls` to match the migration we're about to write (the default `townhalls` has no underscore — override it).

```
Where should the model be created?
❯ Core
  Module
  Plugin
```

Choose `Plugin`, which prompts:

```
Select plugin:
❯ TownHall
```

This writes `plugins/TownHall/server/models/TownHall.lua`:

```lua
--- TownHall Model
TownHall = {}
setmetatable(TownHall, { __index = BaseModel })

-- Table configuration
TownHall.table = 'town_halls'
TownHall.primaryKey = 'id'
TownHall.timestamps = true
TownHall.fillable = {'name', 'description'}
TownHall.hidden = {}
TownHall.casts = {}

--- Create a new TownHall instance
--- @param attributes table
--- @return TownHall
function TownHall.new(attributes)
    local instance = BaseModel.new(attributes)
    setmetatable(instance, { __index = TownHall })

    -- Copy class properties
    instance.table = TownHall.table
    instance.primaryKey = TownHall.primaryKey
    instance.timestamps = TownHall.timestamps
    instance.fillable = TownHall.fillable
    instance.hidden = TownHall.hidden
    instance.casts = TownHall.casts

    return instance
end

--- Custom methods
function TownHall:customMethod()
    -- Add custom logic here
end

return TownHall
```

The generator's `fillable` default (`{'name', 'description'}`) doesn't match our actual columns yet — edit it once the migration below is in place:

```lua
TownHall.fillable = {'name', 'mayor'}
```

This is the same `BaseModel:extend`-style pattern documented in [ORM: Models](/concepts/orm#models), just written out explicitly rather than via `extend()` — both produce a model with the same `find`/`save`/`create` helpers.

## 3. Write a migration

```bash
obelisk make:migration create_town_halls_table
```

```
Where should the migration be created?
❯ Core
  Module
  Plugin
```

Choose `Plugin`, then `TownHall` from the plugin list. Because the migration name matches the `create_<table>_table` pattern, the CLI infers the table name (`town_halls`) and generates a ready-made `Schema.create` migration rather than a generic `Schema.table` stub, writing it to `plugins/TownHall/server/migrations/<yyyy>_<mm>_<dd>_<HHMMSS>_create_town_halls_table.lua` (and appending `create_town_halls_table` to `plugins/TownHall/server/migrations.json`):

```lua
--- Migration: Create town_halls table
return {
    up = function()
        Schema.create('town_halls', function(table)
            table:id()
            -- Add your columns here
            table:string('name', 255):notNullable()
            table:timestamps()
        end)

        print('[Migration] Created town_halls table')
    end,

    down = function()
        Schema.drop('town_halls')
        print('[Migration] Dropped town_halls table')
    end
}
```

Fill in the real columns for TownHall — a `name` and a `mayor`, using the `Schema`/`Blueprint` API from [ORM: Schema & Migrations](/concepts/orm#schema-migrations):

```lua
--- Migration: Create town_halls table
return {
    up = function()
        Schema.create('town_halls', function(table)
            table:id()
            table:string('name', 255):notNullable()
            table:string('mayor', 255)
            table:timestamps()
        end)

        print('[Migration] Created town_halls table')
    end,

    down = function()
        Schema.drop('town_halls')
        print('[Migration] Dropped town_halls table')
    end
}
```

This matches `TownHall.fillable = {'name', 'mayor'}` from Step 2.

## 4. Add an action

```bash
obelisk make:action AssignMayor
```

```
Action ID (snake_case): (assign_mayor)
Where should the action be created?
❯ Core
  Module
  Plugin
```

Choose `Plugin` → `TownHall`. This writes `plugins/TownHall/server/actions/AssignMayor.lua`, a `return function(source, data) ... end` handler with player-existence checks and `NotificationService` calls already stubbed in:

```lua
--- AssignMayor Action
--- Action ID: assign_mayor
--- Triggered by: keybinds, interactions, or manual calls

return function(source, data)
    print('[AssignMayor] Triggered by player ' .. source)

    -- Validate player exists
    if not source or source == 0 then
        print('[AssignMayor] Invalid player source')
        return
    end

    -- Get player data
    local playerPed = GetPlayerPed(source)
    if not DoesEntityExist(playerPed) then
        print('[AssignMayor] Player entity does not exist')
        return
    end

    -- Your action logic here
    local canPerformAction = true

    if not canPerformAction then
        NotificationService.error(source, 'AssignMayor', 'Cannot perform this action')
        return
    end

    -- Execute action
    -- Add your logic here

    -- Send success notification
    NotificationService.success(source, 'AssignMayor', 'Action completed successfully')
end
```

The CLI also prints a reminder that you still need to wire it into `ActionService`:

```
Remember to register this action in your initialization code:
ActionService.register('assign_mayor', require('plugins/TownHall/server/actions/AssignMayor.lua'))
```

Fill in the actual logic — updating the `TownHall` row's `mayor` column — and register it, consistent with the `ActionService.register(actionId, handler, options)` signature from [Services: ActionService](/concepts/services#actionservice):

```lua
return function(source, data)
    if not source or source == 0 then return end

    local townHall = TownHall:findSync(data.townHallId)
    if not townHall then
        NotificationService.error(source, 'AssignMayor', 'Town hall not found')
        return
    end

    townHall.mayor = data.mayorName
    townHall:saveSync()

    NotificationService.success(source, 'AssignMayor', data.mayorName .. ' is now mayor!')
end
```

```lua
ActionService.register('assign_mayor', require('server.actions.AssignMayor'))
```

## 5. Add a policy

```bash
obelisk make:policy IsMayorOrAdmin
```

```
Policy ID (camelCase): (isMayorOrAdmin)
Policy description: (Checks if ismayororadmin requirement is met)
Where should the policy be created?
❯ Core
  Module
  Plugin
```

Choose `Plugin` → `TownHall`. This writes `plugins/TownHall/server/policies/IsMayorOrAdminPolicy.lua`, which defines a validator and self-registers with `PolicyService`:

```lua
--- IsMayorOrAdmin Policy
--- Checks if ismayororadmin requirement is met
--- Policy ID: isMayorOrAdmin

--- Policy validator function
--- @param source number Player server ID
--- @param resource table Resource being accessed {type, id}
--- @param config table Configuration from pivot data
--- @return boolean allowed
--- @return string reason Optional denial reason
local function isMayorOrAdminValidator(source, resource, config)
    local playerPed = GetPlayerPed(source)

    if not DoesEntityExist(playerPed) then
        return false, 'Player not found'
    end

    -- Add your validation logic here

    return true
end

-- Register the policy
PolicyService.register('isMayorOrAdmin', isMayorOrAdminValidator, {
    description = 'Checks if ismayororadmin requirement is met'
})

print('[Policy] Registered isMayorOrAdmin policy')
```

Fill in a real check — a minimal authorization rule gating the `assign_mayor` action to admins only, using the `PolicyService.register(policyId, validator, options)` signature from [Services: PolicyService](/concepts/services#policyservice):

```lua
local function isMayorOrAdminValidator(source, resource, config)
    local playerPed = GetPlayerPed(source)
    if not DoesEntityExist(playerPed) then
        return false, 'Player not found'
    end

    if not IsPlayerAceAllowed(source, 'command.admin') then
        return false, 'Only admins can assign a mayor'
    end

    return true
end

PolicyService.register('isMayorOrAdmin', isMayorOrAdminValidator, {
    description = 'Restricts an action to admins only'
})
```

The CLI also prints a usage example after generating the file:

```
Usage example:
PolicyService.attach('interaction', interactionId, 'isMayorOrAdmin', {
    -- config options here
})
```

Since we're gating an action (not an interaction), attach it to the action instead:

```lua
PolicyService.attach('action', 'assign_mayor', 'isMayorOrAdmin', {})
```

Now `ActionService.execute` will call `PolicyService.check` before running `assign_mayor`'s handler, and deny (with an `error`-type notification) any player who isn't an admin — see [Services: ActionService](/concepts/services#actionservice) for exactly how that enforcement chain works.

## 6. Load it

Add the plugin to `server-data/server.cfg`, alongside the other `ensure` lines (see [Installation](/guide/installation) for the full server layout):

```
ensure oblsk_connector
ensure obelisk
ensure oblsk_character-selection
ensure TownHall
```

Restart the server:

```bash
docker compose restart fxserver
```

Watch the server console. You should see the same `Loading...` / `Loaded successfully!` print pattern that every CLI-generated `server/main.lua` produces — this is the same shape used by the real `oblsk_character-selection` plugin's `server/main.lua`:

```
[Oblsk_character-selection] Loading...
[Oblsk_character-selection] Loaded successfully!
```

For `TownHall`, that's:

```
[TownHall] Loading...
[TownHall] Loaded successfully!
```

If you see both lines with no errors in between, the plugin loaded successfully, its migration ran, and `assign_mayor` and `isMayorOrAdmin` are registered and ready.

## What's next

`TownHall` is intentionally minimal — enough to show the full scaffold-to-running-plugin loop, but not a realistic plugin on its own. For two real, more fully built-out examples that use interactions, keybinds, and a Vue UI page together, see [Existing Plugins](/reference/existing-plugins).
