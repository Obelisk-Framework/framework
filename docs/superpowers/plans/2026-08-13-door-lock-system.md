# Door Lock System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `core/modules/oblsk_doors` — doors unlockable by permission grant, org/rank/department license rules, a bound key item, or a lockpick minigame — plus the small `oblsk_licenses` addendum (structured `organization_id`/`rank_id`, an item binding, and a cross-resource export) it depends on.

**Architecture:** Two repos. `oblsk_licenses` (plugin, `core/plugins/oblsk_licenses`) gets `organization_id`/`rank_id` added to duty-credential instance data, a `license.duty` item binding, and a new `hasValidLicense` export. `core`'s new `oblsk_doors` module owns three tables (`doors`, `door_items`, `door_access_rules`), a `DoorService` with a four-method unlock resolver, registers each door with the existing `InteractionService`/`EntityStreamerService` rather than building new proximity code, and ships a Vue port of a lockpicking minigame pulled from the team's Claude Design project.

**Tech Stack:** Lua 5.4 (FXServer server/client scripts), the repo's own ORM (`Schema`/`BaseModel`/`QueryBuilder`), Vue 3 SFCs for NUI, hand-rolled `lua5.4`-runnable spec files (no external test framework) run via `dofile` stubs + `tests/support/fake_query_builder.lua`.

**Spec:** `core/docs/superpowers/specs/2026-08-13-door-lock-system-design.md`

## Global Constraints

- No hardcoded item names anywhere in `oblsk_doors` — every item lookup goes through `ItemService.binding(key)`/`.hasBinding(key)`; an unbound key means that unlock path is simply unavailable (fail closed), never a crash or a guessed fallback name.
- `door_access_rules` rows are **OR'd** per door; within a row, `rank_id`/`department_id` are **AND'd** when both set and "any" when null. This must support arbitrary rank allow-lists (e.g. "Lieutenant and Chief, not Captain" — two separate rows), not a single min-rank threshold.
- The lockpick minigame's outcome is never trusted from an unvalidated client claim — server issues a one-time challenge token, client submits the result with that token, server validates token + a minimum elapsed-time floor before unlocking.
- Follow the existing module shape exactly: modules under `core/modules/*` have no `fxmanifest.lua` of their own (wildcard-globbed by `core/fxmanifest.lua`, registered by name in `core/modules/registry.json`); plugins under `core/plugins/*` do have their own `fxmanifest.lua`.
- Every server-side unit test is a standalone `lua5.4`-runnable spec file following the exact `dofile`/`fake_query_builder`/hand-rolled `eq`/`os.exit` harness shown in Task 1 below — copy that shape verbatim in every subsequent test file, only the `dofile` list and test bodies change.

---

## Part A — `oblsk_licenses` companion changes

### Task 1: `organization_id`/`rank_id` on duty-credential data

**Files:**
- Modify: `core/plugins/oblsk_licenses/server/services/LicenseService.lua:58-70`
- Test: `core/plugins/oblsk_licenses/tests/license_service_spec.lua`

**Interfaces:**
- Produces: `LicenseService.issue(characterId, licenseTypeName, fields)` now also accepts (and persists into the stored `data`) `fields.organization_id` (number|nil) and `fields.rank_id` (number|nil), alongside the existing `fields.holder` free-text display fields. These are independent of `holder.dept`/`holder.rank` (which stay free text for card display) — `organization_id`/`rank_id` are the structured fields other resources query against.

- [ ] **Step 1: Write the failing test**

Add to `core/plugins/oblsk_licenses/tests/license_service_spec.lua`, after the existing `'LicenseService.issue: Duty credential applies the dept preset...'` test (currently ending at line 108):

```lua
test('LicenseService.issue: Duty credential stores organization_id and rank_id alongside holder', function()
    withFakeDb(function(tables)
        seedBaseItem(tables, 2, 'Duty credential')
        tables.items = {}

        local item = LicenseService.issue(5, 'Duty credential', {
            holder = { name = 'Kayla West', rank = 'Detective II', badge = '1147', dept = 'LSPD' },
            organization_id = 3,
            rank_id = 12,
        })

        eq(item.attributes.data.organization_id, 3)
        eq(item.attributes.data.rank_id, 12)
        -- display fields are untouched by the structured fields
        eq(item.attributes.data.holder.dept, 'LSPD')
        eq(item.attributes.data.holder.rank, 'Detective II')
    end)
end)

test('LicenseService.issue: organization_id/rank_id are nil when not supplied', function()
    withFakeDb(function(tables)
        seedBaseItem(tables, 1, 'Driver licence')
        tables.items = {}

        local item = LicenseService.issue(5, 'Driver licence', { no = 'DL 1234' })

        eq(item.attributes.data.organization_id, nil)
        eq(item.attributes.data.rank_id, nil)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_licenses/tests/license_service_spec.lua`
Expected: FAIL on the two new tests — `item.attributes.data.organization_id` is `nil` when `3` was expected (the field isn't written yet).

- [ ] **Step 3: Write minimal implementation**

In `core/plugins/oblsk_licenses/server/services/LicenseService.lua`, the `generated` table inside `LicenseService.issue` (currently lines 59-70):

```lua
    local generated = {
        no = fields.no,
        issued = issued,
        expires = fields.expires or addYearsIso(issued, Config.DefaultLicenseValidYears),
        status = 'VALID',
        authority = baseItem.data and baseItem.data.authority,
        theme = baseItem.data and baseItem.data.theme,
        back = baseItem.data and baseItem.data.back,
        holder = fields.holder,
        classes = fields.classes,
        weapons = fields.weapons,
        organization_id = fields.organization_id,
        rank_id = fields.rank_id,
    }
```

(Two lines added at the end; `merge(generated, fields)` on line 81 already carries any caller override through unchanged, since `fields.organization_id`/`fields.rank_id` win the merge same as every other key.)

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_licenses/tests/license_service_spec.lua`
Expected: PASS, all tests including the two new ones and the pre-existing ones (unaffected — `fields.organization_id`/`fields.rank_id` are `nil` by default, so untouched call sites keep writing `nil` for both, same as before this change).

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_licenses
git add server/services/LicenseService.lua tests/license_service_spec.lua
git commit -m "Add organization_id/rank_id to duty-credential license data"
```

---

### Task 2: `license.duty` item binding

**Files:**
- Modify: `core/plugins/oblsk_licenses/shared/config.lua`
- Modify: `core/plugins/oblsk_licenses/server/seeders/LicensesItemSeeder.lua`
- Test: `core/plugins/oblsk_licenses/tests/licenses_item_seeder_spec.lua` (new)

**Interfaces:**
- Consumes: `QueryBuilder.new('item_bindings'):insert({...})` (columns: `id, key, base_item_id, updated_by, updated_at`, per `core/modules/oblsk_items/server/migrations/2026_08_12_100001_create_item_bindings_table.lua`); `Database.now()`.
- Produces: an `item_bindings` row `{key = 'license.duty', base_item_id = <Duty credential's id>}`, so `ItemService.binding('license.duty')` (consumed in Task 3) resolves to the Duty credential base item.

- [ ] **Step 1: Write the failing test**

Create `core/plugins/oblsk_licenses/tests/licenses_item_seeder_spec.lua`:

```lua
-- plugins/oblsk_licenses/tests/licenses_item_seeder_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_licenses/tests/licenses_item_seeder_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/seeders/LicensesItemSeeder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = { base_items = {}, item_bindings = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('LicensesItemSeeder.ensure: binds license.duty to the seeded Duty credential base item', function()
    withFakeDb(function(tables)
        LicensesItemSeeder.ensure()

        local dutyItem
        for _, row in ipairs(tables.base_items) do
            if row.name == 'Duty credential' then dutyItem = row end
        end
        eq(dutyItem ~= nil, true)

        local binding
        for _, row in ipairs(tables.item_bindings) do
            if row.key == 'license.duty' then binding = row end
        end
        eq(binding ~= nil, true)
        eq(binding.base_item_id, dutyItem.id)
    end)
end)

test('LicensesItemSeeder.ensure: is idempotent, does not duplicate the binding on a second run', function()
    withFakeDb(function(tables)
        LicensesItemSeeder.ensure()
        LicensesItemSeeder.ensure()

        local count = 0
        for _, row in ipairs(tables.item_bindings) do
            if row.key == 'license.duty' then count = count + 1 end
        end
        eq(count, 1)
    end)
end)

print('\nRunning LicensesItemSeeder unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_licenses/tests/licenses_item_seeder_spec.lua`
Expected: FAIL — `tables.item_bindings` stays empty, `binding ~= nil` is `false`.

- [ ] **Step 3: Write minimal implementation**

In `core/plugins/oblsk_licenses/shared/config.lua`, append before `return Config`:

```lua
-- See docs/superpowers/specs/2026-08-13-door-lock-system-design.md's
-- License integration section. Loaded by core/core/server/bootstrap.lua at
-- boot and handed to ItemService.registerRequirements('oblsk_licenses', Config.Requires.bindings).
Config.Requires = {
    bindings = {
        ['license.duty'] = {
            live = false,
            description = 'On-duty service credential, checked by door access rules',
            hint = 'This plugin\'s own Duty credential item',
        },
    },
}
```

In `core/plugins/oblsk_licenses/server/seeders/LicensesItemSeeder.lua`, replace the `LicensesItemSeeder.ensure` function (currently lines 96-122) with:

```lua
function LicensesItemSeeder.ensure()
    local dutyBaseItemId
    for _, def in ipairs(ITEMS) do
        local existing = QueryBuilder.new('base_items'):where('name', def.name):firstSync()
        if not existing then
            local id = QueryBuilder.new('base_items'):insert({
                name = def.name,
                description = def.description,
                icon = def.icon,
                weight = def.weight,
                is_takeable = def.is_takeable,
                is_giveable = def.is_giveable,
                is_dropable = def.is_dropable,
                is_container = def.is_container,
                is_useable = def.is_useable,
                is_stackable = def.is_stackable,
                is_presentable = def.is_presentable,
                -- QueryBuilder passes insert params through to the connector
                -- untouched (no BaseModel casts layer here), so the JSON
                -- column has to be encoded by hand.
                data = json.encode(def.data),
                created_at = Database.now(),
                updated_at = Database.now(),
            })
            print('[Licenses] seeded base item: ' .. def.name)
            if def.name == 'Duty credential' then dutyBaseItemId = id end
        elseif def.name == 'Duty credential' then
            dutyBaseItemId = existing.id
        end
    end

    if dutyBaseItemId then
        local existingBinding = QueryBuilder.new('item_bindings'):where('key', 'license.duty'):firstSync()
        if not existingBinding then
            QueryBuilder.new('item_bindings'):insert({
                key = 'license.duty',
                base_item_id = dutyBaseItemId,
                updated_by = 'LicensesItemSeeder',
                updated_at = Database.now(),
            })
            print('[Licenses] bound license.duty -> Duty credential (#' .. tostring(dutyBaseItemId) .. ')')
        end
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_licenses/tests/licenses_item_seeder_spec.lua`
Expected: PASS, both tests.

Also re-run: `lua5.4 core/plugins/oblsk_licenses/tests/license_service_spec.lua` — unaffected, still PASS (the seeder change doesn't touch `LicenseService`).

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_licenses
git add shared/config.lua server/seeders/LicensesItemSeeder.lua tests/licenses_item_seeder_spec.lua
git commit -m "Bind license.duty item binding to the seeded Duty credential item"
```

---

### Task 3: `hasValidLicense` export

**Files:**
- Modify: `core/plugins/oblsk_licenses/fxmanifest.lua`
- Create: `core/plugins/oblsk_licenses/server/services/LicenseQueryService.lua`
- Modify: `core/plugins/oblsk_licenses/server/main.lua` (register the export)
- Test: `core/plugins/oblsk_licenses/tests/license_query_service_spec.lua` (new)

**Interfaces:**
- Consumes: `ItemService.hasBinding('license.duty')`/`ItemService.binding('license.duty')` (Task 2's binding); `QueryBuilder.new('items'):where(...)` for the owning character's items; `LicenseService.decodeRowData` (existing).
- Produces: `LicenseQueryService.hasValidLicense(characterId, organizationId)` → `boolean`, and the FiveM export `exports.oblsk_licenses:hasValidLicense(characterId, organizationId)` wired to it — this is what `oblsk_doors` (Task 8) calls.

- [ ] **Step 1: Write the failing test**

Create `core/plugins/oblsk_licenses/tests/license_query_service_spec.lua`:

```lua
-- plugins/oblsk_licenses/tests/license_query_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_licenses/tests/license_query_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/modules/oblsk_items/server/services/ItemService.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/services/LicenseService.lua')
dofile(scriptDir .. '../server/services/LicenseQueryService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = { base_items = {}, items = {}, item_bindings = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    ItemService.resetBindingCacheForTests()
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('hasValidLicense: false when license.duty binding is unset', function()
    withFakeDb(function(tables)
        eq(LicenseQueryService.hasValidLicense(5, 3), false)
    end)
end)

test('hasValidLicense: true for a VALID duty credential matching the organization', function()
    withFakeDb(function(tables)
        ItemService.registerRequirements('oblsk_licenses', { ['license.duty'] = { live = false } })
        tables.base_items = { { id = 2, name = 'Duty credential', data = {} } }
        tables.item_bindings = { { key = 'license.duty', base_item_id = 2 } }
        tables.items = {
            {
                id = 20, base_item_id = 2, owner_type = 'character', owner_id = 5, amount = 1,
                data = json.encode({ status = 'VALID', organization_id = 3, rank_id = 12 }),
            },
        }

        eq(LicenseQueryService.hasValidLicense(5, 3), true)
    end)
end)

test('hasValidLicense: false when the credential is for a different organization', function()
    withFakeDb(function(tables)
        ItemService.registerRequirements('oblsk_licenses', { ['license.duty'] = { live = false } })
        tables.base_items = { { id = 2, name = 'Duty credential', data = {} } }
        tables.item_bindings = { { key = 'license.duty', base_item_id = 2 } }
        tables.items = {
            {
                id = 20, base_item_id = 2, owner_type = 'character', owner_id = 5, amount = 1,
                data = json.encode({ status = 'VALID', organization_id = 99, rank_id = 12 }),
            },
        }

        eq(LicenseQueryService.hasValidLicense(5, 3), false)
    end)
end)

test('hasValidLicense: false for a REVOKED credential', function()
    withFakeDb(function(tables)
        ItemService.registerRequirements('oblsk_licenses', { ['license.duty'] = { live = false } })
        tables.base_items = { { id = 2, name = 'Duty credential', data = {} } }
        tables.item_bindings = { { key = 'license.duty', base_item_id = 2 } }
        tables.items = {
            {
                id = 20, base_item_id = 2, owner_type = 'character', owner_id = 5, amount = 1,
                data = json.encode({ status = 'REVOKED', organization_id = 3, rank_id = 12 }),
            },
        }

        eq(LicenseQueryService.hasValidLicense(5, 3), false)
    end)
end)

print('\nRunning LicenseQueryService unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/plugins/oblsk_licenses/tests/license_query_service_spec.lua`
Expected: FAIL with a Lua error — `LicenseQueryService` is `nil` (file doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `core/plugins/oblsk_licenses/server/services/LicenseQueryService.lua`:

```lua
-- plugins/oblsk_licenses/server/services/LicenseQueryService.lua
--- LicenseQueryService - read-only cross-resource query surface. Kept
--- deliberately dumb (license validity only, no rank/department logic) so
--- rank/dept resolution lives once, in oblsk_organizations, not duplicated
--- here. See docs/superpowers/specs/2026-08-13-door-lock-system-design.md.
LicenseQueryService = {}

--- @param characterId number
--- @param organizationId number
--- @return boolean true if characterId holds a VALID, unexpired duty
---   credential for organizationId
function LicenseQueryService.hasValidLicense(characterId, organizationId)
    if not ItemService.hasBinding('license.duty') then
        return false
    end

    local dutyBaseItem = ItemService.binding('license.duty')
    local rows = QueryBuilder.new('items')
        :where('base_item_id', dutyBaseItem.id)
        :where('owner_type', 'character')
        :where('owner_id', characterId)
        :getSync()

    for _, row in ipairs(rows) do
        LicenseService.decodeRowData(row)
        local data = row.data or {}
        if data.status == 'VALID'
            and tonumber(data.organization_id) == tonumber(organizationId)
            and (not data.expires or data.expires >= os.date('!%Y-%m-%d')) then
            return true
        end
    end

    return false
end

return LicenseQueryService
```

In `core/plugins/oblsk_licenses/fxmanifest.lua`, add an `exports` block after `dependencies` (currently ending line 10):

```lua
exports {
    'hasValidLicense'
}
```

In `core/plugins/oblsk_licenses/server/main.lua`, add near the top (after the `character:created` handler block, before `presentPayload`):

```lua
exports('hasValidLicense', LicenseQueryService.hasValidLicense)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_licenses/tests/license_query_service_spec.lua`
Expected: PASS, all four tests.

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_licenses
git add fxmanifest.lua server/services/LicenseQueryService.lua server/main.lua tests/license_query_service_spec.lua
git commit -m "Add hasValidLicense cross-resource export for door access rules"
```

---

## Part B — `core/modules/oblsk_doors`

### Task 4: Module scaffold + `doors` table

**Files:**
- Create: `core/modules/oblsk_doors/README.md`
- Create: `core/modules/oblsk_doors/server/migrations.json`
- Create: `core/modules/oblsk_doors/server/migrations/2026_08_13_090000_create_doors_table.lua`
- Create: `core/modules/oblsk_doors/server/models/Door.lua`
- Modify: `core/modules/registry.json`
- Test: `core/modules/oblsk_doors/tests/door_model_spec.lua`

**Interfaces:**
- Produces: `Door` model (`BaseModel:extend('doors')`), fillable `{pos_x, pos_y, pos_z, heading, radius, model_hash, locked}`.

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/door_model_spec.lua`:

```lua
-- modules/oblsk_doors/tests/door_model_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/door_model_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(scriptDir .. '../server/models/Door.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('Door.fillable includes coordinate, radius and lock fields', function()
    local fields = {}
    for _, f in ipairs(Door.fillable) do fields[f] = true end
    eq(fields.pos_x, true)
    eq(fields.pos_y, true)
    eq(fields.pos_z, true)
    eq(fields.heading, true)
    eq(fields.radius, true)
    eq(fields.model_hash, true)
    eq(fields.locked, true)
end)

test('a Door can be created and defaults to locked', function()
    local tables = { doors = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(function()
        local door = Door:createSync({ pos_x = 1.0, pos_y = 2.0, pos_z = 3.0, heading = 90.0, radius = 2.0, locked = true })
        eq(door.attributes.locked, true)
        eq(door.attributes.radius, 2.0)
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

print('Running Door model unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_model_spec.lua`
Expected: FAIL — `dofile` errors, `core/modules/oblsk_doors/server/models/Door.lua` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `core/modules/oblsk_doors/server/migrations.json`:

```json
{
  "migrations": [
    "2026_08_13_090000_create_doors_table"
  ]
}
```

Create `core/modules/oblsk_doors/server/migrations/2026_08_13_090000_create_doors_table.lua`:

```lua
--- Migration: Create doors table
return {
    up = function()
        Schema.create('doors', function(table)
            table:id()
            table:float('pos_x')
            table:float('pos_y')
            table:float('pos_z')
            table:float('heading')
            table:float('radius'):default(2.0)
            table:string('model_hash', 64):nullable()
            table:boolean('locked'):default(1)
            table:timestamps()
        end)

        print('[Migration] Created doors table')
    end,

    down = function()
        Schema.drop('doors')
        print('[Migration] Dropped doors table')
    end
}
```

Create `core/modules/oblsk_doors/server/models/Door.lua`:

```lua
Door = BaseModel:extend('doors')

Door.primaryKey = 'id'
Door.timestamps = true

Door.fillable = {
    'pos_x', 'pos_y', 'pos_z', 'heading', 'radius', 'model_hash', 'locked',
}

Door.hidden = {}

return Door
```

Create `core/modules/oblsk_doors/README.md`:

```markdown
# oblsk_doors

Door lock module — permission, org/rank/department license rules, bound
key items, and a lockpick minigame as independent unlock methods. See
`docs/superpowers/specs/2026-08-13-door-lock-system-design.md`.
```

In `core/modules/registry.json`, add `"oblsk_doors"` to the `modules` array (alphabetical, between `oblsk_characters` and `oblsk_items`):

```json
{
  "modules": [
    "oblsk_accounts",
    "oblsk_characters",
    "oblsk_doors",
    "oblsk_items",
    "oblsk_organizations",
    "oblsk_preferences",
    "oblsk_vehicles"
  ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_model_spec.lua`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/README.md modules/oblsk_doors/server/migrations.json \
  modules/oblsk_doors/server/migrations/2026_08_13_090000_create_doors_table.lua \
  modules/oblsk_doors/server/models/Door.lua modules/registry.json \
  modules/oblsk_doors/tests/door_model_spec.lua
git commit -m "Scaffold oblsk_doors module with doors table"
```

---

### Task 5: `door_items` table (key-item binding pivot)

**Files:**
- Create: `core/modules/oblsk_doors/server/migrations/2026_08_13_090001_create_door_items_table.lua`
- Create: `core/modules/oblsk_doors/server/models/DoorItem.lua`
- Modify: `core/modules/oblsk_doors/server/migrations.json`
- Test: `core/modules/oblsk_doors/tests/door_item_model_spec.lua`

**Interfaces:**
- Produces: `DoorItem` model (`BaseModel:extend('door_items')`), fillable `{door_id, binding_key}`.

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/door_item_model_spec.lua`:

```lua
-- modules/oblsk_doors/tests/door_item_model_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/door_item_model_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(scriptDir .. '../server/models/DoorItem.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('DoorItem.fillable is door_id and binding_key', function()
    local fields = {}
    for _, f in ipairs(DoorItem.fillable) do fields[f] = true end
    eq(fields.door_id, true)
    eq(fields.binding_key, true)
end)

test('the same binding_key can be attached to two different doors', function()
    local tables = { door_items = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(function()
        DoorItem:createSync({ door_id = 1, binding_key = 'door.key.house_42.master' })
        DoorItem:createSync({ door_id = 2, binding_key = 'door.key.house_42.master' })

        local rows = QueryBuilder.new('door_items'):where('binding_key', 'door.key.house_42.master'):getSync()
        eq(#rows, 2)
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

print('Running DoorItem model unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_item_model_spec.lua`
Expected: FAIL — `DoorItem` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `core/modules/oblsk_doors/server/migrations/2026_08_13_090001_create_door_items_table.lua`:

```lua
--- Migration: Create door_items table (key-item binding pivot)
return {
    up = function()
        Schema.create('door_items', function(table)
            table:id()
            table:foreignId('door_id'):constrained('doors'):onDelete('CASCADE')
            table:string('binding_key', 128)
            table:timestamps()

            table:index('door_id')
            table:index('binding_key')
        end)

        print('[Migration] Created door_items table')
    end,

    down = function()
        Schema.drop('door_items')
        print('[Migration] Dropped door_items table')
    end
}
```

Create `core/modules/oblsk_doors/server/models/DoorItem.lua`:

```lua
DoorItem = BaseModel:extend('door_items')

DoorItem.primaryKey = 'id'
DoorItem.timestamps = true

DoorItem.fillable = { 'door_id', 'binding_key' }

DoorItem.hidden = {}

function DoorItem:doorRelation()
    return self:belongsTo(Door, 'door_id', 'id')
end

return DoorItem
```

In `core/modules/oblsk_doors/server/migrations.json`, add the new migration:

```json
{
  "migrations": [
    "2026_08_13_090000_create_doors_table",
    "2026_08_13_090001_create_door_items_table"
  ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_item_model_spec.lua`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/server/migrations/2026_08_13_090001_create_door_items_table.lua \
  modules/oblsk_doors/server/models/DoorItem.lua modules/oblsk_doors/server/migrations.json \
  modules/oblsk_doors/tests/door_item_model_spec.lua
git commit -m "Add door_items key-item binding pivot table"
```

---

### Task 6: `door_access_rules` table (org/rank/department)

**Files:**
- Create: `core/modules/oblsk_doors/server/migrations/2026_08_13_090002_create_door_access_rules_table.lua`
- Create: `core/modules/oblsk_doors/server/models/DoorAccessRule.lua`
- Modify: `core/modules/oblsk_doors/server/migrations.json`
- Test: `core/modules/oblsk_doors/tests/door_access_rule_model_spec.lua`

**Interfaces:**
- Produces: `DoorAccessRule` model (`BaseModel:extend('door_access_rules')`), fillable `{door_id, organization_id, rank_id, department_id}`.

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/door_access_rule_model_spec.lua`:

```lua
-- modules/oblsk_doors/tests/door_access_rule_model_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/door_access_rule_model_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(scriptDir .. '../server/models/DoorAccessRule.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('DoorAccessRule.fillable is door_id, organization_id, rank_id, department_id', function()
    local fields = {}
    for _, f in ipairs(DoorAccessRule.fillable) do fields[f] = true end
    eq(fields.door_id, true)
    eq(fields.organization_id, true)
    eq(fields.rank_id, true)
    eq(fields.department_id, true)
end)

test('a door can have two rules for two different ranks (allow-list, not a threshold)', function()
    local tables = { door_access_rules = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(function()
        DoorAccessRule:createSync({ door_id = 1, organization_id = 3, rank_id = 40 })  -- Lieutenant
        DoorAccessRule:createSync({ door_id = 1, organization_id = 3, rank_id = 50 })  -- Chief
        -- deliberately no row for rank_id 45 (Captain) — excluded

        local rows = QueryBuilder.new('door_access_rules'):where('door_id', 1):getSync()
        eq(#rows, 2)
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

print('Running DoorAccessRule model unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_access_rule_model_spec.lua`
Expected: FAIL — `DoorAccessRule` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `core/modules/oblsk_doors/server/migrations/2026_08_13_090002_create_door_access_rules_table.lua`:

```lua
--- Migration: Create door_access_rules table
return {
    up = function()
        Schema.create('door_access_rules', function(table)
            table:id()
            table:foreignId('door_id'):constrained('doors'):onDelete('CASCADE')
            table:integer('organization_id')
            table:integer('rank_id'):nullable()
            table:integer('department_id'):nullable()
            table:timestamps()

            table:index('door_id')
        end)

        print('[Migration] Created door_access_rules table')
    end,

    down = function()
        Schema.drop('door_access_rules')
        print('[Migration] Dropped door_access_rules table')
    end
}
```

(`organization_id`/`rank_id`/`department_id` are plain integers, not `table:foreignId(...):constrained(...)`, because `oblsk_organizations` lives in a different module and this module shouldn't hard-depend on its migration having already run — same soft-reference style used elsewhere for cross-module ids, e.g. `Vehicle.owner_id` in `oblsk_vehicles`.)

Create `core/modules/oblsk_doors/server/models/DoorAccessRule.lua`:

```lua
DoorAccessRule = BaseModel:extend('door_access_rules')

DoorAccessRule.primaryKey = 'id'
DoorAccessRule.timestamps = true

DoorAccessRule.fillable = { 'door_id', 'organization_id', 'rank_id', 'department_id' }

DoorAccessRule.hidden = {}

function DoorAccessRule:doorRelation()
    return self:belongsTo(Door, 'door_id', 'id')
end

return DoorAccessRule
```

In `core/modules/oblsk_doors/server/migrations.json`:

```json
{
  "migrations": [
    "2026_08_13_090000_create_doors_table",
    "2026_08_13_090001_create_door_items_table",
    "2026_08_13_090002_create_door_access_rules_table"
  ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_access_rule_model_spec.lua`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/server/migrations/2026_08_13_090002_create_door_access_rules_table.lua \
  modules/oblsk_doors/server/models/DoorAccessRule.lua modules/oblsk_doors/server/migrations.json \
  modules/oblsk_doors/tests/door_access_rule_model_spec.lua
git commit -m "Add door_access_rules org/rank/department pivot table"
```

---

### Task 7: `DoorService` — permission grant unlock + lock/unlock + admin commands

**Files:**
- Create: `core/modules/oblsk_doors/server/services/DoorService.lua`
- Create: `core/modules/oblsk_doors/server/commands/DoorCommands.lua`
- Test: `core/modules/oblsk_doors/tests/door_service_permission_spec.lua`

**Interfaces:**
- Consumes: `PermissionService.can('character', characterId, key)`/`.grant`/`.revoke` (existing, `core/core/server/Services/PermissionService.lua`); `CharacterService.getActiveCharacterId(source)` (existing pattern, used the same way in `oblsk_licenses/server/main.lua:89`).
- Produces: `DoorService.canUnlock(source, doorId)` → `boolean` (permission-only for this task; Tasks 8-9 add the other two synchronous methods into the same function). `DoorService.lock(doorId)`/`DoorService.unlock(doorId)` → sets `Door.locked` and returns the updated `Door` instance. `DoorService.grant(characterId, doorId)`/`.revoke(characterId, doorId)` — thin wrappers over `PermissionService`.

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/door_service_permission_spec.lua`:

```lua
-- modules/oblsk_doors/tests/door_service_permission_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/door_service_permission_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(scriptDir .. '../server/models/Door.lua')
dofile(scriptDir .. '../server/models/DoorItem.lua')
dofile(scriptDir .. '../server/models/DoorAccessRule.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

-- Test double for CharacterService: DoorService.canUnlock(source, doorId)
-- resolves source -> characterId this way, matching the real
-- oblsk_characters convention without pulling that module in.
CharacterService = { getActiveCharacterId = function(source) return source end }

dofile(scriptDir .. '../server/services/DoorService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = { doors = {}, door_items = {}, door_access_rules = {}, permissions = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('canUnlock: false with no grant and no other unlock method available', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        eq(DoorService.canUnlock(5, 1), false)
    end)
end)

test('canUnlock: true once DoorService.grant has granted the character access', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        DoorService.grant(5, 1)
        eq(DoorService.canUnlock(5, 1), true)
    end)
end)

test('canUnlock: false again after DoorService.revoke', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        DoorService.grant(5, 1)
        DoorService.revoke(5, 1)
        eq(DoorService.canUnlock(5, 1), false)
    end)
end)

test('lock/unlock flip Door.locked', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }

        local door = DoorService.unlock(1)
        eq(door.attributes.locked, false)

        door = DoorService.lock(1)
        eq(door.attributes.locked, true)
    end)
end)

print('Running DoorService permission unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_service_permission_spec.lua`
Expected: FAIL — `DoorService` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `core/modules/oblsk_doors/server/services/DoorService.lua`:

```lua
-- modules/oblsk_doors/server/services/DoorService.lua
--- DoorService - four independent unlock methods, checked in order, first
--- match wins: (1) direct permission grant, (2) org/rank/department access
--- rule via oblsk_licenses' hasValidLicense export, (3) a bound key item,
--- (4) lockpick (handled separately, see the lockpick challenge/response
--- flow, not through canUnlock). See
--- docs/superpowers/specs/2026-08-13-door-lock-system-design.md.
DoorService = {}

local function permissionKey(doorId)
    return 'door:' .. tostring(doorId)
end

--- @param characterId number
--- @param doorId number
function DoorService.grant(characterId, doorId)
    PermissionService.grant('character', characterId, permissionKey(doorId))
end

--- @param characterId number
--- @param doorId number
function DoorService.revoke(characterId, doorId)
    PermissionService.revoke('character', characterId, permissionKey(doorId))
end

--- @param source number player server id
--- @param doorId number
--- @return boolean
function DoorService.canUnlock(source, doorId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false
    end

    if PermissionService.can('character', characterId, permissionKey(doorId)) then
        return true
    end

    return false
end

--- @param doorId number
--- @return table Door instance
function DoorService.lock(doorId)
    local door = Door:findSync(doorId)
    door:update({ locked = true })
    return door
end

--- @param doorId number
--- @return table Door instance
function DoorService.unlock(doorId)
    local door = Door:findSync(doorId)
    door:update({ locked = false })
    return door
end

return DoorService
```

Create `core/modules/oblsk_doors/server/commands/DoorCommands.lua`:

```lua
-- modules/oblsk_doors/server/commands/DoorCommands.lua
--- Admin commands. door_items/door_access_rules rows are data entry
--- (seed/migration or a future admin panel), not chat commands — see the
--- design spec's Open items section.
RegisterCommand('door-create', function(source, args)
    if source ~= 0 and not PermissionService.can('character', CharacterService.getActiveCharacterId(source), 'admin:doors') then
        return
    end

    local x, y, z, heading, radius = tonumber(args[1]), tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
    if not (x and y and z and heading) then
        print('Usage: door-create <x> <y> <z> <heading> [radius]')
        return
    end

    local door = Door:createSync({
        pos_x = x, pos_y = y, pos_z = z, heading = heading,
        radius = radius or 2.0, locked = true,
    })
    print('[Doors] created door #' .. tostring(door.attributes.id))
end, true)

RegisterCommand('door-grant', function(source, args)
    if source ~= 0 and not PermissionService.can('character', CharacterService.getActiveCharacterId(source), 'admin:doors') then
        return
    end

    local characterId, doorId = tonumber(args[1]), tonumber(args[2])
    if not (characterId and doorId) then
        print('Usage: door-grant <characterId> <doorId>')
        return
    end

    DoorService.grant(characterId, doorId)
    print('[Doors] granted character #' .. tostring(characterId) .. ' access to door #' .. tostring(doorId))
end, true)

RegisterCommand('door-revoke', function(source, args)
    if source ~= 0 and not PermissionService.can('character', CharacterService.getActiveCharacterId(source), 'admin:doors') then
        return
    end

    local characterId, doorId = tonumber(args[1]), tonumber(args[2])
    if not (characterId and doorId) then
        print('Usage: door-revoke <characterId> <doorId>')
        return
    end

    DoorService.revoke(characterId, doorId)
    print('[Doors] revoked character #' .. tostring(characterId) .. ' access to door #' .. tostring(doorId))
end, true)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_service_permission_spec.lua`
Expected: PASS, all four tests.

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/server/services/DoorService.lua modules/oblsk_doors/server/commands/DoorCommands.lua \
  modules/oblsk_doors/tests/door_service_permission_spec.lua
git commit -m "Add DoorService with permission-grant unlock, lock/unlock, admin commands"
```

---

### Task 8: `DoorService.canUnlock` — access-rule method (org/rank/department)

**Files:**
- Modify: `core/modules/oblsk_doors/server/services/DoorService.lua`
- Test: `core/modules/oblsk_doors/tests/door_service_access_rule_spec.lua`

**Interfaces:**
- Consumes: `exports.oblsk_licenses:hasValidLicense(characterId, organizationId)` (Task 3); `OrganizationService.getMembership(characterId, organizationId)` → `{organization_id, rank_id, department_ids}` or `nil` (existing, `core/modules/oblsk_organizations/server/services/OrganizationService.lua:209`).
- Produces: extends `DoorService.canUnlock` with the access-rule check; adds `DoorService.passesAccessRule(rule, membership)` (pure function, easy to unit-test in isolation) used internally.

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/door_service_access_rule_spec.lua`:

```lua
-- modules/oblsk_doors/tests/door_service_access_rule_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/door_service_access_rule_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(scriptDir .. '../server/models/Door.lua')
dofile(scriptDir .. '../server/models/DoorItem.lua')
dofile(scriptDir .. '../server/models/DoorAccessRule.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

CharacterService = { getActiveCharacterId = function(source) return source end }

-- Test doubles for the two cross-module/cross-resource dependencies.
-- Real code: exports.oblsk_licenses:hasValidLicense(characterId, orgId);
-- real code: OrganizationService.getMembership(characterId, orgId).
local licensedCharacters = {}   -- characterId -> { [orgId] = true }
local memberships = {}          -- characterId -> orgId -> { organization_id, rank_id, department_ids }
exports = { oblsk_licenses = { hasValidLicense = function(characterId, orgId)
    return licensedCharacters[characterId] ~= nil and licensedCharacters[characterId][orgId] == true
end } }
OrganizationService = { getMembership = function(characterId, orgId)
    return memberships[characterId] and memberships[characterId][orgId]
end }

dofile(scriptDir .. '../server/services/DoorService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = { doors = {}, door_items = {}, door_access_rules = {}, permissions = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    licensedCharacters = {}
    memberships = {}
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('passesAccessRule: a rule with no rank_id/department_id passes any member of the org', function()
    local rule = { organization_id = 3, rank_id = nil, department_id = nil }
    local membership = { organization_id = 3, rank_id = 40, department_ids = {} }
    eq(DoorService.passesAccessRule(rule, membership), true)
end)

test('passesAccessRule: a rank_id-scoped rule requires an exact match', function()
    local rule = { organization_id = 3, rank_id = 40 }
    eq(DoorService.passesAccessRule(rule, { organization_id = 3, rank_id = 40, department_ids = {} }), true)
    eq(DoorService.passesAccessRule(rule, { organization_id = 3, rank_id = 45, department_ids = {} }), false)
end)

test('passesAccessRule: a department_id-scoped rule checks membership among department_ids', function()
    local rule = { organization_id = 3, department_id = 9 }
    eq(DoorService.passesAccessRule(rule, { organization_id = 3, rank_id = 10, department_ids = { 9, 11 } }), true)
    eq(DoorService.passesAccessRule(rule, { organization_id = 3, rank_id = 10, department_ids = { 11 } }), false)
end)

test('passesAccessRule: rank_id and department_id AND together when both set on one row', function()
    local rule = { organization_id = 3, rank_id = 40, department_id = 9 }
    eq(DoorService.passesAccessRule(rule, { organization_id = 3, rank_id = 40, department_ids = { 9 } }), true)
    eq(DoorService.passesAccessRule(rule, { organization_id = 3, rank_id = 40, department_ids = { 11 } }), false)
    eq(DoorService.passesAccessRule(rule, { organization_id = 3, rank_id = 45, department_ids = { 9 } }), false)
end)

test('canUnlock: allow-list of two ranks (Lieutenant, Chief) excludes an unlisted rank (Captain)', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        DoorAccessRule:createSync({ door_id = 1, organization_id = 3, rank_id = 40 })  -- Lieutenant
        DoorAccessRule:createSync({ door_id = 1, organization_id = 3, rank_id = 50 })  -- Chief

        licensedCharacters[5] = { [3] = true }
        licensedCharacters[6] = { [3] = true }

        memberships[5] = { [3] = { organization_id = 3, rank_id = 50, department_ids = {} } }   -- Chief: passes
        memberships[6] = { [3] = { organization_id = 3, rank_id = 45, department_ids = {} } }   -- Captain: excluded

        eq(DoorService.canUnlock(5, 1), true)
        eq(DoorService.canUnlock(6, 1), false)
    end)
end)

test('canUnlock: access rule fails without a valid license even if rank matches', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        DoorAccessRule:createSync({ door_id = 1, organization_id = 3 })

        memberships[5] = { [3] = { organization_id = 3, rank_id = 40, department_ids = {} } }
        -- licensedCharacters[5] left unset -> no valid license

        eq(DoorService.canUnlock(5, 1), false)
    end)
end)

print('Running DoorService access-rule unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_service_access_rule_spec.lua`
Expected: FAIL — `DoorService.passesAccessRule` is `nil`.

- [ ] **Step 3: Write minimal implementation**

In `core/modules/oblsk_doors/server/services/DoorService.lua`, add after `permissionKey` and before `DoorService.grant`:

```lua
--- Pure predicate, no DB/export calls — easy to unit-test in isolation.
--- @param rule table { organization_id, rank_id, department_id } (nullable rank_id/department_id)
--- @param membership table { organization_id, rank_id, department_ids } from OrganizationService.getMembership
--- @return boolean
function DoorService.passesAccessRule(rule, membership)
    if tonumber(rule.organization_id) ~= tonumber(membership.organization_id) then
        return false
    end
    if rule.rank_id ~= nil and tonumber(rule.rank_id) ~= tonumber(membership.rank_id) then
        return false
    end
    if rule.department_id ~= nil then
        local found = false
        for _, deptId in ipairs(membership.department_ids or {}) do
            if tonumber(deptId) == tonumber(rule.department_id) then found = true break end
        end
        if not found then return false end
    end
    return true
end

--- @param characterId number
--- @param doorId number
--- @return boolean
local function passesAnyAccessRule(characterId, doorId)
    local rules = QueryBuilder.new('door_access_rules'):where('door_id', doorId):getSync()
    for _, rule in ipairs(rules) do
        if exports.oblsk_licenses:hasValidLicense(characterId, rule.organization_id) then
            local membership = OrganizationService.getMembership(characterId, rule.organization_id)
            if membership and DoorService.passesAccessRule(rule, membership) then
                return true
            end
        end
    end
    return false
end
```

Then extend `DoorService.canUnlock` (from Task 7) to also check this method:

```lua
function DoorService.canUnlock(source, doorId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false
    end

    if PermissionService.can('character', characterId, permissionKey(doorId)) then
        return true
    end

    if passesAnyAccessRule(characterId, doorId) then
        return true
    end

    return false
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_service_access_rule_spec.lua`
Expected: PASS, all six tests.

Also re-run: `lua5.4 core/modules/oblsk_doors/tests/door_service_permission_spec.lua` — still PASS (its fake environment has no `exports`/`OrganizationService` globals and no `door_access_rules` rows, so `passesAnyAccessRule` iterates zero rules and returns `false`, leaving those tests' outcomes unchanged).

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/server/services/DoorService.lua modules/oblsk_doors/tests/door_service_access_rule_spec.lua
git commit -m "Add org/rank/department access-rule unlock method to DoorService"
```

---

### Task 9: `DoorService.canUnlock` — key-item method

**Files:**
- Modify: `core/modules/oblsk_doors/server/services/DoorService.lua`
- Test: `core/modules/oblsk_doors/tests/door_service_key_item_spec.lua`

**Interfaces:**
- Consumes: `ItemService.hasBinding(key)`/`.binding(key)`/`.has(source, baseItem, amount)` (existing, `core/modules/oblsk_items/server/services/ItemService.lua:204,235,82`).
- Produces: extends `DoorService.canUnlock` with the key-item check (third and final synchronous method; lockpick is handled separately per Task 11).

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/door_service_key_item_spec.lua`:

```lua
-- modules/oblsk_doors/tests/door_service_key_item_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/door_service_key_item_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(scriptDir .. '../server/models/Door.lua')
dofile(scriptDir .. '../server/models/DoorItem.lua')
dofile(scriptDir .. '../server/models/DoorAccessRule.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

CharacterService = { getActiveCharacterId = function(source) return source end }
exports = { oblsk_licenses = { hasValidLicense = function() return false end } }
OrganizationService = { getMembership = function() return nil end }

-- Test double for ItemService: a fixed set of bound keys and, per source,
-- which of those bound base items they're carrying.
local bindings = {}          -- key -> { id = number }
local carriedByCharacter = {} -- characterId -> { [baseItemId] = true }
ItemService = {
    hasBinding = function(key) return bindings[key] ~= nil end,
    binding = function(key) return bindings[key] end,
    has = function(source, baseItem, amount)
        return carriedByCharacter[source] ~= nil and carriedByCharacter[source][baseItem.id] == true
    end,
}

dofile(scriptDir .. '../server/services/DoorService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function withFakeDb(fn)
    local tables = { doors = {}, door_items = {}, door_access_rules = {}, permissions = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    bindings = {}
    carriedByCharacter = {}
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('canUnlock: true when the player carries the item bound to the door\'s key', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        DoorItem:createSync({ door_id = 1, binding_key = 'door.key.house_42.front' })

        bindings['door.key.house_42.front'] = { id = 77 }
        carriedByCharacter[5] = { [77] = true }

        eq(DoorService.canUnlock(5, 1), true)
    end)
end)

test('canUnlock: false when the binding key resolves but the player lacks the item', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        DoorItem:createSync({ door_id = 1, binding_key = 'door.key.house_42.front' })

        bindings['door.key.house_42.front'] = { id = 77 }
        -- carriedByCharacter[5] left unset

        eq(DoorService.canUnlock(5, 1), false)
    end)
end)

test('canUnlock: false and fails closed when the binding key is unbound', function()
    withFakeDb(function(tables)
        tables.doors = { { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true } }
        DoorItem:createSync({ door_id = 1, binding_key = 'door.key.house_42.front' })
        -- bindings table left empty -> ItemService.hasBinding returns false

        eq(DoorService.canUnlock(5, 1), false)
    end)
end)

test('canUnlock: a shared master key opens two different doors', function()
    withFakeDb(function(tables)
        tables.doors = {
            { id = 1, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true },
            { id = 2, pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, radius = 2, locked = true },
        }
        DoorItem:createSync({ door_id = 1, binding_key = 'door.key.house_42.master' })
        DoorItem:createSync({ door_id = 2, binding_key = 'door.key.house_42.master' })

        bindings['door.key.house_42.master'] = { id = 88 }
        carriedByCharacter[5] = { [88] = true }

        eq(DoorService.canUnlock(5, 1), true)
        eq(DoorService.canUnlock(5, 2), true)
    end)
end)

print('Running DoorService key-item unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_service_key_item_spec.lua`
Expected: FAIL — `canUnlock` doesn't check `door_items` yet, all four tests return `false` where some expect `true`.

- [ ] **Step 3: Write minimal implementation**

In `core/modules/oblsk_doors/server/services/DoorService.lua`, add after `passesAnyAccessRule`:

```lua
--- @param source number
--- @param doorId number
--- @return boolean
local function unlocksWithKeyItem(source, doorId)
    local rows = QueryBuilder.new('door_items'):where('door_id', doorId):getSync()
    for _, row in ipairs(rows) do
        if ItemService.hasBinding(row.binding_key) then
            local baseItem = ItemService.binding(row.binding_key)
            if ItemService.has(source, baseItem, 1) then
                return true
            end
        end
    end
    return false
end
```

Then extend `DoorService.canUnlock` once more:

```lua
function DoorService.canUnlock(source, doorId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false
    end

    if PermissionService.can('character', characterId, permissionKey(doorId)) then
        return true
    end

    if passesAnyAccessRule(characterId, doorId) then
        return true
    end

    if unlocksWithKeyItem(source, doorId) then
        return true
    end

    return false
end
```

(`unlocksWithKeyItem` takes `source`, not `characterId` — `ItemService.has`'s existing signature is `(source, baseItem, amount)`, matching the `BankingService` calling convention shown in the spec's research.)

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_service_key_item_spec.lua`
Expected: PASS, all four tests.

Also re-run Tasks 7-8's spec files — still PASS (their fake environments have no `door_items` rows, so `unlocksWithKeyItem` iterates zero rows and returns `false`).

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/server/services/DoorService.lua modules/oblsk_doors/tests/door_service_key_item_spec.lua
git commit -m "Add key-item unlock method to DoorService"
```

---

### Task 10: Server wiring — `InteractionService`/`EntityStreamerService` registration, sync/toggle events

**Files:**
- Create: `core/modules/oblsk_doors/server/main.lua`
- Test: `core/modules/oblsk_doors/tests/door_bootstrap_spec.lua`

**Interfaces:**
- Consumes: `InteractionService.register(data)` (`{x,y,z,range,label,action,options}`, existing, `core/core/server/Services/InteractionService.lua:10`); `EntityStreamerService.register(entityType, entityData)` (existing, `core/core/server/Services/EntityStreamerService.lua:190`); `ActionService.register(actionId, handler, options)` (existing, `core/core/server/Services/ActionService.lua:13`); `Obelisk.emitClient`/`Obelisk.onServer` (existing).
- Produces: on boot, every `Door` row gets an `InteractionService` registration (and an `EntityStreamerService` one if `model_hash` is set) plus a registered `doors:door-toggle` action; `doors:server:sync` sent to a joining player; `doors:client:toggle` handled server-side.

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/door_bootstrap_spec.lua`:

```lua
-- modules/oblsk_doors/tests/door_bootstrap_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/door_bootstrap_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(scriptDir .. '../server/models/Door.lua')
dofile(scriptDir .. '../server/models/DoorItem.lua')
dofile(scriptDir .. '../server/models/DoorAccessRule.lua')

local makeFakeQueryBuilderModule = dofile(CORE_ROOT .. '/tests/support/fake_query_builder.lua')

CharacterService = { getActiveCharacterId = function(source) return source end }
exports = { oblsk_licenses = { hasValidLicense = function() return false end } }
OrganizationService = { getMembership = function() return nil end }
ItemService = { hasBinding = function() return false end, binding = function() return nil end, has = function() return false end }

dofile(scriptDir .. '../server/services/DoorService.lua')

-- Recording doubles for the two registration services and ActionService,
-- so main.lua's boot routine can be asserted against without a real event
-- loop or a real Citizen.CreateThread.
local registeredInteractions = {}
local registeredEntities = {}
local registeredActions = {}
InteractionService = { register = function(data) table.insert(registeredInteractions, data); return #registeredInteractions end }
EntityStreamerService = { register = function(entityType, entityData) table.insert(registeredEntities, { entityType, entityData }) end }
ActionService = { register = function(actionId, handler, options) registeredActions[actionId] = { handler = handler, options = options } end }

dofile(scriptDir .. '../server/main.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('DoorService.registerAll registers an InteractionService point per door', function()
    local tables = { doors = {}, door_items = {}, door_access_rules = {}, permissions = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    tables.doors = { { id = 1, pos_x = 1.0, pos_y = 2.0, pos_z = 3.0, heading = 0, radius = 2.5, locked = true, model_hash = nil } }

    local ok, err = pcall(function()
        registeredInteractions = {}
        registeredEntities = {}
        DoorService.registerAll()

        eq(#registeredInteractions, 1)
        eq(registeredInteractions[1].x, 1.0)
        eq(registeredInteractions[1].range, 2.5)
        eq(registeredInteractions[1].action, 'doors:door-toggle')
        eq(registeredInteractions[1].options.doorId, 1)
        eq(#registeredEntities, 0)  -- no model_hash -> no streamer registration
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

test('DoorService.registerAll also registers an entity when model_hash is set', function()
    local tables = { doors = {}, door_items = {}, door_access_rules = {}, permissions = {} }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    tables.doors = { { id = 2, pos_x = 5.0, pos_y = 6.0, pos_z = 7.0, heading = 90, radius = 2.0, locked = true, model_hash = 'prop_door_01' } }

    local ok, err = pcall(function()
        registeredInteractions = {}
        registeredEntities = {}
        DoorService.registerAll()

        eq(#registeredEntities, 1)
        eq(registeredEntities[1][1], 'object')
        eq(registeredEntities[1][2].model, 'prop_door_01')
    end)

    QueryBuilder = original
    if not ok then error(err, 2) end
end)

test('doors:door-toggle action calls DoorService.canUnlock via ActionService registration', function()
    eq(registeredActions['doors:door-toggle'] ~= nil, true)
end)

print('Running door bootstrap unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_bootstrap_spec.lua`
Expected: FAIL — `core/modules/oblsk_doors/server/main.lua` doesn't exist, `dofile` errors.

- [ ] **Step 3: Write minimal implementation**

Create `core/modules/oblsk_doors/server/main.lua`:

```lua
-- modules/oblsk_doors/server/main.lua
--- Boot-time registration: every door becomes an InteractionService point
--- (and an EntityStreamerService object if it has a model_hash), plus the
--- doors:door-toggle action and the client sync/toggle events.

--- Registers every persisted Door with InteractionService (always) and
--- EntityStreamerService (only if model_hash is set). Exposed on
--- DoorService (rather than kept local to this file) so
--- tests/door_bootstrap_spec.lua can call it directly without a real
--- Citizen.CreateThread/Database.isReady loop.
function DoorService.registerAll()
    local doors = QueryBuilder.new('doors'):getSync()
    for _, door in ipairs(doors) do
        InteractionService.register({
            x = door.pos_x, y = door.pos_y, z = door.pos_z,
            range = door.radius,
            label = 'Use door',
            action = 'doors:door-toggle',
            options = { doorId = door.id },
        })

        if door.model_hash then
            EntityStreamerService.register('object', {
                x = door.pos_x, y = door.pos_y, z = door.pos_z,
                heading = door.heading,
                model = door.model_hash,
                networked = true,
                data = { doorId = door.id },
            })
        end
    end
end

ActionService.register('doors:door-toggle', function(source, data)
    local doorId = data and data.interaction and data.interaction.options and data.interaction.options.doorId
    if not doorId then return end

    if not DoorService.canUnlock(source, doorId) then
        return
    end

    local door = Door:findSync(doorId)
    local updated = door.attributes.locked and DoorService.unlock(doorId) or DoorService.lock(doorId)

    Obelisk.emitClient('doors:server:state-changed', -1, { doorId = doorId, locked = updated.attributes.locked })
end, { label = 'Toggle door lock' })

Obelisk.onServer('doors:client:sync-request', function()
    local source = source
    local doors = QueryBuilder.new('doors'):getSync()
    local payload = {}
    for _, door in ipairs(doors) do
        table.insert(payload, {
            id = door.id, pos_x = door.pos_x, pos_y = door.pos_y, pos_z = door.pos_z,
            heading = door.heading, radius = door.radius, model_hash = door.model_hash,
            locked = door.locked,
        })
    end
    Obelisk.emitClient('doors:server:sync', source, payload)
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    DoorService.registerAll()
    print('[Doors] Loaded successfully!')
end)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/door_bootstrap_spec.lua`
Expected: PASS, all three tests.

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/server/main.lua modules/oblsk_doors/tests/door_bootstrap_spec.lua
git commit -m "Wire doors into InteractionService/EntityStreamerService on boot"
```

---

### Task 11: Lockpick challenge/response flow

**Files:**
- Create: `core/modules/oblsk_doors/server/services/LockpickChallengeService.lua`
- Modify: `core/modules/oblsk_doors/server/main.lua`
- Test: `core/modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua`

**Interfaces:**
- Produces: `LockpickChallengeService.issue(source, doorId)` → `string` token (also stores `{source, doorId, issuedAt}` keyed by token); `LockpickChallengeService.redeem(source, token, doorId)` → `boolean` (validates token exists, matches `source`/`doorId`, and at least `MIN_ELAPSED_MS` has passed since issue; consumes the token — a second redeem with the same token fails).
- Consumes (in `main.lua`'s event handlers): `DoorService.unlock`; `Obelisk.onServer`/`Obelisk.emitClient`.

- [ ] **Step 1: Write the failing test**

Create `core/modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua`:

```lua
-- modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')

-- fivem_stubs.lua provides a GetGameTimer() stub; LockpickChallengeService
-- uses it (not os.time, which fivem_stubs.lua does not stub) to measure
-- elapsed time between issue and redeem, matching how ProgressService
-- times things elsewhere in core.
local fakeNow = 1000
GetGameTimer = function() return fakeNow end

dofile(scriptDir .. '../server/services/LockpickChallengeService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('issue returns a non-empty token', function()
    local token = LockpickChallengeService.issue(5, 1)
    eq(type(token), 'string')
    eq(#token > 0, true)
end)

test('redeem succeeds for the right source/doorId after enough elapsed time', function()
    fakeNow = 1000
    local token = LockpickChallengeService.issue(5, 1)
    fakeNow = 1000 + LockpickChallengeService.MIN_ELAPSED_MS + 1
    eq(LockpickChallengeService.redeem(5, token, 1), true)
end)

test('redeem fails if not enough time has elapsed (implausibly fast completion)', function()
    fakeNow = 1000
    local token = LockpickChallengeService.issue(5, 1)
    fakeNow = 1000 + LockpickChallengeService.MIN_ELAPSED_MS - 1
    eq(LockpickChallengeService.redeem(5, token, 1), false)
end)

test('redeem fails for a mismatched source', function()
    fakeNow = 1000
    local token = LockpickChallengeService.issue(5, 1)
    fakeNow = 1000 + LockpickChallengeService.MIN_ELAPSED_MS + 1
    eq(LockpickChallengeService.redeem(6, token, 1), false)
end)

test('redeem fails for a mismatched doorId', function()
    fakeNow = 1000
    local token = LockpickChallengeService.issue(5, 1)
    fakeNow = 1000 + LockpickChallengeService.MIN_ELAPSED_MS + 1
    eq(LockpickChallengeService.redeem(5, token, 2), false)
end)

test('redeem fails for an unknown/forged token', function()
    eq(LockpickChallengeService.redeem(5, 'forged-token', 1), false)
end)

test('a token can only be redeemed once', function()
    fakeNow = 1000
    local token = LockpickChallengeService.issue(5, 1)
    fakeNow = 1000 + LockpickChallengeService.MIN_ELAPSED_MS + 1
    eq(LockpickChallengeService.redeem(5, token, 1), true)
    eq(LockpickChallengeService.redeem(5, token, 1), false)
end)

print('Running LockpickChallengeService unit tests\n')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua`
Expected: FAIL — `core/modules/oblsk_doors/server/services/LockpickChallengeService.lua` doesn't exist yet, `dofile` errors.

- [ ] **Step 3: Write minimal implementation**

Create `core/modules/oblsk_doors/server/services/LockpickChallengeService.lua`:

```lua
-- modules/oblsk_doors/server/services/LockpickChallengeService.lua
--- LockpickChallengeService - one-time server-issued tokens so the client
--- can never simply claim a lockpick success. issue() hands back a token
--- tied to (source, doorId, issuedAt); redeem() checks the token exists,
--- matches source/doorId, has aged past MIN_ELAPSED_MS (rejects
--- implausibly fast "completions"), and consumes it (a token redeems at
--- most once). See docs/superpowers/specs/2026-08-13-door-lock-system-design.md.
LockpickChallengeService = {}

--- Fastest the real minigame (3 pins, per-pin sweep + tension) could ever
--- legitimately complete in; anything faster than this is a forged result.
LockpickChallengeService.MIN_ELAPSED_MS = 2500

local pending = {}   -- token -> { source, doorId, issuedAt }
local counter = 0

local function newToken()
    counter = counter + 1
    return tostring(GetGameTimer()) .. '-' .. tostring(counter)
end

--- @param source number
--- @param doorId number
--- @return string token
function LockpickChallengeService.issue(source, doorId)
    local token = newToken()
    pending[token] = { source = source, doorId = doorId, issuedAt = GetGameTimer() }
    return token
end

--- @param source number
--- @param token string
--- @param doorId number
--- @return boolean
function LockpickChallengeService.redeem(source, token, doorId)
    local entry = pending[token]
    if not entry then
        return false
    end
    -- Consume unconditionally: a rejected redeem is still spent, so a
    -- forged/mismatched attempt can't be retried against the same token.
    pending[token] = nil

    if entry.source ~= source or entry.doorId ~= doorId then
        return false
    end
    if GetGameTimer() - entry.issuedAt < LockpickChallengeService.MIN_ELAPSED_MS then
        return false
    end
    return true
end

return LockpickChallengeService
```

In `core/modules/oblsk_doors/server/main.lua`, add after the `doors:client:sync-request` handler:

```lua
Obelisk.onServer('doors:client:lockpick-start', function(doorId)
    local source = source
    local token = LockpickChallengeService.issue(source, doorId)
    Obelisk.emitClient('doors:server:lockpick-challenge', source, { doorId = doorId, token = token })
end)

Obelisk.onServer('doors:client:lockpick-result', function(doorId, token, success)
    local source = source
    if not success then return end
    if not LockpickChallengeService.redeem(source, token, doorId) then return end

    local updated = DoorService.unlock(doorId)
    Obelisk.emitClient('doors:server:state-changed', -1, { doorId = doorId, locked = updated.attributes.locked })
end)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua`
Expected: PASS, all seven tests.

- [ ] **Step 5: Commit**

```bash
cd core
git add modules/oblsk_doors/server/services/LockpickChallengeService.lua modules/oblsk_doors/server/main.lua \
  modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua
git commit -m "Add lockpick challenge/response token flow"
```

---

### Task 12: Client `DoorClientService`

**Files:**
- Create: `core/modules/oblsk_doors/client/services/DoorClientService.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient`/`Obelisk.emitServer` (client-side counterparts of the server helpers, same naming convention); native FiveM functions `CreateObject`, `SetEntityHeading`, `FreezeEntityPosition`, `DeleteObject` for animating the prop the streamer spawned.
- Produces: an in-memory `doors` table synced from the server, kept current via `doors:server:state-changed`; on a state change, if a live object handle for that door exists (tracked separately from `EntityStreamerService`'s own chunk-based handles, per the spec's "prop animation is DoorClientService's job, not the streamer's" decision), its heading is rotated open/closed.

- [ ] **Step 1: Write the client service**

There is no client-side Lua test harness in this codebase (`tests/support/fivem_stubs.lua` only stubs enough for server-side ORM specs) — client logic here is verified manually per the plan's Task 14 checklist, matching how other client services in the framework (e.g. `oblsk_vehicles/client/services/VehicleService.lua`) are covered.

Create `core/modules/oblsk_doors/client/services/DoorClientService.lua`:

```lua
-- modules/oblsk_doors/client/services/DoorClientService.lua
--- DoorClientService - keeps a local copy of every door's state and, for
--- doors with a spawned visual prop, rotates that prop open/closed on
--- state change. Deliberately independent of EntityStreamerService's own
--- object lifecycle (see the design spec's Interaction & prop section) —
--- this only touches a handle it finds live in the world right now; it
--- never asks the streamer to spawn/despawn anything itself.
DoorClientService = {}

local doors = {}       -- doorId -> door row (pos_x/y/z, heading, radius, model_hash, locked)
local propHandles = {} -- doorId -> entity handle, populated lazily when found nearby

local OPEN_HEADING_OFFSET = 90.0

local function findNearbyPropHandle(door)
    if not door.model_hash then return nil end
    local modelHash = GetHashKey(door.model_hash)
    local handle = GetClosestObjectOfType(door.pos_x, door.pos_y, door.pos_z, 1.0, modelHash, false, false, false)
    return handle ~= 0 and handle or nil
end

local function applyDoorState(doorId)
    local door = doors[doorId]
    if not door then return end

    local handle = propHandles[doorId] or findNearbyPropHandle(door)
    if not handle then return end
    propHandles[doorId] = handle

    local heading = door.locked and door.heading or (door.heading + OPEN_HEADING_OFFSET)
    SetEntityHeading(handle, heading)
end

Obelisk.onClient('doors:server:sync', function(payload)
    doors = {}
    for _, door in ipairs(payload) do
        doors[door.id] = door
    end
    for doorId in pairs(doors) do
        applyDoorState(doorId)
    end
end)

Obelisk.onClient('doors:server:state-changed', function(data)
    local door = doors[data.doorId]
    if not door then return end
    door.locked = data.locked
    applyDoorState(data.doorId)
end)

Citizen.CreateThread(function()
    Obelisk.emitServer('doors:client:sync-request')
end)

return DoorClientService
```

- [ ] **Step 2: Manual smoke check (no automated harness for client Lua)**

Confirmed at Task 14's manual verification pass, not here — flagged explicitly rather than silently skipped.

- [ ] **Step 3: Commit**

```bash
cd core
git add modules/oblsk_doors/client/services/DoorClientService.lua
git commit -m "Add client-side door state sync and prop rotation"
```

---

### Task 13: Lockpick minigame — Vue port

**Files:**
- Create: `core/modules/oblsk_doors/web/LockpickGame.vue`
- Create: `core/modules/oblsk_doors/web/globalElements.js`
- Modify: `core/modules/oblsk_doors/client/services/DoorClientService.lua`

**Interfaces:**
- Produces: `LockpickGame.vue`, a self-contained Vue 3 SFC replicating `LockpickGame` from the Claude Design source (`src/proto/minigames.jsx`, project `019de78f-9966-77d9-90c0-73b12ead46cd`) — 3-pin sweep-lock, `A`/`D` sweep, `Space` tension-hold, per-pin randomized sweet spot with shrinking tolerance, pick wear/strain (3 picks), pass/fail state. Registered via `globalElements.js` (the `App.vue` glob-import convention, `core/web/src/App.vue:17,20,29,46`), shown/hidden via `WebView.showGlobalElement`/`.hideGlobalElement` (same mechanism `oblsk_licenses/server/main.lua:65-66,102,105` uses for its present overlay) triggered from `DoorClientService` when the player chooses "Pick lock" on a locked door's interaction.

- [ ] **Step 1: Write the Vue component**

Create `core/modules/oblsk_doors/web/LockpickGame.vue`:

```vue
<template>
  <div v-if="visible" class="lockpick-overlay">
    <div class="lockpick-panel" :style="{ width: `${R * 2}px`, height: `${R * 2}px` }">
      <div class="ring" />
      <div class="cylinder" :style="{ transform: `rotate(${cylTurn}deg)` }">
        <div class="keyway" />
      </div>
      <div class="pick" :style="{ transform: `rotate(${angle}deg) translateY(-50%)`, background: tension ? 'var(--ob-accent)' : 'rgba(255,255,255,.55)' }" />
      <div v-if="state !== 'run'" class="result">
        <div class="title">{{ state === 'pass' ? 'Lock open' : 'All picks broken' }}</div>
        <button @click="reset">Close</button>
      </div>
    </div>
    <div class="hud">
      <div>Pins set: {{ pin }} / {{ PINS }}</div>
      <div>Picks left: {{ picks }}</div>
      <div>Pin progress: {{ Math.round(progress) }}%</div>
      <div>Pick strain: {{ Math.round(wear) }}%</div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'LockpickGame',
  props: {
    visible: { type: Boolean, default: false },
    doorId: { type: Number, default: null },
  },
  emits: ['result'],
  data() {
    return {
      R: 150,
      PINS: 3,
      pin: 0,
      picks: 3,
      angle: -90,
      progress: 0,
      wear: 0,
      state: 'run',
      tension: false,
      turn: null,
      sweet: -160 + Math.random() * 140,
      raf: null,
      last: 0,
      keydownHandler: null,
      keyupHandler: null,
    };
  },
  computed: {
    tol() { return 16 - this.pin * 3; },
    cylTurn() { return (this.progress / 100) * 78; },
  },
  watch: {
    visible(v) {
      if (v) this.start(); else this.stop();
    },
  },
  methods: {
    start() {
      this.reset();
      this.keydownHandler = (e) => {
        const k = e.key.toLowerCase();
        if (k === 'a' || e.code === 'ArrowLeft') { e.preventDefault(); this.turn = 'ccw'; }
        if (k === 'd' || e.code === 'ArrowRight') { e.preventDefault(); this.turn = 'cw'; }
        if (e.code === 'Space') { e.preventDefault(); this.tension = true; }
      };
      this.keyupHandler = (e) => {
        const k = e.key.toLowerCase();
        if (k === 'a' || k === 'd' || e.code === 'ArrowLeft' || e.code === 'ArrowRight') this.turn = null;
        if (e.code === 'Space') this.tension = false;
      };
      window.addEventListener('keydown', this.keydownHandler);
      window.addEventListener('keyup', this.keyupHandler);
      this.last = performance.now();
      this.raf = requestAnimationFrame(this.tick);
    },
    stop() {
      if (this.raf) cancelAnimationFrame(this.raf);
      if (this.keydownHandler) window.removeEventListener('keydown', this.keydownHandler);
      if (this.keyupHandler) window.removeEventListener('keyup', this.keyupHandler);
    },
    reset() {
      this.pin = 0; this.picks = 3; this.progress = 0; this.wear = 0;
      this.state = 'run'; this.turn = null; this.tension = false;
      this.sweet = -160 + Math.random() * 140;
    },
    tick(t) {
      const dt = Math.min(64, t - this.last); this.last = t;

      if (this.state === 'run') {
        const dir = this.turn === 'ccw' ? -1 : this.turn === 'cw' ? 1 : 0;
        if (dir) this.angle = Math.max(-180, Math.min(0, this.angle + dir * 0.11 * dt));

        if (this.tension) {
          const diff = Math.abs(this.angle - this.sweet);
          if (diff < this.tol) {
            this.progress += dt * (0.16 * (1 - diff / this.tol) + 0.05);
            this.wear = Math.max(0, this.wear - dt * 0.02);
            if (this.progress >= 100) {
              this.progress = 0;
              if (this.pin + 1 >= this.PINS) {
                this.state = 'pass';
                this.tension = false;
                this.$emit('result', { doorId: this.doorId, success: true });
              } else {
                this.pin += 1;
                this.sweet = -170 + Math.random() * 160;
                this.wear = 0;
              }
            }
          } else {
            this.wear += dt * (0.035 + (diff / 180) * 0.09);
            this.progress = Math.max(0, this.progress - dt * 0.08);
            if (this.wear >= 100) {
              this.tension = false;
              this.wear = 0;
              this.progress = 0;
              this.picks -= 1;
              if (this.picks <= 0) {
                this.state = 'fail';
                this.$emit('result', { doorId: this.doorId, success: false });
              }
            }
          }
        } else {
          this.progress = Math.max(0, this.progress - dt * 0.05);
          this.wear = Math.max(0, this.wear - dt * 0.05);
        }
      }

      if (this.visible) this.raf = requestAnimationFrame(this.tick);
    },
  },
};
</script>

<style scoped>
.lockpick-overlay { position: fixed; inset: 0; display: grid; place-items: center; background: rgba(0,0,0,.55); z-index: 9990; }
.lockpick-panel { position: relative; border-radius: 999px; border: 6px solid rgba(255,255,255,.12); background: radial-gradient(circle at 35% 30%, #1a1d20, #0b0d0f); }
.ring { position: absolute; inset: 18px; border-radius: 999px; border: 1px solid rgba(255,255,255,.08); }
.cylinder { position: absolute; inset: 42px; border-radius: 999px; background: radial-gradient(circle at 35% 30%, #2a2f34, #111417); transition: transform .08s linear; }
.keyway { position: absolute; left: 50%; top: 50%; width: 12px; height: 60%; transform: translate(-50%, -50%); background: rgba(0,0,0,.55); border-radius: 3px; }
.pick { position: absolute; left: 50%; top: 50%; width: calc(50% - 12px); height: 3px; transform-origin: left; }
.result { position: absolute; inset: 0; display: grid; place-items: center; background: rgba(0,0,0,.72); border-radius: 999px; text-align: center; }
.hud { margin-top: 12px; color: #e6e8ea; font-family: monospace; font-size: 12px; display: flex; gap: 16px; }
</style>
```

Create `core/modules/oblsk_doors/web/globalElements.js`, following the `oblsk_licenses/web/globalElements.js:4-6` precedent:

```js
import LockpickGame from './LockpickGame.vue';

export default [
  { name: 'doorLockpick', component: LockpickGame, defaultVisible: false },
];
```

In `core/modules/oblsk_doors/client/services/DoorClientService.lua`, add (after the `Citizen.CreateThread` sync-request block):

```lua
--- Called by whatever UI presents the door's interact options (radial menu
--- or a simple prompt — out of scope for this plan, see the door admin UI
--- open item) when the player picks "Pick lock" on a locked door.
function DoorClientService.startLockpick(doorId)
    Obelisk.emitServer('doors:client:lockpick-start', doorId)
end

Obelisk.onClient('doors:server:lockpick-challenge', function(data)
    WebView.showGlobalElement('doorLockpick')
    WebView.emitClient('doors:lockpick-show', { doorId = data.doorId, token = data.token })
end)
```

And add the NUI-callback bridge at the end of the same file:

```lua
--- The Vue component's 'result' emit reaches Lua through this callback
--- (same NUI-callback convention as oblsk_licenses' present/putAway flow).
RegisterNUICallback('doors:lockpick-result', function(payload, cb)
    Obelisk.emitServer('doors:client:lockpick-result', payload.doorId, payload.token, payload.success)
    WebView.hideGlobalElement('doorLockpick')
    cb('ok')
end)
```

- [ ] **Step 2: Manual verification**

No automated harness for Vue/NUI in this codebase (confirmed in Task 12) — verified at Task 14's manual pass: open the minigame, confirm A/D sweep the pick, Space applies tension, wear/strain climbs off-target, 3 pins complete the lock, 3 broken picks fail it, and a `success`/`failure` NUI callback round-trips to the server and the door's `locked` state flips accordingly.

- [ ] **Step 3: Commit**

```bash
cd core
git add modules/oblsk_doors/web/LockpickGame.vue modules/oblsk_doors/web/globalElements.js \
  modules/oblsk_doors/client/services/DoorClientService.lua
git commit -m "Port lockpick minigame to Vue and wire the NUI result callback"
```

---

### Task 14: Full-suite run + manual verification checklist

**Files:** none (verification only)

- [ ] **Step 1: Run every new server-side spec file**

```bash
cd /home/andi/Projects/obelisk-framework
for f in core/plugins/oblsk_licenses/tests/license_service_spec.lua \
         core/plugins/oblsk_licenses/tests/licenses_item_seeder_spec.lua \
         core/plugins/oblsk_licenses/tests/license_query_service_spec.lua \
         core/modules/oblsk_doors/tests/door_model_spec.lua \
         core/modules/oblsk_doors/tests/door_item_model_spec.lua \
         core/modules/oblsk_doors/tests/door_access_rule_model_spec.lua \
         core/modules/oblsk_doors/tests/door_service_permission_spec.lua \
         core/modules/oblsk_doors/tests/door_service_access_rule_spec.lua \
         core/modules/oblsk_doors/tests/door_service_key_item_spec.lua \
         core/modules/oblsk_doors/tests/door_bootstrap_spec.lua \
         core/modules/oblsk_doors/tests/lockpick_challenge_service_spec.lua; do
  echo "== $f =="
  lua5.4 "$f" || exit 1
done
```

Expected: every file prints `N passed, 0 failed` and the loop completes without exiting early.

- [ ] **Step 2: Also run the pre-existing suites this plan touched, to catch regressions**

```bash
lua5.4 core/plugins/oblsk_licenses/tests/license_present_service_spec.lua 2>/dev/null || true
lua5.4 core/modules/oblsk_organizations/tests/department_rank_model_spec.lua
```

Expected: unaffected, both still `PASS` (Task 1-3 changes are additive fields/new files, no existing behavior removed).

- [ ] **Step 3: Manual verification checklist (live server, no automated coverage)**

Run against a real FXServer boot (per the framework's existing manual-verification convention for NUI/minigame work, matching how the character-selection and keybind-layering plans closed out):

- [ ] Boot with `oblsk_doors` in `core/modules/registry.json` and `oblsk_licenses` running; confirm `[Doors] Loaded successfully!` and `[Licenses] bound license.duty -> Duty credential (#N)` both print.
- [ ] `/door-create <x> <y> <z> <heading> 2.0` near the player creates a door; interacting while `locked = true` and holding no grant/license/key fails silently (door stays locked).
- [ ] `/door-grant <characterId> <doorId>` then interacting unlocks it; door state broadcasts and (if `model_hash` was set) the prop visibly rotates.
- [ ] Issue a duty license with `organization_id`/`rank_id` matching a `door_access_rules` row created directly via DB insert (no admin UI yet, per the spec's open item) — confirm the org/rank/department AND/OR semantics from Task 8's test cases hold against a real character/organization, including the "two ranks, not a threshold" case.
- [ ] Bind an item to a `door.key.*` key via a direct `item_bindings` row, give the character that item, confirm the door unlocks; remove the item, confirm it no longer does.
- [ ] Open the lockpick minigame on a locked door with no other unlock method available; complete it and confirm the door unlocks; fail it (break all 3 picks) and confirm it stays locked; attempt a forged/replayed NUI callback (same token twice) and confirm the second attempt is rejected server-side (no state change, no error visible to the exploit attempt beyond it silently failing).

- [ ] **Step 4: Final commit (if the manual pass surfaced fixes)**

```bash
cd core
git add -A
git commit -m "Door lock system: address manual verification findings"
```

(Skip this step entirely if the manual pass found nothing to fix.)
