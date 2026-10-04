-- Real client/server services bridged through native spies; no handshake or crypto.
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
local function loadInto(path, env)
    return assert(loadfile(ROOT .. '/' .. path, 't', env))()
end
local handlers = { server = {}, client = {} }
local sender, target = 7, nil
local player = { getSource = function() return 7 end }
local now = 0
local function environment(side)
    local env = setmetatable({}, { __index = _G })
    env.SecureEventService = {}
    env.RegisterNetEvent = function() end
    env.AddEventHandler = function(name, callback)
        assert(not handlers[side][name], 'duplicate stable handler')
        handlers[side][name] = callback
        return callback
    end
    env.GetGameTimer = function() return now end
    env.PlayerService = { get = function(source) if source == 7 then return player end end }
    return env
end
local server, client = environment('server'), environment('client')
client.TriggerServerEvent = function(name, ...)
    server.source = sender
    assert(handlers.server[name], 'server/client names disagree')(...)
end
server.TriggerClientEvent = function(name, source, ...)
    target = source
    client.source = 65535
    assert(handlers.client[name], 'server/client names disagree')(...)
end
local serverService = loadInto('core/server/Services/SecureEventService.lua', server)
local clientService = loadInto('core/client/Services/SecureEventService.lua', client)
local requests, responses = 0, 0
clientService.onServerSecure('reply', function(...)
    local args = table.pack(...)
    assert(args.n == 3 and args[1] == 'ok' and args[2] == nil and args[3] == nil)
    responses = responses + 1
end)
serverService.onClientSecure('request', function(resolved, ...)
    assert(resolved == player, 'must resolve native sender, not claimed payload')
    local args = table.pack(...)
    assert(args.n == 3 and args[1] == 999 and args[2] == nil and args[3] == nil)
    requests = requests + 1
    serverService.emitClientSecure('reply', resolved, 'ok', nil, nil)
end)
clientService.emitServerSecure('request', 999, nil, nil)
clientService.emitServerSecure('request', 999, nil, nil)
assert(requests == 2 and responses == 2 and target == 7)
sender = 8
clientService.emitServerSecure('request', 7, nil, nil)
assert(requests == 2, 'unknown native sender must not claim another Player')

-- Replay protection belongs to domain state, not event names. A server-issued
-- operation is bound to the native Player and consumed before yielding/effects.
sender = 7
local pending = { ['server-issued-operation'] = player }
local rewards = 0
serverService.onClientSecure('claim', function(resolved, operationId)
    pending[operationId] = nil
    rewards = rewards + 1
end, {
    validate = function(_, operationId) return type(operationId) == 'string' end,
    authorize = function(resolved, operationId) return pending[operationId] == resolved end,
})
clientService.emitServerSecure('claim', 'server-issued-operation')
clientService.emitServerSecure('claim', 'server-issued-operation')
clientService.emitServerSecure('claim', 'client-chosen-operation')
assert(rewards == 1, 'replayed and invented operation IDs must not grant rewards')

-- Client bootstrap must no longer register or request a secure handshake.
client.Citizen = { CreateThread = function() end }
client.RegisterNetEvent = function() error('bootstrap must not register a handshake') end
client.AddEventHandler = function() error('bootstrap must not register a handshake') end
client.TriggerServerEvent = function() error('bootstrap must not request a handshake') end
loadInto('core/client/bootstrap.lua', client)
print('Secure event transport integration: passed')
