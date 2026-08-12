# Keybind Layering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `KeybindService`'s per-FiveM-identifier storage with a
three-tier resolution model (action-declared default → account override →
character override, one key per action per tier), and ship a standalone
`oblsk_keybinds` plugin with a rebind settings screen.

**Architecture:** `KeybindService` (core) resolves a key purely from
`actions.options.default_key` plus `oblsk_preferences`' existing
`PreferenceService` (account/character key/value rows, `keybind:<actionId>`),
reusing its `getMerged` precedence rather than reimplementing it. The old
`keybinds` table and its per-identifier API are dropped. A new UI-only
plugin, `oblsk_keybinds`, ports the design reference's Key Bindings screen
against this API.

**Tech Stack:** Lua 5.4 (FXServer server/client), Vue 3 + Tailwind (NUI),
the framework's own ORM/QueryBuilder, `lua5.4` for unit tests.

## Global Constraints

- One key per action per tier — no alt-key slot anywhere in this feature.
- Multiple actions may resolve to the same key; this is never blocked, only
  flagged informationally in the UI.
- `KeybindService` takes `accountId`/`characterId` as plain parameters and
  never imports `oblsk_characters`/`oblsk_accounts` — same no-hard-dependency
  shape `PreferenceService` already uses. Any lookup from a player `source`
  to those ids happens in the caller (`syncToClient`), guarded so a server
  without those modules installed still resolves default-only keybinds.
- `oblsk_keybinds` never takes an `ownerId`/scope from the client for
  `setOverride`/`clearOverride` calls — the server resolves the requesting
  player's own account/character ids itself, so a player can never write
  another player's override.
- Every new/changed Lua file must pass `luac5.4 -p` and this repo's existing
  test files must keep passing.
- See `docs/superpowers/specs/2026-08-13-keybind-layering-design.md` for the
  full rationale behind every choice below.

---

### Task 1: `PreferenceService.clear` (oblsk_preferences)

**Files:**
- Modify: `server/services/PreferenceService.lua`
- Test: `tests/preference_service_spec.lua`

**Interfaces:**
- Produces: `PreferenceService.clear(ownerType, ownerId, key)` — deletes the
  matching row if one exists (no-op if not). Used by Task 2's
  `KeybindService.clearOverride`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/preference_service_spec.lua`, in a new section after the
`getMerged` tests (before the `Runner` section):

```lua
--------------------------------------------------------------------------------
-- clear
--------------------------------------------------------------------------------

test('clear: removes an existing row', function()
    withFakeDb(function(tables)
        PreferenceService.set('account', 1, 'hud:notifications:enabled', false)
        PreferenceService.clear('account', 1, 'hud:notifications:enabled')
        eq(#tables.preferences, 0)
        eq(PreferenceService.get('account', 1, 'hud:notifications:enabled'), nil)
    end)
end)

test('clear: is a no-op when no row exists', function()
    withFakeDb(function(tables)
        PreferenceService.clear('account', 1, 'hud:never-set:enabled')
        eq(#tables.preferences, 0)
    end)
end)

test('clear: only removes the matching owner/key, not siblings', function()
    withFakeDb(function(tables)
        PreferenceService.set('account', 1, 'hud:notifications:enabled', false)
        PreferenceService.set('account', 2, 'hud:notifications:enabled', false)
        PreferenceService.set('account', 1, 'hud:other:enabled', true)

        PreferenceService.clear('account', 1, 'hud:notifications:enabled')

        eq(#tables.preferences, 2)
        eq(PreferenceService.get('account', 2, 'hud:notifications:enabled'), false)
        eq(PreferenceService.get('account', 1, 'hud:other:enabled'), true)
    end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua5.4 tests/preference_service_spec.lua` (from `oblsk_preferences`'s
own repo root)
Expected: FAIL — `attempt to call a nil value (field 'clear')`

- [ ] **Step 3: Implement `PreferenceService.clear`**

In `server/services/PreferenceService.lua`, add after `PreferenceService.get`:

```lua
--- @param ownerType string 'account'|'character'
--- @param ownerId number
--- @param key string
function PreferenceService.clear(ownerType, ownerId, key)
    local existing = QueryBuilder.new('preferences')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('key', key):firstSync()
    if existing then
        QueryBuilder.new('preferences'):where('id', existing.id):delete()
    end
end
```

Check `tests/support/fake_query_builder.lua`'s fake supports `:delete()`
(the same fake `oblsk_preferences` already uses for `set`/`get`) — if it
doesn't yet, add a minimal `delete()` that removes the matching row(s) from
the in-memory table, following the same pattern as its existing
`update`/`insert` implementations.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua5.4 tests/preference_service_spec.lua`
Expected: PASS, all tests green

- [ ] **Step 5: Commit**

```bash
git add server/services/PreferenceService.lua tests/preference_service_spec.lua tests/support/fake_query_builder.lua
git commit -m "feat: add PreferenceService.clear"
```

---

### Task 2: `KeybindService` server rewrite (core)

**Files:**
- Modify: `core/server/Services/KeybindService.lua`
- Modify: `core/server/bootstrap.lua` (give `use_interaction` a default key)
- Delete: `core/server/database/seeders/DefaultKeybindsSeeder.lua`
- Create: `core/server/database/migrations/2026_08_13_000000_drop_keybinds_table.lua`
- Test: `tests/keybind_service_spec.lua` (new)

**Interfaces:**
- Consumes: `PreferenceService.get/set/clear(ownerType, ownerId, key)` (Task 1),
  `ActionService.getAll()` / `.exists(actionId)` / `.execute(source, actionId, data)`
  (unchanged, existing), `PolicyService` (unchanged, via `ActionService.execute`).
- Produces: `KeybindService.resolve(actionId, accountId, characterId) -> key|nil`,
  `KeybindService.resolveAll(accountId, characterId) -> {actionId -> key}`,
  `KeybindService.setOverride(scope, ownerId, actionId, key)`,
  `KeybindService.clearOverride(scope, ownerId, actionId)`,
  `KeybindService.syncToClient(source)` (signature unchanged, behavior
  rewritten). Task 3 (client) consumes `resolveAll`'s payload shape via the
  `core:server:keybinds-sync` event. Task 4 (`oblsk_keybinds` server) calls
  `resolveAll`/`setOverride`/`clearOverride` directly.

- [ ] **Step 1: Write the migration to drop `keybinds`**

Create `core/server/database/migrations/2026_08_13_000000_drop_keybinds_table.lua`:

```lua
--- Migration: Drop keybinds table — replaced by the default/account/character
--- resolution model (actions.options.default_key + oblsk_preferences rows).
--- See docs/superpowers/specs/2026-08-13-keybind-layering-design.md.
return {
    up = function()
        Schema.drop('keybinds')
        print('[Migration] Dropped keybinds table')
    end,

    down = function()
        Schema.create('keybinds', function(table)
            table:id()
            table:string('key_code', 50)
            table:string('action_id', 100)
            table:integer('action_id_int'):nullable()
            table:json('data'):nullable()
            table:boolean('is_global'):default(0):nullable()
            table:string('player_identifier', 100):nullable()
            table:boolean('enabled'):default(1):nullable()
            table:timestamps()

            table:index({'key_code'})
            table:index({'player_identifier'})
            table:index({'is_global'})
        end)
        print('[Migration] Recreated keybinds table')
    end
}
```

- [ ] **Step 2: Delete the old seeder**

```bash
git rm core/server/database/seeders/DefaultKeybindsSeeder.lua
```

It seeded `E -> use_interaction` into the now-dropped table; Step 5 below
moves that default onto the action registration itself.

- [ ] **Step 3: Write the failing tests**

Create `tests/keybind_service_spec.lua`:

```lua
--- Unit tests for the server-side KeybindService's resolution model.
--- Run from the repository root:  lua5.4 tests/keybind_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

_G.Obelisk = _G.Obelisk or { onServer = function() end, emitClient = function() end }

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

--- Fresh ActionService + PreferenceService + KeybindService against a fake
--- DB, with one pre-registered action carrying a default_key.
local function freshServices(tables)
    _G.QueryBuilder = makeFakeQueryBuilderModule(tables or {})
    _G.Database = { isReady = function() return true end }
    dofile(ROOT .. '/core/server/Services/ActionService.lua')
    dofile(ROOT .. '/modules/oblsk_preferences/server/services/PreferenceService.lua')
    local KeybindService = dofile(ROOT .. '/core/server/Services/KeybindService.lua')

    ActionService.register('vehicle:seatbelt', function() end, {label = 'Seatbelt', default_key = 'B'})
    ActionService.register('interaction:point', function() end, {label = 'Point', default_key = 'B'})
    ActionService.register('phone:toggle-dock', function() end, {label = 'Toggle phone dock'})

    return KeybindService
end

test('resolve: returns the action default when no override exists', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    eq(KeybindService.resolve('vehicle:seatbelt', nil, nil), 'B')
end)

test('resolve: returns nil for an action with no default and no override', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    eq(KeybindService.resolve('phone:toggle-dock', nil, nil), nil)
end)

test('resolve: account override beats the default', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    KeybindService.setOverride('account', 1, 'vehicle:seatbelt', 'J')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, nil), 'J')
end)

test('resolve: character override beats account override', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    KeybindService.setOverride('account', 1, 'vehicle:seatbelt', 'J')
    KeybindService.setOverride('character', 5, 'vehicle:seatbelt', 'K')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, 5), 'K')
end)

test('resolve: nil accountId/characterId still resolves the default (no optional modules installed)', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    eq(KeybindService.resolve('vehicle:seatbelt', nil, nil), 'B')
end)

test('clearOverride: falls resolution back to the tier below', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    KeybindService.setOverride('account', 1, 'vehicle:seatbelt', 'J')
    KeybindService.setOverride('character', 5, 'vehicle:seatbelt', 'K')

    KeybindService.clearOverride('character', 5, 'vehicle:seatbelt')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, 5), 'J')

    KeybindService.clearOverride('account', 1, 'vehicle:seatbelt')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, 5), 'B')
end)

test('resolveAll: returns every registered action, sharing a key across two actions is not an error', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    local all = KeybindService.resolveAll(nil, nil)
    eq(all['vehicle:seatbelt'], 'B')
    eq(all['interaction:point'], 'B')
    eq(all['phone:toggle-dock'], nil)
end)

test('setOverride: rejects an unknown scope', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    local ok = pcall(KeybindService.setOverride, 'vehicle', 1, 'vehicle:seatbelt', 'J')
    eq(ok, false)
end)

print('Running KeybindService unit tests\n')
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

- [ ] **Step 4: Run the tests to verify they fail**

Run: `lua5.4 tests/keybind_service_spec.lua`
Expected: FAIL — `KeybindService.resolve` doesn't exist yet

- [ ] **Step 5: Rewrite `KeybindService.lua`**

Replace `core/server/Services/KeybindService.lua` entirely with:

```lua
--- KeybindService - resolves the key bound to an action via a three-tier
--- model: action-declared default -> account override -> character
--- override. Overrides are stored in oblsk_preferences (`keybind:<actionId>`
--- preference keys); the default lives on `actions.options.default_key`,
--- set by whichever plugin calls ActionService.register. See
--- docs/superpowers/specs/2026-08-13-keybind-layering-design.md.
KeybindService = {}

local VALID_SCOPES = { account = true, character = true }

--- @param actionId string
--- @param accountId number|nil
--- @param characterId number|nil
--- @return string|nil key
function KeybindService.resolve(actionId, accountId, characterId)
    local action = ActionService.get(actionId)
    local key = action and action.options and action.options.default_key or nil

    if accountId then
        local override = PreferenceService.get('account', accountId, 'keybind:' .. actionId)
        if override ~= nil then key = override end
    end

    if characterId then
        local override = PreferenceService.get('character', characterId, 'keybind:' .. actionId)
        if override ~= nil then key = override end
    end

    return key
end

--- @param accountId number|nil
--- @param characterId number|nil
--- @return table {actionId -> key}
function KeybindService.resolveAll(accountId, characterId)
    local resolved = {}
    for actionId in pairs(ActionService.getAll()) do
        resolved[actionId] = KeybindService.resolve(actionId, accountId, characterId)
    end
    return resolved
end

--- @param scope string 'account'|'character'
--- @param ownerId number
--- @param actionId string
--- @param key string
function KeybindService.setOverride(scope, ownerId, actionId, key)
    if not VALID_SCOPES[scope] then
        error('KeybindService.setOverride: invalid scope "' .. tostring(scope) .. '"')
    end
    PreferenceService.set(scope, ownerId, 'keybind:' .. actionId, key)
end

--- @param scope string 'account'|'character'
--- @param ownerId number
--- @param actionId string
function KeybindService.clearOverride(scope, ownerId, actionId)
    if not VALID_SCOPES[scope] then
        error('KeybindService.clearOverride: invalid scope "' .. tostring(scope) .. '"')
    end
    PreferenceService.clear(scope, ownerId, 'keybind:' .. actionId)
end

--- Resolve source -> accountId/characterId softly: AccountService/
--- CharacterService are optional modules, so a core-only server (or one
--- mid-boot before they've loaded) still resolves default-only keybinds.
--- @param source number
--- @return number|nil accountId, number|nil characterId
local function resolveIdsForSource(source)
    local accountId = AccountService and AccountService.getAccountId(source) or nil
    local characterId = CharacterService and CharacterService.getActiveCharacterId(source) or nil
    return accountId, characterId
end

--- Send this player's fully-resolved keybind map to their client.
--- @param source number
function KeybindService.syncToClient(source)
    local accountId, characterId = resolveIdsForSource(source)
    local resolved = KeybindService.resolveAll(accountId, characterId)
    Obelisk.emitClient('core:server:keybinds-sync', source, resolved)
end

--- Client pressed a key already known (client-side) to map to this action.
--- @param source number
--- @param actionId string
function KeybindService.handlePress(source, actionId)
    if not ActionService.exists(actionId) then
        print('[KeybindService] Error: Action not found: ' .. tostring(actionId))
        return
    end
    ActionService.execute(source, actionId, {})
end

--- Net event: Client requests keybind sync
Obelisk.onServer('core:client:keybinds-requestSync', function()
    local source = source
    KeybindService.syncToClient(source)
end)

--- Net event: Client pressed a keybind
Obelisk.onServer('core:client:keybinds-pressed', function(actionId)
    local source = source
    KeybindService.handlePress(source, actionId)
end)

--- On player connect, sync keybinds
AddEventHandler('playerJoining', function()
    local source = source
    SetTimeout(1000, function()
        KeybindService.syncToClient(source)
    end)
end)

return KeybindService
```

Note the `core:client:keybinds-pressed` payload is simplified from
`(actionId, keybindData)` to just `actionId` — `resolveAll`'s map is
string-`actionId`-keyed, so the client already has the string id directly
and the old numeric-dbId round trip (`ActionService.getDbId`/`resolveDbId`)
serves no purpose here anymore. `ActionService.getDbId`/`resolveDbId`
themselves are untouched (still used elsewhere, e.g. `actions` table
bookkeeping) — only this one call site stops using them.

- [ ] **Step 6: Give `use_interaction` its default key**

In `core/server/bootstrap.lua`, update the existing registration (around
line 161):

```lua
    ActionService.register('use_interaction', function(source, data)
        -- This is handled by InteractionService
        print('[Action] use_interaction called by player ' .. source)
    end, { label = 'Interact', default_key = 'E' })
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `lua5.4 tests/keybind_service_spec.lua`
Expected: PASS, all tests green

Also run the full existing suite to confirm nothing else broke:
Run: `for f in tests/*_spec.lua; do lua5.4 "$f" || echo "FAILED: $f"; done`
Expected: every file passes

- [ ] **Step 8: Syntax-check every changed file**

Run: `luac5.4 -p core/server/Services/KeybindService.lua core/server/bootstrap.lua core/server/database/migrations/2026_08_13_000000_drop_keybinds_table.lua`
Expected: no output (success)

- [ ] **Step 9: Commit**

```bash
git add core/server/Services/KeybindService.lua core/server/bootstrap.lua \
        core/server/database/migrations/2026_08_13_000000_drop_keybinds_table.lua \
        tests/keybind_service_spec.lua
git rm core/server/database/seeders/DefaultKeybindsSeeder.lua
git commit -m "feat: rewrite KeybindService around default/account/character resolution"
```

---

### Task 3: `KeybindService` client rewrite (core)

**Files:**
- Modify: `core/client/Services/KeybindService.lua`

**Interfaces:**
- Consumes: `core:server:keybinds-sync` payload, now `{actionId -> key}`
  (Task 2) instead of an array of `{key_code, action_id, data}` rows.
- Produces: unchanged public surface (`KeybindService.requestSync`,
  `KeybindService.checkKeyPress`), rewired internals.

No test file — this file only exists as FiveM client Lua (natives like
`IsControlJustPressed`), unit-testable only via the existing `fivem_stubs.lua`
stand-ins used for *server* specs; there's no client spec convention
anywhere else in this repo either. Verified by `luac5.4 -p` plus manual
in-game/dev-preview check.

- [ ] **Step 1: Rewrite the file**

Replace `core/client/Services/KeybindService.lua` entirely with:

```lua
--- Client KeybindService - keeps a local {keyCode -> [actionId]} map in
--- sync with the server's resolved keybinds and dispatches key presses.
KeybindService = {}
KeybindService.keyMap = {} -- {keyCode -> actionId[]}

--- Sync keybinds from server: resolved is {actionId -> key}
Obelisk.onClient('core:server:keybinds-sync', function(resolved)
    local keyMap = {}
    local count = 0
    for actionId, key in pairs(resolved) do
        if key then
            keyMap[key] = keyMap[key] or {}
            table.insert(keyMap[key], actionId)
            count = count + 1
        end
    end
    KeybindService.keyMap = keyMap

    print('[KeybindService] Loaded ' .. count .. ' resolved keybinds')
end)

--- Request keybinds from server
function KeybindService.requestSync()
    Obelisk.emitServer('core:client:keybinds-requestSync')
end

--- Server told us a keybind changed (an override was set/cleared) elsewhere;
--- re-request our own list so it reflects the change.
Obelisk.onClient('core:server:keybinds-requestSync', function()
    KeybindService.requestSync()
end)

--- Check if key is pressed and trigger every action bound to it. More than
--- one action can share a key (e.g. B for both seatbelt and point) -- all
--- of them fire, there's no first-match-wins behavior.
--- @param keyCode string
function KeybindService.checkKeyPress(keyCode)
    local actionIds = KeybindService.keyMap[keyCode]
    if not actionIds then return end

    for _, actionId in ipairs(actionIds) do
        Obelisk.emitServer('core:client:keybinds-pressed', actionId)
    end
end

--- Main thread to monitor key presses
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        local commonKeys = {
            ['E'] = 38,      -- E key
            ['F'] = 23,      -- F key
            ['G'] = 47,      -- G key
            ['X'] = 73,      -- X key
            ['Y'] = 246,     -- Y key
            ['U'] = 303,     -- U key
            ['SPACE'] = 22,  -- Space
            ['ENTER'] = 18,  -- Enter
            ['ESC'] = 322    -- Escape
        }

        for keyName, controlId in pairs(commonKeys) do
            if IsControlJustPressed(0, controlId) then
                KeybindService.checkKeyPress(keyName)
            end
        end
    end
end)

--- Request keybinds on script start
Citizen.CreateThread(function()
    Wait(2000) -- Wait for player to fully load
    KeybindService.requestSync()
end)

return KeybindService
```

The `commonKeys`/`IsControlJustPressed` polling table is carried over
unchanged from the current file — expanding the physical-key coverage
(beyond this fixed set) is out of scope for this plan, matching the
existing behavior exactly.

- [ ] **Step 2: Syntax-check**

Run: `luac5.4 -p core/client/Services/KeybindService.lua`
Expected: no output (success)

- [ ] **Step 3: Commit**

```bash
git add core/client/Services/KeybindService.lua
git commit -m "feat: rewrite client KeybindService for the resolved-map sync payload"
```

---

### Task 4: `oblsk_keybinds` plugin scaffold + server/client (new repo)

**Files:**
- Create (new plugin, via CLI): `fxmanifest.lua`, `shared/config.lua`, etc.
  (whatever `obelisk make:plugin` generates)
- Create: `server/main.lua`
- Create: `client/main.lua`

**Interfaces:**
- Consumes: `KeybindService.resolveAll/setOverride/clearOverride` (Task 2),
  `ActionService.register/getAll` (existing), `AccountService.getAccountId`/
  `CharacterService.getActiveCharacterId` (existing, soft-optional — same
  guard pattern as `KeybindService.syncToClient`).
- Produces: NUI-facing net events `keybinds:server:resolveAll`,
  `keybinds:server:setOverride`, `keybinds:server:clearOverride`, and the
  open trigger `keybinds:client:open` — consumed by Task 5's Vue page.

- [ ] **Step 1: Scaffold the plugin**

From `core/`'s repo root, on the host:

```bash
obelisk make:plugin Keybinds
```

Answer the prompts: description `"Key bindings settings screen"`; accept
whatever else defaults to. Confirm the generated folder is
`plugins/oblsk_keybinds/` and matches the shape of an existing plugin
(compare against `plugins/oblsk_progressbar/` — pick the smallest existing
plugin as the closest structural reference, since this plugin has no
database table of its own).

- [ ] **Step 2: Write `server/main.lua`**

```lua
--- oblsk_keybinds server: registers the settings-screen open action and the
--- three NUI-facing round trips the Vue page needs. All account/character
--- scoping is resolved server-side from `source` -- the client never sends
--- an ownerId, so a player can only ever read/write their own overrides.
--- See docs/superpowers/specs/2026-08-13-keybind-layering-design.md.

--- @param source number
--- @return number|nil accountId, number|nil characterId
local function resolveIdsForSource(source)
    local accountId = AccountService and AccountService.getAccountId(source) or nil
    local characterId = CharacterService and CharacterService.getActiveCharacterId(source) or nil
    return accountId, characterId
end

ActionService.register('keybinds:open', function(source)
    Obelisk.emitClient('keybinds:client:open', source)
end, { label = 'Key Bindings' })

Obelisk.onServer('keybinds:server:resolveAll', function()
    local source = source
    local accountId, characterId = resolveIdsForSource(source)
    local resolved = KeybindService.resolveAll(accountId, characterId)

    local actions = {}
    for actionId, entry in pairs(ActionService.getAll()) do
        actions[actionId] = {
            label = entry.options and entry.options.label or actionId,
            description = entry.options and entry.options.description or nil,
            category = entry.options and entry.options.category or nil,
            defaultKey = entry.options and entry.options.default_key or nil,
        }
    end

    Obelisk.emitClient('keybinds:client:resolveAll', source, { resolved = resolved, actions = actions })
end)

Obelisk.onServer('keybinds:server:setOverride', function(scope, actionId, key)
    local source = source
    local accountId, characterId = resolveIdsForSource(source)
    local ownerId = scope == 'character' and characterId or accountId
    if not ownerId then
        NotificationService.error(source, 'Keybinds', 'No ' .. scope .. ' to bind this to yet.')
        return
    end
    KeybindService.setOverride(scope, ownerId, actionId, key)
    NotificationService.success(source, 'Keybinds', 'Bound to ' .. key)
end)

Obelisk.onServer('keybinds:server:clearOverride', function(scope, actionId)
    local source = source
    local accountId, characterId = resolveIdsForSource(source)
    local ownerId = scope == 'character' and characterId or accountId
    if not ownerId then return end
    KeybindService.clearOverride(scope, ownerId, actionId)
end)
```

- [ ] **Step 3: Write `client/main.lua`**

```lua
--- oblsk_keybinds client: relays the open trigger and every NUI round trip
--- straight through to the server, following oblsk_garage/client/main.lua's
--- established relay-pair pattern.

Obelisk.onClient('keybinds:client:open', function()
    WebView.showGlobalElement('keybinds')
    WebView.focus()
end)

WebView.on('keybinds:client:resolveAll', function()
    Obelisk.emitServer('keybinds:server:resolveAll')
end)

Obelisk.onClient('keybinds:client:resolveAll', function(data)
    WebView.emit('keybinds:client:resolveAll', data)
end)

WebView.on('keybinds:client:setOverride', function(data)
    Obelisk.emitServer('keybinds:server:setOverride', data.scope, data.actionId, data.key)
end)

WebView.on('keybinds:client:clearOverride', function(data)
    Obelisk.emitServer('keybinds:server:clearOverride', data.scope, data.actionId)
end)

WebView.on('keybinds:client:close', function()
    WebView.hideGlobalElement('keybinds')
end)
```

`WebView.on` registers a `RegisterNUICallback` (the Vue side calls these via
`Obelisk.emit`, one-way outbound per `core/web/src/obelisk.js` — see the
`WebView.emit`/`Obelisk.on` round trip below in Task 5 for how the response
comes back). `Obelisk.onClient('keybinds:client:resolveAll', ...)` receives
the server's actual answer and pushes it into the webview via `WebView.emit`,
matching the two-hop shape `core:client:webview-*` already uses elsewhere in
this file's sibling services.

- [ ] **Step 4: Syntax-check**

Run: `luac5.4 -p plugins/oblsk_keybinds/server/main.lua plugins/oblsk_keybinds/client/main.lua`
Expected: no output (success)

- [ ] **Step 5: Commit**

```bash
cd plugins/oblsk_keybinds
git add -A
git commit -m "feat: scaffold oblsk_keybinds, server/client NUI bridge"
```

---

### Task 5: `oblsk_keybinds` Vue settings screen

**Files:**
- Create: `web/globalElements.js`
- Create: `web/Icon.vue`
- Create: `web/Keybinds.vue`

**Interfaces:**
- Consumes: `keybinds:client:resolveAll` (fired by `Obelisk.emit` from Task
  4's client, payload `{ resolved: {actionId -> key}, actions: {actionId ->
  {label, description, category, defaultKey}} }`), NUI callbacks
  `keybinds:client:resolveAll`/`-setOverride`/`-clearOverride`/`-close`
  (Task 4).
- Produces: registers itself as the `keybinds` global element (`defaultVisible: false`),
  consumed by `WebView.showGlobalElement('keybinds')` (Task 4).

- [ ] **Step 1: `web/globalElements.js`**

```js
import Keybinds from './Keybinds.vue'

export default [
  { name: 'keybinds', component: Keybinds, defaultVisible: false }
]
```

- [ ] **Step 2: `web/Icon.vue`**

A small, self-contained icon set (this plugin doesn't import another
plugin's `Icon.vue` — each plugin repo is independently deployable) with
just the glyphs this page needs, same wrapper shape as
`oblsk_phone/web/phone/Icon.vue`:

```vue
<template>
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    :stroke-width="sw"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <component :is="shape.tag" v-for="(shape, i) in shapes" :key="i" v-bind="shape.attrs" />
  </svg>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  name: { type: String, required: true },
  size: { type: [Number, String], default: 16 },
  sw: { type: [Number, String], default: 1.6 }
})

const ICONS = {
  hashtag: [{ tag: 'path', attrs: { d: 'M4 9h16M4 15h16M10 3 8 21M16 3l-2 18' } }],
  search: [
    { tag: 'circle', attrs: { cx: 10.5, cy: 10.5, r: 6.5 } },
    { tag: 'path', attrs: { d: 'm20 20-4.4-4.4' } }
  ],
  refresh: [
    { tag: 'path', attrs: { d: 'M3 12a9 9 0 0 1 9-9c2.4 0 4.6.9 6.2 2.4M21 3v6h-6' } },
    { tag: 'path', attrs: { d: 'M21 12a9 9 0 0 1-9 9c-2.4 0-4.6-.9-6.2-2.4M3 21v-6h6' } }
  ],
  close: [{ tag: 'path', attrs: { d: 'M18 6 6 18M6 6l12 12' } }]
}

const shapes = computed(() => ICONS[props.name] || ICONS.hashtag)
</script>
```

- [ ] **Step 3: `web/Keybinds.vue`**

Ports `src/proto/keybinds.jsx`'s layout (design reference,
`019de78f-9966-77d9-90c0-73b12ead46cd`) down to a single rebind slot per
action (no alt), real data instead of the mock `KB_DEFAULTS`, and no
eviction-on-conflict (shared keys are flagged, never stolen):

```vue
<template>
  <div class="absolute inset-0 flex flex-col" style="padding: 3vh 3vw">
    <div class="flex-1 min-h-0 rounded-2xl border border-white/12 bg-[#0d1012] shadow-2xl overflow-hidden flex flex-col text-white">
      <div class="h-14 px-5 flex items-center justify-between border-b border-white/8 shrink-0">
        <div class="flex items-center gap-2.5">
          <div class="w-8 h-8 rounded-lg grid place-items-center" style="background: var(--ob-accent)">
            <Icon name="hashtag" :size="16" class="text-black" />
          </div>
          <div>
            <div class="text-[14px] font-semibold leading-tight">Key bindings</div>
            <div class="font-mono text-[9px] text-white/35">SETTINGS · CONTROLS · {{ rows.length }} ACTIONS</div>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span v-if="sharedKeys.size" class="font-mono text-[9.5px] px-2 py-1 rounded border border-amber-400/30 bg-amber-400/10 text-amber-300">
            {{ sharedKeys.size }} SHARED KEY{{ sharedKeys.size > 1 ? 'S' : '' }}
          </span>
          <button class="h-8 px-3 rounded-lg border border-white/12 text-[11.5px] hover:bg-white/8 flex items-center gap-1.5 transition" @click="resetAll">
            <Icon name="refresh" :size="12" /> Reset to defaults
          </button>
          <button class="w-8 h-8 rounded-lg border border-white/12 hover:bg-white/8 grid place-items-center transition" @click="close">
            <Icon name="close" :size="14" />
          </button>
        </div>
      </div>

      <div class="flex-1 min-h-0 grid" style="grid-template-columns: 1fr 420px">
        <div class="flex flex-col min-h-0 border-r border-white/8">
          <div class="p-4 flex items-center gap-3 border-b border-white/8 shrink-0">
            <div class="h-8 flex-1 rounded-lg bg-white/6 border border-white/8 flex items-center gap-2 px-2.5">
              <Icon name="search" :size="12" class="text-white/30 shrink-0" />
              <input v-model="q" placeholder="Search actions" autocomplete="off"
                class="flex-1 min-w-0 bg-transparent outline-none text-[11.5px] placeholder:text-white/30" style="user-select: text" />
            </div>
            <div class="flex gap-1 flex-wrap">
              <button v-for="c in categories" :key="c"
                class="px-2.5 h-7 rounded-lg text-[11.5px] transition"
                :class="cat === c ? 'text-black font-medium' : 'text-white/45 hover:text-white bg-white/5'"
                :style="cat === c ? { background: 'var(--ob-accent)' } : undefined"
                @click="cat = c">{{ c }}</button>
            </div>
          </div>

          <div class="flex-1 overflow-y-auto ob-no-scroll">
            <div v-for="group in groupedRows" :key="group.category">
              <div class="px-5 pt-4 pb-1.5 font-mono text-[9px] tracking-[0.2em] uppercase text-white/28">{{ group.category }}</div>
              <div v-for="row in group.rows" :key="row.actionId"
                class="px-5 py-2.5 flex items-center gap-4 border-b border-white/6 transition"
                :class="hover === row.actionId ? 'bg-white/[0.05]' : ''"
                @mouseenter="hover = row.actionId" @mouseleave="hover = null">
                <div class="min-w-0 flex-1">
                  <div class="text-[12.5px]">{{ row.label }}</div>
                  <div v-if="row.description" class="font-mono text-[9px] text-white/30 mt-0.5">{{ row.description.toUpperCase() }}</div>
                </div>
                <div class="relative">
                  <button
                    class="h-8 min-w-[92px] px-3 rounded-lg border text-[11.5px] transition"
                    :class="bindButtonClass(row)"
                    @click="startListening(row.actionId)">
                    <span class="font-mono">{{ listening === row.actionId ? 'PRESS A KEY' : (row.key || 'UNBOUND') }}</span>
                  </button>
                  <button v-if="row.key && listening !== row.actionId" title="Clear"
                    class="absolute -right-1.5 -top-1.5 w-4 h-4 rounded-full bg-black/80 border border-white/15 text-white/45 hover:text-red-300 grid place-items-center text-[9px] leading-none"
                    @click="clearBinding(row.actionId)">×</button>
                </div>
              </div>
            </div>
            <div v-if="!rows.length" class="p-10 text-center text-[12.5px] text-white/30">No actions match "{{ q }}".</div>
          </div>
        </div>

        <div class="flex flex-col min-h-0">
          <div class="px-5 py-3 border-b border-white/8 flex items-center justify-between shrink-0">
            <span class="font-mono text-[9px] tracking-[0.2em] uppercase text-white/35">Keyboard map</span>
            <span class="font-mono text-[9px] text-white/25">HOVER A KEY OR AN ACTION</span>
          </div>
          <div class="p-5 space-y-1.5 overflow-y-auto ob-no-scroll">
            <div v-for="(row, ri) in KB_ROWS" :key="ri" class="flex gap-1.5">
              <button v-for="k in row" :key="k"
                class="h-9 rounded-md border text-[10px] grid place-items-center transition shrink-0"
                :style="keyStyle(k)"
                :title="keyTitle(k)"
                @mouseenter="onKeyHover(k)" @mouseleave="hover = null">
                <span class="font-mono truncate px-1">{{ k === 'CapsLock' ? 'Caps' : k }}</span>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div v-if="listening" class="absolute inset-0 z-40 grid place-items-center bg-black/70" @pointerdown="listening = null">
      <div class="rounded-2xl border border-white/15 bg-[#0d1012] px-8 py-6 text-center shadow-2xl">
        <div class="font-mono text-[10px] tracking-[0.25em] text-white/35 uppercase">Listening</div>
        <div class="text-[20px] font-semibold mt-2">Press any key</div>
        <div class="text-[11.5px] text-white/40 mt-1">Esc cancels</div>
      </div>
    </div>

    <div v-if="toast" class="absolute left-1/2 -translate-x-1/2 bottom-6 rounded-lg border border-white/12 bg-[#101416] px-4 py-2 text-[12px]">{{ toast }}</div>
  </div>
</template>

<script setup>
// Keybinds.vue — the oblsk_keybinds settings screen, ported from the design
// reference's src/proto/keybinds.jsx down to one rebind slot per action
// (no alt key) with no eviction-on-conflict: shared keys are flagged, never
// stolen. See docs/superpowers/specs/2026-08-13-keybind-layering-design.md.
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import Obelisk from '@/obelisk.js'
import Icon from './Icon.vue'

const KB_ROWS = [
  ['Esc', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
  ['`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 'Backspace'],
  ['Tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', '\\'],
  ['Caps', 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', "'", 'Enter'],
  ['Shift', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/', 'RShift'],
  ['Ctrl', 'Alt', 'Space', 'RAlt', 'RCtrl']
]

// Browser key event -> the label used throughout this UI (matches the
// design reference's kbNameFor exactly, so rebind labels line up with the
// keyboard-map row labels above).
function kbNameFor(e) {
  if (e.code === 'Space') return 'Space'
  if (e.code === 'CapsLock') return 'CapsLock'
  if (e.code.startsWith('Key')) return e.code.slice(3)
  if (e.code.startsWith('Digit')) return e.code.slice(5)
  if (e.code.startsWith('F') && /^F\d+$/.test(e.code)) return e.code
  const map = {
    ShiftLeft: 'Shift', ShiftRight: 'RShift', ControlLeft: 'Ctrl', ControlRight: 'RCtrl',
    AltLeft: 'Alt', AltRight: 'RAlt', Tab: 'Tab', Enter: 'Enter', Backspace: 'Backspace',
    Comma: ',', Period: '.', Slash: '/', Semicolon: ';', Quote: "'", BracketLeft: '[',
    BracketRight: ']', Backslash: '\\', Minus: '-', Equal: '=', Backquote: '`'
  }
  return map[e.code] || null
}

const actions = ref({})   // {actionId -> {label, description, category, defaultKey}}
const resolved = ref({})  // {actionId -> key}, live edits happen here
const q = ref('')
const cat = ref('All')
const hover = ref(null)
const listening = ref(null) // actionId currently capturing a keypress
const toast = ref(null)
let toastTimer = null

function showToast(msg) {
  toast.value = msg
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.value = null }, 1800)
}

const rows = computed(() => {
  const query = q.value.toLowerCase()
  return Object.entries(actions.value)
    .map(([actionId, meta]) => ({
      actionId,
      key: resolved.value[actionId] || null,
      label: meta.label,
      description: meta.description,
      category: meta.category || 'Other'
    }))
    .filter((row) => cat.value === 'All' || row.category === cat.value)
    .filter((row) => (row.label + (row.description || '')).toLowerCase().includes(query))
})

const categories = computed(() => {
  const set = new Set(['All'])
  for (const meta of Object.values(actions.value)) set.add(meta.category || 'Other')
  return Array.from(set)
})

const groupedRows = computed(() => {
  const byCategory = new Map()
  for (const row of rows.value) {
    if (!byCategory.has(row.category)) byCategory.set(row.category, [])
    byCategory.get(row.category).push(row)
  }
  return Array.from(byCategory.entries()).map(([category, categoryRows]) => ({ category, rows: categoryRows }))
})

// key -> actionId[], used for the keyboard map and shared-key flagging.
const boundBy = computed(() => {
  const map = {}
  for (const [actionId, key] of Object.entries(resolved.value)) {
    if (!key) continue
    map[key] = map[key] || []
    map[key].push(actionId)
  }
  return map
})

const sharedKeys = computed(() => {
  const set = new Set()
  for (const [key, actionIds] of Object.entries(boundBy.value)) {
    if (actionIds.length > 1) set.add(key)
  }
  return set
})

function bindButtonClass(row) {
  if (listening.value === row.actionId) return 'border-white/60 bg-white/10 animate-pulse'
  if (row.key && sharedKeys.value.has(row.key)) return 'border-amber-400/40 bg-amber-400/10 text-amber-200'
  if (row.key) return 'border-white/14 bg-white/[0.06] hover:bg-white/12'
  return 'border-dashed border-white/12 text-white/25 hover:text-white/60'
}

function keyStyle(k) {
  const boundActionIds = boundBy.value[k]
  const isHoveredKey = hover.value && resolved.value[hover.value] === k
  const shared = sharedKeys.value.has(k)
  return {
    borderColor: isHoveredKey ? 'var(--ob-accent)' : shared ? 'rgba(251,191,36,.5)' : boundActionIds ? 'rgba(255,255,255,.22)' : 'rgba(255,255,255,.07)',
    background: isHoveredKey ? 'color-mix(in oklab, var(--ob-accent) 30%, transparent)'
      : shared ? 'rgba(251,191,36,.14)'
      : boundActionIds ? 'rgba(255,255,255,.09)' : 'rgba(255,255,255,.02)',
    color: isHoveredKey ? '#fff' : boundActionIds ? 'rgba(255,255,255,.8)' : 'rgba(255,255,255,.25)'
  }
}

function keyTitle(k) {
  const boundActionIds = boundBy.value[k]
  if (!boundActionIds) return 'Unassigned'
  return boundActionIds.map((id) => actions.value[id]?.label || id).join(' · ')
}

function onKeyHover(k) {
  const boundActionIds = boundBy.value[k]
  hover.value = boundActionIds ? boundActionIds[0] : null
}

function startListening(actionId) {
  listening.value = actionId
}

function clearBinding(actionId) {
  const wasAccount = !resolved.value[actionId]
  delete resolved.value[actionId]
  resolved.value = { ...resolved.value }
  Obelisk.emit('keybinds:client:clearOverride', { scope: 'character', actionId })
  Obelisk.emit('keybinds:client:clearOverride', { scope: 'account', actionId })
  showToast('Cleared')
}

function assignKey(actionId, key) {
  resolved.value = { ...resolved.value, [actionId]: key }
  // Character scope by default -- falls back to account server-side if the
  // player has no active character (see oblsk_keybinds/server/main.lua).
  Obelisk.emit('keybinds:client:setOverride', { scope: 'character', actionId, key })
  showToast(`Bound to ${key}`)
}

function resetAll() {
  for (const actionId of Object.keys(actions.value)) {
    Obelisk.emit('keybinds:client:clearOverride', { scope: 'character', actionId })
    Obelisk.emit('keybinds:client:clearOverride', { scope: 'account', actionId })
  }
  refresh()
  showToast('Restored defaults')
}

function close() {
  Obelisk.emit('keybinds:client:close', {})
}

function handleResolveAll(data) {
  actions.value = data.actions || {}
  resolved.value = data.resolved || {}
}

function refresh() {
  Obelisk.emit('keybinds:client:resolveAll', {})
}

function onKeydown(e) {
  if (!listening.value) return
  e.preventDefault()
  e.stopPropagation()
  if (e.code === 'Escape') { listening.value = null; return }
  const name = kbNameFor(e)
  if (!name) { showToast('That key can’t be bound'); return }
  assignKey(listening.value, name)
  listening.value = null
}

onMounted(() => {
  Obelisk.on('keybinds:client:resolveAll', handleResolveAll)
  window.addEventListener('keydown', onKeydown, true)
  refresh()
})

onBeforeUnmount(() => {
  Obelisk.off('keybinds:client:resolveAll', handleResolveAll)
  window.removeEventListener('keydown', onKeydown, true)
})
</script>
```

- [ ] **Step 4: Build check**

Run (from `oblsk_keybinds`'s own `web/` if it has an independent Vite
config, or via whatever this repo's convention is for plugin web builds —
confirm against `oblsk_phone/web`'s `package.json` for the exact command):
`npm run build`
Expected: succeeds, no Vue/Tailwind compile errors

- [ ] **Step 5: Manual dev-preview check**

With `core/web`'s dev server running and Task 6's dev-debug trigger wired
up (next task), open the Keybinds page and confirm: the action list
renders, search/category filtering works, clicking a bind button enters
listening mode, pressing a key assigns it and shows a toast, the keyboard
map highlights that key, rebinding two different actions to the same key
shows the amber shared-key state on both without evicting either.

- [ ] **Step 6: Commit**

```bash
cd plugins/oblsk_keybinds
git add web/globalElements.js web/Icon.vue web/Keybinds.vue
git commit -m "feat: Keybinds.vue settings screen"
```

---

### Task 6: Dev-debug trigger (core)

**Files:**
- Modify: `web/src/pages/DevHudHelper.vue`

**Interfaces:**
- Consumes: none new (reuses the existing `postToPhone`-style
  `window.postMessage` simulation this file already established for the
  phone dock toggle).
- Produces: a button that opens the Keybinds page in browser-only dev
  preview, the same way the existing "Toggle phone dock" button works.

- [ ] **Step 1: Add the button**

In `web/src/pages/DevHudHelper.vue`, add a new section below the existing
"Phone debug" block (following that block's exact structure):

```html
      <div class="mt-6 pt-4 border-t border-black/15">
        <div class="text-xs tracking-[0.2em] uppercase text-black/50 mb-2">Keybinds debug</div>
        <div class="flex flex-wrap gap-2">
          <button class="px-3 py-1.5 rounded border border-black/20 hover:bg-black/10 text-xs" @click="openKeybinds">Open key bindings</button>
        </div>
      </div>
```

And in `<script setup>`, alongside the existing `postToPhone` helper:

```js
function openKeybinds() {
  window.postMessage({ eventname: 'keybinds:client:open', args: [{}] }, '*')
}
```

`oblsk_keybinds`'s Vue side doesn't listen for `keybinds:client:open`
directly (that event only exists between the real client Lua and the
global-elements registry in production) — in dev preview, showing the page
goes through the same `toggleGlobalElement`/`showGlobalElement` NUI events
`App.vue`'s registry already answers, so this button should instead post
`core:client:webview-showGlobalElement` with `{ name: 'keybinds' }`,
matching exactly how the existing "phone" checkbox in this same file's
`entries` list already shows/hides a global element — reuse that exact
mechanism rather than inventing a second one:

```js
function openKeybinds() {
  window.postMessage({ eventname: 'core:client:webview-showGlobalElement', args: ['keybinds'] }, '*')
}
```

Confirm the exact args shape (`args: ['keybinds']` vs `args: [{name: 'keybinds'}]`)
against `App.vue`'s actual handler for `core:client:webview-showGlobalElement`
before finalizing this step — written from the event name pattern, not a
verified payload shape.

- [ ] **Step 2: Build check**

Run: `npm run build` (from `core/web`)
Expected: succeeds

- [ ] **Step 3: Manual check**

Start `core/web`'s dev server, open the dev route, click "Open key
bindings", confirm the Keybinds page appears with the checkbox list still
visible/functional underneath (matches how the phone's dev checkbox
behaves).

- [ ] **Step 4: Commit**

```bash
cd core
git add web/src/pages/DevHudHelper.vue
git commit -m "web: add dev-debug trigger for the Keybinds settings screen"
```
