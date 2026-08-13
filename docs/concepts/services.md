# Services

Services are plain Lua tables loaded early in `fxmanifest.lua`'s `server_scripts`, right after the ORM layer and the `Hooks` module:

```
core/server/Services/Hooks.lua
core/server/Services/ActionService.lua
core/server/Services/InteractionService.lua
core/server/Services/PolicyService.lua
core/server/Services/NotificationService.lua
core/server/Services/ProgressService.lua
core/server/Services/KeybindService.lua
core/server/Services/*.lua
```

Because they're globals loaded in this fixed order, later services can call earlier ones directly (e.g. `ActionService` calls `PolicyService.check` and `NotificationService.notify`).

## Event naming

Every FiveM net event (`RegisterNetEvent`/`TriggerEvent`/`TriggerServerEvent`/`TriggerClientEvent`) and every NUI name (`SendNUIMessage`'s `eventname` field, `RegisterNUICallback`) follows one shape:

```
<plugin-or-module>:<server|client>:<action>
```

- **`<plugin-or-module>`**: the owning plugin/module slug, e.g. `character-selection`. Core's own built-in services (Notification, Progress, Interaction, and the rest) use `core`.
- **`<server|client>`**: the side that *sends* the event, not the side that handles it. A server broadcast like `core:server:notification-show` is registered with `RegisterNetEvent` on the client but sent with `core` as the sender context, since that's where `TriggerClientEvent` is called. This also keeps a request and its matching push from colliding when they'd otherwise share a name: `core:server:keybinds-requestSync` (server telling clients to re-request) and `core:client:keybinds-requestSync` (a client's actual request) are two different, unambiguous strings, not one name overloaded for both directions.
- **`<action>`**: a single hyphenated action name, e.g. `notification-show`, `progress-cancel`.

NUI names get the same treatment, always with `client` as the middle segment, since NUI (the Vue webview) only ever talks to client-side Lua, never to the server directly: `core:client:progress-start` (a `SendNUIMessage` payload's `eventname`, sent as `{eventname = 'core:client:progress-start', args = {...}}` and picked up by the `Obelisk` JS singleton), `core:client:notification-dismissed` (a `RegisterNUICallback` name).

This is a naming convention only, not a validated/enforced one; nothing in the framework rejects an event name that doesn't match. `Hooks.registerHook`/`Hooks.runHook` names (`interaction:use`, `notification:sent`, etc.) are a separate, in-process pub/sub system, not FiveM net events, and don't follow this scheme.

## Obelisk

A shared wrapper (`core/shared/Obelisk.lua`, loaded on both server and client) around FiveM's raw event natives. Every service in this file uses it instead of calling `RegisterNetEvent`/`TriggerServerEvent`/`TriggerClientEvent` directly. It always takes the full event name string (no auto-namespacing); the caller is responsible for following the naming convention above.

- **`Obelisk.emit(eventName, ...)`** / **`Obelisk.on(eventName, callback)`**: local-only, same-side. `emit` is `TriggerEvent`; `on` is `AddEventHandler` only, deliberately without `RegisterNetEvent`, so a local-only event never becomes remotely triggerable by the other side just because you registered a handler for it. Both work on server or client.
- **`Obelisk.emitClient(eventName, target, ...)`** (server only): `TriggerClientEvent`. `target` is a player server ID, or `-1` for everyone.
- **`Obelisk.onServer(eventName, callback)`** (server only): the receiving half of a client's `emitServer`, registered via `RegisterNetEvent` + `AddEventHandler`.
- **`Obelisk.emitServer(eventName, ...)`** (client only): `TriggerServerEvent`.
- **`Obelisk.onClient(eventName, callback)`** (client only): the receiving half of a server's `emitClient`.

Calling a wrong-side method (e.g. `Obelisk.emitClient` from client code) throws `'Obelisk.<name> can only be called from the <side>'` immediately, rather than silently misbehaving. `core/shared/Obelisk.lua` picks the right set of methods once at load time via `IsDuplicityVersion()`.

```lua
-- server
Obelisk.emitClient('myplugin:client:open', source, { page = 'shop' })
Obelisk.onServer('myplugin:server:buy', function(itemId)
    local source = source
    -- ...
end)

-- client
Obelisk.onClient('myplugin:client:open', function(data)
    WebView.openPage(data.page)
end)
Obelisk.emitServer('myplugin:server:buy', 'water')
```

## WebView

`Obelisk.emit`/`emitClient`/`emitServer` cover networked events between server and client, but plugins also need to talk to the NUI (the Vue webview). That's what `WebView` is for. See [WebView & NUI](/concepts/webview) for the full API, the NUI message shape, the JS `Obelisk` singleton on the Vue side, and how to register a persistent overlay component.

## Hooks

A minimal event-hook system (`core/server/Services/Hooks.lua`), loaded before every other service so they can all register and run hooks against each other's lifecycle events.

- **`Hooks.registerHook(hookName, callback)`**: registers `callback` under `hookName`. Multiple callbacks can register under the same name; they run in registration order.
- **`Hooks.runHook(hookName, finalCallback, ...)`**: runs every callback registered under `hookName`, passing `...` to each, then calls `finalCallback(results)` once they've all finished. `results` is an array of each callback's return value, in registration order.

Each callback can be synchronous or asynchronous:

- **Synchronous**: return a plain value directly. It's collected into `results` as-is.
- **Asynchronous**: return a `function(cb)`. `runHook` calls it and waits for `cb(result)` before moving to the next callback (or calling `finalCallback` if it was the last one). This is how a hook can, for example, run its own database query before contributing a result.

A callback that errors is caught via `pcall`; the error is printed and that callback's slot in `results` is left `nil`, but the chain continues to the next callback rather than aborting.

```lua
Hooks.registerHook('interaction:use', function(source, interaction)
    print(('[MyPlugin] %s used %s'):format(source, interaction.label))
    return true -- synchronous result
end)

Hooks.registerHook('action:before:open_stash', function(source, data)
    return function(cb)
        PolicyService.checkSync(source, 'custom', 'stash-cooldown')
        cb(true) -- asynchronous result, via the callback
    end
end)
```

Hooks the built-in services already run, that a plugin/module can register against without modifying core:

- **`action:before:<actionId>`** / **`action:after:<actionId>`**: run by `ActionService.execute` around the action handler. Any callback returning `false` from `action:before:<actionId>` cancels the action before it runs.
- **`interaction:use`**: run by `InteractionService.use` after a successful interaction (policy passed, associated action executed).
- **`notification:sent`**: run by `NotificationService.notify`, but only for a specific `target` (never for a `-1` broadcast).
- **`death:handle`**: run by `DeathService:handlePlayerDeath`. If any callback's result is truthy, the default respawn/heal behavior is skipped, letting a plugin (e.g. a custom death screen) take over entirely.

## ActionService

A registry/dispatcher for named, server-executed operations — the thing keybinds, interactions, and UI events all funnel through.

- **`ActionService.register(actionId, handler, options)`** — registers a handler, `function(source, data)`. Re-registering an `actionId` prints a warning and overwrites it.
- **`ActionService.execute(source, actionId, data)`** — runs the action for a player. It runs the `action:before:<actionId>` hook first (any hook returning `false` cancels the action), then checks `PolicyService.check(source, 'action', actionId, ...)` before invoking the handler, then runs `action:after:<actionId>`. If a policy denies the action, the player gets an `error`-type `NotificationService.notify` and the handler never runs. Actions with no attached policies are allowed by default.
- **`ActionService.get(actionId)`** — returns the registered `{id, handler, options}` entry or `nil`.
- **`ActionService.getAll()`** — returns the full registry table.
- **`ActionService.exists(actionId)`** — boolean.
- **`ActionService.unregister(actionId)`** — removes a registration.

Clients trigger actions over the network via the `core:client:action-execute` net event, which calls `ActionService.execute(source, actionId, data)` directly — this is why `PolicyService` enforcement in `execute` matters: without it, any client could invoke any registered action with arbitrary data.

## InteractionService

A registry of spatial (coordinate + range) world interactions, used for things like "press E to open."

- **`InteractionService.register(data)`** — `data` is `{x, y, z, range, label, action, options}` (`range` defaults to `2.0`, `label` defaults to `'Interact'`, `action` is the `ActionService` action ID to trigger). Returns a numeric `interactionId` and broadcasts it to all clients (`core:server:interaction-add`) for client-side streaming.
- **`InteractionService.unregister(interactionId)`** — removes it and broadcasts `core:server:interaction-remove`.
- **`InteractionService.get(interactionId)`** / **`InteractionService.getAll()`**.
- **`InteractionService.getNearby(x, y, z, range)`** — returns enabled interactions within `range` (or the interaction's own configured range) of a point.
- **`InteractionService.update(interactionId, data)`** — merges fields into an existing interaction and re-broadcasts it.
- **`InteractionService.setEnabled(interactionId, enabled)`** — toggles an interaction and re-broadcasts it.
- **`InteractionService.use(source, interactionId)`** — server-side handler for a player using an interaction: re-validates the player is within `range + 1.0` (latency tolerance) of the interaction, runs `PolicyService.check(source, 'interaction', interactionId, ...)`, and on success calls `ActionService.execute(source, interaction.action, {interactionId, interaction})` and runs the `interaction:use` hook.

Clients trigger use via the `core:client:interaction-use` net event; a fresh client requests the full registry via `core:client:interaction-requestAll`, answered with `core:server:interaction-syncAll`.

## PolicyService

Composable authorization middleware, backed by two database pivot tables — `action_policy` and `interaction_policy` — that attach named policies to a resource (an action ID or interaction ID).

- **`PolicyService.register(policyId, validator, options)`** — `validator` is `function(source, resource, config) -> allowed, reason`, where `resource` is `{type, id}`.
- **`PolicyService.attach(resourceType, resourceId, policyId, config)`** — `resourceType` is `'action'` or `'interaction'` (an allowlist; any other value errors). Upserts a row into `action_policy`/`interaction_policy` with the JSON-encoded `config`.
- **`PolicyService.detach(resourceType, resourceId, [policyId])`** — removes one attached policy, or all of them if `policyId` is omitted.
- **`PolicyService.getPolicies(resourceType, resourceId)`** — returns `{ {policyId, config}, ... }` read back from the pivot table.
- **`PolicyService.check(source, resourceType, resourceId, callback)`** — async; runs every attached policy's validator in order via `callback(allowed, reason)`. No attached policies means allowed by default; the first failing (or erroring) policy short-circuits the chain.
- **`PolicyService.checkSync(source, resourceType, resourceId)`** — synchronous equivalent, returns `allowed, reason`.

`ActionService.execute` and `InteractionService.use` both call into `PolicyService.check` before running their handlers, which is how policies actually gate access.

## NotificationService

Sends notifications to the client's Vue 3 UI via NUI/net events.

- **`NotificationService.notify(target, data)`** — the base call. `target` is a player server ID, or `-1` for everyone. `data` is `{type, title, description, duration, color}`; `type` defaults to `'default'` and is validated against `NotificationService.TYPES` (`info`, `default`, `warning`, `danger`, `error`, `success`) unless a custom `color` is given. `duration` defaults to `5000` (ms). Sends `core:server:notification-show` to the client and runs the `notification:sent` hook (for a specific target, not a broadcast).
- **`NotificationService.success(target, title, description, [duration])`**
- **`NotificationService.error(target, title, description, [duration])`**
- **`NotificationService.warning(target, title, description, [duration])`**
- **`NotificationService.info(target, title, description, [duration])`**

Each of the four convenience wrappers just calls `notify` with the matching `type`. This matches the pattern used in real action handlers, e.g. `plugins/oblsk_character-selection/server/actions/ExampleAction.lua`:

```lua
NotificationService.success(source, 'Oblsk_character-selection', 'Action executed successfully!')
```

Clients can also self-trigger a notification via the `core:client:notification-show` net event, which calls `NotificationService.notify(source, data)` for the sending player.

## ProgressService

Queue-based, per-player progress bars shown on the client via the Vue UI.

- **`ProgressService.start(target, data, onComplete, onCancel)`** — `data` is `{label, duration, canCancel}` (`label` defaults to `'Progress...'`, `duration` to `5000` ms, `canCancel` to `true`). Generates and returns a `progressId`, sends `core:server:progress-start` to the client, and schedules an automatic `ProgressService.complete` call via `SetTimeout` once `duration` elapses.
- **`ProgressService.complete(target, progressId)`** — removes the tracked progress, sends `core:server:progress-complete`, and calls `onComplete(target)` if one was given.
- **`ProgressService.cancel(target, progressId)`** — removes the tracked progress, sends `core:server:progress-cancel`, and calls `onCancel(target)` if one was given.
- **`ProgressService.cancelAll(target)`** — cancels every active progress bar for a player.
- **`ProgressService.getActive(target)`** — returns the player's active-progress table.

Progress state is also cleared automatically on `playerDropped`. Clients report completion/cancellation back via the `core:client:progress-complete` / `core:client:progress-cancel` net events.

## KeybindService

Resolves the key bound to an action through a three-tier model: an action's declared default (`actions.options.default_key`, set by whichever plugin calls `ActionService.register`) → an account-level override → a character-level override. Overrides are stored in `oblsk_preferences` (key `keybind:<actionId>`, scoped `owner_type = 'account'|'character'`) via that module's `PreferenceService.getMerged` precedence pattern — there's no dedicated keybinds table. See `docs/superpowers/specs/2026-08-13-keybind-layering-design.md` for the full design.

- **`KeybindService.resolve(actionId, accountId, characterId)`** — resolves a single action's effective key: default → account override (if set) → character override (if set).
- **`KeybindService.resolveAll(accountId, characterId)`** — resolves every registered action, returning `{actionId -> key}`.
- **`KeybindService.setOverride(scope, ownerId, actionId, key)`** / **`clearOverride(scope, ownerId, actionId)`** — write/clear an override (`scope` is `'account'` or `'character'`; anything else raises an error).
- **`KeybindService.syncToClient(source)`** — resolves that player's `accountId`/`characterId` (soft dependency on `AccountService`/`CharacterService`, so a core-only server still resolves default-only keybinds) and pushes the resolved `{actionId -> key}` map via `core:server:keybinds-sync`.
- **`KeybindService.handlePress(source, actionId)`** — verifies the action exists via `ActionService.exists`, then calls `ActionService.execute(source, actionId, {})`.

Clients report key presses via the `core:client:keybinds-pressed` net event and can request a re-sync via `core:client:keybinds-requestSync`; new players are synced automatically shortly after `playerJoining`. The client dispatch loop matches raw keyboard state (`IsRawKeyPressed`, not `IsControlJustPressed` — most keys have no native GTA5 control mapping) against the resolved map, skipping dispatch while the NUI has focus. The `oblsk_keybinds` plugin owns the rebind settings screen; it holds no keybind data of its own, just calls back into this service.

## EntityStreamerService

Budgeted, chunk-based spatial streaming for world entities (peds, objects, pickups, blips, markers) — spawns/despawns them per player based on position, so a plugin that wants ambient NPCs or props doesn't spawn/manage them itself. Backed by an `entities` table via the `Entity` model (`core/core/server/Models/Entity.lua`), with matching server (`core/server/Services/EntityStreamerService.lua`) and client (`core/client/Services/EntityStreamerService.lua`) halves.

- The world is divided into fixed 100-unit chunks (`EntityStreamerService.chunkSize`). Each player streams the chunks around their position, degrading through three tiers under budget pressure:
  - **Tier 1** (full) — the player's chunk plus all 8 neighbors (9 chunks).
  - **Tier 2** (degraded) — the player's chunk plus the one they're facing.
  - **Tier 3** (minimal) — the player's chunk only.

  Only peds/objects/pickups count against the global budget (`EntityStreamerService.entityBudget`, default `300`) — markers and blips are free. The highest tier that fits under budget wins, recalculated as players' active-chunk sets change (a chunk shared by two nearby players costs once, not twice).
- **Hysteresis** prevents flicker: a chunk only unloads once the player is 15 units past its boundary (not the instant they cross it), and a tier change only takes effect once 2 consecutive position updates (the 500ms client tick, so ~1s) agree on it.
- **Facing-direction precache**: the client reports its heading alongside position (re-sent only once it's turned more than 20°). The server derives the chunk one step past the facing chunk (`lookaheadChunk`) and pushes that chunk's entity models to the client ahead of time, so `RequestModel` has already streamed them in by the time the player's real chunk membership includes it — spawning becomes an instant `CreatePed`/`CreateObject` rather than a stall.
- **Local vs. networked entities** (`entities.networked` column): local-only entities (ambient dressing) are spawned independently and privately by every client with the chunk active. Networked entities (anything another player must see identically, e.g. a shared prop) spawn once — whichever client's active-chunk set first includes them becomes the owner (`EntityStreamerService.networkedOwners`, cleared on that owner's disconnect) — then FiveM/OneSync handles visibility and ownership migration to everyone else automatically; no hand-rolled handoff protocol.

Server API:

- **`EntityStreamerService.register(entityType, entityData)`** — registers an entity (`entityType` one of `ped`/`object`/`pickup`/`marker`/`blip`; `entityData` needs `x`/`y`/`z` plus type-specific fields, e.g. `scenario`/`freeze`/`invincible` for peds, `pickupType`/`amount` for pickups, `sprite`/`color`/`scale`/`label` for blips, `markerType`/`scaleX,Y,Z`/`r,g,b,a` for markers). Returns an `entityId`. Currently only called by `init()` at boot, which loads every enabled `entities` row — nothing in the framework registers one at runtime yet, so adding an entity means inserting a row and restarting the resource (or calling `register` directly from your own code for an immediate, unpersisted spawn).
- **`EntityStreamerService.unregister(entityType, entityId)`** — removes an entity and broadcasts its removal to whichever players have it loaded.
- **`EntityStreamerService.getChunkEntityRecords(chunkKey)`** — flat array of `{entityId, entityType, data}` for everything currently in a chunk.

```lua
Entity:create({
    entity_type = 'ped',
    model = 'a_m_y_business_01',
    x = 215.4, y = -810.2, z = 30.7, heading = 90.0,
    networked = false,
    enabled = true,
    data = { scenario = 'WORLD_HUMAN_STAND_IMPATIENT' },
})
-- picked up by EntityStreamerService.init() on the next resource restart
```

On the client, `Obelisk.onClient('core:server:streamer-entityAdd', ...)` / `-entityRemove` spawn/despawn entities via natives (`CreatePed`, `CreateObject`, `CreatePickup`, `AddBlipForCoord`; markers have no handle and are just redrawn every frame). A background thread reports the local player's position and facing heading every 500ms via `core:client:streamer-updatePosition`, which drives the server's tier/hysteresis/precache logic above.

See `docs/superpowers/specs/2026-08-12-entity-streamer-design.md` for the full design writeup (tier/budget math, hysteresis margins, data model) and `core/tests/entity_streamer_service_spec.lua` for its test coverage.

## Other services

`core/server/Services/*.lua` also loads a few additional services not detailed here: `BlipService`, `DeathService`, `MarkerService`, and `PedService`. They're currently empty stubs, loaded automatically via that fxmanifest wildcard alongside the services above.
