# Shell Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new core `InstanceService` (routing-bucket dimensions) and a new `oblsk_shellbuilder` plugin that lets staff build enterable interiors ("shells") — fully furnished or left empty for owning characters to furnish themselves — with a browser/editor NUI ported from the Claude Design reference.

**Architecture:** `InstanceService` (core) maps an arbitrary string key to a deterministic FiveM routing bucket (`row id + 1000`) and moves players in/out of it. `oblsk_shellbuilder` owns three tables (`shells`, `shell_owners`, `shell_objects`), two services (`ShellService` for CRUD/ownership, `ShellObjectService` for placement), one world interaction that opens a Vue browser screen, and a Vue editor screen for the bottom-dock build UI. Every shell's interior geometry sits at one shared underground anchor coordinate; the routing bucket alone keeps different shells' occupants from seeing or colliding with each other there.

**Tech Stack:** Lua 5.4 (server/client, this repo's ORM: `QueryBuilder`/`Schema`/`BaseModel`), Vue 3 SFC (NUI), `lua5.4` CLI for headless unit tests with a fake in-memory `QueryBuilder`.

**Spec:** `core/docs/superpowers/specs/2026-08-15-shell-builder-plugin-design.md`

## Global Constraints

- Every new Lua file follows this repo's existing service/model conventions exactly (see Task 1-4 code — copied patterns, not reinvented): `Obelisk.emit*`/`Obelisk.on*` for net events (never raw `TriggerEvent`/`RegisterNetEvent`), `<plugin>:<server|client>:<action>` event naming, `WebView.on`/`WebView.emit` for NUI, models via `BaseModel:extend('table_name')`.
- All new tables use the migration `Schema.create`/`Schema.table` DSL, one migration per table, `up`/`down` both implemented.
- Every service that touches the database must be headless-testable: no `source`-dependent native calls inside the pure logic functions (natives stay in `server/main.lua`/`client/main.lua`).
- No placeholder code, no `TODO`. Every step below contains complete, runnable content.
- Shared underground anchor coordinates: `Config.Anchor = { x = -3000.0, y = -3000.0, z = -500.0 }` (arbitrary far-below-map point) — defined once in `plugins/oblsk_shellbuilder/shared/config.lua`, used by every task that teleports a player into a shell.
- Object placement budget default: `900` (matches the design), stored per-shell on `shells.object_budget`.

---

## File Structure

```
core/
  server/database/migrations/
    2026_08_15_095900_create_instance_buckets_table.lua      -- new (Task 1)
  server/Services/
    InstanceService.lua                                       -- new (Task 1)
  tests/
    instance_service_spec.lua                                 -- new (Task 1)

plugins/oblsk_shellbuilder/
  README.md                                                   -- new (Task 8)
  fxmanifest.lua                                               -- new (Task 2)
  shared/
    config.lua                                                 -- new (Task 2)
  server/
    migrations/
      2026_08_15_100000_create_shells_table.lua                -- new (Task 2)
      2026_08_15_100001_create_shell_owners_table.lua          -- new (Task 2)
      2026_08_15_100002_create_shell_objects_table.lua         -- new (Task 2)
    models/
      Shell.lua                                                -- new (Task 2)
      ShellOwner.lua                                            -- new (Task 2)
      ShellObject.lua                                           -- new (Task 2)
    policies/
      CanBuildShellsPolicy.lua                                 -- new (Task 3)
    services/
      ShellService.lua                                          -- new (Task 3)
      ShellObjectService.lua                                    -- new (Task 4)
    main.lua                                                    -- new (Task 5)
  client/
    main.lua                                                    -- new (Task 5)
  web/
    routes.js                                                   -- new (Task 6)
    globalElements.js                                           -- new (Task 6)
    ShellBrowser.vue                                             -- new (Task 6)
    ShellEditor.vue                                              -- new (Task 7)
  tests/
    support/
      fake_query_builder.lua                                    -- new (Task 3, copied)
    shell_service_spec.lua                                      -- new (Task 3)
    shell_object_service_spec.lua                                -- new (Task 4)
```

---

### Task 1: Core `InstanceService` (routing-bucket dimensions)

**Files:**
- Create: `core/server/database/migrations/2026_08_15_095900_create_instance_buckets_table.lua`
- Create: `core/server/Services/InstanceService.lua`
- Test: `core/tests/instance_service_spec.lua`

**Interfaces:**
- Produces: `InstanceService.getOrCreateBucket(key: string) -> bucketId: number`, `InstanceService.enter(source: number, key: string) -> bucketId: number`, `InstanceService.leave(source: number)`, `InstanceService.getPlayersIn(key: string) -> playerSources: number[]` (tracks membership in-memory, cleared on `playerDropped`).

- [ ] **Step 1: Write the migration**

```lua
-- core/server/database/migrations/2026_08_15_095900_create_instance_buckets_table.lua
return {
    up = function()
        Schema.create('instance_buckets', function(table)
            table:id()
            table:string('key', 120):unique()
            table:integer('bucket_id')
            table:timestamps()
        end)

        print('[Migration] Created instance_buckets table')
    end,

    down = function()
        Schema.drop('instance_buckets')
        print('[Migration] Dropped instance_buckets table')
    end
}
```

- [ ] **Step 2: Write the failing test**

```lua
-- core/tests/instance_service_spec.lua
-- Run from the repository root:  lua5.4 core/tests/instance_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

-- Native stubs: fivem_stubs.lua doesn't know about routing-bucket natives.
local bucketCalls = {}
function SetPlayerRoutingBucket(source, bucket) bucketCalls[#bucketCalls + 1] = { source = source, bucket = bucket } end
function SetRoutingBucketPopulationEnabled(bucket, enabled) end
function SetRoutingBucketEntityLockdownMode(bucket, mode) end

dofile(ROOT .. '/core/server/Services/InstanceService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    QueryBuilder = makeFakeQueryBuilderModule({})
    bucketCalls = {}
    InstanceService.resetForTests()
    fn()
end

test('getOrCreateBucket allocates a new deterministic bucket for a new key', function()
    withFreshState(function()
        local bucketId = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        eq(bucketId, 1001) -- row id 1 + 1000 offset
    end)
end)

test('getOrCreateBucket returns the same bucket for the same key on repeat calls', function()
    withFreshState(function()
        local first = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        local second = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        eq(first, second)
    end)
end)

test('getOrCreateBucket allocates different buckets for different keys', function()
    withFreshState(function()
        local a = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        local b = InstanceService.getOrCreateBucket('shellbuilder:shell:2')
        eq(a == b, false)
    end)
end)

test('enter moves the player into the key\'s bucket and tracks membership', function()
    withFreshState(function()
        local bucketId = InstanceService.enter(7, 'shellbuilder:shell:1')
        eq(bucketId, 1001)
        eq(bucketCalls[1].source, 7)
        eq(bucketCalls[1].bucket, 1001)

        local players = InstanceService.getPlayersIn('shellbuilder:shell:1')
        eq(#players, 1)
        eq(players[1], 7)
    end)
end)

test('leave moves the player back to bucket 0 and clears membership', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        InstanceService.leave(7)

        eq(bucketCalls[2].source, 7)
        eq(bucketCalls[2].bucket, 0)
        eq(#InstanceService.getPlayersIn('shellbuilder:shell:1'), 0)
    end)
end)

test('getPlayersIn reflects multiple players sharing one shell\'s bucket', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        InstanceService.enter(9, 'shellbuilder:shell:1')

        local players = InstanceService.getPlayersIn('shellbuilder:shell:1')
        eq(#players, 2)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 3: Run test to verify it fails**

Run: `lua5.4 core/tests/instance_service_spec.lua`
Expected: FAIL — `InstanceService` is nil (file doesn't exist yet).

- [ ] **Step 4: Write the implementation**

```lua
-- core/server/Services/InstanceService.lua
--- InstanceService - generic dimension allocation via FiveM routing buckets.
--- A "key" (any stable string, e.g. "shellbuilder:shell:42") maps
--- deterministically to a bucket id, so every consumer that later resolves
--- the same key lands in the same bucket - no pooled/ephemeral allocation,
--- no free-list bookkeeping. bucket_id is simply the instance_buckets row's
--- own id + OFFSET, kept clear of FiveM's default bucket 0.
InstanceService = {}

local OFFSET = 1000

-- source -> key, so leave() and playerDropped cleanup know which bucket's
-- membership set to remove a player from without the caller repeating it.
local playerBucketKey = {}

-- key -> { [source] = true }, membership per bucket key.
local bucketMembers = {}

--- @param key string
--- @return number bucketId
function InstanceService.getOrCreateBucket(key)
    local existing = QueryBuilder.new('instance_buckets'):where('key', key):firstSync()
    if existing then
        return existing.bucket_id
    end

    local id = QueryBuilder.new('instance_buckets'):insert({
        key = key,
        bucket_id = 0, -- placeholder, corrected below once we know our own row id
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    local bucketId = id + OFFSET
    QueryBuilder.new('instance_buckets'):where('id', id):update({ bucket_id = bucketId })

    return bucketId
end

--- Moves `source` into `key`'s bucket, disabling ambient population/traffic
--- in it the first time this process resolves that key. Records membership
--- so getPlayersIn/leave/playerDropped cleanup can find this player again.
--- @param source number
--- @param key string
--- @return number bucketId
function InstanceService.enter(source, key)
    local bucketId = InstanceService.getOrCreateBucket(key)

    SetPlayerRoutingBucket(source, bucketId)
    SetRoutingBucketPopulationEnabled(bucketId, false)
    SetRoutingBucketEntityLockdownMode(bucketId, 'strict')

    InstanceService.leave(source) -- clear any previous membership first
    playerBucketKey[source] = key
    bucketMembers[key] = bucketMembers[key] or {}
    bucketMembers[key][source] = true

    return bucketId
end

--- Moves `source` back to the default overworld bucket (0) and clears their
--- membership from whatever key they were previously in, if any.
--- @param source number
function InstanceService.leave(source)
    local key = playerBucketKey[source]
    if key and bucketMembers[key] then
        bucketMembers[key][source] = nil
    end
    playerBucketKey[source] = nil

    SetPlayerRoutingBucket(source, 0)
end

--- @param key string
--- @return number[] every player source currently tracked as inside this key's bucket
function InstanceService.getPlayersIn(key)
    local sources = {}
    for source in pairs(bucketMembers[key] or {}) do
        table.insert(sources, source)
    end
    return sources
end

AddEventHandler('playerDropped', function()
    InstanceService.leave(source)
end)

--- Test-only: resets module state between spec cases.
function InstanceService.resetForTests()
    playerBucketKey = {}
    bucketMembers = {}
end

return InstanceService
```

- [ ] **Step 5: Run test to verify it passes**

Run: `lua5.4 core/tests/instance_service_spec.lua`
Expected: `6 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
cd core
git add server/database/migrations/2026_08_15_095900_create_instance_buckets_table.lua server/Services/InstanceService.lua tests/instance_service_spec.lua
git commit -m "feat(core): add InstanceService for routing-bucket dimensions"
```

---

### Task 2: `oblsk_shellbuilder` scaffold — manifest, config, migrations, models

**Files:**
- Create: `core/plugins/oblsk_shellbuilder/fxmanifest.lua`
- Create: `core/plugins/oblsk_shellbuilder/shared/config.lua`
- Create: `core/plugins/oblsk_shellbuilder/server/migrations/2026_08_15_100000_create_shells_table.lua`
- Create: `core/plugins/oblsk_shellbuilder/server/migrations/2026_08_15_100001_create_shell_owners_table.lua`
- Create: `core/plugins/oblsk_shellbuilder/server/migrations/2026_08_15_100002_create_shell_objects_table.lua`
- Create: `core/plugins/oblsk_shellbuilder/server/models/Shell.lua`
- Create: `core/plugins/oblsk_shellbuilder/server/models/ShellOwner.lua`
- Create: `core/plugins/oblsk_shellbuilder/server/models/ShellObject.lua`

**Interfaces:**
- Consumes: none (first task in the plugin).
- Produces: `shells`/`shell_owners`/`shell_objects` tables; `Shell`/`ShellOwner`/`ShellObject` model classes (`BaseModel:extend(...)`) for any later task that prefers the model API over raw `QueryBuilder`; `Config.Anchor`, `Config.EntryPoint`, `Config.DefaultObjectBudget` globals from `shared/config.lua`.

- [ ] **Step 1: Create the plugin manifest**

```lua
-- core/plugins/oblsk_shellbuilder/fxmanifest.lua
fx_version 'cerulean'
games { 'gta5' }

name 'ShellBuilder'
author ''
version '1.0.0'

dependencies {
    'obelisk'
}

shared_scripts {
    'shared/**/*.lua'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
    'web/routes.js',
    'web/globalElements.js',
}
```

- [ ] **Step 2: Create the shared config**

```lua
-- core/plugins/oblsk_shellbuilder/shared/config.lua
Config = {}

-- Every shell's interior geometry is placed at this one shared, fixed
-- coordinate far below the map. FiveM routing buckets already make two
-- different shells' occupants invisible and non-colliding to each other at
-- identical coordinates, so no per-shell coordinate allocation is needed.
Config.Anchor = { x = -3000.0, y = -3000.0, z = -500.0, heading = 0.0 }

-- The single world interaction that opens the shell browser. Staff can
-- relocate this by editing the coordinates below (e.g. to a "shell
-- builder's office" prop) - no code change needed.
Config.EntryPoint = { x = 215.0, y = -810.0, z = 30.7, range = 2.5, label = 'Shell Access Point' }

-- Default shell_objects budget for a newly-created shell (design's own cap).
Config.DefaultObjectBudget = 900

return Config
```

- [ ] **Step 3: Write the three migrations**

```lua
-- core/plugins/oblsk_shellbuilder/server/migrations/2026_08_15_100000_create_shells_table.lua
return {
    up = function()
        Schema.create('shells', function(table)
            table:id()
            table:string('name', 100)
            table:float('entry_x')
            table:float('entry_y')
            table:float('entry_z')
            table:float('entry_heading'):default(0)
            table:float('interior_heading'):default(0)
            table:integer('object_budget'):default(900)
            table:string('timecycle', 40):default('Neutral')
            table:integer('created_by_character_id')
            table:timestamps()
        end)

        print('[Migration] Created shells table')
    end,

    down = function()
        Schema.drop('shells')
        print('[Migration] Dropped shells table')
    end
}
```

```lua
-- core/plugins/oblsk_shellbuilder/server/migrations/2026_08_15_100001_create_shell_owners_table.lua
return {
    up = function()
        Schema.create('shell_owners', function(table)
            table:id()
            table:foreignId('shell_id'):constrained('shells'):onDelete('CASCADE')
            table:integer('character_id')
            table:timestamps()

            table:index({'shell_id'})
            table:index({'character_id'})
        end)

        print('[Migration] Created shell_owners table')
    end,

    down = function()
        Schema.drop('shell_owners')
        print('[Migration] Dropped shell_owners table')
    end
}
```

```lua
-- core/plugins/oblsk_shellbuilder/server/migrations/2026_08_15_100002_create_shell_objects_table.lua
return {
    up = function()
        Schema.create('shell_objects', function(table)
            table:id()
            table:foreignId('shell_id'):constrained('shells'):onDelete('CASCADE')
            table:string('item_key', 60)
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('heading'):default(0)
            table:integer('floor_level'):default(0)
            table:boolean('locked'):default(0)
            table:integer('placed_by_character_id'):nullable()
            table:json('color_data'):nullable()
            table:timestamps()

            table:index({'shell_id'})
        end)

        print('[Migration] Created shell_objects table')
    end,

    down = function()
        Schema.drop('shell_objects')
        print('[Migration] Dropped shell_objects table')
    end
}
```

- [ ] **Step 4: Write the three models**

```lua
-- core/plugins/oblsk_shellbuilder/server/models/Shell.lua
Shell = BaseModel:extend('shells')

Shell.primaryKey = 'id'
Shell.timestamps = true

Shell.fillable = {
    'name', 'entry_x', 'entry_y', 'entry_z', 'entry_heading', 'interior_heading',
    'object_budget', 'timecycle', 'created_by_character_id',
}

Shell.hidden = {}
Shell.casts = {}

return Shell
```

```lua
-- core/plugins/oblsk_shellbuilder/server/models/ShellOwner.lua
ShellOwner = BaseModel:extend('shell_owners')

ShellOwner.primaryKey = 'id'
ShellOwner.timestamps = true

ShellOwner.fillable = { 'shell_id', 'character_id' }
ShellOwner.hidden = {}
ShellOwner.casts = {}

return ShellOwner
```

```lua
-- core/plugins/oblsk_shellbuilder/server/models/ShellObject.lua
ShellObject = BaseModel:extend('shell_objects')

ShellObject.primaryKey = 'id'
ShellObject.timestamps = true

ShellObject.fillable = {
    'shell_id', 'item_key', 'x', 'y', 'z', 'heading', 'floor_level',
    'locked', 'placed_by_character_id', 'color_data',
}

ShellObject.hidden = {}
ShellObject.casts = {
    color_data = 'json',
}

return ShellObject
```

- [ ] **Step 5: Verify Lua syntax on every new file**

Run: `for f in core/plugins/oblsk_shellbuilder/fxmanifest.lua core/plugins/oblsk_shellbuilder/shared/config.lua core/plugins/oblsk_shellbuilder/server/migrations/*.lua core/plugins/oblsk_shellbuilder/server/models/*.lua; do luac5.4 -p "$f" || echo "FAILED: $f"; done`
Expected: no `FAILED` lines printed.

- [ ] **Step 6: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/fxmanifest.lua plugins/oblsk_shellbuilder/shared/config.lua plugins/oblsk_shellbuilder/server/migrations plugins/oblsk_shellbuilder/server/models
git commit -m "feat(shellbuilder): scaffold plugin manifest, config, migrations, models"
```

---

### Task 3: `ShellService` — CRUD, ownership, build-permission policy

**Files:**
- Create: `core/plugins/oblsk_shellbuilder/server/policies/CanBuildShellsPolicy.lua`
- Create: `core/plugins/oblsk_shellbuilder/server/services/ShellService.lua`
- Create: `core/plugins/oblsk_shellbuilder/tests/support/fake_query_builder.lua` (copy of `core/tests/support/fake_query_builder.lua`)
- Test: `core/plugins/oblsk_shellbuilder/tests/shell_service_spec.lua`

**Interfaces:**
- Consumes: `PermissionService.can(ownerType, ownerId, key)` (core, already registered), `PolicyService.register(policyId, validator, options)` (core), `CharacterService.getActiveCharacterId(source)` (stubbed in the test).
- Produces: `ShellService.create(createdByCharacterId, name) -> shell: table`, `ShellService.list() -> shell[]`, `ShellService.get(shellId) -> shell|nil`, `ShellService.delete(shellId)`, `ShellService.rename(shellId, name)`, `ShellService.setEntryCoords(shellId, x, y, z, heading)`, `ShellService.addOwner(shellId, characterId)`, `ShellService.removeOwner(shellId, characterId)`, `ShellService.isOwner(shellId, characterId) -> boolean`, `ShellService.listOwners(shellId) -> characterId[]`. Later tasks (5, 6, 7) call these directly.

- [ ] **Step 1: Copy the fake QueryBuilder test support file**

```bash
mkdir -p core/plugins/oblsk_shellbuilder/tests/support
cp core/tests/support/fake_query_builder.lua core/plugins/oblsk_shellbuilder/tests/support/fake_query_builder.lua
```

- [ ] **Step 2: Write the failing test**

```lua
-- core/plugins/oblsk_shellbuilder/tests/shell_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- PermissionService stub: settable per-test.
local GRANTED = {}
PermissionService = {}
function PermissionService.can(ownerType, ownerId, key)
    return GRANTED[ownerType .. ':' .. ownerId .. ':' .. key] == true
end

-- PolicyService stub: records registrations, doesn't execute them (the
-- policy's own validator function is exercised directly, see the tests
-- below).
PolicyService = { registry = {} }
function PolicyService.register(policyId, validator, options)
    PolicyService.registry[policyId] = validator
end

dofile(scriptDir .. '../server/policies/CanBuildShellsPolicy.lua')
dofile(scriptDir .. '../server/services/ShellService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    QueryBuilder = makeFakeQueryBuilderModule({})
    GRANTED = {}
    fn()
end

test('create inserts a shell with the default object budget from config', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test Hideout')
        eq(shell.name, 'Test Hideout')
        eq(shell.object_budget, Config.DefaultObjectBudget)
        eq(shell.created_by_character_id, 100)
    end)
end)

test('get returns the created shell by id', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test Hideout')
        local fetched = ShellService.get(shell.id)
        eq(fetched.id, shell.id)
        eq(fetched.name, 'Test Hideout')
    end)
end)

test('list returns every shell', function()
    withFreshState(function()
        ShellService.create(100, 'A')
        ShellService.create(100, 'B')
        eq(#ShellService.list(), 2)
    end)
end)

test('rename updates the shell name', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Old name')
        ShellService.rename(shell.id, 'New name')
        eq(ShellService.get(shell.id).name, 'New name')
    end)
end)

test('setEntryCoords updates the entry coordinates and heading', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        ShellService.setEntryCoords(shell.id, 1.5, 2.5, 3.5, 90.0)
        local fetched = ShellService.get(shell.id)
        eq(fetched.entry_x, 1.5)
        eq(fetched.entry_y, 2.5)
        eq(fetched.entry_z, 3.5)
        eq(fetched.entry_heading, 90.0)
    end)
end)

test('addOwner then isOwner reports true, removeOwner then isOwner reports false', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        eq(ShellService.isOwner(shell.id, 200), false)

        ShellService.addOwner(shell.id, 200)
        eq(ShellService.isOwner(shell.id, 200), true)

        ShellService.removeOwner(shell.id, 200)
        eq(ShellService.isOwner(shell.id, 200), false)
    end)
end)

test('a shell supports multiple owning characters', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Shared house')
        ShellService.addOwner(shell.id, 200)
        ShellService.addOwner(shell.id, 300)

        local owners = ShellService.listOwners(shell.id)
        eq(#owners, 2)
    end)
end)

test('delete removes the shell', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        ShellService.delete(shell.id)
        eq(ShellService.get(shell.id), nil)
    end)
end)

test('CanBuildShellsPolicy denies a character with no granted permission', function()
    withFreshState(function()
        local allowed, reason = PolicyService.registry['shellbuilder:canBuild'](7, { type = 'action', id = 1 }, {})
        eq(allowed, false)
        eq(reason, 'You do not have permission to build shells')
    end)
end)

test('CanBuildShellsPolicy allows a character with the granted permission', function()
    withFreshState(function()
        GRANTED['character:100:shellbuilder.build'] = true
        local allowed = PolicyService.registry['shellbuilder:canBuild'](7, { type = 'action', id = 1 }, {})
        eq(allowed, true)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

Note: the test's `CanBuildShellsPolicy` validator calls `CharacterService.getActiveCharacterId(source)` internally — Step 4 below defines the policy to resolve `source -> characterId` via `CharacterService`, so the test file above also needs a `CharacterService` stub before loading the policy file. Add it right after the `PermissionService` stub:

```lua
-- CharacterService stub: every source maps to character 100 for these tests.
CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    return 100
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua` (from `core/`)
Expected: FAIL — `ShellService` is nil (file doesn't exist yet).

- [ ] **Step 4: Write `CanBuildShellsPolicy`**

```lua
-- core/plugins/oblsk_shellbuilder/server/policies/CanBuildShellsPolicy.lua
--- CanBuildShellsPolicy - gates shell creation/edit-mode entry to admins
--- (FiveM ACE 'admin', same check IsAdminPolicy uses) or any character
--- explicitly granted the 'shellbuilder.build' permission via
--- PermissionService. Attached to the shellbuilder:create and
--- shellbuilder:edit actions in server/main.lua (Task 5).
local function canBuildShellsValidator(source, resource, config)
    if IsPlayerAceAllowed(source, 'admin') then
        return true
    end

    local characterId = CharacterService.getActiveCharacterId(source)
    if characterId and PermissionService.can('character', characterId, 'shellbuilder.build') then
        return true
    end

    return false, 'You do not have permission to build shells'
end

PolicyService.register('shellbuilder:canBuild', canBuildShellsValidator, {
    description = 'Checks admin ACE or a granted shellbuilder.build permission',
})

print('[Policy] Registered shellbuilder:canBuild policy')
```

- [ ] **Step 5: Write `ShellService`**

```lua
-- core/plugins/oblsk_shellbuilder/server/services/ShellService.lua
--- ShellService - shell CRUD and ownership. Kept free of any native/source
--- coupling so it's headless-testable; server/main.lua (Task 5) is the only
--- place that touches players/teleports directly.
ShellService = {}

--- @param createdByCharacterId number
--- @param name string
--- @return table shell row
function ShellService.create(createdByCharacterId, name)
    local id = QueryBuilder.new('shells'):insert({
        name = name,
        entry_x = Config.EntryPoint.x,
        entry_y = Config.EntryPoint.y,
        entry_z = Config.EntryPoint.z,
        entry_heading = 0,
        interior_heading = 0,
        object_budget = Config.DefaultObjectBudget,
        timecycle = 'Neutral',
        created_by_character_id = createdByCharacterId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return ShellService.get(id)
end

--- @return table[] every shell
function ShellService.list()
    return QueryBuilder.new('shells'):getSync()
end

--- @param shellId number
--- @return table|nil
function ShellService.get(shellId)
    return QueryBuilder.new('shells'):where('id', shellId):firstSync()
end

--- @param shellId number
function ShellService.delete(shellId)
    QueryBuilder.new('shell_owners'):where('shell_id', shellId):delete()
    QueryBuilder.new('shell_objects'):where('shell_id', shellId):delete()
    QueryBuilder.new('shells'):where('id', shellId):delete()
end

--- @param shellId number
--- @param name string
function ShellService.rename(shellId, name)
    QueryBuilder.new('shells'):where('id', shellId):update({
        name = name,
        updated_at = Database.now(),
    })
end

--- @param shellId number
--- @param x number
--- @param y number
--- @param z number
--- @param heading number
function ShellService.setEntryCoords(shellId, x, y, z, heading)
    QueryBuilder.new('shells'):where('id', shellId):update({
        entry_x = x,
        entry_y = y,
        entry_z = z,
        entry_heading = heading,
        updated_at = Database.now(),
    })
end

--- @param shellId number
--- @param characterId number
function ShellService.addOwner(shellId, characterId)
    if ShellService.isOwner(shellId, characterId) then return end

    QueryBuilder.new('shell_owners'):insert({
        shell_id = shellId,
        character_id = characterId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param shellId number
--- @param characterId number
function ShellService.removeOwner(shellId, characterId)
    QueryBuilder.new('shell_owners')
        :where('shell_id', shellId):where('character_id', characterId):delete()
end

--- @param shellId number
--- @param characterId number
--- @return boolean
function ShellService.isOwner(shellId, characterId)
    return QueryBuilder.new('shell_owners')
        :where('shell_id', shellId):where('character_id', characterId):firstSync() ~= nil
end

--- @param shellId number
--- @return number[] every owning character_id
function ShellService.listOwners(shellId)
    local rows = QueryBuilder.new('shell_owners'):where('shell_id', shellId):getSync()
    local ids = {}
    for _, row in ipairs(rows) do
        table.insert(ids, row.character_id)
    end
    return ids
end

return ShellService
```

- [ ] **Step 6: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua` (from `core/`)
Expected: `9 passed, 0 failed`

- [ ] **Step 7: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/server/policies/CanBuildShellsPolicy.lua plugins/oblsk_shellbuilder/server/services/ShellService.lua plugins/oblsk_shellbuilder/tests/support/fake_query_builder.lua plugins/oblsk_shellbuilder/tests/shell_service_spec.lua
git commit -m "feat(shellbuilder): add ShellService and CanBuildShellsPolicy"
```

---

### Task 4: `ShellObjectService` — catalog resolution, placement, budget, locked pieces

**Files:**
- Create: `core/plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua`
- Test: `core/plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua`

**Interfaces:**
- Consumes: `ItemService.binding(key)`, `ItemService.getRequiredBindingKeys()`, `ItemService.remove(source, baseItem, amount)`, `ItemService.add(source, baseItem, amount)` (all from core `oblsk_items`, stubbed in the test), `CharacterService.getActiveCharacterId(source)`.
- Produces: `ShellObjectService.catalog(tool: 'build'|'style'|'decor') -> entry[]` (each `{ key, name, category, model, tool }`, read from every `shellbuilder.*`-prefixed item binding whose bound item's `data.shell_tool` matches), `ShellObjectService.place(source, shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked) -> ok, objectOrReason`, `ShellObjectService.remove(source, shellId, objectId) -> ok, reason|nil`, `ShellObjectService.list(shellId) -> object[]`, `ShellObjectService.count(shellId) -> number`.

- [ ] **Step 1: Write the failing test**

```lua
-- core/plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- ItemService stub: a tiny in-memory bindings registry + owned-amount ledger.
local BINDINGS = {}   -- key -> { id, name, data = { shell_tool, shell_category, shell_model } }
local OWNED = {}       -- characterId -> key -> amount
ItemService = {}
function ItemService.getRequiredBindingKeys()
    local keys = {}
    for key in pairs(BINDINGS) do table.insert(keys, key) end
    return keys
end
function ItemService.binding(key)
    return BINDINGS[key]
end
function ItemService.remove(source, baseItem, amount)
    local characterId = CharacterService.getActiveCharacterId(source)
    local owned = (OWNED[characterId] or {})[baseItem.key] or 0
    if owned < amount then return false, 'Not enough items' end
    OWNED[characterId][baseItem.key] = owned - amount
    return true
end
function ItemService.add(source, baseItem, amount)
    local characterId = CharacterService.getActiveCharacterId(source)
    OWNED[characterId] = OWNED[characterId] or {}
    OWNED[characterId][baseItem.key] = (OWNED[characterId][baseItem.key] or 0) + amount
    return true
end

CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    if source == 1 then return 100 end
    return nil
end

dofile(scriptDir .. '../server/services/ShellObjectService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    QueryBuilder = makeFakeQueryBuilderModule({
        shells = { [1] = { id = 1, object_budget = 2 } },
    })
    BINDINGS = {
        ['shellbuilder.floor_wood'] = { key = 'shellbuilder.floor_wood', id = 1, name = 'Wooden Floor', data = { shell_tool = 'build', shell_category = 'Floors', shell_model = 'prop_floor_wood_01' } },
        ['shellbuilder.sofa_basic'] = { key = 'shellbuilder.sofa_basic', id = 2, name = 'Sofa', data = { shell_tool = 'decor', shell_category = 'Seating', shell_model = 'prop_sofa_01' } },
    }
    OWNED = { [100] = { ['shellbuilder.floor_wood'] = 5, ['shellbuilder.sofa_basic'] = 5 } }
    fn()
end

test('catalog returns only bindings whose shell_tool matches', function()
    withFreshState(function()
        local build = ShellObjectService.catalog('build')
        eq(#build, 1)
        eq(build[1].key, 'shellbuilder.floor_wood')

        local decor = ShellObjectService.catalog('decor')
        eq(#decor, 1)
        eq(decor[1].key, 'shellbuilder.sofa_basic')
    end)
end)

test('place consumes one item and inserts an unlocked object row for the placing character', function()
    withFreshState(function()
        local ok, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 1.0, 2.0, 3.0, 0, 0, nil, false)
        eq(ok, true)
        eq(obj.shell_id, 1)
        eq(obj.item_key, 'shellbuilder.sofa_basic')
        eq(obj.locked, false)
        eq(obj.placed_by_character_id, 100)
        eq(OWNED[100]['shellbuilder.sofa_basic'], 4)
    end)
end)

test('place rejects an unknown item_key', function()
    withFreshState(function()
        local ok, reason = ShellObjectService.place(1, 1, 'shellbuilder.does_not_exist', 0, 0, 0, 0, 0, nil, false)
        eq(ok, false)
        eq(reason, 'Unknown item')
    end)
end)

test('place rejects once the shell hits its object_budget', function()
    withFreshState(function()
        ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 1, 0, 0, 0, 0, nil, false)
        local ok, reason = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 2, 0, 0, 0, 0, nil, false)
        eq(ok, false)
        eq(reason, 'Shell has reached its object budget')
    end)
end)

test('place rejects when the character does not own the item', function()
    withFreshState(function()
        OWNED[100]['shellbuilder.sofa_basic'] = 0
        local ok, reason = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        eq(ok, false)
        eq(reason, 'Not enough items')
    end)
end)

test('remove deletes an unlocked object and refunds the item', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        local ok = ShellObjectService.remove(1, 1, obj.id)
        eq(ok, true)
        eq(#ShellObjectService.list(1), 0)
        eq(OWNED[100]['shellbuilder.sofa_basic'], 5)
    end)
end)

test('remove refuses to delete a locked object', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, true)
        local ok, reason = ShellObjectService.remove(1, 1, obj.id)
        eq(ok, false)
        eq(reason, 'This piece is locked')
        eq(#ShellObjectService.list(1), 1)
    end)
end)

test('count reflects the number of placed objects', function()
    withFreshState(function()
        eq(ShellObjectService.count(1), 0)
        ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        eq(ShellObjectService.count(1), 1)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua` (from `core/`)
Expected: FAIL — `ShellObjectService` is nil.

- [ ] **Step 3: Write the implementation**

```lua
-- core/plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua
--- ShellObjectService - the placeable catalog (drawn from oblsk_items
--- bindings prefixed "shellbuilder.") plus placement/removal, budget
--- enforcement, and the locked/unlocked split that makes "comes with
--- interior, not removable" vs "empty, owner furnishes it" possible without
--- a separate shell "kind": staff-placed structural/decor pieces are
--- inserted with locked = true; an owner's own placements are always
--- locked = false, and remove() refuses to touch a locked row.
ShellObjectService = {}

local PREFIX = 'shellbuilder.'

--- @param key string
--- @return boolean
local function hasPrefix(key)
    return key:sub(1, #PREFIX) == PREFIX
end

--- Every "shellbuilder.*" item binding whose bound item's data.shell_tool
--- matches `tool`. A binding that's required but not yet bound (or bound to
--- an item missing shell_tool/shell_category/shell_model) is skipped rather
--- than surfaced as a broken catalog entry.
--- @param tool string 'build' | 'style' | 'decor'
--- @return table[] { key, name, category, model, tool }
function ShellObjectService.catalog(tool)
    local entries = {}
    for _, key in ipairs(ItemService.getRequiredBindingKeys()) do
        if hasPrefix(key) then
            local item = ItemService.binding(key)
            if item and item.data and item.data.shell_tool == tool then
                table.insert(entries, {
                    key = key,
                    name = item.name,
                    category = item.data.shell_category,
                    model = item.data.shell_model,
                    tool = tool,
                })
            end
        end
    end
    return entries
end

--- @param shellId number
--- @return table[] every shell_objects row for this shell
function ShellObjectService.list(shellId)
    return QueryBuilder.new('shell_objects'):where('shell_id', shellId):getSync()
end

--- @param shellId number
--- @return number
function ShellObjectService.count(shellId)
    return #ShellObjectService.list(shellId)
end

--- @param source number the placing player
--- @param shellId number
--- @param itemKey string a "shellbuilder.*" binding key
--- @param x number
--- @param y number
--- @param z number
--- @param heading number
--- @param floorLevel number
--- @param colorData table|nil
--- @param locked boolean true for a staff-placed, owner-immutable piece
--- @return boolean ok
--- @return table|string objectOrReason the inserted row on success, a reason string on failure
function ShellObjectService.place(source, shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked)
    local shell = QueryBuilder.new('shells'):where('id', shellId):firstSync()
    if not shell then
        return false, 'Unknown shell'
    end

    local item = ItemService.binding(itemKey)
    if not item then
        return false, 'Unknown item'
    end

    if ShellObjectService.count(shellId) >= shell.object_budget then
        return false, 'Shell has reached its object budget'
    end

    local removed, reason = ItemService.remove(source, item, 1)
    if not removed then
        return false, reason or 'Not enough items'
    end

    local characterId = CharacterService.getActiveCharacterId(source)

    local id = QueryBuilder.new('shell_objects'):insert({
        shell_id = shellId,
        item_key = itemKey,
        x = x,
        y = y,
        z = z,
        heading = heading or 0,
        floor_level = floorLevel or 0,
        locked = locked and true or false,
        placed_by_character_id = locked and nil or characterId,
        color_data = colorData or {},
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return true, QueryBuilder.new('shell_objects'):where('id', id):firstSync()
end

--- Deletes a placed object and refunds the item it was placed from, unless
--- the object is locked (a staff-placed structural/fixed piece).
--- @param source number the removing player, credited the refund
--- @param shellId number
--- @param objectId number
--- @return boolean ok
--- @return string|nil reason
function ShellObjectService.remove(source, shellId, objectId)
    local object = QueryBuilder.new('shell_objects')
        :where('id', objectId):where('shell_id', shellId):firstSync()
    if not object then
        return false, 'Unknown object'
    end
    if object.locked then
        return false, 'This piece is locked'
    end

    local item = ItemService.binding(object.item_key)
    QueryBuilder.new('shell_objects'):where('id', objectId):delete()

    if item then
        ItemService.add(source, item, 1)
    end

    return true
end

return ShellObjectService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua` (from `core/`)
Expected: `8 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
git commit -m "feat(shellbuilder): add ShellObjectService with catalog, budget, locked pieces"
```

---

### Task 5: Server + client wiring — interaction, actions, teleport

**Files:**
- Create: `core/plugins/oblsk_shellbuilder/server/main.lua`
- Create: `core/plugins/oblsk_shellbuilder/client/main.lua`

**Interfaces:**
- Consumes: `ShellService.*` (Task 3), `ShellObjectService.*` (Task 4), `InstanceService.enter/leave` (Task 1), core `InteractionService.register`, `ActionService.register`, `PolicyService.attach`, `WebView.openPage/focus/emit/on`, `Obelisk.emit*/on*`, `NotificationService.notify`, `CharacterService.getActiveCharacterId`.
- Produces: net events `shellbuilder:server:sync` (pushes the browser its data), `shellbuilder:server:enterShell` / `shellbuilder:server:exitShell` (teleport + focus toggling), `shellbuilder:server:catalog`, `shellbuilder:server:objectPlaced` / `shellbuilder:server:objectRemoved`; NUI callback names `shellbuilder:open`, `shellbuilder:create`, `shellbuilder:enter`, `shellbuilder:edit`, `shellbuilder:exit`, `shellbuilder:place`, `shellbuilder:removeObject` — Tasks 6 and 7's Vue components call these via `WebView.on`'s client-side counterparts below.

- [ ] **Step 1: Write `server/main.lua`**

```lua
-- core/plugins/oblsk_shellbuilder/server/main.lua
print('[ShellBuilder] Loading...')

--- @param source number
--- @return table { canBuild: boolean, ownedShellIds: number[] }
local function permissionsFor(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    local canBuild = IsPlayerAceAllowed(source, 'admin')
        or (characterId and PermissionService.can('character', characterId, 'shellbuilder.build'))

    local ownedShellIds = {}
    if characterId then
        for _, shell in ipairs(ShellService.list()) do
            if ShellService.isOwner(shell.id, characterId) then
                table.insert(ownedShellIds, shell.id)
            end
        end
    end

    return { canBuild = canBuild and true or false, ownedShellIds = ownedShellIds }
end

local function openBrowser(source)
    WebView.openPage(source, '/ShellBrowser')
    WebView.focus(source)
    Obelisk.emitClient('shellbuilder:server:sync', source, {
        shells = ShellService.list(),
        permissions = permissionsFor(source),
    })
end

ActionService.register('shellbuilder:open', function(source, data)
    openBrowser(source)
end, { label = 'Access shells' })

PolicyService.attach('action', 'shellbuilder:create', 'shellbuilder:canBuild')
PolicyService.attach('action', 'shellbuilder:edit', 'shellbuilder:canBuild')

Obelisk.onServer('shellbuilder:client:create', function(name)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:create')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end

    local characterId = CharacterService.getActiveCharacterId(source)
    local shell = ShellService.create(characterId, name)
    Obelisk.emitClient('shellbuilder:server:sync', source, {
        shells = ShellService.list(),
        permissions = permissionsFor(source),
    })
end)

Obelisk.onServer('shellbuilder:client:enter', function(shellId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or not ShellService.isOwner(shellId, characterId) then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = 'You do not own this shell' })
        return
    end

    InstanceService.enter(source, 'shellbuilder:shell:' .. shellId)
    local shell = ShellService.get(shellId)
    SetEntityCoords(GetPlayerPed(source), Config.Anchor.x, Config.Anchor.y, Config.Anchor.z, false, false, false, false)
    SetEntityHeading(GetPlayerPed(source), shell.interior_heading)
    WebView.hide(source)
    Obelisk.emitClient('shellbuilder:server:entered', source, { shellId = shellId, mode = 'walk' })
end)

Obelisk.onServer('shellbuilder:client:edit', function(shellId)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end

    InstanceService.enter(source, 'shellbuilder:shell:' .. shellId)
    local shell = ShellService.get(shellId)
    SetEntityCoords(GetPlayerPed(source), Config.Anchor.x, Config.Anchor.y, Config.Anchor.z, false, false, false, false)
    SetEntityHeading(GetPlayerPed(source), shell.interior_heading)
    WebView.openPage(source, '/ShellEditor')
    WebView.focus(source)
    Obelisk.emitClient('shellbuilder:server:entered', source, { shellId = shellId, mode = 'edit' })
    Obelisk.emitClient('shellbuilder:server:editSync', source, {
        shell = shell,
        objects = ShellObjectService.list(shellId),
        catalogBuild = ShellObjectService.catalog('build'),
        catalogStyle = ShellObjectService.catalog('style'),
        catalogDecor = ShellObjectService.catalog('decor'),
    })
end)

Obelisk.onServer('shellbuilder:client:exit', function(shellId)
    local source = source
    local shell = ShellService.get(shellId)
    InstanceService.leave(source)
    if shell then
        SetEntityCoords(GetPlayerPed(source), shell.entry_x, shell.entry_y, shell.entry_z, false, false, false, false)
        SetEntityHeading(GetPlayerPed(source), shell.entry_heading)
    end
    WebView.hide(source)
    Obelisk.emitClient('shellbuilder:server:exited', source, {})
end)

Obelisk.onServer('shellbuilder:client:place', function(shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked)
    local source = source
    if locked then
        local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
        if not ok then
            NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
            return
        end
    end

    local ok, objectOrReason = ShellObjectService.place(source, shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked)
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Could not place', description = objectOrReason })
        return
    end

    Obelisk.emitClient('shellbuilder:server:objectPlaced', source, objectOrReason)
end)

Obelisk.onServer('shellbuilder:client:removeObject', function(shellId, objectId)
    local source = source
    local ok, reason = ShellObjectService.remove(source, shellId, objectId)
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Could not remove', description = reason })
        return
    end

    Obelisk.emitClient('shellbuilder:server:objectRemoved', source, { objectId = objectId })
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end

    InteractionService.register({
        x = Config.EntryPoint.x, y = Config.EntryPoint.y, z = Config.EntryPoint.z,
        range = Config.EntryPoint.range, label = Config.EntryPoint.label,
        action = 'shellbuilder:open',
    })

    print('[ShellBuilder] Loaded successfully!')
end)
```

- [ ] **Step 2: Write `client/main.lua`**

```lua
-- core/plugins/oblsk_shellbuilder/client/main.lua
print('[ShellBuilder] Client loading...')

WebView.on('shellbuilder:create', function(data)
    WebView.emitServer('shellbuilder:client:create', data.name)
end)

WebView.on('shellbuilder:enter', function(data)
    WebView.emitServer('shellbuilder:client:enter', data.shellId)
end)

WebView.on('shellbuilder:edit', function(data)
    WebView.emitServer('shellbuilder:client:edit', data.shellId)
end)

WebView.on('shellbuilder:exit', function(data)
    WebView.emitServer('shellbuilder:client:exit', data.shellId)
end)

WebView.on('shellbuilder:place', function(data)
    WebView.emitServer('shellbuilder:client:place', data.shellId, data.itemKey,
        data.x, data.y, data.z, data.heading, data.floorLevel, data.colorData, data.locked)
end)

WebView.on('shellbuilder:removeObject', function(data)
    WebView.emitServer('shellbuilder:client:removeObject', data.shellId, data.objectId)
end)

Obelisk.onClient('shellbuilder:server:sync', function(payload)
    WebView.emit('shellbuilder:sync', payload)
end)

Obelisk.onClient('shellbuilder:server:entered', function(payload)
    WebView.emit('shellbuilder:entered', payload)
end)

Obelisk.onClient('shellbuilder:server:editSync', function(payload)
    WebView.emit('shellbuilder:editSync', payload)
end)

Obelisk.onClient('shellbuilder:server:exited', function(payload)
    WebView.emit('shellbuilder:exited', payload)
end)

Obelisk.onClient('shellbuilder:server:objectPlaced', function(payload)
    WebView.emit('shellbuilder:objectPlaced', payload)
end)

Obelisk.onClient('shellbuilder:server:objectRemoved', function(payload)
    WebView.emit('shellbuilder:objectRemoved', payload)
end)
```

- [ ] **Step 3: Verify Lua syntax**

Run: `luac5.4 -p core/plugins/oblsk_shellbuilder/server/main.lua && luac5.4 -p core/plugins/oblsk_shellbuilder/client/main.lua`
Expected: no output, exit code 0 for both.

- [ ] **Step 4: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/server/main.lua plugins/oblsk_shellbuilder/client/main.lua
git commit -m "feat(shellbuilder): wire interaction, actions, and dimension teleport"
```

---

### Task 6: Vue — `ShellBrowser.vue` (list, detail, create, enter/edit)

**Files:**
- Create: `core/plugins/oblsk_shellbuilder/web/routes.js`
- Create: `core/plugins/oblsk_shellbuilder/web/ShellBrowser.vue`

**Interfaces:**
- Consumes: `Obelisk.on(eventName, handler)` / `Obelisk.emit(eventName, data)` (the JS-side singleton every other plugin's `.vue` file uses to talk to `WebView.on`/`WebView.emit` in `client/main.lua`), events from Task 5: `shellbuilder:sync` (`{ shells, permissions: { canBuild, ownedShellIds } }`), emits `shellbuilder:create` (`{ name }`), `shellbuilder:enter` (`{ shellId }`), `shellbuilder:edit` (`{ shellId }`).
- Produces: the `/ShellBrowser` route Task 5's `WebView.openPage(source, '/ShellBrowser')` opens.

- [ ] **Step 1: Register the route**

```js
// core/plugins/oblsk_shellbuilder/web/routes.js
export default [
  {
    path: '/ShellBrowser',
    name: 'ShellBrowser',
    component: () => import('./ShellBrowser.vue')
  },
  {
    path: '/ShellEditor',
    name: 'ShellEditor',
    component: () => import('./ShellEditor.vue')
  }
]
```

- [ ] **Step 2: Write `ShellBrowser.vue`**

```vue
<!-- core/plugins/oblsk_shellbuilder/web/ShellBrowser.vue -->
<!-- Shell browser — ported from the Claude Design reference's SbBrowser
     (src/proto/shell-browser.jsx): a shell list on the left, detail +
     actions on the right. Trimmed to what the signed-in player can
     actually do: owners get Enter, build-permission staff also get Edit,
     Create, and Delete. -->
<template>
  <div class="absolute inset-0 grid place-items-center">
    <div class="rounded-[14px] overflow-hidden flex flex-col"
      style="width:1180px;height:780px;background:color-mix(in oklab, var(--ob-accent) 5%, rgba(8,11,10,.94));border:1px solid color-mix(in oklab, var(--ob-accent) 35%, transparent)">
      <div class="shrink-0 text-center pt-5 pb-4">
        <div class="text-[20px] font-semibold uppercase tracking-wide">Shell Creator</div>
        <div class="text-[11.5px] text-white/40 mt-0.5">interiors for housing, businesses and hideouts</div>
      </div>

      <div class="flex-1 min-h-0 flex gap-4 px-5">
        <!-- list -->
        <div class="flex-1 min-w-0 flex flex-col gap-2.5 overflow-y-auto pr-1"
          style="border-right:1px solid color-mix(in oklab, var(--ob-accent) 30%, transparent)">
          <button v-if="permissions.canBuild" @click="creating = true"
            class="shrink-0 h-[76px] rounded-[9px] text-[14px] font-semibold uppercase tracking-wide flex items-center justify-center gap-2"
            style="background:color-mix(in oklab, var(--ob-accent) 14%, transparent);border:1px dashed color-mix(in oklab, var(--ob-accent) 55%, transparent);color:#fff">
            Create new shell +
          </button>

          <button v-for="shell in shells" :key="shell.id" @click="selectedId = shell.id"
            class="shrink-0 rounded-[9px] p-3 flex items-start gap-3 text-left"
            :style="rowStyle(shell.id)">
            <span class="min-w-0 flex-1">
              <span class="block text-[15px] font-semibold uppercase tracking-wide leading-tight">{{ shell.name }}</span>
              <span class="block text-[10px] text-white/32 mt-3">Objects: {{ shell.object_budget }} max</span>
              <span v-if="permissions.ownedShellIds.includes(shell.id)" class="block text-[10px] text-white/32">You own this shell</span>
            </span>
          </button>

          <div v-if="shells.length === 0" class="text-[12px] text-white/35 text-center py-6">No shells yet</div>
        </div>

        <!-- detail -->
        <div class="shrink-0 flex flex-col" style="width:520px">
          <template v-if="selected">
            <div class="text-[18px] font-semibold uppercase tracking-wide mb-2.5">{{ selected.name }}</div>
            <div class="grid grid-cols-2 gap-x-6 gap-y-1.5 mt-3.5 text-[12px]">
              <div><span class="text-white/40">ID:</span> {{ selected.id }}</div>
              <div><span class="text-white/40">Timecycle:</span> {{ selected.timecycle }}</div>
              <div><span class="text-white/40">Budget:</span> {{ selected.object_budget }}</div>
            </div>
            <div class="grid grid-cols-2 gap-2 mt-4">
              <button v-if="isOwner(selected.id)" @click="enter(selected.id)"
                class="h-[38px] rounded-[7px] text-[12.5px] font-semibold uppercase tracking-wide"
                style="background:var(--ob-accent);color:#04120d">Enter</button>
              <button v-if="permissions.canBuild" @click="edit(selected.id)"
                class="h-[38px] rounded-[7px] text-[12.5px] font-semibold uppercase tracking-wide"
                style="background:var(--ob-accent);color:#04120d">Edit</button>
            </div>
          </template>
          <div v-else class="text-[12px] text-white/35">Select a shell</div>
        </div>
      </div>

      <div class="shrink-0 px-5 py-3.5">
        <button @click="close"
          class="w-full h-[38px] rounded-[7px] text-[13px] font-semibold uppercase tracking-wide"
          style="border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent);color:rgba(255,255,255,.75)">
          Exit
        </button>
      </div>
    </div>

    <div v-if="creating" class="absolute inset-0 z-30 grid place-items-center" style="background:rgba(0,0,0,.55)" @click="creating = false">
      <div @click.stop class="rounded-[12px] p-5" style="width:360px;background:color-mix(in oklab, var(--ob-accent) 6%, rgba(8,11,10,.96));border:1px solid color-mix(in oklab, var(--ob-accent) 40%, transparent)">
        <div class="text-[15px] font-semibold uppercase tracking-wide mb-3">New shell</div>
        <input v-model="newName" placeholder="Shell name"
          class="w-full h-[34px] rounded-[6px] px-2.5 text-[12.5px] bg-black/45 outline-none mb-3"
          style="border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent)" />
        <button @click="createShell"
          class="w-full h-[38px] rounded-[7px] text-[12.5px] font-semibold uppercase tracking-wide"
          style="background:var(--ob-accent);color:#04120d">Create</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'

const shells = ref([])
const permissions = ref({ canBuild: false, ownedShellIds: [] })
const selectedId = ref(null)
const creating = ref(false)
const newName = ref('')

const selected = computed(() => shells.value.find(s => s.id === selectedId.value) || null)

function isOwner(shellId) {
  return permissions.value.ownedShellIds.includes(shellId)
}

function rowStyle(shellId) {
  const on = shellId === selectedId.value
  return {
    background: on ? 'color-mix(in oklab, var(--ob-accent) 13%, transparent)' : 'rgba(255,255,255,.03)',
    border: `1px solid ${on ? 'var(--ob-accent)' : 'color-mix(in oklab, var(--ob-accent) 22%, transparent)'}`,
  }
}

function createShell() {
  if (!newName.value.trim()) return
  Obelisk.emit('shellbuilder:create', { name: newName.value.trim() })
  creating.value = false
  newName.value = ''
}

function enter(shellId) {
  Obelisk.emit('shellbuilder:enter', { shellId })
}

function edit(shellId) {
  Obelisk.emit('shellbuilder:edit', { shellId })
}

function close() {
  Obelisk.emit('core:client:close', {})
}

Obelisk.on('shellbuilder:sync', (payload) => {
  shells.value = payload.shells || []
  permissions.value = payload.permissions || { canBuild: false, ownedShellIds: [] }
  if (!selectedId.value && shells.value.length) {
    selectedId.value = shells.value[0].id
  }
})
</script>
```

- [ ] **Step 3: Manual verification**

Since Vue components aren't unit-testable here (no headless DOM harness in this repo, matching every other plugin), verify by running the plugin's `web/` Vite dev build (`npm run dev` inside `web/`, per this repo's Vue-plugin convention) and confirming `ShellBrowser.vue` renders without a console error given a mocked `shellbuilder:sync` payload.

- [ ] **Step 4: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/web/routes.js plugins/oblsk_shellbuilder/web/ShellBrowser.vue
git commit -m "feat(shellbuilder): add ShellBrowser.vue"
```

---

### Task 7: Vue — `ShellEditor.vue` (bottom-dock build UI)

**Files:**
- Create: `core/plugins/oblsk_shellbuilder/web/globalElements.js`
- Create: `core/plugins/oblsk_shellbuilder/web/ShellEditor.vue`

**Interfaces:**
- Consumes: `shellbuilder:editSync` (`{ shell, objects, catalogBuild, catalogStyle, catalogDecor }`), `shellbuilder:objectPlaced`, `shellbuilder:objectRemoved`, `shellbuilder:exited`; emits `shellbuilder:place` (`{ shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked }`), `shellbuilder:removeObject` (`{ shellId, objectId }`), `shellbuilder:exit` (`{ shellId }`).
- Produces: the `/ShellEditor` route Task 5's `WebView.openPage(source, '/ShellEditor')` opens.

- [ ] **Step 1: Register as a global element (so the walk-toggle preview can hide the dock without unmounting it)**

```js
// core/plugins/oblsk_shellbuilder/web/globalElements.js
import ShellEditor from './ShellEditor.vue'

export default [
  { name: 'shellEditor', component: ShellEditor, defaultVisible: false }
]
```

- [ ] **Step 2: Write `ShellEditor.vue`**

```vue
<!-- core/plugins/oblsk_shellbuilder/web/ShellEditor.vue -->
<!-- Bottom-dock shell editor — ported from the Claude Design reference's
     SbEditor (src/proto/shell-builder.jsx). Tool rail is filtered by
     `canBuild` (Construction/Style are staff-only; Decorate is the only
     tool an owner without build permission ever sees). The palette/tool
     rail render from the server's real oblsk_items-backed catalog, not a
     static list. Placement/removal round-trips through the server so
     budget and locked-piece checks (ShellObjectService, Task 4) are
     authoritative. -->
<template>
  <div v-if="shell" class="absolute inset-0">
    <div class="absolute left-6 top-5 flex items-center gap-2.5">
      <span class="text-[14px] font-semibold uppercase tracking-wide">{{ shell.name }}</span>
      <span class="text-[10px] text-white/35 font-mono">EDITOR</span>
    </div>

    <div v-if="!walking" class="absolute left-0 right-0 bottom-0 flex" style="height:268px;background:rgba(4,7,6,.97);border-top:1px solid color-mix(in oklab, var(--ob-accent) 30%, transparent)">
      <!-- tool rail -->
      <div class="shrink-0 flex flex-col items-center justify-center gap-3 px-3" style="width:74px;border-right:1px solid rgba(255,255,255,.07)">
        <button v-for="t in availableTools" :key="t" @click="tool = t"
          class="w-[46px] h-[46px] rounded-[9px] grid place-items-center text-[10px] uppercase"
          :style="tool === t ? { background: 'color-mix(in oklab, var(--ob-accent) 26%, transparent)', border: '1px solid var(--ob-accent)' } : { background: 'rgba(255,255,255,.04)', border: '1px solid rgba(255,255,255,.1)' }">
          {{ t[0] }}
        </button>
      </div>

      <!-- items -->
      <div class="flex-1 min-w-0 flex flex-col py-3 px-3.5">
        <div class="text-[11px] text-white/45 uppercase tracking-wide mb-2">{{ tool }} · {{ items.length }} items</div>
        <div class="flex-1 min-h-0 overflow-y-auto flex flex-wrap gap-2 content-start">
          <button v-for="entry in items" :key="entry.key" @click="selectedItem = entry.key"
            class="rounded-[7px] px-2.5 py-2 text-[10.5px] text-left"
            :style="selectedItem === entry.key ? { background: 'color-mix(in oklab, var(--ob-accent) 30%, transparent)', border: '1px solid var(--ob-accent)' } : { background: 'color-mix(in oklab, var(--ob-accent) 10%, transparent)', border: '1px solid rgba(255,255,255,.1)' }">
            <div>{{ entry.name }}</div>
            <div class="text-white/40">{{ entry.category }}</div>
          </button>
          <div v-if="items.length === 0" class="text-[11px] text-white/35">Nothing in this category</div>
        </div>
      </div>

      <!-- budget + controls -->
      <div class="shrink-0 flex flex-col items-center gap-2 py-3 px-3" style="width:220px;border-left:1px solid rgba(255,255,255,.07)">
        <div class="w-full h-[24px] rounded-full relative overflow-hidden" style="background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.12)">
          <span class="absolute inset-y-0 left-0" :style="{ width: budgetPct + '%', background: 'var(--ob-accent)', opacity: .75 }" />
          <span class="absolute inset-0 flex items-center justify-center text-[10.5px] font-mono">{{ objects.length }} / {{ shell.object_budget }}</span>
        </div>
        <div class="flex gap-2 mt-1">
          <button @click="wreck = !wreck" class="h-[34px] px-3 rounded-[7px] text-[11px] uppercase"
            :style="wreck ? { background: 'rgba(190,40,40,.35)', border: '1px solid #ef4444' } : { background: 'rgba(255,255,255,.04)', border: '1px solid rgba(255,255,255,.1)' }">
            Delete mode
          </button>
          <button @click="walking = true" class="h-[34px] px-3 rounded-[7px] text-[11px] uppercase"
            style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.1)">
            Walk preview
          </button>
        </div>
        <button @click="exitEditor" class="mt-auto h-[36px] w-full rounded-[7px] text-[12px] uppercase"
          style="background:var(--ob-accent);color:#04120d">Save & exit</button>
      </div>
    </div>

    <button v-else @click="walking = false"
      class="absolute left-6 bottom-6 h-[38px] px-4 rounded-[7px] text-[12px] uppercase"
      style="background:var(--ob-accent);color:#04120d">
      Back to editor
    </button>
  </div>
</template>

<script setup>
import { ref, computed, watch } from 'vue'

const shell = ref(null)
const objects = ref([])
const catalogBuild = ref([])
const catalogStyle = ref([])
const catalogDecor = ref([])
const canBuild = ref(false)

const tool = ref('decor')
const selectedItem = ref(null)
const wreck = ref(false)
const walking = ref(false)

const availableTools = computed(() => canBuild.value ? ['build', 'style', 'decor'] : ['decor'])

const items = computed(() => {
  if (tool.value === 'build') return catalogBuild.value
  if (tool.value === 'style') return catalogStyle.value
  return catalogDecor.value
})

const budgetPct = computed(() => shell.value ? Math.min(100, (objects.value.length / shell.value.object_budget) * 100) : 0)

// A staff editor placing from Construction/Style always locks the piece
// (structural, owner-immutable); an owner in the Decorate tool always
// places unlocked furniture they can later remove themselves.
function place(x, y, z, heading, floorLevel) {
  if (!selectedItem.value || !shell.value) return
  const locked = canBuild.value && tool.value !== 'decor'
  Obelisk.emit('shellbuilder:place', {
    shellId: shell.value.id,
    itemKey: selectedItem.value,
    x, y, z, heading, floorLevel,
    colorData: null,
    locked,
  })
}

function removeObject(objectId) {
  if (!shell.value) return
  Obelisk.emit('shellbuilder:removeObject', { shellId: shell.value.id, objectId })
}

function exitEditor() {
  if (!shell.value) return
  Obelisk.emit('shellbuilder:exit', { shellId: shell.value.id })
}

Obelisk.on('shellbuilder:editSync', (payload) => {
  shell.value = payload.shell
  objects.value = payload.objects || []
  catalogBuild.value = payload.catalogBuild || []
  catalogStyle.value = payload.catalogStyle || []
  catalogDecor.value = payload.catalogDecor || []
})

Obelisk.on('shellbuilder:objectPlaced', (object) => {
  objects.value.push(object)
})

Obelisk.on('shellbuilder:objectRemoved', ({ objectId }) => {
  objects.value = objects.value.filter(o => o.id !== objectId)
})

Obelisk.on('shellbuilder:exited', () => {
  shell.value = null
  objects.value = []
})

watch(availableTools, (tools) => {
  if (!tools.includes(tool.value)) tool.value = 'decor'
})

defineExpose({ place, removeObject })
</script>
```

- [ ] **Step 3: Manual verification**

`client/main.lua` (Task 5) opens `/ShellEditor` as a page for the initial edit-mode entry; `walking`'s "Back to editor" toggle only needs to switch local component state (no native call), matching the design's `walk` toggle. Verify in a browser-driven dev build that switching `tool` correctly filters `availableTools`/`items`, and that `canBuild = false` (an owner without build permission) only ever shows the Decorate tool. Full in-game placement/removal/teleport is exercised in Task 8's manual checklist.

- [ ] **Step 4: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/web/globalElements.js plugins/oblsk_shellbuilder/web/ShellEditor.vue
git commit -m "feat(shellbuilder): add ShellEditor.vue"
```

---

### Task 8: Registry, README, full test run, manual verification

**Files:**
- Modify: `core/plugins/registry.json`
- Create: `core/plugins/oblsk_shellbuilder/README.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — this task wires the plugin into boot and documents it.

- [ ] **Step 1: Add the plugin to the registry**

Run: `cd core && node cli/index.js registry:generate` (regenerates `plugins/registry.json` from disk, per `core/docs/concepts/modules-and-plugins.md`'s documented workflow — run on the host, not inside the Docker container).

Expected: `plugins/registry.json`'s `"plugins"` array now includes `"oblsk_shellbuilder"`.

If the CLI isn't runnable in this environment, add it by hand instead:

```json
{
  "plugins": [
    "oblsk_admin",
    "oblsk_banking",
    "oblsk_character-selection",
    "oblsk_deathscreen",
    "oblsk_garage",
    "oblsk_cardealer",
    "oblsk_hud",
    "oblsk_inventory",
    "oblsk_keybinds",
    "oblsk_licenses",
    "oblsk_mdt",
    "oblsk_notifications",
    "oblsk_payment",
    "oblsk_phone",
    "oblsk_phonebooth",
    "oblsk_progressbar",
    "oblsk_radialmenu",
    "oblsk_shellbuilder",
    "oblsk_shop",
    "oblsk_speedometer",
    "oblsk_terminal",
    "oblsk_tuner"
  ]
}
```

- [ ] **Step 2: Write the README**

```markdown
# oblsk_shellbuilder

## Description
Staff-built, character-owned enterable interiors ("shells") — houses,
hideouts, workshops. A shell can come fully furnished (staff place and lock
every piece, an owner can't remove any of it) or empty (an owner furnishes
it themselves via the Decorate tool). Every shell lives in its own FiveM
routing bucket (see `core/server/Services/InstanceService.lua`), so
multiple shells share one fixed underground anchor coordinate without
occupants of different shells ever seeing or colliding with each other.
Multiple characters can own the same shell.

See `docs/superpowers/specs/2026-08-15-shell-builder-plugin-design.md` for
the full design.

## Access
A single world interaction (`Config.EntryPoint` in `shared/config.lua`)
opens the shell browser. Owners (rows in `shell_owners`) see **Enter**.
Anyone with the ACE `admin` permission, or a character explicitly granted
`shellbuilder.build` via `PermissionService`, also sees **Edit** and
**Create new shell**.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).

## Placeable catalog
Placeable objects are `oblsk_items` bindings whose key is prefixed
`shellbuilder.` (e.g. `shellbuilder.floor_wood`, `shellbuilder.sofa_basic`).
Each bound base item's `data` column needs `shell_tool` (`build` | `style` |
`decor`), `shell_category`, and `shell_model` set for it to appear in the
editor's catalog — see `ShellObjectService.catalog` in
`server/services/ShellObjectService.lua`.
```

- [ ] **Step 3: Run every new test file**

Run (from `core/`):
```bash
lua5.4 tests/instance_service_spec.lua
lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua
lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
```
Expected: all three print `N passed, 0 failed` with no `FAIL` lines.

- [ ] **Step 4: Verify Lua syntax across the whole plugin**

Run: `find plugins/oblsk_shellbuilder -name '*.lua' -exec luac5.4 -p {} \; ` (from `core/`)
Expected: no output (a syntax error would print to stderr and exit non-zero per file).

- [ ] **Step 5: Manual verification checklist** (not automatable — no in-game harness in this repo)

1. Bind at least two `shellbuilder.*` items in `item_bindings` (one `shell_tool = 'decor'`, one `shell_tool = 'build'`) so the editor's catalog isn't empty.
2. As an admin, walk to `Config.EntryPoint`, press the interaction, confirm the browser opens and **Create new shell** works.
3. **Edit** the new shell: confirm teleport to `Config.Anchor`, confirm the bottom dock renders, place a `decor` item and a `build` item, confirm both appear as rows in `shell_objects` (one `locked = true`, one `locked = false` per which tool placed it).
4. Grant a second, non-admin character `shellbuilder.build` via `PermissionService.grant('character', characterId, 'shellbuilder.build')`; confirm they also see Edit/Create.
5. Add a third character as an owner via `ShellService.addOwner`; confirm they see **Enter** (not Edit), and that opening the shell as owner only ever shows the Decorate tool with the locked `build`-tool piece from step 3 not removable (attempt `shellbuilder:removeObject` on it, confirm the server rejects with "This piece is locked").
6. With two different shells created, confirm a player inside shell A cannot see or collide with a player inside shell B, even though both are physically at `Config.Anchor`.
7. Toggle **Walk preview**; confirm the dock hides and the player can walk normally inside the shell, then **Back to editor** restores the dock.
8. **Save & exit** from the editor; confirm teleport back to the shell's `entry_x/y/z` and the routing bucket resets to `0` (`InstanceService.leave`).

- [ ] **Step 6: Commit**

```bash
cd core
git add plugins/registry.json plugins/oblsk_shellbuilder/README.md
git commit -m "feat(shellbuilder): register plugin and document it"
```

---

## Self-Review Notes

- **Spec coverage:** InstanceService (Task 1) ✓, shared anchor (`Config.Anchor`, Task 2) ✓, data model — `shells`/`shell_owners`/`shell_objects`/`instance_buckets` (Tasks 1-2) ✓, entry flow via single `InteractionService` registration + browser (Tasks 5-6) ✓, build permission via `PolicyService`/`PermissionService` (Task 3) ✓, editor UI with tool-rail gating (Task 7) ✓, walkthrough preview reusing the existing walk toggle (Task 7) ✓, `oblsk_items`-driven catalog (Task 4) ✓, locked/unlocked object model replacing a shell "kind" (Task 4) ✓, testing per the spec's server-only-tests posture (Tasks 1, 3, 4, 8) ✓.
- **Placeholder scan:** none found — every step has complete code, migrations, or a concrete manual-verification action.
- **Type consistency checked:** `ShellObjectService.place`'s parameter order (`source, shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked`) matches exactly between Task 4's implementation, Task 4's test calls, Task 5's `Obelisk.onServer('shellbuilder:client:place', ...)` handler, and Task 7's `Obelisk.emit('shellbuilder:place', ...)` payload keys. `InstanceService.enter/leave` signatures match between Task 1 and their Task 5 call sites. `ShellService.get/list/create/addOwner/isOwner/listOwners` names and return shapes match between Task 3's implementation and Task 5's `permissionsFor`/event-handler usage.
