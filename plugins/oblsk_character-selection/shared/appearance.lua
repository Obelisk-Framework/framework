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

--- The 8 face sliders in the design map to SetPedFaceFeature indices
--- (0-19, native range -1.0..1.0). Values below are well-known, stable
--- native indices, not something invented for this plugin.
Appearance.FACE_FEATURE_INDEX = {
    nose = 0,       -- FACE_FEATURE_NOSE_WIDTH
    noseH = 2,      -- FACE_FEATURE_NOSE_HEIGHT (peak height)
    cheek = 6,      -- FACE_FEATURE_CHEEKBONES_HEIGHT
    jaw = 15,       -- FACE_FEATURE_JAW_WIDTH
    chin = 10,      -- FACE_FEATURE_CHIN_LENGTH
    brow = 8,       -- FACE_FEATURE_EYEBROW_HEIGHT
    eyeSize = 13,   -- FACE_FEATURE_EYES_OPENING
    lips = 17,      -- FACE_FEATURE_LIPS_THICKNESS
}

local function slot(label, component, drawable, texture)
    return { label = label, component = component, drawable = drawable, texture = texture or 0 }
end

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

--- Component 2 (hair) drawable per style.
Appearance.HAIR_STYLES = {
    { drawable = 0 }, { drawable = 1 }, { drawable = 2 },
    { drawable = 3 }, { drawable = 4 }, { drawable = 5 },
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
        hairStyle = Appearance.HAIR_STYLES[1].drawable,
        hairColor = Appearance.HAIR_COLORS[1].colorId,
        hairHighlight = Appearance.HAIR_COLORS[1].highlightId,
        eyeColor = Appearance.EYE_COLORS[1].index,
        components = {},
        props = {},
    }
end

return Appearance
