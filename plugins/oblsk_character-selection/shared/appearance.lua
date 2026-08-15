-- shared/appearance.lua
--- Curated appearance/wardrobe config for the character creator. This is a
--- hand-picked STARTING catalog of GTA ped component/drawable/texture and
--- native color-table indices, not a researched, art-directed final
--- catalog -- expect some entries to look off in-game until play-tested
--- and tuned. See docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md,
--- "Known limitations".
---
--- GTA ped component IDs used below: 2=hair, 3=torso(top), 4=legs(pants),
--- 6=shoes, 7=accessory, 11=torso2(jacket/outerwear). Prop IDs: 0=hats.
Appearance = {}

--- All 20 SetPedFaceFeature indices (native range -1.0..1.0), matching the
--- reference dataset's full slider set 1:1 by position -- key order below
--- IS native index order, so this doubles as documentation of the mapping.
Appearance.FACE_FEATURE_INDEX = {
    noseWidth = 0, noseHeight = 1, noseLength = 2, noseBridge = 3, noseTip = 4, noseBridgeShift = 5,
    browHeight = 6, browWidth = 7,
    cheekboneHeight = 8, cheekboneWidth = 9, cheeksWidth = 10,
    eyesGap = 11, lipsThickness = 12,
    jawWidth = 13, jawHeight = 14,
    chinLength = 15, chinPosition = 16, chinWidth = 17, chinShape = 18,
    neckWidth = 19,
}

local function slot(label, component, drawable, texture)
    return { label = label, component = component, drawable = drawable, texture = texture or 0 }
end

--- Named MP freemode parent heads, in SetPedHeadBlendData shapeFirst/
--- shapeSecond ID order (index N below = native ID N). This is GTA Online's
--- own canonical character-creator parent roster, not an invented list --
--- portraits at gta.fandom.com/wiki/Dad and /wiki/Mom.
Appearance.PARENTS = {
    male = {
        'Benjamin', 'Daniel', 'Joshua', 'Noah', 'Andrew', 'Juan', 'Alex', 'Isaac',
        'Evan', 'Ethan', 'Vincent', 'Angel', 'Diego', 'Adrian', 'Gabriel', 'Michael',
        'Santiago', 'Kevin', 'Louis', 'Samuel', 'Anthony', 'Claude', 'Niko', 'John',
    },
    female = {
        'Hannah', 'Audrey', 'Jasmine', 'Giselle', 'Amelia', 'Isabella', 'Zoe', 'Ava',
        'Camila', 'Violet', 'Sophia', 'Evelyn', 'Nicole', 'Ashley', 'Grace', 'Brianna',
        'Natalie', 'Olivia', 'Elizabeth', 'Charlotte', 'Emma', 'Misty',
    },
}

Appearance.WARDROBE = {
    male = {
        top    = { slot('Tee · black', 3, 4, 0), slot('Henley', 3, 8, 0), slot('Polo', 3, 15, 0), slot('Tank', 3, 1, 0), slot('Flannel', 3, 20, 0), slot('Hoodie', 3, 34, 0) },
        jacket = { slot('None', 11, 0, 0), slot('Field jacket', 11, 6, 0), slot('Bomber', 11, 12, 0), slot('Leather', 11, 24, 0), slot('Denim', 11, 30, 0) },
        pants  = { slot('Jeans', 4, 4, 0), slot('Cargo · khaki', 4, 8, 1), slot('Chinos', 4, 15, 0), slot('Joggers', 4, 21, 0), slot('Tactical', 4, 26, 0) },
        shoes  = { slot('Sneakers', 6, 1, 0), slot('Combat boots', 6, 5, 0), slot('Runners', 6, 8, 0), slot('Dress shoes', 6, 11, 0) },
        hat    = { slot('None', 0, -1, 0), slot('Ball cap', 0, 4, 0), slot('Beanie', 0, 14, 0), slot('Bandana', 0, 19, 0) },
        acc    = { slot('None', 7, 0, 0), slot('Watch', 7, 2, 0), slot('Chain', 7, 5, 0), slot('Glasses', 7, 8, 0) },
    },
    female = {
        top    = { slot('Tee · black', 3, 6, 0), slot('Henley', 3, 11, 0), slot('Polo', 3, 18, 0), slot('Tank', 3, 2, 0), slot('Flannel', 3, 24, 0), slot('Hoodie', 3, 38, 0) },
        jacket = { slot('None', 11, 0, 0), slot('Field jacket', 11, 8, 0), slot('Bomber', 11, 14, 0), slot('Leather', 11, 26, 0), slot('Denim', 11, 32, 0) },
        pants  = { slot('Jeans', 4, 6, 0), slot('Cargo · khaki', 4, 10, 1), slot('Chinos', 4, 17, 0), slot('Joggers', 4, 23, 0), slot('Tactical', 4, 28, 0) },
        shoes  = { slot('Sneakers', 6, 3, 0), slot('Combat boots', 6, 7, 0), slot('Runners', 6, 10, 0), slot('Dress shoes', 6, 13, 0) },
        hat    = { slot('None', 0, -1, 0), slot('Ball cap', 0, 6, 0), slot('Beanie', 0, 16, 0), slot('Bandana', 0, 21, 0) },
        acc    = { slot('None', 7, 0, 0), slot('Watch', 7, 3, 0), slot('Chain', 7, 6, 0), slot('Glasses', 7, 9, 0) },
    },
}

--- Skin tone is NOT raw RGB in GTA -- it's controlled by SetPedHeadBlendData's
--- skin IDs + mix. Each swatch below is a curated {skinFirst, skinSecond,
--- skinMix} combo chosen to visually approximate the given color, ordered
--- lightest to darkest to match the design's 8-chip palette.
Appearance.SKIN_TONES = {
    { label = 'Tone 1', swatch = '#3a2418', skinFirst = 4, skinSecond = 4, skinMix = 0.9 },
    { label = 'Tone 2', swatch = '#4a2e1e', skinFirst = 4, skinSecond = 5, skinMix = 0.7 },
    { label = 'Tone 3', swatch = '#5e3b25', skinFirst = 5, skinSecond = 5, skinMix = 0.5 },
    { label = 'Tone 4', swatch = '#7a4f33', skinFirst = 5, skinSecond = 6, skinMix = 0.5 },
    { label = 'Tone 5', swatch = '#9a6a48', skinFirst = 6, skinSecond = 6, skinMix = 0.4 },
    { label = 'Tone 6', swatch = '#b88761', skinFirst = 6, skinSecond = 7, skinMix = 0.3 },
    { label = 'Tone 7', swatch = '#d2a47e', skinFirst = 7, skinSecond = 7, skinMix = 0.2 },
    { label = 'Tone 8', swatch = '#e8c39c', skinFirst = 8, skinSecond = 8, skinMix = 0.1 },
}

--- SetPedEyeColor native index (0-31); 8 representative picks.
Appearance.EYE_COLORS = {
    { label = 'Blue',    swatch = '#2a4a6e', index = 0 },
    { label = 'Sky',     swatch = '#3b6e8f', index = 1 },
    { label = 'Green',   swatch = '#4a8e4a', index = 5 },
    { label = 'Hazel',   swatch = '#6b5b3a', index = 9 },
    { label = 'Grey',    swatch = '#3a3a3a', index = 11 },
    { label = 'Amber',   swatch = '#7a4a2a', index = 13 },
    { label = 'Teal',    swatch = '#1a3a3a', index = 18 },
    { label = 'Violet',  swatch = '#5a2a4a', index = 22 },
}

--- SetPedHairColor(colorID, highlightID); 8 representative picks.
Appearance.HAIR_COLORS = {
    { label = 'Black',      swatch = '#0e0d0c', colorId = 0,  highlightId = 0 },
    { label = 'Dark brown', swatch = '#2b1d15', colorId = 1,  highlightId = 1 },
    { label = 'Brown',      swatch = '#4a2f1c', colorId = 3,  highlightId = 3 },
    { label = 'Auburn',     swatch = '#7a4a22', colorId = 5,  highlightId = 5 },
    { label = 'Blonde',     swatch = '#b07a34', colorId = 8,  highlightId = 8 },
    { label = 'Platinum',   swatch = '#d9b877', colorId = 10, highlightId = 10 },
    { label = 'Grey',       swatch = '#8a8a8a', colorId = 17, highlightId = 17 },
    { label = 'Red',        swatch = '#c94f2a', colorId = 28, highlightId = 28 },
}

--- SetPedHeadOverlayColor colorType=2 palette (blush/lipstick/makeup use a
--- separate ~64-entry native table from hair, not curated 1:1 -- 8
--- representative picks, same "curated starting catalog" approach as
--- SKIN_TONES/EYE_COLORS/HAIR_COLORS above.
Appearance.MAKEUP_COLORS = {
    { label = 'Nude',    swatch = '#c9967a', index = 0 },
    { label = 'Rose',    swatch = '#c96b7a', index = 4 },
    { label = 'Berry',   swatch = '#8a3a5a', index = 8 },
    { label = 'Coral',   swatch = '#e0725a', index = 12 },
    { label = 'Plum',    swatch = '#6a3a5a', index = 16 },
    { label = 'Crimson', swatch = '#a5223a', index = 20 },
    { label = 'Bronze',  swatch = '#a97a4a', index = 24 },
    { label = 'Violet',  swatch = '#7a4a9a', index = 28 },
}

local function makeupOptions()
    local named = {
        'None', 'Smokey Black', 'Bronze', 'Soft Grey', 'Retro Glam', 'Natural Look', 'Cat Eye', 'Chola',
        'Vamp', 'Vinewood Glamour', 'Bubblegum', 'Aqua Dream', 'Pin Up', 'Purple Passion',
        'Smoky Cat Eye', 'Smoldering Ruby', 'Pop Princess',
    }
    -- Native makeup range is -1..74 (76 total incl. 'None'); the reference
    -- dataset's own list only names the first 16 styles -- the rest are
    -- unnamed there too ("???"). Numbered here instead of inventing fake
    -- names, to preserve the real native range/count.
    for i = 1, 76 - #named do
        named[#named + 1] = 'Look ' .. (#named + 1)
    end
    return named
end

--- GTA's 11 SetPedHeadOverlay slots (0-10). `options[1]` is always 'None'
--- (UI index 0), resolved to native style -1 (clears the overlay); every
--- other UI index N resolves to native style N-1. `colorTable`, where
--- present, names which curated palette above (HAIR_COLORS or
--- MAKEUP_COLORS) the overlay's SetPedHeadOverlayColor color comes from, and
--- `colorType` is the native's own colorType argument (1 = hair-style
--- palette, 2 = makeup palette). English names below are translated 1:1 from
--- the reference dataset's German labels; counts match its min/max ranges.
Appearance.OVERLAYS = {
    blemishes = {
        overlayId = 0, hasColor = false,
        options = {
            'None', 'Measles', 'Pimples', 'Spots', 'Breakouts', 'Blackheads', 'Build Up', 'Pustules', 'Zits',
            'Acne (Full Face)', 'Acne', 'Rash (Cheek)', 'Rash (Face)', 'Picker', 'Puberty', 'Blemish',
            'Rash (Chin)', 'Two Face', 'T-Zone', 'Oily', 'Marked', 'Acne Scars', 'Acne Scars (Full Face)',
            'Cold Sores', 'Pus Spots',
        },
    },
    facial_hair = {
        overlayId = 1, hasColor = true, colorTable = 'HAIR_COLORS', colorType = 1,
        options = {
            'None', 'Light Stubble', 'Balbo', 'Circle Beard', 'Goatee', 'Chin Strap', 'Chin Fuzz',
            'Pencil Chin Strap', 'Scruffy', 'Musketeer', 'Mustache', 'Trimmed Beard', 'Stubble',
            'Thin Circle Beard', 'Horseshoe', "Pencil and 'Chops", 'Chin Curtain', 'Balbo and Sideburns',
            'Sideburns', 'Scruffy Beard', 'Curly', 'Curly & Deep Stranger', 'Handlebar', 'Faustic',
            'Otto & Patch', 'Otto & Full Stranger', 'Light Franz', 'The Hampstead', 'The Ambrose',
            'Lincoln Curtain',
        },
    },
    eyebrows = {
        overlayId = 2, hasColor = true, colorTable = 'HAIR_COLORS', colorType = 1,
        options = {
            'None', 'Balanced', 'Fashion', 'Cleopatra', 'Quizzical', 'Wife', 'Seductive', 'Pinched', 'Chola',
            'Triomphe', 'Carefree', 'Curvy', 'Rodent', 'Double Team', 'Thin', 'Pencil', 'Mother Plucker',
            'Straight and Narrow', 'Natural', 'Fuzzy', 'Unkempt', 'Caterpillar', 'Regular', 'Mediterranean',
            'Groomed', 'Bushels', 'Feathered', 'Spiky', 'Unibrow', 'Winged', 'Triple Tramline',
            'Arched Tramline', 'Cut-Outs', 'Fade', 'Solo Tramline',
        },
    },
    ageing = {
        overlayId = 3, hasColor = false,
        options = {
            'None', "Crow's Feet", 'First Signs', 'Middle Age', 'Worry Lines', 'Depression', 'Excellent',
            'Aged', 'Weathered', 'Wrinkled', 'Sagging', 'Hard Life', 'Vintage', 'Retirement', 'Junkie',
            'Geriatric',
        },
    },
    makeup = {
        overlayId = 4, hasColor = true, colorTable = 'MAKEUP_COLORS', colorType = 2,
        options = makeupOptions(),
    },
    blush = {
        overlayId = 5, hasColor = true, colorTable = 'MAKEUP_COLORS', colorType = 2,
        options = { 'None', 'Full', 'Angled', 'Round', 'Horizontal', 'High', 'Sweetheart', 'Eighties' },
    },
    complexion = {
        overlayId = 6, hasColor = false,
        options = {
            'None', 'Rosy Cheeks', 'Stubble Rash', 'Hot Flush', 'Sunburn', 'Bruised', 'Alcoholic', 'Patchy',
            'Totem', 'Blood Vessels', 'Damaged', 'Pale', 'Ghostly',
        },
    },
    sun_damage = {
        overlayId = 7, hasColor = false,
        options = {
            'None', 'Uneven', 'Sandpaper', 'Patchy', 'Rough', 'Leathery', 'Textured', 'Coarse', 'Rugged',
            'Creased', 'Cracked', 'Gritty',
        },
    },
    lipstick = {
        overlayId = 8, hasColor = true, colorTable = 'MAKEUP_COLORS', colorType = 2,
        options = {
            'None', 'Color Matte', 'Color Gloss', 'Lined Matte', 'Lined Gloss', 'Heavily Lined Matte',
            'Heavily Lined Gloss', 'Lined Nude Matte', 'Lined Nude Gloss', 'Smudged', 'Geisha',
        },
    },
    moles = {
        overlayId = 9, hasColor = false,
        options = {
            'None', 'Cherub', 'All Over', 'Irregular', 'Dot Dash', 'Over the Bridge', 'Baby Doll', 'Pixie',
            'Sun Kissed', 'Beauty Marks', 'Line Up', 'Modelesque', 'Occasional', 'Speckled', 'Rain Drops',
            'Double Dip', 'One Sided', 'Pairs', 'Growth',
        },
    },
    chest_hair = {
        overlayId = 10, hasColor = true, colorTable = 'HAIR_COLORS', colorType = 1,
        options = {
            'None', 'Natural', 'The Stripe', 'The Tree', 'Hairy', 'Grisly', 'Monkey', 'Groomed Monkey',
            'Bikini', 'Lightning', 'Reverse Lightning', 'Love Heart', 'Chest Pain', 'Happy Face', 'Skull',
            'Snail Trail', 'Slug and Nips', 'Hairy Arms',
        },
    },
}

--- Wardrobe slots whose `component` field is a PROP id (SetPedPropIndex),
--- not a ped component id (SetPedComponentVariation).
Appearance.PROP_SLOTS = { hat = true }

--- Component 2 (hair) drawable per style. Gender-split -- the male and
--- female freemode models don't share a drawable table (component 2's
--- meaning differs per model), same as WARDROBE above. Labels are
--- numbered (the wiki source doesn't name individual cuts), same
--- 'no fake names' convention as makeupOptions() below.
Appearance.HAIR_STYLES = {
    male = {
        { label = 'Style 1', drawable = 0, thumb = 'assets/hair/male/0.jpg' },
        { label = 'Style 2', drawable = 1, thumb = 'assets/hair/male/1.jpg' },
        { label = 'Style 3', drawable = 2, thumb = 'assets/hair/male/2.jpg' },
        { label = 'Style 4', drawable = 3, thumb = 'assets/hair/male/3.jpg' },
        { label = 'Style 5', drawable = 4, thumb = 'assets/hair/male/4.jpg' },
        { label = 'Style 6', drawable = 5, thumb = 'assets/hair/male/5.jpg' },
        { label = 'Style 7', drawable = 6, thumb = 'assets/hair/male/6.jpg' },
        { label = 'Style 8', drawable = 7, thumb = 'assets/hair/male/7.jpg' },
        { label = 'Style 9', drawable = 8, thumb = 'assets/hair/male/8.jpg' },
        { label = 'Style 10', drawable = 9, thumb = 'assets/hair/male/9.jpg' },
        { label = 'Style 11', drawable = 10, thumb = 'assets/hair/male/10.jpg' },
        { label = 'Style 12', drawable = 11, thumb = 'assets/hair/male/11.jpg' },
        { label = 'Style 13', drawable = 12, thumb = 'assets/hair/male/12.jpg' },
        { label = 'Style 14', drawable = 13, thumb = 'assets/hair/male/13.jpg' },
        { label = 'Style 15', drawable = 14, thumb = 'assets/hair/male/14.jpg' },
        { label = 'Style 16', drawable = 15, thumb = 'assets/hair/male/15.jpg' },
        { label = 'Style 17', drawable = 16, thumb = 'assets/hair/male/16.jpg' },
        { label = 'Style 18', drawable = 17, thumb = 'assets/hair/male/17.jpg' },
        { label = 'Style 19', drawable = 18, thumb = 'assets/hair/male/18.jpg' },
        { label = 'Style 20', drawable = 19, thumb = 'assets/hair/male/19.jpg' },
        { label = 'Style 21', drawable = 20, thumb = 'assets/hair/male/20.jpg' },
        { label = 'Style 22', drawable = 21, thumb = 'assets/hair/male/21.jpg' },
        { label = 'Style 23', drawable = 22, thumb = 'assets/hair/male/22.jpg' },
        { label = 'Style 24', drawable = 23, thumb = 'assets/hair/male/23.jpg' },
        { label = 'Style 25', drawable = 24, thumb = 'assets/hair/male/24.jpg' },
        { label = 'Style 26', drawable = 25, thumb = 'assets/hair/male/25.jpg' },
        { label = 'Style 27', drawable = 26, thumb = 'assets/hair/male/26.jpg' },
        { label = 'Style 28', drawable = 27, thumb = 'assets/hair/male/27.jpg' },
        { label = 'Style 29', drawable = 28, thumb = 'assets/hair/male/28.jpg' },
        { label = 'Style 30', drawable = 29, thumb = 'assets/hair/male/29.jpg' },
        { label = 'Style 31', drawable = 30, thumb = 'assets/hair/male/30.jpg' },
        { label = 'Style 32', drawable = 31, thumb = 'assets/hair/male/31.jpg' },
        { label = 'Style 33', drawable = 32, thumb = 'assets/hair/male/32.jpg' },
        { label = 'Style 34', drawable = 33, thumb = 'assets/hair/male/33.jpg' },
        { label = 'Style 35', drawable = 34, thumb = 'assets/hair/male/34.jpg' },
        { label = 'Style 36', drawable = 35, thumb = 'assets/hair/male/35.jpg' },
        { label = 'Style 37', drawable = 36, thumb = 'assets/hair/male/36.jpg' },
        { label = 'Style 38', drawable = 37, thumb = 'assets/hair/male/37.jpg' },
        { label = 'Style 39', drawable = 38, thumb = 'assets/hair/male/38.jpg' },
        { label = 'Style 40', drawable = 39, thumb = 'assets/hair/male/39.jpg' },
        { label = 'Style 41', drawable = 40, thumb = 'assets/hair/male/40.jpg' },
        { label = 'Style 42', drawable = 41, thumb = 'assets/hair/male/41.jpg' },
        { label = 'Style 43', drawable = 42, thumb = 'assets/hair/male/42.jpg' },
        { label = 'Style 44', drawable = 43, thumb = 'assets/hair/male/43.jpg' },
        { label = 'Style 45', drawable = 44, thumb = 'assets/hair/male/44.jpg' },
        { label = 'Style 46', drawable = 45, thumb = 'assets/hair/male/45.jpg' },
        { label = 'Style 47', drawable = 46, thumb = 'assets/hair/male/46.jpg' },
        { label = 'Style 48', drawable = 47, thumb = 'assets/hair/male/47.jpg' },
        { label = 'Style 49', drawable = 48, thumb = 'assets/hair/male/48.jpg' },
        { label = 'Style 50', drawable = 49, thumb = 'assets/hair/male/49.jpg' },
        { label = 'Style 51', drawable = 50, thumb = 'assets/hair/male/50.jpg' },
        { label = 'Style 52', drawable = 51, thumb = 'assets/hair/male/51.jpg' },
        { label = 'Style 53', drawable = 52, thumb = 'assets/hair/male/52.jpg' },
        { label = 'Style 54', drawable = 53, thumb = 'assets/hair/male/53.jpg' },
        { label = 'Style 55', drawable = 54, thumb = 'assets/hair/male/54.jpg' },
        { label = 'Style 56', drawable = 55, thumb = 'assets/hair/male/55.jpg' },
        { label = 'Style 57', drawable = 56, thumb = 'assets/hair/male/56.jpg' },
        { label = 'Style 58', drawable = 57, thumb = 'assets/hair/male/57.jpg' },
        { label = 'Style 59', drawable = 58, thumb = 'assets/hair/male/58.jpg' },
        { label = 'Style 60', drawable = 59, thumb = 'assets/hair/male/59.jpg' },
        { label = 'Style 61', drawable = 60, thumb = 'assets/hair/male/60.jpg' },
        { label = 'Style 62', drawable = 61, thumb = 'assets/hair/male/61.jpg' },
        { label = 'Style 63', drawable = 62, thumb = 'assets/hair/male/62.jpg' },
        { label = 'Style 64', drawable = 63, thumb = 'assets/hair/male/63.jpg' },
        { label = 'Style 65', drawable = 64, thumb = 'assets/hair/male/64.jpg' },
        { label = 'Style 66', drawable = 65, thumb = 'assets/hair/male/65.jpg' },
        { label = 'Style 67', drawable = 66, thumb = 'assets/hair/male/66.jpg' },
        { label = 'Style 68', drawable = 67, thumb = 'assets/hair/male/67.jpg' },
        { label = 'Style 69', drawable = 68, thumb = 'assets/hair/male/68.jpg' },
        { label = 'Style 70', drawable = 69, thumb = 'assets/hair/male/69.jpg' },
        { label = 'Style 71', drawable = 70, thumb = 'assets/hair/male/70.jpg' },
        { label = 'Style 72', drawable = 71, thumb = 'assets/hair/male/71.jpg' },
        { label = 'Style 73', drawable = 72, thumb = 'assets/hair/male/72.jpg' },
        { label = 'Style 74', drawable = 73, thumb = 'assets/hair/male/73.jpg' },
        { label = 'Style 75', drawable = 74, thumb = 'assets/hair/male/74.jpg' },
        { label = 'Style 76', drawable = 75, thumb = 'assets/hair/male/75.jpg' },
        { label = 'Style 77', drawable = 76, thumb = 'assets/hair/male/76.jpg' },
        { label = 'Style 78', drawable = 77, thumb = 'assets/hair/male/77.jpg' },
        { label = 'Style 79', drawable = 78, thumb = 'assets/hair/male/78.jpg' },
        { label = 'Style 80', drawable = 79, thumb = 'assets/hair/male/79.jpg' },
        { label = 'Style 81', drawable = 80, thumb = 'assets/hair/male/80.jpg' },
        { label = 'Style 82', drawable = 81, thumb = 'assets/hair/male/81.jpg' },
        { label = 'Style 83', drawable = 82, thumb = 'assets/hair/male/82.jpg' },
    },
    female = {
        { label = 'Style 1', drawable = 0, thumb = 'assets/hair/female/0.jpg' },
        { label = 'Style 2', drawable = 1, thumb = 'assets/hair/female/1.jpg' },
        { label = 'Style 3', drawable = 2, thumb = 'assets/hair/female/2.jpg' },
        { label = 'Style 4', drawable = 3, thumb = 'assets/hair/female/3.jpg' },
        { label = 'Style 5', drawable = 4, thumb = 'assets/hair/female/4.jpg' },
        { label = 'Style 6', drawable = 5, thumb = 'assets/hair/female/5.jpg' },
        { label = 'Style 7', drawable = 6, thumb = 'assets/hair/female/6.jpg' },
        { label = 'Style 8', drawable = 7, thumb = 'assets/hair/female/7.jpg' },
        { label = 'Style 9', drawable = 8, thumb = 'assets/hair/female/8.jpg' },
        { label = 'Style 10', drawable = 9, thumb = 'assets/hair/female/9.jpg' },
        { label = 'Style 11', drawable = 10, thumb = 'assets/hair/female/10.jpg' },
        { label = 'Style 12', drawable = 11, thumb = 'assets/hair/female/11.jpg' },
        { label = 'Style 13', drawable = 12, thumb = 'assets/hair/female/12.jpg' },
        { label = 'Style 14', drawable = 13, thumb = 'assets/hair/female/13.jpg' },
        { label = 'Style 15', drawable = 14, thumb = 'assets/hair/female/14.jpg' },
        { label = 'Style 16', drawable = 15, thumb = 'assets/hair/female/15.jpg' },
        { label = 'Style 17', drawable = 16, thumb = 'assets/hair/female/16.jpg' },
        { label = 'Style 18', drawable = 17, thumb = 'assets/hair/female/17.jpg' },
        { label = 'Style 19', drawable = 18, thumb = 'assets/hair/female/18.jpg' },
        { label = 'Style 20', drawable = 19, thumb = 'assets/hair/female/19.jpg' },
        { label = 'Style 21', drawable = 20, thumb = 'assets/hair/female/20.jpg' },
        { label = 'Style 22', drawable = 21, thumb = 'assets/hair/female/21.jpg' },
        { label = 'Style 23', drawable = 22, thumb = 'assets/hair/female/22.jpg' },
        { label = 'Style 24', drawable = 23, thumb = 'assets/hair/female/23.jpg' },
        { label = 'Style 25', drawable = 24, thumb = 'assets/hair/female/24.jpg' },
        { label = 'Style 26', drawable = 25, thumb = 'assets/hair/female/25.jpg' },
        { label = 'Style 27', drawable = 26, thumb = 'assets/hair/female/26.jpg' },
        { label = 'Style 28', drawable = 27, thumb = 'assets/hair/female/27.jpg' },
        { label = 'Style 29', drawable = 28, thumb = 'assets/hair/female/28.jpg' },
        { label = 'Style 30', drawable = 29, thumb = 'assets/hair/female/29.jpg' },
        { label = 'Style 31', drawable = 30, thumb = 'assets/hair/female/30.jpg' },
        { label = 'Style 32', drawable = 31, thumb = 'assets/hair/female/31.jpg' },
        { label = 'Style 33', drawable = 32, thumb = 'assets/hair/female/32.jpg' },
        { label = 'Style 34', drawable = 33, thumb = 'assets/hair/female/33.jpg' },
        { label = 'Style 35', drawable = 34, thumb = 'assets/hair/female/34.jpg' },
        { label = 'Style 36', drawable = 35, thumb = 'assets/hair/female/35.jpg' },
        { label = 'Style 37', drawable = 36, thumb = 'assets/hair/female/36.jpg' },
        { label = 'Style 38', drawable = 37, thumb = 'assets/hair/female/37.jpg' },
        { label = 'Style 39', drawable = 38, thumb = 'assets/hair/female/38.jpg' },
        { label = 'Style 40', drawable = 39, thumb = 'assets/hair/female/39.jpg' },
        { label = 'Style 41', drawable = 40, thumb = 'assets/hair/female/40.jpg' },
        { label = 'Style 42', drawable = 41, thumb = 'assets/hair/female/41.jpg' },
        { label = 'Style 43', drawable = 42, thumb = 'assets/hair/female/42.jpg' },
        { label = 'Style 44', drawable = 43, thumb = 'assets/hair/female/43.jpg' },
        { label = 'Style 45', drawable = 44, thumb = 'assets/hair/female/44.jpg' },
        { label = 'Style 46', drawable = 45, thumb = 'assets/hair/female/45.jpg' },
        { label = 'Style 47', drawable = 46, thumb = 'assets/hair/female/46.jpg' },
        { label = 'Style 48', drawable = 47, thumb = 'assets/hair/female/47.jpg' },
        { label = 'Style 49', drawable = 48, thumb = 'assets/hair/female/48.jpg' },
        { label = 'Style 50', drawable = 49, thumb = 'assets/hair/female/49.jpg' },
        { label = 'Style 51', drawable = 50, thumb = 'assets/hair/female/50.jpg' },
        { label = 'Style 52', drawable = 51, thumb = 'assets/hair/female/51.jpg' },
        { label = 'Style 53', drawable = 52, thumb = 'assets/hair/female/52.jpg' },
        { label = 'Style 54', drawable = 53, thumb = 'assets/hair/female/53.jpg' },
        { label = 'Style 55', drawable = 54, thumb = 'assets/hair/female/54.jpg' },
        { label = 'Style 56', drawable = 55, thumb = 'assets/hair/female/55.jpg' },
        { label = 'Style 57', drawable = 56, thumb = 'assets/hair/female/56.jpg' },
        { label = 'Style 58', drawable = 57, thumb = 'assets/hair/female/57.jpg' },
        { label = 'Style 59', drawable = 58, thumb = 'assets/hair/female/58.jpg' },
        { label = 'Style 60', drawable = 59, thumb = 'assets/hair/female/59.jpg' },
        { label = 'Style 61', drawable = 60, thumb = 'assets/hair/female/60.jpg' },
        { label = 'Style 62', drawable = 61, thumb = 'assets/hair/female/61.jpg' },
        { label = 'Style 63', drawable = 62, thumb = 'assets/hair/female/62.jpg' },
        { label = 'Style 64', drawable = 63, thumb = 'assets/hair/female/63.jpg' },
        { label = 'Style 65', drawable = 64, thumb = 'assets/hair/female/64.jpg' },
        { label = 'Style 66', drawable = 65, thumb = 'assets/hair/female/65.jpg' },
        { label = 'Style 67', drawable = 66, thumb = 'assets/hair/female/66.jpg' },
        { label = 'Style 68', drawable = 67, thumb = 'assets/hair/female/67.jpg' },
        { label = 'Style 69', drawable = 68, thumb = 'assets/hair/female/68.jpg' },
        { label = 'Style 70', drawable = 69, thumb = 'assets/hair/female/69.jpg' },
        { label = 'Style 71', drawable = 70, thumb = 'assets/hair/female/70.jpg' },
        { label = 'Style 72', drawable = 71, thumb = 'assets/hair/female/71.jpg' },
        { label = 'Style 73', drawable = 72, thumb = 'assets/hair/female/72.jpg' },
        { label = 'Style 74', drawable = 73, thumb = 'assets/hair/female/73.jpg' },
        { label = 'Style 75', drawable = 74, thumb = 'assets/hair/female/74.jpg' },
        { label = 'Style 76', drawable = 75, thumb = 'assets/hair/female/75.jpg' },
        { label = 'Style 77', drawable = 76, thumb = 'assets/hair/female/76.jpg' },
        { label = 'Style 78', drawable = 77, thumb = 'assets/hair/female/77.jpg' },
        { label = 'Style 79', drawable = 78, thumb = 'assets/hair/female/78.jpg' },
        { label = 'Style 80', drawable = 79, thumb = 'assets/hair/female/79.jpg' },
        { label = 'Style 81', drawable = 80, thumb = 'assets/hair/female/80.jpg' },
    },
}

--- @param gender string 'male' | 'female'
--- @return table full appearance shape (see design spec's "Appearance data shape")
---
--- NOTE: gender is accepted (not currently branched on) so every caller can pass
--- it uniformly without checking function signatures. Server character creation
--- and client preview fallback both pass gender for consistency; a future default
--- could vary by gender without changing this signature.
function Appearance.DEFAULT_APPEARANCE(gender)
    local faceFeatures = {}
    for _, idx in pairs(Appearance.FACE_FEATURE_INDEX) do
        faceFeatures[idx] = 0.0
    end

    return {
        headBlend = {
            shapeFirst = 0, shapeSecond = 0, shapeThird = 0,
            skinFirst = 0, skinSecond = 0, skinThird = 0,
            shapeMix = 0.5, skinMix = 0.5, thirdMix = 0.0,
        },
        faceFeatures = faceFeatures,
        hairStyle = Appearance.HAIR_STYLES[gender][1].drawable,
        hairColor = Appearance.HAIR_COLORS[1].colorId,
        hairHighlight = Appearance.HAIR_COLORS[1].highlightId,
        eyeColor = Appearance.EYE_COLORS[1].index,
        components = {},
        props = {},
        -- Keyed by OVERLAYS' keys; absent key = that overlay is left alone
        -- (a fresh ped already has none applied, so there's nothing to
        -- clear on first apply -- see resolvePresetAppearance below).
        overlays = {},
    }
end

--- Resolves the browser's PRESET-INDEX payload into a fully native-valued
--- appearance table (the shape DEFAULT_APPEARANCE returns and
--- CharacterAppearanceService.apply consumes).
---
--- The Vue layer deliberately only knows labels/swatches (see
--- web/appearancePresets.js) and therefore sends 0-BASED indices into the
--- preset tables below (`skinIndex`, `eyeColorIndex`, `hairColorIndex`,
--- `hairStyleIndex`, `wardrobe = { top = 0, ... }`), never native IDs. This
--- function is the single place those indices become native values, so the
--- create path (server) and the live preview path (client) agree.
---
--- Already-resolved appearances (e.g. a row read back out of the DB) pass
--- through unchanged: every index key is optional, and the corresponding
--- native-valued key (`hairColor`, `eyeColor`, `components`, ...) is used
--- when no index was supplied. That makes the function safe to call on any
--- appearance payload, whichever side of the bridge it came from.
---
--- @param gender string 'male' | 'female'
--- @param raw table|nil index-based (or already-resolved) appearance payload
--- @return table fully resolved appearance
function Appearance.resolvePresetAppearance(gender, raw)
    gender = gender == 'female' and 'female' or 'male'
    local resolved = Appearance.DEFAULT_APPEARANCE(gender)
    if type(raw) ~= 'table' then
        return resolved
    end

    if type(raw.headBlend) == 'table' then
        for key, value in pairs(raw.headBlend) do
            resolved.headBlend[key] = value
        end
    end

    if type(raw.faceFeatures) == 'table' then
        resolved.faceFeatures = raw.faceFeatures
    end

    -- Skin tone: a headBlend skin-ID/mix combo, not an RGB value.
    local skin = raw.skinIndex and Appearance.SKIN_TONES[raw.skinIndex + 1]
    if skin then
        resolved.headBlend.skinFirst = skin.skinFirst
        resolved.headBlend.skinSecond = skin.skinSecond
        resolved.headBlend.skinMix = skin.skinMix
    end

    local hairStyle = raw.hairStyleIndex and Appearance.HAIR_STYLES[gender][raw.hairStyleIndex + 1]
    if hairStyle then
        resolved.hairStyle = hairStyle.drawable
    elseif raw.hairStyle ~= nil then
        resolved.hairStyle = raw.hairStyle
    end

    local hairColor = raw.hairColorIndex and Appearance.HAIR_COLORS[raw.hairColorIndex + 1]
    if hairColor then
        resolved.hairColor = hairColor.colorId
        resolved.hairHighlight = hairColor.highlightId
    elseif raw.hairColor ~= nil then
        resolved.hairColor = raw.hairColor
        resolved.hairHighlight = raw.hairHighlight or raw.hairColor
    end

    local eyeColor = raw.eyeColorIndex and Appearance.EYE_COLORS[raw.eyeColorIndex + 1]
    if eyeColor then
        resolved.eyeColor = eyeColor.index
    elseif raw.eyeColor ~= nil then
        resolved.eyeColor = raw.eyeColor
    end

    if type(raw.wardrobe) == 'table' then
        for slotKey, optionIndex in pairs(raw.wardrobe) do
            local slots = Appearance.WARDROBE[gender][slotKey]
            local option = slots and type(optionIndex) == 'number' and slots[optionIndex + 1]
            if option then
                local target = Appearance.PROP_SLOTS[slotKey] and resolved.props or resolved.components
                target[option.component] = { drawable = option.drawable, texture = option.texture or 0 }
            end
        end
    else
        if type(raw.components) == 'table' then resolved.components = raw.components end
        if type(raw.props) == 'table' then resolved.props = raw.props end
    end

    -- Overlays (blemishes/facial_hair/eyebrows/ageing/makeup/blush/
    -- complexion/sun_damage/lipstick/moles/chest_hair): the browser sends
    -- UI shape ({style = 0-based option index, opacity, color = 0-based
    -- palette index}); an already-resolved DB row instead has `styleIndex`
    -- (the native SetPedHeadOverlay style, already -1..N-1) and passes
    -- through unchanged.
    if type(raw.overlays) == 'table' then
        for key, def in pairs(Appearance.OVERLAYS) do
            local sel = raw.overlays[key]
            if type(sel) == 'table' then
                if sel.style ~= nil then
                    local styleIndex = sel.style > 0 and (sel.style - 1) or -1
                    local entry = { overlayId = def.overlayId, styleIndex = styleIndex, opacity = sel.opacity ~= nil and sel.opacity or 1.0 }
                    if def.hasColor and sel.color ~= nil then
                        local palette = Appearance[def.colorTable]
                        local c = palette and palette[sel.color + 1]
                        if c then
                            entry.colorId = c.index or c.colorId
                            entry.colorType = def.colorType
                        end
                    end
                    resolved.overlays[key] = entry
                elseif sel.styleIndex ~= nil then
                    resolved.overlays[key] = sel
                end
            end
        end
    end

    return resolved
end

return Appearance
