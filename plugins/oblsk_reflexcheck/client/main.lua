-- plugins/oblsk_reflexcheck/client/main.lua
--- oblsk_reflexcheck - Client Main
--- Pure relay between the NUI page and the server, same posture as
--- oblsk_fishing's client/main.lua. All validation/judging happens
--- server-side in ReflexCheckService.

WebView.on('reflexcheck:attempt', function(data)
    WebView.emitServer('reflexcheck:server:attempt')
end)

WebView.on('reflexcheck:ready', function(data)
    WebView.emitServer('reflexcheck:server:ready')
end)

Obelisk.onServer('reflexcheck:server:zone', function(payload)
    WebView.emit('reflexcheck:zone', payload)
end)

Obelisk.onServer('reflexcheck:client:feedback', function(payload)
    WebView.emit('reflexcheck:feedback', payload)
end)

Obelisk.onServer('reflexcheck:client:result', function(payload)
    WebView.emit('reflexcheck:result', payload)
end)
