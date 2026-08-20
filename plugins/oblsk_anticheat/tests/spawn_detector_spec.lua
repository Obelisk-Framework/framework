-- plugins/oblsk_anticheat/tests/spawn_detector_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/plugins/oblsk_anticheat/server/detectors/SpawnDetector.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('check returns nil when every client weapon is server-granted', function()
    local v = SpawnDetector.check({1, 2, 3}, {1, 2, 3, 4})
    eq(v, nil)
end)

test('check flags a client weapon with no matching server grant', function()
    local v = SpawnDetector.check({1, 2, 999}, {1, 2})
    eq(v.category, 'spawn')
    eq(v.severity, 'hard')
end)

test('check returns nil for empty client weapon list', function()
    local v = SpawnDetector.check({}, {1, 2})
    eq(v, nil)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
