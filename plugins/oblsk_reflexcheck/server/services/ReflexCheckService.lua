-- plugins/oblsk_reflexcheck/server/services/ReflexCheckService.lua
--- ReflexCheckService - server-authoritative reflex-dial skill check.
--- Every random decision (zone angle) and every timing judgement (has the
--- needle reached the zone) happens here, driven only by GetGameTimer()
--- and math.random. The client is told what to render (zoneAngle,
--- needleSpeed, zoneWidth) and reports only a bare "a keypress happened"
--- event — never a claimed hit/miss. See
--- docs/superpowers/specs/2026-08-16-oblsk-reflexcheck-design.md.
ReflexCheckService = {}

ReflexCheckService.sessions = {} -- source -> session table

-- Fallback presets for load-order safety: core/fxmanifest.lua globs every
-- plugin's shared/*.lua into one resource with no guaranteed order, so
-- ReflexCheckConfig may not exist yet when this file's top-level code
-- runs. Same idiom as FishingChallengeService's BITE_WINDOW_MS fallback.
local DEFAULT_PRESETS = {
    easy = { zoneWidth = 48, needleSpeed = 170, maxMisses = 4, timeoutMs = 8000 },
    medium = { zoneWidth = 34, needleSpeed = 230, maxMisses = 3, timeoutMs = 6000 },
    hard = { zoneWidth = 22, needleSpeed = 300, maxMisses = 2, timeoutMs = 4500 },
}

-- Used only when neither opts.timeoutMs nor the resolved preset provide one
-- (e.g. an unrecognized difficulty falling back past presets.medium, which
-- always has its own timeoutMs in practice - this is a last-resort floor).
local DEFAULT_TIMEOUT_MS = 6000

--- @return table presets keyed by difficulty name
local function resolvePresets()
    return (ReflexCheckConfig and ReflexCheckConfig.Presets) or DEFAULT_PRESETS
end

--- @param count number|table|nil a plain required-hit count, a {min,max}
---   range (resolved to a random int in range), or nil (defaults to 1)
--- @return number
local function resolveCount(count)
    if type(count) == 'table' then
        local lo, hi = count[1], count[2]
        if hi == nil then hi = lo end
        if hi < lo then hi = lo end
        local resolved = math.random(lo, hi)
        return resolved <= 0 and 1 or resolved
    end
    local resolved = count or 1
    return resolved <= 0 and 1 or resolved
end

--- Current needle angle, derived purely from server-side elapsed time —
--- never from any client-supplied value.
--- @param session table
--- @return number degrees, 0-359.999...
local function currentAngle(session)
    local elapsedMs = GetGameTimer() - session.startServerTime
    return (elapsedMs / 1000 * session.needleSpeed) % 360
end

--- @param angle number
--- @param zoneAngle number
--- @return number degrees from zoneAngle to angle, going clockwise, 0-359.999...
local function angularDistance(angle, zoneAngle)
    return (angle - zoneAngle + 360) % 360
end

--- @param source number
--- @param opts table|nil { difficulty, count, maxMisses, zoneWidth, needleSpeed }
--- @param onDone function(passed: boolean)
--- @return boolean ok
--- @return string|nil err set only when ok is false
--- @return table|nil info { zoneAngle, needleSpeed, zoneWidth, requiredHits } set only when ok is true
function ReflexCheckService.start(source, opts, onDone)
    if ReflexCheckService.sessions[source] then
        return false, 'busy', nil
    end

    opts = opts or {}
    local presets = resolvePresets()
    local preset = presets[opts.difficulty or 'medium'] or presets.medium

    local zoneWidth = opts.zoneWidth or preset.zoneWidth
    local needleSpeed = opts.needleSpeed or preset.needleSpeed
    local maxMisses = opts.maxMisses or preset.maxMisses
    local timeoutMs = opts.timeoutMs or preset.timeoutMs or DEFAULT_TIMEOUT_MS
    local requiredHits = resolveCount(opts.count)
    local zoneAngle = math.random(0, 359)

    ReflexCheckService.sessions[source] = {
        zoneAngle = zoneAngle,
        needleSpeed = needleSpeed,
        zoneWidth = zoneWidth,
        timeoutMs = timeoutMs,
        startServerTime = GetGameTimer(),
        hits = 0,
        misses = 0,
        requiredHits = requiredHits,
        maxMisses = maxMisses,
        onDone = onDone,
    }

    return true, nil, {
        zoneAngle = zoneAngle,
        needleSpeed = needleSpeed,
        zoneWidth = zoneWidth,
        requiredHits = requiredHits,
    }
end

--- Force-resolves and cleans up a session. Shared by a genuine win/loss
--- inside attempt() and by cancel()'s disconnect path.
--- @param source number
--- @param passedResult boolean
--- @return string 'passed'|'failed'
function ReflexCheckService.finish(source, passedResult)
    local session = ReflexCheckService.sessions[source]
    ReflexCheckService.sessions[source] = nil
    if session and session.onDone then
        session.onDone(passedResult)
    end
    return passedResult and 'passed' or 'failed'
end

--- @param source number
--- @return string result 'hit'|'miss'|'passed'|'failed'|'no-session'
--- @return table|nil nextZone { zoneAngle } set only when result is 'hit' or 'miss'
function ReflexCheckService.attempt(source)
    local session = ReflexCheckService.sessions[source]
    if not session then
        return 'no-session'
    end

    local angle = currentAngle(session)
    local hit = angularDistance(angle, session.zoneAngle) <= session.zoneWidth

    if hit then
        session.hits = session.hits + 1
        if session.hits >= session.requiredHits then
            return ReflexCheckService.finish(source, true)
        end
    else
        session.misses = session.misses + 1
        if session.misses >= session.maxMisses then
            return ReflexCheckService.finish(source, false)
        end
    end

    -- Reposition the zone ahead of the current needle so it's never
    -- already under it — same rule as the design reference's nextZone().
    local offset = math.random(90, 280)
    session.zoneAngle = (angle + offset) % 360

    return (hit and 'hit' or 'miss'), { zoneAngle = session.zoneAngle }
end

--- Force-fails a session that has outlived its timeoutMs (e.g. the player
--- ESC'd the NUI away, or simply never pressed). No-op - and returns false -
--- if the source has no session (already resolved naturally, or this is a
--- stale timer from a session that already finished) or hasn't actually
--- timed out yet.
--- @param source number
--- @return boolean timedOut
function ReflexCheckService.checkTimeout(source)
    local session = ReflexCheckService.sessions[source]
    if not session then
        return false
    end
    if GetGameTimer() - session.startServerTime < session.timeoutMs then
        return false
    end
    ReflexCheckService.finish(source, false)
    return true
end

--- Force-fails an in-progress session (e.g. on disconnect). No-op if the
--- source has no session.
--- @param source number
function ReflexCheckService.cancel(source)
    if ReflexCheckService.sessions[source] then
        ReflexCheckService.finish(source, false)
    end
end

--- @param source number
--- @return table|nil the live session table - callers must not mutate it
function ReflexCheckService.getSession(source)
    return ReflexCheckService.sessions[source]
end

--- Test-only: clears every in-memory session between spec cases.
function ReflexCheckService.resetForTests()
    ReflexCheckService.sessions = {}
end

return ReflexCheckService
