--- Obelisk - shared event wrapper around FXServer's native event primitives.
--- Loaded on both server and client (covered by fxmanifest.lua's
--- 'core/shared/**/*.lua' shared_scripts glob, no manifest change needed).
--- Every method takes the full event name string; nothing here auto-namespaces.
Obelisk = {}

local isServer = IsDuplicityVersion()

--- Trigger a local, same-side event (no networking).
--- @param eventName string
function Obelisk.emit(eventName, ...)
    TriggerEvent(eventName, ...)
end

--- Register a handler for a local, same-side event.
--- @param eventName string
--- @param callback function
function Obelisk.on(eventName, callback)
    RegisterNetEvent(eventName)
    AddEventHandler(eventName, callback)
end

if isServer then
    --- Send an event to one client (or -1 for all). Server only.
    --- @param eventName string
    --- @param target number
    function Obelisk.emitClient(eventName, target, ...)
        TriggerClientEvent(eventName, target, ...)
    end

    --- Register a handler for an event a client sent via Obelisk.emitServer.
    --- Server only.
    --- @param eventName string
    --- @param callback function
    function Obelisk.onServer(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, callback)
    end

    function Obelisk.emitServer()
        error('Obelisk.emitServer can only be called from the client', 2)
    end

    function Obelisk.onClient()
        error('Obelisk.onClient can only be called from the client', 2)
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
    function Obelisk.onClient(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, callback)
    end

    function Obelisk.emitClient()
        error('Obelisk.emitClient can only be called from the server', 2)
    end

    function Obelisk.onServer()
        error('Obelisk.onServer can only be called from the server', 2)
    end
end

return Obelisk
