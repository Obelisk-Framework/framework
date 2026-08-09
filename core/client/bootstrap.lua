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

-- NUI Message handler for route changes
RegisterNUICallback('core:client:navigate', function(data, cb)
    if data.route then
        -- Handle navigation
        SendNUIMessage({
            type = 'core:client:navigate',
            route = data.route
        })
    end
    cb('ok')
end)

-- NUI Close handler
RegisterNUICallback('core:client:close', function(data, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

-- Helper function to open NUI
function OpenNUI(page)
    SetNuiFocus(true, true)
    SendNUIMessage({
        type = 'core:client:open',
        page = page or '/'
    })
end

-- Helper function to close NUI
function CloseNUI()
    SetNuiFocus(false, false)
    SendNUIMessage({
        type = 'core:client:close'
    })
end

-- Export functions for other resources
exports('OpenNUI', OpenNUI)
exports('CloseNUI', CloseNUI)

-- Key press handler for ESC to close UI
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        
        if IsControlJustPressed(0, 322) then -- ESC
            -- Check if NUI is focused
            if IsNuiFocused() then
                CloseNUI()
            end
        end
    end
end)

print('[Obelisk Client] Bootstrap complete')
