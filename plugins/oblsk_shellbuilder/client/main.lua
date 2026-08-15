-- core/plugins/oblsk_shellbuilder/client/main.lua
print('[ShellBuilder] Client loading...')

WebView.on('shellbuilder:create', function(data)
    WebView.emitServer('shellbuilder:client:create', data.name)
end)

WebView.on('shellbuilder:enter', function(data)
    WebView.emitServer('shellbuilder:client:enter', data.shellId)
end)

WebView.on('shellbuilder:edit', function(data)
    WebView.emitServer('shellbuilder:client:edit', data.shellId)
end)

WebView.on('shellbuilder:exit', function(data)
    WebView.emitServer('shellbuilder:client:exit', data.shellId)
end)

WebView.on('shellbuilder:place', function(data)
    WebView.emitServer('shellbuilder:client:place', data.shellId, data.itemKey,
        data.x, data.y, data.z, data.heading, data.floorLevel, data.colorData, data.locked)
end)

WebView.on('shellbuilder:removeObject', function(data)
    WebView.emitServer('shellbuilder:client:removeObject', data.shellId, data.objectId)
end)

Obelisk.onClient('shellbuilder:server:sync', function(payload)
    WebView.emit('shellbuilder:sync', payload)
end)

Obelisk.onClient('shellbuilder:server:entered', function(payload)
    WebView.emit('shellbuilder:entered', payload)
end)

Obelisk.onClient('shellbuilder:server:editSync', function(payload)
    WebView.emit('shellbuilder:editSync', payload)
end)

Obelisk.onClient('shellbuilder:server:exited', function(payload)
    WebView.emit('shellbuilder:exited', payload)
end)

Obelisk.onClient('shellbuilder:server:objectPlaced', function(payload)
    WebView.emit('shellbuilder:objectPlaced', payload)
end)

Obelisk.onClient('shellbuilder:server:objectRemoved', function(payload)
    WebView.emit('shellbuilder:objectRemoved', payload)
end)
