# Keybind layering: default → account → character overrides

**Goal:** Replace `KeybindService`'s current per-FiveM-identifier storage with a
three-tier resolution model (a plugin-declared default key on the action
itself, overridable per account, overridable again per character), and ship a
standalone settings plugin so a player can actually rebind keys.

**Source:** `core/core/server/Services/KeybindService.lua` (server) and its
client counterpart exist today but store keybinds keyed by
`GetPlayerIdentifier`/`is_global`, with no account/character concept at all —
this design replaces that persistence layer, not the keypress/dispatch
mechanics around it (`ActionService.execute`, the client-side key-listener
loop, `core:client:keybinds-pressed`), which are unchanged.

## Architecture

Resolving the bound key for one `actionId` given a player's `accountId`
and `characterId` is a three-tier lookup, highest tier wins:

1. **Default** — `ActionService.register(actionId, handler, options)`'s
   `options.default_key`, persisted onto the existing `actions.options`
   json column (no migration: `options` already exists and is already
   written by `ActionService.flushPendingRegistrations`). A plugin declares
   its action's default binding at registration time, e.g.
   `ActionService.register('vehicle:seatbelt', handler, {label = 'Seatbelt', default_key = 'B'})`.
2. **Account override** — `oblsk_preferences`' `PreferenceService.get('account', accountId, 'keybind:'..actionId)`,
   a plain key string.
3. **Character override** — `PreferenceService.get('character', characterId, 'keybind:'..actionId)`,
   same shape.

This is exactly `PreferenceService.getMerged`'s existing base/override
precedence (character beats account beats "no row"), reused rather than
reimplemented — `KeybindService` calls `PreferenceService` directly rather
than owning its own override storage. One key per action per tier — no alt
slot (the design reference's two independent binding slots per action are
not carried over; see UI section below).

**Multiple actions may resolve to the same key.** This is not a conflict to
prevent — e.g. `B` is the default for both `vehicle:seatbelt` and
`interaction:point`. Nothing in `KeybindService` detects or blocks this;
resolution is purely per-`actionId`, independent of what any other action
resolves to. The settings UI flags a shared key informationally (an amber
highlight/badge, see below) but never auto-evicts the other binding on
rebind — a deliberate divergence from the design reference's `assign()`,
which does evict.

`oblsk_preferences` has no dependency on `oblsk_characters`/`oblsk_accounts`
(callers resolve their own ids) — `KeybindService` keeps that same shape,
taking `accountId`/`characterId` as plain parameters rather than importing
those modules. The one place `KeybindService` needs to resolve `source` →
ids itself (`syncToClient`) does so via a soft/optional lookup (`AccountService`/
`CharacterService` called only if the global exists, matching the
soft-dependency pattern already used elsewhere, e.g.
`oblsk_banking/server/main.lua`'s `PhoneAppRegistry` guard) — so core doesn't
hard-depend on either module, and a server without them still resolves
default-only keybinds correctly (`resolve` with `nil` account/character ids
just returns the default).

## Data model

- **`actions.options`** gains one conventional (unenforced) key:
  `default_key`. No migration.
- **`keybinds` table**: dropped. `player_identifier`, `is_global`, and the
  `registerGlobal`/`registerPlayer`/`update`/`delete` API built around them
  are removed entirely — every existing caller of `registerGlobal` (e.g.
  `oblsk_phone`'s `phone:toggle-dock` action) moves its key assignment into
  `ActionService.register`'s `options.default_key` instead. A migration
  drops the table.
- **`oblsk_preferences`**: no schema change. `keybind:<actionId>` is just
  another preference key, value a plain key string (row absent entirely
  means "cleared back to the tier below").

## KeybindService API (server, rewritten)

- **`KeybindService.resolve(actionId, accountId, characterId)`** → `key`
  string, or `nil`. Falls through default → account → character; `nil` if
  the action has no default and no override at any tier (an unbound
  action).
- **`KeybindService.resolveAll(accountId, characterId)`** →
  `{actionId -> key}` for every action in `ActionService.getAll()`. What
  the client needs to build its local key-press → action dispatch table.
- **`KeybindService.setOverride(scope, ownerId, actionId, key)`** —
  `scope` is `'account'` or `'character'` (an allowlist, anything else
  errors, matching `PolicyService.attach`'s `resourceType` precedent).
  Writes `PreferenceService.set(scope, ownerId, 'keybind:'..actionId, key)`.
- **`KeybindService.clearOverride(scope, ownerId, actionId)`** — deletes
  the override row for that scope/action, falling resolution back to the
  tier below. (`PreferenceService` has no `delete`; add one — `PreferenceService.clear(ownerType, ownerId, key)` —
  since "unbind back to default" needs an actual row removal, not a
  `nil`-valued row that `getMerged`'s `if value ~= nil` check would still
  skip correctly, but which would leave dead rows accumulating.)
- **`KeybindService.syncToClient(source)`** — resolves `accountId`
  (`AccountService.getAccountId(source)` if that global exists) and
  `characterId` (`CharacterService.getActiveCharacterId(source)` if that
  global exists), calls `resolveAll`, sends the result via
  `core:server:keybinds-sync` (event name unchanged).

Removed: `loadPlayerKeybinds`/`loadPlayerKeybindsSync`/`registerGlobal`/
`registerPlayer`/`update`/`delete` and their raw-SQL queries against
`keybinds`.

Unchanged: `KeybindService.handlePress` (still resolves a pressed key back
to an `actionId` and calls `ActionService.execute`), the
`core:client:keybinds-pressed`/`core:client:keybinds-requestSync` net
events, the `playerJoining` auto-sync, and everything in
`core/core/client/Services/KeybindService.lua` except that its local
dispatch table is now keyed by the richer `resolveAll` payload (still one
`SendNUIMessage`-free, pure-Lua key-listener loop — the client doesn't
change how it *detects* a keypress, only what table it looks the pressed
key up against).

## New plugin: `oblsk_keybinds`

A UI-only plugin (no server-side game logic beyond a thin NUI bridge) that
owns the rebind settings screen. `KeybindService` stays in core since
`ActionService` and many other plugins depend on it; this plugin only
*calls* core's API.

- **`server/main.lua`**: registers `ActionService.register('keybinds:open', handler, {label = 'Key Bindings'})`
  (default key intentionally unbound — a player binds it themselves, or a
  future pause-menu integration triggers it directly) whose handler does
  `Obelisk.emitClient('keybinds:client:open', source)`. Three
  `Obelisk.onServer` handlers backing the settings screen's NUI round
  trips: `keybinds:server:resolveAll` (calls `KeybindService.resolveAll`
  for the requesting player, returns the map), `keybinds:server:setOverride`,
  `keybinds:server:clearOverride` (both call straight into `KeybindService`,
  scoped to the requesting player's own account/character — a player can
  never set another player's override, there's no ownerId parameter taken
  from the client).
- **`client/main.lua`**: `Obelisk.onClient('keybinds:client:open', ...)` →
  `WebView.showGlobalElement('keybinds')` (or a dedicated open call,
  following whichever of `WebView`'s existing helpers matches a one-shot
  full-screen page rather than a toggleable HUD element — confirm against
  `core/core/client/Services/WebView.lua`'s exact API during planning, not
  guessed here).
- **`web/globalElements.js`**: registers the page, `defaultVisible: false`.
- **`web/Keybinds.vue`**: ports `src/proto/keybinds.jsx`'s layout, adapted
  from two rebind slots per action down to one — Overview/Edit mode toggle,
  category filter + search, per-action rows with a single rebind button
  (click, then "press any key" capture, same as the reference's `listening`
  state machine minus its `slot` dimension), a live keyboard map
  highlighting bound keys and cross-highlighting on hover, and a shared-key
  indicator (amber, informational only — no eviction, see Architecture).
  Real data via `keybinds:server:resolveAll` on mount instead of the
  reference's mock `KB_DEFAULTS` array; "Save" (or immediate-on-rebind,
  decide during planning which matches this framework's other settings UX
  better) calls `keybinds:server:setOverride`/`-clearOverride`. Action
  metadata (label/description/category) needed for display beyond the key
  itself comes from `ActionService.getAll()`'s `options`
  (`label`/`description` already exist there; `category` is a new
  convention this plugin introduces via `options.category`, same
  unenforced-convention pattern as `default_key`) — actions that don't
  declare a `category` fall into an "Other" bucket rather than being
  hidden.
- **Dev-debug trigger**: `DevHudHelper.vue` gains a button posting a
  simulated `keybinds:client:open`-equivalent `window.postMessage`, same
  pattern as the phone's dock-toggle dev button, so the page is reachable
  in browser-only dev preview without a running FiveM client.

## Migration path for existing default-key callers

`oblsk_phone`'s `ActionService.register('phone:toggle-dock', handler, {label = 'Toggle phone dock'})`
(no key assigned today — it's bound via the dev-debug panel only, per this
session's earlier work) is unaffected either way; it simply gains an
optional `default_key` if one is ever wanted. No other current caller uses
`KeybindService.registerGlobal`/`registerPlayer` (grepped: zero hits outside
`KeybindService.lua` itself and its test file), so the removal has no other
call sites to migrate.

## Testing

- Server: rewrite `core/tests/keybind_service_spec.lua` (or wherever the
  current coverage lives — confirm exact path during planning) around
  `resolve`/`resolveAll`/`setOverride`/`clearOverride`: default-only
  resolution, account override beats default, character override beats
  account, clearing an override falls back correctly, an action with no
  default and no override resolves to `nil`, `resolve` with `nil`
  `accountId`/`characterId` still returns the default
  (core-without-optional-modules case).
- `oblsk_preferences`: add `PreferenceService.clear` coverage to its
  existing spec file.
- No client-side test file for `oblsk_keybinds`' Vue page (matches this
  repo's existing convention of no browser-DOM tests for Vue components) —
  correctness verified manually via dev preview (the `DevHudHelper` trigger
  above) plus the existing `npm run build` type-check gate.

## Out of scope

- Pause-menu integration (no pause-menu plugin exists in this framework
  yet) — `keybinds:open` is reachable only via a bound key or the dev
  panel for now, same as any other action.
- Conflict *prevention* (blocking a rebind that collides with another
  action's key) — informational flagging only, per the "multiple actions
  per key allowed" decision above.
- Per-device/controller bindings (gamepad, etc.) — keyboard only, matching
  the design reference and this framework's current scope.
