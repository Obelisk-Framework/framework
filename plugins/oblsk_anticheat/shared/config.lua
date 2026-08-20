-- plugins/oblsk_anticheat/shared/config.lua
Config = Config or {}

Config.Anticheat = {
    -- Movement: allowed speed is (game-max-speed-for-state * this), to
    -- absorb network jitter/latency without false-flagging legitimate play.
    speedToleranceMultiplier = 1.25,
    -- Any single position update further than this (game units) with no
    -- loading-screen event in between is flagged as a teleport.
    teleportDistanceThreshold = 100.0,

    -- Escalation: how many violations inside violationWindowSeconds before
    -- ViolationService escalates to a ban instead of just logging.
    violationsBeforeBan = 3,
    violationWindowSeconds = 300,

    -- EventGuardService: max accepted triggers of a single guarded event,
    -- per player, per second.
    eventRateLimitPerSecond = 10,
}

return Config
