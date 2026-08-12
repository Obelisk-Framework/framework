# Preferences Module and HUD Element Plugins Design

**Repositories:** `modules/oblsk_preferences` (new, standalone module), `plugins/oblsk_notifications` and `plugins/oblsk_progressbar` (new, extracted from core), `plugins/oblsk_phone`, `plugins/oblsk_hud`, `plugins/oblsk_speedometer` (new, minimal skeletons). Six repositories total.

**Goal:** Let global HUD elements (notifications, phone, hud, speedometer, progress bars) live as independent, swappable plugin repositories rather than framework-owned code, each individually toggleable, with the player's on/off choice persisted per account or per character. Core keeps owning only the generic mechanism (the global-elements registry, `WebView`, and one small extension point), never a specific element's implementation.

## Why this exists

Two of these elements (`Notifications.vue`, `ProgressBars.vue`) currently live inside core's own `web/src/components/global/`, hardcoded into `web/src/globalElements.js`. That contradicts the framework's own stated intent: core should provide the API (`NotificationService`, `ProgressService`, both already correctly placed in `core/client|server/Services/`) and nothing more, every actual UI implementation, including the ones core ships as a starting point, should be a swappable reference plugin someone can fully replace. This project fixes that (moves both `.vue` files into their own plugin repos, unchanged, since their event contract already has zero coupling to where the file lives) and establishes the pattern for new elements going forward.

Separately, "toggled on or off" implies the choice needs to survive relogging. There's no existing generic settings store anywhere in the framework, and the natural owner varies by setting: some things make sense per-account (a player always wants notifications quiet), others per-character (a roleplay persona's phone contacts, though that's out of scope here, just the pattern that motivates a polymorphic owner). `oblsk_preferences` is that generic store, one table, reusable by any future plugin, not just HUD elements.

## Part 1: `oblsk_preferences`

### Schema

`preferences`:

| Column | Type | Notes |
|---|---|---|
| `owner_type` | string(20) | `'account'` or `'character'`, open, not a fixed enum (same convention as `Item`/`Vehicle` ownership) |
| `owner_id` | integer | no FK, target table depends on `owner_type` |
| `key` | string(150) | e.g. `'hud:notifications:enabled'` |
| `value` | json | |
| (timestamps) | | |

`unique({'owner_type', 'owner_id', 'key'})`: the upsert target for `PreferenceService.set`, and what makes "one setting per owner per key" an actual guarantee rather than a convention.

### `PreferenceService` (server-only)

- **`PreferenceService.set(ownerType, ownerId, key, value)`**: upsert (select-then-insert-or-update, same shape as `ActionService.register`'s upsert).
- **`PreferenceService.get(ownerType, ownerId, key)`**: single lookup, decoded `value` or `nil`.
- **`PreferenceService.getMerged(accountId, characterId, keys)`**: for each key in `keys`, returns the `character`-scoped value if `characterId` is non-nil and a row exists, otherwise the `account`-scoped value, otherwise omits the key entirely. Character overrides account for the same key, same base/override precedence `VehicleHandling.mergeRows` already established for handling data. Returns one flat `{key -> value}` table. This is the only merge logic in the module; `set`/`get` never merge anything.

`oblsk_preferences` has no `require`, no Lua reference, and no migration-level foreign key pointing at `oblsk_accounts` or `oblsk_characters`. The only place it reads either module is the session resolver below, and that's a plain global function call (`AccountService.getAccountId(source)`), the same cross-module reference style `Character:accountRelation()` already uses to reach `Account` without a hard dependency.

### Session resolution and the write path

A small server-side handler resolves the *current connection's* `accountId`/`characterId` before ever touching the database:

```lua
Obelisk.onServer('oblsk_preferences:server:set', function(scope, key, value)
    local source = source

    local accountId = AccountService.getAccountId(source)
    local characterId = CharacterService.getActiveCharacterId(source)

    local ownerType, ownerId
    if scope == 'character' and characterId then
        ownerType, ownerId = 'character', characterId
    else
        ownerType, ownerId = 'account', accountId
    end

    if not ownerId then
        return -- unresolved session, nothing to write against
    end

    PreferenceService.set(ownerType, ownerId, key, value)
end)
```

**The client only ever sends `{ scope, key, value }`, never an id.** The server resolves the real `owner_id` itself from session state. A client that could supply its own `owner_id` could overwrite another account's or character's preferences, this is the same class of footgun already caught once this session (`Obelisk.on` unnecessarily calling `RegisterNetEvent`, making a "local" event remotely triggerable). `scope = 'character'` silently falls back to `'account'` if no character is currently selected (true for every session today, until the Characters UI-wiring pass exists), rather than erroring.

### Hydration (the read path) via `provide`/`inject`, not a core change per element

The **only** change to any core file in this entire project is one line in `core/web/src/App.vue`, exposing the reactive global-elements registry it already maintains:

```js
provide('obelisk:globalElementsRegistry', registry)
```

`oblsk_preferences` ships its own global element, `PreferencesHydrator.vue`, always `defaultVisible: true`, renders nothing (`<template></template>`), whose only job is:

```js
import { inject, onMounted } from 'vue'
import Obelisk from '../../../../web/src/obelisk.js' // same relative import every plugin global element already uses

const registry = inject('obelisk:globalElementsRegistry')

onMounted(() => {
  const keys = [...registry.keys()].map(name => `hud:${name}:enabled`)

  Obelisk.on('oblsk_preferences:client:hydrate', (merged) => {
    for (const [name, entry] of registry) {
      const key = `hud:${name}:enabled`
      if (merged[key] !== undefined) entry.visible = merged[key]
    }
  })

  Obelisk.emit('oblsk_preferences:client:request', { keys })
})
```

Server side, mirroring the write path's session resolution:

```lua
Obelisk.onServer('oblsk_preferences:server:request', function(keys)
    local source = source

    local accountId = AccountService.getAccountId(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    local merged = PreferenceService.getMerged(accountId, characterId, keys)
    Obelisk.emitClient('oblsk_preferences:client:hydrate', source, merged)
end)
```

No HUD element plugin needs to know `oblsk_preferences` exists to get persisted visibility, being a normal global element (a registry entry with a `name`) is enough. The convention key `hud:<name>:enabled` is the entire contract; nothing needs to be declared anywhere else.

**This degrades gracefully today.** `characterId` is `nil` for every session until a future Characters UI-wiring pass exists, so hydration is effectively account-only for now, `getMerged` already handles a `nil` `characterId` by never looking at the `character` scope.

## Part 2: The HUD element plugin pattern

Every HUD element plugin needs exactly:

- `web/src/components/<Name>.vue`, whatever it actually renders.
- `web/globalElements.js`, exporting `[{ name, component, defaultVisible }]` (the existing convention, unchanged).
- Whatever server/client Lua API it talks to (already exists for notifications/progress bars: `NotificationService`, `ProgressService`, both staying in core).

Nothing about persisted visibility, toggling, or the preferences wiring above needs to be written per-plugin. That's the whole point, `oblsk_preferences` is orthogonal to every element.

### Extraction: `oblsk_notifications`, `oblsk_progressbar`

Move `web/src/components/global/Notifications.vue` and `ProgressBars.vue` verbatim into their own new plugin repos (`web/src/components/Notifications.vue` etc.), each with its own `web/globalElements.js`:

```js
import Notifications from './components/Notifications.vue'
export default [{ name: 'notifications', component: Notifications, defaultVisible: true }]
```

Remove both entries from core's `web/src/globalElements.js` (which becomes an empty array, or is deleted along with its import in `App.vue` if nothing core-owned remains, core never owns any HUD element after this). `NotificationService`/`ProgressService` (client and server, in `core/`) are untouched, their event names (`core:client:notification-show`, `core:server:progress-*`, etc.) are the stable contract that makes this extraction purely mechanical, zero Lua changes.

### New skeletons: `oblsk_phone`, `oblsk_hud`, `oblsk_speedometer`

Minimal, no real feature content. Each gets a placeholder `.vue` component (a labeled box, nothing functional) and a `globalElements.js` entry, correctly wired into the toggle/preferences mechanism by virtue of being a normal registry entry. What each of these actually displays (contacts and calls for phone, health/armor/minimap for hud, real vehicle speed for speedometer) is explicitly out of scope, a separate future pass per element, same deferral pattern as every other module this session.

## Duplicate name handling

If two plugins register a global element with the same `name` (e.g. someone's custom notifications replacement installed alongside the reference `oblsk_notifications`), `App.vue`'s registry build logs a console warning naming the conflict and keeps whichever was discovered last (glob order). Swapping an element means removing the old plugin from `plugins/`, not just adding a competing one, this is a policy for `App.vue`'s existing registry-building loop, not a new mechanism.

## Testing

- `PreferenceService`: unit tests (fake `QueryBuilder`, same pattern as `oblsk_accounts`/`oblsk_characters`) for `set`/`get` round-trip, `getMerged`'s character-overrides-account precedence, `getMerged` with a `nil` `characterId` (falls back to account-only), `getMerged` omitting a key with no row in either scope.
- The session-resolution handlers, `App.vue`'s `provide`, and `PreferencesHydrator.vue` all touch FXServer-only globals or the Vue runtime, manual verification only (syntax checks, matching the existing convention for anything that can't run outside FXServer/a browser).
- The extraction of `Notifications.vue`/`ProgressBars.vue` has no new logic to test, verify by inspection that the moved files are byte-identical apart from their new location and import paths.

## Known gaps (deferred)

- No settings-menu UI for a player to actually flip these toggles, this ships plumbing only. A future pass wires an actual settings screen to `Obelisk.emit('oblsk_preferences:client:set', ...)`.
- Hydration doesn't re-fire when a character gets selected later, the future Characters UI-wiring pass needs to trigger a re-request once it sets the active character.
- No admin/CLI tooling for inspecting or clearing preferences.
- `oblsk_phone`/`oblsk_hud`/`oblsk_speedometer` ship with no real feature content, each is its own future design pass.
- No CLI generator for scaffolding a new HUD element plugin (a `make:plugin` preset could add this later).
