-- tests/event_naming_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/Services/storage/sha256.lua')
dofile(ROOT .. '/core/shared/EventNaming.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('deriveName is deterministic for identical inputs', function()
    local a = EventNaming.deriveName('secret', 'garage:server:open', 'client_to_server', 0)
    local b = EventNaming.deriveName('secret', 'garage:server:open', 'client_to_server', 0)
    eq(a, b)
end)

test('deriveName starts with the ob_ prefix and is 23 chars total', function()
    local name = EventNaming.deriveName('secret', 'garage:server:open', 'client_to_server', 0)
    eq(name:sub(1, 3), 'ob_')
    eq(#name, 23)
end)

test('deriveName changes when the counter changes (one-time property)', function()
    local n0 = EventNaming.deriveName('secret', 'garage:server:open', 'client_to_server', 0)
    local n1 = EventNaming.deriveName('secret', 'garage:server:open', 'client_to_server', 1)
    if n0 == n1 then error('counter 0 and 1 produced the same name') end
end)

test('deriveName changes when the direction changes', function()
    local toServer = EventNaming.deriveName('secret', 'garage:server:open', 'client_to_server', 0)
    local toClient = EventNaming.deriveName('secret', 'garage:server:open', 'server_to_client', 0)
    if toServer == toClient then error('directions collided') end
end)

test('deriveName changes when the secret changes', function()
    local a = EventNaming.deriveName('secret-a', 'garage:server:open', 'client_to_server', 0)
    local b = EventNaming.deriveName('secret-b', 'garage:server:open', 'client_to_server', 0)
    if a == b then error('different secrets collided') end
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
