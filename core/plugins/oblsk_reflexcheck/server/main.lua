-- core/plugins/oblsk_reflexcheck/server/main.lua
--- oblsk_reflexcheck - Server Main
--- Public entry point (ReflexCheck.Start) for other plugins, and the net
--- event wiring for the in-progress check. All judging happens in
--- ReflexCheckService; this file only translates between Player objects/
--- WebView and the service's plain source-number API. See
--- docs/superpowers/specs/2026-08-16-oblsk-reflexcheck-design.md.
print('[ReflexCheck] Loading...')

ReflexCheck = {}

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
    Obelisk.emitClient('reflexcheck:server:zone', player, info)
    return true
end

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
AddEventHandler('playerDropped', function()
    local source = source
    ReflexCheckService.cancel(source)
end)
