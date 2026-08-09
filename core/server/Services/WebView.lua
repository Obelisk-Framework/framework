--- Server WebView - per-player proxy. There is exactly one webview per
--- client; "opening" it from the server means telling that specific client's
--- own WebView to act locally. See core/client/Services/WebView.lua for the
--- real implementation this relays to.
WebView = {}

for serverMethodName, clientMethodName in pairs(WebViewRelayMethods) do
    WebView[serverMethodName] = function(target, ...)
        Obelisk.emitClient('core:server:webview-' .. clientMethodName, target, ...)
    end
end

return WebView
