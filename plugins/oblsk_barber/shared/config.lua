Config = {}

-- Non-hair sections: hair itself comes from
-- exports['oblsk_character-selection']:getHairStyles(gender) (see
-- client/main.lua), real per-gender counts. Everything below keeps the
-- design prototype's original counts/prices -- no external data source was
-- given for these catalogs.
Config.Sections = {
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
-- `count` here (real per-gender counts come from getHairStyles).
Config.HairPrice = 95

return Config
