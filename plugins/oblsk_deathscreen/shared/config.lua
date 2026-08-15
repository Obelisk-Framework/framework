DeathScreenConfig = {}

DeathScreenConfig.Debug = false

-- Seconds a downed player must wait before "hold to respawn" becomes
-- available. A medic reviving them sooner skips this entirely.
DeathScreenConfig.BleedoutSeconds = 300

-- Where a forced respawn drops the player. Pillbox Hill Medical, matching
-- the design reference's "Respawning at Pillbox" copy.
DeathScreenConfig.RespawnCoords = vector4(298.7, -584.7, 43.3, 158.0)

return DeathScreenConfig
