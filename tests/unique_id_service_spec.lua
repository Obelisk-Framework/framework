--- Unit tests for UniqueIdService.
--- Run from core/: lua5.4 tests/unique_id_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/UniqueIdService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') ..
              '\n  expected: ' .. tostring(expected) ..
              '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function assert_(cond, msg)
    if not cond then error(msg or 'assertion failed', 2) end
end

-- helpers
local function matchesCharSet(s, allowed)
    for i = 1, #s do
        if not allowed:find(s:sub(i,i), 1, true) then return false end
    end
    return true
end

-- ── pattern expansion ────────────────────────────────────────────────────────

test('X positions produce uppercase alphanumeric characters', function()
    local result = UniqueIdService.generate('XXXXXXXX')
    eq(#result, 8, 'length')
    assert_(matchesCharSet(result, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'),
        'non-alphanum char in: ' .. result)
end)

test('N positions produce digit characters', function()
    local result = UniqueIdService.generate('NNNNNN')
    eq(#result, 6, 'length')
    assert_(matchesCharSet(result, '0123456789'),
        'non-digit char in: ' .. result)
end)

test('A positions produce uppercase letter characters', function()
    local result = UniqueIdService.generate('AAAA')
    eq(#result, 4, 'length')
    assert_(matchesCharSet(result, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'),
        'non-letter char in: ' .. result)
end)

test('literal characters pass through unchanged', function()
    local result = UniqueIdService.generate('WPN-XXXXXXXX')
    eq(#result, 12, 'length')
    eq(result:sub(1, 2), 'WP', 'prefix literal')
    -- Pattern: W(lit) P(lit) N(digit) -(lit) XXXXXXXX(8 alphanum)
    -- Result should have W, P, digit, -, then 8 alphanum
    local digit = result:sub(3, 3)
    local dash = result:sub(4, 4)
    local suffix = result:sub(5)
    assert_(matchesCharSet(digit, '0123456789'),
        'N should produce digit, got: ' .. digit)
    eq(dash, '-', 'dash literal')
    assert_(matchesCharSet(suffix, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'),
        'non-alphanum in suffix: ' .. suffix)
end)

test('mixed pattern produces correct total length and char sets', function()
    -- TIRE-XXXX-XXXX: 4 literals + 4 X + 1 literal + 4 X = 13 chars
    local result = UniqueIdService.generate('TIRE-XXXX-XXXX')
    eq(#result, 14, 'length')
    eq(result:sub(1, 5), 'TIRE-', 'prefix')
    eq(result:sub(10, 10), '-', 'mid dash')
end)

-- ── clock sequence ───────────────────────────────────────────────────────────

test('clock sequence increments when two calls land in the same second', function()
    -- Pin os.time to a fixed value so both calls appear to be in the same second.
    UniqueIdService._getTime = function() return 1000000 end

    local id1 = UniqueIdService.generate('XXXXXXXXAA')
    local id2 = UniqueIdService.generate('XXXXXXXXAA')

    -- Restore real clock
    UniqueIdService._getTime = os.time

    -- Both IDs are valid alphanum/letter strings of the right length
    eq(#id1, 10)
    eq(#id2, 10)
    -- They differ — clock sequence bumped the UUID between calls
    assert_(id1 ~= id2, 'same-second calls produced identical IDs: ' .. id1)
end)

-- ── uniqueness smoke test ────────────────────────────────────────────────────

test('sequential generates within a second are distinct', function()
    local seen = {}
    -- Test that multiple rapid calls within the same second produce distinct IDs
    -- by leveraging clock sequence increment mechanism. Mixed-radix decomposition
    -- ensures consecutive counter values produce distinct outputs.
    local pattern = 'WPN-XXXXXXXX'
    for i = 1, 1000 do
        local v = UniqueIdService.generate(pattern)
        assert_(not seen[v], 'collision at iteration ' .. i .. ': ' .. v)
        seen[v] = true
    end
end)

-- ── runner ───────────────────────────────────────────────────────────────────

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
