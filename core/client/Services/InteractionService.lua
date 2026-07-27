--- Client InteractionService - Manages nearby interactions and displays prompts
InteractionService = {}
InteractionService.interactions = {}
InteractionService.nearbyInteractions = {}
InteractionService.closestInteraction = nil

--- Sync all interactions from server
RegisterNetEvent('obelisk:interaction:syncAll')
AddEventHandler('obelisk:interaction:syncAll', function(interactions)
    InteractionService.interactions = interactions
    print('[InteractionService] Synced ' .. table.count(interactions) .. ' interactions')
end)

--- Add a new interaction
RegisterNetEvent('obelisk:interaction:add')
AddEventHandler('obelisk:interaction:add', function(interaction)
    InteractionService.interactions[interaction.id] = interaction
    print('[InteractionService] Added interaction #' .. interaction.id)
end)

--- Remove an interaction
RegisterNetEvent('obelisk:interaction:remove')
AddEventHandler('obelisk:interaction:remove', function(interactionId)
    InteractionService.interactions[interactionId] = nil
    print('[InteractionService] Removed interaction #' .. interactionId)
end)

--- Update an interaction
RegisterNetEvent('obelisk:interaction:update')
AddEventHandler('obelisk:interaction:update', function(interaction)
    InteractionService.interactions[interaction.id] = interaction
end)

--- Update nearby interactions based on player position
function InteractionService.updateNearby()
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    
    InteractionService.nearbyInteractions = {}
    InteractionService.closestInteraction = nil
    local closestDist = math.huge
    
    for id, interaction in pairs(InteractionService.interactions) do
        if interaction.enabled then
            local interactionCoords = vector3(interaction.x, interaction.y, interaction.z)
            local dist = #(playerCoords - interactionCoords)
            
            if dist <= interaction.range then
                table.insert(InteractionService.nearbyInteractions, {
                    interaction = interaction,
                    distance = dist
                })
                
                if dist < closestDist then
                    closestDist = dist
                    InteractionService.closestInteraction = interaction
                end
            end
        end
    end
end

--- Use the closest interaction
function InteractionService.useClosest()
    if InteractionService.closestInteraction then
        TriggerServerEvent('obelisk:interaction:use', InteractionService.closestInteraction.id)
    end
end

--- Draw 3D text for interaction
function InteractionService.draw3DText(x, y, z, text)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    local px, py, pz = table.unpack(GetGameplayCamCoords())
    local dist = #(vector3(px, py, pz) - vector3(x, y, z))
    
    local scale = (1 / dist) * 2
    local fov = (1 / GetGameplayCamFov()) * 100
    scale = scale * fov
    
    if onScreen then
        SetTextScale(0.0 * scale, 0.55 * scale)
        SetTextFont(4)
        SetTextProportional(1)
        SetTextColour(255, 255, 255, 215)
        SetTextDropshadow(0, 0, 0, 0, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        SetTextDropShadow()
        SetTextOutline()
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x, _y)
    end
end

--- Main update thread
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(100) -- Update every 100ms
        
        InteractionService.updateNearby()
    end
end)

--- Render thread for displaying interaction prompts
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        
        if InteractionService.closestInteraction then
            local interaction = InteractionService.closestInteraction
            
            -- Draw 3D text
            local displayText = '[E] ' .. interaction.label
            InteractionService.draw3DText(interaction.x, interaction.y, interaction.z + 1.0, displayText)
        end
    end
end)

--- Request all interactions on start
Citizen.CreateThread(function()
    Wait(2000)
    TriggerServerEvent('obelisk:interaction:requestAll')
end)

--- Helper: Count table entries
function table.count(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

return InteractionService
