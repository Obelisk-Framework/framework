-- tests/secure_event_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/sha256.lua')
dofile(ROOT .. '/core/shared/EventNaming.lua')

-- Fake PlayerService: SecureEventService resolves `source` -> Player via
-- PlayerService.get, same pattern Obelisk.onClient uses.
_G.PlayerService = {
    players = {},
    get = function(source) return _G.PlayerService.players[source] end,
}
local function fakePlayer(source)
    local p = { source = source }
    function p:getSource() return self.source end
    _G.PlayerService.players[source] = p
    return p
end

-- Spy registry standing in for the real RegisterNetEvent/AddEventHandler/
-- RemoveEventHandler natives, so the test can both drive "the client fired
-- event X" and assert exactly one handler is live per logical event.
local registered = {} -- [name] = handlerFn
local nextRef = 0
_G.RegisterNetEvent = function() end
_G.AddEventHandler = function(name, fn)
    nextRef = nextRef + 1
    registered[name] = fn
    return {name = name, ref = nextRef}
end
_G.RemoveEventHandler = function(handlerRef)
    registered[handlerRef.name] = nil
end
_G.TriggerClientEvent = function() end

dofile(ROOT .. '/core/server/Services/SecureEventService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

test('onClientSecure registers the counter-0 name for every active session', function()
    registered = {}
    SecureEventService._sessions = {}
    fakePlayer(1)
    SecureEventService.startSession(1, 'player-1-secret')

    SecureEventService.onClientSecure('garage:server:open', function() end)

    local expected = EventNaming.deriveName('player-1-secret', 'garage:server:open', 'client_to_server', 0)
    truthy(registered[expected] ~= nil, 'expected name not registered: ' .. expected)
end)

test('firing the current name advances to the next one-time name and removes the old one', function()
    registered = {}
    SecureEventService._sessions = {}
    fakePlayer(1)
    SecureEventService.startSession(1, 'player-1-secret')

    local received = {}
    SecureEventService.onClientSecure('garage:server:open', function(player, arg)
        received[#received + 1] = arg
    end)

    local name0 = EventNaming.deriveName('player-1-secret', 'garage:server:open', 'client_to_server', 0)
    -- Simulate the client triggering the current one-time name.
    registered[name0](1, 'payload-1')

    eq(#received, 1)
    eq(received[1], 'payload-1')

    local name1 = EventNaming.deriveName('player-1-secret', 'garage:server:open', 'client_to_server', 1)
    truthy(registered[name1] ~= nil, 'next one-time name was not registered')
    truthy(registered[name0] == nil, 'old one-time name was not removed')
end)

test('endSession removes the pending handler for that player', function()
    registered = {}
    SecureEventService._sessions = {}
    fakePlayer(1)
    SecureEventService.startSession(1, 'player-1-secret')
    SecureEventService.onClientSecure('garage:server:open', function() end)

    local name0 = EventNaming.deriveName('player-1-secret', 'garage:server:open', 'client_to_server', 0)
    truthy(registered[name0] ~= nil)

    SecureEventService.endSession(1)
    truthy(registered[name0] == nil, 'handler should be removed on disconnect')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
