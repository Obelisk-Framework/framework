ReflexCheckConfig = {}

ReflexCheckConfig.Debug = false

-- Degrees for the success band, degrees/sec for the needle sweep speed,
-- and the miss count that auto-fails a session. A caller's `opts` table
-- (see ReflexCheckService.start) may override any of these per-call.
ReflexCheckConfig.Presets = {
    easy = { zoneWidth = 48, needleSpeed = 170, maxMisses = 4 },
    medium = { zoneWidth = 34, needleSpeed = 230, maxMisses = 3 },
    hard = { zoneWidth = 22, needleSpeed = 300, maxMisses = 2 },
}

return ReflexCheckConfig
