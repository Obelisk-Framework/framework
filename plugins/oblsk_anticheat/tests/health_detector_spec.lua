-- plugins/oblsk_anticheat/tests/health_detector_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/plugins/oblsk_anticheat/server/detectors/HealthDetector.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('check allows a full heal when it was a known heal action', function()
    local v = HealthDetector.check(20, 200, nil, true)
    eq(v, nil)
end)

test('check flags an instant full heal with no known heal action', function()
    local v = HealthDetector.check(20, 200, nil, false)
    eq(v.category, 'health')
    eq(v.severity, 'hard')
end)

test('check allows damage within the weapon expected range', function()
    local v = HealthDetector.check(200, 175, {min = 15, max = 30}, false)
    eq(v, nil)
end)

test('check flags damage far below the weapon expected range (damage-mod/godmode)', function()
    local v = HealthDetector.check(200, 199, {min = 15, max = 30}, false)
    eq(v.category, 'health')
    eq(v.severity, 'hard')
end)

test('check allows an increase in health when it is not a suspicious full heal', function()
    -- small regen tick, e.g. natural passive regen — not treated as suspicious
    local v = HealthDetector.check(190, 195, nil, false)
    eq(v, nil)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
