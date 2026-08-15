# MDT Command/Lines rework + real flight-mode/DND Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `oblsk_mdt`'s placeholder unit-assignment model with a real on-duty-roster-based Command centre, build a real emergency-line registration/failover system in the Lines module wired into `oblsk_phone`'s dialer, and make flight-mode/DND real server-observed state instead of cosmetic client-only toggles.

**Architecture:** Two plugins touched. `oblsk_mdt` gets a schema change (drop `mdt_unit_assignments`, extend `mdt_staff_meta`) plus a new `MdtLineService`/`mdt_lines`/`mdt_line_registrations`. `oblsk_phone`'s `DialerService` gains a line-resolution fallback + ring-timeout/failover state machine, and its `PreferenceService`-backed flight-mode/DND state (already real storage, just disconnected client refs) gets wired into the messages-send push path and a new shared client preference store.

**Tech Stack:** Lua (FXServer, `Obelisk.onServer`/`emitClient`, `QueryBuilder`, `Schema`), Vue 3 `<script setup>`.

**Spec:** `core/docs/superpowers/specs/2026-08-15-mdt-command-lines-and-flight-mode-design.md`

## Global Constraints

- `mdt_lines.number` is unique across the whole table (no per-org scoping) — confirmed acceptable by the user, no collision-resolution logic anywhere.
- DND gates nothing server-side — client-only notification suppression.
- Flight mode gates exactly four points: message live-push, direct dialer calls, line-call failover, and the flight-mode character's own MDT accessibility (client-side "no signal" placeholder, not a new push block).
- No queueing/retry/voicemail on failed line calls — a failed call just fails.
- `oblsk_phone`'s `DispatchService`/`phone_dispatch_calls` (CAD board) stays completely untouched — do not modify it, do not add new reads to it. This plan REMOVES `oblsk_mdt`'s existing read of it (`command-active-calls`/`MdtCommandService.activeCalls`) since neither Command nor Lines' redesigned scope includes a CAD-board view anymore — this is a deliberate feature removal, not an oversight; call it out explicitly wherever it appears in this plan.
- Every new server write handler follows this codebase's established convention: resolve `characterId` server-side via `CharacterService.getActiveCharacterId(source)` (never trust a client-supplied id), gate with the exact permission key named in each task, respond `{ok:false, error:'forbidden'}` on refusal, log every successful write via `MdtAuditService.log` (oblsk_mdt side) — `oblsk_phone` has no equivalent audit log, don't invent one there.

---

## File structure

**`oblsk_mdt` (create):**
- `server/migrations/2026_08_15_000006_rework_mdt_command_tables.lua`
- `server/migrations/2026_08_15_000007_create_mdt_lines_tables.lua`
- `server/services/MdtLineService.lua`
- `tests/mdt_line_service_spec.lua`
- `web/apps/Lines/Lines.vue` (full rewrite)

**`oblsk_mdt` (modify):**
- `server/services/MdtStaffService.lua` — add `setAssignedVehicle`
- `server/services/MdtCommandService.lua` — delete `assign`/`assignments`/`activeCalls`, keep `fleet`
- `server/main.lua` — remove `command-assign`/`command-assignments`/`command-active-calls` handlers; add `staff-set-vehicle`; add `lines-list`/`lines-create`/`lines-delete`/`lines-register`/`lines-unregister`; update `buildStaffList` to carry `assigned_vehicle_id`
- `tests/mdt_staff_service_spec.lua` — add `setAssignedVehicle` coverage
- `web/apps/Command/Command.vue` — full rewrite (drop CAD board, add vehicle-assign dropdown)
- `server/migrations.json` — register the two new migrations

**`oblsk_phone` (create):**
- `web/phone/phonePreferences.js` — shared reactive flight-mode/DND store used by `Phone.vue` and `Settings.vue`

**`oblsk_phone` (modify):**
- `server/services/DialerService.lua` — line-resolution fallback, ring-timeout, failover state machine
- `server/main.lua` — flight-mode gate in `messages-send`; new server-driven timeout wiring for `dialer-call`
- `web/Phone.vue` — replace local `flight`/`dnd` refs with `phonePreferences.js`
- `web/apps/Settings/Settings.vue` — flight/dnd rows read/write through `phonePreferences.js` instead of local `state`
- `tests/dialer_service_spec.lua` — line routing/timeout/failover coverage

---

## Task 1: Command centre schema — drop `mdt_unit_assignments`, extend `mdt_staff_meta`

**Files:**
- Create: `core/plugins/oblsk_mdt/server/migrations/2026_08_15_000006_rework_mdt_command_tables.lua`
- Modify: `core/plugins/oblsk_mdt/server/migrations.json`

**Interfaces:**
- Produces: `mdt_staff_meta.assigned_vehicle_id` (integer, nullable) — consumed by Task 2's `MdtStaffService.setAssignedVehicle` and Task 4's `buildStaffList` update.

- [ ] **Step 1: Write the migration**

```lua
--- Migration: Command centre rework. A "unit" is not a free-standing
--- entity, it's simply an on-duty officer - mdt_unit_assignments (free-text
--- unit_id, never shipped to real players) is dropped outright rather than
--- migrated. Vehicle assignment moves onto mdt_staff_meta as
--- assigned_vehicle_id, alongside the existing status/cam columns. See
--- docs/superpowers/specs/2026-08-15-mdt-command-lines-and-flight-mode-design.md.
return {
    up = function()
        Schema.drop('mdt_unit_assignments')
        Schema.table('mdt_staff_meta', function(table)
            table:integer('assigned_vehicle_id'):nullable()
        end)
        print('[Migration] Dropped mdt_unit_assignments, added assigned_vehicle_id to mdt_staff_meta')
    end,
    down = function()
        Schema.dropColumn('mdt_staff_meta', 'assigned_vehicle_id')
        Schema.create('mdt_unit_assignments', function(table)
            table:id()
            table:integer('organization_id'):index()
            table:string('unit_id', 20)
            table:integer('character_id'):nullable()
            table:integer('fleet_id'):nullable()
        end)
        print('[Migration] Restored mdt_unit_assignments, dropped assigned_vehicle_id')
    end
}
```

- [ ] **Step 2: Register it in migrations.json**

Add `"2026_08_15_000006_rework_mdt_command_tables"` to the end of the `migrations` array in `core/plugins/oblsk_mdt/server/migrations.json` (after `"2026_08_15_000005_create_mdt_document_templates_table"`).

- [ ] **Step 3: Commit**

```bash
cd core/plugins/oblsk_mdt
git add server/migrations/2026_08_15_000006_rework_mdt_command_tables.lua server/migrations.json
git commit -m "mdt: drop mdt_unit_assignments, add assigned_vehicle_id to staff meta"
```

---

## Task 2: `MdtStaffService.setAssignedVehicle`

**Files:**
- Modify: `core/plugins/oblsk_mdt/server/services/MdtStaffService.lua`
- Test: `core/plugins/oblsk_mdt/tests/mdt_staff_service_spec.lua`

**Interfaces:**
- Consumes: `targetIsInOrg(orgId, targetCharacterId)` (already-existing local helper in this file), `ensureMeta(characterId)` (already-existing local helper), `MdtAuditService.log(characterId, auth, module, what, ref)`.
- Produces: `MdtStaffService.setAssignedVehicle(characterId, auth, orgId, targetCharacterId, vehicleId)` — `vehicleId` may be `nil` to unassign. Returns `true`/`false`. Consumed by Task 3's `staff-set-vehicle` event handler.

- [ ] **Step 1: Write the failing test**

Add to `core/plugins/oblsk_mdt/tests/mdt_staff_service_spec.lua` (follow the exact `test`/`eq` + fake-`QueryBuilder` `setup()` pattern already in that file):

```lua
test('setAssignedVehicle sets the vehicle for an on-duty target in the org', function()
    local tables, logged = setup()
    tables['organization_memberships'] = { { character_id = 5, organization_id = 1 } }
    local ok = MdtStaffService.setAssignedVehicle(1, 'lspd', 1, 5, 42)
    eq(ok, true)
    eq(MdtStaffService.metaFor(5).assigned_vehicle_id, 42)
    eq(#logged, 1, 'audit logged once')
end)

test('setAssignedVehicle refuses a target not in the acting org', function()
    local tables = setup()
    tables['organization_memberships'] = {}
    local ok = MdtStaffService.setAssignedVehicle(1, 'lspd', 1, 5, 42)
    eq(ok, false)
end)

test('setAssignedVehicle accepts nil to unassign', function()
    local tables = setup()
    tables['organization_memberships'] = { { character_id = 5, organization_id = 1 } }
    MdtStaffService.setAssignedVehicle(1, 'lspd', 1, 5, 42)
    local ok = MdtStaffService.setAssignedVehicle(1, 'lspd', 1, 5, nil)
    eq(ok, true)
    eq(MdtStaffService.metaFor(5).assigned_vehicle_id, nil)
end)
```

Check the top of this spec file first for how `OrganizationService.getMemberships` is currently stubbed (it's used by the existing `targetIsInOrg` tests for `setDuty`/`setCam`) — reuse that exact stub, don't invent a new one. If the existing stub already reads from a `tables['organization_memberships']`-shaped fake, match it; if it stubs `OrganizationService.getMemberships` as a plain Lua function instead, write these three tests against that same stub style instead of the table shown above.

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
cd core/plugins/oblsk_mdt
lua tests/mdt_staff_service_spec.lua
```

Expected: FAIL — `attempt to call a nil value (method 'setAssignedVehicle')`.

- [ ] **Step 3: Implement**

Add to `core/plugins/oblsk_mdt/server/services/MdtStaffService.lua`, after `setCam`:

```lua
--- @param characterId number acting character
--- @param auth string
--- @param orgId number the acting character's organization
--- @param targetCharacterId number
--- @param vehicleId number|nil nil to unassign
--- @return boolean true when set, false when refused
function MdtStaffService.setAssignedVehicle(characterId, auth, orgId, targetCharacterId, vehicleId)
    if not targetIsInOrg(orgId, targetCharacterId) then return false end

    ensureMeta(targetCharacterId)
    QueryBuilder.new('mdt_staff_meta'):where('character_id', targetCharacterId):update({ assigned_vehicle_id = vehicleId })
    MdtAuditService.log(characterId, auth, 'staff',
        vehicleId and ('assigned vehicle ' .. tostring(vehicleId)) or 'unassigned vehicle',
        tostring(targetCharacterId))
    return true
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
lua tests/mdt_staff_service_spec.lua
```

Expected: `All tests passed`.

- [ ] **Step 5: Commit**

```bash
git add server/services/MdtStaffService.lua tests/mdt_staff_service_spec.lua
git commit -m "mdt: add MdtStaffService.setAssignedVehicle"
```

---

## Task 3: Remove old Command events, add `staff-set-vehicle`, update `buildStaffList`

**Files:**
- Modify: `core/plugins/oblsk_mdt/server/main.lua`
- Modify: `core/plugins/oblsk_mdt/server/services/MdtCommandService.lua`

**Interfaces:**
- Consumes: `MdtStaffService.setAssignedVehicle` (Task 2).
- Produces: `oblsk_mdt:server:staff-set-vehicle` event; `buildStaffList` rows now carry `assigned_vehicle_id`. Consumed by Task 8 (Command.vue).

- [ ] **Step 1: Delete the obsolete Command handlers in `server/main.lua`**

Delete these three handler blocks entirely (they currently sit around lines 919-956 and 1368-1378 — re-locate by searching for the event names, since earlier tasks in this plan may have shifted line numbers):
- `Obelisk.onServer('oblsk_mdt:server:command-assignments', ...)`
- `Obelisk.onServer('oblsk_mdt:server:command-assign', ...)`
- `Obelisk.onServer('oblsk_mdt:server:command-active-calls', ...)`

Keep `Obelisk.onServer('oblsk_mdt:server:command-fleet', ...)` untouched.

- [ ] **Step 2: Delete the now-unused `MdtCommandService` functions**

In `core/plugins/oblsk_mdt/server/services/MdtCommandService.lua`, delete `MdtCommandService.assignments`, `MdtCommandService.assign`, and `MdtCommandService.activeCalls`. Keep `MdtCommandService.fleet` untouched. Update the file's header doc-comment (currently describes "fleet roster and unit assignments, plus a read-only proxy into oblsk_phone's dispatch call board") to reflect that it's now fleet-only — vehicle assignment lives on `MdtStaffService`, and the dispatch-board proxy is removed (Lines no longer reads it, per the design's explicit removal of the CAD-board view from MDT).

- [ ] **Step 3: Update `buildStaffList` to carry the new field**

In `core/plugins/oblsk_mdt/server/main.lua`, find the `buildStaffList` local function (around line 27) and add `assigned_vehicle_id` to the per-row table it assembles:

```lua
local function buildStaffList(orgId)
    local members = OrganizationService.listMembers(orgId)
    local staff = {}
    for _, member in ipairs(members) do
        local meta = MdtStaffService.metaFor(member.character_id) or {}
        table.insert(staff, {
            character_id = member.character_id,
            name = member.name,
            rank = member.rank,
            status = meta.status or 'OFF DUTY',
            cam = meta.cam or false,
            assigned_vehicle_id = meta.assigned_vehicle_id,
        })
    end
    return staff
end
```

- [ ] **Step 4: Add the `staff-set-vehicle` event**

Add immediately after the existing `staff-set-cam` handler in `server/main.lua` (find it by searching for `oblsk_mdt:server:staff-set-cam`):

```lua
Obelisk.onServer('oblsk_mdt:server:staff-set-vehicle', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    local character = resolved and Character:findSync(characterId)
    if not resolved or not character or not character:can('mdt-write-staff') then
        Obelisk.emitClient('oblsk_mdt:client:staff-set-vehicle', source, { ok = false, error = 'forbidden' })
        return
    end
    data = data or {}
    local auth, _, orgId = MdtAuthService.acting(resolved, data.auth)
    if not MdtStaffService.setAssignedVehicle(characterId, auth, orgId, data.targetCharacterId, data.vehicleId) then
        Obelisk.emitClient('oblsk_mdt:client:staff-set-vehicle', source, { ok = false, error = 'forbidden' })
        return
    end
    Obelisk.emitClient('oblsk_mdt:client:staff-set-vehicle', source, { ok = true, targetCharacterId = data.targetCharacterId })
    Obelisk.emitClient('oblsk_mdt:client:staff-list', source, buildStaffList(orgId))
end)
```

- [ ] **Step 5: Syntax-check and run the full test suite**

```bash
cd core/plugins/oblsk_mdt
lua -e "assert(loadfile('server/main.lua'))" 2>&1 | head -5
lua -e "assert(loadfile('server/services/MdtCommandService.lua'))" 2>&1 | head -5
lua tests/mdt_staff_service_spec.lua
```

Expected: no syntax errors printed, staff spec still `All tests passed`. (There's no `mdt_command_service_spec.lua` covering the deleted functions to worry about — confirm this by checking `ls tests/ | grep command`; if one exists, delete the now-obsolete test cases for `assign`/`assignments`/`activeCalls` from it, keeping any `fleet` coverage.)

- [ ] **Step 6: Commit**

```bash
git add server/main.lua server/services/MdtCommandService.lua tests/
git commit -m "mdt: remove unit-assignment/CAD-board Command events, add staff-set-vehicle"
```

---

## Task 4: `mdt_lines` / `mdt_line_registrations` schema

**Files:**
- Create: `core/plugins/oblsk_mdt/server/migrations/2026_08_15_000007_create_mdt_lines_tables.lua`
- Modify: `core/plugins/oblsk_mdt/server/migrations.json`

**Interfaces:**
- Produces: `mdt_lines` (`id, organization_id, number, label`), `mdt_line_registrations` (`id, line_id, character_id, role, registered_at`) — consumed by Task 5's `MdtLineService`.

- [ ] **Step 1: Write the migration**

```lua
--- Migration: Emergency-line registration. A line belongs to one org and
--- has a globally-unique number (no cross-org number sharing - confirmed
--- with the user, so no collision-resolution logic exists anywhere in this
--- feature). Officers register as 'primary' or 'passive' on a line their
--- own org owns; at most one of each role per line is enforced in
--- MdtLineService (upsert-by-role), not a DB constraint. See
--- docs/superpowers/specs/2026-08-15-mdt-command-lines-and-flight-mode-design.md.
return {
    up = function()
        Schema.create('mdt_lines', function(table)
            table:id()
            table:integer('organization_id'):index()
            table:string('number', 20):unique()
            table:string('label', 100)
        end)
        Schema.create('mdt_line_registrations', function(table)
            table:id()
            table:integer('line_id'):index()
            table:integer('character_id')
            table:string('role', 10)
            table:datetime('registered_at')
        end)
        print('[Migration] Created mdt_lines tables')
    end,
    down = function()
        Schema.drop('mdt_line_registrations')
        Schema.drop('mdt_lines')
        print('[Migration] Dropped mdt_lines tables')
    end
}
```

- [ ] **Step 2: Register it in migrations.json**

Add `"2026_08_15_000007_create_mdt_lines_tables"` to the end of the `migrations` array.

- [ ] **Step 3: Commit**

```bash
cd core/plugins/oblsk_mdt
git add server/migrations/2026_08_15_000007_create_mdt_lines_tables.lua server/migrations.json
git commit -m "mdt: add mdt_lines/mdt_line_registrations tables"
```

---

## Task 5: `MdtLineService`

**Files:**
- Create: `core/plugins/oblsk_mdt/server/services/MdtLineService.lua`
- Test: `core/plugins/oblsk_mdt/tests/mdt_line_service_spec.lua`

**Interfaces:**
- Produces: `MdtLineService.list(orgId)`, `MdtLineService.create(characterId, auth, orgId, number, label)`, `MdtLineService.delete(characterId, auth, orgId, lineId)` (signature corrected during this task's review to include an org-ownership check, matching `register`/`unregister`), `MdtLineService.register(characterId, auth, orgId, lineId, role)`, `MdtLineService.unregister(characterId, auth, orgId, lineId, role)`, `MdtLineService.resolveByNumber(number)`. Consumed by Task 6 (main.lua events) and Task 9 (`oblsk_phone`'s `DialerService`, cross-plugin global call).

- [ ] **Step 1: Write the failing tests**

Create `core/plugins/oblsk_mdt/tests/mdt_line_service_spec.lua`, following the exact structure of `tests/mdt_case_service_spec.lua` (its `test`/`eq` helpers, `setup()` dofiling against `tests/support/fake_query_builder.lua`, stubbed `Database`/`MdtAuditService`):

```lua
local scriptDir = arg[0]:match('(.*/)') or './'
local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

Database = { now = function() return '2026-08-15 00:00:00' end }

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local logged = {}
    MdtAuditService = { log = function(...) table.insert(logged, { ... }) end }
    dofile(scriptDir .. '../server/services/MdtLineService.lua')
    return tables, logged
end

test('create inserts a line row', function()
    local tables, logged = setup()
    local lineId = MdtLineService.create(1, 'lspd', 10, '911', '911 Emergency')
    eq(tables['mdt_lines'][1].organization_id, 10)
    eq(tables['mdt_lines'][1].number, '911')
    eq(#logged, 1)
    eq(lineId, tables['mdt_lines'][1].id)
end)

test('list only returns lines for the given org', function()
    local tables = setup()
    MdtLineService.create(1, 'lspd', 10, '911', 'A')
    MdtLineService.create(1, 'lsmd', 20, '912', 'B')
    local list = MdtLineService.list(10)
    eq(#list, 1)
    eq(list[1].number, '911')
end)

test('register sets a primary, then a different character can register as passive', function()
    local tables = setup()
    local lineId = MdtLineService.create(1, 'lspd', 10, '911', 'A')
    local ok1 = MdtLineService.register(2, 'lspd', 10, lineId, 'primary')
    local ok2 = MdtLineService.register(3, 'lspd', 10, lineId, 'passive')
    eq(ok1, true)
    eq(ok2, true)
    local regs = tables['mdt_line_registrations']
    eq(#regs, 2)
end)

test('register upserts - re-registering the same role replaces the prior holder', function()
    local tables = setup()
    local lineId = MdtLineService.create(1, 'lspd', 10, '911', 'A')
    MdtLineService.register(2, 'lspd', 10, lineId, 'primary')
    MdtLineService.register(3, 'lspd', 10, lineId, 'primary')
    local regs = tables['mdt_line_registrations']
    local primaries = 0
    for _, r in ipairs(regs) do if r.role == 'primary' then primaries = primaries + 1 end end
    eq(primaries, 1, 'only one primary row survives')
    eq(regs[#regs].character_id, 3)
end)

test('register refuses a line belonging to a different org', function()
    local tables = setup()
    local lineId = MdtLineService.create(1, 'lspd', 10, '911', 'A')
    local ok = MdtLineService.register(2, 'lsmd', 20, lineId, 'primary')
    eq(ok, false)
    eq(#tables['mdt_line_registrations'], 0)
end)

test('unregister removes the role holder', function()
    local tables = setup()
    local lineId = MdtLineService.create(1, 'lspd', 10, '911', 'A')
    MdtLineService.register(2, 'lspd', 10, lineId, 'primary')
    local ok = MdtLineService.unregister(2, 'lspd', 10, lineId, 'primary')
    eq(ok, true)
    eq(#tables['mdt_line_registrations'], 0)
end)

test('delete removes a line and its registrations', function()
    local tables = setup()
    local lineId = MdtLineService.create(1, 'lspd', 10, '911', 'A')
    MdtLineService.register(2, 'lspd', 10, lineId, 'primary')
    local ok = MdtLineService.delete(1, 'lspd', lineId)
    eq(ok, true)
    eq(#tables['mdt_lines'], 0)
    eq(#tables['mdt_line_registrations'], 0)
end)

test('resolveByNumber returns primary/passive character ids', function()
    local tables = setup()
    local lineId = MdtLineService.create(1, 'lspd', 10, '911', 'A')
    MdtLineService.register(2, 'lspd', 10, lineId, 'primary')
    MdtLineService.register(3, 'lspd', 10, lineId, 'passive')
    local resolved = MdtLineService.resolveByNumber('911')
    eq(resolved.lineId, lineId)
    eq(resolved.organizationId, 10)
    eq(resolved.primaryCharacterId, 2)
    eq(resolved.passiveCharacterId, 3)
end)

test('resolveByNumber returns nil for an unknown number', function()
    setup()
    local resolved = MdtLineService.resolveByNumber('555')
    eq(resolved, nil)
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd core/plugins/oblsk_mdt
lua tests/mdt_line_service_spec.lua
```

Expected: FAIL — `MdtLineService.lua` doesn't exist yet.

- [ ] **Step 3: Implement `MdtLineService`**

Create `core/plugins/oblsk_mdt/server/services/MdtLineService.lua`:

```lua
--- MdtLineService (server) - emergency-line registration and number
--- resolution. A line belongs to one org and has a globally-unique
--- number - the user has confirmed the same number will never be
--- configured for two different orgs, so resolveByNumber never needs to
--- resolve an ambiguous match. resolveByNumber is called cross-plugin by
--- oblsk_phone's DialerService as a plain global function call (no event
--- round-trip), the same reverse-direction precedent
--- MdtCommandService.activeCalls() previously established by calling
--- oblsk_phone's DispatchService.list() directly.
MdtLineService = {}

--- @param orgId number
--- @return table[]
function MdtLineService.list(orgId)
    local lines = QueryBuilder.new('mdt_lines'):where('organization_id', orgId):getSync()
    for _, line in ipairs(lines) do
        local regs = QueryBuilder.new('mdt_line_registrations'):where('line_id', line.id):getSync()
        for _, reg in ipairs(regs) do
            if reg.role == 'primary' then line.primary_character_id = reg.character_id end
            if reg.role == 'passive' then line.passive_character_id = reg.character_id end
        end
    end
    return lines
end

--- @param characterId number acting character
--- @param auth string
--- @param orgId number
--- @param number string
--- @param label string
--- @return number lineId
function MdtLineService.create(characterId, auth, orgId, number, label)
    local lineId = QueryBuilder.new('mdt_lines'):insert({
        organization_id = orgId, number = number, label = label,
    })
    MdtAuditService.log(characterId, auth, 'lines', 'created line ' .. tostring(number), tostring(lineId))
    return lineId
end

--- @param characterId number
--- @param auth string
--- @param lineId number
--- @return boolean true when deleted
function MdtLineService.delete(characterId, auth, lineId)
    QueryBuilder.new('mdt_line_registrations'):where('line_id', lineId):delete()
    QueryBuilder.new('mdt_lines'):where('id', lineId):delete()
    MdtAuditService.log(characterId, auth, 'lines', 'deleted line', tostring(lineId))
    return true
end

--- Registers the acting character as primary or passive on a line, upsert
--- by (line_id, role) - re-registering the same role replaces whoever
--- held it. Refuses (returns false) if the line doesn't belong to orgId.
--- @param characterId number
--- @param auth string
--- @param orgId number the acting character's organization
--- @param lineId number
--- @param role string 'primary'|'passive'
--- @return boolean
function MdtLineService.register(characterId, auth, orgId, lineId, role)
    local line = QueryBuilder.new('mdt_lines'):where('id', lineId):firstSync()
    if not line or line.organization_id ~= orgId then return false end

    QueryBuilder.new('mdt_line_registrations'):where('line_id', lineId):where('role', role):delete()
    QueryBuilder.new('mdt_line_registrations'):insert({
        line_id = lineId, character_id = characterId, role = role, registered_at = Database.now(),
    })
    MdtAuditService.log(characterId, auth, 'lines', 'registered as ' .. role .. ' on line ' .. tostring(lineId), tostring(lineId))
    return true
end

--- @param characterId number
--- @param auth string
--- @param orgId number
--- @param lineId number
--- @param role string 'primary'|'passive'
--- @return boolean
function MdtLineService.unregister(characterId, auth, orgId, lineId, role)
    local line = QueryBuilder.new('mdt_lines'):where('id', lineId):firstSync()
    if not line or line.organization_id ~= orgId then return false end

    QueryBuilder.new('mdt_line_registrations'):where('line_id', lineId):where('role', role):delete()
    MdtAuditService.log(characterId, auth, 'lines', 'unregistered as ' .. role .. ' from line ' .. tostring(lineId), tostring(lineId))
    return true
end

--- Cross-plugin entry point for oblsk_phone's DialerService. Not exposed
--- as an Obelisk.onServer event.
--- @param number string
--- @return table|nil { lineId, organizationId, primaryCharacterId, passiveCharacterId }
function MdtLineService.resolveByNumber(number)
    local line = QueryBuilder.new('mdt_lines'):where('number', number):firstSync()
    if not line then return nil end

    local resolved = { lineId = line.id, organizationId = line.organization_id }
    for _, reg in ipairs(QueryBuilder.new('mdt_line_registrations'):where('line_id', line.id):getSync()) do
        if reg.role == 'primary' then resolved.primaryCharacterId = reg.character_id end
        if reg.role == 'passive' then resolved.passiveCharacterId = reg.character_id end
    end
    return resolved
end

return MdtLineService
```

Note the test file's `register`/`unregister` calls above pass `(characterId, auth, orgId, lineId, role)` — 5 args for `register` and matching for `unregister`. Double check the test in Step 1 calls both with this exact 5-argument shape before running; the test file as written already matches this signature.

- [ ] **Step 4: Run tests to verify they pass**

```bash
lua tests/mdt_line_service_spec.lua
```

Expected: `All tests passed`.

- [ ] **Step 5: Commit**

```bash
git add server/services/MdtLineService.lua tests/mdt_line_service_spec.lua
git commit -m "mdt: add MdtLineService"
```

---

## Task 6: Lines server events

**Files:**
- Modify: `core/plugins/oblsk_mdt/server/main.lua`

**Interfaces:**
- Consumes: `MdtLineService.*` (Task 5).
- Produces: `oblsk_mdt:server:lines-list`, `lines-create`, `lines-delete`, `lines-register`, `lines-unregister` events. Consumed by Task 8 (Lines.vue).

- [ ] **Step 1: Add the five handlers**

Add after the `staff-set-vehicle` handler added in Task 3 (or anywhere among the other module handler blocks — follow the file's existing grouping-by-module convention):

```lua
Obelisk.onServer('oblsk_mdt:server:lines-list', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    if not resolved then return end
    local _, _, orgId = MdtAuthService.acting(resolved, data and data.auth)
    Obelisk.emitClient('oblsk_mdt:client:lines-list', source, MdtLineService.list(orgId))
end)

Obelisk.onServer('oblsk_mdt:server:lines-create', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    local character = resolved and Character:findSync(characterId)
    if not resolved or not character or not character:can('mdt-admin') then
        Obelisk.emitClient('oblsk_mdt:client:lines-create', source, { ok = false, error = 'forbidden' })
        return
    end
    data = data or {}
    local auth, _, orgId = MdtAuthService.acting(resolved, data.auth)
    local lineId = MdtLineService.create(characterId, auth, orgId, data.number, data.label)
    Obelisk.emitClient('oblsk_mdt:client:lines-create', source, { ok = true, lineId = lineId })
    Obelisk.emitClient('oblsk_mdt:client:lines-list', source, MdtLineService.list(orgId))
end)

Obelisk.onServer('oblsk_mdt:server:lines-delete', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    local character = resolved and Character:findSync(characterId)
    if not resolved or not character or not character:can('mdt-admin') then
        Obelisk.emitClient('oblsk_mdt:client:lines-delete', source, { ok = false, error = 'forbidden' })
        return
    end
    data = data or {}
    local auth, _, orgId = MdtAuthService.acting(resolved, data.auth)
    -- MdtLineService.delete's signature was corrected during Task 5's
    -- review to take orgId and enforce an ownership check (same pattern
    -- as register/unregister), matching this plugin's precedent
    -- (MdtDocTemplateService.delete also checks ownership despite also
    -- being mdt-admin-gated) — see the SDD ledger's Task 5 ruling.
    if not MdtLineService.delete(characterId, auth, orgId, data.lineId) then
        Obelisk.emitClient('oblsk_mdt:client:lines-delete', source, { ok = false, error = 'forbidden' })
        return
    end
    Obelisk.emitClient('oblsk_mdt:client:lines-delete', source, { ok = true })
    Obelisk.emitClient('oblsk_mdt:client:lines-list', source, MdtLineService.list(orgId))
end)

Obelisk.onServer('oblsk_mdt:server:lines-register', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    if not resolved then
        Obelisk.emitClient('oblsk_mdt:client:lines-register', source, { ok = false, error = 'forbidden' })
        return
    end
    data = data or {}
    local auth, _, orgId = MdtAuthService.acting(resolved, data.auth)
    if not MdtLineService.register(characterId, auth, orgId, data.lineId, data.role) then
        Obelisk.emitClient('oblsk_mdt:client:lines-register', source, { ok = false, error = 'forbidden' })
        return
    end
    Obelisk.emitClient('oblsk_mdt:client:lines-register', source, { ok = true })
    Obelisk.emitClient('oblsk_mdt:client:lines-list', source, MdtLineService.list(orgId))
end)

Obelisk.onServer('oblsk_mdt:server:lines-unregister', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    if not resolved then
        Obelisk.emitClient('oblsk_mdt:client:lines-unregister', source, { ok = false, error = 'forbidden' })
        return
    end
    data = data or {}
    local auth, _, orgId = MdtAuthService.acting(resolved, data.auth)
    if not MdtLineService.unregister(characterId, auth, orgId, data.lineId, data.role) then
        Obelisk.emitClient('oblsk_mdt:client:lines-unregister', source, { ok = false, error = 'forbidden' })
        return
    end
    Obelisk.emitClient('oblsk_mdt:client:lines-unregister', source, { ok = true })
    Obelisk.emitClient('oblsk_mdt:client:lines-list', source, MdtLineService.list(orgId))
end)
```

Note `register`/`unregister` are open to any resolved character (no `mdt-admin`/`mdt-write-*` gate) — registering yourself as primary/passive on your own org's line is an ordinary officer action, matching the spec. Only `lines-create`/`lines-delete` (line configuration) are `mdt-admin`-gated.

- [ ] **Step 2: Syntax-check**

```bash
cd core/plugins/oblsk_mdt
lua -e "assert(loadfile('server/main.lua'))" 2>&1 | head -5
```

Expected: no output (no syntax error).

- [ ] **Step 3: Commit**

```bash
git add server/main.lua
git commit -m "mdt: add lines-list/create/delete/register/unregister events"
```

---

## Task 7: Command.vue rewrite

**Files:**
- Modify: `core/plugins/oblsk_mdt/web/apps/Command/Command.vue`

**Interfaces:**
- Consumes: `oblsk_mdt:client:command-fleet` (unchanged, request `{auth}`), `oblsk_mdt:client:staff-list` (now carries `assigned_vehicle_id` per row, per Task 3), `oblsk_mdt:client:staff-set-vehicle` (Task 3, request `{auth, targetCharacterId, vehicleId}` → `{ok}`/`{ok:false,error}`).

- [ ] **Step 1: Rewrite the component**

Replace `core/plugins/oblsk_mdt/web/apps/Command/Command.vue` entirely. Read the existing file first for the established shared-kit import paths and toast pattern (`../../kit/{Pill,MdtPanel,MdtSearch}.vue`, local `toast` ref + `setTimeout(2400)`), then rewrite it as: a fleet panel (unchanged read from `command-fleet`) and an on-duty roster panel (`staff-list`, filtered client-side to `status === 'ON DUTY'`) where each on-duty row has a `<select>` of fleet vehicles (plus a "— none —" option) wired to `staff-set-vehicle`. Drop every reference to `command-assignments`/`command-assign`/`command-active-calls` and any CAD-board/call-list markup entirely — those events no longer exist server-side after Task 3.

```vue
<template>
  <div class="h-full flex gap-4 min-h-0 relative">
    <MdtPanel class="w-[320px] shrink-0" title="Fleet">
      <div class="overflow-y-auto ob-no-scroll h-full">
        <div v-for="v in fleet" :key="v.id" class="px-3.5 py-2.5 border-b border-white/6">
          <div class="text-[12.5px]">{{ v.name }}</div>
          <div class="ob-mono text-[9px] text-white/35">{{ v.unit_key }}<template v-if="v.note"> · {{ v.note }}</template></div>
        </div>
        <div v-if="!fleet.length" class="p-6 text-center text-[12px] text-white/30">No fleet vehicles configured.</div>
      </div>
    </MdtPanel>

    <MdtPanel class="flex-1 min-w-0" :title="`On duty · ${onDuty.length}`">
      <div class="overflow-y-auto ob-no-scroll h-full">
        <div v-for="s in onDuty" :key="s.character_id" class="px-3.5 py-2.5 border-b border-white/6 flex items-center gap-3">
          <div class="min-w-0 flex-1">
            <div class="text-[12.5px] truncate">{{ s.name }}</div>
            <div class="ob-mono text-[9px] text-white/35 truncate">{{ s.rank }}</div>
          </div>
          <select :value="s.assigned_vehicle_id || ''" @change="assignVehicle(s.character_id, $event.target.value)"
            class="h-8 rounded-lg bg-white/6 border border-white/10 px-2 text-[12px] text-white outline-none">
            <option value="">— no vehicle —</option>
            <option v-for="v in fleet" :key="v.id" :value="v.id" class="bg-[#0b0e10]">{{ v.name }}</option>
          </select>
        </div>
        <div v-if="!onDuty.length" class="p-6 text-center text-[12px] text-white/30">Nobody on duty.</div>
      </div>
    </MdtPanel>

    <div v-if="toast" class="absolute left-1/2 bottom-4 -translate-x-1/2 px-3.5 py-2 rounded-lg bg-black/85 border border-white/15 text-[12px] text-white shadow-lg z-[60]">
      {{ toast }}
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'
import MdtPanel from '../../kit/MdtPanel.vue'

const props = defineProps({ auth: String, dbGroup: String })

const fleet = ref([])
const staff = ref([])
const toast = ref('')
let toastTimer = null

const onDuty = computed(() => staff.value.filter(s => s.status === 'ON DUTY'))

function flash(msg) {
  toast.value = msg
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.value = '' }, 2400)
}

function refresh() {
  Obelisk.emit('oblsk_mdt:client:command-fleet', { auth: props.auth })
  Obelisk.emit('oblsk_mdt:client:staff-list', { auth: props.auth })
}

function assignVehicle(targetCharacterId, vehicleId) {
  Obelisk.emit('oblsk_mdt:client:staff-set-vehicle', {
    auth: props.auth,
    targetCharacterId,
    vehicleId: vehicleId ? Number(vehicleId) : null
  })
}

function handleFleet(data) { fleet.value = data || [] }
function handleStaffList(data) { staff.value = data || [] }
function handleSetVehicle(result) {
  if (!result?.ok) flash('Vehicle assignment failed — ' + (result?.error || 'unknown error'))
}

const EVENTS = {
  'oblsk_mdt:client:command-fleet': handleFleet,
  'oblsk_mdt:client:staff-list': handleStaffList,
  'oblsk_mdt:client:staff-set-vehicle': handleSetVehicle
}

onMounted(() => {
  for (const [event, handler] of Object.entries(EVENTS)) Obelisk.on(event, handler)
  refresh()
})
onBeforeUnmount(() => {
  for (const [event, handler] of Object.entries(EVENTS)) Obelisk.off(event, handler)
  if (toastTimer) clearTimeout(toastTimer)
})
</script>
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/andi/Projects/obelisk-framework
node -e "
const { parse, compileScript } = require('./core/node_modules/@vue/compiler-sfc');
const fs = require('fs');
const f = 'core/plugins/oblsk_mdt/web/apps/Command/Command.vue';
const src = fs.readFileSync(f, 'utf8');
const { descriptor, errors } = parse(src, { filename: f });
if (errors.length) { console.log(errors); process.exit(1); }
compileScript(descriptor, { id: f });
console.log('ok');
"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
cd core/plugins/oblsk_mdt
git add web/apps/Command/Command.vue
git commit -m "mdt: rewrite Command centre as fleet + on-duty vehicle assignment"
```

---

## Task 8: Lines.vue rewrite

**Files:**
- Modify: `core/plugins/oblsk_mdt/web/apps/Lines/Lines.vue`

**Interfaces:**
- Consumes: `oblsk_mdt:client:lines-list` (request `{auth}`, response array of `{id, organization_id, number, label, primary_character_id, passive_character_id}`), `lines-create`/`lines-delete` (admin, request `{auth, number, label}` / `{auth, lineId}`), `lines-register`/`lines-unregister` (request `{auth, lineId, role}`).

- [ ] **Step 1: Rewrite the component**

Replace `core/plugins/oblsk_mdt/web/apps/Lines/Lines.vue` entirely with a line list showing each line's current primary/passive (by character id — no name-resolution event exists for this, matching the "Officer #<id>" convention used elsewhere in this plugin, e.g. `Manhunts.vue`), register-as-primary/register-as-passive/unregister buttons, and an admin create/delete form (rendered unconditionally, `{ok:false,error:'forbidden'}` surfaced via toast — same pattern `Laws.vue`'s amend action and `Admin.vue`'s permission tab already use in this plugin, since there's no client-visible "am I admin" check available).

```vue
<template>
  <div class="h-full flex flex-col gap-3 min-h-0 relative">
    <div class="flex items-center justify-between shrink-0">
      <span class="ob-mono text-[9.5px] tracking-[0.2em] uppercase text-white/40">Emergency lines</span>
      <button @click="openDraft" class="px-2.5 h-8 rounded-md text-[11px] text-black font-medium" style="background: var(--ob-accent)">+ New line</button>
    </div>

    <div class="flex-1 min-h-0 overflow-y-auto ob-no-scroll space-y-2">
      <div v-for="l in lines" :key="l.id" class="rounded-xl border border-white/10 bg-black/40 p-3.5">
        <div class="flex items-center justify-between">
          <div>
            <div class="text-[13px] font-medium">{{ l.label }}</div>
            <div class="ob-mono text-[10px] text-white/35">{{ l.number }}</div>
          </div>
          <button @click="remove(l.id)" class="ob-mono text-[9px] px-1.5 h-[20px] rounded border border-white/14 text-red-300/70 hover:text-red-300 hover:bg-white/10 transition">DELETE</button>
        </div>
        <div class="grid grid-cols-2 gap-2 mt-2.5">
          <div class="rounded-lg border border-white/8 bg-white/[0.03] px-2.5 py-2">
            <div class="ob-mono text-[8.5px] text-white/30 uppercase">Primary</div>
            <div class="text-[12px] mt-0.5">{{ l.primary_character_id ? `Officer #${l.primary_character_id}` : '— unregistered —' }}</div>
            <button v-if="!l.primary_character_id" @click="register(l.id, 'primary')" class="ob-mono text-[9px] mt-1.5 px-2 h-6 rounded text-black" style="background: var(--ob-accent)">REGISTER</button>
            <button v-else @click="unregister(l.id, 'primary')" class="ob-mono text-[9px] mt-1.5 px-2 h-6 rounded border border-white/14 text-white/60 hover:text-white hover:bg-white/10 transition">UNREGISTER</button>
          </div>
          <div class="rounded-lg border border-white/8 bg-white/[0.03] px-2.5 py-2">
            <div class="ob-mono text-[8.5px] text-white/30 uppercase">Passive</div>
            <div class="text-[12px] mt-0.5">{{ l.passive_character_id ? `Officer #${l.passive_character_id}` : '— unregistered —' }}</div>
            <button v-if="!l.passive_character_id" @click="register(l.id, 'passive')" class="ob-mono text-[9px] mt-1.5 px-2 h-6 rounded text-black" style="background: var(--ob-accent)">REGISTER</button>
            <button v-else @click="unregister(l.id, 'passive')" class="ob-mono text-[9px] mt-1.5 px-2 h-6 rounded border border-white/14 text-white/60 hover:text-white hover:bg-white/10 transition">UNREGISTER</button>
          </div>
        </div>
      </div>
      <div v-if="!lines.length" class="p-6 text-center text-[12px] text-white/30">No lines configured.</div>
    </div>

    <MdtModal v-if="draft" title="New line" width="380" @close="draft = null">
      <div>
        <MdtLabel>Number</MdtLabel>
        <MdtInput v-model="draft.number" placeholder="e.g. 911" />
      </div>
      <div>
        <MdtLabel>Label</MdtLabel>
        <MdtInput v-model="draft.label" placeholder="e.g. 911 Emergency" />
      </div>
      <template #footer>
        <button @click="draft = null" class="px-3 h-8 rounded-md border border-white/12 hover:bg-white/8 text-[12px] transition">Cancel</button>
        <button @click="create" class="px-3.5 h-8 rounded-md text-black text-[12px] font-medium" style="background: var(--ob-accent)">Create</button>
      </template>
    </MdtModal>

    <div v-if="toast" class="absolute left-1/2 bottom-4 -translate-x-1/2 px-3.5 py-2 rounded-lg bg-black/85 border border-white/15 text-[12px] text-white shadow-lg z-[60]">
      {{ toast }}
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'
import MdtModal from '../../kit/MdtModal.vue'
import MdtLabel from '../../kit/MdtLabel.vue'
import MdtInput from '../../kit/MdtInput.vue'

const props = defineProps({ auth: String, dbGroup: String })

const lines = ref([])
const draft = ref(null)
const toast = ref('')
let toastTimer = null

function flash(msg) {
  toast.value = msg
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.value = '' }, 2400)
}

function refresh() { Obelisk.emit('oblsk_mdt:client:lines-list', { auth: props.auth }) }

function openDraft() { draft.value = { number: '', label: '' } }
function create() {
  if (!draft.value.number.trim() || !draft.value.label.trim()) { flash('Number and label are required'); return }
  Obelisk.emit('oblsk_mdt:client:lines-create', { auth: props.auth, number: draft.value.number.trim(), label: draft.value.label.trim() })
}
function remove(lineId) { Obelisk.emit('oblsk_mdt:client:lines-delete', { auth: props.auth, lineId }) }
function register(lineId, role) { Obelisk.emit('oblsk_mdt:client:lines-register', { auth: props.auth, lineId, role }) }
function unregister(lineId, role) { Obelisk.emit('oblsk_mdt:client:lines-unregister', { auth: props.auth, lineId, role }) }

function handleList(data) { lines.value = data || [] }
function handleCreate(result) {
  if (result?.ok) { draft.value = null; flash('Line created') }
  else flash('Create failed — ' + (result?.error || 'unknown error'))
}
function handleMutation(label) {
  return (result) => { if (!result?.ok) flash(`${label} failed — ` + (result?.error || 'unknown error')) }
}
const handleDelete = handleMutation('Delete')
const handleRegister = handleMutation('Register')
const handleUnregister = handleMutation('Unregister')

const EVENTS = {
  'oblsk_mdt:client:lines-list': handleList,
  'oblsk_mdt:client:lines-create': handleCreate,
  'oblsk_mdt:client:lines-delete': handleDelete,
  'oblsk_mdt:client:lines-register': handleRegister,
  'oblsk_mdt:client:lines-unregister': handleUnregister
}

onMounted(() => {
  for (const [event, handler] of Object.entries(EVENTS)) Obelisk.on(event, handler)
  refresh()
})
onBeforeUnmount(() => {
  for (const [event, handler] of Object.entries(EVENTS)) Obelisk.off(event, handler)
  if (toastTimer) clearTimeout(toastTimer)
})
</script>
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/andi/Projects/obelisk-framework
node -e "
const { parse, compileScript } = require('./core/node_modules/@vue/compiler-sfc');
const fs = require('fs');
const f = 'core/plugins/oblsk_mdt/web/apps/Lines/Lines.vue';
const src = fs.readFileSync(f, 'utf8');
const { descriptor, errors } = parse(src, { filename: f });
if (errors.length) { console.log(errors); process.exit(1); }
compileScript(descriptor, { id: f });
console.log('ok');
"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
cd core/plugins/oblsk_mdt
git add web/apps/Lines/Lines.vue
git commit -m "mdt: rewrite Lines as emergency-line registration"
```

---

## Task 9: `DialerService` line-routing + ring-timeout + failover

**Files:**
- Modify: `core/plugins/oblsk_phone/server/services/DialerService.lua`
- Test: `core/plugins/oblsk_phone/tests/dialer_service_spec.lua`

**Interfaces:**
- Consumes: `MdtLineService.resolveByNumber(number)` (Task 5, cross-plugin global), `PreferenceService.get('character', characterId, 'phone:flight_mode')` (existing, `oblsk_preferences`).
- Produces: `DialerService.call` gains a line-routing branch. New: `DialerService.isReachable(characterId)` (busy/flight-mode check, also consumed by Task 10's messages gate — actually Task 10 checks flight-mode directly via `PreferenceService`, not through this function; this function is call-routing-specific since it also checks `activeCalls`, keep it scoped to `DialerService`). New: `DialerService.RING_TIMEOUT_SECONDS` constant.

- [ ] **Step 1: Write the failing tests**

Read `core/plugins/oblsk_phone/tests/dialer_service_spec.lua` first for its exact stubbing style (how `CharacterService`, `PhoneNumberService`, `VoiceService` are currently faked) before writing these — match that style exactly, don't reinvent stubs for services already stubbed there. Add:

```lua
test('call falls back to a registered line when the number is not a personal number', function()
    local dialer = setup() -- however the existing spec's setup() returns/exposes DialerService
    PhoneNumberService.resolveCharacterId = function() return nil end
    MdtLineService = { resolveByNumber = function(n)
        if n == '911' then return { lineId = 1, organizationId = 10, primaryCharacterId = 5, passiveCharacterId = 6 } end
        return nil
    end }
    CharacterService.findSourceByCharacterId = function(id) if id == 5 then return 555 end if id == 6 then return 666 end return nil end
    PreferenceService = { get = function() return false end } -- nobody in flight mode
    local callId = DialerService.call(1, '911')
    assert(callId, 'expected a call to start')
    eq(DialerService.activeCalls[callId].calleeCharacterId, 5, 'rings the primary first')
end)

test('call skips straight to passive when primary is in flight mode', function()
    setup()
    PhoneNumberService.resolveCharacterId = function() return nil end
    MdtLineService = { resolveByNumber = function() return { lineId = 1, organizationId = 10, primaryCharacterId = 5, passiveCharacterId = 6 } end }
    CharacterService.findSourceByCharacterId = function(id) if id == 5 then return 555 end if id == 6 then return 666 end return nil end
    PreferenceService = { get = function(_, characterId) return characterId == 5 end } -- only character 5 (primary) is in flight mode
    local callId = DialerService.call(1, '911')
    assert(callId, 'expected a call to start')
    eq(DialerService.activeCalls[callId].calleeCharacterId, 6, 'rings the passive directly')
end)

test('call fails when both primary and passive are unreachable', function()
    setup()
    PhoneNumberService.resolveCharacterId = function() return nil end
    MdtLineService = { resolveByNumber = function() return { lineId = 1, organizationId = 10, primaryCharacterId = 5, passiveCharacterId = 6 } end }
    CharacterService.findSourceByCharacterId = function() return nil end -- nobody online
    PreferenceService = { get = function() return false end }
    local callId, err = DialerService.call(1, '911')
    eq(callId, nil)
    eq(err, 'not reachable')
end)

test('call fails with unknown number when neither a personal number nor a line matches', function()
    setup()
    PhoneNumberService.resolveCharacterId = function() return nil end
    MdtLineService = { resolveByNumber = function() return nil end }
    local callId, err = DialerService.call(1, '000')
    eq(callId, nil)
    eq(err, 'unknown number')
end)
```

Adjust these four tests' exact call to `setup()` and any pre-existing global stubs (`CharacterService.getActiveCharacterId`, etc.) to match whatever the existing spec file's `setup()` already provides — the snippets above show the NEW stubs specific to line routing, layered on top of whatever `setup()` already establishes for a normal personal-number call.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd core/plugins/oblsk_phone
lua tests/dialer_service_spec.lua
```

Expected: FAIL (line-routing branch doesn't exist yet).

- [ ] **Step 3: Implement**

Modify `core/plugins/oblsk_phone/server/services/DialerService.lua`. Replace the `DialerService.call` function:

```lua
DialerService.RING_TIMEOUT_SECONDS = 15

--- Reachability check used only for line-routing decisions: unreachable
--- means offline, already on a call, or in flight mode - any of these
--- means "don't bother ringing them, try the next person in the failover
--- chain" per the design.
--- @param characterId number
--- @return boolean
local function isReachable(characterId)
    local targetSource = CharacterService.findSourceByCharacterId(characterId)
    if not targetSource then return false end
    if PreferenceService.get('character', characterId, 'phone:flight_mode') then return false end
    for _, call in pairs(DialerService.activeCalls) do
        if call.calleeCharacterId == characterId or call.callerCharacterId == characterId then return false end
    end
    return true
end

local function startRinging(callerSource, callerCharacterId, callerNumber, calleeCharacterId, targetNumber)
    local calleeSource = CharacterService.findSourceByCharacterId(calleeCharacterId)
    if not calleeSource then return nil end

    local callId = nextCallId
    nextCallId = nextCallId + 1
    DialerService.activeCalls[callId] = {
        callerSource = callerSource,
        calleeSource = calleeSource,
        callerCharacterId = callerCharacterId,
        calleeCharacterId = calleeCharacterId,
        callerNumber = callerNumber,
        calleeNumber = targetNumber,
        startedAt = os.time(),
        answered = false,
    }
    return callId
end

--- Starts a call attempt. Fails immediately (no ringing, no recents entry)
--- if the dialled number doesn't resolve to a personal number OR a
--- registered oblsk_mdt line, or nobody reachable is found for it.
---
--- Line calls (a number that resolves via MdtLineService.resolveByNumber
--- rather than PhoneNumberService) get failover: the primary is rung
--- first unless already unreachable (offline/busy/flight-mode), in which
--- case the passive is rung directly; if the primary rings out
--- unanswered, `onLineCallTimeout` (registered by the caller of
--- `.call` in server/main.lua, see that file) is responsible for
--- retrying with the passive. This function itself only starts the
--- FIRST leg of a line call - the timeout-driven failover to the
--- passive is orchestrated by main.lua's dialer-call handler, which is
--- what schedules the timeout, since DialerService has no built-in
--- scheduler dependency today.
--- @param callerSource number
--- @param targetNumber string
--- @return number|nil callId, nil if the attempt failed
--- @return string|nil err set only when callId is nil
--- @return table|nil lineFailover set only for a line call that rang the primary: { lineId, passiveCharacterId, callerCharacterId, callerNumber, targetNumber } for main.lua to use if this leg times out
function DialerService.call(callerSource, targetNumber)
    local callerCharacterId = CharacterService.getActiveCharacterId(callerSource)
    if not callerCharacterId then
        return nil, 'no active character'
    end

    local calleeCharacterId = PhoneNumberService.resolveCharacterId(targetNumber)
    if calleeCharacterId then
        local calleeSource = CharacterService.findSourceByCharacterId(calleeCharacterId)
        if not calleeSource then
            return nil, 'not reachable'
        end
        local callerNumber = PhoneNumberService.ensureNumber(callerCharacterId)
        local callId = startRinging(callerSource, callerCharacterId, callerNumber, calleeCharacterId, targetNumber)
        return callId
    end

    local line = MdtLineService.resolveByNumber(targetNumber)
    if not line then
        return nil, 'unknown number'
    end

    local callerNumber = PhoneNumberService.ensureNumber(callerCharacterId)
    local primary = line.primaryCharacterId
    local passive = line.passiveCharacterId

    if primary and isReachable(primary) then
        local callId = startRinging(callerSource, callerCharacterId, callerNumber, primary, targetNumber)
        if callId then
            return callId, nil, { lineId = line.lineId, passiveCharacterId = passive, callerCharacterId = callerCharacterId, callerNumber = callerNumber, targetNumber = targetNumber }
        end
    end

    if passive and isReachable(passive) then
        local callId = startRinging(callerSource, callerCharacterId, callerNumber, passive, targetNumber)
        return callId
    end

    return nil, 'not reachable'
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
lua tests/dialer_service_spec.lua
```

Expected: `All tests passed`. Also confirm the pre-existing tests in this file (personal-number call path) still pass unmodified — the `PhoneNumberService.resolveCharacterId` branch above is unchanged behavior, just refactored to share `startRinging`.

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_phone
git add server/services/DialerService.lua tests/dialer_service_spec.lua
git commit -m "phone: DialerService line-call resolution and failover-primary-check"
```

---

## Task 10: Wire the ring-timeout in `main.lua`'s `dialer-call` handler

**Files:**
- Modify: `core/plugins/oblsk_phone/server/main.lua`

**Interfaces:**
- Consumes: `DialerService.call` (Task 9, now returns a third `lineFailover` value for a line call that rang the primary), `DialerService.RING_TIMEOUT_SECONDS`, `DialerService.hangup`.

This is the piece that actually schedules the timeout and, on expiry, rings the passive using the exact same `dialer-ringing`/`dialer-incoming` events the primary leg used — from the caller's phone's perspective, an un-answered primary leg just silently gives way to a second incoming-call sequence for the passive, or a `dialer-call-failed` if there's no passive.

- [ ] **Step 1: Add `DialerService.ringPassive`**

`main.lua`'s timeout callback needs to start a second call leg (the passive) without allocating a call id itself (call-id allocation is `DialerService`'s private concern, via its internal `nextCallId` counter). Add this to `core/plugins/oblsk_phone/server/services/DialerService.lua`, after the `DialerService.call` function added in Task 9 (it can see `isReachable`/`startRinging` since they're local functions defined earlier in the same file):

```lua
--- Rings the passive leg of a line call after the primary timed out.
--- Wraps startRinging with the same "not reachable" outcome DialerService
--- normally returns from .call, for main.lua's timeout callback to reuse
--- rather than duplicating call-id allocation itself.
--- @param callerSource number
--- @param callerCharacterId number
--- @param callerNumber string
--- @param passiveCharacterId number
--- @param targetNumber string
--- @return number|nil callId, nil if the passive isn't reachable either
function DialerService.ringPassive(callerSource, callerCharacterId, callerNumber, passiveCharacterId, targetNumber)
    if not isReachable(passiveCharacterId) then return nil end
    return startRinging(callerSource, callerCharacterId, callerNumber, passiveCharacterId, targetNumber)
end
```

- [ ] **Step 2: Replace the `dialer-call` handler in `main.lua`**

```lua
Obelisk.onServer('oblsk_phone:server:dialer-call', function(targetNumber)
    local source = source
    if type(targetNumber) ~= 'string' then
        return
    end

    local callId, err, lineFailover = DialerService.call(source, targetNumber)
    if not callId then
        Obelisk.emitClient('oblsk_phone:client:dialer-call-failed', source, err)
        return
    end

    local call = DialerService.activeCalls[callId]
    Obelisk.emitClient('oblsk_phone:client:dialer-ringing', call.callerSource, callId, call.calleeNumber)
    Obelisk.emitClient('oblsk_phone:client:dialer-incoming', call.calleeSource, callId, call.callerNumber)

    if lineFailover then
        SetTimeout(DialerService.RING_TIMEOUT_SECONDS * 1000, function()
            local stillRinging = DialerService.activeCalls[callId]
            if not stillRinging or stillRinging.answered then return end

            DialerService.hangup(callId, stillRinging.callerSource)
            Obelisk.emitClient('oblsk_phone:client:dialer-ended', stillRinging.callerSource, callId, 'no answer')
            Obelisk.emitClient('oblsk_phone:client:dialer-ended', stillRinging.calleeSource, callId, 'no answer')

            if not lineFailover.passiveCharacterId then
                Obelisk.emitClient('oblsk_phone:client:dialer-call-failed', source, 'not reachable')
                return
            end

            local passiveCallId = DialerService.ringPassive(
                source, lineFailover.callerCharacterId, lineFailover.callerNumber,
                lineFailover.passiveCharacterId, lineFailover.targetNumber)
            if not passiveCallId then
                Obelisk.emitClient('oblsk_phone:client:dialer-call-failed', source, 'not reachable')
                return
            end

            local passiveCall = DialerService.activeCalls[passiveCallId]
            Obelisk.emitClient('oblsk_phone:client:dialer-ringing', passiveCall.callerSource, passiveCallId, passiveCall.calleeNumber)
            Obelisk.emitClient('oblsk_phone:client:dialer-incoming', passiveCall.calleeSource, passiveCallId, passiveCall.callerNumber)
        end)
    end
end)
```

- [ ] **Step 3: Syntax-check**

```bash
cd core/plugins/oblsk_phone
lua -e "assert(loadfile('server/main.lua'))" 2>&1 | head -5
lua -e "assert(loadfile('server/services/DialerService.lua'))" 2>&1 | head -5
```

Expected: no output.

- [ ] **Step 4: Run the full dialer spec again**

```bash
lua tests/dialer_service_spec.lua
```

Expected: `All tests passed` (this handler-level timeout wiring isn't itself unit-testable with this plugin's plain-Lua spec style since it depends on FXServer's real `SetTimeout` — that's expected; the service-level failover logic Task 9 tests is where the real coverage lives. Note this gap explicitly rather than trying to fake `SetTimeout` in a spec.)

- [ ] **Step 5: Commit**

```bash
git add server/main.lua server/services/DialerService.lua
git commit -m "phone: wire ring-timeout failover-to-passive for line calls"
```

---

## Task 11: Flight-mode gate on Messages push

**Files:**
- Modify: `core/plugins/oblsk_phone/server/main.lua`

**Interfaces:**
- Consumes: `PreferenceService.get('character', characterId, 'phone:flight_mode')`.

- [ ] **Step 1: Update the `messages-send` handler**

Find the handler (search for `oblsk_phone:server:messages-send`). Replace the per-recipient loop:

```lua
Obelisk.onServer('oblsk_phone:server:messages-send', function(threadId, body)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or type(threadId) ~= 'number' or type(body) ~= 'string' then
        return
    end

    local message = MessagesService.send(characterId, threadId, body)
    if not message then
        return
    end

    Obelisk.emitClient('oblsk_phone:client:messages-new', source, threadId, message)
    Obelisk.emitClient('oblsk_phone:client:messages-threads', source, MessagesService.threads(characterId), characterId)

    for _, otherCharacterId in ipairs(MessagesService.otherMembers(characterId, threadId)) do
        -- The message is always stored (MessagesService.send already ran
        -- above, unconditionally) so it's there next time this recipient
        -- opens Messages - flight mode only defers the LIVE push, matching
        -- real airplane-mode semantics, it doesn't drop the message.
        if not PreferenceService.get('character', otherCharacterId, 'phone:flight_mode') then
            local otherSource = CharacterService.findSourceByCharacterId(otherCharacterId)
            if otherSource then
                Obelisk.emitClient('oblsk_phone:client:messages-new', otherSource, threadId, message)
                Obelisk.emitClient('oblsk_phone:client:messages-threads', otherSource, MessagesService.threads(otherCharacterId), otherCharacterId)
            end
        end
    end
end)
```

Note the sender's own two pushes (the two `Obelisk.emitClient(..., source, ...)` lines right after `MessagesService.send`) are deliberately NOT flight-mode-gated — a character in flight mode can still send (they typed and hit send, that's a local action, not something being delivered to them), only the OTHER recipients' delivery is gated. This matches the spec precisely: flight mode gates reachability of that character by others.

- [ ] **Step 2: Syntax-check**

```bash
cd core/plugins/oblsk_phone
lua -e "assert(loadfile('server/main.lua'))" 2>&1 | head -5
```

Expected: no output.

- [ ] **Step 3: Extend the messages send test coverage**

Find whichever spec file already covers the `messages-send` flow (check `tests/` for `messages_service_spec.lua` or a `main.lua`-handler-level spec — if the handler itself isn't unit-tested anywhere today because `Obelisk.onServer` registration isn't exercised by this plugin's plain-Lua specs, note that explicitly rather than inventing a new test harness pattern this plugin doesn't already use elsewhere; if `MessagesService.send`/`otherMembers` ARE covered, no change needed there since this task only touches the handler's push-gating, not `MessagesService` itself).

- [ ] **Step 4: Commit**

```bash
git add server/main.lua
git commit -m "phone: skip live message push to flight-mode recipients"
```

---

## Task 12: Shared `phonePreferences.js` store

**Files:**
- Create: `core/plugins/oblsk_phone/web/phone/phonePreferences.js`

**Interfaces:**
- Produces: `phonePrefs` (a Vue `reactive` object keyed by preference key, e.g. `phonePrefs['phone:flight_mode']`), `hydratePhonePrefs()`, `setPhonePref(key, value)`. Consumed by Task 13 (`Phone.vue`) and Task 14 (`Settings.vue`).

- [ ] **Step 1: Write the module**

```js
// Single source of truth for phone-shell preference toggles that more than
// one component needs to read/write the SAME live value within a session
// (flight mode, DND). oblsk_preferences' own `:set` event is fire-and-forget
// (it does not re-broadcast a hydrate after writing), so two components each
// independently hydrating their own local copy would drift out of sync
// whenever one writes and the other doesn't re-request. This module is
// imported by both Phone.vue and Settings.vue instead of each keeping its
// own local ref, so a write from either one is visible to both immediately,
// with server persistence still going through the normal
// oblsk_preferences:client:set/:request cycle underneath.
import { reactive } from 'vue'
import Obelisk from '@/obelisk.js'

export const phonePrefs = reactive({
  'phone:flight_mode': false,
  'phone:dnd': false
})

const KEYS = Object.keys(phonePrefs)

export function hydratePhonePrefs() {
  Obelisk.emit('oblsk_preferences:client:request', { keys: KEYS })
}

export function setPhonePref(key, value) {
  phonePrefs[key] = value
  Obelisk.emit('oblsk_preferences:client:set', { scope: 'character', key, value })
}

function handleHydrate(merged) {
  if (!merged) return
  for (const key of KEYS) {
    if (merged[key] !== undefined) phonePrefs[key] = Boolean(merged[key])
  }
}

Obelisk.on('oblsk_preferences:client:hydrate', handleHydrate)
```

Note this registers its `Obelisk.on` listener once at module load (not inside a component's `onMounted`) since it's a singleton store meant to live for the whole phone session, not tied to any one component's lifecycle — this is a deliberate deviation from the per-component `onMounted`/`onBeforeUnmount` pattern every other Vue file in this port uses, because this file isn't a component.

- [ ] **Step 2: Commit**

```bash
cd core/plugins/oblsk_phone
git add web/phone/phonePreferences.js
git commit -m "phone: add shared phonePreferences store for flight-mode/DND"
```

---

## Task 13: Wire `Phone.vue` to `phonePreferences.js`

**Files:**
- Modify: `core/plugins/oblsk_phone/web/Phone.vue`

**Interfaces:**
- Consumes: `phonePrefs`, `hydratePhonePrefs`, `setPhonePref` (Task 12).

- [ ] **Step 1: Replace the local `flight`/`dnd` refs**

Around line 491/493 (re-locate by searching for `const flight = ref(false)` — other tasks may have shifted exact line numbers), remove:

```js
const flight = ref(false)
const dnd = ref(false)
```

Add the import near the top of the `<script setup>` block (alongside this file's other imports) and hydrate on mount:

```js
import { phonePrefs, hydratePhonePrefs, setPhonePref } from './phone/phonePreferences.js'
```

Find this file's existing `onMounted` hook (there should be exactly one at the top-level of the component) and add a call to `hydratePhonePrefs()` inside it.

- [ ] **Step 2: Update every read/write site**

Every remaining reference to `flight.value`/`dnd.value` in this file (the `:flight`/`:dnd` props passed to a child around line 69/71, the `v-if="dnd"`/`v-if="flight"` badges around line 275/276, the `quickSettings` computed around line 519-521, and the `notify()` function's `flight.value`/`dnd.value` checks around line 669/674/677/685) becomes `phonePrefs['phone:flight_mode']`/`phonePrefs['phone:dnd']`. For the two toggle callbacks in `quickSettings` (currently `toggle: () => (flight.value = !flight.value)` and the `dnd` equivalent), replace with:

```js
toggle: () => setPhonePref('phone:flight_mode', !phonePrefs['phone:flight_mode'])
```

and the equivalent for `phone:dnd`.

- [ ] **Step 3: Verify it compiles**

```bash
cd /home/andi/Projects/obelisk-framework
node -e "
const { parse, compileScript } = require('./core/node_modules/@vue/compiler-sfc');
const fs = require('fs');
const f = 'core/plugins/oblsk_phone/web/Phone.vue';
const src = fs.readFileSync(f, 'utf8');
const { descriptor, errors } = parse(src, { filename: f });
if (errors.length) { console.log(errors); process.exit(1); }
compileScript(descriptor, { id: f });
console.log('ok');
"
```

Expected: `ok`. If it fails with "flight is not defined" or similar, you missed a read/write site from Step 2 above — search the whole file for `flight.value`/`dnd.value` again (`grep -n "flight\.value\|dnd\.value"`) and confirm zero remain.

- [ ] **Step 4: Commit**

```bash
cd core/plugins/oblsk_phone
git add web/Phone.vue
git commit -m "phone: wire Phone.vue flight/dnd to the shared preference store"
```

---

## Task 14: Wire `Settings.vue` to `phonePreferences.js`

**Files:**
- Modify: `core/plugins/oblsk_phone/web/apps/Settings/Settings.vue`

**Interfaces:**
- Consumes: `phonePrefs`, `hydratePhonePrefs`, `setPhonePref` (Task 12).

- [ ] **Step 1: Split flight/dnd out of the generic `rows`/`state` loop**

This file currently manages three keys (`phone:flight_mode`, `phone:hide_number`, `phone:dnd`) identically through a local `reactive` `state` object and its own hydrate/set cycle. `phone:hide_number` isn't part of this design (no other component needs to read it live) and stays exactly as-is, local to this file. `phone:flight_mode`/`phone:dnd` move to the shared store.

Replace the file's `<script setup>` block:

```js
import { onBeforeUnmount, onMounted, reactive } from 'vue'
import Obelisk from '@/obelisk.js'
import Icon from '../../phone/Icon.vue'
import { phonePrefs, hydratePhonePrefs, setPhonePref } from '../../phone/phonePreferences.js'

const SHARED_KEYS = ['phone:flight_mode', 'phone:dnd']

const rows = [
  { key: 'phone:flight_mode', label: 'Airplane mode', icon: 'plane', sub: 'Disable calls, texts and data' },
  { key: 'phone:hide_number', label: 'Hide my number', icon: 'contact', sub: 'Withhold caller ID on outgoing calls' },
  { key: 'phone:dnd', label: 'Do not disturb', icon: 'bell', sub: 'Silence notification banners' }
]

// phone:hide_number stays local to this file - nothing else reads it live.
const localState = reactive({ 'phone:hide_number': false })

function currentValue(key) {
  return SHARED_KEYS.includes(key) ? phonePrefs[key] : localState[key]
}

function handleHydrate(merged) {
  if (!merged) return
  if (merged['phone:hide_number'] !== undefined) localState['phone:hide_number'] = Boolean(merged['phone:hide_number'])
}

function requestHydration() {
  Obelisk.emit('oblsk_preferences:client:request', { keys: ['phone:hide_number'] })
  hydratePhonePrefs()
}

function toggle(row) {
  const value = !currentValue(row.key)
  if (SHARED_KEYS.includes(row.key)) {
    setPhonePref(row.key, value)
  } else {
    localState[row.key] = value
    Obelisk.emit('oblsk_preferences:client:set', { scope: 'character', key: row.key, value })
  }
}

onMounted(() => {
  Obelisk.on('oblsk_preferences:client:hydrate', handleHydrate)
  requestHydration()
})

onBeforeUnmount(() => {
  Obelisk.off('oblsk_preferences:client:hydrate', handleHydrate)
})
```

- [ ] **Step 2: Update the template's `state[row.key]` references**

The template currently reads `state[row.key]` in two places (the toggle-switch background/thumb-position bindings). Replace both `state[row.key]` with `currentValue(row.key)`.

- [ ] **Step 3: Verify it compiles**

```bash
cd /home/andi/Projects/obelisk-framework
node -e "
const { parse, compileScript } = require('./core/node_modules/@vue/compiler-sfc');
const fs = require('fs');
const f = 'core/plugins/oblsk_phone/web/apps/Settings/Settings.vue';
const src = fs.readFileSync(f, 'utf8');
const { descriptor, errors } = parse(src, { filename: f });
if (errors.length) { console.log(errors); process.exit(1); }
compileScript(descriptor, { id: f });
console.log('ok');
"
```

Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
cd core/plugins/oblsk_phone
git add web/apps/Settings/Settings.vue
git commit -m "phone: wire Settings.vue flight/dnd to the shared preference store"
```

---

## Task 15: MDT "no signal" gate on flight mode

**Files:**
- Modify: `core/plugins/oblsk_mdt/web/Mdt.vue`

**Interfaces:**
- Consumes: `phonePrefs` from `oblsk_phone`'s `web/phone/phonePreferences.js` — cross-plugin frontend import, same convention this framework already uses for shared Vue building blocks between plugins registered into the same Phone shell (confirm the exact import path/alias this monorepo's Vite config uses for cross-plugin imports — check how any other `oblsk_mdt` file already imports something from `oblsk_phone`, or how `oblsk_phone` apps import shared `core/web` components, before guessing the path; if no cross-plugin frontend import precedent exists anywhere in this codebase, that's a real blocker for this task — stop and flag it rather than inventing a broken import path).

- [ ] **Step 1: Investigate the cross-plugin frontend import path**

```bash
grep -rn "from '\.\./\.\./\.\./oblsk_" core/plugins/*/web/ 2>/dev/null | head -10
grep -rn "phoneApps.js" core/plugins/oblsk_phone/web/Phone.vue
```

The second command shows how `Phone.vue` discovers `oblsk_mdt`'s `phoneApps.js` (`import.meta.glob('../../*/web/phoneApps.js', { eager: true })` per the original MDT plugin design doc) — that's a glob-based sibling-plugin-directory convention already established, meaning `core/plugins/oblsk_mdt/web/*` and `core/plugins/oblsk_phone/web/*` are siblings under a shared `core/plugins/*/web/` root the bundler resolves relative paths across. If that's confirmed, the import in `Mdt.vue` is:

```js
import { phonePrefs } from '../oblsk_phone/web/phone/phonePreferences.js'
```

Verify this resolves by checking whether any existing file already does a relative `../oblsk_<other>/web/...` import; if the actual working convention differs (e.g. an alias like `@phone/...`), use that instead — don't guess blindly, confirm via an existing precedent in this codebase first.

- [ ] **Step 2: Add the gate**

In `core/plugins/oblsk_mdt/web/Mdt.vue`, wrap the existing top-level template content (everything currently inside the `v-else` branch that renders the sidebar+main shell once `resolved` is truthy) with an additional check: when `phonePrefs['phone:flight_mode']` is true, render a "No signal" placeholder instead. Read the current top of `Mdt.vue`'s `<template>` first (it already has a `v-if="!resolved"` / `v-else` split) and add flight mode as a third branch:

```vue
<div v-if="!resolved" class="w-full h-full flex items-center justify-center text-white/40 text-[12px]"
  style="background: linear-gradient(160deg, rgba(7,9,10,.92), rgba(7,9,10,.97)); color: #fff;">
  No MDT access for this character.
</div>
<div v-else-if="flightMode" class="w-full h-full flex flex-col items-center justify-center gap-2 text-white/40 text-[12px]"
  style="background: linear-gradient(160deg, rgba(7,9,10,.92), rgba(7,9,10,.97)); color: #fff;">
  <Icon name="alert" :size="20" class="text-white/25" />
  No signal — disable flight mode to use the terminal.
</div>
<div v-else class="absolute inset-0 flex text-[13px]" ...>
  <!-- existing shell content, unchanged -->
</div>
```

In the `<script setup>` block, add:

```js
import { phonePrefs } from '../../oblsk_phone/web/phone/phonePreferences.js'
```

(adjust the relative path per what Step 1 confirmed) and a computed:

```js
const flightMode = computed(() => phonePrefs['phone:flight_mode'])
```

`computed` must already be imported from `'vue'` in this file (it is, per the existing `Mdt.vue` code from earlier in this port) — no new Vue import needed.

- [ ] **Step 3: Verify it compiles**

```bash
cd /home/andi/Projects/obelisk-framework
node -e "
const { parse, compileScript } = require('./core/node_modules/@vue/compiler-sfc');
const fs = require('fs');
const f = 'core/plugins/oblsk_mdt/web/Mdt.vue';
const src = fs.readFileSync(f, 'utf8');
const { descriptor, errors } = parse(src, { filename: f });
if (errors.length) { console.log(errors); process.exit(1); }
compileScript(descriptor, { id: f });
console.log('ok');
"
```

Expected: `ok`. A compile-time pass here does NOT prove the cross-plugin import path resolves at bundle/runtime (that requires this monorepo's actual build, which this plan's verification steps elsewhere in this port have consistently NOT run — same limitation applies here, note it rather than claiming more than was verified).

- [ ] **Step 4: Commit**

```bash
cd core/plugins/oblsk_mdt
git add web/Mdt.vue
git commit -m "mdt: show a no-signal placeholder while flight mode is on"
```

---

## Final verification (run after all 15 tasks)

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_mdt
for f in tests/mdt_*_spec.lua; do echo "== $f =="; lua "$f" 2>&1 | tail -3; done

cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_phone
for f in tests/*_spec.lua; do echo "== $f =="; lua "$f" 2>&1 | tail -3; done

cd /home/andi/Projects/obelisk-framework
node -e "
const { parse, compileScript } = require('./core/node_modules/@vue/compiler-sfc');
const fs = require('fs');
const files = require('child_process').execSync(\"find core/plugins/oblsk_mdt/web core/plugins/oblsk_phone/web -name '*.vue'\", {encoding:'utf8'}).trim().split('\n');
let fail = 0, ok = 0;
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  const { descriptor, errors } = parse(src, { filename: f });
  if (errors.length) { console.log('PARSE ERR', f, errors); fail++; continue; }
  if (!descriptor.scriptSetup && !descriptor.script) { ok++; continue; }
  try { compileScript(descriptor, { id: f }); ok++; } catch (e) { console.log('SCRIPT ERR', f, e.message); fail++; }
}
console.log(ok + ' ok, ' + fail + ' failed, ' + files.length + ' total');
"
```

Expected: every Lua spec prints `All tests passed` (pre-existing unrelated `Settings`-stub failures in specs this plan didn't touch — `mdt_impound_service_spec.lua`, `mdt_law_service_spec.lua`, `mdt_manhunt_service_spec.lua` — are a known, already-documented issue from before this plan, not a regression to chase here); the Vue compile sweep reports 0 failures.
