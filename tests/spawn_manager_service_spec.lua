--- Unit tests for SpawnManagerService's stage tracking and client relay.
--- Run from the repository root:  lua5.4 tests/spawn_manager_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

local emitted = {}
_G.Obelisk = _G.Obelisk or {}
Obelisk.emitClient = function(eventName, target, ...)
    emitted[#emitted + 1] = { eventName = eventName, target = target, args = { ... } }
end

dofile(ROOT .. '/core/server/Services/SpawnManagerService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('markConnecting sets stage to connecting and emits spawn-begin', function()
    emitted = {}
    SpawnManagerService.markConnecting(7)
    eq(SpawnManagerService.getStage(7), 'connecting')
    eq(#emitted, 1)
    eq(emitted[1].eventName, 'core:server:spawn-begin')
    eq(emitted[1].target, 7)
end)

test('readyToSpawn sets stage to spawned and emits spawn-complete', function()
    SpawnManagerService.markConnecting(9)
    emitted = {}
    SpawnManagerService.readyToSpawn(9, 42)
    eq(SpawnManagerService.getStage(9), 'spawned')
    eq(#emitted, 1)
    eq(emitted[1].eventName, 'core:server:spawn-complete')
    eq(emitted[1].target, 9)
    eq(emitted[1].args[1], 42)
end)

test('getStage returns nil for an unknown source', function()
    eq(SpawnManagerService.getStage(999), nil)
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
