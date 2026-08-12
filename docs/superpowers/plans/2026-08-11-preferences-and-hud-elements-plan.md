# Preferences Module and HUD Element Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `oblsk_preferences` (a polymorphic account/character preference store plus a generic, mechanism-only hydration hook into core's global-elements registry), extend core's Vue build to discover modules' Vue contributions (not just plugins'), extract `Notifications.vue`/`ProgressBars.vue` out of core into their own plugin repos, and scaffold three minimal HUD element skeleton plugins (`oblsk_phone`, `oblsk_hud`, `oblsk_speedometer`).

**Architecture:** See `docs/superpowers/specs/2026-08-11-preferences-and-hud-elements-design.md` for full rationale. Seven repositories touched: `core` (one small, generic build-mechanism change), `oblsk_preferences` (new module), `oblsk_notifications` and `oblsk_progressbar` (new plugins, extracted from core), `oblsk_phone`/`oblsk_hud`/`oblsk_speedometer` (new plugins, minimal skeletons).

**Tech Stack:** Lua (FXServer `server_scripts`/`client_scripts`), the existing ORM (`QueryBuilder`/`Schema`, no dedicated model needed for `preferences`, see Task 2), Vue 3 (core's single bundled NUI app), `lua5.4` for unit tests.

## Global Constraints

- `oblsk_preferences` is a **separate git repository** (`core/modules/oblsk_preferences/`), freshly `git init`'d, no remote yet, no commits. Work directly on `master`, no worktree, same reasoning already used for `oblsk_accounts`/`oblsk_items`/`oblsk_vehicles`/`oblsk_characters`.
- `oblsk_preferences` has **no code dependency** on `oblsk_accounts`/`oblsk_characters`: no `require`, no migration-level foreign key. The session-resolution handlers in Task 3 read `AccountService.getAccountId(source)`/`CharacterService.getActiveCharacterId(source)` as plain globals, resolved at FXServer runtime because all modules load into the same `core` resource, exactly the same cross-module reference style `Character:accountRelation()` already uses to reach `Account`.
- **The write path never trusts a client-supplied id.** The NUI-facing write handler only ever accepts `{ scope, key, value }`; the server resolves the real `owner_id` itself from session state. This is a security-shaped requirement, not a style preference, see the design spec's "Session resolution and the write path" section for the precedent this follows.
- Core's Vue build glob for `web/globalElements.js` (and, for symmetry, `web/routes.js`) is extended from plugins-only to **both** `modules/*/web/...` and `plugins/*/web/...`. This is a generic, ownership-agnostic build-mechanism change (Task 4), not specific to any HUD element or to `oblsk_preferences` itself.
- Every new plugin's Vue file that needs the NUI bridge imports it as `import Obelisk from '@/obelisk.js'` (the `@` alias in `core/web/vite.config.js` already resolves to `core/web/src/` regardless of the importing file's location, verified against that config; do not use a relative path like `../../obelisk.js`, that only worked for files that lived inside `core/web/src/` itself).
- Every plugin's `web/` directory is **flat** (`plugins/<name>/web/<Component>.vue`, `plugins/<name>/web/globalElements.js`, `plugins/<name>/web/package.json`), matching the existing `oblsk_character-selection`/`oblsk_inventory` convention. Do not create a `web/src/components/` subdirectory, that's core's own internal layout, not the plugin convention.
- No Claude co-authorship in any commit.
- Minimize em/en dashes in prose (project owner's stated preference); applies to commit messages and docs prose, not code/SQL.

---

## Task 1: `oblsk_preferences` module scaffold and schema

**Repository:** `oblsk_preferences`, working directly on `master`.

**Files:**
- Create: `README.md`
- Create: `server/migrations/2026_08_10_194309_create_preferences_table.lua`
- Create: `server/migrations.json`

**Interfaces:**
- Produces: the `preferences` table. Task 2 depends on it existing.

- [ ] **Step 1: Write the `preferences` migration**

```lua
--- Migration: Create preferences table
return {
    up = function()
        Schema.create('preferences', function(table)
            table:id()
            table:string('owner_type', 20):notNullable()
            table:integer('owner_id'):notNullable()
            table:string('key', 150):notNullable()
            table:json('value')
            table:timestamps()

            table:unique({'owner_type', 'owner_id', 'key'})
        end)

        print('[Migration] Created preferences table')
    end,

    down = function()
        Schema.drop('preferences')
        print('[Migration] Dropped preferences table')
    end
}
```

Save to `server/migrations/2026_08_10_194309_create_preferences_table.lua`.

- [ ] **Step 2: Write `server/migrations.json`**

```json
{
  "migrations": [
    "2026_08_10_194309_create_preferences_table"
  ]
}
```

- [ ] **Step 3: Write `README.md`**

```markdown
# Oblsk_preferences Module

## Description
A generic, polymorphic key/value preference store (owner_type: 'account' or
'character', owner_id, key, value). No dependency on oblsk_accounts or
oblsk_characters, callers resolve their own owner ids. Also ships a
mechanism-only Vue component (PreferencesHydrator) that restores a player's
persisted global-element visibility on connect, via core's global-elements
registry.

## Installation
This module loads as part of the `core` resource. After adding it under
`modules/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).

## Usage
`PreferenceService.set(ownerType, ownerId, key, value)`, `PreferenceService.get(ownerType, ownerId, key)`,
`PreferenceService.getMerged(accountId, characterId, keys)`.

Any global element gets persisted on/off state for free: the convention key
is `hud:<elementName>:enabled`, nothing needs to be declared anywhere for
this to work, being a normal global-elements registry entry is enough.
```

- [ ] **Step 4: Verify the migration file parses**

Run: `luac5.4 -p server/migrations/2026_08_10_194309_create_preferences_table.lua`

Expected: no output, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add README.md server/migrations server/migrations.json
git commit -m "feat: add preferences schema"
```

---

## Task 2: `PreferenceService`

**Files:**
- Create: `server/services/PreferenceService.lua`
- Create: `tests/support/fake_query_builder.lua`
- Create: `tests/preference_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(tableName)` and `Database.now()` from core's ORM.
- Produces: `PreferenceService.set(ownerType, ownerId, key, value)`, `PreferenceService.get(ownerType, ownerId, key)`, `PreferenceService.getMerged(accountId, characterId, keys)`. Task 3's server-side NUI handlers call all three.

No dedicated `Preference` model: `set`/`get` are a plain upsert/lookup by three columns, the same shape `ActionService.flushPendingRegistrations` already uses via raw `QueryBuilder` rather than a model (see `core/server/Services/ActionService.lua`), and `value` is JSON-encoded/decoded by hand here (`json.encode`/`pcall(json.decode, ...)`) rather than via `BaseModel`'s cast machinery, since there's no model instance in play.

- [ ] **Step 1: Write the fake QueryBuilder test support**

Same shape as `oblsk_accounts`/`oblsk_characters`'s copies (no `orderBy` needed here, `PreferenceService` never sorts).

```lua
--- A fake QueryBuilder.new that operates on in-memory Lua tables instead of
--- real SQL. See tests/preference_service_spec.lua for how this is swapped
--- in for the real global QueryBuilder around each test.
local FakeQueryBuilder = {}
FakeQueryBuilder.__index = FakeQueryBuilder

local function rowMatches(row, wheres, whereNulls)
    for _, w in ipairs(wheres) do
        if row[w.column] ~= w.value then return false end
    end
    for _, col in ipairs(whereNulls) do
        if row[col] ~= nil then return false end
    end
    return true
end

function FakeQueryBuilder:where(column, a, b)
    local value = b ~= nil and b or a
    table.insert(self.wheres, { column = column, value = value })
    return self
end

function FakeQueryBuilder:whereNull(column)
    table.insert(self.whereNulls, column)
    return self
end

function FakeQueryBuilder:firstSync()
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            return row
        end
    end
    return nil
end

function FakeQueryBuilder:getSync()
    local results = {}
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            table.insert(results, row)
        end
    end
    return results
end

function FakeQueryBuilder:insert(data)
    self.nextIds[self.tableName] = (self.nextIds[self.tableName] or 0) + 1
    local id = self.nextIds[self.tableName]
    local row = { id = id }
    for k, v in pairs(data) do row[k] = v end
    table.insert(self.rows, row)
    return id
end

function FakeQueryBuilder:update(data)
    local affected = 0
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            for k, v in pairs(data) do row[k] = v end
            affected = affected + 1
        end
    end
    return affected
end

--- @param tables table tableName -> array of row tables (shared, mutated in place across calls)
--- @return table a QueryBuilder-shaped module (has .new(tableName))
local function makeFakeQueryBuilderModule(tables)
    local nextIds = {}
    local Module = {}
    function Module.new(tableName)
        tables[tableName] = tables[tableName] or {}
        return setmetatable({
            tableName = tableName,
            rows = tables[tableName],
            nextIds = nextIds,
            wheres = {},
            whereNulls = {},
        }, FakeQueryBuilder)
    end
    return Module
end

return makeFakeQueryBuilderModule
```

Save to `tests/support/fake_query_builder.lua`.

- [ ] **Step 2: Write `PreferenceService.lua`**

```lua
--- PreferenceService (server) - a generic, polymorphic key/value preference
--- store (owner_type: 'account'|'character', owner_id, key, value). No
--- dependency on oblsk_accounts/oblsk_characters, callers resolve their own
--- owner ids. See
--- docs/superpowers/specs/2026-08-11-preferences-and-hud-elements-design.md.
PreferenceService = {}

local function encodeValue(value)
    return json.encode(value)
end

local function decodeValue(raw)
    if raw == nil then return nil end
    local ok, decoded = pcall(json.decode, raw)
    if ok then return decoded end
    return nil
end

--- @param ownerType string 'account'|'character'
--- @param ownerId number
--- @param key string
--- @param value any JSON-encodable
function PreferenceService.set(ownerType, ownerId, key, value)
    local existing = QueryBuilder.new('preferences')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('key', key):firstSync()

    if existing then
        QueryBuilder.new('preferences'):where('id', existing.id):update({
            value = encodeValue(value),
            updated_at = Database.now(),
        })
    else
        QueryBuilder.new('preferences'):insert({
            owner_type = ownerType,
            owner_id = ownerId,
            key = key,
            value = encodeValue(value),
            created_at = Database.now(),
            updated_at = Database.now(),
        })
    end
end

--- @param ownerType string 'account'|'character'
--- @param ownerId number
--- @param key string
--- @return any|nil decoded value, or nil if not set
function PreferenceService.get(ownerType, ownerId, key)
    local row = QueryBuilder.new('preferences')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('key', key):firstSync()
    if not row then return nil end
    return decodeValue(row.value)
end

--- Merges account-scoped and character-scoped preferences for a key list.
--- A character-scoped value overrides the account-scoped value for the same
--- key, same base/override precedence VehicleHandling.mergeRows already
--- established. A key with no row in either scope is omitted entirely.
--- @param accountId number|nil
--- @param characterId number|nil
--- @param keys string[]
--- @return table flat {key -> value}
function PreferenceService.getMerged(accountId, characterId, keys)
    local merged = {}

    if accountId then
        for _, key in ipairs(keys) do
            local value = PreferenceService.get('account', accountId, key)
            if value ~= nil then merged[key] = value end
        end
    end

    if characterId then
        for _, key in ipairs(keys) do
            local value = PreferenceService.get('character', characterId, key)
            if value ~= nil then merged[key] = value end
        end
    end

    return merged
end

return PreferenceService
```

Save to `server/services/PreferenceService.lua`.

- [ ] **Step 3: Write `tests/preference_service_spec.lua`**

```lua
--- Unit tests for PreferenceService: upsert semantics, decode round-trip,
--- and getMerged's character-overrides-account precedence.
--- Run from the repository root:  lua5.4 tests/preference_service_spec.lua
---
--- CORE_ROOT is a relative walk-up from this file to the core repo root.
--- oblsk_preferences must live at <core-root>/modules/oblsk_preferences/
--- for FXServer to load it as part of core at all, so this file is always
--- three levels below the core root (tests/ -> oblsk_preferences/ ->
--- modules/ -> core-root).
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(scriptDir .. '../server/services/PreferenceService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

--- Swaps the real global QueryBuilder for the fake for the duration of fn.
local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

--------------------------------------------------------------------------------
-- set / get
--------------------------------------------------------------------------------

test('set: creates a new row when none exists', function()
    withFakeDb(function(tables)
        PreferenceService.set('account', 1, 'hud:notifications:enabled', false)
        eq(#tables.preferences, 1)
        eq(tables.preferences[1].owner_type, 'account')
        eq(tables.preferences[1].owner_id, 1)
        eq(tables.preferences[1].key, 'hud:notifications:enabled')
    end)
end)

test('set: updates the existing row instead of inserting a duplicate', function()
    withFakeDb(function(tables)
        PreferenceService.set('account', 1, 'hud:notifications:enabled', false)
        PreferenceService.set('account', 1, 'hud:notifications:enabled', true)
        eq(#tables.preferences, 1)
        eq(PreferenceService.get('account', 1, 'hud:notifications:enabled'), true)
    end)
end)

test('get: returns the decoded value that was set', function()
    withFakeDb(function()
        PreferenceService.set('account', 1, 'hud:notifications:enabled', false)
        eq(PreferenceService.get('account', 1, 'hud:notifications:enabled'), false)
    end)
end)

test('get: returns nil when no row exists', function()
    withFakeDb(function()
        eq(PreferenceService.get('account', 1, 'hud:never-set:enabled'), nil)
    end)
end)

test('get: different owners never see each other\'s value for the same key', function()
    withFakeDb(function()
        PreferenceService.set('account', 1, 'hud:notifications:enabled', false)
        eq(PreferenceService.get('account', 2, 'hud:notifications:enabled'), nil)
    end)
end)

--------------------------------------------------------------------------------
-- getMerged
--------------------------------------------------------------------------------

test('getMerged: a character-scoped value overrides the account-scoped value for the same key', function()
    withFakeDb(function()
        PreferenceService.set('account', 1, 'hud:notifications:enabled', true)
        PreferenceService.set('character', 5, 'hud:notifications:enabled', false)

        local merged = PreferenceService.getMerged(1, 5, { 'hud:notifications:enabled' })
        eq(merged['hud:notifications:enabled'], false)
    end)
end)

test('getMerged: falls back to the account-scoped value when no character row exists', function()
    withFakeDb(function()
        PreferenceService.set('account', 1, 'hud:notifications:enabled', true)

        local merged = PreferenceService.getMerged(1, 5, { 'hud:notifications:enabled' })
        eq(merged['hud:notifications:enabled'], true)
    end)
end)

test('getMerged: a nil characterId only checks the account scope', function()
    withFakeDb(function()
        PreferenceService.set('account', 1, 'hud:notifications:enabled', true)

        local merged = PreferenceService.getMerged(1, nil, { 'hud:notifications:enabled' })
        eq(merged['hud:notifications:enabled'], true)
    end)
end)

test('getMerged: a key with no row in either scope is omitted entirely', function()
    withFakeDb(function()
        local merged = PreferenceService.getMerged(1, 5, { 'hud:never-set:enabled' })
        eq(merged['hud:never-set:enabled'], nil)
        eq(next(merged), nil)
    end)
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running PreferenceService unit tests\n')
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

Save to `tests/preference_service_spec.lua`.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `lua5.4 tests/preference_service_spec.lua`

Expected: `9 passed, 0 failed` (2 `set` + 3 `get` + 4 `getMerged`; every `test(...)` block in the file must report `ok`, none `FAIL`).

- [ ] **Step 5: Commit**

```bash
git add server/services/PreferenceService.lua tests/support/fake_query_builder.lua tests/preference_service_spec.lua
git commit -m "feat: add PreferenceService with polymorphic get/set/getMerged"
```

---

## Task 3: NUI wiring and the hydrator component

**Files:**
- Create: `server/main.lua`
- Create: `client/main.lua`
- Create: `web/PreferencesHydrator.vue`
- Create: `web/globalElements.js`
- Create: `web/package.json`

**Interfaces:**
- Consumes: `PreferenceService.getMerged`/`PreferenceService.set` (Task 2), `AccountService.getAccountId(source)` (from `oblsk_accounts`, a plain global, not required/loaded here), `CharacterService.getActiveCharacterId(source)` (from `oblsk_characters`, same), `Obelisk.onServer`/`Obelisk.emitClient`/`Obelisk.emitServer`/`Obelisk.onClient` (core's event wrapper), the injected `obelisk:globalElementsRegistry` (provided by Task 4's core change).
- Produces: the NUI-facing events `oblsk_preferences:client:set` and `oblsk_preferences:client:request` (via `RegisterNUICallback`), and `oblsk_preferences:client:hydrate` (server to client to NUI).

This task's Lua files touch FXServer-only globals (`RegisterNUICallback`, `Obelisk.onServer`, `Obelisk.onClient`, `Obelisk.emitClient`, `SendNUIMessage`) and its Vue file touches the Vue runtime (`inject`, `onMounted`) and the browser-only `Obelisk` NUI bridge, none of which run outside FXServer/a real browser. Verify by syntax check only (`luac5.4 -p` for the Lua files; the Vue file has no automated check available in this repo, hand-verify by reading it against the code below).

- [ ] **Step 1: Write `server/main.lua`**

```lua
--- oblsk_preferences - Server Main
--- Resolves the current connection's account/character before ever
--- touching the database. The client only ever sends {scope, key, value},
--- never an id, the server fills in the real owner_id itself. See
--- docs/superpowers/specs/2026-08-11-preferences-and-hud-elements-design.md.
local function resolveOwner(source, scope)
    local accountId = AccountService.getAccountId(source)
    local characterId = CharacterService.getActiveCharacterId(source)

    if scope == 'character' and characterId then
        return 'character', characterId
    end
    return 'account', accountId
end

Obelisk.onServer('oblsk_preferences:server:set', function(source, scope, key, value)
    local ownerType, ownerId = resolveOwner(source, scope)
    if not ownerId then
        return
    end
    PreferenceService.set(ownerType, ownerId, key, value)
end)

Obelisk.onServer('oblsk_preferences:server:request', function(source, keys)
    local accountId = AccountService.getAccountId(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    local merged = PreferenceService.getMerged(accountId, characterId, keys)
    Obelisk.emitClient('oblsk_preferences:client:hydrate', source, merged)
end)
```

- [ ] **Step 2: Write `client/main.lua`**

```lua
--- oblsk_preferences - Client Main
--- Relays NUI preference read/write requests to the server, and relays the
--- server's hydrate reply back down to the NUI. See
--- docs/superpowers/specs/2026-08-11-preferences-and-hud-elements-design.md.
RegisterNUICallback('oblsk_preferences:client:set', function(data, cb)
    Obelisk.emitServer('oblsk_preferences:server:set', data.scope, data.key, data.value)
    cb('ok')
end)

RegisterNUICallback('oblsk_preferences:client:request', function(data, cb)
    Obelisk.emitServer('oblsk_preferences:server:request', data.keys)
    cb('ok')
end)

Obelisk.onClient('oblsk_preferences:client:hydrate', function(merged)
    SendNUIMessage({ eventname = 'oblsk_preferences:client:hydrate', args = { merged } })
end)
```

- [ ] **Step 3: Write `web/PreferencesHydrator.vue`**

```vue
<template></template>

<script setup>
import { inject, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const registry = inject('obelisk:globalElementsRegistry')

onMounted(() => {
  Obelisk.on('oblsk_preferences:client:hydrate', (merged) => {
    if (!registry) return
    for (const [name, entry] of registry) {
      const key = `hud:${name}:enabled`
      if (merged[key] !== undefined) entry.visible = merged[key]
    }
  })

  const keys = registry ? [...registry.keys()].map(name => `hud:${name}:enabled`) : []
  Obelisk.emit('oblsk_preferences:client:request', { keys })
})
</script>
```

Renders nothing (`<template></template>`), its only job is the mount-time hydration request and applying the reply. `inject('obelisk:globalElementsRegistry')` returns `undefined` if `core/web/src/App.vue` hasn't been updated yet (Task 4), the `if (!registry) return` / `registry ? ... : []` guards make this file safe to write and commit before Task 4 runs, it just does nothing useful until then.

- [ ] **Step 4: Write `web/globalElements.js`**

```js
import PreferencesHydrator from './PreferencesHydrator.vue'

export default [
  { name: '__preferencesHydrator', component: PreferencesHydrator, defaultVisible: true }
]
```

- [ ] **Step 5: Write `web/package.json`**

```json
{
  "name": "oblsk_preferences",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "vue": "^3.5.22"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^6.0.1",
    "vite": "^7.1.7"
  }
}
```

- [ ] **Step 6: Verify the Lua files parse**

Run: `luac5.4 -p server/main.lua client/main.lua`

Expected: no output, exit code 0.

- [ ] **Step 7: Commit**

```bash
git add server/main.lua client/main.lua web/PreferencesHydrator.vue web/globalElements.js web/package.json
git commit -m "feat: add NUI preference read/write relay and hydrator component"
```

---

## Task 4: Core build-mechanism change

**Repository:** `core`, working directly on `main`.

**Files:**
- Modify: `web/src/App.vue`
- Modify: `web/src/router/index.js`

**Interfaces:**
- Produces: the `obelisk:globalElementsRegistry` injection key that Task 3's `PreferencesHydrator.vue` (and any future module/plugin global element) can `inject()`. Extends both Vue-contribution globs from plugins-only to modules-and-plugins.

This is the **only** change to any core file in this whole plan, and it is generic (a build-mechanism extension and a registry-building safeguard), not specific to `oblsk_preferences` or any HUD element.

- [ ] **Step 1: Read the current `web/src/App.vue` and `web/src/router/index.js`**

Confirm they still match what this task assumes (in case something else changed core's Vue app since this plan was written):

```bash
cat web/src/App.vue
cat web/src/router/index.js
```

`App.vue`'s `<script setup>` should still contain, verbatim:
```js
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
  const defaultVisible = !!entry.defaultVisible
  registry.set(entry.name, { component: entry.component, defaultVisible, visible: defaultVisible })
}
```

`router/index.js` should still contain, verbatim:
```js
const pluginRouteModules = import.meta.glob('../../../plugins/*/web/routes.js', { eager: true });
```

If either differs meaningfully from the above, stop and report `BLOCKED`, don't guess at a merge, this task's edits are written against this exact text.

- [ ] **Step 2: Extend the `globalElements.js` glob to include modules, and warn on duplicates**

In `web/src/App.vue`, replace:

```js
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
  const defaultVisible = !!entry.defaultVisible
  registry.set(entry.name, { component: entry.component, defaultVisible, visible: defaultVisible })
}
```

with:

```js
const contributedGlobalElementModules = import.meta.glob(
  ['../../modules/*/web/globalElements.js', '../../plugins/*/web/globalElements.js'],
  { eager: true }
)

const contributedGlobalElements = []
for (const mod of Object.values(contributedGlobalElementModules)) {
  if (Array.isArray(mod.default)) {
    contributedGlobalElements.push(...mod.default)
  } else {
    console.warn('[Obelisk] a globalElements.js did not export a default array, skipping')
  }
}

const registry = reactive(new Map())
for (const entry of [...coreGlobalElements, ...contributedGlobalElements]) {
  if (!entry || !entry.name || !entry.component) {
    console.warn('[Obelisk] a global element entry is missing name/component, skipping', entry)
    continue
  }
  if (registry.has(entry.name)) {
    console.warn(`[Obelisk] duplicate global element name "${entry.name}", keeping the last one discovered`)
  }
  const defaultVisible = !!entry.defaultVisible
  registry.set(entry.name, { component: entry.component, defaultVisible, visible: defaultVisible })
}

provide('obelisk:globalElementsRegistry', registry)
```

And update the Vue import line from:

```js
import { reactive, onMounted } from 'vue'
```

to:

```js
import { reactive, onMounted, provide } from 'vue'
```

Every other part of `App.vue` (the `onMounted` block, the `Obelisk.on(...)` handlers, the `<template>`, the `<style>`) is unchanged.

- [ ] **Step 3: Extend the `routes.js` glob to include modules**

In `web/src/router/index.js`, replace:

```js
const pluginRouteModules = import.meta.glob('../../../plugins/*/web/routes.js', { eager: true });
```

with:

```js
const pluginRouteModules = import.meta.glob(
  ['../../../modules/*/web/routes.js', '../../../plugins/*/web/routes.js'],
  { eager: true }
);
```

Everything else in this file is unchanged. (No module ships `routes.js` yet, `oblsk_preferences` only ships `globalElements.js`, this is a symmetry change so a future module could add a routed page the same way a plugin can.)

- [ ] **Step 4: Verify the docs build still succeeds**

Run: `cd docs && npm run build`

Expected: build completes (this validates the docs site, not the NUI Vue app itself, since the NUI app's own build requires the FXServer bundling context; running `cd web && npm install && npm run build` if `web/node_modules` already exists is a good extra check, but is not required to pass this step if dependencies aren't installed in this environment, note whichever you actually ran in your report).

- [ ] **Step 5: Commit**

```bash
git add web/src/App.vue web/src/router/index.js
git commit -m "feat: extend global-elements/routes globs to modules, provide registry for injection"
```

---

## Task 5: Extract `oblsk_notifications`

**Repository:** `oblsk_notifications`, a brand-new plugin repository (`plugins/oblsk_notifications/`, freshly `git init`'d, work directly on `master`). Also touches **core** (removing the extracted entry).

**Files:**
- Create: `plugins/oblsk_notifications/README.md`
- Create: `plugins/oblsk_notifications/web/Notifications.vue` (moved from `core/web/src/components/global/Notifications.vue`, byte-identical apart from its import path, see Step 2)
- Create: `plugins/oblsk_notifications/web/globalElements.js`
- Create: `plugins/oblsk_notifications/web/package.json`
- Delete (in **core**, on `main`): `web/src/components/global/Notifications.vue`
- Modify (in **core**, on `main`): `web/src/globalElements.js`

**Interfaces:**
- Consumes: `NotificationService` (client and server, both stay in `core/`, untouched, this task is Vue-only). The event contract (`core:client:notification-show`, `core:client:notification-dismissed`) is unchanged, that's what makes this extraction purely mechanical.

- [ ] **Step 1: Set up the new repository**

```bash
mkdir -p plugins/oblsk_notifications/web
cd plugins/oblsk_notifications
git init -b master
```

(Run from `core/`'s root; adjust the `cd` to your actual working directory.)

- [ ] **Step 2: Move `Notifications.vue`, fixing its one import line**

Copy `core/web/src/components/global/Notifications.vue`'s content into `plugins/oblsk_notifications/web/Notifications.vue`, changing only this line:

```js
import Obelisk from '../../obelisk.js'
```

to:

```js
import Obelisk from '@/obelisk.js'
```

Every other line, including the `<template>` and `<style>` blocks, is byte-identical to the original file.

- [ ] **Step 3: Write `web/globalElements.js`**

```js
import Notifications from './Notifications.vue'

export default [
  { name: 'notifications', component: Notifications, defaultVisible: true }
]
```

- [ ] **Step 4: Write `web/package.json`**

```json
{
  "name": "oblsk_notifications",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "vue": "^3.5.22"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^6.0.1",
    "vite": "^7.1.7"
  }
}
```

- [ ] **Step 5: Write `README.md`**

```markdown
# Oblsk_notifications Plugin

## Description
The reference notification UI, a Vue global element listening for
core:client:notification-show and rendering a toast-style stack. Talks to
NotificationService (server and client, both in core, unchanged). Fully
swappable: replace this plugin with your own to change how notifications
look, remove it entirely and provide your own global element named
"notifications" instead.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).
```

- [ ] **Step 6: Commit the new repository**

```bash
git add README.md web
git commit -m "feat: extract Notifications.vue from core as its own plugin"
```

- [ ] **Step 7: Remove the extracted element from core**

Back in the `core` repository (on `main`), delete the moved file and update `web/src/globalElements.js`:

```bash
git rm web/src/components/global/Notifications.vue
```

Edit `web/src/globalElements.js` from:

```js
import Notifications from './components/global/Notifications.vue'
import ProgressBars from './components/global/ProgressBars.vue'

export default [
  { name: 'notifications', component: Notifications, defaultVisible: true },
  { name: 'progressBars', component: ProgressBars, defaultVisible: true }
]
```

to (removing only the `Notifications` import and registry entry, `ProgressBars` stays until Task 6):

```js
import ProgressBars from './components/global/ProgressBars.vue'

export default [
  { name: 'progressBars', component: ProgressBars, defaultVisible: true }
]
```

- [ ] **Step 8: Commit the core-side removal**

```bash
git add web/src/globalElements.js
git commit -m "chore: remove Notifications.vue, extracted to oblsk_notifications"
```

---

## Task 6: Extract `oblsk_progressbar`

**Repository:** `oblsk_progressbar`, a brand-new plugin repository (`plugins/oblsk_progressbar/`, freshly `git init`'d, work directly on `master`). Also touches **core**.

**Files:**
- Create: `plugins/oblsk_progressbar/README.md`
- Create: `plugins/oblsk_progressbar/web/ProgressBars.vue` (moved from `core/web/src/components/global/ProgressBars.vue`, byte-identical apart from its import path)
- Create: `plugins/oblsk_progressbar/web/globalElements.js`
- Create: `plugins/oblsk_progressbar/web/package.json`
- Delete (in **core**, on `main`): `web/src/components/global/ProgressBars.vue`
- Modify (in **core**, on `main`): `web/src/globalElements.js`

**Interfaces:**
- Consumes: `ProgressService` (client and server, both stay in `core/`, untouched). Same extraction shape as Task 5.

Identical procedure to Task 5, applied to `ProgressBars.vue`/`ProgressService`.

- [ ] **Step 1: Set up the new repository**

```bash
mkdir -p plugins/oblsk_progressbar/web
cd plugins/oblsk_progressbar
git init -b master
```

- [ ] **Step 2: Move `ProgressBars.vue`, fixing its one import line**

Copy `core/web/src/components/global/ProgressBars.vue`'s content into `plugins/oblsk_progressbar/web/ProgressBars.vue`, changing only this line:

```js
import Obelisk from '../../obelisk.js'
```

to:

```js
import Obelisk from '@/obelisk.js'
```

Every other line is byte-identical to the original file.

- [ ] **Step 3: Write `web/globalElements.js`**

```js
import ProgressBars from './ProgressBars.vue'

export default [
  { name: 'progressBars', component: ProgressBars, defaultVisible: true }
]
```

- [ ] **Step 4: Write `web/package.json`**

```json
{
  "name": "oblsk_progressbar",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "vue": "^3.5.22"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^6.0.1",
    "vite": "^7.1.7"
  }
}
```

- [ ] **Step 5: Write `README.md`**

```markdown
# Oblsk_progressbar Plugin

## Description
The reference progress-bar UI, a Vue global element listening for
core:client:progress-start/complete/cancel and rendering an animated bar
with a cancel button. Talks to ProgressService (server and client, both in
core, unchanged). Fully swappable: replace this plugin with your own to
change how progress bars look, remove it entirely and provide your own
global element named "progressBars" instead.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).
```

- [ ] **Step 6: Commit the new repository**

```bash
git add README.md web
git commit -m "feat: extract ProgressBars.vue from core as its own plugin"
```

- [ ] **Step 7: Remove the extracted element from core**

```bash
git rm web/src/components/global/ProgressBars.vue
```

Edit `web/src/globalElements.js` from:

```js
import ProgressBars from './components/global/ProgressBars.vue'

export default [
  { name: 'progressBars', component: ProgressBars, defaultVisible: true }
]
```

to:

```js
export default []
```

- [ ] **Step 8: Commit the core-side removal**

```bash
git add web/src/globalElements.js
git commit -m "chore: remove ProgressBars.vue, extracted to oblsk_progressbar"
```

After this step, core owns zero HUD elements, matching the design's stated goal.

---

## Task 7: Scaffold `oblsk_phone`, `oblsk_hud`, `oblsk_speedometer` skeletons

**Repositories:** Three brand-new plugin repositories (`plugins/oblsk_phone/`, `plugins/oblsk_hud/`, `plugins/oblsk_speedometer/`), each freshly `git init`'d, each worked on directly on `master`. No core changes.

**Files (repeated identically per repository, only the name/label differs):**
- Create: `<repo>/README.md`
- Create: `<repo>/web/<Name>.vue`
- Create: `<repo>/web/globalElements.js`
- Create: `<repo>/web/package.json`

**Interfaces:**
- Produces: three registry entries (`phone`, `hud`, `speedometer`), each a placeholder with no real feature content. What each one actually displays is explicitly out of scope, see the design spec's Known Gaps.

This task has no server/client Lua at all, these three plugins have no backend yet, only a placeholder Vue component each.

- [ ] **Step 1: Scaffold `oblsk_phone`**

```bash
mkdir -p plugins/oblsk_phone/web
cd plugins/oblsk_phone
git init -b master
```

`web/Phone.vue`:

```vue
<template>
  <div class="fixed bottom-4 right-4 z-50 w-72 h-96 bg-gray-900/90 rounded-2xl border border-gray-700 flex items-center justify-center">
    <span class="text-gray-500 text-sm">Phone (placeholder)</span>
  </div>
</template>

<script setup>
</script>
```

`web/globalElements.js`:

```js
import Phone from './Phone.vue'

export default [
  { name: 'phone', component: Phone, defaultVisible: false }
]
```

`web/package.json`:

```json
{
  "name": "oblsk_phone",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "vue": "^3.5.22"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^6.0.1",
    "vite": "^7.1.7"
  }
}
```

`README.md`:

```markdown
# Oblsk_phone Plugin

## Description
A placeholder phone global element. No contacts, calls, or apps yet, this
just establishes the plugin, correctly wired into the toggle/preferences
mechanism by virtue of being a normal global-elements registry entry. Real
feature content is a separate future pass.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).
```

Commit:

```bash
git add README.md web
git commit -m "feat: scaffold oblsk_phone placeholder"
```

- [ ] **Step 2: Scaffold `oblsk_hud`**

```bash
mkdir -p plugins/oblsk_hud/web
cd plugins/oblsk_hud
git init -b master
```

`web/Hud.vue`:

```vue
<template>
  <div class="fixed bottom-4 left-4 z-40 text-white text-sm bg-black/50 rounded px-3 py-2">
    HUD (placeholder)
  </div>
</template>

<script setup>
</script>
```

`web/globalElements.js`:

```js
import Hud from './Hud.vue'

export default [
  { name: 'hud', component: Hud, defaultVisible: true }
]
```

`web/package.json`: identical shape to Task 7 Step 1's, with `"name": "oblsk_hud"`.

`README.md`:

```markdown
# Oblsk_hud Plugin

## Description
A placeholder HUD global element (health/armor/minimap, eventually). No real
readout yet, this just establishes the plugin, correctly wired into the
toggle/preferences mechanism by virtue of being a normal global-elements
registry entry. Real feature content is a separate future pass.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).
```

Commit:

```bash
git add README.md web
git commit -m "feat: scaffold oblsk_hud placeholder"
```

- [ ] **Step 3: Scaffold `oblsk_speedometer`**

```bash
mkdir -p plugins/oblsk_speedometer/web
cd plugins/oblsk_speedometer
git init -b master
```

`web/Speedometer.vue`:

```vue
<template>
  <div class="fixed bottom-4 right-4 z-40 text-white text-sm bg-black/50 rounded px-3 py-2">
    Speedometer (placeholder)
  </div>
</template>

<script setup>
</script>
```

`web/globalElements.js`:

```js
import Speedometer from './Speedometer.vue'

export default [
  { name: 'speedometer', component: Speedometer, defaultVisible: false }
]
```

`web/package.json`: identical shape, with `"name": "oblsk_speedometer"`.

`README.md`:

```markdown
# Oblsk_speedometer Plugin

## Description
A placeholder speedometer global element. No real vehicle-speed readout yet
(GetEntitySpeed is a trivial future addition), this just establishes the
plugin, correctly wired into the toggle/preferences mechanism by virtue of
being a normal global-elements registry entry. Real feature content is a
separate future pass.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).
```

Commit:

```bash
git add README.md web
git commit -m "feat: scaffold oblsk_speedometer placeholder"
```

---

## After all tasks: final review and handoff

Once Task 7 is complete: re-run `lua5.4 tests/preference_service_spec.lua` from `oblsk_preferences`'s repo root to confirm the suite is still green, then run a whole-branch review per the subagent-driven-development skill (this plan spans 7 repositories, the final review needs to check consistency across all of them: the extraction preserved behavior exactly, the core glob change doesn't break `oblsk_character-selection`'s existing `routes.js` discovery, the hydrator degrades correctly with no character selected). After that review is clean:

- Run `obelisk registry:generate` from `core/` on the host so `modules/registry.json` picks up `oblsk_preferences` and `plugins/registry.json` picks up `oblsk_notifications`, `oblsk_progressbar`, `oblsk_phone`, `oblsk_hud`, `oblsk_speedometer`.
- Create the five new GitHub repos and push each, same as every prior module/plugin this session, once the user confirms.
- Push core's `main` (the Task 4 glob extension and the two Task 5/6 removals).
- A settings-menu UI, character-select re-hydration, and real feature content for phone/hud/speedometer are all separate future passes, see the design spec's Known Gaps.
