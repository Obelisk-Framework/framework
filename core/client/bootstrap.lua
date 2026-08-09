--- Obelisk Framework Bootstrap (Client)
--- Initializes client-side systems

print([[
  ╔═══════════════════════════════════════╗
  ║   OBELISK FRAMEWORK - CLIENT INIT    ║
  ╚═══════════════════════════════════════╝
]])

-- Initialize NUI
Citizen.CreateThread(function()
    Wait(1000)

    -- Enable NUI focus for development
    SetNuiFocus(false, false)

    print('[Obelisk Client] NUI initialized')

    -- Request initial data from server
    TriggerServerEvent('core:client:ready')

    print('[Obelisk Client] Ready')
end)

print('[Obelisk Client] Bootstrap complete')
