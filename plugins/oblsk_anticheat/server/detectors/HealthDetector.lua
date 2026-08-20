-- plugins/oblsk_anticheat/server/detectors/HealthDetector.lua
--- Pure health-sanity checks. Two independent checks: an instant full-ish
--- heal outside a known heal action, and damage taken that's far below
--- what the weapon that hit the player should deal (godmode / damage
--- reduction). Both are heuristics on the observed delta, not a physics
--- simulation.
HealthDetector = HealthDetector or {}

local FULL_HEAL_THRESHOLD = 150 -- health gained in one update this large, unexplained, is suspicious
local DAMAGE_UNDERSHOOT_RATIO = 0.5 -- taking less than this fraction of expected min damage is suspicious

--- @param previousHealth number
--- @param currentHealth number
--- @param expectedDamageRange table|nil {min, max} when this update follows a weapon hit; nil otherwise
--- @param wasKnownHealAction boolean true if a medic/heal-item action explains a health increase
--- @return table|nil {category='health', detail=string, severity='hard'} or nil
function HealthDetector.check(previousHealth, currentHealth, expectedDamageRange, wasKnownHealAction)
    local delta = currentHealth - previousHealth

    if delta > 0 then
        if delta >= FULL_HEAL_THRESHOLD and not wasKnownHealAction then
            return {
                category = 'health',
                detail = string.format('unexplained heal of %d', delta),
                severity = 'hard',
            }
        end
        return nil
    end

    if expectedDamageRange then
        local damageTaken = -delta
        local minExpected = expectedDamageRange.min
        if damageTaken < minExpected * DAMAGE_UNDERSHOOT_RATIO then
            return {
                category = 'health',
                detail = string.format('took %d damage, expected at least %.1f', damageTaken, minExpected),
                severity = 'hard',
            }
        end
    end

    return nil
end

return HealthDetector
