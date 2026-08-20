-- plugins/oblsk_anticheat/tests/event_guard_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/plugins/oblsk_anticheat/shared/config.lua')
dofile(ROOT .. '/plugins/oblsk_anticheat/server/EventGuardService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

test('validate accepts args matching the schema', function()
    EventGuardService._rateState = {}
    local schema = {{type = 'number', min = 0, max = 100}, {type = 'string'}}
    local ok, reason = EventGuardService.validate(1, 'shop:server:buy', schema, {50, 'apple'})
    truthy(ok, reason)
end)

test('validate rejects wrong type', function()
    EventGuardService._rateState = {}
    local schema = {{type = 'number'}}
    local ok, reason = EventGuardService.validate(1, 'shop:server:buy', schema, {'not-a-number'})
    eq(ok, false)
    truthy(reason ~= nil)
end)

test('validate rejects a number out of range', function()
    EventGuardService._rateState = {}
    local schema = {{type = 'number', min = 0, max = 10}}
    local ok = EventGuardService.validate(1, 'shop:server:buy', schema, {9999})
    eq(ok, false)
end)

test('validate rejects missing required args', function()
    EventGuardService._rateState = {}
    local schema = {{type = 'number'}, {type = 'string'}}
    local ok = EventGuardService.validate(1, 'shop:server:buy', schema, {50})
    eq(ok, false)
end)

test('validate rate-limits: allows up to the configured burst, rejects beyond it in the same second', function()
    EventGuardService._rateState = {}
    Config.Anticheat.eventRateLimitPerSecond = 3
    local schema = {}
    local nowSeconds = 1000
    for i = 1, 3 do
        local ok = EventGuardService.validate(1, 'shop:server:buy', schema, {}, nowSeconds)
        truthy(ok, 'call ' .. i .. ' should be allowed')
    end
    local ok, reason = EventGuardService.validate(1, 'shop:server:buy', schema, {}, nowSeconds)
    eq(ok, false)
    truthy(reason:find('rate') ~= nil, 'expected a rate-limit reason, got: ' .. tostring(reason))
end)

test('validate accepts a table arg for type=table', function()
    EventGuardService._rateState = {}
    local schema = {{type = 'table'}}
    local ok, reason = EventGuardService.validate(1, 'anticheat:server:reportWeapons', schema, {{1, 2, 3}})
    truthy(ok, reason)
end)

test('validate rejects a non-table arg for type=table', function()
    EventGuardService._rateState = {}
    local schema = {{type = 'table'}}
    local ok, reason = EventGuardService.validate(1, 'anticheat:server:reportWeapons', schema, {'not-a-table'})
    eq(ok, false)
    truthy(reason ~= nil)
end)

test('validate rate-limit window resets on the next second', function()
    EventGuardService._rateState = {}
    Config.Anticheat.eventRateLimitPerSecond = 1
    local schema = {}
    truthy(EventGuardService.validate(1, 'shop:server:buy', schema, {}, 1000))
    local ok = EventGuardService.validate(1, 'shop:server:buy', schema, {}, 1001)
    truthy(ok, 'new second should reset the rate window')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
