-- plugins/oblsk_anticheat/tests/movement_detector_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/plugins/oblsk_anticheat/shared/config.lua')
dofile(ROOT .. '/plugins/oblsk_anticheat/server/detectors/MovementDetector.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('check returns nil for movement within the speed tolerance', function()
    local prev = {x = 0, y = 0, z = 0, timestamp = 1000.0}
    local cur = {x = 5, y = 0, z = 0, timestamp = 1001.0} -- 5 units/sec
    local v = MovementDetector.check(prev, cur, 10.0, false) -- max 10/sec, tolerance 1.25x -> 12.5 allowed
    eq(v, nil)
end)

test('check flags movement exceeding speed * tolerance', function()
    local prev = {x = 0, y = 0, z = 0, timestamp = 1000.0}
    local cur = {x = 100, y = 0, z = 0, timestamp = 1001.0} -- 100 units/sec
    local v = MovementDetector.check(prev, cur, 10.0, false) -- 12.5 allowed, 100 is way over
    eq(v.category, 'movement')
    eq(v.severity, 'hard')
end)

test('check flags a large jump with no loading screen as a teleport, ignoring speed', function()
    local prev = {x = 0, y = 0, z = 0, timestamp = 1000.0}
    local cur = {x = 500, y = 0, z = 0, timestamp = 1000.05} -- huge distance, tiny dt
    local v = MovementDetector.check(prev, cur, 10.0, false)
    eq(v.category, 'movement')
    eq(v.severity, 'hard')
end)

test('check does not flag a large jump when a loading screen happened', function()
    local prev = {x = 0, y = 0, z = 0, timestamp = 1000.0}
    local cur = {x = 5000, y = 0, z = 0, timestamp = 1002.0}
    local v = MovementDetector.check(prev, cur, 10.0, true)
    eq(v, nil)
end)

test('check ignores a zero or negative time delta (out-of-order update)', function()
    local prev = {x = 0, y = 0, z = 0, timestamp = 1000.0}
    local cur = {x = 500, y = 0, z = 0, timestamp = 999.0}
    local v = MovementDetector.check(prev, cur, 10.0, false)
    eq(v, nil)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
