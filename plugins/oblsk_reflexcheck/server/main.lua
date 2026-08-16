-- plugins/oblsk_reflexcheck/server/main.lua
--- oblsk_reflexcheck - Server Main
--- Public entry point (ReflexCheck.Start) for other plugins, and the net
--- event wiring for the in-progress check. All judging happens in
--- ReflexCheckService; this file only translates between Player objects/
--- WebView and the service's plain source-number API. See
--- docs/superpowers/specs/2026-08-16-oblsk-reflexcheck-design.md.
print('[ReflexCheck] Loading...')

ReflexCheck = {}

-- source -> { player, info } for a session whose zone push is waiting on
-- the NUI's 'reflexcheck:server:ready' round-trip (see the 'ready' handler
-- below). Cleared once the push actually happens.
local pendingZone = {}

--- Starts a reflex-dial check for `player`. See README.md for the full
--- `opts` shape. Rejects synchronously (without calling onDone) if the
--- player already has a running session.
--- @param player table a core Player object (NOT a raw source)
--- @param opts table|nil { difficulty, count, maxMisses, zoneWidth, needleSpeed }
--- @param onDone function(passed: boolean)
--- @return boolean ok
--- @return string|nil err set only when ok is false
function ReflexCheck.Start(player, opts, onDone)
    local source = player:getSource()
    local ok, err, info = ReflexCheckService.start(source, opts, onDone)
    if not ok then
        return false, err
    end

    WebView.openPage(player, '/ReflexCheck')
    WebView.focus(player)

    -- The zone push itself is gated on the NUI's 'ready' ping (see below) -
    -- the Vue component's onMounted (dynamic import + router resolve) may
    -- not have registered its listener yet in this same tick.
    pendingZone[source] = { player = player, info = info }

    local session = ReflexCheckService.getSession(source)
    if session then
        SetTimeout(session.timeoutMs, function()
            if ReflexCheckService.checkTimeout(source) then
                player:emit('reflexcheck:client:result', { passed = false })
                WebView.destroy(player)
            end
        end)
    end

    return true
end

Obelisk.onClient('reflexcheck:server:ready', function(player)
    local source = player:getSource()
    local pending = pendingZone[source]
    if not pending then
        return
    end
    pendingZone[source] = nil
    Obelisk.emitClient('reflexcheck:server:zone', pending.player, pending.info)
end)

Obelisk.onClient('reflexcheck:server:attempt', function(player)
    local source = player:getSource()
    local result, nextZone = ReflexCheckService.attempt(source)

    if result == 'no-session' then
        return
    end

    if result == 'passed' or result == 'failed' then
        player:emit('reflexcheck:client:result', { passed = (result == 'passed') })
        WebView.destroy(player)
        return
    end

    player:emit('reflexcheck:client:feedback', { result = result, zoneAngle = nextZone.zoneAngle })
end)

--- Disconnect cleanup - a player who quits mid-check would otherwise leave
--- a dangling session (and never call the caller's onDone), matching
--- BoothService's playerDropped handling.
Obelisk.on('playerDropped', function()
    local source = source
    pendingZone[source] = nil
    ReflexCheckService.cancel(source)
end)
