--- Client SpawnManagerService - reacts to the two stage events the server
--- SpawnManagerService emits: freeze + hide HUD on connect, unfreeze + show
--- HUD once a character has spawned. No native automated tests exist for
--- this file (FreezeEntityPosition/PlayerPedId aren't stubbed headless);
--- verify manually per the plan's end-to-end checklist.
SpawnManagerService = {}
SpawnManagerService.stage = nil

--- @param frozen boolean
function SpawnManagerService.FreezePlayer(frozen)
    FreezeEntityPosition(PlayerPedId(), frozen)
end

--- Fires a local event other HUD-owning plugins can listen for. No listener
--- exists yet in this framework — this defines the contract other plugins
--- can adopt later.
--- @param visible boolean
function SpawnManagerService.SetHudVisible(visible)
    TriggerEvent('obelisk:hud:setVisible', visible)
end

Obelisk.onServer('core:server:spawn-begin', function()
    SpawnManagerService.stage = 'connecting'
    SpawnManagerService.FreezePlayer(true)
    SpawnManagerService.SetHudVisible(false)
    TriggerEvent('obelisk:spawnStageChanged', 'connecting')
end)

Obelisk.onServer('core:server:spawn-complete', function(characterId)
    SpawnManagerService.stage = 'spawned'
    SpawnManagerService.FreezePlayer(false)
    SpawnManagerService.SetHudVisible(true)
    TriggerEvent('obelisk:spawnStageChanged', 'spawned', characterId)
end)

return SpawnManagerService
