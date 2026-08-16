ReflexCheckConfig = {}

ReflexCheckConfig.Debug = false

-- Degrees for the success band, degrees/sec for the needle sweep speed,
-- the miss count that auto-fails a session, and the session timeout in
-- milliseconds (see ReflexCheckService.checkTimeout). A caller's `opts`
-- table (see ReflexCheckService.start) may override any of these per-call.
-- zoneWidth is measured clockwise FROM zoneAngle (i.e. the hit band spans
-- [zoneAngle, zoneAngle + zoneWidth]), not centered on zoneAngle - see
-- ReflexCheckService.angularDistance/attempt.
ReflexCheckConfig.Presets = {
    easy = { zoneWidth = 48, needleSpeed = 170, maxMisses = 4, timeoutMs = 8000 },
    medium = { zoneWidth = 34, needleSpeed = 230, maxMisses = 3, timeoutMs = 6000 },
    hard = { zoneWidth = 22, needleSpeed = 300, maxMisses = 2, timeoutMs = 4500 },
}

return ReflexCheckConfig
