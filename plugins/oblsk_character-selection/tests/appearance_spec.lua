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
    'nose', 'noseH', 'cheek', 'jaw', 'chin', 'brow', 'eyeSize', 'lips',
}
local WARDROBE_SLOTS = { 'top', 'jacket', 'pants', 'shoes', 'hat', 'acc' }

test('every design slider key maps to a face feature index', function()
    for _, key in ipairs(SLIDER_KEYS) do
        truthy(Appearance.FACE_FEATURE_INDEX[key] ~= nil, 'missing FACE_FEATURE_INDEX for ' .. key)
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

test('color/skin/hair-style tables each have exactly 8/8/8/6 presets', function()
    eq(#Appearance.SKIN_TONES, 8)
    eq(#Appearance.EYE_COLORS, 8)
    eq(#Appearance.HAIR_COLORS, 8)
    eq(#Appearance.HAIR_STYLES, 6)
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
    eq(resolved.hairStyle, Appearance.HAIR_STYLES[1].drawable)
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
