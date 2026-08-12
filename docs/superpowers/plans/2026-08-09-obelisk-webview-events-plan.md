# Obelisk Event Wrapper & WebView/NUI Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Lua `Obelisk` event wrapper (both sides), a Lua `WebView` NUI-control module (client real implementation + server per-player proxy), a matching NUI message payload shape, a Vue global-elements registry, and a JS `Obelisk` singleton replacing `useNui.js` — then migrate every existing service's raw net-event calls onto the new wrapper.

**Architecture:** See `docs/superpowers/specs/2026-08-09-obelisk-webview-events-design.md` for the full design rationale. This plan implements it in dependency order: the shared `Obelisk` wrapper first (everything else calls it), then `WebView` (client, then server), then the NUI transport/Vue-side pieces, then the mechanical migration of existing services.

**Tech Stack:** Lua (FXServer resource scripts, both `server_scripts`/`client_scripts`/`shared_scripts`), Vue 3 (Composition API), Vite.

## Global Constraints

- Every event name is the full `<plugin>:<server|client>:<action>` string, passed explicitly by the caller. Nothing in this plan auto-namespaces anything.
- `Obelisk.emit`/`on` are local-only (same-side `TriggerEvent`/`AddEventHandler`, no networking). Server-only: `emitClient`, `onServer`. Client-only: `emitServer`, `onClient`. Calling a wrong-side method throws `'Obelisk.<name> can only be called from the <side>'`.
- Every `SendNUIMessage` call (existing and new) uses `{eventname = <name>, args = {...}}` — never the old `{type = ..., ...namedFields}` shape.
- No FXServer runtime exists in this repo's test environment. `WebView.lua` (both sides) and the Vue/JS side get manual verification (syntax/parse checks, `npm test`, `vite build`), matching the existing convention already applied to `bootstrap.lua` and the CLI generators — do not introduce new test infrastructure for those. `core/shared/Obelisk.lua`'s routing/error logic IS pure Lua logic and DOES get real unit tests (Task 1).
- No Claude co-authorship in any commit message (repo-wide convention).

---

## Task 1: `core/shared/Obelisk.lua` event wrapper (TDD)

**Files:**
- Create: `core/shared/Obelisk.lua`
- Modify: `tests/support/fivem_stubs.lua`
- Create: `tests/obelisk_spec.lua`
- Modify: `package.json`
- Modify: `tests/README.md`

**Interfaces:**
- Produces: global `Obelisk` table with `emit(eventName, ...)`, `on(eventName, callback)` (both sides); `emitClient(eventName, target, ...)`, `onServer(eventName, callback)` (server only, error on client); `emitServer(eventName, ...)`, `onClient(eventName, callback)` (client only, error on server). Every later task requires this table to exist and behave exactly this way.

- [ ] **Step 1: Add stubs the new test file needs**

In `tests/support/fivem_stubs.lua`, add after the existing `_G.GetConvarInt` line:

```lua
_G.IsDuplicityVersion = _G.IsDuplicityVersion or function() return true end
_G.RegisterNetEvent = _G.RegisterNetEvent or function() end
_G.AddEventHandler = _G.AddEventHandler or function() end
_G.TriggerEvent = _G.TriggerEvent or function() end
_G.TriggerServerEvent = _G.TriggerServerEvent or function() end
_G.TriggerClientEvent = _G.TriggerClientEvent or function() end
```

- [ ] **Step 2: Write the failing test file**

Create `tests/obelisk_spec.lua`:

```lua
--- Unit tests for core/shared/Obelisk.lua's routing/error logic.
--- Run from the repository root:  lua5.4 tests/obelisk_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

--- Loads a fresh Obelisk global under the given server/client mode. Each call
--- re-executes the file, so tests don't leak state into one another.
local function loadObeliskAs(isServer)
    _G.IsDuplicityVersion = function() return isServer end
    _G.Obelisk = nil
    dofile(ROOT .. '/core/shared/Obelisk.lua')
    return _G.Obelisk
end

test('emit: TriggerEvent locally, works on either side', function()
    local captured
    _G.TriggerEvent = function(name, ...) captured = {name, ...} end
    local Obelisk = loadObeliskAs(true)
    Obelisk.emit('foo:bar', 1, 2)
    eq(captured[1], 'foo:bar')
    eq(captured[2], 1)
    eq(captured[3], 2)
end)

test('on: RegisterNetEvent + AddEventHandler locally, works on either side', function()
    local registered, handlerName
    _G.RegisterNetEvent = function(name) registered = name end
    _G.AddEventHandler = function(name, _) handlerName = name end
    local Obelisk = loadObeliskAs(false)
    Obelisk.on('foo:bar', function() end)
    eq(registered, 'foo:bar')
    eq(handlerName, 'foo:bar')
end)

test('server: emitClient calls TriggerClientEvent', function()
    local captured
    _G.TriggerClientEvent = function(name, target, ...) captured = {name, target, ...} end
    local Obelisk = loadObeliskAs(true)
    Obelisk.emitClient('foo:bar', 5, 'x')
    eq(captured[1], 'foo:bar')
    eq(captured[2], 5)
    eq(captured[3], 'x')
end)

test('server: onServer calls RegisterNetEvent + AddEventHandler', function()
    local registered
    _G.RegisterNetEvent = function(name) registered = name end
    local Obelisk = loadObeliskAs(true)
    Obelisk.onServer('foo:bar', function() end)
    eq(registered, 'foo:bar')
end)

test('server: emitServer throws', function()
    local Obelisk = loadObeliskAs(true)
    local ok, err = pcall(Obelisk.emitServer, 'foo:bar')
    truthy(not ok, 'expected an error')
    truthy(tostring(err):find('can only be called from the client', 1, true),
        'error message mentions client: ' .. tostring(err))
end)

test('server: onClient throws', function()
    local Obelisk = loadObeliskAs(true)
    local ok = pcall(Obelisk.onClient, 'foo:bar', function() end)
    truthy(not ok, 'expected an error')
end)

test('client: emitServer calls TriggerServerEvent', function()
    local captured
    _G.TriggerServerEvent = function(name, ...) captured = {name, ...} end
    local Obelisk = loadObeliskAs(false)
    Obelisk.emitServer('foo:bar', 'x')
    eq(captured[1], 'foo:bar')
    eq(captured[2], 'x')
end)

test('client: onClient calls RegisterNetEvent + AddEventHandler', function()
    local registered
    _G.RegisterNetEvent = function(name) registered = name end
    local Obelisk = loadObeliskAs(false)
    Obelisk.onClient('foo:bar', function() end)
    eq(registered, 'foo:bar')
end)

test('client: emitClient throws', function()
    local Obelisk = loadObeliskAs(false)
    local ok, err = pcall(Obelisk.emitClient, 'foo:bar', 5)
    truthy(not ok, 'expected an error')
    truthy(tostring(err):find('can only be called from the server', 1, true),
        'error message mentions server: ' .. tostring(err))
end)

test('client: onServer throws', function()
    local Obelisk = loadObeliskAs(false)
    local ok = pcall(Obelisk.onServer, 'foo:bar', function() end)
    truthy(not ok, 'expected an error')
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running Obelisk unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = t.name
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err):gsub('\n', '\n         '))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `lua5.4 tests/obelisk_spec.lua`
Expected: fails immediately — `core/shared/Obelisk.lua` doesn't exist yet, `dofile` errors.

- [ ] **Step 3: Implement `core/shared/Obelisk.lua`**

```lua
--- Obelisk - shared event wrapper around FXServer's native event primitives.
--- Loaded on both server and client (covered by fxmanifest.lua's
--- 'core/shared/**/*.lua' shared_scripts glob, no manifest change needed).
--- Every method takes the full event name string; nothing here auto-namespaces.
Obelisk = {}

local isServer = IsDuplicityVersion()

--- Trigger a local, same-side event (no networking).
--- @param eventName string
function Obelisk.emit(eventName, ...)
    TriggerEvent(eventName, ...)
end

--- Register a handler for a local, same-side event.
--- @param eventName string
--- @param callback function
function Obelisk.on(eventName, callback)
    RegisterNetEvent(eventName)
    AddEventHandler(eventName, callback)
end

if isServer then
    --- Send an event to one client (or -1 for all). Server only.
    --- @param eventName string
    --- @param target number
    function Obelisk.emitClient(eventName, target, ...)
        TriggerClientEvent(eventName, target, ...)
    end

    --- Register a handler for an event a client sent via Obelisk.emitServer.
    --- Server only.
    --- @param eventName string
    --- @param callback function
    function Obelisk.onServer(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, callback)
    end

    function Obelisk.emitServer()
        error('Obelisk.emitServer can only be called from the client', 2)
    end

    function Obelisk.onClient()
        error('Obelisk.onClient can only be called from the client', 2)
    end
else
    --- Send an event to the server. Client only.
    --- @param eventName string
    function Obelisk.emitServer(eventName, ...)
        TriggerServerEvent(eventName, ...)
    end

    --- Register a handler for an event the server sent via Obelisk.emitClient.
    --- Client only.
    --- @param eventName string
    --- @param callback function
    function Obelisk.onClient(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, callback)
    end

    function Obelisk.emitClient()
        error('Obelisk.emitClient can only be called from the server', 2)
    end

    function Obelisk.onServer()
        error('Obelisk.onServer can only be called from the server', 2)
    end
end

return Obelisk
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `lua5.4 tests/obelisk_spec.lua`
Expected: `9 passed, 0 failed`.

- [ ] **Step 5: Wire the new spec into `npm test` and the tests README**

In `package.json`, change:

```json
"test": "lua5.4 tests/orm_spec.lua",
```

to:

```json
"test": "lua5.4 tests/orm_spec.lua && lua5.4 tests/obelisk_spec.lua",
```

In `tests/README.md`, add a sentence noting `obelisk_spec.lua` covers `core/shared/Obelisk.lua`'s side-detection and error-throwing logic, next to the existing description of `orm_spec.lua`'s scope (read the file first to match its existing structure/wording).

Run: `npm test` — expected: both suites run, all green (`62 passed, 0 failed` then `9 passed, 0 failed`, or however the combined output renders).

- [ ] **Step 6: Commit**

```bash
cd core
git add core/shared/Obelisk.lua tests/support/fivem_stubs.lua tests/obelisk_spec.lua package.json tests/README.md
git commit -m "feat(core): add Obelisk shared event wrapper (emit/on/emitServer/emitClient/onServer/onClient)"
```

---

## Task 2: `WebView` client-side + relay method list + `bootstrap.lua` cleanup

**Files:**
- Create: `core/shared/WebViewRelay.lua`
- Create: `core/client/Services/WebView.lua`
- Modify: `core/client/bootstrap.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient(eventName, callback)` (Task 1).
- Produces: global `WebViewRelayMethods` table (shared, `{serverMethodName = clientMethodName, ...}`), consumed by Task 3's server-side proxy. Global `WebView` table (client) with `focus()`, `toggleCursor()`, `showCursor()`, `hideCursor()`, `show()`, `hide()`, `destroy()`, `openPage(page)`, `toggleGlobalElement(name)`, `showGlobalElement(name)`, `hideGlobalElement(name)`, `emit(eventName, data)`, `emitServer(eventName, ...)`, plus `WebView.state = {focus, cursor}`.

- [ ] **Step 1: Create the shared relay-method list**

Create `core/shared/WebViewRelay.lua`:

```lua
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
```

- [ ] **Step 2: Create the client-side `WebView.lua`**

Create `core/client/Services/WebView.lua`:

```lua
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

--- Convenience alias for Obelisk.emitServer, so a RegisterNUICallback handler
--- that needs to relay straight to the server doesn't separately require Obelisk.
function WebView.emitServer(eventName, ...)
    Obelisk.emitServer(eventName, ...)
end

--- Wire up the server->client relay: every clientMethodName in
--- WebViewRelayMethods becomes callable by the server via Obelisk.emitClient.
for _, clientMethodName in pairs(WebViewRelayMethods) do
    Obelisk.onClient('core:server:webview-' .. clientMethodName, function(...)
        WebView[clientMethodName](...)
    end)
end

--- NUI callback: the webview asked to navigate; echo it back as a message so
--- the Vue router can act on it (see web/src/App.vue's Obelisk.on handler).
RegisterNUICallback('core:client:navigate', function(data, cb)
    if data.route then
        WebView.emit('core:client:navigate', data.route)
    end
    cb('ok')
end)

RegisterNUICallback('core:client:close', function(data, cb)
    WebView.hide()
    cb('ok')
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
```

- [ ] **Step 3: Strip the now-owned-by-WebView code out of `bootstrap.lua`**

In `core/client/bootstrap.lua`, remove the `RegisterNUICallback('navigate', ...)`/`RegisterNUICallback('close', ...)` blocks, the `OpenNUI`/`CloseNUI` function definitions and their `exports(...)` calls, and the ESC-key `Citizen.CreateThread` block (everything from the `-- NUI Message handler for route changes` comment through the `exports('CloseNUI', CloseNUI)` line, and separately the `-- Key press handler for ESC to close UI` thread). The file keeps only its startup prints, the `SetNuiFocus(false, false)`/`TriggerServerEvent('obelisk:client:ready')`-turned-`Obelisk.emitServer('core:client:ready')` startup thread (this line's rename to the `Obelisk` wrapper happens in Task 6, not here — leave it as the plain `TriggerServerEvent` call for now), and the final `print('[Obelisk Client] Bootstrap complete')`.

Resulting file:

```lua
--- Obelisk Framework Bootstrap (Client)
--- Initializes client-side systems

print([[
  ╔═══════════════════════════════════════╗
  ║   OBELISK FRAMEWORK - CLIENT INIT    ║
  ╚═══════════════════════════════════════╝
]])

-- Initialize NUI
Citizen.CreateThread(function()
    Wait(1000)

    -- Enable NUI focus for development
    SetNuiFocus(false, false)

    print('[Obelisk Client] NUI initialized')

    -- Request initial data from server
    TriggerServerEvent('core:client:ready')

    print('[Obelisk Client] Ready')
end)

print('[Obelisk Client] Bootstrap complete')
```

- [ ] **Step 4: Manual verification (no FXServer runtime available here)**

Run: `lua5.4 -e "assert(loadfile('core/shared/WebViewRelay.lua'))"` and the same for `core/client/Services/WebView.lua` and `core/client/bootstrap.lua` — all three must parse without error.

Run: `npm test` — must still show all Lua suites green (this task doesn't touch anything they cover, this just guards against an unrelated regression).

- [ ] **Step 5: Commit**

```bash
cd core
git add core/shared/WebViewRelay.lua core/client/Services/WebView.lua core/client/bootstrap.lua
git commit -m "feat(core): add client-side WebView module, absorb NUI lifecycle out of bootstrap.lua"
```

---

## Task 3: `WebView` server-side proxy

**Files:**
- Create: `core/server/Services/WebView.lua`

**Interfaces:**
- Consumes: `WebViewRelayMethods` (Task 2), `Obelisk.emitClient(eventName, target, ...)` (Task 1).
- Produces: global `WebView` table (server) with `focus(target)`, `toggleCursor(target)`, `showCursor(target)`, `hideCursor(target)`, `show(target)`, `hide(target)`, `destroy(target)`, `openPage(target, page)`, `toggleGlobalElement(target, name)`, `showGlobalElement(target, name)`, `hideGlobalElement(target, name)`, `emitClient(target, eventName, data)`.

- [ ] **Step 1: Create the server-side proxy**

Create `core/server/Services/WebView.lua`:

```lua
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
```

- [ ] **Step 2: Manual verification**

Run: `lua5.4 -e "assert(loadfile('core/server/Services/WebView.lua'))"` — must parse.

Read through the generated method table by hand and confirm: `WebView.emitClient(target, eventName, data)` sends `core:server:webview-emit` (not `core:server:webview-emitClient`), matching client `WebView.lua`'s relay loop which listens on `'core:server:webview-' .. clientMethodName` for every `clientMethodName` value in `WebViewRelayMethods` (and `WebViewRelayMethods.emitClient == 'emit'`, so the event name the client listens on and the event name the server sends are the same string).

Run: `npm test` — still green (unrelated).

- [ ] **Step 3: Commit**

```bash
cd core
git add core/server/Services/WebView.lua
git commit -m "feat(core): add server-side WebView per-player proxy"
```

---

## Task 4: NUI payload shape + `web/src/obelisk.js` + Vue NUI-bridge migration

**Files:**
- Modify: `core/client/Services/NotificationService.lua`
- Modify: `core/client/Services/ProgressService.lua`
- Create: `web/src/obelisk.js`
- Delete: `web/src/composables/useNui.js`
- Modify: `web/src/components/global/Notifications.vue`
- Modify: `web/src/components/global/ProgressBars.vue`

**Interfaces:**
- Produces: `web/src/obelisk.js` default export, a singleton with `on(eventName, cb)`, `off(eventName, cb)`, `async emit(eventName, args)`. Consumed by Task 5 (`App.vue`) and by `Notifications.vue`/`ProgressBars.vue` in this task.

- [ ] **Step 1: Switch the two client Lua services' `SendNUIMessage` calls to `{eventname, args}`**

In `core/client/Services/NotificationService.lua`, change:

```lua
    SendNUIMessage({
        type = 'core:client:notification-show',
        notification = notification
    })
```

to:

```lua
    SendNUIMessage({
        eventname = 'core:client:notification-show',
        args = { notification }
    })
```

In `core/client/Services/ProgressService.lua`, change each of the three `SendNUIMessage` calls:

```lua
    SendNUIMessage({
        type = 'progress:start',
        progress = progressData
    })
```
→
```lua
    SendNUIMessage({
        eventname = 'core:client:progress-start',
        args = { progressData }
    })
```

(Note: the `type` value here is still the pre-rename literal `'progress:start'` in the file on disk today — this task's diff also finishes converting it to `'core:client:progress-start'` as part of the same edit, since Task 4 runs on top of the already-renamed event-naming work everywhere else in the file. Read the file first to confirm its current exact content before editing.)

```lua
    SendNUIMessage({
        type = 'progress:complete',
        progressId = progressId
    })
```
→
```lua
    SendNUIMessage({
        eventname = 'core:client:progress-complete',
        args = { progressId }
    })
```

```lua
    SendNUIMessage({
        type = 'progress:cancel',
        progressId = progressId
    })
```
→
```lua
    SendNUIMessage({
        eventname = 'core:client:progress-cancel',
        args = { progressId }
    })
```

- [ ] **Step 2: Create the JS `Obelisk` singleton**

Create `web/src/obelisk.js`:

```js
/**
 * The one NUI <-> client-Lua bridge. `on`/`off` register callbacks for
 * messages Lua sends via SendNUIMessage ({eventname, args}); `emit` posts to
 * the matching RegisterNUICallback name on the client Lua side.
 */
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
    if (!window.invokeNative) {
      console.log('[Dev] NUI emit:', eventName, args)
      return
    }

    const res = await fetch(`https://${getResourceName()}/${eventName}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(args)
    })
    if (!res.ok) throw new Error(`HTTP error! Status: ${res.status}`)
    return await res.json()
  }
}

function getResourceName() {
  const match = window.location.href.match(/https?:\/\/(.*?)\//)
  return match ? match[1] : 'obelisk'
}

export default new Obelisk()
```

- [ ] **Step 3: Delete `useNui.js`**

Run: `rm web/src/composables/useNui.js`

- [ ] **Step 4: Migrate `Notifications.vue` to the new singleton and payload shape**

In `web/src/components/global/Notifications.vue`, replace:

```js
// Dismiss notification
const dismiss = (id) => {
  const index = notifications.value.findIndex(n => n.id === id)
  if (index !== -1) {
    notifications.value.splice(index, 1)
    
    // Notify client Lua
    if (window.invokeNative) {
      fetch(`https://${GetParentResourceName()}/core:client:notification-dismissed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id })
      })
    }
  }
}

// Listen for messages from Lua
onMounted(() => {
  window.addEventListener('message', (event) => {
    const data = event.data
    
    if (data.type === 'core:client:notification-show') {
      addNotification(data.notification)
    }
  })
})

// Helper to get resource name
function GetParentResourceName() {
  let currentUrl = window.location.href
  let match = currentUrl.match(/https?:\/\/(.*?)\//)
  return match ? match[1] : 'obelisk'
}
```

with:

```js
// Dismiss notification
const dismiss = (id) => {
  const index = notifications.value.findIndex(n => n.id === id)
  if (index !== -1) {
    notifications.value.splice(index, 1)
    Obelisk.emit('core:client:notification-dismissed', { id })
  }
}

// Listen for messages from Lua
onMounted(() => {
  Obelisk.on('core:client:notification-show', (notification) => {
    addNotification(notification)
  })
})
```

And add the import alongside the existing `ref`/`onMounted` import at the top of the `<script setup>` block:

```js
import Obelisk from '../../obelisk.js'
```

- [ ] **Step 5: Migrate `ProgressBars.vue` to the new singleton and payload shape**

In `web/src/components/global/ProgressBars.vue`, replace:

```js
// Complete progress bar
const complete = (progressId) => {
  const index = progressBars.value.findIndex(p => p.id === progressId)
  if (index !== -1) {
    progressBars.value.splice(index, 1)
    
    // Notify Lua
    if (window.invokeNative) {
      fetch(`https://${GetParentResourceName()}/core:client:progress-completed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ progressId })
      })
    }
  }
}

// Cancel progress bar
const cancel = (progressId) => {
  const index = progressBars.value.findIndex(p => p.id === progressId)
  if (index !== -1) {
    progressBars.value.splice(index, 1)
    
    // Notify Lua
    if (window.invokeNative) {
      fetch(`https://${GetParentResourceName()}/core:client:progress-userCancel`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ progressId })
      })
    }
  }
}
```

with:

```js
// Complete progress bar
const complete = (progressId) => {
  const index = progressBars.value.findIndex(p => p.id === progressId)
  if (index !== -1) {
    progressBars.value.splice(index, 1)
    Obelisk.emit('core:client:progress-completed', { progressId })
  }
}

// Cancel progress bar
const cancel = (progressId) => {
  const index = progressBars.value.findIndex(p => p.id === progressId)
  if (index !== -1) {
    progressBars.value.splice(index, 1)
    Obelisk.emit('core:client:progress-userCancel', { progressId })
  }
}
```

Replace:

```js
// Listen for messages from Lua
onMounted(() => {
  window.addEventListener('message', handleMessage)
  
  // Start update interval
  updateInterval = setInterval(updateProgress, 100)
})

onUnmounted(() => {
  window.removeEventListener('message', handleMessage)
  
  if (updateInterval) {
    clearInterval(updateInterval)
  }
})

const handleMessage = (event) => {
  const data = event.data
  
  if (data.type === 'core:client:progress-start') {
    addProgress(data.progress)
  } else if (data.type === 'core:client:progress-complete') {
    complete(data.progressId)
  } else if (data.type === 'core:client:progress-cancel') {
    const index = progressBars.value.findIndex(p => p.id === data.progressId)
    if (index !== -1) {
      progressBars.value.splice(index, 1)
    }
  }
}

// Helper to get resource name
function GetParentResourceName() {
  let currentUrl = window.location.href
  let match = currentUrl.match(/https?:\/\/(.*?)\//)
  return match ? match[1] : 'obelisk'
}
```

with:

```js
const handleCancel = (progressId) => {
  const index = progressBars.value.findIndex(p => p.id === progressId)
  if (index !== -1) {
    progressBars.value.splice(index, 1)
  }
}

// Listen for messages from Lua
onMounted(() => {
  Obelisk.on('core:client:progress-start', addProgress)
  Obelisk.on('core:client:progress-complete', complete)
  Obelisk.on('core:client:progress-cancel', handleCancel)

  // Start update interval
  updateInterval = setInterval(updateProgress, 100)
})

onUnmounted(() => {
  Obelisk.off('core:client:progress-start', addProgress)
  Obelisk.off('core:client:progress-complete', complete)
  Obelisk.off('core:client:progress-cancel', handleCancel)

  if (updateInterval) {
    clearInterval(updateInterval)
  }
})
```

And add the import:

```js
import Obelisk from '../../obelisk.js'
```

Note: `complete`/`cancel` above are still the plain progress-tracking functions the component already has, both now also directly usable as `Obelisk.on` callbacks since a `SendNUIMessage` with `args = { progressId }` calls the handler as `handler(progressId)`, matching `complete(progressId)`'s/`cancel`'s own signature. `handleCancel` is a new small local function (distinct from the exported `cancel`, which is the "user clicked cancel" action that also notifies Lua) — needed because the old inline branch for `'progress:cancel'` only removed the bar locally, it never called the existing `cancel` function (which would incorrectly re-notify Lua about a cancellation Lua itself just told the UI about).

- [ ] **Step 6: Manual verification**

Run:
```js
node -e "
const { parse } = require('@vue/compiler-sfc');
const fs = require('fs');
for (const f of ['web/src/components/global/Notifications.vue', 'web/src/components/global/ProgressBars.vue']) {
  const { errors } = parse(fs.readFileSync(f, 'utf8'), { filename: f });
  console.log(f, errors.length ? errors : 'OK');
}
"
```
Expected: `OK` for both.

Run: `node --check web/src/obelisk.js` — expected: no output (valid syntax).

Run: `cd web && npm run build` (or `npx vite build` if the pre-existing unrelated `NativeMenu.vue` case-sensitivity build error from this repo's `main` branch is still present — that failure is not caused by this task; if it blocks the full build, fall back to the two checks above plus a manual read-through).

Run: `lua5.4 -e "assert(loadfile('core/client/Services/NotificationService.lua'))"` and the same for `ProgressService.lua` — both must parse.

Run: `grep -rn "useNui" web/src` from the `core` directory — expected: no output (nothing still imports the deleted file).

- [ ] **Step 7: Commit**

```bash
cd core
git add core/client/Services/NotificationService.lua core/client/Services/ProgressService.lua web/src/obelisk.js web/src/components/global/Notifications.vue web/src/components/global/ProgressBars.vue
git rm web/src/composables/useNui.js
git commit -m "feat(web): add Obelisk JS singleton, switch NUI payloads to {eventname, args}, retire useNui.js"
```

---

## Task 5: Global elements registry

**Files:**
- Create: `web/src/globalElements.js`
- Modify: `web/src/App.vue`

**Interfaces:**
- Consumes: `Obelisk` singleton (Task 4), the `core:client:webview-*` NUI message names client `WebView.lua` sends (Task 2).
- Produces: a plugin-facing convention — `plugins/<name>/web/globalElements.js` exporting a default array of `{name, component, defaultVisible}`, globbed the same way `plugins/*/web/routes.js` already is in `web/src/router/index.js`.

- [ ] **Step 1: Create core's own global-elements list**

Create `web/src/globalElements.js`:

```js
import Notifications from './components/global/Notifications.vue'
import ProgressBars from './components/global/ProgressBars.vue'

export default [
  { name: 'notifications', component: Notifications, defaultVisible: true },
  { name: 'progressBars', component: ProgressBars, defaultVisible: true }
]
```

- [ ] **Step 2: Rebuild `App.vue` around the registry**

Replace the full contents of `web/src/App.vue` with:

```vue
<template>
  <div id="app" class="relative">
    <component
      v-for="[name, entry] in registry"
      :key="name"
      :is="entry.component"
      v-show="entry.visible"
    />
    <router-view />
  </div>
</template>

<script setup>
import { reactive, onMounted } from 'vue'
import router from './router'
import Obelisk from './obelisk.js'
import coreGlobalElements from './globalElements.js'

const pluginGlobalElementModules = import.meta.glob('../../plugins/*/web/globalElements.js', { eager: true })

const pluginGlobalElements = []
for (const mod of Object.values(pluginGlobalElementModules)) {
  if (Array.isArray(mod.default)) {
    pluginGlobalElements.push(...mod.default)
  } else {
    console.warn('[Obelisk] a plugin globalElements.js did not export a default array, skipping')
  }
}

const registry = reactive(new Map())
for (const entry of [...coreGlobalElements, ...pluginGlobalElements]) {
  if (!entry || !entry.name || !entry.component) {
    console.warn('[Obelisk] a global element entry is missing name/component, skipping', entry)
    continue
  }
  registry.set(entry.name, { component: entry.component, visible: !!entry.defaultVisible })
}

onMounted(() => {
  Obelisk.on('core:client:navigate', (route) => {
    router.push(route)
  })

  Obelisk.on('core:client:webview-openPage', (page) => {
    router.push(page)
  })

  Obelisk.on('core:client:webview-showGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = true
  })

  Obelisk.on('core:client:webview-hideGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = false
  })

  Obelisk.on('core:client:webview-toggleGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = !entry.visible
  })

  Obelisk.on('core:client:webview-destroy', () => {
    for (const entry of registry.values()) entry.visible = false
  })
})
</script>

<style>
/* Global styles */
#app {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
</style>
```

Note the `import.meta.glob` path here is `'../../plugins/*/web/globalElements.js'` (two `../`, from `web/src/`), matching the two-levels-up-then-into-`plugins/` path `web/src/router/index.js` already uses for `routes.js` (`'../../../plugins/*/web/routes.js'`, three `../` because that file lives one directory deeper, at `web/src/router/`) — verify the exact relative depth against the current `router/index.js` glob before finalizing, since a wrong depth silently globs zero files instead of erroring.

- [ ] **Step 3: Manual verification**

Run the `@vue/compiler-sfc` parse check (same command shape as Task 4 Step 6) against `web/src/App.vue` — expected: `OK`.

Run: `cd web && npm run build` (same caveat about the pre-existing unrelated build error as Task 4).

Read `web/src/router/index.js` once more and confirm the glob-path depth reasoning above actually matches; fix `globalElements.js`'s glob path in `App.vue` if it doesn't.

- [ ] **Step 4: Commit**

```bash
cd core
git add web/src/globalElements.js web/src/App.vue
git commit -m "feat(web): add plugin-extensible global-elements registry, replacing hardcoded App.vue mounts"
```

---

## Task 6: Migrate existing services to the `Obelisk` wrapper

**Files:**
- Modify: `core/server/Services/NotificationService.lua`
- Modify: `core/client/Services/NotificationService.lua`
- Modify: `core/server/Services/ProgressService.lua`
- Modify: `core/client/Services/ProgressService.lua`
- Modify: `core/server/Services/InteractionService.lua`
- Modify: `core/client/Services/InteractionService.lua`
- Modify: `core/client/actions/UseInteraction.lua`
- Modify: `core/server/Services/EntityStreamerService.lua`
- Modify: `core/client/Services/EntityStreamerService.lua`
- Modify: `core/server/Services/KeybindService.lua`
- Modify: `core/client/Services/KeybindService.lua`
- Modify: `core/server/Services/ActionService.lua`
- Modify: `core/client/bootstrap.lua`

**Interfaces:**
- Consumes: `Obelisk.emit/on/emitServer/emitClient/onServer/onClient` (Task 1). No new interfaces produced — this task only changes how existing services call the network, not their public API.

This task is purely mechanical: every `RegisterNetEvent(name)` + `AddEventHandler(name, fn)` pair becomes a single `Obelisk.onServer(name, fn)` (if the handler is on the server, receiving something a client sent) or `Obelisk.onClient(name, fn)` (if the handler is on the client, receiving something the server sent); every `TriggerClientEvent(name, target, ...)` becomes `Obelisk.emitClient(name, target, ...)`; every `TriggerServerEvent(name, ...)` becomes `Obelisk.emitServer(name, ...)`.

- [ ] **Step 1: `core/server/Services/NotificationService.lua`**

Change:
```lua
    TriggerClientEvent('core:server:notification-show', target, notification)
```
to:
```lua
    Obelisk.emitClient('core:server:notification-show', target, notification)
```

Change:
```lua
RegisterNetEvent('core:client:notification-show')
AddEventHandler('core:client:notification-show', function(data)
    local source = source
    -- Client is allowed to trigger notifications for themselves
    NotificationService.notify(source, data)
end)
```
to:
```lua
Obelisk.onServer('core:client:notification-show', function(data)
    local source = source
    -- Client is allowed to trigger notifications for themselves
    NotificationService.notify(source, data)
end)
```

- [ ] **Step 2: `core/client/Services/NotificationService.lua`**

Change:
```lua
RegisterNetEvent('core:server:notification-show')
AddEventHandler('core:server:notification-show', function(notification)
    NotificationService.show(notification)
end)
```
to:
```lua
Obelisk.onClient('core:server:notification-show', function(notification)
    NotificationService.show(notification)
end)
```

- [ ] **Step 3: `core/server/Services/ProgressService.lua`**

Change each `TriggerClientEvent('core:server:progress-<x>', target, ...)` (three call sites: `start`, `complete`, `cancel`) to `Obelisk.emitClient('core:server:progress-<x>', target, ...)`, same arguments.

Change:
```lua
RegisterNetEvent('core:client:progress-complete')
AddEventHandler('core:client:progress-complete', function(progressId)
```
to:
```lua
Obelisk.onServer('core:client:progress-complete', function(progressId)
```

Change:
```lua
RegisterNetEvent('core:client:progress-cancel')
AddEventHandler('core:client:progress-cancel', function(progressId)
```
to:
```lua
Obelisk.onServer('core:client:progress-cancel', function(progressId)
```

- [ ] **Step 4: `core/client/Services/ProgressService.lua`**

Change each `RegisterNetEvent('core:server:progress-<x>')` + `AddEventHandler('core:server:progress-<x>', function(...)` pair (three: `start`, `complete`, `cancel`) to a single `Obelisk.onClient('core:server:progress-<x>', function(...)`, same body.

Change:
```lua
        TriggerServerEvent('core:client:progress-cancel', progressId)
```
to:
```lua
        Obelisk.emitServer('core:client:progress-cancel', progressId)
```

Change:
```lua
        TriggerServerEvent('core:client:progress-complete', progressId)
```
to:
```lua
        Obelisk.emitServer('core:client:progress-complete', progressId)
```

- [ ] **Step 5: `core/server/Services/InteractionService.lua`**

Change each of the four `TriggerClientEvent('core:server:interaction-<x>', -1 or source, ...)` call sites (`add`, `remove`, `update` ×2, `syncAll`) to `Obelisk.emitClient(...)`, same arguments.

Change:
```lua
RegisterNetEvent('core:client:interaction-use')
AddEventHandler('core:client:interaction-use', function(interactionId)
```
to:
```lua
Obelisk.onServer('core:client:interaction-use', function(interactionId)
```

Change:
```lua
RegisterNetEvent('core:client:interaction-requestAll')
AddEventHandler('core:client:interaction-requestAll', function()
```
to:
```lua
Obelisk.onServer('core:client:interaction-requestAll', function()
```

- [ ] **Step 6: `core/client/Services/InteractionService.lua`**

Change each of the four `RegisterNetEvent`+`AddEventHandler` pairs (`syncAll`, `add`, `remove`, `update`) to a single `Obelisk.onClient(...)` each, same bodies.

Change:
```lua
        TriggerServerEvent('core:client:interaction-use', InteractionService.closestInteraction.id)
```
to:
```lua
        Obelisk.emitServer('core:client:interaction-use', InteractionService.closestInteraction.id)
```

Change:
```lua
    TriggerServerEvent('core:client:interaction-requestAll')
```
to:
```lua
    Obelisk.emitServer('core:client:interaction-requestAll')
```

- [ ] **Step 7: `core/client/actions/UseInteraction.lua`**

Change:
```lua
        TriggerServerEvent('core:client:interaction-use', InteractionService.closestInteraction.id)
```
to:
```lua
        Obelisk.emitServer('core:client:interaction-use', InteractionService.closestInteraction.id)
```

- [ ] **Step 8: `core/server/Services/EntityStreamerService.lua`**

Change the two direct `TriggerClientEvent('core:server:streamer-<x>', source, ...)` call sites (inside `loadChunkForPlayer`/`unloadChunkForPlayer`, for `entityAdd`/`entityRemove`) to `Obelisk.emitClient(...)`, same arguments.

Change the generic relay inside `broadcastToChunk`:
```lua
function EntityStreamerService.broadcastToChunk(chunkKey, eventName, data)
    for playerId, playerData in pairs(EntityStreamerService.playerChunks) do
        for _, activeChunk in ipairs(playerData.activeChunks) do
            if activeChunk == chunkKey then
                TriggerClientEvent(eventName, playerId, data)
                break
            end
        end
    end
end
```
to:
```lua
function EntityStreamerService.broadcastToChunk(chunkKey, eventName, data)
    for playerId, playerData in pairs(EntityStreamerService.playerChunks) do
        for _, activeChunk in ipairs(playerData.activeChunks) do
            if activeChunk == chunkKey then
                Obelisk.emitClient(eventName, playerId, data)
                break
            end
        end
    end
end
```

Change:
```lua
RegisterNetEvent('core:client:streamer-updatePosition')
AddEventHandler('core:client:streamer-updatePosition', function(x, y)
```
to:
```lua
Obelisk.onServer('core:client:streamer-updatePosition', function(x, y)
```

Change:
```lua
RegisterNetEvent('core:client:streamer-requestChunk')
AddEventHandler('core:client:streamer-requestChunk', function(chunkKey)
```
to:
```lua
Obelisk.onServer('core:client:streamer-requestChunk', function(chunkKey)
```

- [ ] **Step 9: `core/client/Services/EntityStreamerService.lua`**

Change the two `RegisterNetEvent`+`AddEventHandler` pairs (`entityAdd`, `entityRemove`) to a single `Obelisk.onClient(...)` each, same bodies.

Change:
```lua
        TriggerServerEvent('core:client:streamer-updatePosition', coords.x, coords.y)
```
to:
```lua
        Obelisk.emitServer('core:client:streamer-updatePosition', coords.x, coords.y)
```

- [ ] **Step 10: `core/server/Services/KeybindService.lua`**

Change:
```lua
        TriggerClientEvent('core:server:keybinds-sync', source, keybinds)
```
to:
```lua
        Obelisk.emitClient('core:server:keybinds-sync', source, keybinds)
```

Change each of the three `TriggerClientEvent('core:server:keybinds-requestSync', -1)` call sites (in `registerGlobal`, `update`, `delete`) to `Obelisk.emitClient('core:server:keybinds-requestSync', -1)`.

Change:
```lua
RegisterNetEvent('core:client:keybinds-requestSync')
AddEventHandler('core:client:keybinds-requestSync', function()
```
to:
```lua
Obelisk.onServer('core:client:keybinds-requestSync', function()
```

Change:
```lua
RegisterNetEvent('core:client:keybinds-pressed')
AddEventHandler('core:client:keybinds-pressed', function(actionId, keybindData)
```
to:
```lua
Obelisk.onServer('core:client:keybinds-pressed', function(actionId, keybindData)
```

- [ ] **Step 11: `core/client/Services/KeybindService.lua`**

Change:
```lua
RegisterNetEvent('core:server:keybinds-sync')
AddEventHandler('core:server:keybinds-sync', function(keybinds)
```
to:
```lua
Obelisk.onClient('core:server:keybinds-sync', function(keybinds)
```

Change:
```lua
    TriggerServerEvent('core:client:keybinds-requestSync')
```
to:
```lua
    Obelisk.emitServer('core:client:keybinds-requestSync')
```

Change:
```lua
            TriggerServerEvent('core:client:keybinds-pressed', keybind.action_id, data or {})
```
to:
```lua
            Obelisk.emitServer('core:client:keybinds-pressed', keybind.action_id, data or {})
```

- [ ] **Step 12: `core/server/Services/ActionService.lua`**

Change:
```lua
RegisterNetEvent('core:client:action-execute')
AddEventHandler('core:client:action-execute', function(actionId, data)
```
to:
```lua
Obelisk.onServer('core:client:action-execute', function(actionId, data)
```

- [ ] **Step 13: `core/client/bootstrap.lua`**

Change:
```lua
    TriggerServerEvent('core:client:ready')
```
to:
```lua
    Obelisk.emitServer('core:client:ready')
```

- [ ] **Step 14: Manual verification**

Run a syntax check on every file touched in this task:

```bash
for f in core/server/Services/NotificationService.lua core/client/Services/NotificationService.lua \
         core/server/Services/ProgressService.lua core/client/Services/ProgressService.lua \
         core/server/Services/InteractionService.lua core/client/Services/InteractionService.lua \
         core/client/actions/UseInteraction.lua \
         core/server/Services/EntityStreamerService.lua core/client/Services/EntityStreamerService.lua \
         core/server/Services/KeybindService.lua core/client/Services/KeybindService.lua \
         core/server/Services/ActionService.lua core/client/bootstrap.lua; do
  lua5.4 -e "assert(loadfile('$f'))" && echo "OK: $f" || echo "FAIL: $f"
done
```
Expected: `OK` for all thirteen.

Run: `grep -rn "RegisterNetEvent\|TriggerServerEvent\|TriggerClientEvent" core/server/Services core/client/Services core/client/actions core/client/bootstrap.lua` from the `core` directory and confirm the only remaining raw-native call sites are: `core/shared/Obelisk.lua` itself (expected, it's the wrapper), and nothing else — every service-level call site should now read `Obelisk.emit*`/`Obelisk.on*`.

Run: `npm test` — expected: unaffected, all green (`RegisterNetEvent`/`TriggerEvent`-adjacent logic isn't covered by `orm_spec.lua`/`obelisk_spec.lua`; this is a regression guard for the ORM/Obelisk suites, not new coverage for this task).

- [ ] **Step 15: Commit**

```bash
cd core
git add core/server/Services/NotificationService.lua core/client/Services/NotificationService.lua \
        core/server/Services/ProgressService.lua core/client/Services/ProgressService.lua \
        core/server/Services/InteractionService.lua core/client/Services/InteractionService.lua \
        core/client/actions/UseInteraction.lua \
        core/server/Services/EntityStreamerService.lua core/client/Services/EntityStreamerService.lua \
        core/server/Services/KeybindService.lua core/client/Services/KeybindService.lua \
        core/server/Services/ActionService.lua core/client/bootstrap.lua
git commit -m "refactor: migrate existing services from raw net-event natives to the Obelisk wrapper"
```
