--- SpawnManagerService (core) - owns the join -> select -> spawn lifecycle
--- at the framework level: tracks which stage each connected player is in
--- and relays the two stage transitions the client needs to react to
--- (freeze+hide-hud on connect, unfreeze+show-hud once a character has
--- spawned). Deliberately thin: no loading-screen UI, no death/respawn
--- integration, no server-side spawn-position logic (that stays in
--- CharacterService.getVitals/saveVitals). Character-selection UI, ped
--- appearance and camera work are owned by oblsk_character-selection, not
--- here. See docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md.
SpawnManagerService = {}
SpawnManagerService.stages = {} -- source -> 'connecting' | 'spawned'

--- Called once a connecting player's account has resolved (after
--- oblsk_accounts' playerConnecting handler runs) — signals the client to
--- freeze the player, hide the HUD, and show its own character-selection UI.
--- @param player Player
function SpawnManagerService.markConnecting(player)
    SpawnManagerService.stages[player:getSource()] = 'connecting'
    player:emit('core:server:spawn-begin')
end

--- Called by a character-selection-style plugin once a character has been
--- chosen and its appearance/position applied client-side — signals the
--- client to unfreeze and restore the HUD.
--- @param player Player
--- @param characterId any
function SpawnManagerService.readyToSpawn(player, characterId)
    SpawnManagerService.stages[player:getSource()] = 'spawned'
    player:emit('core:server:spawn-complete', characterId)
end

--- @param player Player
--- @return string|nil
function SpawnManagerService.getStage(player)
    return SpawnManagerService.stages[player:getSource()]
end

Obelisk.on('playerDropped', function()
    local source = source
    SpawnManagerService.stages[source] = nil
end)

return SpawnManagerService
