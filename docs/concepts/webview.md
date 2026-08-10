# WebView & NUI

There's exactly one webview per client (the `ui_page`, a single Vue 3 app). `WebView` is the Lua-side API for controlling it, and a matching `Obelisk` singleton on the JS side is how the Vue app talks back to client Lua. See [Services: Obelisk](/concepts/services#obelisk) for the separate net-event wrapper this builds on.

## Client-side `WebView`

The real implementation, `core/client/Services/WebView.lua`. Every method except `emit`/`emitServer` also exists on the server (below) as a per-player proxy.

- **`WebView.focus()`**: `SetNuiFocus(true, true)`, grabbing both keyboard focus and cursor.
- **`WebView.toggleCursor()`** / **`showCursor()`** / **`hideCursor()`**: toggle cursor-only mode independent of full focus. FXServer has no "get current NUI focus" native, so `WebView.state = {focus, cursor}` tracks it locally; every method that calls `SetNuiFocus` keeps it in sync.
- **`WebView.show()`** / **`WebView.hide()`**: send a `core:client:webview-show`/`-hide` NUI message. `hide()` also releases focus/cursor unconditionally. Neither one has a built-in meaning on the Vue side by default (see Global elements below for what actually controls visibility). A plugin subscribing to these decides what "showing" means for its own UI.
- **`WebView.destroy()`**: a full logical reset. Releases focus/cursor and tells the Vue app (via `core:client:webview-destroy`) to reset every registered global element back to its own default visibility. There's one persistent webview for the resource's lifetime; this never tears down the actual browser instance.
- **`WebView.openPage(page)`**: sends `core:client:webview-openPage`; the Vue side does `router.push(page)`. Doesn't grab focus on its own, call `WebView.focus()` too if the page needs input.
- **`WebView.toggleGlobalElement(name)`** / **`showGlobalElement(name)`** / **`hideGlobalElement(name)`**: flip a [global element](#global-elements)'s visibility by name.
- **`WebView.emit(eventName, data)`**: the generic escape hatch, for any NUI message not covered above.
- **`WebView.emitServer(eventName, ...)`**: a convenience alias for `Obelisk.emitServer`, so a `RegisterNUICallback` handler that needs to immediately relay to the server doesn't have to separately reference `Obelisk`.

`exports('OpenNUI', function(page) ... end)` and `exports('CloseNUI', WebView.hide)` are still exported for anything outside `core` that calls them, implemented on top of `WebView` now instead of the old bootstrap-level functions.

## Server-side `WebView`

A thin per-player proxy, `core/server/Services/WebView.lua`. There's no server-side NUI to touch directly, "opening it from the server" means telling a specific player's client to act locally:

```lua
WebView.openPage(source, 'shop')
WebView.focus(source)
```

Every client-side method above except `emit`/`emitServer` gets this `WebView.<name>(target, ...)` server form, relaying to `target`'s client via `Obelisk.emitClient`. `WebView.emitClient(target, eventName, data)` is the one server-only method, pushing an arbitrary NUI message straight into one player's webview (the server-side name for what the client receives as `WebView.emit`).

Both sides share one list of method names, `WebViewRelayMethods` in `core/shared/WebViewRelay.lua`, so the server's sender and the client's receiver can't drift out of sync with each other.

A `TriggerClientEvent` to a disconnected or invalid player ID is a silent no-op in FXServer, same here, calling a server-side `WebView` method for an offline player doesn't error.

## NUI messages

Every `SendNUIMessage` call (core's own and anything a plugin sends) uses one shape:

```lua
SendNUIMessage({
    eventname = 'core:client:progress-start',
    args = { progressData }  -- always a table, even for zero args ({} sends nothing)
})
```

`args` is always a table of positional arguments, spread into the JS handler's parameters, matching the `eventname` convention documented in [Services: Event naming](/concepts/services#event-naming).

## The `Obelisk` JS singleton

`web/src/obelisk.js`, the one NUI↔client-Lua bridge on the Vue side. Import it directly, no Vue composable wrapper needed:

```js
import Obelisk from '../../obelisk.js' // adjust the relative path to web/src/obelisk.js

Obelisk.on('core:client:progress-start', (progressData) => {
  addProgress(progressData)
})

Obelisk.emit('core:client:progress-userCancel', { progressId })
```

- **`Obelisk.on(eventName, cb)`**: registers `cb` for NUI messages matching `eventname`. Multiple callbacks can register under the same name.
- **`Obelisk.off(eventName, cb)`**: unregisters it.
- **`Obelisk.emit(eventName, args)`**: POSTs to the `RegisterNUICallback` matching `eventName` on the client. In dev mode (outside a real NUI webview, `window.invokeNative` absent), this logs to the console instead of making a request.

This replaced the old `useNui.js` composable, which no longer exists.

## Global elements

Plugins and modules can add persistent overlay UI without editing `App.vue`, by exporting a `globalElements.js` from their `web/` directory, picked up the same way `web/src/router/index.js` already globs plugin/module `routes.js` files, via `['../../modules/*/web/globalElements.js', '../../plugins/*/web/globalElements.js']`:

```js
// plugins/myplugin/web/globalElements.js
import MyHud from './components/MyHud.vue'

export default [
  { name: 'myHud', component: MyHud, defaultVisible: true }
]
```

`App.vue` merges every module's and plugin's list with core's own (`web/src/globalElements.js`, now an empty array, core ships zero HUD elements itself, every one lives in its own plugin, e.g. `oblsk_notifications`/`oblsk_progressbar`) into a reactive registry keyed by `name`, each entry's `visible` flag starting at its own `defaultVisible`. An entry missing `name`/`component`, or a module/plugin whose default export isn't an array, is skipped with a `console.warn` rather than breaking the whole app.

`WebView.showGlobalElement(name)`/`hideGlobalElement(name)`/`toggleGlobalElement(name)` (either side) flip an entry's `visible` flag by name; a name that isn't registered is silently ignored, not an error. `WebView.destroy()` resets every entry back to its own `defaultVisible`, not to hidden, so an element that defaults to visible comes back after a destroy instead of staying hidden for the rest of the session.
