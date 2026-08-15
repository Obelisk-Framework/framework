--- oblsk_deathscreen server: hooks into core's DeathService to replace the
--- default instant-respawn behaviour with the full-screen death UI, then
--- performs the actual respawn once the player has held the UI's button
--- (or otherwise earns one, e.g. a future medic revive).

Hooks.registerHook('death:handle', function(player)
    Obelisk.emitClient('deathscreen:client:show', player)
    return true -- suppress DeathService's default instant respawn
end)

Obelisk.onServer('deathscreen:server:playerDied', function()
    DeathService:handlePlayerDeath(source)
end)

Obelisk.onServer('deathscreen:server:respawn', function()
    local source = source
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end

    local coords = DeathScreenConfig.RespawnCoords
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, true)
    SetEntityHeading(ped, coords.w)
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    -- UI closes itself once its own "you pulled through" beat finishes
    -- (see web/DeathScreen.vue) -- no hide event needed from here.
end)
