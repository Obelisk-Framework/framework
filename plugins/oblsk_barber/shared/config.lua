-- Named BarberConfig (not the generic `Config`) because
-- core/fxmanifest.lua globs every plugin's shared/**/*.lua into one Lua
-- state; a bare `Config = {}` here would clobber
-- oblsk_character-selection's own `Config = {}` global -- the exact
-- collision oblsk_shellbuilder/shared/config.lua already documents hitting.
BarberConfig = {}

-- Non-hair sections: hair itself comes from Appearance.HAIR_STYLES[gender]
-- (oblsk_character-selection's shared/appearance.lua, a plain shared global
-- in the same Lua state -- see client/main.lua), real per-gender counts.
-- Everything below keeps the design prototype's original counts/prices --
-- no external data source was given for these catalogs.
BarberConfig.Sections = {
    { id = 'haircol',  label = 'Hair Color',        kind = 'colour', count = 24, price = 55 },
    { id = 'hl',       label = 'Hair Highlight',     kind = 'colour', count = 24, price = 40 },
    { id = 'beard',    label = 'Beard',              kind = 'style',  count = 28, price = 70 },
    { id = 'beardcol', label = 'Beard Color',        kind = 'colour', count = 24, price = 35 },
    { id = 'brows',    label = 'Eyebrows',           kind = 'style',  count = 34, price = 40 },
    { id = 'browcol',  label = 'Eyebrow Color',      kind = 'colour', count = 24, price = 30 },
    { id = 'chest',    label = 'Chest Hair',         kind = 'style',  count = 16, price = 50 },
    { id = 'chestcol', label = 'Chest Hair Color',   kind = 'colour', count = 24, price = 30 },
    { id = 'makeup',   label = 'Makeup',             kind = 'style',  count = 14, price = 65 },
    { id = 'blush',    label = 'Blusher',            kind = 'colour', count = 12, price = 30 },
    { id = 'lipstick', label = 'Lipstick',           kind = 'colour', count = 12, price = 30 },
}

-- Price for the hair (style) section, since it no longer carries its own
-- `count` here (real per-gender counts come from Appearance.HAIR_STYLES).
BarberConfig.HairPrice = 95

-- Item-binding keys this plugin needs bound to a real base item. Declaring
-- a key here only makes it *known* to ItemService.getRequiredBindingKeys()
-- / registerRequirements (see core/server/bootstrap.lua), which warns at
-- boot when it is unbound - a server operator still has to create matching
-- base_items/item_bindings rows before cash payment actually works.
BarberConfig.Requires = {
    bindings = {
        ['currency.cash'] = {
            live = true,
            description = 'Cash payments at the barber',
            hint = 'Cash — used for barber shop cash payments',
        },
    },
}

return BarberConfig
