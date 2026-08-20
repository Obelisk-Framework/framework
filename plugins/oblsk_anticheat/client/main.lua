-- plugins/oblsk_anticheat/client/main.lua
--- Reports raw telemetry to the server for AnticheatService to judge.
--- This file makes no decisions — every verdict happens server-side, per
--- the spec's "server is the sole source of truth" constraint.
local lastHealth = nil

CreateThread(function()
    while true do
        Wait(2000)
        local ped = PlayerPedId()
        local currentHealth = GetEntityHealth(ped)

        if lastHealth ~= nil and currentHealth ~= lastHealth then
            Obelisk.emitServerSecure('anticheat:server:reportHealth', currentHealth, nil, false)
        end
        lastHealth = currentHealth

        local weaponHashes = {}
        -- Wiring detail: FiveM has no single native that lists every
        -- weapon a ped owns; confirm the correct enumeration approach
        -- (e.g. iterating a known weapon hash list with HasPedGotWeapon,
        -- or GetSelectedPedWeapon for just the active one) against the
        -- game build this server targets before finalizing this loop.
        Obelisk.emitServerSecure('anticheat:server:reportWeapons', weaponHashes)
    end
end)
