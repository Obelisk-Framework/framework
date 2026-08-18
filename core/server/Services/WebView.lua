--- Server WebView - per-player proxy. There is exactly one webview per
--- client; "opening" it from the server means telling that specific client's
--- own WebView to act locally. See core/client/Services/WebView.lua for the
--- real implementation this relays to.
WebView = {}

for serverMethodName, clientMethodName in pairs(WebViewRelayMethods) do
    WebView[serverMethodName] = function(player, ...)
        Obelisk.emitClient('core:server:webview-' .. clientMethodName, player, ...)
    end
end

--- Opens a page and grants focus for the given player in one call.
--- Replaces the openPage(player, page) + focus(player) pair that every
--- plugin's openForPlayer function repeated.
function WebView.openFor(player, page)
    WebView.openPage(player, page)
    WebView.focus(player)
end

return WebView
