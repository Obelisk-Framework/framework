# Obelisk Event Wrapper & WebView/NUI Module

## Goal

Replace ad hoc `RegisterNetEvent`/`TriggerServerEvent`/`TriggerClientEvent`/`SendNUIMessage` call sites with three small, purpose-built modules:

- A Lua `Obelisk` table (shared, both sides) wrapping the six event primitives (`emit`, `on`, `emitServer`, `emitClient`, `onServer`, `onClient`).
- A Lua `WebView` table (client owns the real NUI control surface; server gets a thin per-player proxy) replacing `core/client/bootstrap.lua`'s `OpenNUI`/`CloseNUI` exports and ad hoc `SendNUIMessage` calls scattered across services.
- A JS `Obelisk` singleton (renamed from the reference `Events` class) that becomes the one NUI↔client-Lua bridge on the Vue side, replacing `web/src/composables/useNui.js`.

None of this changes the `<plugin>:<server|client>:<action>` naming convention adopted earlier the same day; every event name these modules use still follows it, and callers still always pass the full name string, not a bare action.

## Background

Today, every service (`NotificationService`, `ProgressService`, `InteractionService`, etc.) hand-rolls its own `RegisterNetEvent`/`TriggerClientEvent` pairs and its own `SendNUIMessage` calls, each with a slightly different payload shape (`{type = ..., someField = ...}`). There's no shared vocabulary for "send this to one client," "listen for what the server sent," or "control the webview," and no way for a plugin to add its own persistent overlay UI (like `Notifications`/`ProgressBars` today) without hand-editing `App.vue`.

This spec introduces the shared vocabulary. It does not touch the *existing* services' business logic, only:
- the transport primitives they use to talk over the network (now via `Obelisk`),
- the transport primitives client Lua uses to talk to the webview (now via `WebView` and the payload shape below), and
- the mechanism for registering a persistent NUI overlay (now a registry, not a hardcoded mount in `App.vue`).

## Architecture

### 1. `Obelisk` Lua event wrapper — `core/shared/Obelisk.lua`

A shared script (already covered by `fxmanifest.lua`'s `'core/shared/**/*.lua'` glob, no manifest change needed), loaded on both server and client. It branches on `IsDuplicityVersion()` (`true` on the server) to expose the side-appropriate methods and to make the wrong-side methods fail loudly instead of silently misbehaving.

**Both sides:**
- `Obelisk.emit(eventName, ...)`: local-only, same-side. `TriggerEvent(eventName, ...)`.
- `Obelisk.on(eventName, callback)`: local-only, same-side. `AddEventHandler(eventName, callback)` only, `RegisterNetEvent` is deliberately NOT called here, since that would make an otherwise-local event name remotely triggerable by the other side. Only `onServer`/`onClient` (which genuinely receive networked events) call `RegisterNetEvent`.

**Server only** (each throws `'Obelisk.<name> can only be called from the server'` if called on the client):
- `Obelisk.emitClient(eventName, target, ...)`: `TriggerClientEvent(eventName, target, ...)`.
- `Obelisk.onServer(eventName, callback)`: `RegisterNetEvent(eventName)` + `AddEventHandler(eventName, callback)`, documented as "the receiving half of a client's `emitServer`" (identical mechanism to `on`, kept as a separate name for symmetry and readability at call sites).

**Client only** (each throws `'Obelisk.<name> can only be called from the client'` if called on the server):
- `Obelisk.emitServer(eventName, ...)`: `TriggerServerEvent(eventName, ...)`.
- `Obelisk.onClient(eventName, callback)`: `RegisterNetEvent(eventName)` + `AddEventHandler(eventName, callback)`, the receiving half of a server's `emitClient`.

No auto-namespacing anywhere: every call site passes the complete `plugin:context:action` string itself, exactly as it does today.

### 2. `WebView` Lua module

Two files, each loaded automatically by the existing `Services/*.lua` (server, non-recursive) / `Services/**/*.lua` (client, recursive) globs:

- `core/client/Services/WebView.lua`: the real implementation. Absorbs everything `core/client/bootstrap.lua` currently does for NUI (the `RegisterNUICallback('navigate', ...)`/`RegisterNUICallback('close', ...)` handlers, `OpenNUI`/`CloseNUI` and their `exports`, and the ESC-key-closes-NUI thread). `bootstrap.lua` keeps only its startup prints and the `core:client:ready` trigger.
- `core/server/Services/WebView.lua`: a thin per-player proxy. Since there's exactly one webview (the `ui_page`) per client, "opening it from the server" means telling *that player's client* to open it locally — there's no server-side NUI to touch directly.

**Client-side methods** (the real behavior):

| Method | Behavior |
|---|---|
| `WebView.focus()` | `SetNuiFocus(true, true)` — grab both keyboard focus and cursor. Updates `WebView.state`. |
| `WebView.toggleCursor()` | Flips cursor-only mode (`SetNuiFocus(WebView.state.focus, not WebView.state.cursor)`), tracked in a local `WebView.state = {focus = false, cursor = false}` table (initialized at script load) since FXServer has no "get current NUI focus" native. Every method below that calls `SetNuiFocus` updates both fields of `WebView.state` to match, so this stays accurate across calls. |
| `WebView.showCursor()` / `WebView.hideCursor()` | Explicit set/clear of cursor-only mode (`SetNuiFocus(WebView.state.focus, true/false)`), independent of full focus. Updates `WebView.state.cursor`. |
| `WebView.show()` | `SendNUIMessage({eventname = 'core:client:webview-show', args = {}})` — tells the Vue app to render (the app itself decides what "showing" means; see Global elements below). Does not by itself grab focus/cursor, and does not touch `WebView.state`. |
| `WebView.hide()` | Mirrors `show()`, plus `SetNuiFocus(false, false)` to release focus/cursor unconditionally. Sets `WebView.state = {focus = false, cursor = false}`. |
| `WebView.destroy()` | Full reset: sends a single `core:client:webview-destroy` NUI message; releases focus/cursor, and the Vue-side registry resets every global element back to its own `defaultVisible` (not blanket-hidden, so elements like `notifications`/`progressBars` that default to visible come back after a destroy instead of staying hidden for the rest of the session). Logical reset only, there is one persistent webview process for the resource's lifetime; this never tears down the actual browser instance. |
| `WebView.openPage(page)` | `SendNUIMessage({eventname = 'core:client:webview-openPage', args = {page}})`; the Vue side's `Obelisk.on('core:client:webview-openPage', ...)` handler does the `router.push(page)`. Does not implicitly call `focus()` — call it explicitly if the page needs input. |
| `WebView.toggleGlobalElement(name)` / `showGlobalElement(name)` / `hideGlobalElement(name)` | `SendNUIMessage` with the matching `eventname`, `args = {name}`; the Vue-side registry (below) flips that element's `visible` flag. |
| `WebView.emit(eventName, data)` | Generic escape hatch: `SendNUIMessage({eventname = eventName, args = {data}})`, for any plugin-defined NUI message that isn't one of the above. |
| `WebView.emitServer(eventName, ...)` | Convenience alias for `Obelisk.emitServer(eventName, ...)` — exists on `WebView` so a `RegisterNUICallback` handler that needs to immediately relay to the server doesn't have to separately require `Obelisk`. |

**Server-side methods** (the proxy): for every method above except `emit`, `emitServer` (client-only, no server-side meaning) — `focus`, `toggleCursor`, `showCursor`, `hideCursor`, `show`, `hide`, `destroy`, `openPage`, `toggleGlobalElement`, `showGlobalElement`, `hideGlobalElement` — the server exposes `WebView.<name>(target, ...)`, sending `Obelisk.emitClient('core:server:webview-' .. name, target, ...)`. `target`'s client listens once per method name (`Obelisk.onClient('core:server:webview-' .. name, function(...) WebView[name](...) end)`) and calls its own local method. This is generated from one shared list of method names on both sides (`RELAY_METHODS`) rather than hand-written per method, to avoid eleven near-identical copies.

`WebView.emitClient(target, eventName, data)` is the one server-side method with no same-named client method: it relays to the client's generic `WebView.emit(eventName, data)`, letting the server push arbitrary NUI messages into one player's webview. Internally this reuses the same relay list under the entry `emitClient` (server name) → `emit` (client name it calls).

A `TriggerClientEvent`/`emitClient` call to a disconnected or invalid player ID is a silent no-op in FXServer; this is accepted, not treated as an error to handle.

### 3. NUI message payload shape

Every `SendNUIMessage` call (existing and new) uses one shape from now on:

```lua
SendNUIMessage({
    eventname = 'core:client:progress-start',
    args = { progressData }  -- always a table/array of positional args
})
```

This replaces the current `{type = '...', someNamedField = ...}` shape used by `NotificationService`/`ProgressService`. `NotificationService.lua` and `ProgressService.lua` (client-side) are updated to the new shape as part of this work — no functional change to what they send, only the envelope.

### 4. Global elements registry (Vue)

Today `App.vue` hardcodes `<Notifications />` and `<ProgressBars />` as always-mounted. This becomes a registry:

- `web/src/globalElements.js` (core's own): exports a list of `{ name, component, defaultVisible }` entries — `notifications` and `progressBars`, both `defaultVisible: true`, preserving today's behavior exactly.
- A new glob, mirroring the existing plugin-routes pattern in `web/src/router/index.js`: `import.meta.glob('../../../plugins/*/web/globalElements.js', { eager: true })`, merged with core's own list. A plugin adds a persistent overlay the same way it adds a page today, just in a different file.
- `App.vue` builds a `reactive` `Map<name, {component, visible}>` from the merged list at startup (`visible` seeded from `defaultVisible`, default `false` if omitted) and renders every entry via `<component :is="entry.component" v-if="entry.visible" v-for="[name, entry] in registry" :key="name" />`.
- `Obelisk.on('core:client:webview-showGlobalElement', ([name]) => registry.get(name).visible = true)` (and the `hide`/`toggle` equivalents) live in `App.vue`'s setup, next to where the registry is built.

### 5. `Obelisk` JS singleton — `web/src/obelisk.js`

Your reference class, renamed `Obelisk`, exported as the module's default (a singleton instance, matching the reference `export default new Events()`):

```js
class Obelisk {
  events = new Map()

  constructor() {
    window.addEventListener('message', (event) => {
      const { eventname, args = [] } = event.data
      const cbs = this.events.get(eventname)
      if (cbs) Promise.allSettled(cbs.map(cb => cb(...args)))
    })
  }

  on(eventName, cb) {
    if (!this.events.has(eventName)) this.events.set(eventName, [])
    const cbs = this.events.get(eventName)
    if (!cbs.includes(cb)) cbs.push(cb)
  }

  off(eventName, cb) {
    if (!this.events.has(eventName)) return
    const cbs = this.events.get(eventName).filter(callback => callback !== cb)
    if (cbs.length > 0) this.events.set(eventName, cbs)
    else this.events.delete(eventName)
  }

  async emit(eventName, args) {
    const res = await fetch(`https://${GetParentResourceName()}/${eventName}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(args)
    })
    if (!res.ok) throw new Error(`HTTP error! Status: ${res.status}`)
    return await res.json()
  }
}

export default new Obelisk()
```

(`GetParentResourceName` here is the same global FiveM injects into the NUI page today — already used by `Notifications.vue`/`ProgressBars.vue` directly, not something this module defines itself.)

`web/src/composables/useNui.js` is deleted; its two consumers (`Notifications.vue`, `ProgressBars.vue`) and `App.vue`'s manual `window.addEventListener('message')` block switch to `import Obelisk from '../../obelisk.js'` and `Obelisk.on(...)`/`Obelisk.emit(...)`. `GetParentResourceName()` (used by `useNui.js` today only as a `window.location`-parsing fallback) keeps whatever fallback behavior it already has, unchanged.

No plugin currently imports `useNui.js` (verified: only `Notifications.vue` and `ProgressBars.vue` use it), so this is a clean removal, not a deprecation.

## Error Handling

- `Obelisk.emitClient`/`onServer` called from the client, or `emitServer`/`onClient` called from the server: `error('Obelisk.<name> can only be called from the <side>')`. Loud failure, not a silent no-op, since calling the wrong one is a programmer error.
- `WebView`'s server-side proxy sending to a disconnected/invalid player: no error (matches FXServer's own `TriggerClientEvent` semantics), not handled specially.
- `WebView.toggleGlobalElement`/`showGlobalElement`/`hideGlobalElement` for a `name` not present in the registry: the Vue-side handler does nothing (no matching `Map` entry to flip) rather than throwing, since a stale/misspelled name shouldn't crash the whole NUI.
- A plugin's `globalElements.js` exporting something malformed (missing `name`/`component`): skipped with a `console.warn`, not a hard failure, mirroring how `router/index.js` already silently skips a plugin's `routes.js` if it isn't a proper array.

## Testing

- `core/shared/Obelisk.lua`'s routing/error logic (the `IsDuplicityVersion()` branch, and the wrong-side error throws) is pure Lua logic with no real native I/O needed beyond a call-recording stub, so it gets real unit tests: a new `tests/obelisk_spec.lua`, following `tests/orm_spec.lua`'s existing tiny test-framework pattern. `tests/support/fivem_stubs.lua` gains spy-friendly stubs for `IsDuplicityVersion`, `RegisterNetEvent`, `AddEventHandler`, `TriggerEvent`, `TriggerServerEvent`, `TriggerClientEvent` (each overridable per-test, same pattern as the existing `Database.executeQuery` capture helper). `package.json`'s `test` script and `tests/README.md` are updated to run both spec files.
- `WebView.lua` (both sides) is FXServer-native-heavy (`SetNuiFocus`, `SendNUIMessage`, `TriggerClientEvent` to a real player) — no automated test, matching the existing convention already applied to `bootstrap.lua` and the CLI generators. Verified manually: `lua5.4 -e "loadfile(...)"` syntax check on both files, plus a real-server smoke test noted as a followup (no FXServer runtime exists in this repo's test environment).
- The Vue/JS side (`obelisk.js`, `App.vue`'s registry, `Notifications.vue`/`ProgressBars.vue`) has no existing JS test framework in this repo (matching convention) — verified via `@vue/compiler-sfc` parse checks and a full `vite build`, same as the verification already used earlier this session for the event-naming rename.

## Out of Scope

- Auto-namespacing event names from call-stack/file-path detection — explicitly rejected in favor of always passing the full name.
- Any change to the actual business-logic services (`NotificationService`, `ProgressService`, `InteractionService`, etc.) beyond the transport calls they make. Their `TriggerServerEvent`/`TriggerClientEvent`/`RegisterNetEvent` calls are migrated to `Obelisk.emit*`/`Obelisk.on*` equivalents (mechanical, one-for-one), but no other logic changes.
- Multiple simultaneous webview instances/pages — FXServer's NUI model is one `ui_page` per resource; `WebView` manages visibility/routing within that one page, not multiple browser processes.
- A real-server smoke test for `WebView`'s `SetNuiFocus`/`SendNUIMessage` behavior — flagged above as a followup, not verifiable in this repo's test environment.
