-- tests/secure_event_service_client_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')

local handlers, registrations, removed, sent, logs = {}, {}, {}, {}, {}
local originalPrint = print
_G.RegisterNetEvent = function(name) registrations[name] = (registrations[name] or 0) + 1 end
_G.AddEventHandler = function(name, fn)
    local ref = {name = name, fn = fn}
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = ref
    return ref
end
_G.RemoveEventHandler = function(ref)
    removed[#removed + 1] = ref
    for i, candidate in ipairs(handlers[ref.name] or {}) do
        if candidate == ref then table.remove(handlers[ref.name], i); break end
    end
end
_G.TriggerServerEvent = function(name, ...) sent[#sent + 1] = {name = name, args = table.pack(...)} end
_G.print = function(message) logs[#logs + 1] = message end

dofile(ROOT .. '/core/client/Services/SecureEventService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end
local function raises(fn) local ok = pcall(fn); truthy(not ok, 'expected error') end
local function stable(direction, logical) return 'obelisk:secure:' .. direction .. ':' .. logical end

test('repeated sends use stable names and preserve payloads', function()
    sent = {}
    SecureEventService.emitServerSecure('garage:open', 42, 'x')
    SecureEventService.emitServerSecure('garage:open', nil)
    eq(sent[1].name, stable('client_to_server', 'garage:open')); eq(sent[1].args[1], 42)
    eq(sent[2].name, stable('client_to_server', 'garage:open')); eq(sent[2].args.n, 1); eq(sent[2].args[1], nil)
end)

test('server-origin handler accepts source 65535 and forwards nil vararg', function()
    local got, count = nil, 0
    SecureEventService.onServerSecure('garage:opened', function(value) count = count + 1; got = value end)
    local name = stable('server_to_client', 'garage:opened')
    eq(#handlers[name], 1); source = 65535; handlers[name][1].fn(nil); handlers[name][1].fn('again')
    eq(count, 2); eq(got, 'again'); eq(#handlers[name], 1)
end)

test('local/client source is rejected', function()
    local count = 0
    SecureEventService.onServerSecure('garage:local', function() count = count + 1 end)
    local handler = handlers[stable('server_to_client', 'garage:local')][1].fn
    source = 1; handler('bad'); source = 0; handler('bad'); source = nil; handler('bad')
    eq(count, 0)
end)

test('replacement callback has one stable handler and no stacking', function()
    local old, new = 0, 0
    local name = stable('server_to_client', 'garage:replace')
    SecureEventService.onServerSecure('garage:replace', function() old = old + 1 end)
    SecureEventService.onServerSecure('garage:replace', function() new = new + 1 end)
    eq(#handlers[name], 1); eq(registrations[name], 1); source = 65535; handlers[name][1].fn()
    eq(old, 0); eq(new, 1); eq(#removed, 0)
end)

test('callback errors are caught and logged', function()
    logs = {}
    SecureEventService.onServerSecure('garage:error', function() error('boom') end)
    source = 65535; handlers[stable('server_to_client', 'garage:error')][1].fn()
    truthy(#logs >= 1); truthy(logs[1]:find('boom', 1, true) ~= nil)
end)

test('registration validates names and callbacks', function()
    raises(function() SecureEventService.onServerSecure('', function() end) end)
    raises(function() SecureEventService.onServerSecure('x', nil) end)
    raises(function() SecureEventService.emitServerSecure('', 1) end)
end)

for _, t in ipairs(tests) do local ok, err = pcall(t.fn); if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end end
originalPrint(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do originalPrint('FAIL: ' .. f.name); originalPrint('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
