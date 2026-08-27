-- tests/secure_event_service_client_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/sha256.lua')
dofile(ROOT .. '/core/shared/EventNaming.lua')

local registered = {}
local sent = {}
_G.RegisterNetEvent = function() end
_G.AddEventHandler = function(name, fn)
    registered[name] = fn
    return {name = name}
end
_G.RemoveEventHandler = function(handlerRef)
    registered[handlerRef.name] = nil
end
_G.TriggerServerEvent = function(name, ...)
    sent[#sent + 1] = {name = name, args = {...}}
end

dofile(ROOT .. '/core/client/Services/SecureEventService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

test('emitServerSecure sends the counter-0 name first, then advances', function()
    sent = {}
    SecureEventService.startSession('client-secret')

    SecureEventService.emitServerSecure('garage:server:open', 42)
    SecureEventService.emitServerSecure('garage:server:open', 43)

    local name0 = EventNaming.deriveName('client-secret', 'garage:server:open', 'client_to_server', 0)
    local name1 = EventNaming.deriveName('client-secret', 'garage:server:open', 'client_to_server', 1)

    eq(#sent, 2)
    eq(sent[1].name, name0)
    eq(sent[1].args[1], 42)
    eq(sent[2].name, name1)
    eq(sent[2].args[1], 43)
end)

test('onServerSecure receives on the counter-0 name and rolls to counter-1', function()
    registered = {}
    SecureEventService.startSession('client-secret')

    local received = {}
    SecureEventService.onServerSecure('garage:client:opened', function(arg)
        received[#received + 1] = arg
    end)

    local name0 = EventNaming.deriveName('client-secret', 'garage:client:opened', 'server_to_client', 0)
    truthy(registered[name0] ~= nil)

    registered[name0]('ok')
    eq(#received, 1)
    eq(received[1], 'ok')

    local name1 = EventNaming.deriveName('client-secret', 'garage:client:opened', 'server_to_client', 1)
    truthy(registered[name1] ~= nil, 'next name not registered')
    truthy(registered[name0] == nil, 'old name not removed')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
