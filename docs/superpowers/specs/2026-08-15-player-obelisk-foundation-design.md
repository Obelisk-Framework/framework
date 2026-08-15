# Player / Obelisk Foundation — Design Spec

Sub-project 1 of 3 (Foundation → Account link → Character link + char-select
backend). This spec covers Foundation only. Account link (`player.account`)
and Character link (`player.character` + `oblsk_character-selection` server
backend) are separate follow-up specs that depend on this one.

## Problem

`Obelisk.onServer`/`Obelisk.onClient` are named for "which side runs this
code", not "which direction the event travels" — `onServer` is a
server-side handler for client-originated events, `onClient` is a
client-side handler for server-originated events. This is internally
consistent (see code comments in `core/shared/Obelisk.lua`) but reads
backwards to this codebase's convention: `onX` should mean "handler for an
event X sent", located on the *other* side from X. Additionally, every
server-side net-event handler currently receives a raw numeric `source`
and re-derives player state ad hoc (`local source = source`, then manual
`GetPlayerName`/identifier lookups scattered per-plugin) — there's no
shared Player abstraction, even though the pattern of "resolve this
source into something richer" already exists twice, informally
(`AccountService.sessionAccounts`, `CharacterService.sessionCharacters`).

## Goals

1. Rename `Obelisk.onServer`/`onClient` (server-side) and
   `Obelisk.onServer`/`onClient` (client-side) so the name matches "who
   sent this event", not "which side is running".
2. Fix a latent correctness bug: net-event registration must call
   `RegisterNetEvent(eventName)` and `AddEventHandler(eventName, handler)`
   separately — `RegisterNetEvent`'s second argument is a numeric argsize
   hint, not a callback.
3. Introduce `PlayerService`, a server-side registry of `Player` objects
   keyed by connection source, with a deterministic join/drop lifecycle.
4. Propagate `Player` through every server-side function that currently
   takes a raw `source`, so `source` as a bare number stops being a thing
   application code passes around — it only exists at the exact point a
   native call or DB column needs it.
5. Sweep raw `AddEventHandler` usage (for same-side/global engine events
   like `playerJoining`, `playerConnecting`, `onResourceStop`) over to
   `Obelisk.on`, for consistency with the rest of the framework.

## Non-goals

- `player.account` / `player.character` — next two specs.
- Any change to `oblsk_character-selection`'s web/UI layer.
- Any change to client-side game logic beyond the `Obelisk.lua` rename.

## Design

### `Obelisk.lua` (`core/shared/Obelisk.lua`)

Server branch (`isServer == true`):

```lua
-- unchanged: same-side / global engine events
function Obelisk.on(eventName, callback)
    AddEventHandler(eventName, callback)
end

-- RENAMED (was emitClient, semantics unchanged) — send TO a client
function Obelisk.emitClient(eventName, player, ...)
    TriggerClientEvent(eventName, player:getSource(), ...)
end

-- RENAMED (was onServer) — handler for an event a CLIENT sent
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
```

Client branch (`isServer == false`):

```lua
function Obelisk.emitServer(eventName, ...)  -- unchanged
    TriggerServerEvent(eventName, ...)
end

-- RENAMED (was onClient) — handler for an event the SERVER sent
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
```

`Obelisk.emit` (same-side trigger) is unchanged on both sides.

### `PlayerService` (new — `core/server/Services/PlayerService.lua`)

```lua
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
        account = nil,   -- set by the Account-link sub-project
        character = nil, -- set by the Character-link sub-project
    }, Player)
end

function Player:getSource() return self.source end
function Player:getIdentifier(t) return self.identifiers[t] end
function Player:getName() return self.name end
function Player:notify(data) NotificationService.notify(self.source, data) end
function Player:emit(event, ...) Obelisk.emitClient(event, self, ...) end

function PlayerService.get(source)
    return PlayerService.registry[source]
end

Obelisk.on('playerJoining', function()
    local source = source
    PlayerService.registry[source] = Player.new(source)
end)

Obelisk.on('playerDropped', function()
    PlayerService.registry[source] = nil
end)
```

No lazy `find`/`create` path — lifecycle is join/drop-driven, so `get`
returns the `Player` or `nil`. `nil` is only reachable in the brief window
before `playerJoining` fires, which no net event can reach (the client
resource that could call `Obelisk.emitServer` doesn't start until after
`playerJoining`). `Obelisk.onClient`'s wrapper treats that as a drop-and-log
case, not a crash.

`core/server/bootstrap.lua`'s existing empty `playerJoining`/`playerDropped`
stubs are folded into `PlayerService.lua` (their `print(...)` diagnostics
move there too) rather than left as separate no-ops.

### Raw `AddEventHandler` → `Obelisk.on` sweep

Confirmed via repo-wide grep: **zero** raw `RegisterNetEvent` /
`TriggerServerEvent` / `TriggerClientEvent` calls exist outside
`Obelisk.lua` — every net event already goes through the `Obelisk.emit*`/
`Obelisk.on*` wrappers, so the rename itself has no hidden bypass to find.

Raw `AddEventHandler` usage for same-side/global engine events does exist
and converts to `Obelisk.on`:

- `core/server/bootstrap.lua` — `playerConnecting`, `playerJoining`,
  `playerDropped`, `onResourceStop` (the `playerJoining`/`playerDropped`
  handlers move into `PlayerService.lua` per above, rather than converting
  in place)
- `core/server/Services/KeybindService.lua:107` — `playerJoining`
- `core/server/Services/SpawnManagerService.lua:38` — `playerDropped`
- `core/server/Services/ProgressService.lua:130` — `playerDropped`
- `core/server/Services/InstanceService.lua:108` — `playerDropped`
- `core/server/Services/EntityStreamerService.lua:693` — `playerDropped`
  (currently passes `EntityStreamerService.handlePlayerDropped` directly as
  the callback — stays a direct function reference, just via `Obelisk.on`)
- `plugins/oblsk_tattoo/server/main.lua:149` — `playerDropped`

(`modules/oblsk_accounts/server/main.lua`'s `playerConnecting`/
`playerDropped` handlers are explicitly out of scope here — they're
rewritten as part of the Account-link sub-project, which also removes
`AccountService.sessionAccounts`.)

### `source` → `player` propagation

Every server-side function currently taking a raw `source` (~72 across
~20 files, per repo grep) is changed to take `player` instead. Call sites
pass through the `Player` they already have — from the `Obelisk.onClient`
boundary, or from a caller that itself now takes `player`. Where a native
call or a DB column genuinely needs the numeric id (`GetPlayerPed`,
`GetEntityCoords`, a `source`-keyed table lookup that must stay numeric),
call `player:getSource()` at that exact point — `source` as a bare number
is never threaded through application code again.

### Testing

- Existing busted-style specs that call these functions directly with a
  raw numeric `source` need updating to construct/pass a fake `Player`
  (a plain table with `getSource`/`getIdentifier`/etc. is sufficient — no
  need to route through the real `PlayerService` registry in unit tests
  unless the test is specifically about `PlayerService` itself).
- The FiveM-globals test-stub support module needs `GetPlayerName` and
  `GetPlayerIdentifierByType` stubs added.
- New `player_service_spec.lua`: registry populated on `playerJoining`,
  cleared on `playerDropped`, `get` returns `nil` before join / after drop,
  identifier/name caching, `Player` method behavior.
- `Obelisk.lua` itself gets a spec (doesn't have one today) covering: the
  client/server cross-guards still error correctly, `onClient`'s
  nil-player drop-and-log path, `RegisterNetEvent`+`AddEventHandler` both
  actually get called (regression test for the bug this spec fixes).

## Open questions for the implementation plan

- Exact enumeration of all ~72 call sites and their call graphs — the
  plan should re-derive this list mechanically (grep) rather than trust
  this spec's count, since the codebase moves.
- Whether the ~20 affected files are best migrated one-plugin-at-a-time
  with the existing test suite as the correctness gate per file, given
  the size.
