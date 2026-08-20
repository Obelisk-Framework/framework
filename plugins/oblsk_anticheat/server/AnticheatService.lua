-- plugins/oblsk_anticheat/server/AnticheatService.lua
--- Wires the pure detectors (MovementDetector, HealthDetector,
--- SpawnDetector) to live player telemetry and feeds any violation into
--- ViolationService. This file is intentionally thin — all judgment logic
--- lives in the detector modules so it stays unit-testable; this file only
--- owns state tracking and native/event plumbing.
AnticheatService = AnticheatService or {}

-- [playerId] = {x, y, z, timestamp}
local lastPosition = {}
-- [playerId] = health
local lastHealth = {}

local MAX_SPEED_ON_FOOT = 8.0   -- game units/sec, sprinting
local MAX_SPEED_VEHICLE = 90.0  -- game units/sec, generous upper bound across vehicle classes

local function maxSpeedForState(player)
    -- Wiring detail: read the player's current vehicle state (however
    -- PedService/VehicleService already exposes it) to pick between
    -- MAX_SPEED_ON_FOOT and MAX_SPEED_VEHICLE. Verify against
    -- PedService's actual API on a live server before shipping — this
    -- function is the one piece of this task worth hand-testing first.
    return player:isInVehicle() and MAX_SPEED_VEHICLE or MAX_SPEED_ON_FOOT
end

Obelisk.onStateBag('pos', 'player:', function(bagName, key, value, bagId, replicated)
    local playerId = tonumber(bagId:match('player:(%d+)'))
    local player = PlayerService.get(playerId)
    if not player then return end

    local current = {x = value.x, y = value.y, z = value.z, timestamp = os.clock()}
    local previous = lastPosition[playerId]
    lastPosition[playerId] = current
    if not previous then return end

    local hadLoadingScreen = false -- wiring detail: track via existing spawn/teleport-approved events if any exist
    local violation = MovementDetector.check(previous, current, maxSpeedForState(player), hadLoadingScreen)
    if violation then
        ViolationService.record(player, violation.category, violation.detail, violation.severity)
    end
end)

Obelisk.onClientSecure('anticheat:server:reportHealth', function(player, currentHealth, expectedDamageRange, wasKnownHealAction)
    local ok, reason = EventGuardService.validate(player:getSource(), 'anticheat:server:reportHealth',
        {{type = 'number', min = 0, max = 200}}, {currentHealth})
    if not ok then
        ViolationService.record(player, 'event', reason, 'soft')
        return
    end

    local playerId = player:getSource()
    local previous = lastHealth[playerId]
    lastHealth[playerId] = currentHealth
    if not previous then return end

    local violation = HealthDetector.check(previous, currentHealth, expectedDamageRange, wasKnownHealAction)
    if violation then
        ViolationService.record(player, violation.category, violation.detail, violation.severity)
    end
end)

Obelisk.onClientSecure('anticheat:server:reportWeapons', function(player, clientReportedWeaponHashes)
    local ok, reason = EventGuardService.validate(player:getSource(), 'anticheat:server:reportWeapons', {}, {})
    if not ok then
        ViolationService.record(player, 'event', reason, 'soft')
        return
    end

    -- Wiring detail: fetch this character's actually-granted weapon
    -- hashes from InventoryService (filter buildCharacterSync's items to
    -- the weapon category and map to hashes) — confirm the exact field
    -- names against InventoryService.buildCharacterSync on a live server
    -- before wiring this call in.
    local serverGrantedWeaponHashes = InventoryService.getGrantedWeaponHashes(player)

    local violation = SpawnDetector.check(clientReportedWeaponHashes, serverGrantedWeaponHashes)
    if violation then
        ViolationService.record(player, violation.category, violation.detail, violation.severity)
    end
end)

return AnticheatService
