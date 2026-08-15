--- Unit tests for core/server/Services/PlayerService.lua.
--- Run from the repository root:  lua5.4 tests/player_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local function freshPlayerService()
    _G.IsDuplicityVersion = function() return true end
    _G.Obelisk = nil
    _G.PlayerService = nil
    dofile(ROOT .. '/core/shared/Obelisk.lua')
    -- capture the two Obelisk.on registrations PlayerService installs
    local handlers = {}
    local realOn = Obelisk.on
    Obelisk.on = function(name, fn) handlers[name] = fn; realOn(name, fn) end
    dofile(ROOT .. '/core/server/Services/PlayerService.lua')
    return PlayerService, handlers
end

test('get: returns nil before playerJoining fires', function()
    local PlayerService = freshPlayerService()
    eq(PlayerService.get(7), nil)
end)

test('playerJoining: creates a Player with source, name, identifiers', function()
    local PlayerService, handlers = freshPlayerService()
    _G.source = 7
    handlers['playerJoining']()
    _G.source = nil

    local player = PlayerService.get(7)
    truthy(player ~= nil, 'expected a Player to exist after playerJoining')
    eq(player:getSource(), 7)
    eq(player:getName(), 'Player7')
    eq(player:getIdentifier('license'), 'license:fake-7')
end)

test('playerDropped: removes the Player', function()
    local PlayerService, handlers = freshPlayerService()
    _G.source = 7
    handlers['playerJoining']()
    handlers['playerDropped']()
    _G.source = nil

    eq(PlayerService.get(7), nil)
end)

test('Player:emit forwards to Obelisk.emitClient with self as the player', function()
    local PlayerService, handlers = freshPlayerService()
    _G.source = 3
    handlers['playerJoining']()
    _G.source = nil

    local captured
    _G.TriggerClientEvent = function(name, target, ...) captured = {name, target, ...} end
    local player = PlayerService.get(3)
    player:emit('foo:bar', 'x')
    eq(captured[1], 'foo:bar')
    eq(captured[2], 3)
    eq(captured[3], 'x')
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running PlayerService unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = t.name
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err):gsub('\n', '\n         '))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
