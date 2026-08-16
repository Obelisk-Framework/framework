-- core/plugins/oblsk_reflexcheck/tests/reflex_check_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_reflexcheck/tests/reflex_check_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
-- NOTE: deviates from the brief's literal '../../..' — this plugin lives one
-- level deeper (core/plugins/<name>/tests/) than the sibling plugin the
-- brief's snippet was copied from (plugins/<name>/tests/), so an extra '..'
-- is required to actually reach the repository root where tests/support/
-- lives. Verified empirically: 3 levels left ROOT pointing at core/plugins/
-- oblsk_reflexcheck's parent 'core/' dir, and dofile could not find
-- tests/support/fivem_stubs.lua there.
local ROOT = scriptDir .. '../../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')

-- fivem_stubs.lua does not stub GetGameTimer; ReflexCheckService measures
-- elapsed time with it exclusively (never os.time), same convention as
-- FishingChallengeService.
local fakeNow = 1000
GetGameTimer = function() return fakeNow end

-- Deterministic RNG hook, same technique as FISHING_RANDOM_OVERRIDE /
-- VENDING_RANDOM_OVERRIDE: when set, every math.random call inside the
-- service returns this instead of a real draw. Tests that need a specific
-- integer draw (e.g. resolveCount's range pick) set this to that integer;
-- math.random(lo, hi) callers still receive the override verbatim, so pick
-- override values inside whatever range the test expects.
REFLEXCHECK_RANDOM_OVERRIDE = nil
local realRandom = math.random
math.random = function(...)
    if REFLEXCHECK_RANDOM_OVERRIDE ~= nil then return REFLEXCHECK_RANDOM_OVERRIDE end
    return realRandom(...)
end

dofile(scriptDir .. '../server/services/ReflexCheckService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

local function reset()
    fakeNow = 1000
    REFLEXCHECK_RANDOM_OVERRIDE = nil
    ReflexCheckService.resetForTests()
end

test('start: rejects a second call for a source that already has a session', function()
    reset()
    local ok1 = ReflexCheckService.start(1, { difficulty = 'medium', count = 1 }, function() end)
    truthy(ok1)

    local ok2, err2 = ReflexCheckService.start(1, { difficulty = 'medium', count = 1 }, function() end)

    eq(ok2, false)
    eq(err2, 'busy')
end)

test('start: returns session info with the resolved zone/speed/requiredHits', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40 -- both the zoneAngle draw and any count-range draw see this

    local ok, err, info = ReflexCheckService.start(2, { difficulty = 'medium', count = 1 }, function() end)

    truthy(ok)
    eq(err, nil)
    eq(info.zoneAngle, 40)
    eq(info.needleSpeed, 230)
    eq(info.zoneWidth, 34)
    eq(info.requiredHits, 1)
end)

test('attempt: a press inside the zone width counts as a hit', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    ReflexCheckService.start(1, { difficulty = 'medium', count = 2 }, function() end)
    -- medium: needleSpeed 230 deg/s, zoneWidth 34, zoneAngle 40.
    -- At 100ms elapsed the needle has traveled 23 degrees -> angle 23,
    -- distance from zoneAngle 40 is (23-40+360)%360 = 343, NOT a hit.
    -- Advance to 174ms: traveled 40.02 degrees -> angle ~40.02, distance
    -- ~0.02, inside zoneWidth 34 -> a hit.
    fakeNow = 1000 + 174

    local result = ReflexCheckService.attempt(1)

    eq(result, 'hit')
    eq(ReflexCheckService.getSession(1).hits, 1)
end)

test('attempt: a press outside the zone width counts as a miss', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    ReflexCheckService.start(1, { difficulty = 'medium', count = 2 }, function() end)
    -- At 100ms elapsed the needle is at 23 degrees, 343 degrees from the
    -- zone (going clockwise) - outside zoneWidth 34.
    fakeNow = 1000 + 100

    local result = ReflexCheckService.attempt(1)

    eq(result, 'miss')
    eq(ReflexCheckService.getSession(1).misses, 1)
end)

test('attempt: reaching requiredHits resolves passed and calls onDone(true)', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    local calledWith
    ReflexCheckService.start(1, { difficulty = 'medium', count = 1 }, function(passed) calledWith = passed end)
    fakeNow = 1000 + 174 -- lands the single required hit

    local result = ReflexCheckService.attempt(1)

    eq(result, 'passed')
    eq(calledWith, true)
    eq(ReflexCheckService.getSession(1), nil)
end)

test('attempt: reaching maxMisses resolves failed and calls onDone(false)', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    local calledWith
    ReflexCheckService.start(1, { difficulty = 'medium', count = 5, maxMisses = 1 }, function(passed) calledWith = passed end)
    fakeNow = 1000 + 100 -- a miss, per the miss test above

    local result = ReflexCheckService.attempt(1)

    eq(result, 'failed')
    eq(calledWith, false)
    eq(ReflexCheckService.getSession(1), nil)
end)

test('attempt: a miss that does not reach maxMisses picks a new zone and keeps the session open', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    ReflexCheckService.start(1, { difficulty = 'medium', count = 5, maxMisses = 3 }, function() end)
    fakeNow = 1000 + 100

    local result, nextZone = ReflexCheckService.attempt(1)

    eq(result, 'miss')
    truthy(nextZone)
    truthy(ReflexCheckService.getSession(1) ~= nil)
    truthy(ReflexCheckService.getSession(1).zoneAngle ~= 40, 'zone must move after a miss')
end)

test('attempt: no-session for a source with no active check', function()
    reset()
    local result = ReflexCheckService.attempt(99)
    eq(result, 'no-session')
end)

test('start: a {min,max} count range resolves to a random int in range', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 2
    local ok, err, info = ReflexCheckService.start(1, { difficulty = 'medium', count = { 2, 3 } }, function() end)
    truthy(ok)
    eq(info.requiredHits, 2)
end)

test('start: opts override the resolved preset field-by-field', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    local ok, err, info = ReflexCheckService.start(1, { difficulty = 'medium', count = 1, zoneWidth = 99, needleSpeed = 12 }, function() end)
    truthy(ok)
    eq(info.zoneWidth, 99)
    eq(info.needleSpeed, 12)
end)

test('cancel: force-fails an in-progress session and calls onDone(false)', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    local calledWith
    ReflexCheckService.start(1, { difficulty = 'medium', count = 1 }, function(passed) calledWith = passed end)

    ReflexCheckService.cancel(1)

    eq(calledWith, false)
    eq(ReflexCheckService.getSession(1), nil)
end)

test('cancel: is a no-op for a source with no session', function()
    reset()
    ReflexCheckService.cancel(42) -- must not error
    truthy(true)
end)

test('start: rejecting a busy source does not touch the existing session or call its onDone', function()
    reset()
    REFLEXCHECK_RANDOM_OVERRIDE = 40
    local calledWith
    ReflexCheckService.start(1, { difficulty = 'medium', count = 1 }, function(passed) calledWith = passed end)

    local ok2 = ReflexCheckService.start(1, { difficulty = 'medium', count = 1 }, function() end)

    eq(ok2, false)
    eq(calledWith, nil)
    truthy(ReflexCheckService.getSession(1) ~= nil)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = { name = t.name, err = err } end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print(string.format('FAIL: %s\n  %s', f.name, f.err)) end
os.exit(#failures == 0 and 0 or 1)
