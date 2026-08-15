DeathService = {}

function DeathService:handlePlayerDeath(player)
    Hooks.runHook('death:handle', function(results)
        for _, res in ipairs(results) do
            if res then
                return
            end
        end

        local ped = GetPlayerPed(player:getSource())
        local coords = GetEntityCoords(ped)
        --RespawnPedAtCoords(player, coords)
        SetEntityHealth(ped, GetEntityMaxHealth(ped))
    end, player)
end
