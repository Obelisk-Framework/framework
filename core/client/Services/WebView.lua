--- Client WebView - owns NUI focus/cursor state and the webview's lifecycle.
--- Absorbs what core/client/bootstrap.lua used to do for NUI directly.
WebView = {}
WebView.state = { focus = false, cursor = false }

local function setFocus(focus, cursor)
    SetNuiFocus(focus, cursor)
    WebView.state.focus = focus
    WebView.state.cursor = cursor
end

function WebView.focus()
    setFocus(true, true)
end

function WebView.toggleCursor()
    setFocus(WebView.state.focus, not WebView.state.cursor)
end

function WebView.showCursor()
    setFocus(WebView.state.focus, true)
end

function WebView.hideCursor()
    setFocus(WebView.state.focus, false)
end

function WebView.show()
    SendNUIMessage({ eventname = 'core:client:webview-show', args = {} })
end

function WebView.hide()
    SendNUIMessage({ eventname = 'core:client:webview-hide', args = {} })
    setFocus(false, false)
end

--- Full logical reset: tells the Vue app to hide every global element and
--- releases focus/cursor. There is one persistent webview for the resource's
--- lifetime; this never tears down the actual browser instance.
function WebView.destroy()
    SendNUIMessage({ eventname = 'core:client:webview-destroy', args = {} })
    setFocus(false, false)
end

function WebView.openPage(page)
    SendNUIMessage({ eventname = 'core:client:webview-openPage', args = { page } })
end

function WebView.toggleGlobalElement(name)
    SendNUIMessage({ eventname = 'core:client:webview-toggleGlobalElement', args = { name } })
end

function WebView.showGlobalElement(name)
    SendNUIMessage({ eventname = 'core:client:webview-showGlobalElement', args = { name } })
end

function WebView.hideGlobalElement(name)
    SendNUIMessage({ eventname = 'core:client:webview-hideGlobalElement', args = { name } })
end

--- Generic escape hatch for any plugin-defined NUI message not covered above.
function WebView.emit(eventName, data)
    SendNUIMessage({ eventname = eventName, args = { data } })
end

--- Registers an incoming NUI callback without the caller needing to touch
--- RegisterNUICallback directly or remember to call cb('ok') itself: the
--- handler receives just `data`, WebView acks the NUI call right after it
--- returns. Every plugin's client/main.lua should register its own NUI
--- callbacks through this, not RegisterNUICallback directly.
--- @param eventName string
--- @param handler function(data)
function WebView.on(eventName, handler)
    RegisterNUICallback(eventName, function(data, cb)
        local result = handler(data)
        cb(result ~= nil and result or 'ok')
    end)
end

--- Convenience alias for Obelisk.emitServer, so a RegisterNUICallback handler
--- that needs to relay straight to the server doesn't separately require Obelisk.
function WebView.emitServer(eventName, ...)
    Obelisk.emitServer(eventName, ...)
end

--- Wire up the server->client relay: every clientMethodName in
--- WebViewRelayMethods becomes callable by the server via Obelisk.emitClient.
for _, clientMethodName in pairs(WebViewRelayMethods) do
    Obelisk.onServer('core:server:webview-' .. clientMethodName, function(...)
        WebView[clientMethodName](...)
    end)
end

--- NUI callback: the webview asked to navigate; echo it back as a message so
--- the Vue router can act on it (see web/src/App.vue's Obelisk.on handler).
WebView.on('core:client:navigate', function(data)
    if data.route then
        WebView.emit('core:client:navigate', data.route)
    end
end)

WebView.on('core:client:close', function()
    WebView.hide()
end)

--- ESC closes the webview when it currently has focus.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if IsControlJustPressed(0, 322) and IsNuiFocused() then
            WebView.hide()
        end
    end
end)

exports('OpenNUI', function(page)
    WebView.openPage(page)
    WebView.focus()
end)
exports('CloseNUI', WebView.hide)

return WebView
