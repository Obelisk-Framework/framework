-- Named ShellBuilderConfig (not the generic `Config`) because
-- core/fxmanifest.lua globs every plugin's shared/**/*.lua into one Lua
-- state; a bare `Config = {}` here previously clobbered
-- oblsk_character-selection's own `Config = {}` global (loaded earlier,
-- alphabetically) since both plugins shipped a shared/config.lua.
ShellBuilderConfig = {}

-- Every shell's interior geometry is placed at this one shared, fixed
-- coordinate far below the map. FiveM routing buckets already make two
-- different shells' occupants invisible and non-colliding to each other at
-- identical coordinates, so no per-shell coordinate allocation is needed.
ShellBuilderConfig.Anchor = { x = -3000.0, y = -3000.0, z = -500.0, heading = 0.0 }

-- The single world interaction that opens the shell browser. Staff can
-- relocate this by editing the coordinates below (e.g. to a "shell
-- builder's office" prop) - no code change needed.
ShellBuilderConfig.EntryPoint = { x = 215.0, y = -810.0, z = 30.7, range = 2.5, label = 'Shell Access Point' }

-- Default shell_objects budget for a newly-created shell (design's own cap).
ShellBuilderConfig.DefaultObjectBudget = 900

-- Item-binding keys this plugin needs bound to a real base item before its
-- catalog (ShellObjectService.catalog) can return anything. Declaring a key
-- here only makes it *known* to ItemService.getRequiredBindingKeys() /
-- registerRequirements (see core/server/bootstrap.lua) - a server operator
-- still has to create matching base_items/item_bindings rows for these keys
-- before the catalog is actually populated. Field shape matches the
-- item-binding convention documented in
-- docs/superpowers/specs/2026-08-12-banking-plugin-design.md §3.
ShellBuilderConfig.Requires = {
    bindings = {
        ['shellbuilder.floor_wood'] = {
            live = true,
            description = 'Construction tool: wooden floor tile',
            hint = 'Wooden floor tile — Construction tool',
        },
        ['shellbuilder.wall_plain'] = {
            live = true,
            description = 'Construction tool: plain wall panel',
            hint = 'Plain wall panel — Construction tool',
        },
        ['shellbuilder.wall_paint'] = {
            live = true,
            description = 'Style tool: wall paint/style swatch',
            hint = 'Wall paint/style swatch — Style tool',
        },
        ['shellbuilder.sofa_basic'] = {
            live = true,
            description = 'Decorate tool: basic sofa',
            hint = 'Basic sofa — Decorate tool',
        },
        ['shellbuilder.lamp_basic'] = {
            live = true,
            description = 'Decorate tool: basic lamp',
            hint = 'Basic lamp — Decorate tool',
        },
    },
}

return ShellBuilderConfig
