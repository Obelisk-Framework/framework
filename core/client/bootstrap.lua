--- Obelisk Framework Bootstrap (Client)
--- Initializes client-side systems

print([[
  ╔═══════════════════════════════════════╗
  ║   OBELISK FRAMEWORK - CLIENT INIT    ║
  ╚═══════════════════════════════════════╝
]])

RegisterNetEvent('obelisk:secureHandshake')
AddEventHandler('obelisk:secureHandshake', function(sessionSecret)
    SecureEventService.startSession(sessionSecret)
end)

-- Ask the server to (re)send the handshake secret now that this resource's
-- own event handlers have actually started. playerJoining fires on the
-- server before the client resource is guaranteed to be running, so a
-- server-sent-first handshake is very likely lost; request/response here
-- is naturally ready by construction.
TriggerServerEvent('obelisk:requestHandshake')

-- Initialize NUI
Citizen.CreateThread(function()
    Wait(1000)

    -- Enable NUI focus for development
    SetNuiFocus(false, false)

    print('[Obelisk Client] NUI initialized')

    -- Request initial data from server
    Obelisk.emitServer('core:client:ready')

    print('[Obelisk Client] Ready')
end)

print('[Obelisk Client] Bootstrap complete')
