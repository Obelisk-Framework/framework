-- plugins/oblsk_anticheat/server/detectors/MovementDetector.lua
--- Pure movement-sanity checks: no natives, no DB, no net events — takes
--- two position samples and the context needed to judge them, returns a
--- violation descriptor or nil. The wiring task (AnticheatService) owns
--- collecting the actual samples from live state bag updates and calling
--- this per update.
MovementDetector = MovementDetector or {}

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- @param previous table {x, y, z, timestamp} last known-good sample
--- @param current table {x, y, z, timestamp} newest sample
--- @param maxSpeedForState number game-defined max units/sec for the player's current movement state (on-foot/vehicle/parachute/etc)
--- @param hadLoadingScreen boolean true if a loading-screen event fired between the two samples
--- @return table|nil {category='movement', detail=string, severity='hard'} or nil if the movement looks legitimate
function MovementDetector.check(previous, current, maxSpeedForState, hadLoadingScreen)
    local dt = current.timestamp - previous.timestamp
    if dt <= 0 then
        -- Out-of-order or duplicate update; nothing to judge.
        return nil
    end

    local dist = distance(previous, current)

    if hadLoadingScreen then
        -- A loading screen legitimately teleports the player (spawn,
        -- respawn, interior transition); skip both checks for this sample.
        return nil
    end

    if dist > Config.Anticheat.teleportDistanceThreshold then
        return {
            category = 'movement',
            detail = string.format('teleport: %.1f units in %.2fs with no loading screen', dist, dt),
            severity = 'hard',
        }
    end

    local speed = dist / dt
    local allowedSpeed = maxSpeedForState * Config.Anticheat.speedToleranceMultiplier
    if speed > allowedSpeed then
        return {
            category = 'movement',
            detail = string.format('speed %.1f exceeds allowed %.1f', speed, allowedSpeed),
            severity = 'hard',
        }
    end

    return nil
end

return MovementDetector
