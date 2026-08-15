# Shell Builder Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the shell builder plugin real in-game object rendering (bucket-aware entity streaming) and a real placement/removal trigger (camera raycast), plus a minimal staff-only ownership-grant panel.

**Architecture:** `EntityStreamerService` (core) gains a small, additive "group entity" registry — parallel to its existing chunk system, not a modification of it — keyed by an opaque string (the shell's `InstanceService` bucket key) instead of spatial chunks, since every shell physically sits at one shared coordinate and chunk math provides no useful partitioning there. `ShellObjectService` mirrors every placed object into both the `entities` table (persistence) and this group registry (live delivery to whoever's already in the shell). Client-side placement becomes a camera-raycast "aim mode" toggled from the editor dock, confirming via the exact same `shellbuilder:client:place`/`removeObject` server events Task 5 of the original plan already built — no server-side placement logic changes. Ownership grant is a minimal character-name-search panel added to the existing `ShellBrowser.vue`.

**Tech Stack:** Same as the original plan — Lua 5.4, this repo's ORM, Vue 3 SFC, `lua5.4` CLI for headless tests.

**Spec:** `core/docs/superpowers/specs/2026-08-15-shell-builder-followup-design.md`

## Global Constraints

- Every new Lua file follows this repo's existing conventions: `Obelisk.emit*`/`Obelisk.on*` for net events, `<plugin>:<server|client>:<action>` naming, `WebView.on`/`WebView.emit` for NUI.
- No placeholder code, no TODO.
- The group-entity registry is purely additive to `EntityStreamerService` — the existing chunk/tier/budget/hysteresis logic and its test file (`tests/entity_streamer_service_spec.lua`) must be unchanged and still pass.
- `floorLevel` is not wired to real multi-floor state in this pass (the original design's floor up/down buttons were always UI-only stubs, per the source design reference) — placements always use `floorLevel = 0`. This is an accepted, explicitly out-of-scope simplification, not an oversight.
- No ghost/preview prop while aiming (out of scope, noted in the spec).
- Ownership grant stays minimal: one panel, search + add/remove, no bulk operations, no notifications — a future property-agent plugin owns the fuller flow.

---

## File Structure

```
core/
  server/Services/
    InstanceService.lua                       -- modified: + getCurrentBucket (Task 1)
    EntityStreamerService.lua                  -- modified: + group-entity registry (Task 1)
  tests/
    instance_service_spec.lua                  -- modified: + getCurrentBucket tests (Task 1)
    entity_streamer_service_spec.lua           -- modified: + group-entity tests (Task 1)

plugins/oblsk_shellbuilder/
  server/
    services/
      ShellObjectService.lua                    -- modified: mirror to entities + group registry (Task 2)
      ShellService.lua                          -- modified: + searchCharactersByName (Task 4)
    main.lua                                    -- modified: broadcast on place/remove, send group
                                                    snapshot on enter/edit, search/addOwner/
                                                    removeOwner handlers (Tasks 2, 4)
  client/
    main.lua                                    -- modified: relay arm/disarm/wreck NUI messages (Task 3)
    placement.lua                               -- new: raycast aim-mode (Task 3)
  web/
    ShellEditor.vue                             -- modified: Place/Cancel buttons, arm/disarm signaling,
                                                    drop dead defineExpose (Task 3)
    ShellBrowser.vue                            -- modified: ownership management panel (Task 4)
  tests/
    shell_object_service_spec.lua               -- modified: + entities-mirror tests (Task 2)
    shell_service_spec.lua                       -- modified: + searchCharactersByName tests (Task 4)
  README.md                                      -- modified: document the new pieces (Task 5)
```

---

### Task 1: `EntityStreamerService` group-entity registry + `InstanceService.getCurrentBucket`

**Files:**
- Modify: `core/server/Services/EntityStreamerService.lua`
- Modify: `core/server/Services/InstanceService.lua`
- Modify: `core/tests/entity_streamer_service_spec.lua`
- Modify: `core/tests/instance_service_spec.lua`

**Interfaces:**
- Consumes: nothing new (self-contained additions to two already-complete services).
- Produces: `InstanceService.getCurrentBucket(source) -> number` (0 if the player is in no tracked bucket). `EntityStreamerService.registerGroupEntity(groupKey, entityType, entityData, targetSources) -> entityId`, `.unregisterGroupEntity(groupKey, entityType, entityId, targetSources)`, `.getGroupEntityRecords(groupKey) -> { {entityId, entityType, data}, ... }`, `.sendGroupEntitiesTo(source, groupKey)`. Task 2 calls all of these.

- [ ] **Step 1: Write the failing tests**

Append to `core/tests/instance_service_spec.lua` (inside the existing `withFreshState`-based test list, following its exact style):

```lua
test('getCurrentBucket returns 0 for a source with no active bucket', function()
    withFreshState(function()
        eq(InstanceService.getCurrentBucket(7), 0)
    end)
end)

test('getCurrentBucket returns the active bucket after enter', function()
    withFreshState(function()
        local bucketId = InstanceService.enter(7, 'shellbuilder:shell:1')
        eq(InstanceService.getCurrentBucket(7), bucketId)
    end)
end)

test('getCurrentBucket returns 0 again after leave', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        InstanceService.leave(7)
        eq(InstanceService.getCurrentBucket(7), 0)
    end)
end)
```

Append to `core/tests/entity_streamer_service_spec.lua`, following its exact `freshService()`/`test()`/`eq()` pattern (read the existing file first to match style precisely — in particular, replace the file-level `_G.Obelisk` stub with a spy version so these new tests can assert on broadcast calls, without breaking any existing test that only needs the no-op behavior):

```lua
-- Replace the existing no-op Obelisk stub near the top of the file with a
-- spy that records emitClient calls, so group-entity broadcast tests can
-- assert on them. Existing tests never inspect these calls, so this is a
-- behavior-preserving upgrade, not a breaking change.
local emitClientCalls = {}
_G.Obelisk = _G.Obelisk or {
    onServer = function() end,
    emitClient = function(eventName, target, data)
        table.insert(emitClientCalls, { eventName = eventName, target = target, data = data })
    end,
}

test('registerGroupEntity stores a flattened record retrievable via getGroupEntityRecords', function()
    emitClientCalls = {}
    local service = freshService()
    local entityId = service.registerGroupEntity('shellbuilder:shell:1', 'object', {
        id = 42, x = 1.0, y = 2.0, z = 3.0, heading = 90.0, model = 'prop_sofa_01', networked = false,
    })
    local records = service.getGroupEntityRecords('shellbuilder:shell:1')
    eq(#records, 1)
    eq(records[1].entityId, entityId)
    eq(records[1].entityType, 'object')
    eq(records[1].data.model, 'prop_sofa_01')
    eq(records[1].data.x, 1.0)
end)

test('registerGroupEntity broadcasts entityAdd to every target source', function()
    emitClientCalls = {}
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'prop_sofa_01' }, { 7, 9 })
    eq(#emitClientCalls, 2)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityAdd')
    eq(emitClientCalls[1].target, 7)
    eq(emitClientCalls[2].target, 9)
end)

test('registerGroupEntity with no targetSources broadcasts nothing', function()
    emitClientCalls = {}
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'prop_sofa_01' })
    eq(#emitClientCalls, 0)
end)

test('different groupKeys keep entirely separate entity lists', function()
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    service.registerGroupEntity('shellbuilder:shell:2', 'object', { id = 43, x = 1.0, y = 2.0, z = 3.0, model = 'b' })
    eq(#service.getGroupEntityRecords('shellbuilder:shell:1'), 1)
    eq(#service.getGroupEntityRecords('shellbuilder:shell:2'), 1)
end)

test('unregisterGroupEntity removes the record and broadcasts entityRemove', function()
    emitClientCalls = {}
    local service = freshService()
    local entityId = service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    emitClientCalls = {}
    service.unregisterGroupEntity('shellbuilder:shell:1', 'object', entityId, { 7 })
    eq(#service.getGroupEntityRecords('shellbuilder:shell:1'), 0)
    eq(#emitClientCalls, 1)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityRemove')
    eq(emitClientCalls[1].target, 7)
end)

test('sendGroupEntitiesTo emits entityAdd for every record in that group to one source', function()
    local service = freshService()
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 42, x = 1.0, y = 2.0, z = 3.0, model = 'a' })
    service.registerGroupEntity('shellbuilder:shell:1', 'object', { id = 43, x = 4.0, y = 5.0, z = 6.0, model = 'b' })
    emitClientCalls = {}
    service.sendGroupEntitiesTo(7, 'shellbuilder:shell:1')
    eq(#emitClientCalls, 2)
    eq(emitClientCalls[1].eventName, 'core:server:streamer-entityAdd')
    eq(emitClientCalls[1].target, 7)
    eq(emitClientCalls[2].target, 7)
end)

if #failures > 0 then
    print('FAILURES:')
    for _, f in ipairs(failures) do print('  ' .. f) end
    os.exit(1)
else
    print('All entity streamer tests passed')
end
```

(That final `if #failures > 0 ... end` block replaces whatever the existing file's own trailing summary block does — read the actual existing end-of-file first and merge sensibly rather than duplicating a second summary block.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 tests/instance_service_spec.lua` and `lua5.4 tests/entity_streamer_service_spec.lua` (from `core/`)
Expected: FAIL — `getCurrentBucket`/`registerGroupEntity`/etc. are nil.

- [ ] **Step 3: Add `InstanceService.getCurrentBucket`**

In `core/server/Services/InstanceService.lua`, add (near `getPlayersIn`):

```lua
--- @param source number
--- @return number the bucket id this player is currently tracked in, or 0
function InstanceService.getCurrentBucket(source)
    local key = playerBucketKey[source]
    if not key then return 0 end
    return InstanceService.getOrCreateBucket(key)
end
```

- [ ] **Step 4: Add the group-entity registry to `EntityStreamerService`**

In `core/server/Services/EntityStreamerService.lua`, first factor the existing record-flattening logic out of `register()` into a shared helper (pure refactor, no behavior change to the existing chunk path — read the current `register()` function first, lines ~190-224, and extract exactly its flattening loop):

```lua
--- Build the flat record `register`/`registerGroupEntity` both produce: `id`/
--- `type`/`x`/`y`/`z`/`networked` as named fields, every other key of
--- `entityData` (and its nested `data` json blob) shallow-copied onto the
--- same table. Shared so the chunk and group registries stay byte-identical
--- in shape.
--- @param entityType string
--- @param entityData table
--- @param entityId string
--- @return table
function EntityStreamerService.buildEntityRecord(entityType, entityData, entityId)
    local record = {}
    for key, value in pairs(entityData) do
        if key ~= 'data' and key ~= 'id' then record[key] = value end
    end
    if type(entityData.data) == 'table' then
        for key, value in pairs(entityData.data) do
            if key ~= 'id' then record[key] = value end
        end
    end
    record.id = entityId
    record.type = entityType
    record.x = entityData.x
    record.y = entityData.y
    record.z = entityData.z
    record.networked = entityData.networked or false
    return record
end
```

Then replace `register()`'s own inline flattening block (the `local record = {} ... record.networked = ...` lines) with a call to `EntityStreamerService.buildEntityRecord(entityType, entityData, entityId)` — same behavior, less duplication.

Add the group registry itself (near the top, alongside the other `EntityStreamerService.*` state fields):

```lua
--- Group-entity registry: a shell (or any future non-spatial grouping) gets
--- its entities keyed by an opaque string instead of a spatial chunk, since
--- coordinate-based partitioning provides no value when every group's
--- entities sit at the same shared coordinate (see the shell builder
--- follow-up design). Entirely separate from `.entities`/`.chunks` -- no
--- budget, no tier, no hysteresis; a group's caller is responsible for
--- knowing who should see it (see `registerGroupEntity`'s `targetSources`).
EntityStreamerService.groups = {} -- {groupKey: {entityType: {entityId: record}}}
```

```lua
--- @param groupKey string
--- @param entityType string
--- @param entityData table same shape `register` accepts
--- @param targetSources number[]|nil player sources to immediately notify
---   via entityAdd; nil/empty registers without broadcasting (e.g. loading
---   at boot before anyone's connected)
--- @return string entityId
function EntityStreamerService.registerGroupEntity(groupKey, entityType, entityData, targetSources)
    local entityId
    if entityData.id ~= nil then
        entityId = entityType .. '_' .. tostring(entityData.id)
    else
        entityId = entityType .. '_' .. os.time() .. '_' .. math.random(1000, 9999)
    end

    local record = EntityStreamerService.buildEntityRecord(entityType, entityData, entityId)

    EntityStreamerService.groups[groupKey] = EntityStreamerService.groups[groupKey] or {}
    EntityStreamerService.groups[groupKey][entityType] = EntityStreamerService.groups[groupKey][entityType] or {}
    EntityStreamerService.groups[groupKey][entityType][entityId] = record

    for _, target in ipairs(targetSources or {}) do
        Obelisk.emitClient('core:server:streamer-entityAdd', target, {
            entityId = entityId, entityType = entityType, data = record,
        })
    end

    return entityId
end

--- @param groupKey string
--- @param entityType string
--- @param entityId string
--- @param targetSources number[]|nil player sources to notify via entityRemove
function EntityStreamerService.unregisterGroupEntity(groupKey, entityType, entityId, targetSources)
    local group = EntityStreamerService.groups[groupKey]
    if group and group[entityType] then
        group[entityType][entityId] = nil
    end

    for _, target in ipairs(targetSources or {}) do
        Obelisk.emitClient('core:server:streamer-entityRemove', target, {
            entityId = entityId, entityType = entityType,
        })
    end
end

--- @param groupKey string
--- @return table[] { entityId, entityType, data }
function EntityStreamerService.getGroupEntityRecords(groupKey)
    local records = {}
    for entityType, entityIds in pairs(EntityStreamerService.groups[groupKey] or {}) do
        for entityId, record in pairs(entityIds) do
            table.insert(records, { entityId = entityId, entityType = entityType, data = record })
        end
    end
    return records
end

--- Sends every entity currently in `groupKey` to `source` as entityAdd
--- events -- the "catch this player up" call for whenever they enter a
--- shell that already has furniture in it.
--- @param source number
--- @param groupKey string
function EntityStreamerService.sendGroupEntitiesTo(source, groupKey)
    for _, record in ipairs(EntityStreamerService.getGroupEntityRecords(groupKey)) do
        Obelisk.emitClient('core:server:streamer-entityAdd', source, record)
    end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `lua5.4 tests/instance_service_spec.lua` and `lua5.4 tests/entity_streamer_service_spec.lua` (from `core/`)
Expected: all pass, including every pre-existing test in both files (confirm the full pre-existing entity-streamer suite — tier/hysteresis/etc. — is untouched and still green).

- [ ] **Step 6: Verify Lua syntax**

Run: `luac5.4 -p core/server/Services/EntityStreamerService.lua && luac5.4 -p core/server/Services/InstanceService.lua`

- [ ] **Step 7: Commit**

```bash
cd core
git add server/Services/EntityStreamerService.lua server/Services/InstanceService.lua tests/entity_streamer_service_spec.lua tests/instance_service_spec.lua
git commit -m "feat(core): add group-entity registry to EntityStreamerService, InstanceService.getCurrentBucket"
```

---

### Task 2: `ShellObjectService` mirrors to `entities`/group registry; server broadcasts on place/remove

**Files:**
- Modify: `plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua`
- Modify: `plugins/oblsk_shellbuilder/server/main.lua`
- Modify: `plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua`

**Interfaces:**
- Consumes: `EntityStreamerService.registerGroupEntity/unregisterGroupEntity/sendGroupEntitiesTo` (Task 1), `InstanceService.getPlayersIn(key)` (already exists).
- Produces: `ShellObjectService.place`/`remove` now also maintain the `entities` table and the live group registry; `server/main.lua`'s `enter`/`edit` handlers call `EntityStreamerService.sendGroupEntitiesTo` after teleporting.

- [ ] **Step 1: Write the failing tests**

Add to `plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua`. First add an `EntityStreamerService` stub near the top (alongside the existing `ItemService`/`CharacterService` stubs), capturing calls so tests can assert on them:

```lua
local STREAMER_CALLS = { register = {}, unregister = {} }
EntityStreamerService = {}
function EntityStreamerService.registerGroupEntity(groupKey, entityType, entityData, targetSources)
    table.insert(STREAMER_CALLS.register, { groupKey = groupKey, entityType = entityType, entityData = entityData, targetSources = targetSources })
    return entityType .. '_' .. tostring(entityData.id)
end
function EntityStreamerService.unregisterGroupEntity(groupKey, entityType, entityId, targetSources)
    table.insert(STREAMER_CALLS.unregister, { groupKey = groupKey, entityType = entityType, entityId = entityId, targetSources = targetSources })
end
```

Reset `STREAMER_CALLS = { register = {}, unregister = {} }` inside `withFreshState`, alongside the other resets.

```lua
test('place inserts a matching entities row and registers a group entity', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 5.0, 6.0, 7.0, 45.0, 0, nil, false)
        local entityRow = QueryBuilder.new('entities'):where('owner_type', 'shellbuilder_shell_object'):where('owner_id', obj.id):firstSync()
        eq(entityRow ~= nil, true)
        eq(entityRow.entity_type, 'object')
        eq(entityRow.x, 5.0)
        eq(entityRow.y, 6.0)
        eq(entityRow.z, 7.0)
        eq(entityRow.heading, 45.0)

        eq(#STREAMER_CALLS.register, 1)
        eq(STREAMER_CALLS.register[1].groupKey, 'shellbuilder:shell:1')
        eq(STREAMER_CALLS.register[1].entityType, 'object')
        eq(STREAMER_CALLS.register[1].entityData.id, obj.id)
    end)
end)

test('remove deletes the matching entities row and unregisters the group entity', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        STREAMER_CALLS = { register = {}, unregister = {} }
        ShellObjectService.remove(1, 1, obj.id)

        local entityRow = QueryBuilder.new('entities'):where('owner_type', 'shellbuilder_shell_object'):where('owner_id', obj.id):firstSync()
        eq(entityRow, nil)
        eq(#STREAMER_CALLS.unregister, 1)
        eq(STREAMER_CALLS.unregister[1].groupKey, 'shellbuilder:shell:1')
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua` (from `core/`)
Expected: FAIL.

- [ ] **Step 3: Implement the mirroring in `ShellObjectService.place`/`remove`**

In `place`, right after the existing `shell_objects` insert (and after resolving `id`), add:

```lua
EntityStreamerService.registerGroupEntity(
    'shellbuilder:shell:' .. shellId,
    'object',
    { id = id, x = x, y = y, z = z, heading = heading or 0, model = item.data and item.data.shell_model, networked = false },
    InstanceService.getPlayersIn('shellbuilder:shell:' .. shellId)
)

QueryBuilder.new('entities'):insert({
    entity_type = 'object',
    model = item.data and item.data.shell_model,
    x = x, y = y, z = z, heading = heading or 0,
    networked = false,
    enabled = true,
    owner_type = 'shellbuilder_shell_object',
    owner_id = id,
    data = json.encode({ shellId = shellId }),
    created_at = Database.now(),
    updated_at = Database.now(),
})
```

(Read the current `place` function first to insert this in the right spot relative to the existing `local id = QueryBuilder.new('shell_objects'):insert({...})` and its return statement — the entity mirroring must happen after `id` is known, before `place` returns.)

In `remove`, before the existing `QueryBuilder.new('shell_objects'):where('id', objectId):delete()` call, resolve the entity id the same way `place` minted it (`'object_' .. tostring(objectId)`) and add:

```lua
EntityStreamerService.unregisterGroupEntity(
    'shellbuilder:shell:' .. shellId,
    'object',
    'object_' .. tostring(objectId),
    InstanceService.getPlayersIn('shellbuilder:shell:' .. shellId)
)

QueryBuilder.new('entities'):where('owner_type', 'shellbuilder_shell_object'):where('owner_id', objectId):delete()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua` (from `core/`)
Expected: all pass, including every pre-existing test in this file.

- [ ] **Step 5: Wire `server/main.lua` to send the group snapshot on enter/edit**

In `plugins/oblsk_shellbuilder/server/main.lua`, in both the `shellbuilder:client:enter` and `shellbuilder:client:edit` handlers, right after the existing `InstanceService.enter(source, 'shellbuilder:shell:' .. shellId)` call, add:

```lua
EntityStreamerService.sendGroupEntitiesTo(source, 'shellbuilder:shell:' .. shellId)
```

(Both handlers already call `InstanceService.enter` with this exact key string — read the current handlers first to place this call directly after it, before the `editSync`/`entered` emits.)

- [ ] **Step 6: Verify Lua syntax**

Run: `luac5.4 -p plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua && luac5.4 -p plugins/oblsk_shellbuilder/server/main.lua` (from `core/`)

- [ ] **Step 7: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/server/services/ShellObjectService.lua plugins/oblsk_shellbuilder/server/main.lua plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
git commit -m "feat(shellbuilder): mirror placed objects to entities + live EntityStreamerService group registry"
```

---

### Task 3: Client raycast placement (aim mode) + `ShellEditor.vue` UI

**Files:**
- Create: `plugins/oblsk_shellbuilder/client/placement.lua`
- Modify: `plugins/oblsk_shellbuilder/client/main.lua`
- Modify: `plugins/oblsk_shellbuilder/web/ShellEditor.vue`

**Interfaces:**
- Consumes: `WebView.on`/`WebView.emit`/`WebView.hideCursor`/`WebView.showCursor` (core, already exist), `Obelisk.emitServer` (core), the existing `shellbuilder:client:place`/`removeObject` server events (Task 5 of the original plan, unchanged).
- Produces: NUI messages `shellbuilder:arm` (`{ itemKey, locked }`), `shellbuilder:disarm`, `shellbuilder:wreck` (`{ enabled }`) — sent from `ShellEditor.vue` to `client/main.lua`, which relays them into `placement.lua`'s armed state.

- [ ] **Step 1: Add arm/disarm/wreck NUI relaying to `client/main.lua`**

In `plugins/oblsk_shellbuilder/client/main.lua`, add:

```lua
WebView.on('shellbuilder:arm', function(data)
    Placement.arm(data.itemKey, data.locked)
end)

WebView.on('shellbuilder:disarm', function(data)
    Placement.disarm()
end)

WebView.on('shellbuilder:wreck', function(data)
    Placement.setWreckMode(data.enabled)
end)
```

(`Placement` is the global table `client/placement.lua`, below, exposes — this file loads after it per the `client/**/*.lua` glob's alphabetical order, `main.lua` after `placement.lua`; if that ordering assumption is wrong once both files exist, verify via a quick `ls plugins/oblsk_shellbuilder/client/` sort check and adjust — Lua globals are available regardless of declaration order as long as both files have loaded by the time an event fires, which they will, since these are net/NUI event *handlers*, not top-level execution order dependencies.)

- [ ] **Step 2: Write `client/placement.lua`**

```lua
-- plugins/oblsk_shellbuilder/client/placement.lua
--- Placement - camera-raycast aim mode for the shell editor. Selecting an
--- item in the dock arms it (see ShellEditor.vue); a bind while armed
--- releases the NUI cursor and hands the camera back to the player to aim,
--- confirming placement/removal via the same shellbuilder:client:place/
--- removeObject server events the original plugin already wired end to end.
Placement = {}

local armedItemKey = nil
local armedLocked = false
local wreckMode = false
local aiming = false
local heading = 0.0
local currentShellId = nil

--- Set by ShellEditor.vue's editSync handler relaying the shell id, via a
--- small WebView.on('shellbuilder:setShellId', ...) added alongside arm/
--- disarm/wreck in client/main.lua (Step 1) -- add that handler too:
--- WebView.on('shellbuilder:setShellId', function(data) Placement.setShellId(data.shellId) end)
function Placement.setShellId(shellId)
    currentShellId = shellId
end

function Placement.arm(itemKey, locked)
    armedItemKey = itemKey
    armedLocked = locked and true or false
end

function Placement.disarm()
    armedItemKey = nil
    if aiming then Placement.cancelAim() end
end

function Placement.setWreckMode(enabled)
    wreckMode = enabled and true or false
end

local function rayHitPoint()
    local camCoord = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)
    local rad = vector3(camRot.x * (math.pi / 180.0), camRot.y * (math.pi / 180.0), camRot.z * (math.pi / 180.0))
    local direction = vector3(
        -math.sin(rad.z) * math.abs(math.cos(rad.x)),
        math.cos(rad.z) * math.abs(math.cos(rad.x)),
        math.sin(rad.x)
    )
    local maxDistance = 15.0
    local destination = camCoord + direction * maxDistance

    local rayHandle = StartShapeTestRay(camCoord.x, camCoord.y, camCoord.z, destination.x, destination.y, destination.z, -1, PlayerPedId(), 0)
    local _, hit, endCoords, _, entityHit = GetShapeTestResult(rayHandle)

    if hit == 1 then
        return endCoords.x, endCoords.y, endCoords.z, entityHit
    end
    return destination.x, destination.y, destination.z, 0
end

function Placement.startAim()
    if not currentShellId then return end
    if not armedItemKey and not wreckMode then return end
    WebView.hideCursor()
    aiming = true
    heading = GetEntityHeading(PlayerPedId())
end

function Placement.cancelAim()
    aiming = false
    WebView.showCursor()
end

--- Resolves a hit entity handle back to its shell_objects id via the
--- client EntityStreamerService's spawned-entity map (entityId "object_<id>"
--- -> handle). See EntityStreamerService.entities on the client (keyed by
--- the same entityId strings ShellObjectService/EntityStreamerService mint
--- server-side, "object_<shell_objects.id>").
local function resolveShellObjectId(entityHandle)
    for entityId, entry in pairs(EntityStreamerService.entities) do
        if entry.handle == entityHandle then
            local numericId = entityId:match('^object_(%d+)$')
            if numericId then return tonumber(numericId) end
        end
    end
    return nil
end

function Placement.confirm()
    if not aiming then return end
    local x, y, z, entityHit = rayHitPoint()

    if wreckMode then
        local objectId = resolveShellObjectId(entityHit)
        if objectId then
            Obelisk.emitServer('shellbuilder:client:removeObject', currentShellId, objectId)
        end
    elseif armedItemKey then
        Obelisk.emitServer('shellbuilder:client:place', currentShellId, armedItemKey, x, y, z, heading, 0, nil, armedLocked)
    end
end

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        if aiming then
            if IsControlJustPressed(0, 24) then -- INPUT_ATTACK (left click)
                Placement.confirm()
            elseif IsControlJustPressed(0, 25) or IsControlJustPressed(0, 322) then -- INPUT_AIM (right click) / ESC
                Placement.cancelAim()
            elseif IsControlJustPressed(0, 44) then -- INPUT_COVER (Q), rotate left
                heading = (heading - 5.0) % 360.0
            elseif IsControlJustPressed(0, 38) then -- INPUT_PICKUP (E), rotate right
                heading = (heading + 5.0) % 360.0
            end
        end
    end
end)

return Placement
```

Note on control IDs: `24`/`25`/`322` are FiveM's standard attack/aim/ESC controls; `44`/`38` (Q/E) are placeholders picked to match common FiveM building-mod conventions but may collide with default GTA controls (Q is normally cover, E is normally pickup/vault) — since `aiming` mode already released the cursor but the player is NOT necessarily in a vehicle or combat stance, verify during manual testing whether Q/E fire their default GTA behavior alongside the rotate here; if so, this is a minor UX polish item to fix later (e.g. via `DisableControlAction`), not a functional blocker — note it in the implementation report rather than over-engineering a full control-disable pass now.

- [ ] **Step 3: Add the "Place"/"Cancel" trigger and arm/disarm signaling to `ShellEditor.vue`**

In `plugins/oblsk_shellbuilder/web/ShellEditor.vue`'s `<script setup>`:

- Remove the dead `defineExpose({ place, removeObject })` line and the now-unused `place`/`removeObject` local functions (placement is now driven by `client/placement.lua`, not by these Vue methods being called from nowhere).
- Add a `watch` on `selectedItem` (or whatever the existing selected-item ref is named — read the file first) that emits `Obelisk.emit('shellbuilder:arm', { itemKey: selectedItem.value, locked: locked.value })` whenever it changes to a non-null value, and `Obelisk.emit('shellbuilder:disarm', {})` when it becomes null or when `tool` changes away from a placement-capable tool.
- Add a `watch` on the existing `wreck` ref that emits `Obelisk.emit('shellbuilder:wreck', { enabled: wreck.value })`.
- Add a `watch` on the `shell` ref (set by the `editSync` handler) that emits `Obelisk.emit('shellbuilder:setShellId', { shellId: shell.value?.id })` whenever it changes, so `client/placement.lua` knows which shell it's placing into.
- Add a small "Place (aim)" button next to the existing tool/item selection UI, visible only when an item is selected, that emits a new `shellbuilder:startAim` NUI message (`Obelisk.emit('shellbuilder:startAim', {})`) — add the matching `WebView.on('shellbuilder:startAim', function() Placement.startAim() end)` relay in `client/main.lua` alongside the arm/disarm/wreck handlers from Step 1.

Keep this additive to the file's existing structure — don't restructure the tool rail, category chips, or budget bar, which are all unchanged and already correct.

- [ ] **Step 4: Manual verification** (no automated test — natives aren't unit-testable here)

Since this is pure client-side native/NUI-event code, verify manually once a FiveM environment is available: confirm `luac5.4 -p` passes on `placement.lua` and `client/main.lua`, confirm the Vue changes don't introduce a syntax error (dev build or manual read-through), and note in the report that in-game verification (aim mode toggling, raycast hit accuracy, placement/removal actually working) is deferred to the plan's final manual checklist (Task 5).

- [ ] **Step 5: Verify Lua syntax**

Run: `luac5.4 -p plugins/oblsk_shellbuilder/client/placement.lua && luac5.4 -p plugins/oblsk_shellbuilder/client/main.lua` (from `core/`)

- [ ] **Step 6: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/client/placement.lua plugins/oblsk_shellbuilder/client/main.lua plugins/oblsk_shellbuilder/web/ShellEditor.vue
git commit -m "feat(shellbuilder): add camera-raycast aim mode for placement/removal"
```

---

### Task 4: Ownership grant — character search + management panel

**Files:**
- Modify: `plugins/oblsk_shellbuilder/server/services/ShellService.lua`
- Modify: `plugins/oblsk_shellbuilder/server/main.lua`
- Modify: `plugins/oblsk_shellbuilder/tests/shell_service_spec.lua`
- Modify: `plugins/oblsk_shellbuilder/web/ShellBrowser.vue`

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: `ShellService.searchCharactersByName(query) -> { {id, first_name, last_name}, ... }` (capped at 20). Net events `shellbuilder:client:searchCharacters`, `shellbuilder:client:addOwner`, `shellbuilder:client:removeOwner` (server), relayed via `shellbuilder:searchCharacters`/`shellbuilder:addOwner`/`shellbuilder:removeOwner` (NUI, in `ShellBrowser.vue`).

- [ ] **Step 1: Write the failing tests**

Add to `plugins/oblsk_shellbuilder/tests/shell_service_spec.lua`:

```lua
test('searchCharactersByName matches first or last name, case-insensitively', function()
    withFreshState(function()
        QueryBuilder.new('characters'):insert({ id = 1, first_name = 'John', last_name = 'Smith', deleted_at = nil })
        QueryBuilder.new('characters'):insert({ id = 2, first_name = 'Jane', last_name = 'Johnson', deleted_at = nil })
        QueryBuilder.new('characters'):insert({ id = 3, first_name = 'Bob', last_name = 'Lee', deleted_at = nil })

        local results = ShellService.searchCharactersByName('john')
        eq(#results, 2) -- John Smith (first name) + Jane Johnson (last name)
    end)
end)

test('searchCharactersByName returns an empty list for no matches', function()
    withFreshState(function()
        QueryBuilder.new('characters'):insert({ id = 1, first_name = 'John', last_name = 'Smith' })
        eq(#ShellService.searchCharactersByName('xyz'), 0)
    end)
end)

test('searchCharactersByName caps results at 20', function()
    withFreshState(function()
        for i = 1, 25 do
            QueryBuilder.new('characters'):insert({ id = i, first_name = 'Match' .. i, last_name = 'Test' })
        end
        eq(#ShellService.searchCharactersByName('match'), 20)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua` (from `core/`)
Expected: FAIL.

- [ ] **Step 3: Implement `ShellService.searchCharactersByName`**

```lua
--- Substring, case-insensitive match against first_name/last_name. Filters
--- in Lua rather than SQL LIKE, matching this plugin's existing convention
--- of staying testable against the fake in-memory QueryBuilder, which has
--- no LIKE support.
--- @param query string
--- @return table[] up to 20 { id, first_name, last_name } rows
function ShellService.searchCharactersByName(query)
    local needle = query:lower()
    local rows = QueryBuilder.new('characters'):getSync()
    local results = {}

    for _, row in ipairs(rows) do
        local first = (row.first_name or ''):lower()
        local last = (row.last_name or ''):lower()
        if first:find(needle, 1, true) or last:find(needle, 1, true) then
            table.insert(results, { id = row.id, first_name = row.first_name, last_name = row.last_name })
            if #results >= 20 then break end
        end
    end

    return results
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua` (from `core/`)
Expected: all pass, including every pre-existing test.

- [ ] **Step 5: Wire the server handlers**

In `plugins/oblsk_shellbuilder/server/main.lua`, add (near the other `Obelisk.onServer` handlers):

```lua
Obelisk.onServer('shellbuilder:client:searchCharacters', function(query)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end
    Obelisk.emitClient('shellbuilder:server:characterSearchResults', source, ShellService.searchCharactersByName(query or ''))
end)

Obelisk.onServer('shellbuilder:client:addOwner', function(shellId, characterId)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end
    ShellService.addOwner(shellId, characterId)
    Obelisk.emitClient('shellbuilder:server:ownersUpdated', source, { shellId = shellId, owners = ShellService.listOwners(shellId) })
end)

Obelisk.onServer('shellbuilder:client:removeOwner', function(shellId, characterId)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end
    ShellService.removeOwner(shellId, characterId)
    Obelisk.emitClient('shellbuilder:server:ownersUpdated', source, { shellId = shellId, owners = ShellService.listOwners(shellId) })
end)
```

In `plugins/oblsk_shellbuilder/client/main.lua`, add the relays:

```lua
WebView.on('shellbuilder:searchCharacters', function(data)
    WebView.emitServer('shellbuilder:client:searchCharacters', data.query)
end)
WebView.on('shellbuilder:addOwner', function(data)
    WebView.emitServer('shellbuilder:client:addOwner', data.shellId, data.characterId)
end)
WebView.on('shellbuilder:removeOwner', function(data)
    WebView.emitServer('shellbuilder:client:removeOwner', data.shellId, data.characterId)
end)

Obelisk.onClient('shellbuilder:server:characterSearchResults', function(payload)
    WebView.emit('shellbuilder:characterSearchResults', payload)
end)
Obelisk.onClient('shellbuilder:server:ownersUpdated', function(payload)
    WebView.emit('shellbuilder:ownersUpdated', payload)
end)
```

- [ ] **Step 6: Add the management panel to `ShellBrowser.vue`**

In the detail pane (the section that already shows `selected.name`/Enter/Edit buttons, gated on `permissions.canBuild`), add a collapsible block:

```vue
<div v-if="permissions.canBuild && selected" class="mt-4 pt-4" style="border-top:1px solid color-mix(in oklab, var(--ob-accent) 25%, transparent)">
  <div class="text-[12px] font-semibold uppercase tracking-wide mb-2">Manage owners</div>
  <div class="flex flex-col gap-1 mb-2">
    <div v-for="ownerId in currentOwners" :key="ownerId" class="flex items-center justify-between text-[12px] py-1">
      <span>Character #{{ ownerId }}</span>
      <button @click="removeOwner(ownerId)" class="text-[11px] px-2 py-0.5 rounded" style="border:1px solid rgba(239,68,68,.4);color:#fca5a5">Remove</button>
    </div>
  </div>
  <input v-model="ownerSearch" @input="searchOwners" placeholder="Search character name..."
    class="w-full h-[30px] rounded-[6px] px-2 text-[12px] bg-black/40 outline-none mb-1"
    style="border:1px solid rgba(255,255,255,.12)" />
  <div v-for="result in ownerSearchResults" :key="result.id" class="flex items-center justify-between text-[12px] py-1">
    <span>{{ result.first_name }} {{ result.last_name }}</span>
    <button @click="addOwner(result.id)" class="text-[11px] px-2 py-0.5 rounded" style="background:var(--ob-accent);color:#04120d">Add</button>
  </div>
</div>
```

And in `<script setup>`:

```js
const currentOwners = ref([])
const ownerSearch = ref('')
const ownerSearchResults = ref([])

function searchOwners() {
  Obelisk.emit('shellbuilder:searchCharacters', { query: ownerSearch.value })
}
function addOwner(characterId) {
  if (!selected.value) return
  Obelisk.emit('shellbuilder:addOwner', { shellId: selected.value.id, characterId })
}
function removeOwner(characterId) {
  if (!selected.value) return
  Obelisk.emit('shellbuilder:removeOwner', { shellId: selected.value.id, characterId })
}

Obelisk.on('shellbuilder:characterSearchResults', (results) => {
  ownerSearchResults.value = results || []
})
Obelisk.on('shellbuilder:ownersUpdated', (payload) => {
  if (selected.value && payload.shellId === selected.value.id) {
    currentOwners.value = payload.owners || []
  }
})
```

Add `Obelisk.off` cleanup for these two new listeners in the component's existing `onUnmounted` block (matching the pattern the rest of the file already uses), and note in the report where `currentOwners` gets its initial value from when a shell is first selected (the sync payload doesn't currently include per-shell owner lists — either extend it, or accept that the panel starts empty until the first add/remove roundtrip; pick whichever is simpler and say so).

- [ ] **Step 7: Verify Lua syntax**

Run: `luac5.4 -p plugins/oblsk_shellbuilder/server/services/ShellService.lua && luac5.4 -p plugins/oblsk_shellbuilder/server/main.lua && luac5.4 -p plugins/oblsk_shellbuilder/client/main.lua` (from `core/`)

- [ ] **Step 8: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/server/services/ShellService.lua plugins/oblsk_shellbuilder/server/main.lua plugins/oblsk_shellbuilder/client/main.lua plugins/oblsk_shellbuilder/tests/shell_service_spec.lua plugins/oblsk_shellbuilder/web/ShellBrowser.vue
git commit -m "feat(shellbuilder): add ownership grant panel (character search + add/remove)"
```

---

### Task 5: README updates, full test run, manual verification checklist

**Files:**
- Modify: `plugins/oblsk_shellbuilder/README.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — documentation and final verification only.

- [ ] **Step 1: Update the README**

Add a section documenting: object rendering is now live (via `EntityStreamerService`'s group registry, bucket-isolated), placement/removal happens via camera-raycast aim mode (describe the Place button → aim → left-click confirm / right-click cancel flow briefly), and the ownership management panel (staff/build-permission only, in the shell browser's detail pane).

- [ ] **Step 2: Run every test file from both this plan and the original plan**

Run (from `core/`):
```bash
lua5.4 tests/instance_service_spec.lua
lua5.4 tests/entity_streamer_service_spec.lua
lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua
lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
```
Expected: all pass, 0 failures.

- [ ] **Step 3: Verify Lua syntax across the whole plugin and the touched core files**

Run: `find plugins/oblsk_shellbuilder -name '*.lua' -exec luac5.4 -p {} \; && luac5.4 -p core/server/Services/EntityStreamerService.lua && luac5.4 -p core/server/Services/InstanceService.lua` (from `core/`)

- [ ] **Step 4: Manual verification checklist** (not automatable)

1. Enter a shell as owner or staff; confirm no objects appear if none are placed yet (empty shell) and existing objects DO appear if the shell already has some (tests this plan's `sendGroupEntitiesTo` path).
2. Select a decor item, click "Place (aim)", confirm the cursor releases and the camera can be aimed; left-click at a wall/floor; confirm the object appears immediately for you.
3. With a second player also inside the same shell, confirm the placed object appears for them too (tests the `targetSources = InstanceService.getPlayersIn(...)` broadcast).
4. Confirm a player in a *different* shell (or the overworld) never sees this shell's objects (tests bucket isolation — the core property this whole follow-up exists to prove).
5. Toggle wreck mode, aim at a placed unlocked object, confirm left-click removes it for everyone currently in the shell.
6. Confirm a *locked* object cannot be removed via wreck mode (server-side `ShellObjectService.remove`'s existing locked check still applies — this plan didn't touch that logic).
7. As staff, search a character by partial name in a shell's management panel, add them as an owner, confirm they subsequently see "Enter" for that shell; remove them, confirm the button disappears.
8. Confirm Q/E rotate the pending placement's heading as expected while aiming; note any control-ID collision with default GTA behavior (per Task 3's note) if observed.

- [ ] **Step 5: Commit**

```bash
cd core
git add plugins/oblsk_shellbuilder/README.md
git commit -m "docs(shellbuilder): document object rendering, raycast placement, and ownership grant"
```

## Self-Review Notes

- **Spec coverage:** §1 (bucket-aware EntityStreamerService) ✓ Task 1+2, §2 (raycast placement) ✓ Task 3, §3 (ownership grant) ✓ Task 4, testing posture (targeted new coverage, no attempt at full pre-existing chunk/tier coverage, no client-side tests) ✓ throughout, all "Out of Scope" items (ghost preview, full property-agent flow, chunk logic changes, networked objects) correctly absent from every task.
- **Placeholder scan:** none — every step has complete code or a concrete, named manual-verification action.
- **Type consistency:** `EntityStreamerService.registerGroupEntity/unregisterGroupEntity/getGroupEntityRecords/sendGroupEntitiesTo` signatures match exactly between Task 1's implementation, Task 1's tests, and Task 2's call sites. The group key string `'shellbuilder:shell:' .. shellId` matches the key `InstanceService.enter`/`getPlayersIn` already use everywhere in the original plan — verified against the original plan's `server/main.lua` code, not just assumed. `entityId` minting (`'object_' .. tostring(id)`) matches between `ShellObjectService.place`'s registration call and `remove`'s resolution, and matches `placement.lua`'s `resolveShellObjectId` pattern-match (`'^object_(%d+)$'`).
