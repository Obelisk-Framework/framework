--- Unit tests for core/shared/Obelisk.lua's routing/error logic.
--- Run from the repository root:  lua5.4 tests/obelisk_spec.lua

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

local function fakePlayer(source)
    return {
        source = source,
        getSource = function(self) return self.source end,
    }
end

--- Loads a fresh Obelisk global under the given server/client mode. Each call
--- re-executes the file, so tests don't leak state into one another.
local function loadObeliskAs(isServer)
    _G.IsDuplicityVersion = function() return isServer end
    _G.Obelisk = nil
    dofile(ROOT .. '/core/shared/Obelisk.lua')
    return _G.Obelisk
end

test('emit: TriggerEvent locally, works on either side', function()
    local captured
    _G.TriggerEvent = function(name, ...) captured = {name, ...} end
    local Obelisk = loadObeliskAs(true)
    Obelisk.emit('foo:bar', 1, 2)
    eq(captured[1], 'foo:bar')
    eq(captured[2], 1)
    eq(captured[3], 2)
end)

test('on: AddEventHandler locally, works on either side', function()
    local handlerName
    _G.AddEventHandler = function(name, _) handlerName = name end
    local Obelisk = loadObeliskAs(false)
    Obelisk.on('foo:bar', function() end)
    eq(handlerName, 'foo:bar')
end)

test('server: emitClient calls TriggerClientEvent with player:getSource()', function()
    local captured
    _G.TriggerClientEvent = function(name, target, ...) captured = {name, target, ...} end
    local Obelisk = loadObeliskAs(true)
    Obelisk.emitClient('foo:bar', fakePlayer(5), 'x')
    eq(captured[1], 'foo:bar')
    eq(captured[2], 5)
    eq(captured[3], 'x')
end)

test('server: onClient registers via RegisterNetEvent AND AddEventHandler separately', function()
    local registered, handlerName, handlerFn
    _G.RegisterNetEvent = function(name) registered = name end
    _G.AddEventHandler = function(name, fn) handlerName = name; handlerFn = fn end
    local Obelisk = loadObeliskAs(true)
    Obelisk.onClient('foo:bar', function() end)
    eq(registered, 'foo:bar')
    eq(handlerName, 'foo:bar')
    truthy(type(handlerFn) == 'function', 'AddEventHandler must receive a function, not be passed to RegisterNetEvent')
end)

test('server: onClient resolves source to a Player and passes it as the first callback arg', function()
    local capturedHandler
    _G.RegisterNetEvent = function() end
    _G.AddEventHandler = function(_, fn) capturedHandler = fn end
    _G.source = 42
    _G.PlayerService = { get = function(src) eq(src, 42); return fakePlayer(src) end }
    local Obelisk = loadObeliskAs(true)
    local receivedPlayer, receivedArg
    Obelisk.onClient('foo:bar', function(player, arg) receivedPlayer = player; receivedArg = arg end)
    capturedHandler('hello')
    eq(receivedPlayer:getSource(), 42)
    eq(receivedArg, 'hello')
    _G.source = nil
end)

test('server: onClient drops the event (does not call the handler) when PlayerService has no Player yet', function()
    local capturedHandler
    _G.RegisterNetEvent = function() end
    _G.AddEventHandler = function(_, fn) capturedHandler = fn end
    _G.source = 99
    _G.PlayerService = { get = function() return nil end }
    local Obelisk = loadObeliskAs(true)
    local called = false
    Obelisk.onClient('foo:bar', function() called = true end)
    capturedHandler()
    truthy(not called, 'handler must not run when PlayerService.get returns nil')
    _G.source = nil
end)

test('server: emitServer throws', function()
    local Obelisk = loadObeliskAs(true)
    local ok, err = pcall(Obelisk.emitServer, 'foo:bar')
    truthy(not ok, 'expected an error')
    truthy(tostring(err):find('can only be called from the client', 1, true),
        'error message mentions client: ' .. tostring(err))
end)

test('server: onServer throws', function()
    local Obelisk = loadObeliskAs(true)
    local ok = pcall(Obelisk.onServer, 'foo:bar', function() end)
    truthy(not ok, 'expected an error')
end)

test('client: emitServer calls TriggerServerEvent', function()
    local captured
    _G.TriggerServerEvent = function(name, ...) captured = {name, ...} end
    local Obelisk = loadObeliskAs(false)
    Obelisk.emitServer('foo:bar', 'x')
    eq(captured[1], 'foo:bar')
    eq(captured[2], 'x')
end)

test('client: onServer registers via RegisterNetEvent AND AddEventHandler separately', function()
    local registered, handlerName, handlerFn
    _G.RegisterNetEvent = function(name) registered = name end
    _G.AddEventHandler = function(name, fn) handlerName = name; handlerFn = fn end
    local Obelisk = loadObeliskAs(false)
    Obelisk.onServer('foo:bar', function() end)
    eq(registered, 'foo:bar')
    eq(handlerName, 'foo:bar')
    truthy(type(handlerFn) == 'function')
end)

test('client: emitClient throws', function()
    local Obelisk = loadObeliskAs(false)
    local ok, err = pcall(Obelisk.emitClient, 'foo:bar', 5)
    truthy(not ok, 'expected an error')
    truthy(tostring(err):find('can only be called from the server', 1, true),
        'error message mentions server: ' .. tostring(err))
end)

test('client: onClient throws', function()
    local Obelisk = loadObeliskAs(false)
    local ok = pcall(Obelisk.onClient, 'foo:bar', function() end)
    truthy(not ok, 'expected an error')
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running Obelisk unit tests\n')
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
