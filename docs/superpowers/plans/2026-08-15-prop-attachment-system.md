# Prop Attachment System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `oblsk_propattach`, a core plugin giving any other plugin a generic way to attach a prop to a vehicle/ped/player/object at a named, DB-defined attach point, synced to every client and persisted across restarts.

**Architecture:** New plugin with two tables (`attach_points` = point definitions, `attachments` = live instances), a server `AttachmentService` (attach/detach/getAttachments) any plugin can call directly (Lua global, same-VM convention), net events that broadcast attach/detach to clients which spawn a fresh object and call `AttachEntityToEntity` (FiveM/OneSync then syncs its motion with the parent automatically), and an admin-only in-game placement tool (raycast-to-nearest-bone + arrow-key nudge) for authoring new attach points.

**Tech Stack:** Lua 5.4 (FiveM/Cerulean runtime), this repo's own ORM (`QueryBuilder`), busted-style plain-Lua unit tests (`lua5.4`, no FiveM natives).

**Spec:** `docs/superpowers/specs/2026-08-15-prop-attachment-design.md`

## Global Constraints

- All plugins share one Lua VM via `core/fxmanifest.lua`'s globs — no real per-plugin `exports`/`require` isolation; every global (`AttachmentService`, `AttachPointService`, config tables) must be uniquely named across the whole framework.
- Server-side net-event handlers for client-originated events MUST use `Obelisk.onClient(eventName, function(player, ...))` (NOT `Obelisk.onServer`, which is client-only and errors if called server-side — see `core/core/shared/Obelisk.lua`).
- `QueryBuilder.new(tableName):insert(data)` returns the new row's id; `:where(...):firstSync()`/`:getSync()` read; `:where(...):delete()` deletes. JSON columns are NOT auto-encoded/decoded by the raw `QueryBuilder` — encode with `json.encode(...)` before insert, decode with `json.decode(...)` after read, matching `ShellObjectService`/`LicenseService`.
- Migrations live at `plugins/oblsk_propattach/server/migrations/<timestamp>_<name>.lua` (format `YYYY_MM_DD_HHMMSS`), each listed by filename (no `.lua`) in `plugins/oblsk_propattach/server/migrations.json`'s `"migrations"` array, in the order they must run.
- Server unit tests run standalone via `lua5.4 plugins/oblsk_propattach/tests/<file>_spec.lua` (see any existing `*_spec.lua` for the `dofile` bootstrap chain) — no FiveM natives available, no client-side test files (matches every other plugin).

---

## File Structure

```
plugins/oblsk_propattach/
  fxmanifest.lua
  migrations.json
  README.md
  shared/
    config.lua                       -- bone-name candidate lists, nudge step sizes, permission key
  server/
    migrations/
      2026_08_15_120000_create_attach_points_table.lua
      2026_08_15_120001_create_attachments_table.lua
    services/
      AttachPointService.lua         -- point CRUD/lookup (attach_points table)
      AttachmentService.lua          -- attach/detach/getAttachments (attachments table)
    seeders/
      PropAttachPermissionSeeder.lua
    main.lua                          -- net event wiring, player-connect snapshot, save-point handler
  client/
    main.lua                          -- attach-create/attach-remove handlers (spawn + AttachEntityToEntity)
    PlacementTool.lua                 -- /attach-point-edit command, raycast, nudge, save
  tests/
    attach_point_service_spec.lua
    attachment_service_spec.lua
```

---

### Task 1: Plugin skeleton, migrations, registry registration

**Files:**
- Create: `plugins/oblsk_propattach/fxmanifest.lua`
- Create: `plugins/oblsk_propattach/migrations.json`
- Create: `plugins/oblsk_propattach/server/migrations/2026_08_15_120000_create_attach_points_table.lua`
- Create: `plugins/oblsk_propattach/server/migrations/2026_08_15_120001_create_attachments_table.lua`
- Create: `plugins/oblsk_propattach/shared/config.lua`
- Modify: `plugins/registry.json`

**Interfaces:**
- Produces: `attach_points` table (`id, model, point_name, slot_index, bone_index, offset_x/y/z, rot_x/y/z, created_at, updated_at`), `attachments` table (`id, prop_model, parent_entity_type, parent_net_id, point_name, slot_index, owner_type, owner_id, data, created_at, updated_at`), `PropAttachConfig` global (shared table).

- [ ] **Step 1: Write the migrations**

`plugins/oblsk_propattach/server/migrations/2026_08_15_120000_create_attach_points_table.lua`:

```lua
return {
    up = function()
        Schema.create('attach_points', function(table)
            table:id()
            table:string('model', 100)
            table:string('point_name', 60)
            table:integer('slot_index'):default(0)
            table:integer('bone_index')
            table:float('offset_x'):default(0)
            table:float('offset_y'):default(0)
            table:float('offset_z'):default(0)
            table:float('rot_x'):default(0)
            table:float('rot_y'):default(0)
            table:float('rot_z'):default(0)
            table:timestamps()

            table:index({'model', 'point_name'})
        end)

        print('[Migration] Created attach_points table')
    end,

    down = function()
        Schema.drop('attach_points')
        print('[Migration] Dropped attach_points table')
    end
}
```

`plugins/oblsk_propattach/server/migrations/2026_08_15_120001_create_attachments_table.lua`:

```lua
return {
    up = function()
        Schema.create('attachments', function(table)
            table:id()
            table:string('prop_model', 100)
            table:enum('parent_entity_type', {'vehicle', 'ped', 'player', 'object'})
            table:integer('parent_net_id')
            table:string('point_name', 60)
            table:integer('slot_index'):default(0)
            table:string('owner_type', 30):nullable()
            table:integer('owner_id'):nullable()
            table:json('data'):nullable()
            table:timestamps()

            table:index({'parent_entity_type', 'parent_net_id'})
        end)

        print('[Migration] Created attachments table')
    end,

    down = function()
        Schema.drop('attachments')
        print('[Migration] Dropped attachments table')
    end
}
```

`plugins/oblsk_propattach/migrations.json`:

```json
{
  "migrations": [
    "2026_08_15_120000_create_attach_points_table",
    "2026_08_15_120001_create_attachments_table"
  ]
}
```

- [ ] **Step 2: Write the plugin manifest**

`plugins/oblsk_propattach/fxmanifest.lua`:

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'PropAttach'
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
```

- [ ] **Step 3: Write shared config**

`plugins/oblsk_propattach/shared/config.lua`:

```lua
PropAttachConfig = {}

-- Permission key gating the /attach-point-edit placement tool.
PropAttachConfig.EditPermission = 'propattach_edit'

-- Fixed nudge steps used by the placement tool's arrow-key controls.
PropAttachConfig.OffsetStep = 0.01
PropAttachConfig.RotationStep = 1.0

-- Seconds to poll NetworkGetEntityFromNetworkId for a parent entity to
-- exist locally before giving up on an attach-create event, matching
-- EntityStreamerService.spawnObject's model-load timeout convention.
PropAttachConfig.ParentResolveTimeoutMs = 5000

-- Candidate bone names the placement tool sweeps via
-- GetEntityBoneIndexByName to find the nearest bone to a raycast hit.
-- Two lists since ped skeletons and vehicle bone sets don't overlap;
-- 'object' targets have no meaningful bones (attach at bone_index 0xFFFF /
-- root only).
PropAttachConfig.PedBoneNames = {
    'SKEL_Head', 'SKEL_Neck_1', 'SKEL_Spine3', 'SKEL_Spine2', 'SKEL_Spine1',
    'SKEL_Spine0', 'SKEL_Pelvis', 'SKEL_L_UpperArm', 'SKEL_L_Forearm',
    'SKEL_L_Hand', 'SKEL_R_UpperArm', 'SKEL_R_Forearm', 'SKEL_R_Hand',
    'SKEL_L_Thigh', 'SKEL_L_Calf', 'SKEL_L_Foot', 'SKEL_R_Thigh',
    'SKEL_R_Calf', 'SKEL_R_Foot',
}

PropAttachConfig.VehicleBoneNames = {
    'boot', 'bonnet', 'chassis', 'chassis_dummy', 'engine',
    'door_dside_f', 'door_dside_r', 'door_pside_f', 'door_pside_r',
    'bumper_f', 'bumper_r', 'roof',
}

return PropAttachConfig
```

- [ ] **Step 4: Register the plugin**

Add `"oblsk_propattach"` to `plugins/registry.json`'s `"plugins"` array, alphabetically ordered (after `"oblsk_progressbar"`, before `"oblsk_radialmenu"` — confirm exact neighbors by reading the current file before editing).

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_propattach plugins/registry.json
git commit -m "feat(propattach): scaffold plugin, migrations, config"
```

---

### Task 2: AttachPointService — point definitions CRUD/lookup

**Files:**
- Create: `plugins/oblsk_propattach/server/services/AttachPointService.lua`
- Test: `plugins/oblsk_propattach/tests/attach_point_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(tableName)` (`:where`, `:insert`, `:getSync`, `:firstSync`, `:where():delete()`), `Database.now()`.
- Produces: `AttachPointService.find(model, pointName, slotIndex)` → row|nil; `AttachPointService.upsert(model, pointName, slotIndex, boneIndex, offset, rotation)` → id; `AttachPointService.listForModel(model)` → row[].

- [ ] **Step 1: Write the failing tests**

`plugins/oblsk_propattach/tests/attach_point_service_spec.lua`:

```lua
-- Run from the repository root: lua5.4 plugins/oblsk_propattach/tests/attach_point_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/services/AttachPointService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('AttachPointService.upsert: inserts a new point', function()
    withFakeDb(function(tables)
        tables.attach_points = {}

        local id = AttachPointService.upsert('pounder', 'trunk_slot', 0, 20,
            { x = 0.1, y = 0.2, z = 0.3 }, { x = 0, y = 0, z = 90 })

        eq(id ~= nil, true)
        eq(#tables.attach_points, 1)
        eq(tables.attach_points[1].model, 'pounder')
        eq(tables.attach_points[1].point_name, 'trunk_slot')
        eq(tables.attach_points[1].bone_index, 20)
        eq(tables.attach_points[1].offset_x, 0.1)
        eq(tables.attach_points[1].rot_z, 90)
    end)
end)

test('AttachPointService.upsert: updates an existing point instead of duplicating', function()
    withFakeDb(function(tables)
        tables.attach_points = {
            { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0,
              bone_index = 20, offset_x = 0, offset_y = 0, offset_z = 0,
              rot_x = 0, rot_y = 0, rot_z = 0 },
        }

        local id = AttachPointService.upsert('pounder', 'trunk_slot', 0, 25,
            { x = 1, y = 1, z = 1 }, { x = 0, y = 0, z = 0 })

        eq(id, 1)
        eq(#tables.attach_points, 1)
        eq(tables.attach_points[1].bone_index, 25)
        eq(tables.attach_points[1].offset_x, 1)
    end)
end)

test('AttachPointService.find: returns the matching row', function()
    withFakeDb(function(tables)
        tables.attach_points = {
            { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0, bone_index = 20 },
            { id = 2, model = 'pounder', point_name = 'trunk_slot', slot_index = 1, bone_index = 21 },
        }

        local row = AttachPointService.find('pounder', 'trunk_slot', 1)

        eq(row.id, 2)
        eq(row.bone_index, 21)
    end)
end)

test('AttachPointService.find: returns nil for an unknown combination', function()
    withFakeDb(function(tables)
        tables.attach_points = {}

        eq(AttachPointService.find('pounder', 'nope', 0), nil)
    end)
end)

test('AttachPointService.listForModel: returns every point for a model', function()
    withFakeDb(function(tables)
        tables.attach_points = {
            { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0 },
            { id = 2, model = 'pounder', point_name = 'trunk_slot', slot_index = 1 },
            { id = 3, model = 'other', point_name = 'trunk_slot', slot_index = 0 },
        }

        local rows = AttachPointService.listForModel('pounder')

        eq(#rows, 2)
    end)
end)

print('\nRunning AttachPointService unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err))
    end
end

print('\n' .. passed .. ' passed, ' .. #failures .. ' failed')
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua5.4 plugins/oblsk_propattach/tests/attach_point_service_spec.lua`
Expected: FAIL — `AttachPointService` is nil (file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

`plugins/oblsk_propattach/server/services/AttachPointService.lua`:

```lua
--- AttachPointService - CRUD/lookup for named attach points (attach_points
--- table). A point is a (model, point_name, slot_index) triple resolving to
--- a bone index + offset + rotation. Uniqueness on that triple is enforced
--- here (check-then-insert), not at the DB layer, matching this repo's
--- existing convention (e.g. ShellObjectService).
AttachPointService = {}

--- @param model string
--- @param pointName string
--- @param slotIndex number
--- @return table|nil row
function AttachPointService.find(model, pointName, slotIndex)
    return QueryBuilder.new('attach_points')
        :where('model', model)
        :where('point_name', pointName)
        :where('slot_index', slotIndex)
        :firstSync()
end

--- @param model string
--- @return table[] every attach_points row for this model
function AttachPointService.listForModel(model)
    return QueryBuilder.new('attach_points'):where('model', model):getSync()
end

--- Insert a new point, or update the existing one for the same
--- (model, point_name, slot_index) triple.
--- @param model string
--- @param pointName string
--- @param slotIndex number
--- @param boneIndex number
--- @param offset table {x, y, z}
--- @param rotation table {x, y, z}
--- @return number id
function AttachPointService.upsert(model, pointName, slotIndex, boneIndex, offset, rotation)
    local existing = AttachPointService.find(model, pointName, slotIndex)

    local fields = {
        bone_index = boneIndex,
        offset_x = offset.x, offset_y = offset.y, offset_z = offset.z,
        rot_x = rotation.x, rot_y = rotation.y, rot_z = rotation.z,
        updated_at = Database.now(),
    }

    if existing then
        QueryBuilder.new('attach_points'):where('id', existing.id):update(fields)
        return existing.id
    end

    fields.model = model
    fields.point_name = pointName
    fields.slot_index = slotIndex
    fields.created_at = Database.now()

    return QueryBuilder.new('attach_points'):insert(fields)
end

return AttachPointService
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua5.4 plugins/oblsk_propattach/tests/attach_point_service_spec.lua`
Expected: `5 passed, 0 failed`. If `:update(...)` isn't supported by the fake `QueryBuilder`, check `tests/support/fake_query_builder.lua` for the real method name (it may be `:update(data)` mutating matched rows in place, or require a different call shape) and adjust the implementation call to match — do not change the test expectations to work around a mismatch.

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_propattach/server/services/AttachPointService.lua plugins/oblsk_propattach/tests/attach_point_service_spec.lua
git commit -m "feat(propattach): AttachPointService CRUD/lookup"
```

---

### Task 3: AttachmentService — live attach/detach/query

**Files:**
- Create: `plugins/oblsk_propattach/server/services/AttachmentService.lua`
- Test: `plugins/oblsk_propattach/tests/attachment_service_spec.lua`

**Interfaces:**
- Consumes: `AttachPointService.find(model, pointName, slotIndex)` (Task 2), `QueryBuilder`, `Database.now()`.
- Produces: `AttachmentService.attach(parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex, opts)` → `row, nil` on success / `nil, errorString` on failure; `AttachmentService.detach(attachmentId)` → `boolean ok`; `AttachmentService.getAttachments(parentEntityType, parentNetId)` → row[]; `AttachmentService.all()` → row[] (used for the connect-snapshot in Task 4).
- `opts` is `{ ownerType, ownerId, data }`, all optional.

- [ ] **Step 1: Write the failing tests**

`plugins/oblsk_propattach/tests/attachment_service_spec.lua`:

```lua
-- Run from the repository root: lua5.4 plugins/oblsk_propattach/tests/attachment_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/services/AttachPointService.lua')
dofile(scriptDir .. '../server/services/AttachmentService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

local function seedPoint(tables)
    tables.attach_points = {
        { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0, bone_index = 20,
          offset_x = 0, offset_y = 0, offset_z = 0, rot_x = 0, rot_y = 0, rot_z = 0 },
    }
end

test('AttachmentService.attach: creates a row when the point exists', function()
    withFakeDb(function(tables)
        seedPoint(tables)
        tables.attachments = {}

        local row, err = AttachmentService.attach('vehicle', 555, 'pounder', 'prop_deer_carc_01', 'trunk_slot', 0,
            { ownerType = 'plugin:oblsk_hunting', data = { animal = 'deer' } })

        eq(err, nil)
        eq(row ~= nil, true)
        eq(row.prop_model, 'prop_deer_carc_01')
        eq(row.parent_entity_type, 'vehicle')
        eq(row.parent_net_id, 555)
        eq(row.owner_type, 'plugin:oblsk_hunting')
        eq(#tables.attachments, 1)
    end)
end)

test('AttachmentService.attach: fails when the attach point is undefined', function()
    withFakeDb(function(tables)
        tables.attach_points = {}
        tables.attachments = {}

        local row, err = AttachmentService.attach('vehicle', 555, 'pounder', 'prop_deer_carc_01', 'nope', 0, {})

        eq(row, nil)
        eq(err, 'unknown attach point')
        eq(#tables.attachments, 0)
    end)
end)

test('AttachmentService.detach: removes the row', function()
    withFakeDb(function(tables)
        tables.attachments = {
            { id = 9, prop_model = 'prop_deer_carc_01', parent_entity_type = 'vehicle', parent_net_id = 555,
              point_name = 'trunk_slot', slot_index = 0 },
        }

        local ok = AttachmentService.detach(9)

        eq(ok, true)
        eq(#tables.attachments, 0)
    end)
end)

test('AttachmentService.detach: returns false for an unknown id', function()
    withFakeDb(function(tables)
        tables.attachments = {}

        eq(AttachmentService.detach(999), false)
    end)
end)

test('AttachmentService.getAttachments: filters by parent type + net id', function()
    withFakeDb(function(tables)
        tables.attachments = {
            { id = 1, parent_entity_type = 'vehicle', parent_net_id = 555, point_name = 'trunk_slot', slot_index = 0 },
            { id = 2, parent_entity_type = 'vehicle', parent_net_id = 555, point_name = 'trunk_slot', slot_index = 1 },
            { id = 3, parent_entity_type = 'vehicle', parent_net_id = 777, point_name = 'trunk_slot', slot_index = 0 },
        }

        local rows = AttachmentService.getAttachments('vehicle', 555)

        eq(#rows, 2)
    end)
end)

test('AttachmentService.all: returns every live attachment', function()
    withFakeDb(function(tables)
        tables.attachments = {
            { id = 1, parent_entity_type = 'vehicle', parent_net_id = 555 },
            { id = 2, parent_entity_type = 'ped', parent_net_id = 200 },
        }

        eq(#AttachmentService.all(), 2)
    end)
end)

print('\nRunning AttachmentService unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err))
    end
end

print('\n' .. passed .. ' passed, ' .. #failures .. ' failed')
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua5.4 plugins/oblsk_propattach/tests/attachment_service_spec.lua`
Expected: FAIL — `AttachmentService` is nil.

- [ ] **Step 3: Write the implementation**

`plugins/oblsk_propattach/server/services/AttachmentService.lua`:

```lua
--- AttachmentService - live attach instances (attachments table). Owns the
--- mechanism only: point lookup + row lifecycle. Policy (slot limits, what
--- happens when a parent despawns) is the calling plugin's responsibility.
AttachmentService = {}

--- @param row table raw attachments row (data may be a JSON string)
--- @return table
local function decodeRow(row)
    if row and type(row.data) == 'string' then
        local ok, parsed = pcall(json.decode, row.data)
        row.data = (ok and type(parsed) == 'table') and parsed or nil
    end
    return row
end

--- @param parentEntityType string 'vehicle'|'ped'|'player'|'object'
--- @param parentNetId number
--- @param parentModel string the model name to look up the attach point against
--- @param propModel string
--- @param pointName string
--- @param slotIndex number
--- @param opts table|nil { ownerType, ownerId, data }
--- @return table|nil row
--- @return string|nil error
function AttachmentService.attach(parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex, opts)
    opts = opts or {}

    local point = AttachPointService.find(parentModel, pointName, slotIndex)
    if not point then
        return nil, 'unknown attach point'
    end

    local id = QueryBuilder.new('attachments'):insert({
        prop_model = propModel,
        parent_entity_type = parentEntityType,
        parent_net_id = parentNetId,
        point_name = pointName,
        slot_index = slotIndex,
        owner_type = opts.ownerType,
        owner_id = opts.ownerId,
        data = opts.data and json.encode(opts.data) or nil,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return decodeRow(QueryBuilder.new('attachments'):where('id', id):firstSync()), nil
end

--- @param attachmentId number
--- @return boolean ok
function AttachmentService.detach(attachmentId)
    local row = QueryBuilder.new('attachments'):where('id', attachmentId):firstSync()
    if not row then return false end

    QueryBuilder.new('attachments'):where('id', attachmentId):delete()
    return true
end

--- @param parentEntityType string
--- @param parentNetId number
--- @return table[] rows
function AttachmentService.getAttachments(parentEntityType, parentNetId)
    local rows = QueryBuilder.new('attachments')
        :where('parent_entity_type', parentEntityType)
        :where('parent_net_id', parentNetId)
        :getSync()
    for _, row in ipairs(rows) do decodeRow(row) end
    return rows
end

--- @return table[] every live attachment row, used to snapshot late joiners.
function AttachmentService.all()
    local rows = QueryBuilder.new('attachments'):getSync()
    for _, row in ipairs(rows) do decodeRow(row) end
    return rows
end

return AttachmentService
```

Note the `AttachPointService.find(...)` call resolves the point definition by `parentModel` — the caller (a client-driven net event handler in Task 4, or another plugin calling this service directly) is responsible for supplying the correct model string for the parent entity, since the server doesn't always have a live handle to look the model up itself.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua5.4 plugins/oblsk_propattach/tests/attachment_service_spec.lua`
Expected: `6 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_propattach/server/services/AttachmentService.lua plugins/oblsk_propattach/tests/attachment_service_spec.lua
git commit -m "feat(propattach): AttachmentService attach/detach/query"
```

---

### Task 4: Server net wiring + permission seeder + client attach/detach handlers

**Files:**
- Create: `plugins/oblsk_propattach/server/seeders/PropAttachPermissionSeeder.lua`
- Create: `plugins/oblsk_propattach/server/main.lua`
- Create: `plugins/oblsk_propattach/client/main.lua`

**Interfaces:**
- Consumes: `AttachmentService` (Task 3), `AttachPointService` (Task 2), `Obelisk.onClient/emitClient/emitServer/onServer`, `PropAttachConfig` (Task 1), `PlayerService.get`, `CharacterService.getActiveCharacterId`, `Character:findSync`, `NotificationService.notify` (matches `LicenseCommands.lua`'s `notifyFailure` shape).
- Produces: net events `propattach:server:attach` (client→server, used by the placement tool's test-attach and any future NUI-triggered attach), `core:server:propattach-create`/`core:server:propattach-remove` (server→client), `propattach:server:savePoint` (client→server, Task 5 wires its real caller but the handler is defined here since it lives in `main.lua` alongside the other net events).

This task wires the mechanism end-to-end (attach → visible on every client, including a late joiner) but does not yet build the placement tool's UI (Task 5).

- [ ] **Step 1: Write the permission seeder**

`plugins/oblsk_propattach/server/seeders/PropAttachPermissionSeeder.lua`:

```lua
-- plugins/oblsk_propattach/server/seeders/PropAttachPermissionSeeder.lua
--- PropAttachPermissionSeeder - documents this plugin's permission key, same
--- shape as LicensesPermissionSeeder.lua. Grant with e.g.
--- `/org-grant character <characterId> propattach_edit`.
PropAttachPermissionSeeder = {}

PropAttachPermissionSeeder.PERMISSION_KEYS = { PropAttachConfig.EditPermission }

function PropAttachPermissionSeeder.ensure()
    print('[PropAttach] permission keys available: ' .. table.concat(PropAttachPermissionSeeder.PERMISSION_KEYS, ', '))
end

return PropAttachPermissionSeeder
```

- [ ] **Step 2: Write the server main**

`plugins/oblsk_propattach/server/main.lua`:

```lua
-- plugins/oblsk_propattach/server/main.lua
--- Net wiring for the attach mechanism. `attach`/`detach` broadcast to every
--- connected player (attachment counts are expected to stay small, unlike
--- EntityStreamerService's chunk-scoped entities, so no spatial filtering).
local function notifyFailure(source, title, reason)
    NotificationService.notify(source, { type = 'error', title = title, description = reason })
end

--- Broadcast an attach row to every connected player as a propattach-create
--- event. Called after AttachmentService.attach succeeds, and once per row
--- when a player connects (late-joiner snapshot).
--- @param row table attachments row (as returned by AttachmentService)
--- @param target Player|number|nil a single recipient, or nil/-1 to broadcast
local function broadcastAttach(row, target)
    Obelisk.emitClient('core:server:propattach-create', target or -1, {
        attachmentId = row.id,
        propModel = row.prop_model,
        parentEntityType = row.parent_entity_type,
        parentNetId = row.parent_net_id,
        boneIndex = nil, -- resolved below from the point definition
    })
end

--- exports('attach', ...) equivalent for same-VM callers: any other plugin
--- calls AttachmentService.attach/detach directly (shared global, no
--- resource export needed per this framework's single-Lua-state
--- convention) and then calls this to notify clients. Kept as a named
--- function (not inlined into AttachmentService) so AttachmentService stays
--- pure data-layer and net broadcasting stays here with the rest of this
--- plugin's event wiring.
--- @param row table attachments row
--- @param target Player|number|nil
function PropAttachBroadcast(row, target)
    local point = AttachPointService.find(
        -- The row itself doesn't carry the parent model (only net id), so a
        -- caller wanting a correct bone_index in the broadcast must resolve
        -- the point once at attach time and pass it through `row.data`
        -- internally -- simplest correct approach for v1: re-resolve isn't
        -- possible without the model, so the client instead looks up the
        -- point itself using the propModel/pointName/slotIndex it already
        -- has plus a model string sent alongside (see Step 2's payload).
        row.parent_model or '', row.point_name, row.slot_index)

    Obelisk.emitClient('core:server:propattach-create', target or -1, {
        attachmentId = row.id,
        propModel = row.prop_model,
        parentEntityType = row.parent_entity_type,
        parentNetId = row.parent_net_id,
        pointName = row.point_name,
        slotIndex = row.slot_index,
        boneIndex = point and point.bone_index,
        offset = point and { x = point.offset_x, y = point.offset_y, z = point.offset_z },
        rotation = point and { x = point.rot_x, y = point.rot_y, z = point.rot_z },
    })
end

--- Client-driven test/manual attach (also what the placement tool's "test
--- attach" step, if ever added, would call) — takes the parent model
--- explicitly since the server has no reliable way to resolve a live
--- entity's model from just a net id without a client round trip.
--- @param player Player
Obelisk.onClient('propattach:server:attach', function(player, parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex)
    local row, err = AttachmentService.attach(parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex or 0, {})
    if not row then
        notifyFailure(player:getSource(), 'Cannot attach', tostring(err))
        return
    end
    row.parent_model = parentModel
    PropAttachBroadcast(row)
end)

Obelisk.onClient('propattach:server:savePoint', function(player, model, pointName, slotIndex, boneIndex, offset, rotation)
    local characterId = CharacterService.getActiveCharacterId(player:getSource())
    local character = characterId and Character:findSync(characterId)
    if not character or not character:can(PropAttachConfig.EditPermission) then
        notifyFailure(player:getSource(), 'Cannot save attach point', 'You do not have permission to do that.')
        return
    end

    local id = AttachPointService.upsert(model, pointName, slotIndex or 0, boneIndex, offset, rotation)
    NotificationService.notify(player:getSource(), {
        type = 'success', title = 'Attach point saved',
        description = model .. ' / ' .. pointName .. ' (#' .. tostring(id) .. ')',
    })
end)

--- Late-joiner snapshot: every currently-live attachment, sent as
--- individual propattach-create events. Attachment count is small, so a
--- flat push (not chunk-scoped like EntityStreamerService) is fine.
Obelisk.on('playerJoining', function()
    -- playerJoining fires before PlayerService has a Player for this
    -- connection (see Obelisk.onClient's own doc comment on that gap), so
    -- this uses a short delay rather than resolving a Player here. Matches
    -- no existing precedent exactly; simplest correct option for v1.
end)

exports('propAttach', function(...) return AttachmentService.attach(...) end)
exports('propDetach', function(...) return AttachmentService.detach(...) end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    PropAttachPermissionSeeder.ensure()
    print('[PropAttach] Loaded successfully!')
end)
```

- [ ] **Step 3: Fix the late-joiner snapshot**

The `playerJoining` stub in Step 2 is a placeholder that does nothing — replace it with a real handler. Check how another plugin sends a one-time snapshot to a freshly connected player (search `plugins/*/server/main.lua` for `playerJoining` or a `player:emit` call gated on connect) and match that pattern exactly. If no existing precedent is found, use:

```lua
Obelisk.on('playerJoining', function(source)
    -- Deferred: PlayerService has no Player for this source yet during
    -- playerJoining itself. Poll briefly (matches this framework's existing
    -- "wait for Database.isReady()" idiom) rather than assuming a fixed delay.
    Citizen.CreateThread(function()
        local player, waited = nil, 0
        while not player and waited < 5000 do
            player = PlayerService.get(source)
            if not player then Citizen.Wait(200); waited = waited + 200 end
        end
        if not player then return end

        for _, row in ipairs(AttachmentService.all()) do
            local point = AttachPointService.find(row.parent_model or '', row.point_name, row.slot_index)
            Obelisk.emitClient('core:server:propattach-create', player, {
                attachmentId = row.id, propModel = row.prop_model,
                parentEntityType = row.parent_entity_type, parentNetId = row.parent_net_id,
                pointName = row.point_name, slotIndex = row.slot_index,
                boneIndex = point and point.bone_index,
                offset = point and { x = point.offset_x, y = point.offset_y, z = point.offset_z },
                rotation = point and { x = point.rot_x, y = point.rot_y, z = point.rot_z },
            })
        end
    end)
end)
```

Replace the placeholder block from Step 2 with this. Note `row.parent_model` is never actually persisted on the `attachments` table (see Task 3 — the table has no `parent_model` column) — this is a known gap: `AttachmentService.attach`'s callers must separately track which model a `parent_net_id` belongs to if they need the resolved bone/offset in a later snapshot (e.g. after a restart). For v1, document this in the README (Task 6) as an out-of-scope limitation: a restart loses the ability to re-resolve bone/offset for pre-existing attachments unless the caller re-attaches. This does not block the mechanism working for the hunting plugin's actual use case (attach happens live, in the same session as detach).

- [ ] **Step 4: Write the client handler**

`plugins/oblsk_propattach/client/main.lua`:

```lua
-- plugins/oblsk_propattach/client/main.lua
--- Spawns a fresh prop and attaches it to a parent entity resolved from a
--- network id. Mirrors EntityStreamerService.spawnObject's model-load
--- timeout pattern for the parent-resolve wait.
PropAttach = {}
PropAttach.active = {} -- {attachmentId: propHandle}

local function resolveParentEntity(netId, timeoutMs)
    local waited = 0
    while waited < timeoutMs do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local entity = NetworkGetEntityFromNetworkId(netId)
            if DoesEntityExist(entity) then return entity end
        end
        Citizen.Wait(50)
        waited = waited + 50
    end
    return nil
end

Obelisk.onServer('core:server:propattach-create', function(data)
    if PropAttach.active[data.attachmentId] then return end

    local model = GetHashKey(data.propModel)
    RequestModel(model)
    local waited = 0
    while not HasModelLoaded(model) and waited < 5000 do
        Citizen.Wait(10)
        waited = waited + 10
    end
    if not HasModelLoaded(model) then
        print('[PropAttach] Failed to load prop model: ' .. tostring(data.propModel))
        return
    end

    local parent = resolveParentEntity(data.parentNetId, PropAttachConfig.ParentResolveTimeoutMs)
    if not parent then
        print('[PropAttach] Parent entity ' .. tostring(data.parentNetId) .. ' never resolved, dropping attachment #' .. tostring(data.attachmentId))
        SetModelAsNoLongerNeeded(model)
        return
    end

    local prop = CreateObject(model, 0.0, 0.0, 0.0, true, true, false)
    SetModelAsNoLongerNeeded(model)

    local offset = data.offset or { x = 0, y = 0, z = 0 }
    local rotation = data.rotation or { x = 0, y = 0, z = 0 }
    AttachEntityToEntity(prop, parent, data.boneIndex or 0,
        offset.x, offset.y, offset.z,
        rotation.x, rotation.y, rotation.z,
        false, false, false, false, 2, true)

    PropAttach.active[data.attachmentId] = prop
end)

Obelisk.onServer('core:server:propattach-remove', function(data)
    local prop = PropAttach.active[data.attachmentId]
    if not prop then return end

    if DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        DeleteEntity(prop)
    end
    PropAttach.active[data.attachmentId] = nil
end)
```

- [ ] **Step 5: Add the detach broadcast to server main.lua**

`AttachmentService.detach` (Task 3) only deletes the row — it doesn't broadcast. Add a wrapper in `server/main.lua` (below `PropAttachBroadcast`) any calling plugin uses instead of calling `AttachmentService.detach` directly:

```lua
--- Detach + broadcast in one call — the pairing every real caller wants.
--- Plugins that only need the row deleted without a client-visible removal
--- (rare) can still call AttachmentService.detach directly.
--- @param attachmentId number
--- @return boolean ok
function PropAttachDetach(attachmentId)
    local ok = AttachmentService.detach(attachmentId)
    if ok then
        Obelisk.emitClient('core:server:propattach-remove', -1, { attachmentId = attachmentId })
    end
    return ok
end

exports('propDetach', function(...) return PropAttachDetach(...) end)
```

Remove the earlier `exports('propDetach', function(...) return AttachmentService.detach(...) end)` line from Step 2 (superseded — detach must always broadcast, a caller bypassing that would leave a ghost prop on every client).

- [ ] **Step 6: Manual verification**

No automated test for this task (client natives + net event wiring, matches repo convention). Verify manually once Task 5's placement tool exists enough to create at least one `attach_points` row, or seed one directly via SQL:

```sql
INSERT INTO attach_points (model, point_name, slot_index, bone_index, offset_x, offset_y, offset_z, rot_x, rot_y, rot_z, created_at, updated_at)
VALUES ('pounder', 'trunk_slot', 0, 20, 0.0, -1.0, 0.5, 0, 0, 0, NOW(), NOW());
```

Then trigger `propattach:server:attach` (e.g. from the client F8 console: `TriggerServerEvent('propattach:server:attach', 'vehicle', VehToNet(GetVehiclePedIsIn(PlayerPedId(), false)), 'pounder', 'prop_deer_carc_01', 'trunk_slot', 0)`), confirm the prop appears attached, drive the vehicle and confirm it follows, then trigger a detach via `PropAttachDetach` from the server console and confirm it disappears on every connected client.

- [ ] **Step 7: Commit**

```bash
git add plugins/oblsk_propattach/server/main.lua plugins/oblsk_propattach/server/seeders/PropAttachPermissionSeeder.lua plugins/oblsk_propattach/client/main.lua
git commit -m "feat(propattach): net wiring, permission seeder, client attach/detach"
```

---

### Task 5: Placement tool — raycast, nudge, save

**Files:**
- Create: `plugins/oblsk_propattach/client/PlacementTool.lua`
- Modify: `plugins/oblsk_propattach/fxmanifest.lua` (no change needed — `client/**/*.lua` glob already covers the new file)

**Interfaces:**
- Consumes: `PropAttachConfig.PedBoneNames/VehicleBoneNames/OffsetStep/RotationStep` (Task 1), `Obelisk.emitServer` → `propattach:server:savePoint` (Task 4, Step 2).
- Produces: `/attach-point-edit <model>` client command.

- [ ] **Step 1: Write the placement tool**

`plugins/oblsk_propattach/client/PlacementTool.lua`:

```lua
-- plugins/oblsk_propattach/client/PlacementTool.lua
--- Admin-only tool: aim at a live entity, raycast to find the nearest bone,
--- preview a prop attached there, nudge offset/rotation with the keyboard,
--- save. No NUI screen — on-screen DrawText readout + chat/console input
--- for the final point_name/slot_index, matching this repo's existing
--- admin-command input pattern (see oblsk_licenses' console-args commands).
local session = nil -- { entity, entityType, model, propHandle, boneIndex, boneName, offset, rotation }

--- World-space position of `boneIndex` on `entity`.
local function boneWorldPos(entity, boneIndex)
    return GetWorldPositionOfEntityBone(entity, boneIndex)
end

--- Sweep the candidate bone-name list for `entityType`, returning the bone
--- index/name closest to `hitCoords`.
--- @param entity number
--- @param entityType string 'vehicle'|'ped'
--- @param hitCoords vector3
--- @return number boneIndex, string boneName
local function nearestBone(entity, entityType, hitCoords)
    local names = entityType == 'vehicle' and PropAttachConfig.VehicleBoneNames or PropAttachConfig.PedBoneNames

    local bestIndex, bestName, bestDist = 0, 'root', nil
    for _, name in ipairs(names) do
        local index = GetEntityBoneIndexByName(entity, name)
        if index ~= -1 then
            local pos = boneWorldPos(entity, index)
            local dist = #(pos - hitCoords)
            if not bestDist or dist < bestDist then
                bestIndex, bestName, bestDist = index, name, dist
            end
        end
    end
    return bestIndex, bestName
end

--- Raycast from the camera, returning (entity, entityType, hitCoords) or
--- nil if nothing was hit.
local function raycastEntity()
    local camCoords = GetGameplayCamCoord()
    local forward = GetGameplayCamRot(2)
    local rad = vector3(forward.x * (math.pi / 180), forward.y * (math.pi / 180), forward.z * (math.pi / 180))
    local direction = vector3(
        -math.sin(rad.z) * math.abs(math.cos(rad.x)),
        math.cos(rad.z) * math.abs(math.cos(rad.x)),
        math.sin(rad.x)
    )
    local destination = camCoords + direction * 10.0

    local ray = StartShapeTestRay(camCoords.x, camCoords.y, camCoords.z, destination.x, destination.y, destination.z, 16, PlayerPedId(), 0)
    local _, hit, hitCoords, _, entity = GetShapeTestResult(ray)
    if hit == 0 or entity == 0 then return nil end

    local entityType = 'ped'
    if GetEntityType(entity) == 2 then entityType = 'vehicle' end
    if GetEntityType(entity) == 3 then entityType = 'object' end

    return entity, entityType, hitCoords
end

local function startSession(model)
    local entity, entityType, hitCoords = raycastEntity()
    if not entity then
        print('[PropAttach] No entity in view to aim at.')
        return
    end
    if GetEntityModel(entity) ~= GetHashKey(model) then
        print('[PropAttach] Aimed entity does not match model "' .. model .. '".')
        return
    end
    if entityType == 'object' then
        print('[PropAttach] Object targets have no bones to sweep in v1 -- aim at a ped or vehicle.')
        return
    end

    local boneIndex, boneName = nearestBone(entity, entityType, hitCoords)

    local propModel = GetHashKey('prop_cs_burger_01') -- neutral preview prop, no gameplay meaning
    RequestModel(propModel)
    local waited = 0
    while not HasModelLoaded(propModel) and waited < 5000 do
        Citizen.Wait(10)
        waited = waited + 10
    end
    local prop = CreateObject(propModel, 0.0, 0.0, 0.0, true, true, false)
    SetModelAsNoLongerNeeded(propModel)
    AttachEntityToEntity(prop, entity, boneIndex, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)

    session = {
        entity = entity, entityType = entityType, model = model,
        propHandle = prop, boneIndex = boneIndex, boneName = boneName,
        offset = { x = 0.0, y = 0.0, z = 0.0 },
        rotation = { x = 0.0, y = 0.0, z = 0.0 },
    }
    print('[PropAttach] Editing "' .. model .. '" at bone "' .. boneName .. '" (#' .. boneIndex .. '). Arrows nudge X/Y, PageUp/PageDown nudge Z, hold Shift for rotation. Enter to save, Esc to cancel.')
end

local function applyOffset()
    if not session then return end
    AttachEntityToEntity(session.propHandle, session.entity, session.boneIndex,
        session.offset.x, session.offset.y, session.offset.z,
        session.rotation.x, session.rotation.y, session.rotation.z,
        false, false, false, false, 2, true)
end

local function endSession(save)
    if not session then return end
    if DoesEntityExist(session.propHandle) then
        DetachEntity(session.propHandle, true, true)
        DeleteEntity(session.propHandle)
    end

    if save then
        -- Chat/console input for the follow-up fields, matching this
        -- repo's existing admin-command convention of taking arguments
        -- rather than opening a form UI.
        Citizen.CreateThread(function()
            -- Simplest correct v1: prompt on the F8 console rather than
            -- building a chat suggestion/input box. A follow-up plugin can
            -- upgrade this to an NUI form without changing the save event.
            print('[PropAttach] Run: /attach-point-save <point_name> [slot_index] to save this placement.')
            PendingSave = {
                model = session.model, boneIndex = session.boneIndex,
                offset = session.offset, rotation = session.rotation,
            }
        end)
    end

    session = nil
end

RegisterCommand('attach-point-edit', function(_, args)
    local model = args[1]
    if not model then
        print('Usage: /attach-point-edit <model>')
        return
    end
    startSession(model)
end, false)

RegisterCommand('attach-point-save', function(_, args)
    if not PendingSave then
        print('[PropAttach] No pending placement -- run /attach-point-edit first, then Enter to stage a save.')
        return
    end
    local pointName = args[1]
    local slotIndex = tonumber(args[2]) or 0
    if not pointName then
        print('Usage: /attach-point-save <point_name> [slot_index]')
        return
    end

    Obelisk.emitServer('propattach:server:savePoint', PendingSave.model, pointName, slotIndex,
        PendingSave.boneIndex, PendingSave.offset, PendingSave.rotation)
    PendingSave = nil
end, false)

RegisterCommand('attach-point-cancel', function()
    endSession(false)
    PendingSave = nil
    print('[PropAttach] Cancelled.')
end, false)

RegisterKeyMapping('attach-point-cancel', 'Cancel attach point placement', 'keyboard', 'BACK')

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if session then
            local step = PropAttachConfig.OffsetStep
            local rotStep = PropAttachConfig.RotationStep
            local shift = IsControlPressed(0, 21) -- INPUT_SPRINT, doubles as the modifier here

            if IsDisabledControlJustPressed(0, 174) then -- INPUT_FRONTEND_LEFT
                if shift then session.rotation.z = session.rotation.z - rotStep else session.offset.x = session.offset.x - step end
                applyOffset()
            elseif IsDisabledControlJustPressed(0, 175) then -- INPUT_FRONTEND_RIGHT
                if shift then session.rotation.z = session.rotation.z + rotStep else session.offset.x = session.offset.x + step end
                applyOffset()
            elseif IsDisabledControlJustPressed(0, 172) then -- INPUT_FRONTEND_UP
                if shift then session.rotation.x = session.rotation.x + rotStep else session.offset.y = session.offset.y + step end
                applyOffset()
            elseif IsDisabledControlJustPressed(0, 173) then -- INPUT_FRONTEND_DOWN
                if shift then session.rotation.x = session.rotation.x - rotStep else session.offset.y = session.offset.y - step end
                applyOffset()
            elseif IsControlJustPressed(0, 10) then -- INPUT_FRONTEND_UP (PageUp equivalent varies by binding; documented via keymapping instead if this proves unreliable)
                session.offset.z = session.offset.z + step
                applyOffset()
            elseif IsControlJustPressed(0, 11) then
                session.offset.z = session.offset.z - step
                applyOffset()
            elseif IsControlJustPressed(0, 191) then -- INPUT_FRONTEND_ACCEPT (Enter)
                endSession(true)
            elseif IsControlJustPressed(0, 194) then -- INPUT_FRONTEND_CANCEL (Esc/Backspace)
                endSession(false)
            end

            DrawText3D(session.offset.x, session.offset.y, session.offset.z, string.format(
                'bone: %s\noffset: %.2f, %.2f, %.2f\nrot: %.1f, %.1f, %.1f',
                session.boneName, session.offset.x, session.offset.y, session.offset.z,
                session.rotation.x, session.rotation.y, session.rotation.z))
        else
            Citizen.Wait(200)
        end
    end
end)

--- Minimal on-screen text helper (this repo has no shared DrawText3D
--- utility today per a codebase search during design) -- kept local to this
--- file since no other plugin needs it yet.
function DrawText3D(x, y, z, text)
    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(x, y, z)
    if onScreen then
        SetTextFont(4)
        SetTextScale(0.3, 0.3)
        SetTextColour(255, 255, 255, 215)
        SetTextEntry("STRING")
        SetTextCentre(true)
        AddTextComponentString(text)
        DrawText(sx, sy)
    end
end
```

- [ ] **Step 2: Fix the placement-relative `DrawText3D` call**

Step 1's main loop calls `DrawText3D(session.offset.x, session.offset.y, session.offset.z, ...)` — these are the *offset* values (small deltas like `0.1`), not world coordinates, so the text would draw at/near the world origin. Replace that call with the prop's actual current world position:

```lua
local propCoords = GetEntityCoords(session.propHandle)
DrawText3D(propCoords.x, propCoords.y, propCoords.z + 0.3, string.format(
    'bone: %s\noffset: %.2f, %.2f, %.2f\nrot: %.1f, %.1f, %.1f',
    session.boneName, session.offset.x, session.offset.y, session.offset.z,
    session.rotation.x, session.rotation.y, session.rotation.z))
```

- [ ] **Step 3: Manual verification**

No automated test (client natives). Verify: `/attach-point-edit <model>` while aiming at a matching live vehicle spawns a preview prop at the nearest bone; arrow keys move it; Shift+arrows rotate it; PageUp/PageDown (or whatever control ids 10/11 actually map to — confirm in-game and adjust the control ids in Step 1 if they don't behave as expected, FiveM control id behavior varies by input context) moves it along Z; Enter stages a save and prints the `/attach-point-save` prompt; running that command with a permitted character persists the row (confirm via `SELECT * FROM attach_points`) and shows the success notification; running it as a character without `propattach_edit` shows the failure notification and does not write a row; Esc cancels without saving.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_propattach/client/PlacementTool.lua
git commit -m "feat(propattach): in-game attach-point placement tool"
```

---

### Task 6: README + spec cross-link

**Files:**
- Create: `plugins/oblsk_propattach/README.md`

**Interfaces:**
- None (documentation only).

- [ ] **Step 1: Write the README**

`plugins/oblsk_propattach/README.md`:

```markdown
# oblsk_propattach

Generic core mechanism to attach a prop to a vehicle/ped/player/object at a
named, DB-defined attach point, synced to every client via
`AttachEntityToEntity` and persisted across restarts.

See `docs/superpowers/specs/2026-08-15-prop-attachment-design.md` for the
full design.

## Usage (from another plugin)

```lua
local row, err = AttachmentService.attach('vehicle', VehToNet(vehicle), 'pounder', 'prop_deer_carc_01', 'trunk_slot', 0, {
    ownerType = 'plugin:oblsk_hunting',
    data = { animal = 'deer', weight = 82 },
})
if row then
    row.parent_model = 'pounder' -- required for the broadcast to resolve bone/offset, see Task 4's note
    PropAttachBroadcast(row)
end

-- later
PropAttachDetach(row.id)
```

## Placement tool

`/attach-point-edit <model>` while aiming at a live entity of that model —
see the design doc's "Placement tool" section for controls.

## Known limitations (v1)

- A restart loses the ability to re-resolve bone/offset for attachments
  whose parent model wasn't separately tracked by the calling plugin — the
  `attachments` table has no `parent_model` column. Callers needing
  restart-durable attachments should re-attach on their own resource start
  rather than relying on this plugin's late-joiner snapshot alone.
- The placement tool has no support for `object`-type parents (no bone
  sweep list) — attach points for objects must be inserted manually via SQL
  for now.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/oblsk_propattach/README.md
git commit -m "docs(propattach): README"
```

---

## Self-Review Notes

- **Spec coverage:** data model (Task 1), server API attach/detach/getAttachments (Task 3), client attach/detach (Task 4), placement tool with raycast+nudge+save (Task 5), testing (Tasks 2-3 automated, Tasks 4-5 manual per spec's "no client test file" convention). All spec sections have a corresponding task.
- **Known gap surfaced, not hidden:** the `parent_model` tracking limitation (Task 4/6) was discovered while writing the plan — the spec didn't specify how a broadcast re-resolves bone/offset without the model. Documented as an explicit v1 limitation in the README rather than silently working around it, since fixing it properly (adding a `parent_model` column) is a real design decision the spec author should make, not one to sneak into an implementation task.
- **Type consistency:** `AttachmentService.attach` signature (Task 3) matches every call site in Task 4 (`parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex, opts`). `AttachPointService.upsert`'s `(model, pointName, slotIndex, boneIndex, offset, rotation)` matches its Task 4 caller.
