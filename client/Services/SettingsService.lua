--- Exposes the shared Settings.format table (core/shared/Settings.lua) to
--- the web/NUI layer. Answered directly from the client's own copy — no
--- server round-trip needed, since Settings is a shared script.
WebView.on('core:client:getFormatSettings', function(_data)
    WebView.emit('core:client:formatSettings', Settings.format)
end)
