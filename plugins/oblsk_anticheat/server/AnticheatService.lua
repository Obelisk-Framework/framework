-- plugins/oblsk_anticheat/server/AnticheatService.lua
--- Wires the pure detectors (MovementDetector, HealthDetector,
--- SpawnDetector) to live player telemetry and feeds any violation into
--- ViolationService. This file is intentionally thin — all judgment logic
--- lives in the detector modules so it stays unit-testable; this file only
--- owns state tracking and native/event plumbing.
---
--- Movement and health are server-polled (not client-reported): a
--- `player:` state bag `pos` key was the original design, but nothing in
--- this repo ever writes one, so that path was dead code. Polling
--- GetEntityCoords/GetEntityHealth server-side every ~1s also means the
--- server is the sole source of truth for both checks — a client can no
--- longer suppress the heal/damage check by asserting
--- wasKnownHealAction=true or expectedDamageRange=nil (see anticheat design
--- doc, "Server is the sole source of truth for every verdict").
AnticheatService = AnticheatService or {}

-- [playerId] = {x, y, z, timestamp}
local lastPosition = {}
-- [playerId] = health
local lastHealth = {}

local MAX_SPEED_ON_FOOT = 8.0   -- game units/sec, sprinting
local MAX_SPEED_VEHICLE = 90.0  -- game units/sec, generous upper bound across vehicle classes
local POLL_INTERVAL_MS = 1000

local function maxSpeedForState(ped)
    return IsPedInAnyVehicle(ped, false) and MAX_SPEED_VEHICLE or MAX_SPEED_ON_FOOT
end

CreateThread(function()
    while true do
        Wait(POLL_INTERVAL_MS)

        for _, playerIdStr in ipairs(GetPlayers()) do
            local playerId = tonumber(playerIdStr)
            local player = PlayerService.get(playerId)
            local isSpawned = player and SpawnManagerService.getStage(player) == 'spawned'
            if player and not isSpawned then
                -- Player is still in the join -> character-select flow (or
                -- otherwise not fully spawned yet): ped is 0, so
                -- GetEntityCoords/GetEntityHealth would read (0,0,0)/0 and
                -- falsely register as a teleport/heal the instant they
                -- actually spawn. Skip entirely, and drop any stale sample
                -- so the first poll after they become 'spawned' is recorded
                -- as a fresh baseline rather than compared against it.
                lastPosition[playerId] = nil
                lastHealth[playerId] = nil
            end
            if player and isSpawned then
                local ped = GetPlayerPed(playerId)
                local coords = GetEntityCoords(ped)
                local now = GetGameTimer() / 1000 -- monotonic wall-clock seconds; os.clock() is CPU time and wrong here

                -- Movement check.
                local current = {x = coords.x, y = coords.y, z = coords.z, timestamp = now}
                local previousPosition = lastPosition[playerId]
                lastPosition[playerId] = current
                if previousPosition then
                    local hadLoadingScreen = false -- wiring detail: track via existing spawn/teleport-approved events if any exist
                    local movementViolation = MovementDetector.check(
                        previousPosition, current, maxSpeedForState(ped), hadLoadingScreen)
                    if movementViolation then
                        ViolationService.record(player, movementViolation.category, movementViolation.detail, movementViolation.severity)
                    end
                end

                -- Health check. currentHealth is read server-side (GetEntityHealth), never
                -- taken from the client, so a cheat can't bypass this by lying about it.
                -- There's no medic-service/weapon-damage-config hook visible in this
                -- worktree to derive real wasKnownHealAction/expectedDamageRange values
                -- from, so both are passed as their strictest (never-permissive) values
                -- here; wiring real context is a follow-up once those services are
                -- visible to a full checkout.
                local currentHealth = GetEntityHealth(ped)
                local previousHealth = lastHealth[playerId]
                lastHealth[playerId] = currentHealth
                if previousHealth then
                    local healthViolation = HealthDetector.check(previousHealth, currentHealth, nil, false)
                    if healthViolation then
                        ViolationService.record(player, healthViolation.category, healthViolation.detail, healthViolation.severity)
                    end
                end
            end
        end
    end
end)

-- Ghost-weapon detection (SpawnDetector) is intentionally NOT wired up yet:
-- it depends on InventoryService.getGrantedWeaponHashes(player), which
-- would need a weapon-hash-per-item concept that does not exist anywhere
-- in this framework today (base_items rows have no category/weaponHash
-- field, and no weapon-tracking module/plugin exists). Registering this
-- handler against a nonexistent function would throw at runtime, and
-- guessing a fallback (e.g. "server never grants any weapon") would
-- false-flag every legitimate weapon carry as a violation — the same
-- class of harm as the movement/health false positives already found and
-- fixed in this plugin. Leaving it unregistered is safe: the client's
-- corresponding emitServerSecure('anticheat:server:reportWeapons', ...)
-- call becomes a harmless no-op (no server-side name gets armed for it).
-- Wire this back up once the framework has a real weapon-item model to
-- query, per docs/superpowers/specs/2026-08-20-anticheat-design.md
-- ("Weapon/item spawning").

Obelisk.on('playerDropped', function()
    local source = source
    lastPosition[source] = nil
    lastHealth[source] = nil
    EventGuardService.clearPlayer(source)
end)

return AnticheatService
