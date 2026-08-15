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

WebView.on('shellbuilder:arm', function(data)
    Placement.arm(data.itemKey, data.locked)
end)

WebView.on('shellbuilder:disarm', function(data)
    Placement.disarm()
end)

WebView.on('shellbuilder:wreck', function(data)
    Placement.setWreckMode(data.enabled)
end)

WebView.on('shellbuilder:setShellId', function(data)
    Placement.setShellId(data.shellId)
end)

WebView.on('shellbuilder:startAim', function()
    Placement.startAim()
end)

WebView.on('shellbuilder:searchCharacters', function(data)
    WebView.emitServer('shellbuilder:client:searchCharacters', data.query)
end)

WebView.on('shellbuilder:addOwner', function(data)
    WebView.emitServer('shellbuilder:client:addOwner', data.shellId, data.characterId)
end)

WebView.on('shellbuilder:removeOwner', function(data)
    WebView.emitServer('shellbuilder:client:removeOwner', data.shellId, data.characterId)
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

Obelisk.onClient('shellbuilder:server:characterSearchResults', function(payload)
    WebView.emit('shellbuilder:characterSearchResults', payload)
end)

Obelisk.onClient('shellbuilder:server:ownersUpdated', function(payload)
    WebView.emit('shellbuilder:ownersUpdated', payload)
end)
