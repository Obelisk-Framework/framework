-- Server transport guards tested without FiveM or the former crypto protocol.
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
local tests, passed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected)
    assert(actual == expected, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end
local function setup()
    local env = setmetatable({ SecureEventService = {} }, { __index = _G })
    local handlers, registered, sent, logs, players = {}, {}, {}, {}, {}
    local now = 0
    env.RegisterNetEvent = function(name) registered[name] = (registered[name] or 0) + 1 end
    env.AddEventHandler = function(name, callback)
        handlers[name] = handlers[name] or {}
        table.insert(handlers[name], callback)
        return callback
    end
    env.GetGameTimer = function() return now end
    env.TriggerClientEvent = function(...) sent[#sent + 1] = table.pack(...) end
    env.print = function(message) logs[#logs + 1] = message end
    env.PlayerService = { get = function(source) return players[source] end }
    local service = assert(loadfile(ROOT .. '/core/server/Services/SecureEventService.lua', 't', env))()
    local function player(source)
        players[source] = { getSource = function() return source end }
        return players[source]
    end
    local function fire(event, source, ...)
        env.source = source
        local args = table.pack(...)
        for _, callback in ipairs(handlers['obelisk:secure:client_to_server:' .. event] or {}) do
            callback(table.unpack(args, 1, args.n))
        end
        env.source = nil
    end
    return service, player, fire, function(value) now = value end, handlers, registered, sent, logs, env
end

test('stable handlers preserve nil args, native identity and replacement callback', function()
    local service, player, fire, _, handlers, registered = setup()
    local nativePlayer = player(7)
    player(99)
    local first, replacement = 0, 0
    service.onClientSecure('open', function(resolved, ...)
        eq(resolved, nativePlayer)
        local args = table.pack(...)
        eq(args.n, 3); eq(args[1], 99); eq(args[2], nil); eq(args[3], nil)
        first = first + 1
    end)
    fire('open', 7, 99, nil, nil); fire('open', 7, 99, nil, nil)
    eq(first, 2)
    service.onClientSecure('open', function() replacement = replacement + 1 end)
    fire('open', 7)
    eq(first, 2); eq(replacement, 1)
    local name = 'obelisk:secure:client_to_server:open'
    eq(registered[name], 1); eq(#handlers[name], 1)
end)

test('unknown, local and malformed native senders are rejected before guards', function()
    local service, player, fire = setup()
    player(7)
    local calls = 0
    service.onClientSecure('open', function() calls = calls + 1 end, {
        validate = function() calls = calls + 1; return true end,
    })
    for _, source in ipairs({ 0, -1, 99, '7', 1.5, math.huge, 0/0 }) do fire('open', source, 7) end
    fire('open', nil, 7)
    eq(calls, 0)
end)

test('guards fail closed, short circuit and forward all payload args', function()
    for _, guard in ipairs({ 'validate', 'authorize' }) do
        for _, reject in ipairs({
            function() return false end,
            function() return nil end,
            function() return 'truthy' end,
            function() error('bad guard') end,
        }) do
            local service, player, fire = setup()
            player(7)
            local handlerCalls, authorizeCalls = 0, 0
            local options = {
                validate = function() return true end,
                authorize = function() authorizeCalls = authorizeCalls + 1; return true end,
            }
            options[guard] = reject
            service.onClientSecure('open', function() handlerCalls = handlerCalls + 1 end, options)
            fire('open', 7)
            eq(handlerCalls, 0)
            if guard == 'validate' then eq(authorizeCalls, 0) end
        end
    end
    local service, player, fire, _, _, _, _, _, env = setup()
    local nativePlayer, order = player(7), {}
    local function check(stage, resolved, ...)
        eq(resolved, nativePlayer)
        local args = table.pack(...)
        eq(args.n, 2); eq(args[1], 'payload'); eq(args[2], nil)
        order[#order + 1] = stage
        env.source = 99 -- Native source must already have been resolved/captured.
        return true
    end
    service.onClientSecure('open', function(...) check('handler', ...) end, {
        validate = function(...) return check('validate', ...) end,
        authorize = function(...) return check('authorize', ...) end,
    })
    fire('open', 7, 'payload', nil)
    eq(table.concat(order, ','), 'validate,authorize,handler')
end)

test('default rate limit permits 20 attempts and resets at 1000 ms', function()
    local service, player, fire, setNow = setup()
    player(7)
    local calls = 0
    service.onClientSecure('open', function() calls = calls + 1 end)
    for _ = 1, 21 do fire('open', 7) end
    eq(calls, 20)
    setNow(999); fire('open', 7); eq(calls, 20)
    setNow(1000); fire('open', 7); eq(calls, 21)
end)

test('invalid and unauthorized attempts count before guards and log no denial spam', function()
    for _, guard in ipairs({ 'validate', 'authorize' }) do
        local service, player, fire, setNow, _, _, _, logs = setup()
        player(7)
        local guardCalls, handlerCalls = 0, 0
        local options = { rateLimit = { max = 2, windowMs = 50 } }
        options[guard] = function(_, accepted) guardCalls = guardCalls + 1; return accepted == true end
        service.onClientSecure('open', function() handlerCalls = handlerCalls + 1 end, options)
        fire('open', 7, false); fire('open', 7, false); fire('open', 7, true)
        eq(guardCalls, 2); eq(handlerCalls, 0); eq(#logs, 0)
        setNow(50); fire('open', 7, true)
        eq(guardCalls, 3); eq(handlerCalls, 1)
    end
end)

test('limits isolate players/events and survive session calls and re-registration', function()
    local service, player, fire = setup()
    player(7); player(8)
    local first, second = 0, 0
    local options = { rateLimit = { max = 1, windowMs = 100 } }
    service.onClientSecure('open', function() first = first + 1 end, options)
    service.onClientSecure('close', function() second = second + 1 end, options)
    fire('open', 7); fire('open', 7); fire('open', 8); fire('close', 7)
    eq(first, 2); eq(second, 1)
    service.startSession(7, 'ignored')
    service.onClientSecure('open', function() first = first + 1 end, options)
    fire('open', 7); eq(first, 2)
    service.endSession(7)
    fire('open', 7); fire('close', 7); fire('open', 8)
    eq(first, 3); eq(second, 2)
    service.endSession(123) -- Disconnect cleanup is safe for an unknown source.
end)

test('timer wrap/reset does not leave players permanently rate-limited', function()
    local service, player, fire, setNow = setup()
    player(7)
    local calls = 0
    service.onClientSecure('open', function() calls = calls + 1 end, { rateLimit = { max = 1, windowMs = 100 } })
    setNow(2147483647); fire('open', 7); fire('open', 7); eq(calls, 1)
    setNow(-2147483648); fire('open', 7); fire('open', 7); eq(calls, 2)
    setNow(-2147483548); fire('open', 7); eq(calls, 3)
end)

test('callback errors are contained and subsequent events still run', function()
    local service, player, fire, _, _, _, _, logs = setup()
    player(7)
    local calls = 0
    service.onClientSecure('open', function() calls = calls + 1; error('handler failed') end)
    fire('open', 7); fire('open', 7)
    eq(calls, 2); eq(#logs, 2)
    assert(logs[1]:find('handler failed', 1, true))
end)

test('server sends use stable names without sessions and preserve trailing nils', function()
    local service, player, _, _, _, _, sent = setup()
    local recipient = player(7)
    service.emitClientSecure('reply', recipient, 'ok', nil, nil)
    service.emitClientSecure('reply', recipient, 'ok', nil, nil)
    eq(#sent, 2)
    for _, args in ipairs(sent) do
        eq(args.n, 5); eq(args[1], 'obelisk:secure:server_to_client:reply')
        eq(args[2], 7); eq(args[3], 'ok'); eq(args[4], nil); eq(args[5], nil)
    end
end)

test('invalid registration configuration fails at registration time', function()
    local service = setup()
    local function invalid(options)
        eq(pcall(service.onClientSecure, 'open', function() end, options), false)
    end
    for _, value in ipairs({ 0, -1, 1.5, math.huge, 0/0, '1', false }) do
        invalid({ rateLimit = { max = value, windowMs = 100 } })
        invalid({ rateLimit = { max = 1, windowMs = value } })
    end
    invalid(false); invalid('options'); invalid({ rateLimit = false })
    invalid({ rateLimit = {} }); invalid({ validate = true }); invalid({ authorize = true })
    eq(pcall(service.onClientSecure, '', function() end), false)
    eq(pcall(service.onClientSecure, false, function() end), false)
    eq(pcall(service.onClientSecure, 'open', nil), false)
end)

for _, entry in ipairs(tests) do
    local ok, err = pcall(entry.fn)
    if ok then passed = passed + 1; print('PASS: ' .. entry.name)
    else print('FAIL: ' .. entry.name .. '\n' .. tostring(err)) end
end
print(('%d/%d passed'):format(passed, #tests))
os.exit(passed == #tests and 0 or 1)
