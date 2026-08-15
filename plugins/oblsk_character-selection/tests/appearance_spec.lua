-- tests/appearance_spec.lua
--- Unit tests for the appearance/wardrobe config table: every slider key
--- the UI exposes must resolve to a face feature index, both genders must
--- define every wardrobe slot, and DEFAULT_APPEARANCE must produce a
--- complete, well-shaped table.
--- Run from the repository root:  lua5.4 plugins/oblsk_character-selection/tests/appearance_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. '../shared/appearance.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local SLIDER_KEYS = {
    'noseWidth', 'noseHeight', 'noseLength', 'noseBridge', 'noseTip', 'noseBridgeShift',
    'browHeight', 'browWidth', 'cheekboneHeight', 'cheekboneWidth', 'cheeksWidth',
    'eyesGap', 'lipsThickness', 'jawWidth', 'jawHeight',
    'chinLength', 'chinPosition', 'chinWidth', 'chinShape', 'neckWidth',
}
local OVERLAY_KEYS = {
    'blemishes', 'facial_hair', 'eyebrows', 'ageing', 'makeup', 'blush',
    'complexion', 'sun_damage', 'lipstick', 'moles', 'chest_hair',
}
local WARDROBE_SLOTS = { 'top', 'jacket', 'pants', 'shoes', 'hat', 'acc' }

test('every design slider key maps to a face feature index, all 20 natives covered exactly once', function()
    local seen = {}
    for _, key in ipairs(SLIDER_KEYS) do
        local idx = Appearance.FACE_FEATURE_INDEX[key]
        truthy(idx ~= nil, 'missing FACE_FEATURE_INDEX for ' .. key)
        truthy(not seen[idx], 'native index ' .. idx .. ' used by two slider keys')
        seen[idx] = true
    end
    eq(#SLIDER_KEYS, 20)
    for i = 0, 19 do
        truthy(seen[i], 'no slider key maps to native face feature index ' .. i)
    end
end)

test('both genders define every wardrobe slot with at least one option', function()
    for _, gender in ipairs({ 'male', 'female' }) do
        for _, slot in ipairs(WARDROBE_SLOTS) do
            local options = Appearance.WARDROBE[gender][slot]
            truthy(options ~= nil, gender .. '.' .. slot .. ' missing')
            truthy(#options >= 1, gender .. '.' .. slot .. ' has no options')
            for _, opt in ipairs(options) do
                truthy(opt.label ~= nil, slot .. ' option missing label')
                truthy(opt.component ~= nil, slot .. ' option missing component')
                truthy(opt.drawable ~= nil, slot .. ' option missing drawable')
            end
        end
    end
end)

test('HAIR_STYLES is gender-split with the real GTA V drawable ranges', function()
    truthy(type(Appearance.HAIR_STYLES.male) == 'table', 'HAIR_STYLES.male missing')
    truthy(type(Appearance.HAIR_STYLES.female) == 'table', 'HAIR_STYLES.female missing')
    eq(#Appearance.HAIR_STYLES.male, 83, 'male hair style count')
    eq(#Appearance.HAIR_STYLES.female, 81, 'female hair style count')

    for _, gender in ipairs({ 'male', 'female' }) do
        local list = Appearance.HAIR_STYLES[gender]
        for i, entry in ipairs(list) do
            eq(entry.drawable, i - 1, gender .. ' hair entry ' .. i .. ' drawable must equal its 0-based index')
            truthy(type(entry.label) == 'string' and #entry.label > 0, gender .. ' hair entry ' .. i .. ' missing label')
            truthy(type(entry.thumb) == 'string' and entry.thumb:find(gender .. '/' .. entry.drawable .. '.jpg', 1, true) ~= nil,
                gender .. ' hair entry ' .. i .. ' thumb path must reference its own drawable')
        end
    end
end)

test('DEFAULT_APPEARANCE picks the first hair style for the given gender', function()
    local maleDefault = Appearance.DEFAULT_APPEARANCE('male')
    local femaleDefault = Appearance.DEFAULT_APPEARANCE('female')
    eq(maleDefault.hairStyle, Appearance.HAIR_STYLES.male[1].drawable)
    eq(femaleDefault.hairStyle, Appearance.HAIR_STYLES.female[1].drawable)
end)

test('resolvePresetAppearance resolves hairStyleIndex against the right gender list', function()
    local resolved = Appearance.resolvePresetAppearance('female', { hairStyleIndex = 5 })
    eq(resolved.hairStyle, Appearance.HAIR_STYLES.female[6].drawable)

    local resolvedMale = Appearance.resolvePresetAppearance('male', { hairStyleIndex = 5 })
    eq(resolvedMale.hairStyle, Appearance.HAIR_STYLES.male[6].drawable)
end)

test('color/skin/hair-style tables each have exactly 8/8/8 presets', function()
    eq(#Appearance.SKIN_TONES, 8)
    eq(#Appearance.EYE_COLORS, 8)
    eq(#Appearance.HAIR_COLORS, 8)
    eq(#Appearance.HAIR_STYLES.male, 83)
    eq(#Appearance.HAIR_STYLES.female, 81)
end)

test('all 11 overlay categories exist, "None" is always option 1, hasColor implies a colorTable', function()
    for _, key in ipairs(OVERLAY_KEYS) do
        local def = Appearance.OVERLAYS[key]
        truthy(def ~= nil, 'missing OVERLAYS.' .. key)
        truthy(def.overlayId ~= nil and def.overlayId >= 0 and def.overlayId <= 10, key .. ' has an invalid overlayId')
        truthy(#def.options >= 1, key .. ' has no options')
        eq(def.options[1], 'None')
        if def.hasColor then
            truthy(Appearance[def.colorTable] ~= nil, key .. ' colorTable ' .. tostring(def.colorTable) .. ' does not exist')
            truthy(def.colorType == 1 or def.colorType == 2, key .. ' missing a valid colorType')
        end
    end
end)

test('makeup color palette has 8 curated presets', function()
    eq(#Appearance.MAKEUP_COLORS, 8)
end)

test('makeup overlay has the full native range: 76 options (None + 75 looks)', function()
    eq(#Appearance.OVERLAYS.makeup.options, 76)
end)

test('resolvePresetAppearance resolves overlay UI selections into native style/opacity/color', function()
    local resolved = Appearance.resolvePresetAppearance('male', {
        overlays = {
            facial_hair = { style = 3, opacity = 0.8, color = 2 },
            blemishes = { style = 0 }, -- 'None' -> native -1
        },
    })
    eq(resolved.overlays.facial_hair.overlayId, Appearance.OVERLAYS.facial_hair.overlayId)
    eq(resolved.overlays.facial_hair.styleIndex, 2) -- UI index 3 ('Circle Beard') -> native 2
    eq(resolved.overlays.facial_hair.opacity, 0.8)
    eq(resolved.overlays.facial_hair.colorId, Appearance.HAIR_COLORS[3].colorId)
    eq(resolved.overlays.facial_hair.colorType, 1)
    eq(resolved.overlays.blemishes.styleIndex, -1)
end)

test('parent rosters have 24 named fathers and 22 named mothers, index = native shapeId', function()
    eq(#Appearance.PARENTS.male, 24)
    eq(#Appearance.PARENTS.female, 22)
    eq(Appearance.PARENTS.male[1], 'Benjamin')
    eq(Appearance.PARENTS.male[24], 'John')
    eq(Appearance.PARENTS.female[1], 'Hannah')
    eq(Appearance.PARENTS.female[22], 'Misty')
end)

test('DEFAULT_APPEARANCE returns a complete, well-shaped table for both genders', function()
    for _, gender in ipairs({ 'male', 'female' }) do
        local a = Appearance.DEFAULT_APPEARANCE(gender)
        truthy(a.headBlend ~= nil, 'missing headBlend')
        for _, field in ipairs({ 'shapeFirst', 'shapeSecond', 'shapeThird', 'skinFirst', 'skinSecond', 'skinThird', 'shapeMix', 'skinMix', 'thirdMix' }) do
            truthy(a.headBlend[field] ~= nil, 'headBlend missing ' .. field)
        end
        truthy(a.faceFeatures ~= nil, 'missing faceFeatures')
        for _, key in ipairs(SLIDER_KEYS) do
            local idx = Appearance.FACE_FEATURE_INDEX[key]
            truthy(a.faceFeatures[idx] ~= nil, 'faceFeatures missing index ' .. idx)
        end
        truthy(a.hairStyle ~= nil, 'missing hairStyle')
        truthy(a.hairColor ~= nil, 'missing hairColor')
        truthy(a.hairHighlight ~= nil, 'missing hairHighlight')
        truthy(a.eyeColor ~= nil, 'missing eyeColor')
        truthy(a.components ~= nil, 'missing components')
        truthy(a.props ~= nil, 'missing props')
        truthy(a.overlays ~= nil, 'missing overlays')
    end
end)

test('resolvePresetAppearance turns 0-based UI indices into native ids', function()
    local resolved = Appearance.resolvePresetAppearance('female', {
        skinIndex = 0, eyeColorIndex = 2, hairColorIndex = 7, hairStyleIndex = 0,
        wardrobe = { top = 0, hat = 1, jacket = 4 },
        faceFeatures = { [0] = 0.5 },
        headBlend = { shapeFirst = 3, shapeSecond = 9 },
    })

    eq(resolved.headBlend.skinFirst, Appearance.SKIN_TONES[1].skinFirst)
    eq(resolved.headBlend.skinMix, Appearance.SKIN_TONES[1].skinMix)
    eq(resolved.headBlend.shapeFirst, 3)
    eq(resolved.headBlend.shapeSecond, 9)
    eq(resolved.eyeColor, Appearance.EYE_COLORS[3].index)
    eq(resolved.hairColor, Appearance.HAIR_COLORS[8].colorId)
    eq(resolved.hairHighlight, Appearance.HAIR_COLORS[8].highlightId)
    eq(resolved.hairStyle, Appearance.HAIR_STYLES.female[1].drawable)
    eq(resolved.faceFeatures[0], 0.5)

    -- index 0 from the browser must select the FIRST (1-based) Lua option
    local top = Appearance.WARDROBE.female.top[1]
    eq(resolved.components[top.component].drawable, top.drawable)
    local jacket = Appearance.WARDROBE.female.jacket[5]
    eq(resolved.components[jacket.component].drawable, jacket.drawable)
    -- headwear is a PROP slot, not a component slot
    local hat = Appearance.WARDROBE.female.hat[2]
    eq(resolved.props[hat.component].drawable, hat.drawable)
    eq(resolved.components[hat.component], nil)
end)

test('resolvePresetAppearance passes an already-resolved appearance through', function()
    local stored = Appearance.DEFAULT_APPEARANCE('male')
    stored.hairColor = 17
    stored.hairHighlight = 3
    stored.eyeColor = 22
    stored.hairStyle = 5
    stored.components = { [3] = { drawable = 12, texture = 1 } }
    stored.props = { [0] = { drawable = -1, texture = 0 } }

    local resolved = Appearance.resolvePresetAppearance('male', stored)
    eq(resolved.hairColor, 17)
    eq(resolved.hairHighlight, 3)
    eq(resolved.eyeColor, 22)
    eq(resolved.hairStyle, 5)
    eq(resolved.components[3].drawable, 12)
    eq(resolved.props[0].drawable, -1)
end)

test('resolvePresetAppearance falls back to defaults for a nil payload', function()
    local resolved = Appearance.resolvePresetAppearance('male', nil)
    eq(resolved.hairColor, Appearance.DEFAULT_APPEARANCE('male').hairColor)
    truthy(resolved.headBlend ~= nil, 'missing headBlend')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('FAIL: ' .. t.name .. '\n  ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
