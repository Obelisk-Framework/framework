# Player / Obelisk Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `Obelisk.onServer`/`onClient`/`emitClient` so the name matches "who sent this event" instead of "which side runs the code", fix a latent `RegisterNetEvent` misuse, and introduce a `PlayerService` registry whose `Player` object fully replaces raw numeric `source` across every server-side function in core and every plugin.

**Architecture:** `core/shared/Obelisk.lua`'s server branch gets `onClient`/`emitClient` (renamed from `onServer`/`emitClient`), where `onClient` resolves `source` to a `Player` via a new `PlayerService` registry (populated on `playerJoining`, cleared on `playerDropped`) before invoking the handler. Every downstream function that received a raw `source` now receives that `Player` instead, calling `player:getSource()` only at the exact point a native or DB column needs the number. This is a pure mechanical rename+propagation across ~30 files — no behavior changes beyond the bug fix.

**Tech Stack:** Lua 5.4 (FXServer runtime), the repo's custom `lua5.4 tests/*_spec.lua` unit test runner (not busted — see `tests/obelisk_spec.lua` for the pattern), `core/tests/support/fivem_stubs.lua` for FiveM global stubs.

**Spec:** `core/docs/superpowers/specs/2026-08-15-player-obelisk-foundation-design.md`

## Global Constraints

- **Naming (spec Design > Obelisk.lua):** server-side `Obelisk.on` unchanged (same-side/global events). Server-side `Obelisk.onServer`→`Obelisk.onClient` (handler for a client-sent event, now receives `player` as its first argument). Server-side `Obelisk.emitClient(event, player, ...)` keeps its name but now takes a `Player`, not a number. Client-side `Obelisk.onClient`→`Obelisk.onServer` (handler for a server-sent event, callback signature unchanged — client has no Player concept). `Obelisk.emit`/`Obelisk.emitServer` unchanged on both sides.
- **`RegisterNetEvent` fix (spec Goal 2):** every net-event registration is `RegisterNetEvent(eventName)` followed by a *separate* `AddEventHandler(eventName, handler)` call — never pass a function as `RegisterNetEvent`'s second argument.
- **`source` → `player` propagation (spec Design > propagation):** every server-side function that currently takes a raw `source` takes `player` instead. Call `player:getSource()` only at the exact point a native call or a numeric-keyed internal table genuinely needs the number — never thread a bare number through application code otherwise.
- **`AddEventHandler` sweep (spec Design > sweep):** raw `AddEventHandler` for same-side/global engine events (`playerJoining`, `playerConnecting`, `playerDropped`, `onResourceStop`) converts to `Obelisk.on`.
- **Test runner (spec Design > testing):** every spec file is run individually: `lua5.4 tests/<name>_spec.lua` from the `core/` directory. There is no test framework auto-discovery — each task's test step names its exact command.
- **Out of scope (spec Non-goals):** `player.account`, `player.character`, and `oblsk_character-selection`'s web/UI layer are separate follow-up specs. Do not touch them here.

---

## Conversion Pattern (applies to every plugin/service task below)

This is the exact mechanical transformation every task in Phases 3–5 applies. It is demonstrated here in full against `plugins/oblsk_tattoo/server/main.lua` (Task 14 uses this same code) so every later task can say "apply the Conversion Pattern" instead of repeating it.

**Before:**
```lua
Obelisk.onServer('tattoo:client:apply', function(shopId, designId, inkHex, quality, grade, method, cardId)
    local source = source
    local sanitized = sanitizeHex(inkHex)
    if not sanitized then
        Obelisk.emitClient('tattoo:server:applyResult', source, { ok = false, reason = sanitized })
        return
    end
    local ok, result = pcall(TattooService.apply, source, shopId, designId, sanitized, quality, grade, method, cardId)
    if ok then
        Obelisk.emitClient('tattoo:server:applyResult', source, { ok = true, zone = result.zone, designName = result.designName, pricePaid = result.pricePaid })
    else
        Obelisk.emitClient('tattoo:server:applyResult', source, { ok = false, reason = result })
    end
end)
```

**After:**
```lua
Obelisk.onClient('tattoo:client:apply', function(player, shopId, designId, inkHex, quality, grade, method, cardId)
    local sanitized = sanitizeHex(inkHex)
    if not sanitized then
        player:emit('tattoo:server:applyResult', { ok = false, reason = sanitized })
        return
    end
    local ok, result = pcall(TattooService.apply, player, shopId, designId, sanitized, quality, grade, method, cardId)
    if ok then
        player:emit('tattoo:server:applyResult', { ok = true, zone = result.zone, designName = result.designName, pricePaid = result.pricePaid })
    else
        player:emit('tattoo:server:applyResult', { ok = false, reason = result })
    end
end)
```

Rules, applied identically everywhere:
1. `Obelisk.onServer(event, function(...)` → `Obelisk.onClient(event, function(player, ...)` — `player` is always the new first parameter.
2. Delete every `local source = source` line inside a converted handler — `player` is already in scope.
3. `Obelisk.emitClient(event, source, ...)` → `player:emit(event, ...)` when `player` is the recipient in scope. When the recipient is a *different* connection's source (e.g. `session.customerSource`, `call.calleeSource`, a `targetSource` looked up from another table), replace it with `PlayerService.get(thatSource):emit(event, ...)` — do not call `player:emit` for someone else's player.
3a. `Obelisk.emitClient('event', -1, ...)` (broadcast to all clients, e.g. `oblsk_tuner`'s `applyTuning`) is unchanged — `-1` is not a source, it stays a raw literal; `Obelisk.emitClient`'s second parameter accepts either a `Player` or the literal `-1` for broadcast (note this one exception in `PlayerService`/`Obelisk.lua`'s doc comment).
4. `WebView.<method>(source, ...)` / `WebView.emitClient(source, ...)` → `WebView.<method>(player, ...)` — `WebView`'s server relay (Task 4) takes `player` now, same substitution rule as #3.
5. `ActionService.register(name, function(source, data) ... end, ...)` → `function(player, data) ... end` — `ActionService.execute`'s signature changes in Task 6, so every registered handler across every plugin follows this same substitution.
6. Any plugin service function (e.g. `TattooService.apply(source, ...)`) that receives what was `source` from a converted call site takes `player` in its own signature too — propagate through, don't stop at the handler boundary.
7. Where a native call or DB/table lookup genuinely needs the number (`GetPlayerPed(player:getSource())`, a `[source]`-keyed internal table), call `player:getSource()` at that exact point.

**Verification, identical for every task:** after editing, re-run the enumeration grep given in the task — it must return **zero** matches for `Obelisk.onServer(`, `local source = source`, and `WebView\.\w+\(source` (or `\(target`) within that file; the count of `Obelisk.onClient(` additions must equal the original `Obelisk.onServer(` count. Then run `lua5.4 -e "assert(loadfile('<file>'))"` from `core/` to confirm the file still parses (these files use FXServer globals like `GetPlayerPed` that aren't defined outside the game, so this only proves syntax, not runtime — that's sufficient for files with no existing spec).

---

## Phase 1 — Obelisk.lua rename and PlayerService

### Task 1: Rewrite `Obelisk.lua` — rename + `RegisterNetEvent` fix

**Files:**
- Modify: `core/shared/Obelisk.lua`
- Test: `tests/obelisk_spec.lua`

**Interfaces:**
- Produces: `Obelisk.on(eventName, callback)` (unchanged), `Obelisk.emit(eventName, ...)` (unchanged), server: `Obelisk.onClient(eventName, callback)` where `callback` receives `(player, ...)`, `Obelisk.emitClient(eventName, player, ...)`, `Obelisk.emitServer()`/`Obelisk.onServer()` (server-side, both error stubs), client: `Obelisk.onServer(eventName, callback)` where `callback` receives `(...)` unchanged, `Obelisk.emitServer(eventName, ...)` (unchanged), `Obelisk.emitClient()`/`Obelisk.onClient()` (client-side, both error stubs).
- Consumes (server branch only): `PlayerService.get(source)` — added in Task 2. Since Task 2 doesn't exist yet when this task runs, `Obelisk.onClient`'s body references the global `PlayerService`, which is fine in Lua (resolved at call time, not load time) — but this task's test step below stubs `PlayerService` itself so it doesn't need Task 2 to be done first.

- [ ] **Step 1: Write the failing tests for the renamed API**

Replace `tests/obelisk_spec.lua` entirely with:

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

local function fakePlayer(source)
    return {
        source = source,
        getSource = function(self) return self.source end,
    }
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

test('on: AddEventHandler locally, works on either side', function()
    local handlerName
    _G.AddEventHandler = function(name, _) handlerName = name end
    local Obelisk = loadObeliskAs(false)
    Obelisk.on('foo:bar', function() end)
    eq(handlerName, 'foo:bar')
end)

test('server: emitClient calls TriggerClientEvent with player:getSource()', function()
    local captured
    _G.TriggerClientEvent = function(name, target, ...) captured = {name, target, ...} end
    local Obelisk = loadObeliskAs(true)
    Obelisk.emitClient('foo:bar', fakePlayer(5), 'x')
    eq(captured[1], 'foo:bar')
    eq(captured[2], 5)
    eq(captured[3], 'x')
end)

test('server: onClient registers via RegisterNetEvent AND AddEventHandler separately', function()
    local registered, handlerName, handlerFn
    _G.RegisterNetEvent = function(name) registered = name end
    _G.AddEventHandler = function(name, fn) handlerName = name; handlerFn = fn end
    local Obelisk = loadObeliskAs(true)
    Obelisk.onClient('foo:bar', function() end)
    eq(registered, 'foo:bar')
    eq(handlerName, 'foo:bar')
    truthy(type(handlerFn) == 'function', 'AddEventHandler must receive a function, not be passed to RegisterNetEvent')
end)

test('server: onClient resolves source to a Player and passes it as the first callback arg', function()
    local capturedHandler
    _G.RegisterNetEvent = function() end
    _G.AddEventHandler = function(_, fn) capturedHandler = fn end
    _G.source = 42
    _G.PlayerService = { get = function(src) eq(src, 42); return fakePlayer(src) end }
    local Obelisk = loadObeliskAs(true)
    local receivedPlayer, receivedArg
    Obelisk.onClient('foo:bar', function(player, arg) receivedPlayer = player; receivedArg = arg end)
    capturedHandler('hello')
    eq(receivedPlayer:getSource(), 42)
    eq(receivedArg, 'hello')
    _G.source = nil
end)

test('server: onClient drops the event (does not call the handler) when PlayerService has no Player yet', function()
    local capturedHandler
    _G.RegisterNetEvent = function() end
    _G.AddEventHandler = function(_, fn) capturedHandler = fn end
    _G.source = 99
    _G.PlayerService = { get = function() return nil end }
    local Obelisk = loadObeliskAs(true)
    local called = false
    Obelisk.onClient('foo:bar', function() called = true end)
    capturedHandler()
    truthy(not called, 'handler must not run when PlayerService.get returns nil')
    _G.source = nil
end)

test('server: emitServer throws', function()
    local Obelisk = loadObeliskAs(true)
    local ok, err = pcall(Obelisk.emitServer, 'foo:bar')
    truthy(not ok, 'expected an error')
    truthy(tostring(err):find('can only be called from the client', 1, true),
        'error message mentions client: ' .. tostring(err))
end)

test('server: onServer throws', function()
    local Obelisk = loadObeliskAs(true)
    local ok = pcall(Obelisk.onServer, 'foo:bar', function() end)
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

test('client: onServer registers via RegisterNetEvent AND AddEventHandler separately', function()
    local registered, handlerName, handlerFn
    _G.RegisterNetEvent = function(name) registered = name end
    _G.AddEventHandler = function(name, fn) handlerName = name; handlerFn = fn end
    local Obelisk = loadObeliskAs(false)
    Obelisk.onServer('foo:bar', function() end)
    eq(registered, 'foo:bar')
    eq(handlerName, 'foo:bar')
    truthy(type(handlerFn) == 'function')
end)

test('client: emitClient throws', function()
    local Obelisk = loadObeliskAs(false)
    local ok, err = pcall(Obelisk.emitClient, 'foo:bar', 5)
    truthy(not ok, 'expected an error')
    truthy(tostring(err):find('can only be called from the server', 1, true),
        'error message mentions server: ' .. tostring(err))
end)

test('client: onClient throws', function()
    local Obelisk = loadObeliskAs(false)
    local ok = pcall(Obelisk.onClient, 'foo:bar', function() end)
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

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `core/`): `lua5.4 tests/obelisk_spec.lua`
Expected: several FAILs — `Obelisk.onClient`/`emitClient` don't exist yet under the new contract (the file still has the old `onServer`/`onClient` names).

- [ ] **Step 3: Rewrite `core/shared/Obelisk.lua`**

```lua
--- Obelisk - shared event wrapper around FXServer's native event primitives.
--- Loaded on both server and client (covered by fxmanifest.lua's
--- 'core/shared/**/*.lua' shared_scripts glob, no manifest change needed).
--- Every method takes the full event name string; nothing here auto-namespaces.
---
--- Naming: onX / emitX names the event's ORIGIN side, and the function itself
--- lives on the OTHER side. emitClient sends to a client (called from the
--- server); onClient handles something a client sent (registered on the
--- server). emitServer sends to the server (called from the client);
--- onServer handles something the server sent (registered on the client).
Obelisk = {}

local isServer = IsDuplicityVersion()

--- Trigger a local, same-side event (no networking).
--- @param eventName string
function Obelisk.emit(eventName, ...)
    TriggerEvent(eventName, ...)
end

--- Register a handler for a local, same-side event (or a global engine event
--- like playerJoining/playerConnecting/onResourceStop).
--- @param eventName string
--- @param callback function
function Obelisk.on(eventName, callback)
    AddEventHandler(eventName, callback)
end

if isServer then
    --- Send an event to one client. Server only.
    --- @param eventName string
    --- @param player Player|number the recipient, or the literal -1 to broadcast to all clients
    function Obelisk.emitClient(eventName, player, ...)
        local target = player == -1 and -1 or player:getSource()
        TriggerClientEvent(eventName, target, ...)
    end

    --- Register a handler for an event a client sent via Obelisk.emitServer.
    --- The handler receives the resolved Player as its first argument, not a
    --- raw source. If PlayerService has no Player for this connection yet
    --- (only possible in the brief window before playerJoining fires, which
    --- no net event can reach), the event is dropped and logged rather than
    --- calling the handler with nil. Server only.
    --- @param eventName string
    --- @param callback function(player, ...)
    function Obelisk.onClient(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, function(...)
            local player = PlayerService.get(source)
            if not player then
                print('[Obelisk] dropped ' .. eventName .. ': no Player for source ' .. tostring(source))
                return
            end
            callback(player, ...)
        end)
    end

    function Obelisk.emitServer()
        error('Obelisk.emitServer can only be called from the client', 2)
    end

    function Obelisk.onServer()
        error('Obelisk.onServer can only be called from the client', 2)
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
    function Obelisk.onServer(eventName, callback)
        RegisterNetEvent(eventName)
        AddEventHandler(eventName, callback)
    end

    function Obelisk.emitClient()
        error('Obelisk.emitClient can only be called from the server', 2)
    end

    function Obelisk.onClient()
        error('Obelisk.onClient can only be called from the server', 2)
    end
end

return Obelisk
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua5.4 tests/obelisk_spec.lua`
Expected: `12 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add core/shared/Obelisk.lua tests/obelisk_spec.lua
git commit -m "refactor(core): rename Obelisk on/emit to match event origin, fix RegisterNetEvent misuse"
```

---

### Task 2: `PlayerService` — registry, lifecycle, `Player` methods

**Files:**
- Create: `core/server/Services/PlayerService.lua`
- Modify: `tests/support/fivem_stubs.lua` (add `GetPlayerName`, `GetPlayerIdentifierByType` stubs)
- Test: `tests/player_service_spec.lua`

**Interfaces:**
- Consumes: `Obelisk.on` (Task 1). `NotificationService.notify(source, data)` — exists today at `core/server/Services/NotificationService.lua`, converted to take `player` in Task 8, but `Player:notify` just forwards whatever `NotificationService.notify` currently expects as its first arg, so this task is written against the *post-Task-8* signature (`NotificationService.notify(player, data)`) — order these tasks as Task 2 before Task 8 is fine since `Player:notify` only calls it at runtime, not load time. `Obelisk.emitClient(event, player, ...)` (Task 1) for `Player:emit`.
- Produces: `PlayerService.registry` (table, source→Player, not part of the public contract but referenced by tests), `PlayerService.get(source)` → `Player|nil`, `Player:getSource()`, `Player:getIdentifier(type)`, `Player:getName()`, `Player:notify(data)`, `Player:emit(event, ...)`.

- [ ] **Step 1: Add the two missing FiveM stubs**

In `tests/support/fivem_stubs.lua`, add near the other `GetPlayer*` stubs (after line 22's `IsDuplicityVersion` stub):

```lua
_G.GetPlayerName = _G.GetPlayerName or function(source) return 'Player' .. tostring(source) end
_G.GetPlayerIdentifierByType = _G.GetPlayerIdentifierByType or function(source, idType)
    return idType .. ':fake-' .. tostring(source)
end
```

- [ ] **Step 2: Write the failing test**

Create `tests/player_service_spec.lua`:

```lua
--- Unit tests for core/server/Services/PlayerService.lua.
--- Run from the repository root:  lua5.4 tests/player_service_spec.lua

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

local function freshPlayerService()
    _G.IsDuplicityVersion = function() return true end
    _G.Obelisk = nil
    _G.PlayerService = nil
    dofile(ROOT .. '/core/shared/Obelisk.lua')
    -- capture the two Obelisk.on registrations PlayerService installs
    local handlers = {}
    local realOn = Obelisk.on
    Obelisk.on = function(name, fn) handlers[name] = fn; realOn(name, fn) end
    dofile(ROOT .. '/core/server/Services/PlayerService.lua')
    return PlayerService, handlers
end

test('get: returns nil before playerJoining fires', function()
    local PlayerService = freshPlayerService()
    eq(PlayerService.get(7), nil)
end)

test('playerJoining: creates a Player with source, name, identifiers', function()
    local PlayerService, handlers = freshPlayerService()
    _G.source = 7
    handlers['playerJoining']()
    _G.source = nil

    local player = PlayerService.get(7)
    truthy(player ~= nil, 'expected a Player to exist after playerJoining')
    eq(player:getSource(), 7)
    eq(player:getName(), 'Player7')
    eq(player:getIdentifier('license'), 'license:fake-7')
end)

test('playerDropped: removes the Player', function()
    local PlayerService, handlers = freshPlayerService()
    _G.source = 7
    handlers['playerJoining']()
    handlers['playerDropped']()
    _G.source = nil

    eq(PlayerService.get(7), nil)
end)

test('Player:emit forwards to Obelisk.emitClient with self as the player', function()
    local PlayerService, handlers = freshPlayerService()
    _G.source = 3
    handlers['playerJoining']()
    _G.source = nil

    local captured
    _G.TriggerClientEvent = function(name, target, ...) captured = {name, target, ...} end
    local player = PlayerService.get(3)
    player:emit('foo:bar', 'x')
    eq(captured[1], 'foo:bar')
    eq(captured[2], 3)
    eq(captured[3], 'x')
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running PlayerService unit tests\n')
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

- [ ] **Step 3: Run the test to verify it fails**

Run: `lua5.4 tests/player_service_spec.lua`
Expected: FAIL — `core/server/Services/PlayerService.lua` doesn't exist yet.

- [ ] **Step 4: Write `PlayerService.lua`**

```lua
--- PlayerService - server-side registry of Player objects, one per connected
--- source, keyed by source, created on playerJoining and removed on
--- playerDropped. See docs/superpowers/specs/2026-08-15-player-obelisk-foundation-design.md.
PlayerService = {}
PlayerService.registry = {} -- source(number) -> Player

local Player = {}
Player.__index = Player

local IDENTIFIER_TYPES = { 'license', 'discord', 'steam', 'fivem', 'ip' }

function Player.new(source)
    local identifiers = {}
    for _, t in ipairs(IDENTIFIER_TYPES) do
        identifiers[t] = GetPlayerIdentifierByType(source, t)
    end
    return setmetatable({
        source = source,
        name = GetPlayerName(source),
        identifiers = identifiers,
        account = nil,   -- set by the Account-link follow-up spec
        character = nil, -- set by the Character-link follow-up spec
    }, Player)
end

--- @return number the raw FXServer connection id
function Player:getSource()
    return self.source
end

--- @param identifierType string one of 'license', 'discord', 'steam', 'fivem', 'ip'
--- @return string|nil
function Player:getIdentifier(identifierType)
    return self.identifiers[identifierType]
end

--- @return string
function Player:getName()
    return self.name
end

--- @param data table notification payload, see NotificationService
function Player:notify(data)
    NotificationService.notify(self, data)
end

--- @param event string
function Player:emit(event, ...)
    Obelisk.emitClient(event, self, ...)
end

--- @param source number
--- @return Player|nil
function PlayerService.get(source)
    return PlayerService.registry[source]
end

Obelisk.on('playerJoining', function()
    local source = source
    PlayerService.registry[source] = Player.new(source)
    print('[PlayerService] Player ' .. source .. ' joined')
end)

Obelisk.on('playerDropped', function()
    print('[PlayerService] Player ' .. source .. ' left')
    PlayerService.registry[source] = nil
end)

return PlayerService
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `lua5.4 tests/player_service_spec.lua`
Expected: `4 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add core/server/Services/PlayerService.lua tests/player_service_spec.lua tests/support/fivem_stubs.lua
git commit -m "feat(core): add PlayerService registry with join/drop lifecycle"
```

---

### Task 3: Fold `bootstrap.lua`'s `playerJoining`/`playerDropped` into `PlayerService`, sweep remaining raw `AddEventHandler`

**Files:**
- Modify: `core/server/bootstrap.lua`
- Modify: `core/server/Services/KeybindService.lua:107`
- Modify: `core/server/Services/SpawnManagerService.lua:38`
- Modify: `core/server/Services/ProgressService.lua:130`
- Modify: `core/server/Services/InstanceService.lua:108`
- Modify: `core/server/Services/EntityStreamerService.lua:693`
- Modify: `plugins/oblsk_tattoo/server/main.lua:149`

**Interfaces:**
- Consumes: `Obelisk.on` (Task 1).
- Produces: nothing new — pure `AddEventHandler` → `Obelisk.on` substitution, zero behavior change.

- [ ] **Step 1: Edit `core/server/bootstrap.lua`**

Remove the `playerJoining` and `playerDropped` handlers entirely (their job — creating/destroying the Player entry — now lives in `PlayerService.lua`, Task 2). Convert the remaining two:

```lua
-- Player connection handler
Obelisk.on('playerConnecting', function(name, setKickReason, deferrals)
    deferrals.defer()

    Wait(0)
    deferrals.update('Loading Obelisk Framework...')

    Wait(100)
    deferrals.done()
end)

-- Resource stop handler
Obelisk.on('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        print('[Obelisk] Framework stopping...')
    end
end)
```

- [ ] **Step 2: Convert the five remaining raw `AddEventHandler('playerDropped'/'playerJoining', ...)` call sites**

In each of `core/server/Services/KeybindService.lua`, `SpawnManagerService.lua`, `ProgressService.lua`, `InstanceService.lua`, `EntityStreamerService.lua`, and `plugins/oblsk_tattoo/server/main.lua`, replace `AddEventHandler('playerJoining', function() ... end)` / `AddEventHandler('playerDropped', function() ... end)` with the identical body under `Obelisk.on('playerJoining', function() ... end)` / `Obelisk.on('playerDropped', function() ... end)`. `EntityStreamerService.lua:693` passes a function reference directly (`AddEventHandler('playerDropped', EntityStreamerService.handlePlayerDropped)`) — keep that shape: `Obelisk.on('playerDropped', EntityStreamerService.handlePlayerDropped)`.

- [ ] **Step 3: Verify no raw `AddEventHandler` remains for these events outside `PlayerService.lua`/`Obelisk.lua`**

Run (from `core/`): `grep -rn "AddEventHandler(" . --include="*.lua" | grep -v ".worktrees" | grep -v "core/shared/Obelisk.lua" | grep -v "core/server/Services/PlayerService.lua"`
Expected: no output.

- [ ] **Step 4: Syntax-check every touched file**

Run (from `core/`): `for f in server/bootstrap.lua server/Services/KeybindService.lua server/Services/SpawnManagerService.lua server/Services/ProgressService.lua server/Services/InstanceService.lua server/Services/EntityStreamerService.lua ../plugins/oblsk_tattoo/server/main.lua; do lua5.4 -e "assert(loadfile('$f'))" && echo "OK $f"; done`
Expected: `OK` for all seven files.

- [ ] **Step 5: Commit**

```bash
git add core/server/bootstrap.lua core/server/Services/KeybindService.lua core/server/Services/SpawnManagerService.lua core/server/Services/ProgressService.lua core/server/Services/InstanceService.lua core/server/Services/EntityStreamerService.lua plugins/oblsk_tattoo/server/main.lua
git commit -m "refactor(core): sweep raw AddEventHandler to Obelisk.on for global engine events"
```

---

## Phase 2 — WebView relay + core services

### Task 4: `WebView.lua` server relay takes `Player`

**Files:**
- Modify: `core/server/Services/WebView.lua`
- Modify: `core/client/Services/WebView.lua` (rename its `Obelisk.onClient` call — see below)

**Interfaces:**
- Consumes: `Obelisk.emitClient(event, player, ...)` (Task 1).
- Produces: `WebView.<serverMethodName>(player, ...)` for every method in `WebViewRelayMethods` (e.g. `WebView.openPage(player, page)`, `WebView.focus(player)`, `WebView.hide(player)`, `WebView.emitClient(player, clientEvent, ...)`, `WebView.showGlobalElement(player, name)`, `WebView.hideGlobalElement(player, name)`, `WebView.destroy(player)`) — every plugin task in Phase 3–5 that calls these passes `player`.

- [ ] **Step 1: Edit `core/server/Services/WebView.lua`**

No signature change is needed in this file itself — it already forwards `target` straight into `Obelisk.emitClient`, and Task 1 made `Obelisk.emitClient`'s second parameter a `Player`. So this file is unchanged in behavior; only its doc comment needs updating to say `player`, not `target`:

```lua
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

return WebView
```

- [ ] **Step 2: Rename the client-side wiring in `core/client/Services/WebView.lua`**

The client uses the *old* client-side `onClient` (handler for a server-sent event), which Task 1 renamed to `onServer`. Find:

```lua
for _, clientMethodName in pairs(WebViewRelayMethods) do
    Obelisk.onClient('core:server:webview-' .. clientMethodName, function(...)
        WebView[clientMethodName](...)
    end)
end
```

Replace with:

```lua
for _, clientMethodName in pairs(WebViewRelayMethods) do
    Obelisk.onServer('core:server:webview-' .. clientMethodName, function(...)
        WebView[clientMethodName](...)
    end)
end
```

- [ ] **Step 3: Syntax-check both files**

Run (from `core/`): `lua5.4 -e "assert(loadfile('server/Services/WebView.lua'))" && lua5.4 -e "assert(loadfile('client/Services/WebView.lua'))"`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add core/server/Services/WebView.lua core/client/Services/WebView.lua
git commit -m "refactor(core): WebView server relay takes Player, client wiring uses renamed Obelisk.onServer"
```

---

### Task 5: `PolicyService.lua` + the three `Policies/*.lua` validators take `player`

**Files:**
- Modify: `core/server/Services/PolicyService.lua`
- Modify: `core/server/Policies/CooldownPolicy.lua`
- Modify: `core/server/Policies/IsAdminPolicy.lua`
- Modify: `core/server/Policies/WithinDistancePolicy.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PolicyService.check(player, resourceType, resourceId, callback)`, `PolicyService.checkSync(player, resourceType, resourceId)` — Task 6 (`ActionService`) and Task 10 (`InteractionService`) call these with `player`. Policy validator contract becomes `function(player, resource, config) return boolean, reason`.

- [ ] **Step 1: Edit `PolicyService.lua`**

Replace every `source` parameter/usage in `PolicyService.check` and `PolicyService.checkSync` with `player`:

```lua
--- Check if player passes all policies for a resource
--- @param player Player
--- @param resourceType string
--- @param resourceId any
--- @param callback function function(allowed, reason)
function PolicyService.check(player, resourceType, resourceId, callback)
    local policies = PolicyService.getPolicies(resourceType, resourceId)

    if #policies == 0 then
        callback(true)
        return
    end

    local index = 1

    local function checkNext()
        if index > #policies then
            callback(true)
            return
        end

        local attachment = policies[index]
        index = index + 1

        local policy = PolicyService.registry[attachment.policyId]

        if not policy then
            print('[PolicyService] Warning: Policy not found: ' .. attachment.policyId)
            checkNext()
            return
        end

        local success, allowed, reason = pcall(policy.validator, player, {
            type = resourceType,
            id = resourceId
        }, attachment.config)

        if not success then
            print('[PolicyService] Error in policy ' .. attachment.policyId .. ': ' .. tostring(allowed))
            callback(false, 'Policy check failed')
            return
        end

        if not allowed then
            print('[PolicyService] Policy ' .. attachment.policyId .. ' denied access for player ' .. player:getSource())
            callback(false, reason or 'Access denied by policy')
            return
        end

        checkNext()
    end

    checkNext()
end

--- Synchronous version of check (for use in sync contexts)
--- @param player Player
--- @param resourceType string
--- @param resourceId any
--- @return boolean allowed
--- @return string reason
function PolicyService.checkSync(player, resourceType, resourceId)
    local policies = PolicyService.getPolicies(resourceType, resourceId)

    if #policies == 0 then
        return true
    end

    for _, attachment in ipairs(policies) do
        local policy = PolicyService.registry[attachment.policyId]

        if policy then
            local success, allowed, reason = pcall(policy.validator, player, {
                type = resourceType,
                id = resourceId
            }, attachment.config)

            if not success then
                print('[PolicyService] Error in policy ' .. attachment.policyId .. ': ' .. tostring(allowed))
                return false, 'Policy check failed'
            end

            if not allowed then
                return false, reason or 'Access denied by policy'
            end
        end
    end

    return true
end
```

Everything else in this file (`register`, `attach`, `detach`, `getPolicies`, `resolveResourceTable`) is unchanged — they never touch `source`.

- [ ] **Step 2: Edit the three `Policies/*.lua` validators**

`CooldownPolicy.lua`: rename the `source` param to `player`, and use `player:getSource()` for the cooldown-key string (it's a plain string key, not a native call, but keeping it a number keeps existing cooldown data-shape stable):

```lua
local function cooldownValidator(player, resource, config)
    local duration = config.duration or 5000
    local key = player:getSource() .. ':' .. resource.type .. ':' .. tostring(resource.id)

    local lastUse = cooldowns[key]
    local now = GetGameTimer()

    if lastUse and (now - lastUse) < duration then
        local remaining = math.ceil((duration - (now - lastUse)) / 1000)
        return false, 'Please wait ' .. remaining .. ' seconds'
    end

    cooldowns[key] = now
    return true
end
```

`IsAdminPolicy.lua`: `IsPlayerAceAllowed` is a native needing the number:

```lua
local function isAdminValidator(player, resource, config)
    if IsPlayerAceAllowed(player:getSource(), 'admin') then
        return true
    end

    return false, 'Admin permission required'
end
```

`WithinDistancePolicy.lua`: `GetPlayerPed` needs the number:

```lua
local function withinDistanceValidator(player, resource, config)
    local maxDist = config.distance or 5.0
    local coords = config.coords

    if not coords then
        return false, 'Invalid distance check configuration'
    end

    local playerPed = GetPlayerPed(player:getSource())
    local playerCoords = GetEntityCoords(playerPed)
    local dist = #(vector3(playerCoords.x, playerCoords.y, playerCoords.z) -
                   vector3(coords.x, coords.y, coords.z))

    if dist > maxDist then
        return false, 'You are too far away'
    end

    return true
end
```

- [ ] **Step 3: Syntax-check all four files**

Run (from `core/`): `for f in server/Services/PolicyService.lua server/Policies/CooldownPolicy.lua server/Policies/IsAdminPolicy.lua server/Policies/WithinDistancePolicy.lua; do lua5.4 -e "assert(loadfile('$f'))" && echo "OK $f"; done`
Expected: `OK` for all four.

- [ ] **Step 4: Commit**

```bash
git add core/server/Services/PolicyService.lua core/server/Policies/CooldownPolicy.lua core/server/Policies/IsAdminPolicy.lua core/server/Policies/WithinDistancePolicy.lua
git commit -m "refactor(core): PolicyService and validators take Player instead of source"
```

---

### Task 6: `ActionService.lua` — `execute`/`register` take `player`, convert its `onServer` handler

**Files:**
- Modify: `core/server/Services/ActionService.lua`
- Modify: `tests/action_service_spec.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient` (Task 1), `PolicyService.check(player, ...)` (Task 5).
- Produces: `ActionService.execute(player, actionId, data)`, `ActionService.register(actionId, function(player, data) ... end, options)` — every `ActionService.register` call site across every plugin in Phase 3–5 uses this signature.

- [ ] **Step 1: Update `tests/action_service_spec.lua`'s fakes**

The existing spec stubs `_G.Obelisk = {onServer = function() end}` at file scope (per its own comment, line 17) to no-op the net-event registration so it can call `ActionService.execute(source, ...)` directly with a raw number. Update that stub and every direct call in the spec:

```lua
_G.Obelisk = _G.Obelisk or {onClient = function() end}
```

And wherever the spec currently does `ActionService.execute(42, 'some_action', {})` (or similar with a bare number), change to construct a fake Player first:

```lua
local function fakePlayer(source)
    return { source = source, getSource = function(self) return self.source end }
end
```

and pass `fakePlayer(42)` instead of `42`. Apply this to every `ActionService.execute(...)` call and every `action.handler` assertion in the spec (any place a test's registered handler asserts on its received `source` argument now asserts on `player:getSource()`).

- [ ] **Step 2: Run the spec to verify it fails against the still-unmodified service**

Run (from `core/`): `lua5.4 ../tests/action_service_spec.lua` (or the correct relative path per the spec file's own `arg[0]` resolution — match whatever `tests/obelisk_spec.lua` uses)
Expected: FAILs, since `ActionService.lua` still takes `source`.

- [ ] **Step 3: Edit `ActionService.lua`**

Rename every `source` parameter to `player` in `ActionService.execute` (and the doc comment), and convert the trailing net-event handler:

```lua
--- Execute a registered action, running its policy checks and hook chain.
--- @param player Player
--- @param actionId string
--- @param data table|nil
--- @return boolean
function ActionService.execute(player, actionId, data)
    local action = ActionService.registry[actionId]
    if not action then
        print('[ActionService] Action not found: ' .. actionId)
        return false
    end

    local function runAction()
        Hooks.runHook('action:before:' .. actionId, function(results)
            for _, result in ipairs(results) do
                if result == false then
                    print('[ActionService] Action cancelled by hook: ' .. actionId)
                    return
                end
            end

            local success, err = pcall(action.handler, player, data)

            if not success then
                print('[ActionService] Error executing action ' .. actionId .. ': ' .. tostring(err))
                return
            end

            Hooks.runHook('action:after:' .. actionId, function()
            end, player, data)
        end, player, data)
    end

    if PolicyService then
        PolicyService.check(player, 'action', actionId, function(allowed, reason)
            if not allowed then
                print('[ActionService] Action denied by policy: ' .. actionId .. ' for player ' .. tostring(player:getSource()))
                if NotificationService then
                    NotificationService.notify(player, {
                        type = 'error',
                        title = 'Access Denied',
                        description = reason or 'You cannot perform this action'
                    })
                end
                return
            end
            runAction()
        end)
    else
        runAction()
    end

    return true
end
```

(`ActionService.get`/`getAll`/`exists`/`unregister`/`register` are unchanged — none of them touch `source`; `register`'s stored `handler` is just whatever function the caller passes, which now happens to expect `player` first per every plugin's converted `ActionService.register(...)` call.)

Convert the trailing handler:

```lua
--- Net event handler for client-triggered actions
Obelisk.onClient('core:client:action-execute', function(player, actionId, data)
    ActionService.execute(player, actionId, data)
end)
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: (same command as Step 2)
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/ActionService.lua tests/action_service_spec.lua
git commit -m "refactor(core): ActionService.execute/register take Player"
```

---

### Task 7: `KeybindService.lua`

**Files:**
- Modify: `core/server/Services/KeybindService.lua`
- Modify: `tests/keybind_service_spec.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient` (Task 1), `ActionService.execute(player, ...)` (Task 6).
- Produces: `KeybindService.handlePress(player, actionId)`, `KeybindService.syncToClient(player)`.

- [ ] **Step 1: Update `tests/keybind_service_spec.lua`'s fakes**

Same pattern as Task 6 Step 1 — wherever the spec calls `KeybindService.handlePress(source, ...)` / `syncToClient(source)` with a bare number, construct and pass a fake `Player` instead.

- [ ] **Step 2: Run the spec to verify it fails**

Run (from `core/`): `lua5.4 tests/keybind_service_spec.lua`
Expected: FAILs against the unmodified service.

- [ ] **Step 3: Edit `KeybindService.lua`**

```lua
--- @param player Player
--- @param actionId string
function KeybindService.handlePress(player, actionId)
    if not ActionService.exists(actionId) then
        print('[KeybindService] Error: Action not found: ' .. tostring(actionId))
        return
    end
    ActionService.execute(player, actionId, {})
end

--- Net event: Client requests keybind sync
Obelisk.onClient('core:client:keybinds-requestSync', function(player)
    KeybindService.syncToClient(player)
end)

--- Net event: Client pressed a keybind
Obelisk.onClient('core:client:keybinds-pressed', function(player, actionId)
    KeybindService.handlePress(player, actionId)
end)
```

`KeybindService.syncToClient` itself (defined earlier in the file, not shown in the earlier read) takes whatever its current first param is named — rename it to `player` and update its body's use of that param the same way; if it calls `Obelisk.emitClient('...', source, ...)` internally, change to `player:emit('...', ...)`.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `lua5.4 tests/keybind_service_spec.lua`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/KeybindService.lua tests/keybind_service_spec.lua
git commit -m "refactor(core): KeybindService takes Player"
```

---

### Task 8: `NotificationService.lua`

**Files:**
- Modify: `core/server/Services/NotificationService.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient` (Task 1).
- Produces: `NotificationService.notify(player, data)`, `NotificationService.info(player, title, description, duration)` (and its `success`/`error`/`warning` siblings, same shape) — every caller across core and plugins (`ActionService`, `InteractionService`, every plugin using notifications) passes `player`.

- [ ] **Step 1: Edit `NotificationService.lua`**

Rename every `target`/`source` parameter across `notify` and its `info`/`success`/`error`/`warning` convenience wrappers to `player`, and convert the trailing handler:

```lua
--- Net event: Client requests to show notification (client-side triggered)
Obelisk.onClient('core:client:notification-show', function(player, data)
    NotificationService.notify(player, data)
end)
```

Every internal call like `NotificationService.notify(target, {...})` becomes `NotificationService.notify(player, {...})`, and wherever the function body calls `Obelisk.emitClient('...', target, ...)`, change to `player:emit('...', ...)`.

- [ ] **Step 2: Syntax-check**

Run (from `core/`): `lua5.4 -e "assert(loadfile('server/Services/NotificationService.lua'))"`
Expected: no error. (No existing spec for this file — this is the verification bar per the Conversion Pattern's closing note.)

- [ ] **Step 3: Commit**

```bash
git add core/server/Services/NotificationService.lua
git commit -m "refactor(core): NotificationService takes Player"
```

---

### Task 9: `ProgressService.lua`

**Files:**
- Modify: `core/server/Services/ProgressService.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient` (Task 1).
- Produces: `ProgressService.complete(player, progressId)`, `ProgressService.cancel(player, progressId)`, `ProgressService.activeProgress` stays keyed by numeric source internally (call `player:getSource()` at the point of indexing).

- [ ] **Step 1: Edit `ProgressService.lua`**

Convert the two `Obelisk.onServer` handlers and their bodies:

```lua
Obelisk.onClient('core:client:progress-complete', function(player, progressId)
    ProgressService.complete(player, progressId)
end)

Obelisk.onClient('core:client:progress-cancel', function(player, progressId)
    ProgressService.cancel(player, progressId)
end)
```

`ProgressService.complete`/`ProgressService.cancel` (defined earlier in the file) take `player` now; wherever they index `ProgressService.activeProgress[source]`, use `ProgressService.activeProgress[player:getSource()]`.

The raw `AddEventHandler('playerDropped', ...)` at line 130 was already converted to `Obelisk.on` in Task 3 — this task only touches the two `onServer` handlers above it and the two service functions.

- [ ] **Step 2: Syntax-check**

Run (from `core/`): `lua5.4 -e "assert(loadfile('server/Services/ProgressService.lua'))"`
Expected: no error.

- [ ] **Step 3: Commit**

```bash
git add core/server/Services/ProgressService.lua
git commit -m "refactor(core): ProgressService takes Player"
```

---

### Task 10: `InteractionService.lua`

**Files:**
- Modify: `core/server/Services/InteractionService.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient` (Task 1), `PolicyService.check(player, ...)` (Task 5), `NotificationService.notify(player, ...)` (Task 8), `ActionService.execute(player, ...)` (Task 6).
- Produces: `InteractionService.use(player, interactionId)`.

- [ ] **Step 1: Edit `InteractionService.lua`**

```lua
--- @param player Player
--- @param interactionId string
function InteractionService.use(player, interactionId)
    -- ... existing body, with every `source` renamed to `player`:
    -- GetPlayerPed(source) -> GetPlayerPed(player:getSource())
    -- PolicyService.check(source, ...) -> PolicyService.check(player, ...)
    -- NotificationService.notify(source, {...}) -> NotificationService.notify(player, {...})
    -- ActionService.execute(source, interaction.action, {...}) -> ActionService.execute(player, interaction.action, {...})
    -- Hooks.runHook('interaction:use', function() end, source, interaction) -> ..., player, interaction)
end

Obelisk.onClient('core:client:interaction-use', function(player, interactionId)
    InteractionService.use(player, interactionId)
end)

Obelisk.onClient('core:client:interaction-requestAll', function(player)
    Obelisk.emitClient('core:server:interaction-syncAll', player, InteractionService.registry)
end)
```

- [ ] **Step 2: Syntax-check**

Run (from `core/`): `lua5.4 -e "assert(loadfile('server/Services/InteractionService.lua'))"`
Expected: no error.

- [ ] **Step 3: Commit**

```bash
git add core/server/Services/InteractionService.lua
git commit -m "refactor(core): InteractionService takes Player"
```

---

### Task 11: `EntityStreamerService.lua`

**Files:**
- Modify: `core/server/Services/EntityStreamerService.lua`
- Modify: `tests/entity_streamer_service_spec.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient` (Task 1).
- Produces: `EntityStreamerService.sendGroupEntitiesTo(player, groupKey)`, `despawnGroupEntitiesFor(player, groupKey)`, `updatePlayerChunks(player, x, y, facingChunk)`, `loadChunkForPlayer(player, chunkKey)`, `unloadChunkForPlayer(player, chunkKey)`. `networkedOwners`/`playerChunks` internal tables stay keyed by numeric source (`player:getSource()`) — this is exactly the "genuinely needs the number" case from the Conversion Pattern's rule 7.

- [ ] **Step 1: Update `tests/entity_streamer_service_spec.lua`'s fakes**

Same pattern as Task 6/7 — every direct call to a now-`player`-taking function passes a fake `Player` instead of a bare number.

- [ ] **Step 2: Run the spec to verify it fails**

Run (from `core/`): `lua5.4 tests/entity_streamer_service_spec.lua`
Expected: FAILs against the unmodified service.

- [ ] **Step 3: Edit `EntityStreamerService.lua`**

Rename every `source` parameter to `player` across `sendGroupEntitiesTo`, `despawnGroupEntitiesFor`, `updatePlayerChunks`, `loadChunkForPlayer`, `unloadChunkForPlayer`. Every `Obelisk.emitClient('...', source, ...)` becomes `player:emit('...', ...)`. Every `EntityStreamerService.playerChunks[source]` / `EntityStreamerService.networkedOwners[entityId] = source` becomes `[player:getSource()]`. Convert the net handler:

```lua
Obelisk.onClient('core:client:streamer-updatePosition', function(player, x, y, heading)
    EntityStreamerService.updatePlayerChunks(player, x, y, heading and facingChunk or nil) -- preserve whatever the existing arg-forwarding shape is; do not invent new params
end)
```

(Match this handler's existing body exactly, just adding `player` as the first param and threading it through instead of `local source = source`.)

- [ ] **Step 4: Run the spec to verify it passes**

Run: `lua5.4 tests/entity_streamer_service_spec.lua`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/EntityStreamerService.lua tests/entity_streamer_service_spec.lua
git commit -m "refactor(core): EntityStreamerService takes Player, internal maps stay source-keyed"
```

---

### Task 12: `InstanceService.lua`

**Files:**
- Modify: `core/server/Services/InstanceService.lua`
- Modify: `tests/instance_service_spec.lua`

**Interfaces:**
- Consumes: none new.
- Produces: `InstanceService.enter(player, key)`, `InstanceService.leave(player)`, `InstanceService.getCurrentBucket(player)`, `InstanceService.getCurrentKey(player)`. `playerBucketKey`/`bucketMembers` stay keyed by numeric source (`player:getSource()`) — same rule-7 case as Task 11. `InstanceService.getPlayersIn(key)` keeps returning raw numeric sources (its doc says `@return number[]`) — do not change that return shape, since callers of *that* function are out of scope for this plan (they're not part of the ~72-signature propagation list; changing its return type would be scope creep).

- [ ] **Step 1: Update `tests/instance_service_spec.lua`'s fakes**

Same pattern as prior tasks.

- [ ] **Step 2: Run the spec to verify it fails**

Run (from `core/`): `lua5.4 tests/instance_service_spec.lua`
Expected: FAILs against the unmodified service.

- [ ] **Step 3: Edit `InstanceService.lua`**

```lua
--- @param player Player
local function clearStaleMembership(player)
    local source = player:getSource()
    local key = playerBucketKey[source]
    if key then
        bucketMembers[key][source] = nil
    end
    playerBucketKey[source] = nil
end

--- @param player Player
--- @param key string
function InstanceService.enter(player, key)
    local source = player:getSource()
    clearStaleMembership(player)

    bucketMembers[key] = bucketMembers[key] or {}
    local bucketId = 0 -- keep whatever the existing bucketId derivation is; not shown in the read excerpt, do not invent one
    SetPlayerRoutingBucket(source, bucketId)

    playerBucketKey[source] = key
    bucketMembers[key][source] = true
end

--- @param player Player
function InstanceService.leave(player)
    clearStaleMembership(player)
    SetPlayerRoutingBucket(player:getSource(), 0)
end

--- @param player Player
function InstanceService.getCurrentBucket(player)
    local key = playerBucketKey[player:getSource()]
    -- keep the existing bucketId lookup for `key` unchanged
end

--- @param player Player
function InstanceService.getCurrentKey(player)
    return playerBucketKey[player:getSource()]
end
```

(`InstanceService.getPlayersIn` is unchanged per the Interfaces note above.) Convert the trailing `playerDropped` handler body (already using `Obelisk.on` since Task 3) to call `InstanceService.leave` with a `Player`:

```lua
Obelisk.on('playerDropped', function()
    local player = PlayerService.get(source)
    if player then InstanceService.leave(player) end
end)
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `lua5.4 tests/instance_service_spec.lua`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/InstanceService.lua tests/instance_service_spec.lua
git commit -m "refactor(core): InstanceService takes Player, internal maps stay source-keyed"
```

---

### Task 13: `SpawnManagerService.lua`

**Files:**
- Modify: `core/server/Services/SpawnManagerService.lua`
- Modify: `tests/spawn_manager_service_spec.lua`

**Interfaces:**
- Consumes: `Obelisk.emitClient(event, player, ...)` (Task 1).
- Produces: `SpawnManagerService.markConnecting(player)`, `SpawnManagerService.readyToSpawn(player, characterId)`, `SpawnManagerService.getStage(player)`. `stages` stays keyed by numeric source.

- [ ] **Step 1: Update `tests/spawn_manager_service_spec.lua`'s fakes**

Same pattern as prior tasks.

- [ ] **Step 2: Run the spec to verify it fails**

Run (from `core/`): `lua5.4 tests/spawn_manager_service_spec.lua`
Expected: FAILs against the unmodified service.

- [ ] **Step 3: Edit `SpawnManagerService.lua`**

```lua
--- @param player Player
function SpawnManagerService.markConnecting(player)
    SpawnManagerService.stages[player:getSource()] = 'connecting'
    player:emit('core:server:spawn-begin')
end

--- @param player Player
--- @param characterId any
function SpawnManagerService.readyToSpawn(player, characterId)
    SpawnManagerService.stages[player:getSource()] = 'spawned'
    player:emit('core:server:spawn-complete', characterId)
end

--- @param player Player
function SpawnManagerService.getStage(player)
    return SpawnManagerService.stages[player:getSource()]
end
```

`markConnecting` is called from `core/server/bootstrap.lua`'s `playerJoining` handler today — but Task 3 removed that handler (folded into `PlayerService`). Add the call back into `PlayerService.lua`'s `playerJoining` handler (Task 2's file), right after the `Player.new(source)` line, now that a `Player` exists to pass:

```lua
Obelisk.on('playerJoining', function()
    local source = source
    PlayerService.registry[source] = Player.new(source)
    SpawnManagerService.markConnecting(PlayerService.registry[source])
    print('[PlayerService] Player ' .. source .. ' joined')
end)
```

(This is a one-line addition to `core/server/Services/PlayerService.lua`, included in this task's diff since it's the call site for the function this task converts — update `core/server/Services/PlayerService.lua` as part of this task's Step 3, not a separate task.)

- [ ] **Step 4: Run the spec to verify it passes**

Run: `lua5.4 tests/spawn_manager_service_spec.lua`
Expected: all tests pass. Also re-run `lua5.4 tests/player_service_spec.lua` since `PlayerService.lua` changed — expected still `4 passed, 0 failed` (the existing tests don't assert on `SpawnManagerService`, so this only proves no syntax regression; that's acceptable here since `SpawnManagerService` behavior itself is covered by its own spec).

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/SpawnManagerService.lua core/server/Services/PlayerService.lua tests/spawn_manager_service_spec.lua
git commit -m "refactor(core): SpawnManagerService takes Player, wire markConnecting into PlayerService.playerJoining"
```

---

## Phase 3 — Plugin conversion (small plugins)

Each task below follows the Conversion Pattern exactly. Each task's Step 1 is always: run the enumeration grep to get the current, authoritative list of sites (the lists below were verified at spec-writing time — re-verify, since the codebase moves). Step 2 is always: apply the pattern. Step 3 is always: re-run the same grep to confirm zero remaining old-pattern matches, then syntax-check every touched file.

### Task 14: `oblsk_tattoo`

**Files:**
- Modify: `plugins/oblsk_tattoo/server/main.lua`
- Modify: `plugins/oblsk_tattoo/server/services/TattooService.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient`, `ActionService.register` (Task 6 signature), `WebView.openPage`/`WebView.focus` (Task 4 signature).
- Produces: nothing consumed by later tasks (leaf plugin).

- [ ] **Step 1: Enumerate current sites**

Run: `grep -n "Obelisk\.onServer(\|local source = source\|WebView\.\w\+(source\|ActionService\.register(\|Obelisk\.emitClient(" plugins/oblsk_tattoo/server/main.lua`
Expected (verified at spec time): lines 75–77 (`WebView.openPage(source,...)`, `.focus(source)`, `Obelisk.emitClient('tattoo:server:sync', source, ...)`), 84 (`ActionService.register('tattoo:open', function(source, data)`), 107–108, 113, 121, 124 (`tattoo:client:apply` handler), 128–129, 136, 142, 145 (`tattoo:client:remove` handler). This is the full worked example already shown in the Conversion Pattern section above.

- [ ] **Step 2: Apply the Conversion Pattern to `server/main.lua`**

Use the exact before/after already given in the Conversion Pattern section for the `tattoo:client:apply` handler; apply the identical substitution to `tattoo:client:remove`, the `ActionService.register('tattoo:open', ...)` handler, and the top-of-file `WebView.openPage(source, '/Tattoo')` / `WebView.focus(source)` / `Obelisk.emitClient('tattoo:server:sync', source, {...})` block (these three become `WebView.openPage(player, '/Tattoo')` / `WebView.focus(player)` / `player:emit('tattoo:server:sync', {...})`, with `player` coming from whatever handler wraps that block — per the file, it's the `ActionService.register('tattoo:open', function(source, data)` handler being converted in this same step, so `player` is already in scope there).

- [ ] **Step 3: Edit `TattooService.lua`**

`TattooService.apply` and `TattooService.remove` (called from the converted handlers above) take `player` instead of `source` as their first parameter — propagate through per Conversion Pattern rule 6. Read the file first to find every internal use of that first parameter and convert each.

- [ ] **Step 4: Verify**

Run: `grep -n "Obelisk\.onServer(\|local source = source\|WebView\.\w\+(source" plugins/oblsk_tattoo/server/main.lua`
Expected: no output.
Run: `lua5.4 -e "assert(loadfile('plugins/oblsk_tattoo/server/main.lua'))" && lua5.4 -e "assert(loadfile('plugins/oblsk_tattoo/server/services/TattooService.lua'))"` (from `core/`, adjusting the relative path to `plugins/` — run from the repo root that contains both `core/` and `plugins/` as siblings)
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_tattoo/server/main.lua plugins/oblsk_tattoo/server/services/TattooService.lua
git commit -m "refactor(oblsk_tattoo): server handlers take Player"
```

---

### Task 15: `oblsk_radialmenu`

**Files:**
- Modify: `plugins/oblsk_radialmenu/server/main.lua`
- Modify: `plugins/oblsk_radialmenu/server/services/RadialMenuService.lua`

**Interfaces:** Consumes: same as Task 14. Produces: nothing consumed later.

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|Obelisk\.emitClient(" plugins/oblsk_radialmenu/server/main.lua plugins/oblsk_radialmenu/server/services/RadialMenuService.lua`
Expected sites (verified): `main.lua:13,25` (`ActionService.register('radialmenu:placeholder-action'/'open-default', function(source, data)`), `main.lua:30-31` (`Obelisk.onServer('radialmenu:server:selected', function(menuKey, entryKey)` + `local source = source`), `RadialMenuService.lua:114` (`Obelisk.emitClient('radialmenu:client:open', source, tree)`).
- [ ] **Step 2: Apply the Conversion Pattern** to all three sites in `main.lua` and the one in `RadialMenuService.lua` (its function receiving `source` — likely the function called from the `radialmenu:server:selected` handler — takes `player` instead, propagate per rule 6).
- [ ] **Step 3: Verify.** Re-run Step 1's grep restricted to `Obelisk\.onServer(\|local source = source` — expect no output. Syntax-check both files.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_radialmenu/server/main.lua plugins/oblsk_radialmenu/server/services/RadialMenuService.lua
git commit -m "refactor(oblsk_radialmenu): server handlers take Player"
```

---

### Task 16: `oblsk_keybinds`

**Files:**
- Modify: `plugins/oblsk_keybinds/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|Obelisk\.emitClient(" plugins/oblsk_keybinds/server/main.lua`
Expected: lines 15–16 (`ActionService.register('keybinds:open', function(source)` + `Obelisk.emitClient('keybinds:client:open', source)`), 19–20, 34 (`keybinds:server:resolveAll`), 37–38 (`keybinds:server:setOverride`), 70–71 (`keybinds:server:clearOverride`).
- [ ] **Step 2: Apply the Conversion Pattern** to all five sites.
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_keybinds/server/main.lua
git commit -m "refactor(oblsk_keybinds): server handlers take Player"
```

---

### Task 17: `oblsk_deathscreen`

**Files:**
- Modify: `plugins/oblsk_deathscreen/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|Obelisk\.emitClient(" plugins/oblsk_deathscreen/server/main.lua`
Expected: line 7 (`Obelisk.emitClient('deathscreen:client:show', player)` — this one is interesting: it already uses the identifier `player`, but per the pre-refactor code that was almost certainly a raw source under an existing local named `player` for readability, not a real `Player` object; confirm by reading the surrounding function signature before editing), 11 (`deathscreen:server:playerDied`), 15–16 (`deathscreen:server:respawn`).
- [ ] **Step 2: Read the file in full first** (it's tiny — this was the exact snippet quoted in the spec's opening problem statement) before editing, to correctly resolve what the existing `player` identifier at line 7 actually is.
- [ ] **Step 3: Apply the Conversion Pattern.** `deathscreen:server:playerDied` and `deathscreen:server:respawn` become `Obelisk.onClient(event, function(player) ... end)`; the respawn handler's body (per the very first message of this conversation) sets `SetEntityCoords`/`SetEntityHeading`/`SetEntityHealth` on `GetPlayerPed(source)` — change to `GetPlayerPed(player:getSource())`.
- [ ] **Step 4: Verify** — grep + syntax check.
- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_deathscreen/server/main.lua
git commit -m "refactor(oblsk_deathscreen): server handlers take Player"
```

---

### Task 18: `oblsk_payment`

**Files:**
- Modify: `plugins/oblsk_payment/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|Obelisk\.emitClient(" plugins/oblsk_payment/server/main.lua`
Expected: lines 4–5, 8 (`payment:client:listCards` handler — the entire file, per the earlier full-repo grep, is just this one handler).
- [ ] **Step 2: Apply the Conversion Pattern.**
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_payment/server/main.lua
git commit -m "refactor(oblsk_payment): server handler takes Player"
```

---

### Task 19: `oblsk_garage`

**Files:**
- Modify: `plugins/oblsk_garage/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_garage/server/main.lua`
Expected: lines 12–14 (`WebView.openPage`/`.focus`/`emitClient('garage:server:sync', ...)`), 17 (`ActionService.register('garage:open', ...)`), 56–57 (`rename`), 62–63 (`toggleFavorite`), 70–71 (`parkToggle`).
- [ ] **Step 2: Apply the Conversion Pattern.**
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_garage/server/main.lua
git commit -m "refactor(oblsk_garage): server handlers take Player"
```

---

### Task 20: `oblsk_shop`

**Files:**
- Modify: `plugins/oblsk_shop/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_shop/server/main.lua`
Expected: lines 13–15, 18, 54–55, 61–62, 65 (`shop:client:purchase`).
- [ ] **Step 2: Apply the Conversion Pattern.**
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_shop/server/main.lua
git commit -m "refactor(oblsk_shop): server handlers take Player"
```

---

## Phase 4 — Plugin conversion (medium plugins)

### Task 21: `oblsk_admin`

**Files:**
- Modify: `plugins/oblsk_admin/server/organisations.lua`
- Modify: `plugins/oblsk_admin/server/actions/ToggleAdminPanel.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|Obelisk\.emitClient(" plugins/oblsk_admin/server/organisations.lua plugins/oblsk_admin/server/actions/ToggleAdminPanel.lua`
Expected: `organisations.lua` — 9 handler pairs (`organisations-list`, `-create`, `-setDetails`, `-addDepartment`, `-removeDepartment`, `-addRank`, `-removeRank`, `-addContactNumber`, `-removeContactNumber`, `-toggleContactNumber`) plus the line-11 `Obelisk.emitClient('admin:client:organisations-reply', source, ...)`; `ToggleAdminPanel.lua` — lines 7–8 (`ActionService.register('admin:server:toggle-panel', function(source, data)` + `Obelisk.emitClient('admin:client:toggle-panel', source)`).
- [ ] **Step 2: Apply the Conversion Pattern to both files**, all sites.
- [ ] **Step 3: Verify** — grep both files + syntax check both.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_admin/server/organisations.lua plugins/oblsk_admin/server/actions/ToggleAdminPanel.lua
git commit -m "refactor(oblsk_admin): server handlers take Player"
```

---

### Task 22: `oblsk_notebook`

**Files:**
- Modify: `plugins/oblsk_notebook/server/main.lua`
- Modify: `plugins/oblsk_notebook/server/actions/NotebookActions.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|WebView\.emitClient(source" plugins/oblsk_notebook/server/main.lua plugins/oblsk_notebook/server/actions/NotebookActions.lua`
Expected: `main.lua:12` (`WebView.emitClient(source, 'notebook:open', payload)` — note the argument order here is `WebView.emitClient(target, event, ...)`, opposite of `Obelisk.emitClient(event, target, ...)` — preserve that same argument order, just substitute `player` for `source`), 16–17 (`notebook:client:save`), 26–27 (`notebook:client:tearOut`); `NotebookActions.lua:11` (`ActionService.register('notebook:open', ...)`), 18–20 (`WebView.openPage`/`.focus`/`.emitClient(source, ...)`), 23 (`ActionService.register('notebook:viewPage', ...)`), 30–32.
- [ ] **Step 2: Apply the Conversion Pattern to both files.**
- [ ] **Step 3: Verify** — grep both + syntax check both.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_notebook/server/main.lua plugins/oblsk_notebook/server/actions/NotebookActions.lua
git commit -m "refactor(oblsk_notebook): server handlers take Player"
```

---

### Task 23: `oblsk_inventory`

**Files:**
- Modify: `plugins/oblsk_inventory/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_inventory/server/main.lua`
Expected: lines 20, 32, 38, 41–42, 52–53 (`move`), 59–60 (`split`), 66–67 (`use`), 73–74 (`equip`), 80–81 (`drop`), 87–88 (`give` — note this handler's payload includes `targetSource`, a *different* player's source used to route the item; per Conversion Pattern rule 3, that becomes `PlayerService.get(targetSource)`, not `player`), 93–94, 104 (`openContainer`), 110–111 (`closeContainer`).
- [ ] **Step 2: Apply the Conversion Pattern**, paying attention to the `give` handler's `targetSource` per the note above.
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_inventory/server/main.lua
git commit -m "refactor(oblsk_inventory): server handlers take Player"
```

---

### Task 24: `oblsk_licenses`

**Files:**
- Modify: `plugins/oblsk_licenses/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|WebView\.\w\+(source\|WebView\.\w\+(target\|Obelisk\.emitClient(" plugins/oblsk_licenses/server/main.lua`
Expected: lines 72–73 (`WebView.emitClient(target, ...)` / `WebView.hideGlobalElement(target, 'licensePresent')` — `target` here is a *different* player, an officer checking someone else's license; convert to `PlayerService.get(targetSource):emit(...)` per rule 3, where `targetSource` is whatever numeric variable this file currently calls `target`), 91–92 (`licenses:client:present`), 108–109 (self-present), 111–112 (`targetSource` present-to-other, same rule-3 case as line 72), 129, 138 (`licenses:client:putAway`).
- [ ] **Step 2: Apply the Conversion Pattern**, converting both "present to self" and "present to another officer" call shapes per rule 3.
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_licenses/server/main.lua
git commit -m "refactor(oblsk_licenses): server handlers take Player"
```

---

### Task 25: `oblsk_terminal`

**Files:**
- Modify: `plugins/oblsk_terminal/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_terminal/server/main.lua`
Expected: lines 16–18, 24, 49–50, 57, 62–63 (note line 63: `Obelisk.emitClient('terminal:server:pay', session.customerSource, {...})` — a *different* player, the customer, not the cashier who triggered `charge`; rule-3 case), 82–83, 89, 93 (both `session.cashierSource` — again a different player than whoever's `player` is in scope in the `pay` handler, since `pay` is triggered by the *customer's* client, replying to the *cashier*), 99–100 (`printReceipt`).
- [ ] **Step 2: Apply the Conversion Pattern**, using `PlayerService.get(session.customerSource)`/`PlayerService.get(session.cashierSource)` per rule 3 wherever the recipient isn't the handler's own `player`.
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_terminal/server/main.lua
git commit -m "refactor(oblsk_terminal): server handlers take Player"
```

---

### Task 26: `oblsk_shellbuilder`

**Files:**
- Modify: `plugins/oblsk_shellbuilder/server/main.lua`
- Modify: `plugins/oblsk_shellbuilder/server/policies/CanBuildShellsPolicy.lua`
- Modify: `plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua`

- [ ] **Step 1: Enumerate `main.lua`.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_shellbuilder/server/main.lua`
Expected: 9 `onServer` handlers (`create`, `enter`, `edit`, `exit`, `place`, `removeObject`, `searchCharacters`, `addOwner`, `removeOwner`, `listOwners`) plus their paired `WebView.openPage`/`.focus`/`.hide` and `Obelisk.emitClient` sites — the full list is in the earlier full-repo grep output for this plugin (lines 73–319 of that dump), all following the exact same shape as the Task 14 worked example.
- [ ] **Step 2: Apply the Conversion Pattern to all 9 handlers in `main.lua`.**
- [ ] **Step 3: Edit `CanBuildShellsPolicy.lua`** — this is a `PolicyService` validator (Task 5 changed the contract to `function(player, resource, config)`); update its signature and body the same way Task 5 converted the three core policies.
- [ ] **Step 4: Edit `ShellObjectService.lua`** — it appears in the earlier "functions taking explicit `source`" grep; find every such function and rename `source`→`player`, propagating from the `main.lua` handlers that call into it.
- [ ] **Step 5: Verify** — grep `main.lua` for zero remaining old-pattern matches; syntax-check all three files.
- [ ] **Step 6: Commit**

```bash
git add plugins/oblsk_shellbuilder/server/main.lua plugins/oblsk_shellbuilder/server/policies/CanBuildShellsPolicy.lua plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua
git commit -m "refactor(oblsk_shellbuilder): server handlers, policy, and service take Player"
```

---

### Task 27: `oblsk_cardealer`

**Files:**
- Modify: `plugins/oblsk_cardealer/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_cardealer/server/main.lua`
Expected: lines 13–15, 18, 54–55, 58, 61, 70–71 (`testDrive`), 81–82 (`rent`).
- [ ] **Step 2: Apply the Conversion Pattern.**
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_cardealer/server/main.lua
git commit -m "refactor(oblsk_cardealer): server handlers take Player"
```

---

### Task 28: `oblsk_vendingmachine`

**Files:**
- Modify: `plugins/oblsk_vendingmachine/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_vendingmachine/server/main.lua`
Expected: lines 14–16, 19, 52–53, 56, 59 (`insertNote`), 63–64, 67, 69 (`purchase`), 73–74, 76 (`refund`), 82–83, 88 (`close`).
- [ ] **Step 2: Apply the Conversion Pattern.**
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_vendingmachine/server/main.lua
git commit -m "refactor(oblsk_vendingmachine): server handlers take Player"
```

---

### Task 29: `oblsk_tuner`

**Files:**
- Modify: `plugins/oblsk_tuner/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_tuner/server/main.lua`
Expected: lines 46–48, 53, 64–65, 74, 77 (`purchase` — note line 71's `Obelisk.emitClient('tuner:server:applyTuning', -1, {...})` is the broadcast exception from Conversion Pattern rule 3a, leave the `-1` literal as-is), 89, 115, 122–123, 127–128, 131, 138, 141 (`raise`), 145–146, 149, 159 (`assign`), 162–163, 166, 176 (`complete`), 182–183, 186, 199, 202 (`settle` — line 195 has the same `-1` broadcast exception), 206–207, 210 (`requestCards`), 219–220, 236 (`connectVehicle`).
- [ ] **Step 2: Apply the Conversion Pattern**, leaving both `-1` broadcast sites untouched per rule 3a.
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_tuner/server/main.lua
git commit -m "refactor(oblsk_tuner): server handlers take Player"
```

---

### Task 30: `oblsk_banking`

**Files:**
- Modify: `plugins/oblsk_banking/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_banking/server/main.lua`
Expected: lines 31–33, 53, 93–95, 109, 113 (two `ActionService.register` — `atm-use`, `branch-use`), 156–157, 161–162, 168 (`deposit`), 174–175, 181 (`withdraw`), 187–188, 200 (`transfer`), 206–207, 222 (`setCardFrozen`), 225–226 (`setCardLimit`), 252–253, 270 (`selectAccount`), 286–287, 304 (`openAccount`), 316–317, 328 (`selectPersonalAccount`).
- [ ] **Step 2: Apply the Conversion Pattern.** This plugin moves money — after converting, re-read the full diff once before committing to confirm every `player`/`PlayerService.get(...)` substitution routes to the correct connection (no cross-wiring a deposit's confirmation to the wrong player).
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_banking/server/main.lua
git commit -m "refactor(oblsk_banking): server handlers take Player"
```

---

### Task 31: `oblsk_phonebooth`

**Files:**
- Modify: `plugins/oblsk_phonebooth/server/main.lua`

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|WebView\.\w\+(source\|Obelisk\.emitClient(" plugins/oblsk_phonebooth/server/main.lua`
Expected (verified, ~30 sites): lines 14–16, 19, 55–56, 58 (`feed`), 61–62, 67, 71, 79 (`call.calleeSource` — different player, rule 3), 96–97, 102–103 (both self and `call.boothSource`, mixed rule-3), 111–112, 115–116, 120–121, 125–126, 134, 136 (`calleeSource`), 140–141, 143, 152, 161, 170, 193, 197–198 — this file has calls to *three different players' sources* in places (`boothSource`, `calleeSource`, the acting player) since it bridges phone calls between two people at two different devices; apply rule 3 carefully per site — the acting player is always the handler's new `player` param, every other named `*Source` field becomes `PlayerService.get(thatSource)`.
- [ ] **Step 2: Apply the Conversion Pattern.**
- [ ] **Step 3: Verify** — grep + syntax check.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_phonebooth/server/main.lua
git commit -m "refactor(oblsk_phonebooth): server handlers take Player"
```

---

## Phase 5 — Plugin conversion (large plugins)

### Task 32: `oblsk_phone`

**Files:**
- Modify: `plugins/oblsk_phone/server/main.lua`

**Notes:** this is the largest single file in scope (~60 `onServer` handlers, `main.lua` spans lines 9–783 per the full-repo grep dump). Same mechanical pattern throughout — no new call shapes beyond what Tasks 14–31 already cover (self-`player`, and occasional `*Source`-named fields for a different party, e.g. `passiveCall.callerSource`/`calleeSource`, `otherSource`, `stillRinging.callerSource`, per rule 3).

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|ActionService\.register(\|Obelisk\.emitClient(" plugins/oblsk_phone/server/main.lua | wc -l`
Expected: 143 (matches the full-repo grep dump captured during planning — re-verify this exact count before starting; if it differs, the codebase has moved since this plan was written and the task should re-derive the list rather than trust this number).
- [ ] **Step 2: Apply the Conversion Pattern to every handler.** Given the size, work top to bottom in file order rather than trying to batch by feature area (apps, dialer, contacts, notes, radio, maps, dispatch, messages, gallery, camera) — each section is independent and the pattern is identical, so there's no benefit to reordering.
- [ ] **Step 3: Verify.** Run: `grep -n "Obelisk\.onServer(\|local source = source" plugins/oblsk_phone/server/main.lua`
Expected: no output. Then: `lua5.4 -e "assert(loadfile('plugins/oblsk_phone/server/main.lua'))"` (from the repo root) — expect no error.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_phone/server/main.lua
git commit -m "refactor(oblsk_phone): server handlers take Player"
```

---

### Task 33: `oblsk_mdt`

**Files:**
- Modify: `plugins/oblsk_mdt/server/main.lua`

**Notes:** the largest plugin (~50 `onServer` handlers, file spans past line 1467). Same mechanical pattern as every other task — no new call shapes; every recipient in the enumerated grep output is the acting player's own `source`, no cross-player routing like `oblsk_phone`/`oblsk_phonebooth`/`oblsk_terminal`/`oblsk_licenses`/`oblsk_inventory` have, which makes this one purely mechanical (rule 3 never applies here).

- [ ] **Step 1: Enumerate.** Run: `grep -n "Obelisk\.onServer(\|local source = source\|Obelisk\.emitClient(" plugins/oblsk_mdt/server/main.lua | wc -l`
Expected: 152 (re-verify before starting, per the same caveat as Task 32).
- [ ] **Step 2: Apply the Conversion Pattern to every handler**, working top to bottom by section (auth, cases, citizens, docs, templates, vehicles, command, manhunts, impound, detention, laws, board, staff, lines, calendar, audit, admin).
- [ ] **Step 3: Verify.** Run: `grep -n "Obelisk\.onServer(\|local source = source" plugins/oblsk_mdt/server/main.lua`
Expected: no output. Then: `lua5.4 -e "assert(loadfile('plugins/oblsk_mdt/server/main.lua'))"` (from the repo root) — expect no error.
- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_mdt/server/main.lua
git commit -m "refactor(oblsk_mdt): server handlers take Player"
```

---

## Phase 6 — Full-suite verification

### Task 34: Run every existing spec, fix any fallout, confirm zero remaining old-pattern call sites repo-wide

**Files:** none created/modified in this task unless a spec reveals a missed site (in which case fix it in the relevant plugin/service file from an earlier task and note the fix in this task's commit).

- [ ] **Step 1: Run the full spec suite**

Run (from `core/`): `for f in tests/*_spec.lua; do echo "=== $f ==="; lua5.4 "$f" || echo "FAILED: $f"; done`
Expected: every spec reports `N passed, 0 failed`; no `FAILED:` lines.

- [ ] **Step 2: Repo-wide sweep for anything missed**

Run (from the repo root): `grep -rn "Obelisk\.onServer(\|local source = source\|RegisterNetEvent(" --include="*.lua" core plugins | grep -v "\.worktrees" | grep -v "core/shared/Obelisk.lua"`
Expected: no output. (The `RegisterNetEvent(` check catches any file that still calls it directly instead of through `Obelisk.onClient`/`onServer` — should already be zero per the spec's confirmed "no raw net-event bypass" finding, this is a final confirmation.)

- [ ] **Step 3: If Step 2 finds anything, fix it in place**

Apply the Conversion Pattern to whatever turned up, using the same grep+edit+verify loop as every prior task, then amend that finding into this task's commit (not a separate one, since it's cleanup for this same plan).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: verify Player/Obelisk foundation refactor is complete across the repo"
```

(If Step 2 found nothing and no files changed, skip this commit — there's nothing to commit.)
