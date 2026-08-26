--- Obelisk - shared event wrapper around FXServer's native event primitives.
--- Loaded on both server and client (covered by fxmanifest.lua's
--- 'core/shared/**/*.lua' shared_scripts glob, no manifest change needed).
--- Every method takes the full event name string; nothing here auto-namespaces.
---
--- Naming: onX / emitX names the event's ORIGIN side, and the function itself
--- lives on the OTHER side. emitClient sends to a client (called from the
--- server); onClient handles something a client sent (registered on the
--- server). emitServer sends to the server (called from the client);
--- onServer handles something the server sent (registered on the client).
Obelisk = {}

local isServer = IsDuplicityVersion()

--- Trigger a local, same-side event (no networking).
--- @param eventName string
function Obelisk.emit(eventName, ...)
    TriggerEvent(eventName, ...)
end

--- Register a handler for a local, same-side event (or a global engine event
--- like playerJoining/playerConnecting/onResourceStop).
--- @param eventName string
--- @param callback function
function Obelisk.on(eventName, callback)
    AddEventHandler(eventName, callback)
end

--- Register a handler for state bag key changes.
--- bagFilter narrows to a bag-name prefix (e.g. 'entity:', 'player:') or '' for all bags.
--- callback receives (bagName, key, value, bagId, replicated).
--- @param keyName string
--- @param bagFilter string
--- @param callback function
function Obelisk.onStateBag(keyName, bagFilter, callback)
    AddStateBagChangeHandler(keyName, bagFilter, callback)
end

if isServer then
    --- Send an event to one client. Server only.
    --- @param eventName string
    --- @param player Player|number the recipient, or the literal -1 to broadcast to all clients
    function Obelisk.emitClient(eventName, player, ...)
        local target = player == -1 and -1 or player:getSource()
        TriggerClientEvent(eventName, target, ...)
    end

    --- Register a handler for an event a client sent via Obelisk.emitServer.
    --- The handler receives the resolved Player as its first argument, not a
    --- raw source. If PlayerService has no Player for this connection yet
    --- (only possible in the brief window before playerJoining fires, which
    --- no net event can reach), the event is dropped and logged rather than
    --- calling the handler with nil. Server only.
    --- @param eventName string
    --- @param callback function(player, ...)
    function Obelisk.onClient(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, function(...)
            local player = PlayerService.get(source)
            if not player then
                print('[Obelisk] dropped ' .. eventName .. ': no Player for source ' .. tostring(source))
                return
            end
            callback(player, ...)
        end)
    end

    function Obelisk.emitServer()
        error('Obelisk.emitServer can only be called from the client', 2)
    end

    function Obelisk.onServer()
        error('Obelisk.onServer can only be called from the client', 2)
    end
else
    --- Send an event to the server. Client only.
    --- @param eventName string
    function Obelisk.emitServer(eventName, ...)
        TriggerServerEvent(eventName, ...)
    end

    --- Register a handler for an event the server sent via Obelisk.emitClient.
    --- Client only.
    --- @param eventName string
    --- @param callback function
    function Obelisk.onServer(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, callback)
    end

    function Obelisk.emitClient()
        error('Obelisk.emitClient can only be called from the server', 2)
    end

    function Obelisk.onClient()
        error('Obelisk.onClient can only be called from the server', 2)
    end
end

return Obelisk
