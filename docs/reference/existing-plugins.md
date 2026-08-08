# Existing Plugins

The Obelisk organization ships a handful of example plugins and modules alongside core. Two of them have real, working implementations you can read end-to-end; the rest are reserved names for functionality that hasn't been built yet. This page is an honest inventory of both, don't expect the reserved ones to contain source you can copy.

Both real examples below, `oblsk_character-selection` and `oblsk_inventory`, predate the CLI-generated plugin convention and still carry their own `fxmanifest.lua` for that historical reason. Plugins generated today with `obelisk make:plugin` don't get one: they're registered by name in `plugins/registry.json` instead, and their scripts load as part of `core` itself through the globs in `core/fxmanifest.lua` (see [Modules & Plugins](/concepts/modules-and-plugins)).

## `oblsk_character-selection`

A real, pre-existing plugin that demonstrates the actions feature combined with a Vue UI page. It predates the CLI-generated convention this framework now uses: it was hand-authored (or scaffolded by an earlier version of the CLI) back when plugins still declared their own `fxmanifest.lua`, and it still has one on disk today, with a dependency on `obelisk`, glob'd `shared/client/server` scripts, and its own `ui_page`:

```lua
fx_version 'cerulean'
game 'gta5'

-- Plugin dependencies
dependencies {
    'obelisk'
}

-- Shared scripts
shared_scripts {
    'shared/**/*.lua'
}

-- Client scripts
client_scripts {
    'client/**/*.lua'
}

-- Server scripts
server_scripts {
    '@oxmysql/lib/MySQL.lua',  -- If using database
    'server/**/*.lua'
}

-- UI
ui_page 'web/dist/index.html'

files {
    'web/dist/**/*'
}
```

Its server entry point registers an example action with `ActionService`:

```lua
-- Register actions
ActionService.register('oblsk_character-selection_example', function(source, data)
    print('[Oblsk_character-selection] Action triggered')
end)
```

and the action handler itself (`server/actions/ExampleAction.lua`) shows the pattern for calling back into a service — here, sending a success toast via `NotificationService`:

```lua
-- Example action for Oblsk_character-selection
return function(source, data)
    print('[Oblsk_character-selection] Example action triggered by player ' .. source)

    -- Add your action logic here
    NotificationService.success(source, 'Oblsk_character-selection', 'Action executed successfully!')
end
```

The plugin also ships a `web/` directory with `CharacterSelector.vue`, `CharacterSelection.vue`, `CharacterCreationForm.vue`, and its own `routes.js` — a working example of the Vue-UI-page flavor of plugin, standalone with its own `web/dist` build rather than participating in core's combined router glob.

Source: `plugins/oblsk_character-selection/` in the main Obelisk Framework checkout.

## `oblsk_inventory`

A plugin with a real `BaseModel` in production use. Its `server/models/Inventory.lua` defines the `inventories` table model, including `fillable` mass-assignment fields, attribute casts, and commented-out examples of how relationships would be declared:

```lua
Inventory = BaseModel:extend('inventories')

Inventory.primaryKey = 'id'
Inventory.timestamps = true

--- Mass-assignable attributes
Inventory.fillable = {
    'owner',      -- identifier of the owning entity (player id, char id, stash name)
    'container',  -- which inventory this belongs to ('player', 'stash', ...)
    'slot',       -- zero-based slot index within the container
    'item',       -- item key, resolved against oblsk_items
    'count',      -- stack size
    'metadata',   -- JSON blob: quality, durability, ammo, etc.
}

Inventory.hidden = {}

--- Attribute casts
Inventory.casts = {
    metadata = 'json',
}

--- Example relationships (uncomment and point at the relevant models):
-- function Inventory:owner()
--     return self:belongsTo(Character, 'owner', 'id')
-- end
--
-- function Inventory:definition()
--     return self:belongsTo(Item, 'item', 'key')
-- end
```

It also defines a small instance method that's a good example of a model-level query helper:

```lua
--- Whether this slot currently holds nothing
--- @return boolean
function Inventory:isEmpty()
    return (self.attributes.count or 0) <= 0
end
```

Unlike `oblsk_character-selection`, `oblsk_inventory`'s Vue UI (`web/Inventory.vue`, `web/InventorySlot.vue`, `web/routes.js`) doesn't declare its own `ui_page` — it participates in core's combined build glob instead, as described in [Modules & Plugins](/concepts/modules-and-plugins).

Source: `plugins/oblsk_inventory/` in the main Obelisk Framework checkout.

## Reserved (not yet implemented)

The following names exist as empty repositories reserved for future work. They contain no `fxmanifest.lua` and no source yet — do not treat them as usable examples:

- **`oblsk_banking`** — reserved plugin name, no implementation yet.
- **`oblsk_garage`** — reserved plugin name, no implementation yet.
- **`modules/oblsk_items`** — reserved module name, no implementation yet.
- **`modules/oblsk_vehicles`** — reserved module name, no implementation yet.
