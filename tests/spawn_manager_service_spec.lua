--- Unit tests for SpawnManagerService's stage tracking and client relay.
--- Run from the repository root:  lua5.4 tests/spawn_manager_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

local emitted = {}
_G.Obelisk = nil
dofile(ROOT .. '/core/shared/Obelisk.lua')
Obelisk.emitClient = function(eventName, target, ...)
    emitted[#emitted + 1] = { eventName = eventName, target = target, args = { ... } }
end

-- A minimal fake Player: source/getSource/emit match PlayerService's real
-- Player, so SpawnManagerService's player:getSource()/player:emit() calls
-- resolve correctly.
local function fakePlayer(source)
    return {
        source = source,
        getSource = function(self) return self.source end,
        emit = function(self, event, ...) Obelisk.emitClient(event, self, ...) end,
    }
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

test('markConnecting sets stage to connecting (keyed by numeric source) and emits spawn-begin', function()
    emitted = {}
    local player = fakePlayer(7)
    SpawnManagerService.markConnecting(player)
    eq(SpawnManagerService.getStage(player), 'connecting')
    eq(SpawnManagerService.stages[7], 'connecting', 'stages table must be keyed by numeric source, not the Player object')
    eq(#emitted, 1)
    eq(emitted[1].eventName, 'core:server:spawn-begin')
    eq(emitted[1].target, player)
end)

test('readyToSpawn sets stage to spawned (keyed by numeric source) and emits spawn-complete', function()
    local player = fakePlayer(9)
    SpawnManagerService.markConnecting(player)
    emitted = {}
    SpawnManagerService.readyToSpawn(player, 42)
    eq(SpawnManagerService.getStage(player), 'spawned')
    eq(SpawnManagerService.stages[9], 'spawned', 'stages table must be keyed by numeric source, not the Player object')
    eq(#emitted, 1)
    eq(emitted[1].eventName, 'core:server:spawn-complete')
    eq(emitted[1].target, player)
    eq(emitted[1].args[1], 42)
end)

test('getStage returns nil for an unknown source', function()
    eq(SpawnManagerService.getStage(fakePlayer(999)), nil)
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
