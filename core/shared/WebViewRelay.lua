--- Shared list of WebView methods the server can trigger on a specific
--- client. Loaded on both sides (fxmanifest.lua's shared_scripts glob covers
--- 'core/shared/**/*.lua') so the server-side proxy (core/server/Services/
--- WebView.lua) and the client-side receiver (core/client/Services/
--- WebView.lua) agree on the exact event names without duplicating the list
--- across the two separate Lua VMs.
---
--- Each entry: serverMethodName -> clientMethodName. Every method has the
--- same name on both sides except emitClient (server) -> emit (client).
WebViewRelayMethods = {
    focus = 'focus',
    toggleCursor = 'toggleCursor',
    showCursor = 'showCursor',
    hideCursor = 'hideCursor',
    show = 'show',
    hide = 'hide',
    destroy = 'destroy',
    openPage = 'openPage',
    toggleGlobalElement = 'toggleGlobalElement',
    showGlobalElement = 'showGlobalElement',
    hideGlobalElement = 'hideGlobalElement',
    emitClient = 'emit',
}
