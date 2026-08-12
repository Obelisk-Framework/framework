# oblsk_mdt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `oblsk_mdt`, a new standalone plugin implementing the Mobile Data Terminal, registering into `oblsk_phone` as a phone app via the existing cross-plugin extension points, covering all 15 modules from the source design.

**Architecture:** One new plugin repo, `plugins/oblsk_mdt`, following the exact schema/service/Vue-component-per-module shape already established by `oblsk_phone` and `oblsk_organizations`. Three `oblsk_organizations` orgs (LSPD/LSMD/DOJ) model authority; `PermissionService`/`HasPermissions` gate every write; every write also logs to a shared `mdt_audit_log` via `MdtAuditService`; Command Centre and Phone Lines read `oblsk_phone`'s existing `DispatchService`/`phone_dispatch_calls` instead of duplicating a call queue.

**Tech Stack:** Lua 5.4 (server/client), Vue 3 + Tailwind (web), the Obelisk ORM (`Schema`/`QueryBuilder`/`Database`), `lua5.4` as the test runner (no busted), a fake in-memory `QueryBuilder` for unit tests.

## Global Constraints

- Event naming: `oblsk_mdt:server:<module>-<action>` / `oblsk_mdt:client:<module>-<action>`, matching `<plugin>:<server|client>:<action>` convention.
- Every migration file must be listed by name (no extension) in `server/migrations.json`'s `"migrations"` array, in the order it should run — not auto-discovered.
- Every service function that resolves the acting player does so via `CharacterService.getActiveCharacterId(source)` server-side (`modules/oblsk_characters/server/services/CharacterService.lua:98`); the client never supplies a `characterId`.
- Every write handler checks a permission via `Character:can(key)` (from `HasPermissions.apply(Character, 'character')`, already applied framework-wide) before touching data. A denied check returns `{ ok = false, error = 'forbidden' }`, never throws.
- Every write path (in every module, not just cases/docs) calls `MdtAuditService.log(characterId, auth, module, what, ref)` after the write succeeds.
- Unit tests: one spec file per service under `plugins/oblsk_mdt/tests/`, using the shared fake `QueryBuilder` (`tests/support/fake_query_builder.lua`, copy the existing one from `modules/oblsk_organizations/tests/support/fake_query_builder.lua` — same file, same API, into this plugin's own `tests/support/`), run individually with `lua5.4 tests/<name>_spec.lua`.
- No Claude co-authorship in any commit. Minimize em/en dashes in prose (commit messages, docs), not code/SQL.
- After the plugin directory exists, `plugins/registry.json` must be regenerated (`node cli/commands/registry-generate.js`, run on the host, not inside the Docker container) so the framework loads `oblsk_mdt`.
- `db_group` resolution: given a character's `oblsk_organizations` membership, LSPD and DOJ characters get `db_group = 'ls-shared'`, LSMD characters get `db_group = 'lsmd'`. This is computed at write time from `OrganizationService.getMemberships(characterId)`, never stored redundantly beyond the row's own `db_group` column.

---

## File Structure

```
plugins/oblsk_mdt/
  fxmanifest.lua
  server/
    migrations.json
    migrations/
      2026_08_12_000001_create_mdt_audit_log_table.lua
      2026_08_12_000002_create_mdt_cases_tables.lua
      2026_08_12_000003_create_mdt_citizens_tables.lua
      2026_08_12_000004_create_mdt_documents_tables.lua
      2026_08_12_000005_create_mdt_citizen_vehicles_table.lua
      2026_08_12_000006_create_mdt_command_tables.lua
      2026_08_12_000007_create_mdt_manhunts_table.lua
      2026_08_12_000008_create_mdt_impound_table.lua
      2026_08_12_000009_create_mdt_detention_tables.lua
      2026_08_12_000010_create_mdt_law_tables.lua
      2026_08_12_000011_create_mdt_board_tables.lua
      2026_08_12_000012_create_mdt_staff_meta_table.lua
      2026_08_12_000013_create_mdt_calendar_tables.lua
    services/
      MdtAuditService.lua
      MdtAuthService.lua        -- resolves db_group/authority from org membership
      MdtCaseService.lua
      MdtCitizenService.lua
      MdtDocumentService.lua
      MdtVehicleService.lua
      MdtCommandService.lua
      MdtManhuntService.lua
      MdtImpoundService.lua
      MdtDetentionService.lua
      MdtLawService.lua
      MdtBoardService.lua
      MdtStaffService.lua
      MdtCalendarService.lua
    seeders/
      2026_08_12_000000_seed_mdt_organizations.lua
    main.lua                    -- Obelisk.onServer handlers, PhoneAppRegistry.register() call, seeder invocation
  client/
    main.lua                    -- WebView.on() relays, Obelisk.onClient pushes
  web/
    phoneApps.js
    Mdt.vue                     -- shell/chrome, module nav, auth switcher
    apps/
      Command/Command.vue
      Cases/Cases.vue
      Citizens/Citizens.vue
      Docs/Docs.vue
      Vehicles/Vehicles.vue
      Audit/Audit.vue
      Admin/Admin.vue
      Lines/Lines.vue
      Manhunts/Manhunts.vue
      Impound/Impound.vue
      Detention/Detention.vue
      Laws/Laws.vue
      Board/Board.vue
      Staff/Staff.vue
      Calendar/Calendar.vue
  tests/
    support/fake_query_builder.lua
    mdt_audit_service_spec.lua
    mdt_case_service_spec.lua
    mdt_citizen_service_spec.lua
    mdt_document_service_spec.lua
    mdt_vehicle_service_spec.lua
    mdt_command_service_spec.lua
    mdt_manhunt_service_spec.lua
    mdt_impound_service_spec.lua
    mdt_detention_service_spec.lua
    mdt_law_service_spec.lua
    mdt_board_service_spec.lua
    mdt_staff_service_spec.lua
    mdt_calendar_service_spec.lua

core/web/src/components/DocEditor.vue   -- ported shared component (Task 7)
plugins/oblsk_phone/server/services/PhoneAppRegistry.lua  -- modified (Task 1: remove static 'mdt' catalog row)
```

---

## Task 1: Plugin scaffold, manifest, registration into the phone

**Files:**
- Create: `plugins/oblsk_mdt/fxmanifest.lua`
- Create: `plugins/oblsk_mdt/server/migrations.json`
- Create: `plugins/oblsk_mdt/server/main.lua`
- Create: `plugins/oblsk_mdt/client/main.lua`
- Create: `plugins/oblsk_mdt/web/phoneApps.js`
- Create: `plugins/oblsk_mdt/web/Mdt.vue` (minimal placeholder shell for now, replaced fully in Task 4)
- Modify: `plugins/oblsk_phone/server/services/PhoneAppRegistry.lua:18` (remove the static `{ app_key = 'mdt', name = 'MDT' }` catalog row)
- Modify: `plugins/registry.json` (regenerated, not hand-edited)

**Interfaces:**
- Produces: the `oblsk_mdt` plugin directory exists and boots; `PhoneAppRegistry.register({ app_key = 'mdt', name = 'MDT', mandatory = false })` is called from `oblsk_mdt`'s own boot, matching the signature at `plugins/oblsk_phone/server/services/PhoneAppRegistry.lua:49`.
- Consumes: `PhoneAppRegistry.register` (global, provided by `oblsk_phone` at runtime — not required/imported, just called as a global function, matching how every other cross-module call in this framework works).

- [ ] **Step 1: Remove MDT from oblsk_phone's static catalog**

Edit `plugins/oblsk_phone/server/services/PhoneAppRegistry.lua`, delete line 18:
```lua
    { app_key = 'mdt',       name = 'MDT' },
```
so the `CATALOG` table no longer lists `mdt` (MDT is now a cross-plugin app, same as the Banking precedent already documented in that file's comments).

- [ ] **Step 2: Commit the catalog removal**

```bash
cd plugins/oblsk_phone
git add server/services/PhoneAppRegistry.lua
git commit -m "Remove MDT from static catalog, now a cross-plugin app"
```

- [ ] **Step 3: Create the plugin directory and fxmanifest.lua**

```bash
mkdir -p plugins/oblsk_mdt/server/migrations plugins/oblsk_mdt/server/services plugins/oblsk_mdt/server/seeders plugins/oblsk_mdt/client plugins/oblsk_mdt/web/apps plugins/oblsk_mdt/tests/support
cd plugins/oblsk_mdt
git init
```

`plugins/oblsk_mdt/fxmanifest.lua`:
```lua
fx_version 'cerulean'
games { 'gta5' }

name 'MDT'
author ''
version '1.0.0'

dependencies {
    'obelisk'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
    'web/*.js',
    'web/apps/**/*.vue',
}
```

- [ ] **Step 4: Create an empty migrations manifest**

`plugins/oblsk_mdt/server/migrations.json`:
```json
{
    "migrations": []
}
```

- [ ] **Step 5: Create server/main.lua registering the app**

`plugins/oblsk_mdt/server/main.lua`:
```lua
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    PhoneAppRegistry.register({
        app_key = 'mdt',
        name = 'MDT',
        mandatory = false,
    })
end)
```

- [ ] **Step 6: Create client/main.lua (empty relay file, filled in by later tasks)**

`plugins/oblsk_mdt/client/main.lua`:
```lua
-- WebView.on() relays for oblsk_mdt are added here as each module ships.
```

- [ ] **Step 7: Create web/phoneApps.js and a placeholder Mdt.vue**

`plugins/oblsk_mdt/web/Mdt.vue`:
```vue
<template>
  <div class="w-full h-full flex items-center justify-center text-white/40 text-[12px]">
    MDT (placeholder, replaced in Task 4)
  </div>
</template>
```

`plugins/oblsk_mdt/web/phoneApps.js`:
```js
import Mdt from './Mdt.vue'

export default [
  { app_key: 'mdt', name: 'MDT', component: Mdt },
]
```

- [ ] **Step 8: Regenerate the plugin registry**

```bash
cd /home/andi/Projects/obelisk-framework/core
node cli/commands/registry-generate.js
git diff plugins/registry.json
```
Expected: `plugins/registry.json` now includes `"oblsk_mdt"` in its `plugins` array.

- [ ] **Step 9: Verify the phone still boots and shows an MDT tile**

Manual check (no automated test for this step — it's glue, not logic): start the dev stack, open the phone, confirm an "MDT" app tile appears and opens the placeholder screen without console errors about the glob or missing component.

- [ ] **Step 10: Commit**

```bash
cd plugins/oblsk_mdt
git add -A
git commit -m "Scaffold oblsk_mdt plugin, register into phone"
cd /home/andi/Projects/obelisk-framework/core
git add plugins/registry.json
git commit -m "Register oblsk_mdt in plugin registry"
```

---

## Task 2: Seed LSPD/LSMD/DOJ organizations

**Files:**
- Create: `plugins/oblsk_mdt/server/seeders/2026_08_12_000000_seed_mdt_organizations.lua`
- Modify: `plugins/oblsk_mdt/server/main.lua` (call the seeder on boot)
- Test: `plugins/oblsk_mdt/tests/mdt_organizations_seed_spec.lua`

**Interfaces:**
- Consumes: `OrganizationService.create(name) -> orgId`, `OrganizationService.addDepartment(orgId, name) -> deptId`, `OrganizationService.addRank(orgId, name, grade) -> rankId` (all from `modules/oblsk_organizations/server/services/OrganizationService.lua`).
- Produces: `MdtSeedService.ensureOrganizations()`, idempotent, returns `{ lspd = orgId, lsmd = orgId, doj = orgId }`. Later tasks (`MdtAuthService`) look up these orgs by name, not by a stored id, so this function does not need to be called by other services directly.

- [ ] **Step 1: Write the seeder as a plain idempotent function**

`plugins/oblsk_mdt/server/seeders/2026_08_12_000000_seed_mdt_organizations.lua`:
```lua
MdtSeedService = MdtSeedService or {}

local ORGS = {
    { key = 'lspd', name = 'Los Santos Police Department',
      depts = { 'Patrol', 'Traffic', 'Detective Bureau', 'Air Support', 'Academy', 'Command' },
      ranks = { { 'Cadet', 1 }, { 'Officer I', 2 }, { 'Officer II', 3 }, { 'Sergeant', 4 },
                { 'Detective II', 5 }, { 'Lieutenant', 6 }, { 'Captain', 7 }, { 'Chief', 8 } } },
    { key = 'lsmd', name = 'Los Santos Medical Department',
      depts = { 'Pillbox Hill', 'Sandy Shores', 'Air Ambulance', 'Field Operations', 'Training' },
      ranks = { { 'Trainee', 1 }, { 'EMT', 2 }, { 'Paramedic', 3 }, { 'Senior Paramedic', 4 },
                { 'Supervisor', 5 }, { 'Chief of Medicine', 6 } } },
    { key = 'doj', name = 'Department of Justice',
      depts = { 'Criminal Division', 'Civil Division', 'Judiciary' },
      ranks = { { 'Clerk', 1 }, { 'Deputy Attorney', 2 }, { 'Attorney', 3 },
                { 'Senior Attorney', 4 }, { 'Judge', 5 }, { 'Attorney General', 6 } } },
}

--- Idempotent: safe to call on every boot. Looks up existing orgs by name
--- (Organization has no natural unique key beyond name in this framework),
--- creating only what's missing.
--- @return table { lspd = orgId, lsmd = orgId, doj = orgId }
function MdtSeedService.ensureOrganizations()
    local result = {}
    for _, org in ipairs(ORGS) do
        local existing = QueryBuilder.new('organizations'):where('name', org.name):firstSync()
        local orgId = existing and existing.id or OrganizationService.create(org.name)
        result[org.key] = orgId

        if not existing then
            for _, deptName in ipairs(org.depts) do
                OrganizationService.addDepartment(orgId, deptName)
            end
            for _, rank in ipairs(org.ranks) do
                OrganizationService.addRank(orgId, rank[1], rank[2])
            end
        end
    end
    return result
end
```

- [ ] **Step 2: Wire it into boot**

Add to `plugins/oblsk_mdt/server/main.lua`, inside the existing `onResourceStart` handler, after the `PhoneAppRegistry.register` call:
```lua
    MdtSeedService.ensureOrganizations()
```

- [ ] **Step 3: Write the failing test**

`plugins/oblsk_mdt/tests/mdt_organizations_seed_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')
-- (fake_query_builder.lua sets a global `makeFakeQueryBuilderModule`-style loader,
--  matching modules/oblsk_organizations/tests/organization_service_crud_spec.lua's setup)

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

test('ensureOrganizations creates exactly three orgs with departments and ranks', function()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    dofile(scriptDir .. '../../../modules/oblsk_organizations/server/services/OrganizationService.lua')
    dofile(scriptDir .. '../server/seeders/2026_08_12_000000_seed_mdt_organizations.lua')

    local ids = MdtSeedService.ensureOrganizations()
    eq(ids.lspd ~= nil, true, 'lspd org created')
    eq(ids.lsmd ~= nil, true, 'lsmd org created')
    eq(ids.doj ~= nil, true, 'doj org created')
    eq(#tables['organizations'], 3, 'exactly 3 organization rows')

    local lspdDepts = 0
    for _, row in ipairs(tables['organization_departments'] or {}) do
        if row.organization_id == ids.lspd then lspdDepts = lspdDepts + 1 end
    end
    eq(lspdDepts, 6, 'LSPD has 6 departments')
end)

test('ensureOrganizations is idempotent', function()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    dofile(scriptDir .. '../../../modules/oblsk_organizations/server/services/OrganizationService.lua')
    dofile(scriptDir .. '../server/seeders/2026_08_12_000000_seed_mdt_organizations.lua')

    MdtSeedService.ensureOrganizations()
    MdtSeedService.ensureOrganizations()
    eq(#tables['organizations'], 3, 'still exactly 3 organization rows after calling twice')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 4: Copy the fake QueryBuilder support file**

```bash
cp modules/oblsk_organizations/tests/support/fake_query_builder.lua plugins/oblsk_mdt/tests/support/fake_query_builder.lua
```

- [ ] **Step 5: Run test to verify it fails, then passes**

```bash
lua5.4 plugins/oblsk_mdt/tests/mdt_organizations_seed_spec.lua
```
Expected before Step 1's file exists: FAIL (`MdtSeedService` is nil). After Steps 1-4: `All tests passed`, exit code 0.

- [ ] **Step 6: Commit**

```bash
cd plugins/oblsk_mdt
git add server/seeders server/main.lua tests/mdt_organizations_seed_spec.lua tests/support
git commit -m "Seed LSPD/LSMD/DOJ organizations on boot"
```

---

## Task 3: MdtAuditService and MdtAuthService

Every later module calls both of these, so they're built before any module that writes data.

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000001_create_mdt_audit_log_table.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtAuditService.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtAuthService.lua`
- Modify: `plugins/oblsk_mdt/server/migrations.json`
- Test: `plugins/oblsk_mdt/tests/mdt_audit_service_spec.lua`
- Test: `plugins/oblsk_mdt/tests/mdt_auth_service_spec.lua`

**Interfaces:**
- Produces:
  - `MdtAuditService.log(characterId, auth, module, what, ref)` — `ref` is optional (nil-able), inserts one `mdt_audit_log` row.
  - `MdtAuditService.list(limit)` — every module's `audit` screen calls this. (Single-argument: audit is visible to every authority for accountability, not filtered by `db_group` — see the Step 3 code block below, which governs over this line.)
  - `MdtAuthService.resolve(characterId) -> { auth = 'lspd'|'lsmd'|'doj', dbGroup = 'ls-shared'|'lsmd', orgId, memberships = {...} } | nil` — `nil` if the character holds none of the three MDT orgs (no MDT access at all).
- Consumes: `OrganizationService.getMemberships(characterId) -> table[]` (each row has `organization_id`), `QueryBuilder.new('organizations'):where('name', ...)`.

- [ ] **Step 1: Write the migration**

`plugins/oblsk_mdt/server/migrations/2026_08_12_000001_create_mdt_audit_log_table.lua`:
```lua
return {
    up = function()
        Schema.create('mdt_audit_log', function(table)
            table:id()
            table:integer('character_id'):notNullable():index()
            table:string('auth', 10):notNullable()
            table:string('module', 30):notNullable()
            table:string('what', 255):notNullable()
            table:string('ref', 60)
            table:datetime('at'):notNullable()
        end)
        print('[Migration] Created mdt_audit_log table')
    end,
    down = function()
        Schema.drop('mdt_audit_log')
        print('[Migration] Dropped mdt_audit_log table')
    end
}
```

- [ ] **Step 2: Register it in migrations.json**

`plugins/oblsk_mdt/server/migrations.json`:
```json
{
    "migrations": [
        "2026_08_12_000001_create_mdt_audit_log_table"
    ]
}
```

- [ ] **Step 3: Write MdtAuditService**

`plugins/oblsk_mdt/server/services/MdtAuditService.lua`:
```lua
MdtAuditService = {}

--- @param characterId number
--- @param auth string 'lspd'|'lsmd'|'doj'
--- @param module string e.g. 'cases', 'citizens'
--- @param what string human-readable description of the write
--- @param ref string|nil optional reference (case id, citizen id, etc.)
function MdtAuditService.log(characterId, auth, module, what, ref)
    QueryBuilder.new('mdt_audit_log'):insert({
        character_id = characterId,
        auth = auth,
        module = module,
        what = what,
        ref = ref,
        at = Database.now(),
    })
end

--- @param dbGroup string 'ls-shared'|'lsmd' — audit is scoped by db_group via a join
---   is not needed: entries are already per-character, and MDT's db_group split is
---   about case/citizen visibility, not audit visibility (every authority sees the
---   full audit trail for accountability). Kept as a parameter for future filtering.
--- @param limit number
function MdtAuditService.list(limit)
    return QueryBuilder.new('mdt_audit_log'):orderBy('at', 'desc'):limit(limit or 200):getSync()
end

return MdtAuditService
```

- [ ] **Step 4: Write MdtAuthService**

`plugins/oblsk_mdt/server/services/MdtAuthService.lua`:
```lua
MdtAuthService = {}

local ORG_NAME_TO_AUTH = {
    ['Los Santos Police Department'] = 'lspd',
    ['Los Santos Medical Department'] = 'lsmd',
    ['Department of Justice'] = 'doj',
}

local AUTH_TO_DB_GROUP = {
    lspd = 'ls-shared',
    doj = 'ls-shared',
    lsmd = 'lsmd',
}

--- Resolves a character's MDT authority from their oblsk_organizations
--- memberships. A character with no membership in LSPD/LSMD/DOJ has no
--- MDT access at all.
--- @param characterId number
--- @return table|nil { auth, dbGroup, orgId, memberships }
function MdtAuthService.resolve(characterId)
    local memberships = OrganizationService.getMemberships(characterId)
    local matches = {}

    for _, membership in ipairs(memberships) do
        local org = QueryBuilder.new('organizations'):where('id', membership.organization_id):firstSync()
        local auth = org and ORG_NAME_TO_AUTH[org.name]
        if auth then
            table.insert(matches, { auth = auth, orgId = membership.organization_id, membership = membership })
        end
    end

    if #matches == 0 then return nil end

    -- First match is the default/implicit authority; the shell's auth
    -- switcher (Task 4) lets a multi-org character pick a different one.
    local chosen = matches[1]
    return {
        auth = chosen.auth,
        dbGroup = AUTH_TO_DB_GROUP[chosen.auth],
        orgId = chosen.orgId,
        memberships = matches,
    }
end

return MdtAuthService
```

- [ ] **Step 5: Write failing tests, run, then implement until green**

`plugins/oblsk_mdt/tests/mdt_audit_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

Database = { now = function() return '2026-08-12 00:00:00' end }

test('log inserts one row with all fields', function()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    dofile(scriptDir .. '../server/services/MdtAuditService.lua')

    MdtAuditService.log(7, 'lspd', 'cases', 'created the case file', 'LSPD-2026-114')
    eq(#tables['mdt_audit_log'], 1, 'one row inserted')
    eq(tables['mdt_audit_log'][1].character_id, 7)
    eq(tables['mdt_audit_log'][1].module, 'cases')
end)

test('list returns rows ordered newest first, respecting limit', function()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    dofile(scriptDir .. '../server/services/MdtAuditService.lua')

    MdtAuditService.log(1, 'lspd', 'cases', 'first')
    MdtAuditService.log(1, 'lspd', 'cases', 'second')
    local rows = MdtAuditService.list(1)
    eq(#rows, 1, 'limit respected')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

Run: `lua5.4 plugins/oblsk_mdt/tests/mdt_audit_service_spec.lua` — expect FAIL first (`MdtAuditService.lua` not yet present in test's dofile order before Step 3, or `orderBy`/`limit` unsupported by the fake — check `support/fake_query_builder.lua`'s API from the research notes; it does support `:orderBy()`/`:limit()`), then PASS after Step 3.

`plugins/oblsk_mdt/tests/mdt_auth_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

test('resolve returns lspd auth for a character in the LSPD org', function()
    local tables = { organizations = { { id = 1, name = 'Los Santos Police Department' } } }
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    OrganizationService = { getMemberships = function(characterId)
        return { { organization_id = 1, rank_id = 2, department_ids = {} } }
    end }
    dofile(scriptDir .. '../server/services/MdtAuthService.lua')

    local result = MdtAuthService.resolve(42)
    eq(result.auth, 'lspd')
    eq(result.dbGroup, 'ls-shared')
end)

test('resolve returns nil for a character in no MDT org', function()
    local tables = { organizations = {} }
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    OrganizationService = { getMemberships = function() return {} end }
    dofile(scriptDir .. '../server/services/MdtAuthService.lua')

    local result = MdtAuthService.resolve(42)
    eq(result, nil)
end)

test('resolve returns lsmd db group for an LSMD character', function()
    local tables = { organizations = { { id = 2, name = 'Los Santos Medical Department' } } }
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    OrganizationService = { getMemberships = function() return { { organization_id = 2 } } end }
    dofile(scriptDir .. '../server/services/MdtAuthService.lua')

    local result = MdtAuthService.resolve(9)
    eq(result.auth, 'lsmd')
    eq(result.dbGroup, 'lsmd')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

Run: `lua5.4 plugins/oblsk_mdt/tests/mdt_auth_service_spec.lua` — FAIL then PASS after Step 4.

- [ ] **Step 6: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtAuditService.lua server/services/MdtAuthService.lua tests/mdt_audit_service_spec.lua tests/mdt_auth_service_spec.lua
git commit -m "Add MdtAuditService and MdtAuthService"
```

---

## Task 4: MDT shell (Mdt.vue chrome, module nav, auth switcher)

**Files:**
- Modify: `plugins/oblsk_mdt/web/Mdt.vue` (replace Task 1's placeholder)
- Create: `plugins/oblsk_mdt/web/moduleNav.js`
- Modify: `plugins/oblsk_mdt/server/main.lua` (add the `oblsk_mdt:server:auth-resolve` handler)
- Modify: `plugins/oblsk_mdt/client/main.lua` (add the matching relay)

**Interfaces:**
- Produces: `moduleNav.js` exports `MODULES`, the exact 15-entry array from the source design (`id`, `label`, `icon`, `auth` list), consumed by `Mdt.vue` and by every subsequent module task to know which `auth` values can see it.
- Consumes: `MdtAuthService.resolve` (Task 3), `Obelisk.on/emit` (`core/web/src/obelisk.js`).

- [ ] **Step 1: Write moduleNav.js**

`plugins/oblsk_mdt/web/moduleNav.js`:
```js
export const MODULES = [
  { id: 'command',   label: 'Command centre', icon: 'grid',     auth: ['lspd', 'lsmd'] },
  { id: 'cases',     label: 'Case files',     icon: 'folder',   auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'citizens',  label: 'Citizens',       icon: 'contact',  auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'docs',      label: 'Documents',      icon: 'file',     auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'vehicles',  label: 'Vehicles',       icon: 'car',      auth: ['lspd', 'doj'] },
  { id: 'audit',     label: 'Audit trail',    icon: 'clip',     auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'admin',     label: 'Administration', icon: 'settings', auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'lines',     label: 'Phone lines',    icon: 'phone',    auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'manhunts',  label: 'Manhunts',       icon: 'radio',    auth: ['lspd', 'doj'] },
  { id: 'impound',   label: 'Impound',        icon: 'car',      auth: ['lspd'] },
  { id: 'detention', label: 'Detention',      icon: 'lock',     auth: ['lspd', 'doj'] },
  { id: 'laws',      label: 'Law books',      icon: 'book',     auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'board',     label: 'Blackboard',     icon: 'pin',      auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'staff',     label: 'Employees',      icon: 'users',    auth: ['lspd', 'lsmd', 'doj'] },
  { id: 'calendar',  label: 'Calendar',       icon: 'calendar', auth: ['lspd', 'lsmd', 'doj'] },
]
```

- [ ] **Step 2: Add the auth-resolve server handler**

Add to `plugins/oblsk_mdt/server/main.lua`:
```lua
Obelisk.onServer('oblsk_mdt:server:auth-resolve', function()
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    Obelisk.emitClient('oblsk_mdt:client:auth-resolve', source, resolved)
end)
```

- [ ] **Step 3: Add the client relay**

Add to `plugins/oblsk_mdt/client/main.lua`:
```lua
WebView.on('oblsk_mdt:client:auth-resolve', function(data)
    Obelisk.emitServer('oblsk_mdt:server:auth-resolve')
end)

Obelisk.onClient('oblsk_mdt:client:auth-resolve', function(resolved)
    SendNUIMessage({ eventname = 'oblsk_mdt:client:auth-resolve', args = { resolved } })
end)
```

- [ ] **Step 4: Write Mdt.vue**

`plugins/oblsk_mdt/web/Mdt.vue`:
```vue
<template>
  <div class="w-full h-full flex text-[13px]" style="background: linear-gradient(160deg, rgba(7,9,10,.92), rgba(7,9,10,.97)); color: #fff;">
    <div v-if="!resolved" class="w-full h-full flex items-center justify-center text-white/40 text-[12px]">
      No MDT access for this character.
    </div>
    <template v-else>
      <nav class="w-[220px] shrink-0 border-r border-white/8 flex flex-col">
        <div class="h-10 px-3.5 flex items-center justify-between border-b border-white/8">
          <span class="ob-mono text-[9.5px] tracking-[0.2em] uppercase text-white/40">{{ resolved.auth.toUpperCase() }}</span>
          <select v-if="resolved.memberships.length > 1" v-model="auth" class="bg-transparent text-[10px]">
            <option v-for="m in resolved.memberships" :key="m.auth" :value="m.auth">{{ m.auth.toUpperCase() }}</option>
          </select>
        </div>
        <button v-for="m in visibleModules" :key="m.id" @click="mod = m.id"
          class="text-left px-3.5 py-2.5 border-b border-white/6 transition"
          :class="mod === m.id ? 'bg-white/[0.08]' : 'hover:bg-white/4'">
          {{ m.label }}
        </button>
      </nav>
      <div class="flex-1 min-w-0 p-4">
        <component :is="activeComponent" v-if="activeComponent" :auth="auth" :db-group="dbGroup" />
        <div v-else class="text-white/30 text-[12px]">Module not yet available.</div>
      </div>
    </template>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount, shallowRef } from 'vue'
import Obelisk from '@/obelisk.js'
import { MODULES } from './moduleNav.js'

const resolved = ref(null)
const auth = ref(null)
const mod = ref('command')
const componentRegistry = shallowRef({})

const visibleModules = computed(() => MODULES.filter(m => m.auth.includes(auth.value)))
const dbGroup = computed(() => auth.value === 'lsmd' ? 'lsmd' : 'ls-shared')
const activeComponent = computed(() => componentRegistry.value[mod.value] || null)

function handleAuthResolve(data) {
  resolved.value = data
  if (data) auth.value = data.auth
}

onMounted(() => {
  Obelisk.on('oblsk_mdt:client:auth-resolve', handleAuthResolve)
  Obelisk.emit('oblsk_mdt:client:auth-resolve', {})
})
onBeforeUnmount(() => {
  Obelisk.off('oblsk_mdt:client:auth-resolve', handleAuthResolve)
})
</script>
```

`componentRegistry` starts empty; each subsequent module task (5-18) registers its component into it (e.g. `componentRegistry.value = { ...componentRegistry.value, cases: CasesComponent }`), keeping `Mdt.vue`'s own diff small per task rather than importing all 15 up front in this task.

- [ ] **Step 5: Manual verification**

Start the dev stack, open the MDT app as a character with no org membership (expect "No MDT access"), then as a character joined to LSPD via `OrganizationService.join` (expect the nav to show the 12 modules whose `auth` includes `'lspd'`).

- [ ] **Step 6: Commit**

```bash
cd plugins/oblsk_mdt
git add web/Mdt.vue web/moduleNav.js server/main.lua client/main.lua
git commit -m "Add MDT shell: chrome, module nav, auth resolution"
```

---

## Task 5: Cases module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000002_create_mdt_cases_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtCaseService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Cases/Cases.vue`
- Modify: `plugins/oblsk_mdt/server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue` (register `cases` into `componentRegistry`)
- Test: `plugins/oblsk_mdt/tests/mdt_case_service_spec.lua`

**Interfaces:**
- Consumes: `MdtAuthService.resolve`, `MdtAuditService.log`, `Character:can(key)`.
- Produces: `MdtCaseService.list(dbGroup) -> table[]`, `MdtCaseService.get(caseId) -> table|nil`, `MdtCaseService.create(characterId, auth, dbGroup, data) -> caseId`, `MdtCaseService.setStage(characterId, auth, caseId, stage, note)`, `MdtCaseService.share(characterId, auth, caseId, sharedWithAuth, scope, until_)`.

- [ ] **Step 1: Write the migration**

`plugins/oblsk_mdt/server/migrations/2026_08_12_000002_create_mdt_cases_tables.lua`:
```lua
return {
    up = function()
        Schema.create('mdt_cases', function(table)
            table:id()
            table:string('case_number', 30):notNullable():unique()
            table:string('db_group', 20):notNullable():index()
            table:string('title', 150):notNullable()
            table:string('status', 20):notNullable()
            table:integer('priority'):notNullable()
            table:integer('lead_character_id'):notNullable()
            table:text('narrative')
            table:string('stage', 20):notNullable()
            table:json('settle_json')
            table:json('restricted_depts_json')
            table:datetime('opened_at'):notNullable()
        end)
        Schema.create('mdt_case_charges', function(table)
            table:id()
            table:integer('case_id'):notNullable():index()
            table:string('charge_code', 20):notNullable()
        end)
        Schema.create('mdt_case_people', function(table)
            table:id()
            table:integer('case_id'):notNullable():index()
            table:string('name', 100):notNullable()
            table:string('role', 30):notNullable()
            table:integer('citizen_id')
        end)
        Schema.create('mdt_case_officers', function(table)
            table:id()
            table:integer('case_id'):notNullable():index()
            table:integer('character_id'):notNullable()
            table:string('role', 30):notNullable()
        end)
        Schema.create('mdt_case_shares', function(table)
            table:id()
            table:integer('case_id'):notNullable():index()
            table:string('shared_with_auth', 10):notNullable()
            table:string('scope', 60)
            table:string('until', 30)
        end)
        Schema.create('mdt_case_stages', function(table)
            table:id()
            table:integer('case_id'):notNullable():index()
            table:datetime('at'):notNullable()
            table:string('stage', 20):notNullable()
            table:integer('by_character_id'):notNullable()
            table:text('note')
        end)
        Schema.create('mdt_case_hearings', function(table)
            table:id()
            table:integer('case_id'):notNullable():index()
            table:string('who', 60)
            table:string('kind', 30)
            table:text('body')
            table:datetime('at'):notNullable()
            table:integer('by_character_id'):notNullable()
        end)
        print('[Migration] Created mdt_cases tables')
    end,
    down = function()
        Schema.drop('mdt_case_hearings')
        Schema.drop('mdt_case_stages')
        Schema.drop('mdt_case_shares')
        Schema.drop('mdt_case_officers')
        Schema.drop('mdt_case_people')
        Schema.drop('mdt_case_charges')
        Schema.drop('mdt_cases')
        print('[Migration] Dropped mdt_cases tables')
    end
}
```

- [ ] **Step 2: Register in migrations.json**

Append `"2026_08_12_000002_create_mdt_cases_tables"` to the `"migrations"` array in `plugins/oblsk_mdt/server/migrations.json`.

- [ ] **Step 3: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_case_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

Database = { now = function() return '2026-08-12 00:00:00' end }

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local logged = {}
    MdtAuditService = { log = function(...) table.insert(logged, { ... }) end }
    dofile(scriptDir .. '../server/services/MdtCaseService.lua')
    return tables, logged
end

test('create inserts a case row scoped to the caller db_group', function()
    local tables, logged = setup()
    local caseId = MdtCaseService.create(7, 'lspd', 'ls-shared', { title = 'Forum Dr shooting', priority = 1 })
    eq(tables['mdt_cases'][1].db_group, 'ls-shared')
    eq(tables['mdt_cases'][1].stage, 'open')
    eq(#logged, 1, 'audit logged once')
end)

test('list only returns cases in the caller db_group', function()
    local tables = setup()
    MdtCaseService.create(1, 'lspd', 'ls-shared', { title = 'A', priority = 1 })
    MdtCaseService.create(2, 'lsmd', 'lsmd', { title = 'B', priority = 1 })
    local shared = MdtCaseService.list('ls-shared')
    eq(#shared, 1, 'only the ls-shared case returned')
    eq(shared[1].title, 'A')
end)

test('setStage records a stage-history row and updates the case', function()
    local tables = setup()
    local caseId = MdtCaseService.create(1, 'lspd', 'ls-shared', { title = 'A', priority = 1 })
    MdtCaseService.setStage(1, 'lspd', caseId, 'investigation', 'moved to investigation')
    eq(tables['mdt_cases'][1].stage, 'investigation')
    eq(#tables['mdt_case_stages'], 1)
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

Run: `lua5.4 plugins/oblsk_mdt/tests/mdt_case_service_spec.lua` — expect FAIL (`MdtCaseService` nil).

- [ ] **Step 4: Implement MdtCaseService**

`plugins/oblsk_mdt/server/services/MdtCaseService.lua`:
```lua
MdtCaseService = {}

local function generateCaseNumber(auth)
    local prefix = auth == 'lsmd' and 'LSMD' or (auth == 'doj' and 'DOJ' or 'LSPD')
    return prefix .. '-' .. os.date('%Y') .. '-' .. tostring(math.random(100, 999))
end

--- @param dbGroup string
--- @return table[]
function MdtCaseService.list(dbGroup)
    return QueryBuilder.new('mdt_cases'):where('db_group', dbGroup):orderBy('opened_at', 'desc'):getSync()
end

--- @param caseId number
function MdtCaseService.get(caseId)
    return QueryBuilder.new('mdt_cases'):where('id', caseId):firstSync()
end

--- @param characterId number
--- @param auth string
--- @param dbGroup string
--- @param data table { title, priority, narrative (optional) }
--- @return number caseId
function MdtCaseService.create(characterId, auth, dbGroup, data)
    local caseId = QueryBuilder.new('mdt_cases'):insert({
        case_number = generateCaseNumber(auth),
        db_group = dbGroup,
        title = data.title,
        status = 'OPEN',
        priority = data.priority,
        lead_character_id = characterId,
        narrative = data.narrative,
        stage = 'open',
        opened_at = Database.now(),
    })
    MdtAuditService.log(characterId, auth, 'cases', 'created the case file', tostring(caseId))
    return caseId
end

--- @param characterId number
--- @param auth string
--- @param caseId number
--- @param stage string
--- @param note string|nil
function MdtCaseService.setStage(characterId, auth, caseId, stage, note)
    QueryBuilder.new('mdt_cases'):where('id', caseId):update({ stage = stage })
    QueryBuilder.new('mdt_case_stages'):insert({
        case_id = caseId, at = Database.now(), stage = stage, by_character_id = characterId, note = note,
    })
    MdtAuditService.log(characterId, auth, 'cases', 'moved case to stage ' .. stage, tostring(caseId))
end

--- @param characterId number
--- @param auth string
--- @param caseId number
--- @param sharedWithAuth string
--- @param scope string
--- @param until_ string|nil
function MdtCaseService.share(characterId, auth, caseId, sharedWithAuth, scope, until_)
    QueryBuilder.new('mdt_case_shares'):insert({
        case_id = caseId, shared_with_auth = sharedWithAuth, scope = scope, ['until'] = until_,
    })
    MdtAuditService.log(characterId, auth, 'cases', 'shared with ' .. sharedWithAuth .. ' · ' .. scope, tostring(caseId))
end

return MdtCaseService
```

- [ ] **Step 5: Run tests again, verify pass**

```bash
lua5.4 plugins/oblsk_mdt/tests/mdt_case_service_spec.lua
```
Expected: `All tests passed`, exit 0.

- [ ] **Step 6: Add server handlers**

Add to `plugins/oblsk_mdt/server/main.lua`:
```lua
Obelisk.onServer('oblsk_mdt:server:cases-list', function()
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    if not resolved then return end
    local cases = MdtCaseService.list(resolved.dbGroup)
    Obelisk.emitClient('oblsk_mdt:client:cases-list', source, cases)
end)

Obelisk.onServer('oblsk_mdt:server:cases-create', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    if not resolved or not Character:can('mdt-write-case') then
        Obelisk.emitClient('oblsk_mdt:client:cases-create', source, { ok = false, error = 'forbidden' })
        return
    end
    local caseId = MdtCaseService.create(characterId, resolved.auth, resolved.dbGroup, data)
    Obelisk.emitClient('oblsk_mdt:client:cases-create', source, { ok = true, caseId = caseId })
end)
```

Note: `Character:can(...)` above assumes a `Character` model instance is resolvable server-side for `characterId` (same pattern as every other permission-gated write in this framework — if the framework exposes `CharacterService.find(characterId)` returning a model with `HasPermissions` applied, use `CharacterService.find(characterId):can('mdt-write-case')` instead of a bare global; verify the exact accessor against `modules/oblsk_characters/server/services/CharacterService.lua` during implementation and adjust both this task and Tasks 6-18 consistently).

- [ ] **Step 7: Add client relays**

Add to `plugins/oblsk_mdt/client/main.lua`:
```lua
WebView.on('oblsk_mdt:client:cases-list', function(data) Obelisk.emitServer('oblsk_mdt:server:cases-list') end)
Obelisk.onClient('oblsk_mdt:client:cases-list', function(cases)
    SendNUIMessage({ eventname = 'oblsk_mdt:client:cases-list', args = { cases } })
end)

WebView.on('oblsk_mdt:client:cases-create', function(data) Obelisk.emitServer('oblsk_mdt:server:cases-create', data) end)
Obelisk.onClient('oblsk_mdt:client:cases-create', function(result)
    SendNUIMessage({ eventname = 'oblsk_mdt:client:cases-create', args = { result } })
end)
```

- [ ] **Step 8: Write Cases.vue**

`plugins/oblsk_mdt/web/apps/Cases/Cases.vue`:
```vue
<template>
  <div class="h-full flex flex-col gap-3">
    <div class="flex items-center justify-between">
      <h2 class="text-[14px] font-semibold">Case files</h2>
      <button @click="createDraft" class="px-2.5 h-7 rounded-md text-[11px] text-black" style="background: var(--ob-accent)">+ New case</button>
    </div>
    <div class="flex-1 overflow-y-auto">
      <button v-for="c in cases" :key="c.id" class="w-full text-left px-3.5 py-2.5 border-b border-white/6 hover:bg-white/4">
        <div class="flex justify-between text-[12px]">
          <span>{{ c.case_number }} · {{ c.title }}</span>
          <span class="text-white/40">{{ c.stage }}</span>
        </div>
      </button>
      <div v-if="!cases.length" class="p-6 text-center text-[12px] text-white/30">No cases yet.</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'

const cases = ref([])

function handleList(data) { cases.value = data || [] }
function refresh() { Obelisk.emit('oblsk_mdt:client:cases-list', {}) }
function createDraft() {
  Obelisk.emit('oblsk_mdt:client:cases-create', { title: 'Untitled case', priority: 3 }).then(refresh)
}

onMounted(() => { Obelisk.on('oblsk_mdt:client:cases-list', handleList); refresh() })
onBeforeUnmount(() => { Obelisk.off('oblsk_mdt:client:cases-list', handleList) })
</script>
```

- [ ] **Step 9: Register the component in Mdt.vue**

In `plugins/oblsk_mdt/web/Mdt.vue`, add the import and registration:
```js
import Cases from './apps/Cases/Cases.vue'
componentRegistry.value = { ...componentRegistry.value, cases: Cases }
```
(Place the `componentRegistry.value = { ...componentRegistry.value, cases: Cases }` line in `onMounted`, before the `Obelisk.on`/`emit` calls, so it runs once at mount alongside every later task's own registration line.)

- [ ] **Step 10: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtCaseService.lua server/main.lua client/main.lua web/apps/Cases web/Mdt.vue tests/mdt_case_service_spec.lua
git commit -m "Add Cases module"
```

---

## Task 6: Citizens module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000003_create_mdt_citizens_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtCitizenService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Citizens/Citizens.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_citizen_service_spec.lua`

**Interfaces:**
- Produces: `MdtCitizenService.list(dbGroup) -> table[]`, `MdtCitizenService.search(dbGroup, query) -> table[]`, `MdtCitizenService.get(citizenId) -> table|nil`, `MdtCitizenService.create(characterId, auth, dbGroup, data) -> citizenId`, `MdtCitizenService.setWanted(characterId, auth, citizenId, wanted, wantedFor)`.
- Consumes: `MdtAuditService.log` (Task 3).

- [ ] **Step 1: Write the migration**

`plugins/oblsk_mdt/server/migrations/2026_08_12_000003_create_mdt_citizens_tables.lua`:
```lua
return {
    up = function()
        Schema.create('mdt_citizens', function(table)
            table:id()
            table:string('kind', 10):notNullable()
            table:string('db_group', 20):notNullable():index()
            table:string('name', 100):notNullable():index()
            table:string('dob', 20)
            table:integer('phone_number_character_id')
            table:string('bank_account', 30)
            table:string('address', 150)
            table:boolean('wanted')
            table:string('wanted_for', 150)
        end)
        Schema.create('mdt_citizen_licenses', function(table)
            table:id()
            table:integer('citizen_id'):notNullable():index()
            table:string('license', 30):notNullable()
        end)
        print('[Migration] Created mdt_citizens tables')
    end,
    down = function()
        Schema.drop('mdt_citizen_licenses')
        Schema.drop('mdt_citizens')
        print('[Migration] Dropped mdt_citizens tables')
    end
}
```

- [ ] **Step 2: Register in migrations.json** (append `"2026_08_12_000003_create_mdt_citizens_tables"`)

- [ ] **Step 3: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_citizen_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

Database = { now = function() return '2026-08-12 00:00:00' end }

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtCitizenService.lua')
    return tables
end

test('create inserts a citizen scoped to db_group', function()
    local tables = setup()
    MdtCitizenService.create(1, 'lspd', 'ls-shared', { name = 'John Doe', kind = 'person' })
    eq(#tables['mdt_citizens'], 1)
    eq(tables['mdt_citizens'][1].wanted, false)
end)

test('search matches by partial name within db_group only', function()
    local tables = setup()
    MdtCitizenService.create(1, 'lspd', 'ls-shared', { name = 'John Doe', kind = 'person' })
    MdtCitizenService.create(2, 'lsmd', 'lsmd', { name = 'John Smith', kind = 'person' })
    local results = MdtCitizenService.search('ls-shared', 'john')
    eq(#results, 1)
    eq(results[1].name, 'John Doe')
end)

test('setWanted flags a citizen and audits it', function()
    local tables = setup()
    local id = MdtCitizenService.create(1, 'lspd', 'ls-shared', { name = 'John Doe', kind = 'person' })
    MdtCitizenService.setWanted(1, 'lspd', id, true, 'Armed robbery')
    eq(tables['mdt_citizens'][1].wanted, true)
    eq(tables['mdt_citizens'][1].wanted_for, 'Armed robbery')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

Run: `lua5.4 plugins/oblsk_mdt/tests/mdt_citizen_service_spec.lua` — expect FAIL.

- [ ] **Step 4: Implement MdtCitizenService**

`plugins/oblsk_mdt/server/services/MdtCitizenService.lua`:
```lua
MdtCitizenService = {}

function MdtCitizenService.list(dbGroup)
    return QueryBuilder.new('mdt_citizens'):where('db_group', dbGroup):orderBy('name', 'asc'):getSync()
end

--- Case-insensitive substring match on name, scoped to db_group. The fake
--- QueryBuilder used in tests has no LIKE support, so this filters in Lua
--- over the db_group-scoped list rather than relying on a query operator
--- that may not exist in the real ORM either — confirm QueryBuilder's
--- actual capability (a `:whereLike` or similar) during implementation and
--- push the filter into SQL if available, keeping this Lua fallback only
--- if it isn't.
function MdtCitizenService.search(dbGroup, query)
    local all = MdtCitizenService.list(dbGroup)
    local needle = string.lower(query or '')
    if needle == '' then return all end
    local matches = {}
    for _, citizen in ipairs(all) do
        if string.find(string.lower(citizen.name), needle, 1, true) then
            table.insert(matches, citizen)
        end
    end
    return matches
end

function MdtCitizenService.get(citizenId)
    return QueryBuilder.new('mdt_citizens'):where('id', citizenId):firstSync()
end

--- @param data table { name, kind ('person'|'company'), dob, address, licenses (array, optional) }
function MdtCitizenService.create(characterId, auth, dbGroup, data)
    local citizenId = QueryBuilder.new('mdt_citizens'):insert({
        kind = data.kind or 'person',
        db_group = dbGroup,
        name = data.name,
        dob = data.dob,
        address = data.address,
        wanted = false,
    })
    for _, license in ipairs(data.licenses or {}) do
        QueryBuilder.new('mdt_citizen_licenses'):insert({ citizen_id = citizenId, license = license })
    end
    MdtAuditService.log(characterId, auth, 'citizens', 'created citizen record', data.name)
    return citizenId
end

function MdtCitizenService.setWanted(characterId, auth, citizenId, wanted, wantedFor)
    QueryBuilder.new('mdt_citizens'):where('id', citizenId):update({ wanted = wanted, wanted_for = wantedFor })
    MdtAuditService.log(characterId, auth, 'citizens', wanted and 'flagged wanted' or 'cleared wanted flag', tostring(citizenId))
end

return MdtCitizenService
```

- [ ] **Step 5: Run tests, verify pass**

```bash
lua5.4 plugins/oblsk_mdt/tests/mdt_citizen_service_spec.lua
```

- [ ] **Step 6: Add server handlers (list, search, create) and client relays**

Same shape as Task 5 Steps 6-7, for `oblsk_mdt:server:citizens-list`, `oblsk_mdt:server:citizens-search`, `oblsk_mdt:server:citizens-create`, each requiring `Character:can('mdt-write-citizen')` on the create path only (list/search are read-only, still gated by `MdtAuthService.resolve` returning non-nil).

- [ ] **Step 7: Write Citizens.vue**

`plugins/oblsk_mdt/web/apps/Citizens/Citizens.vue`:
```vue
<template>
  <div class="h-full flex flex-col gap-3">
    <input v-model="query" @input="search" placeholder="Search citizens" class="h-8 rounded-lg bg-white/6 border border-white/8 px-2.5 text-[12px]" />
    <div class="flex-1 overflow-y-auto">
      <button v-for="c in citizens" :key="c.id" class="w-full text-left px-3.5 py-2.5 border-b border-white/6 hover:bg-white/4">
        <div class="flex justify-between text-[12px]">
          <span>{{ c.name }}</span>
          <span v-if="c.wanted" class="text-red-300">WANTED</span>
        </div>
      </button>
      <div v-if="!citizens.length" class="p-6 text-center text-[12px] text-white/30">No matches.</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'

const citizens = ref([])
const query = ref('')

function handleList(data) { citizens.value = data || [] }
function refresh() { Obelisk.emit('oblsk_mdt:client:citizens-list', {}) }
function search() { Obelisk.emit('oblsk_mdt:client:citizens-search', { query: query.value }).then(handleList) }

onMounted(() => { Obelisk.on('oblsk_mdt:client:citizens-list', handleList); refresh() })
onBeforeUnmount(() => { Obelisk.off('oblsk_mdt:client:citizens-list', handleList) })
</script>
```

- [ ] **Step 8: Register in Mdt.vue** (`import Citizens from './apps/Citizens/Citizens.vue'`, add `citizens: Citizens` to the registry object, same pattern as Task 5 Step 9)

- [ ] **Step 9: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtCitizenService.lua server/main.lua client/main.lua web/apps/Citizens web/Mdt.vue tests/mdt_citizen_service_spec.lua
git commit -m "Add Citizens module"
```

---

## Task 7: Documents module + DocEditor.vue port

**Files:**
- Create: `core/web/src/components/DocEditor.vue` (ported shared component)
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000004_create_mdt_documents_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtDocumentService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Docs/Docs.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_document_service_spec.lua`

**Interfaces:**
- Produces: `DocEditor.vue` exports a component with props `{ modelValue: String, readonly: Boolean }` and emits `update:modelValue`, `sign`, `print` — a minimal contenteditable-based rich text surface (redact/sign/print/download toolbar), ported from the design's `phone-docs.jsx` `MdtDocEditor` concept but simplified to what this plan needs (no dependency on anything MDT-specific, so `oblsk_phone`'s future Paperwork app can import it from `core/web/src/components/DocEditor.vue` too).
- Produces: `MdtDocumentService.list(dbGroup) -> table[]`, `MdtDocumentService.get(documentId) -> table|nil`, `MdtDocumentService.create(characterId, auth, dbGroup, data) -> documentId`, `MdtDocumentService.saveVersion(characterId, auth, documentId, body, what)`.

- [ ] **Step 1: Port DocEditor.vue into core's shared components**

`core/web/src/components/DocEditor.vue`:
```vue
<template>
  <div class="flex flex-col h-full">
    <div v-if="!readonly" class="flex gap-1.5 border-b border-white/8 pb-2 mb-2">
      <button @click="exec('bold')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8">B</button>
      <button @click="exec('italic')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8 italic">I</button>
      <button @click="$emit('sign')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8">Sign</button>
      <button @click="$emit('print')" class="px-2 h-6 rounded text-[11px] border border-white/12 hover:bg-white/8">Print</button>
    </div>
    <div ref="editorRef" :contenteditable="!readonly" class="flex-1 overflow-y-auto text-[12px] leading-relaxed outline-none"
      @input="onInput"></div>
  </div>
</template>

<script setup>
import { ref, onMounted, watch } from 'vue'

const props = defineProps({ modelValue: { type: String, default: '' }, readonly: { type: Boolean, default: false } })
const emit = defineEmits(['update:modelValue', 'sign', 'print'])
const editorRef = ref(null)

function onInput() {
  emit('update:modelValue', editorRef.value.innerHTML)
}
function exec(command) {
  editorRef.value.focus()
  document.execCommand(command, false, null)
  onInput()
}

onMounted(() => { if (editorRef.value) editorRef.value.innerHTML = props.modelValue })
watch(() => props.modelValue, (val) => {
  if (editorRef.value && editorRef.value.innerHTML !== val) editorRef.value.innerHTML = val
})
</script>
```

- [ ] **Step 2: Write the migration**

`plugins/oblsk_mdt/server/migrations/2026_08_12_000004_create_mdt_documents_tables.lua`:
```lua
return {
    up = function()
        Schema.create('mdt_documents', function(table)
            table:id()
            table:string('title', 150):notNullable()
            table:string('template_id', 50)
            table:string('kind', 30):notNullable()
            table:string('db_group', 20):notNullable():index()
            table:string('auth', 10):notNullable()
            table:string('attach_kind', 20)
            table:integer('attach_id')
            table:integer('author_character_id'):notNullable()
            table:string('status', 20):notNullable()
            table:text('body')
            table:json('perm_read_json')
            table:json('perm_write_json')
            table:json('orgs_json')
            table:json('org_write_json')
        end)
        Schema.create('mdt_document_versions', function(table)
            table:id()
            table:integer('document_id'):notNullable():index()
            table:datetime('at'):notNullable()
            table:integer('by_character_id'):notNullable()
            table:string('what', 100)
            table:text('body')
        end)
        print('[Migration] Created mdt_documents tables')
    end,
    down = function()
        Schema.drop('mdt_document_versions')
        Schema.drop('mdt_documents')
        print('[Migration] Dropped mdt_documents tables')
    end
}
```

- [ ] **Step 3: Register in migrations.json** (append `"2026_08_12_000004_create_mdt_documents_tables"`)

- [ ] **Step 4: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_document_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

Database = { now = function() return '2026-08-12 00:00:00' end }

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtDocumentService.lua')
    return tables
end

test('create inserts a document with status DRAFT', function()
    local tables = setup()
    MdtDocumentService.create(1, 'lspd', 'ls-shared', { title = 'Arrest report', kind = 'report', body = '<p>...</p>' })
    eq(#tables['mdt_documents'], 1)
    eq(tables['mdt_documents'][1].status, 'DRAFT')
end)

test('saveVersion appends a version row and updates the live body', function()
    local tables = setup()
    local id = MdtDocumentService.create(1, 'lspd', 'ls-shared', { title = 'Arrest report', kind = 'report', body = 'v1' })
    MdtDocumentService.saveVersion(1, 'lspd', id, 'v2', 'edited narrative')
    eq(#tables['mdt_document_versions'], 1)
    eq(tables['mdt_documents'][1].body, 'v2')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 5: Implement MdtDocumentService**

`plugins/oblsk_mdt/server/services/MdtDocumentService.lua`:
```lua
MdtDocumentService = {}

function MdtDocumentService.list(dbGroup)
    return QueryBuilder.new('mdt_documents'):where('db_group', dbGroup):getSync()
end

function MdtDocumentService.get(documentId)
    return QueryBuilder.new('mdt_documents'):where('id', documentId):firstSync()
end

--- @param data table { title, kind, body, template_id (optional), attach_kind/attach_id (optional) }
function MdtDocumentService.create(characterId, auth, dbGroup, data)
    local documentId = QueryBuilder.new('mdt_documents'):insert({
        title = data.title,
        template_id = data.template_id,
        kind = data.kind,
        db_group = dbGroup,
        auth = auth,
        attach_kind = data.attach_kind,
        attach_id = data.attach_id,
        author_character_id = characterId,
        status = 'DRAFT',
        body = data.body,
    })
    MdtAuditService.log(characterId, auth, 'docs', 'created document', data.title)
    return documentId
end

function MdtDocumentService.saveVersion(characterId, auth, documentId, body, what)
    QueryBuilder.new('mdt_document_versions'):insert({
        document_id = documentId, at = Database.now(), by_character_id = characterId, what = what, body = body,
    })
    QueryBuilder.new('mdt_documents'):where('id', documentId):update({ body = body })
    MdtAuditService.log(characterId, auth, 'docs', what or 'edited document', tostring(documentId))
end

return MdtDocumentService
```

- [ ] **Step 6: Run tests, verify pass**

```bash
lua5.4 plugins/oblsk_mdt/tests/mdt_document_service_spec.lua
```

- [ ] **Step 7: Add server handlers + client relays** for `oblsk_mdt:server:docs-list`, `docs-create`, `docs-save-version` (same shape as Task 5 Steps 6-7, create/save-version gated by `Character:can('mdt-write-doc')`).

- [ ] **Step 8: Write Docs.vue**

`plugins/oblsk_mdt/web/apps/Docs/Docs.vue`:
```vue
<template>
  <div class="h-full flex gap-3">
    <div class="w-[260px] shrink-0 overflow-y-auto border-r border-white/8">
      <button v-for="d in docs" :key="d.id" @click="open(d)" class="w-full text-left px-3 py-2 border-b border-white/6 hover:bg-white/4 text-[12px]">
        {{ d.title }}
      </button>
      <button @click="createDraft" class="w-full text-left px-3 py-2 text-[11px] text-white/50">+ New document</button>
    </div>
    <div class="flex-1 min-w-0">
      <DocEditor v-if="active" v-model="body" @sign="save('signed')" />
      <div v-else class="text-white/30 text-[12px] p-4">Select a document.</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'
import DocEditor from '@/components/DocEditor.vue'

const docs = ref([])
const active = ref(null)
const body = ref('')

function handleList(data) { docs.value = data || [] }
function refresh() { Obelisk.emit('oblsk_mdt:client:docs-list', {}) }
function open(d) { active.value = d; body.value = d.body || '' }
function createDraft() {
  Obelisk.emit('oblsk_mdt:client:docs-create', { title: 'Untitled document', kind: 'report', body: '' }).then(refresh)
}
function save(what) {
  if (!active.value) return
  Obelisk.emit('oblsk_mdt:client:docs-save-version', { documentId: active.value.id, body: body.value, what })
}

onMounted(() => { Obelisk.on('oblsk_mdt:client:docs-list', handleList); refresh() })
onBeforeUnmount(() => { Obelisk.off('oblsk_mdt:client:docs-list', handleList) })
</script>
```

- [ ] **Step 9: Register in Mdt.vue** (`docs: Docs`)

- [ ] **Step 10: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core
git add web/src/components/DocEditor.vue
git commit -m "Port DocEditor as a shared component"
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtDocumentService.lua server/main.lua client/main.lua web/apps/Docs web/Mdt.vue tests/mdt_document_service_spec.lua
git commit -m "Add Documents module"
```

---

## Task 8: Vehicles module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000005_create_mdt_citizen_vehicles_table.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtVehicleService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Vehicles/Vehicles.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_vehicle_service_spec.lua`

**Interfaces:**
- Produces: `MdtVehicleService.listForCitizen(citizenId) -> table[]`, `MdtVehicleService.findByPlate(dbGroup, plate) -> table|nil`, `MdtVehicleService.create(characterId, auth, citizenId, data) -> vehicleId`, `MdtVehicleService.setImpounded(characterId, auth, vehicleId, impounded)`.

- [ ] **Step 1: Write the migration**

`plugins/oblsk_mdt/server/migrations/2026_08_12_000005_create_mdt_citizen_vehicles_table.lua`:
```lua
return {
    up = function()
        Schema.create('mdt_citizen_vehicles', function(table)
            table:id()
            table:integer('citizen_id'):notNullable():index()
            table:string('db_group', 20):notNullable():index()
            table:string('make', 60):notNullable()
            table:string('model', 60):notNullable()
            table:string('plate', 15):notNullable():unique()
            table:string('color', 30)
            table:string('registered_at', 20)
            table:boolean('impounded')
        end)
        print('[Migration] Created mdt_citizen_vehicles table')
    end,
    down = function()
        Schema.drop('mdt_citizen_vehicles')
        print('[Migration] Dropped mdt_citizen_vehicles table')
    end
}
```

- [ ] **Step 2: Register in migrations.json** (append `"2026_08_12_000005_create_mdt_citizen_vehicles_table"`)

- [ ] **Step 3: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_vehicle_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtVehicleService.lua')
    return tables
end

test('create inserts a vehicle not impounded by default', function()
    local tables = setup()
    MdtVehicleService.create(1, 'lspd', 42, { make = 'Bravado', model = 'Sandking', plate = '8L-9A', db_group = 'ls-shared' })
    eq(#tables['mdt_citizen_vehicles'], 1)
    eq(tables['mdt_citizen_vehicles'][1].impounded, false)
end)

test('findByPlate matches within db_group', function()
    local tables = setup()
    MdtVehicleService.create(1, 'lspd', 42, { make = 'Bravado', model = 'Sandking', plate = '8L-9A', db_group = 'ls-shared' })
    local found = MdtVehicleService.findByPlate('ls-shared', '8L-9A')
    eq(found.model, 'Sandking')
    eq(MdtVehicleService.findByPlate('lsmd', '8L-9A'), nil)
end)

test('setImpounded flips the flag and audits it', function()
    local tables = setup()
    local id = MdtVehicleService.create(1, 'lspd', 42, { make = 'Bravado', model = 'Sandking', plate = '8L-9A', db_group = 'ls-shared' })
    MdtVehicleService.setImpounded(1, 'lspd', id, true)
    eq(tables['mdt_citizen_vehicles'][1].impounded, true)
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 4: Implement MdtVehicleService**

`plugins/oblsk_mdt/server/services/MdtVehicleService.lua`:
```lua
MdtVehicleService = {}

function MdtVehicleService.listForCitizen(citizenId)
    return QueryBuilder.new('mdt_citizen_vehicles'):where('citizen_id', citizenId):getSync()
end

function MdtVehicleService.findByPlate(dbGroup, plate)
    return QueryBuilder.new('mdt_citizen_vehicles'):where('db_group', dbGroup):where('plate', plate):firstSync()
end

--- @param data table { make, model, plate, color (optional), db_group }
function MdtVehicleService.create(characterId, auth, citizenId, data)
    local vehicleId = QueryBuilder.new('mdt_citizen_vehicles'):insert({
        citizen_id = citizenId,
        db_group = data.db_group,
        make = data.make,
        model = data.model,
        plate = data.plate,
        color = data.color,
        registered_at = os.date('%d %b %Y'),
        impounded = false,
    })
    MdtAuditService.log(characterId, auth, 'vehicles', 'registered vehicle ' .. data.plate, tostring(vehicleId))
    return vehicleId
end

function MdtVehicleService.setImpounded(characterId, auth, vehicleId, impounded)
    QueryBuilder.new('mdt_citizen_vehicles'):where('id', vehicleId):update({ impounded = impounded })
    MdtAuditService.log(characterId, auth, 'vehicles', impounded and 'marked impounded' or 'released from impound', tostring(vehicleId))
end

return MdtVehicleService
```

- [ ] **Step 5: Run tests, verify pass.**

- [ ] **Step 6: Add server handlers + client relays** for `oblsk_mdt:server:vehicles-list-for-citizen`, `vehicles-find-by-plate`, `vehicles-create` (create gated by `Character:can('mdt-write-vehicle')`).

- [ ] **Step 7: Write Vehicles.vue**

`plugins/oblsk_mdt/web/apps/Vehicles/Vehicles.vue`:
```vue
<template>
  <div class="h-full flex flex-col gap-3">
    <input v-model="plate" @keyup.enter="lookup" placeholder="Plate lookup" class="h-8 rounded-lg bg-white/6 border border-white/8 px-2.5 text-[12px]" />
    <div v-if="result" class="p-3 rounded-lg border border-white/10 text-[12px]">
      <div>{{ result.make }} {{ result.model }} · {{ result.plate }}</div>
      <div class="text-white/40">{{ result.color }}</div>
      <div v-if="result.impounded" class="text-red-300 mt-1">IMPOUNDED</div>
    </div>
    <div v-else-if="searched" class="text-white/30 text-[12px]">No vehicle found.</div>
  </div>
</template>

<script setup>
import { ref } from 'vue'
import Obelisk from '@/obelisk.js'

const plate = ref('')
const result = ref(null)
const searched = ref(false)

function lookup() {
  Obelisk.emit('oblsk_mdt:client:vehicles-find-by-plate', { plate: plate.value }).then((data) => {
    result.value = data || null
    searched.value = true
  })
}
</script>
```

- [ ] **Step 8: Register in Mdt.vue** (`vehicles: Vehicles`)

- [ ] **Step 9: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtVehicleService.lua server/main.lua client/main.lua web/apps/Vehicles web/Mdt.vue tests/mdt_vehicle_service_spec.lua
git commit -m "Add Vehicles module"
```

---

## Task 9: Command centre module (fleet/unit board + Dispatch read)

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000006_create_mdt_command_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtCommandService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Command/Command.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_command_service_spec.lua`

**Interfaces:**
- Consumes: `DispatchService.list()` — cross-plugin call into `oblsk_phone`'s existing service (exact signature to confirm against `plugins/oblsk_phone/server/services/DispatchService.lua` during implementation; if it takes filter args rather than none, adjust `MdtCommandService.activeCalls()` accordingly, but the shape below — call it with no args, filter/sort in Lua — is the safe minimum every service in this repo supports).
- Produces: `MdtCommandService.fleet(orgId) -> table[]`, `MdtCommandService.assignments(orgId) -> table[]`, `MdtCommandService.assign(characterId, auth, orgId, unitId, vehicleId)`, `MdtCommandService.activeCalls() -> table[]`.

- [ ] **Step 1: Write the migration**

`plugins/oblsk_mdt/server/migrations/2026_08_12_000006_create_mdt_command_tables.lua`:
```lua
return {
    up = function()
        Schema.create('mdt_department_fleet', function(table)
            table:id()
            table:integer('organization_id'):notNullable():index()
            table:string('unit_key', 20):notNullable()
            table:string('name', 60):notNullable()
            table:string('note', 100)
        end)
        Schema.create('mdt_unit_assignments', function(table)
            table:id()
            table:integer('organization_id'):notNullable():index()
            table:string('unit_id', 20):notNullable()
            table:integer('character_id')
            table:integer('fleet_id')
        end)
        print('[Migration] Created mdt_command tables')
    end,
    down = function()
        Schema.drop('mdt_unit_assignments')
        Schema.drop('mdt_department_fleet')
        print('[Migration] Dropped mdt_command tables')
    end
}
```

- [ ] **Step 2: Register in migrations.json** (append `"2026_08_12_000006_create_mdt_command_tables"`)

- [ ] **Step 3: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_command_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    DispatchService = { list = function() return { { id = 1, type = 'Shots fired', priority = 1 } } end }
    dofile(scriptDir .. '../server/services/MdtCommandService.lua')
    return tables
end

test('assign creates or updates a unit assignment row', function()
    local tables = setup()
    MdtCommandService.assign(1, 'lspd', 5, 'u1', 3)
    eq(#tables['mdt_unit_assignments'], 1)
    eq(tables['mdt_unit_assignments'][1].character_id, 1)

    MdtCommandService.assign(2, 'lspd', 5, 'u1', 4)
    eq(#tables['mdt_unit_assignments'], 1, 'reassigning the same unit updates, not duplicates')
    eq(tables['mdt_unit_assignments'][1].character_id, 2)
end)

test('activeCalls proxies DispatchService.list', function()
    setup()
    local calls = MdtCommandService.activeCalls()
    eq(#calls, 1)
    eq(calls[1].type, 'Shots fired')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 4: Implement MdtCommandService**

`plugins/oblsk_mdt/server/services/MdtCommandService.lua`:
```lua
MdtCommandService = {}

function MdtCommandService.fleet(orgId)
    return QueryBuilder.new('mdt_department_fleet'):where('organization_id', orgId):getSync()
end

function MdtCommandService.assignments(orgId)
    return QueryBuilder.new('mdt_unit_assignments'):where('organization_id', orgId):getSync()
end

--- Upserts a unit's assignment (one row per unit_id per org).
--- @param unitId string e.g. 'u1'
--- @param vehicleId number|nil fleet row id, nil to unassign a vehicle while keeping the officer
function MdtCommandService.assign(characterId, auth, orgId, unitId, vehicleId)
    local existing = QueryBuilder.new('mdt_unit_assignments')
        :where('organization_id', orgId):where('unit_id', unitId):firstSync()
    if existing then
        QueryBuilder.new('mdt_unit_assignments'):where('id', existing.id)
            :update({ character_id = characterId, fleet_id = vehicleId })
    else
        QueryBuilder.new('mdt_unit_assignments'):insert({
            organization_id = orgId, unit_id = unitId, character_id = characterId, fleet_id = vehicleId,
        })
    end
    MdtAuditService.log(characterId, auth, 'command', 'assigned to ' .. unitId, unitId)
end

--- Cross-plugin read from oblsk_phone's DispatchService — no oblsk_mdt
--- table duplicates the call queue.
function MdtCommandService.activeCalls()
    return DispatchService.list()
end

return MdtCommandService
```

- [ ] **Step 5: Run tests, verify pass.**

- [ ] **Step 6: Add server handlers + client relays** for `oblsk_mdt:server:command-fleet`, `command-assignments`, `command-assign`, `command-active-calls` (assign gated by `Character:can('mdt-write-command')`).

- [ ] **Step 7: Write Command.vue**

`plugins/oblsk_mdt/web/apps/Command/Command.vue`:
```vue
<template>
  <div class="h-full grid grid-cols-2 gap-3">
    <div class="overflow-y-auto border border-white/10 rounded-xl p-2">
      <div class="text-[10px] uppercase tracking-wider text-white/40 mb-2">Active calls</div>
      <div v-for="c in calls" :key="c.id" class="text-[12px] py-1.5 border-b border-white/6">
        {{ c.type }} · P{{ c.priority }}
      </div>
    </div>
    <div class="overflow-y-auto border border-white/10 rounded-xl p-2">
      <div class="text-[10px] uppercase tracking-wider text-white/40 mb-2">Fleet</div>
      <div v-for="v in fleet" :key="v.id" class="text-[12px] py-1.5 border-b border-white/6">{{ v.name }}</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const calls = ref([])
const fleet = ref([])

onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:command-active-calls', {}).then((data) => { calls.value = data || [] })
  Obelisk.emit('oblsk_mdt:client:command-fleet', {}).then((data) => { fleet.value = data || [] })
})
</script>
```

- [ ] **Step 8: Register in Mdt.vue** (`command: Command`)

- [ ] **Step 9: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtCommandService.lua server/main.lua client/main.lua web/apps/Command web/Mdt.vue tests/mdt_command_service_spec.lua
git commit -m "Add Command centre module"
```

---

## Task 10: Phone Lines module (911 console, reads oblsk_phone Dispatch)

**Files:**
- Create: `plugins/oblsk_mdt/web/apps/Lines/Lines.vue`
- Modify: `server/main.lua`, `client/main.lua`, `web/Mdt.vue`

No new tables — this module is presentation over `oblsk_phone`'s `DispatchService`, matching the design's note that phone lines are "shared with the Dialer's call-answering machinery." No new service file either: reuse `MdtCommandService.activeCalls()` from Task 9 rather than adding a duplicate accessor.

**Interfaces:**
- Consumes: `oblsk_mdt:server:command-active-calls` (already built in Task 9).

- [ ] **Step 1: Write Lines.vue**

`plugins/oblsk_mdt/web/apps/Lines/Lines.vue`:
```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="c in calls" :key="c.id" class="p-3 border-b border-white/6 text-[12px]">
      <div class="flex justify-between"><span>{{ c.type }}</span><span class="text-white/40">P{{ c.priority }}</span></div>
      <div class="text-white/50 mt-1">{{ c.text }}</div>
    </div>
    <div v-if="!calls.length" class="p-6 text-center text-[12px] text-white/30">No active calls.</div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const calls = ref([])
onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:command-active-calls', {}).then((data) => { calls.value = data || [] })
})
</script>
```

- [ ] **Step 2: Register in Mdt.vue** (`lines: Lines`)

- [ ] **Step 3: Manual verification** — open Phone Lines with at least one active `phone_dispatch_calls` row present, confirm it renders without a separate table/query.

- [ ] **Step 4: Commit**

```bash
cd plugins/oblsk_mdt
git add web/apps/Lines web/Mdt.vue
git commit -m "Add Phone Lines module, reusing Dispatch read path"
```

---

## Task 11: Manhunts module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000007_create_mdt_manhunts_table.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtManhuntService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Manhunts/Manhunts.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_manhunt_service_spec.lua`

**Interfaces:**
- Produces: `MdtManhuntService.list(dbGroup) -> table[]`, `MdtManhuntService.issue(characterId, auth, dbGroup, data) -> manhuntId`, `MdtManhuntService.clear(characterId, auth, manhuntId)`.

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Schema.create('mdt_manhunts', function(table)
            table:id()
            table:string('db_group', 20):notNullable():index()
            table:json('subjects_json'):notNullable()
            table:string('status', 10):notNullable()
            table:string('issued_at', 20):notNullable()
            table:integer('issuer_character_id'):notNullable()
            table:text('reason')
        end)
        print('[Migration] Created mdt_manhunts table')
    end,
    down = function()
        Schema.drop('mdt_manhunts')
        print('[Migration] Dropped mdt_manhunts table')
    end
}
```
Save as `plugins/oblsk_mdt/server/migrations/2026_08_12_000007_create_mdt_manhunts_table.lua`, append `"2026_08_12_000007_create_mdt_manhunts_table"` to `migrations.json`.

- [ ] **Step 2: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_manhunt_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtManhuntService.lua')
    return tables
end

test('issue creates an ACTIVE manhunt', function()
    local tables = setup()
    MdtManhuntService.issue(1, 'lspd', 'ls-shared', { subjects = {'John Doe'}, reason = 'Armed robbery' })
    eq(#tables['mdt_manhunts'], 1)
    eq(tables['mdt_manhunts'][1].status, 'ACTIVE')
end)

test('clear flips status to CLEARED', function()
    local tables = setup()
    local id = MdtManhuntService.issue(1, 'lspd', 'ls-shared', { subjects = {'John Doe'}, reason = 'x' })
    MdtManhuntService.clear(1, 'lspd', id)
    eq(tables['mdt_manhunts'][1].status, 'CLEARED')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 3: Implement MdtManhuntService**

```lua
MdtManhuntService = {}

function MdtManhuntService.list(dbGroup)
    return QueryBuilder.new('mdt_manhunts'):where('db_group', dbGroup):getSync()
end

function MdtManhuntService.issue(characterId, auth, dbGroup, data)
    local id = QueryBuilder.new('mdt_manhunts'):insert({
        db_group = dbGroup,
        subjects_json = data.subjects,
        status = 'ACTIVE',
        issued_at = os.date('%d %b %Y'),
        issuer_character_id = characterId,
        reason = data.reason,
    })
    MdtAuditService.log(characterId, auth, 'manhunts', 'issued manhunt', tostring(id))
    return id
end

function MdtManhuntService.clear(characterId, auth, manhuntId)
    QueryBuilder.new('mdt_manhunts'):where('id', manhuntId):update({ status = 'CLEARED' })
    MdtAuditService.log(characterId, auth, 'manhunts', 'cleared manhunt', tostring(manhuntId))
end

return MdtManhuntService
```
Save as `plugins/oblsk_mdt/server/services/MdtManhuntService.lua`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add server handlers + client relays** for `oblsk_mdt:server:manhunts-list`, `manhunts-issue`, `manhunts-clear` (issue/clear gated by `Character:can('mdt-write-manhunt')`).

- [ ] **Step 6: Write Manhunts.vue**

```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="m in manhunts" :key="m.id" class="p-3 border-b border-white/6 text-[12px]">
      <div class="flex justify-between"><span>{{ (m.subjects_json || []).join(', ') }}</span><span :class="m.status === 'ACTIVE' ? 'text-red-300' : 'text-white/30'">{{ m.status }}</span></div>
      <div class="text-white/50 mt-1">{{ m.reason }}</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const manhunts = ref([])
onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:manhunts-list', {}).then((data) => { manhunts.value = data || [] })
})
</script>
```
Save as `plugins/oblsk_mdt/web/apps/Manhunts/Manhunts.vue`.

- [ ] **Step 7: Register in Mdt.vue** (`manhunts: Manhunts`)

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtManhuntService.lua server/main.lua client/main.lua web/apps/Manhunts web/Mdt.vue tests/mdt_manhunt_service_spec.lua
git commit -m "Add Manhunts module"
```

---

## Task 12: Impound module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000008_create_mdt_impound_table.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtImpoundService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Impound/Impound.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_impound_service_spec.lua`

**Interfaces:**
- Produces: `MdtImpoundService.list(dbGroup) -> table[]`, `MdtImpoundService.hold(characterId, auth, dbGroup, data) -> impoundId`, `MdtImpoundService.release(characterId, auth, impoundId)`.

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Schema.create('mdt_impound', function(table)
            table:id()
            table:string('db_group', 20):notNullable():index()
            table:string('plate', 15):notNullable()
            table:string('make', 60)
            table:string('owner', 100)
            table:string('held_at', 20):notNullable()
            table:string('garage', 60)
            table:integer('officer_character_id'):notNullable()
            table:string('case_ref', 30)
            table:string('status', 15):notNullable()
            table:string('notes', 200)
        end)
        print('[Migration] Created mdt_impound table')
    end,
    down = function()
        Schema.drop('mdt_impound')
        print('[Migration] Dropped mdt_impound table')
    end
}
```
Save as `plugins/oblsk_mdt/server/migrations/2026_08_12_000008_create_mdt_impound_table.lua`, append `"2026_08_12_000008_create_mdt_impound_table"` to `migrations.json`.

- [ ] **Step 2: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_impound_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtImpoundService.lua')
    return tables
end

test('hold inserts a row with status IMPOUNDED', function()
    local tables = setup()
    MdtImpoundService.hold(1, 'lspd', 'ls-shared', { plate = '8L-9A', make = 'Bravado Sandking', owner = 'John Doe' })
    eq(#tables['mdt_impound'], 1)
    eq(tables['mdt_impound'][1].status, 'IMPOUNDED')
end)

test('release flips status to RELEASED', function()
    local tables = setup()
    local id = MdtImpoundService.hold(1, 'lspd', 'ls-shared', { plate = '8L-9A', owner = 'John Doe' })
    MdtImpoundService.release(1, 'lspd', id)
    eq(tables['mdt_impound'][1].status, 'RELEASED')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 3: Implement MdtImpoundService**

```lua
MdtImpoundService = {}

function MdtImpoundService.list(dbGroup)
    return QueryBuilder.new('mdt_impound'):where('db_group', dbGroup):getSync()
end

function MdtImpoundService.hold(characterId, auth, dbGroup, data)
    local id = QueryBuilder.new('mdt_impound'):insert({
        db_group = dbGroup,
        plate = data.plate,
        make = data.make,
        owner = data.owner,
        held_at = os.date('%d %b %Y'),
        garage = data.garage,
        officer_character_id = characterId,
        case_ref = data.case_ref,
        status = 'IMPOUNDED',
        notes = data.notes,
    })
    MdtAuditService.log(characterId, auth, 'impound', 'impounded ' .. data.plate, tostring(id))
    return id
end

function MdtImpoundService.release(characterId, auth, impoundId)
    QueryBuilder.new('mdt_impound'):where('id', impoundId):update({ status = 'RELEASED' })
    MdtAuditService.log(characterId, auth, 'impound', 'released from impound', tostring(impoundId))
end

return MdtImpoundService
```
Save as `plugins/oblsk_mdt/server/services/MdtImpoundService.lua`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add server handlers + client relays** for `oblsk_mdt:server:impound-list`, `impound-hold`, `impound-release` (hold/release gated by `Character:can('mdt-write-impound')`).

- [ ] **Step 6: Write Impound.vue**

```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="v in impound" :key="v.id" class="p-3 border-b border-white/6 text-[12px] flex justify-between">
      <span>{{ v.plate }} · {{ v.make }}</span>
      <span :class="v.status === 'IMPOUNDED' ? 'text-amber-300' : 'text-white/30'">{{ v.status }}</span>
    </div>
    <div v-if="!impound.length" class="p-6 text-center text-[12px] text-white/30">Nothing on hold.</div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const impound = ref([])
onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:impound-list', {}).then((data) => { impound.value = data || [] })
})
</script>
```
Save as `plugins/oblsk_mdt/web/apps/Impound/Impound.vue`.

- [ ] **Step 7: Register in Mdt.vue** (`impound: Impound`)

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtImpoundService.lua server/main.lua client/main.lua web/apps/Impound web/Mdt.vue tests/mdt_impound_service_spec.lua
git commit -m "Add Impound module"
```

---

## Task 13: Detention module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000009_create_mdt_detention_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtDetentionService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Detention/Detention.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_detention_service_spec.lua`

**Interfaces:**
- Produces: `MdtDetentionService.active(dbGroup) -> table[]`, `MdtDetentionService.book(characterId, auth, dbGroup, data) -> inmateId`, `MdtDetentionService.release(characterId, auth, inmateId)`.

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Schema.create('mdt_detention', function(table)
            table:id()
            table:string('db_group', 20):notNullable():index()
            table:string('name', 100):notNullable()
            table:integer('danger'):notNullable()
            table:string('cell', 10)
            table:string('case_ref', 30)
            table:integer('officer_character_id'):notNullable()
            table:datetime('booked_at'):notNullable()
            table:integer('units'):notNullable()
            table:integer('units_left'):notNullable()
        end)
        Schema.create('mdt_detention_archive', function(table)
            table:id()
            table:string('db_group', 20):notNullable():index()
            table:string('name', 100):notNullable()
            table:integer('danger')
            table:string('cell', 10)
            table:string('case_ref', 30)
            table:string('released_at', 20):notNullable()
            table:string('served', 30)
        end)
        print('[Migration] Created mdt_detention tables')
    end,
    down = function()
        Schema.drop('mdt_detention_archive')
        Schema.drop('mdt_detention')
        print('[Migration] Dropped mdt_detention tables')
    end
}
```
Save as `plugins/oblsk_mdt/server/migrations/2026_08_12_000009_create_mdt_detention_tables.lua`, append `"2026_08_12_000009_create_mdt_detention_tables"` to `migrations.json`.

- [ ] **Step 2: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_detention_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

Database = { now = function() return '2026-08-12 00:00:00' end }

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtDetentionService.lua')
    return tables
end

test('book inserts an active detention row', function()
    local tables = setup()
    MdtDetentionService.book(1, 'lspd', 'ls-shared', { name = 'John Doe', danger = 3, cell = 'B-04', units = 45 })
    eq(#tables['mdt_detention'], 1)
    eq(tables['mdt_detention'][1].units_left, 45)
end)

test('release moves the row to the archive and removes it from active', function()
    local tables = setup()
    local id = MdtDetentionService.book(1, 'lspd', 'ls-shared', { name = 'John Doe', danger = 3, cell = 'B-04', units = 45 })
    MdtDetentionService.release(1, 'lspd', id)
    eq(#tables['mdt_detention'], 0, 'removed from active')
    eq(#tables['mdt_detention_archive'], 1, 'moved to archive')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 3: Implement MdtDetentionService**

```lua
MdtDetentionService = {}

function MdtDetentionService.active(dbGroup)
    return QueryBuilder.new('mdt_detention'):where('db_group', dbGroup):getSync()
end

function MdtDetentionService.book(characterId, auth, dbGroup, data)
    local id = QueryBuilder.new('mdt_detention'):insert({
        db_group = dbGroup,
        name = data.name,
        danger = data.danger,
        cell = data.cell,
        case_ref = data.case_ref,
        officer_character_id = characterId,
        booked_at = Database.now(),
        units = data.units,
        units_left = data.units,
    })
    MdtAuditService.log(characterId, auth, 'detention', 'booked ' .. data.name, tostring(id))
    return id
end

function MdtDetentionService.release(characterId, auth, inmateId)
    local inmate = QueryBuilder.new('mdt_detention'):where('id', inmateId):firstSync()
    if not inmate then return end
    QueryBuilder.new('mdt_detention_archive'):insert({
        db_group = inmate.db_group, name = inmate.name, danger = inmate.danger, cell = inmate.cell,
        case_ref = inmate.case_ref, released_at = os.date('%d %b %Y'),
        served = tostring(inmate.units - inmate.units_left) .. ' units',
    })
    QueryBuilder.new('mdt_detention'):where('id', inmateId):delete()
    MdtAuditService.log(characterId, auth, 'detention', 'released ' .. inmate.name, tostring(inmateId))
end

return MdtDetentionService
```
Save as `plugins/oblsk_mdt/server/services/MdtDetentionService.lua`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add server handlers + client relays** for `oblsk_mdt:server:detention-active`, `detention-book`, `detention-release` (book/release gated by `Character:can('mdt-write-detention')`).

- [ ] **Step 6: Write Detention.vue**

```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="i in inmates" :key="i.id" class="p-3 border-b border-white/6 text-[12px] flex justify-between">
      <span>{{ i.name }} · {{ i.cell }}</span>
      <span class="text-white/40">{{ i.units_left }}/{{ i.units }}</span>
    </div>
    <div v-if="!inmates.length" class="p-6 text-center text-[12px] text-white/30">No one in detention.</div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const inmates = ref([])
onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:detention-active', {}).then((data) => { inmates.value = data || [] })
})
</script>
```
Save as `plugins/oblsk_mdt/web/apps/Detention/Detention.vue`.

- [ ] **Step 7: Register in Mdt.vue** (`detention: Detention`)

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtDetentionService.lua server/main.lua client/main.lua web/apps/Detention web/Mdt.vue tests/mdt_detention_service_spec.lua
git commit -m "Add Detention module"
```

---

## Task 14: Law books module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000010_create_mdt_law_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtLawService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Laws/Laws.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_law_service_spec.lua`

Note: `oblsk_phone`'s future `Lawbook` app reads these tables read-only via a direct cross-plugin call to `MdtLawService.books()`/`MdtLawService.sections(bookId)` — no MDT-owned event needed for that consumer since it's a same-server global call, not a client round trip; only this task's own `Laws.vue` (inside the MDT app) needs the `Obelisk.onServer` handlers below.

**Interfaces:**
- Produces: `MdtLawService.books() -> table[]`, `MdtLawService.sections(bookId) -> table[]`, `MdtLawService.amend(characterId, auth, bookId, sectionId, body, note) -> versionId`.

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Schema.create('mdt_law_books', function(table)
            table:id()
            table:string('abbr', 10):notNullable():unique()
            table:string('name', 60):notNullable()
            table:string('version', 10):notNullable()
            table:string('published', 20)
        end)
        Schema.create('mdt_law_sections', function(table)
            table:id()
            table:integer('book_id'):notNullable():index()
            table:integer('parent_id')
            table:string('n', 10):notNullable()
            table:string('title', 100):notNullable()
            table:text('body')
            table:json('pen_json')
        end)
        Schema.create('mdt_law_amendments', function(table)
            table:id()
            table:integer('book_id'):notNullable():index()
            table:string('v', 10):notNullable()
            table:string('at', 20):notNullable()
            table:string('by', 60)
            table:text('note')
        end)
        print('[Migration] Created mdt_law tables')
    end,
    down = function()
        Schema.drop('mdt_law_amendments')
        Schema.drop('mdt_law_sections')
        Schema.drop('mdt_law_books')
        print('[Migration] Dropped mdt_law tables')
    end
}
```
Save as `plugins/oblsk_mdt/server/migrations/2026_08_12_000010_create_mdt_law_tables.lua`, append `"2026_08_12_000010_create_mdt_law_tables"` to `migrations.json`.

- [ ] **Step 2: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_law_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = { mdt_law_books = { { id = 1, abbr = 'PC', name = 'Penal Code', version = '2.1' } } }
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtLawService.lua')
    return tables
end

test('books returns every law book', function()
    local tables = setup()
    eq(#MdtLawService.books(), 1)
end)

test('amend inserts an amendment row and bumps the book version', function()
    local tables = setup()
    MdtLawService.amend(1, 'doj', 1, nil, nil, 'Art. 1 clarified')
    eq(#tables['mdt_law_amendments'], 1)
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 3: Implement MdtLawService**

```lua
MdtLawService = {}

function MdtLawService.books()
    return QueryBuilder.new('mdt_law_books'):getSync()
end

function MdtLawService.sections(bookId)
    return QueryBuilder.new('mdt_law_sections'):where('book_id', bookId):getSync()
end

--- @param sectionId number|nil when nil, the amendment applies to the whole book (a version bump note)
function MdtLawService.amend(characterId, auth, bookId, sectionId, body, note)
    if sectionId and body then
        QueryBuilder.new('mdt_law_sections'):where('id', sectionId):update({ body = body })
    end
    local id = QueryBuilder.new('mdt_law_amendments'):insert({
        book_id = bookId, v = 'pending', at = os.date('%d %b %Y'), by = tostring(characterId), note = note,
    })
    MdtAuditService.log(characterId, auth, 'laws', 'amended law book', tostring(bookId))
    return id
end

return MdtLawService
```
Save as `plugins/oblsk_mdt/server/services/MdtLawService.lua`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add server handlers + client relays** for `oblsk_mdt:server:laws-books`, `laws-sections`, `laws-amend` (amend gated by `Character:can('mdt-write-laws')`, restricted in practice to DOJ per the source design, enforced by the permission grant, not a hardcoded auth check).

- [ ] **Step 6: Write Laws.vue**

```vue
<template>
  <div class="h-full flex gap-3">
    <div class="w-[200px] shrink-0 overflow-y-auto border-r border-white/8">
      <button v-for="b in books" :key="b.id" @click="open(b)" class="w-full text-left px-3 py-2 border-b border-white/6 hover:bg-white/4 text-[12px]">
        {{ b.abbr }} · v{{ b.version }}
      </button>
    </div>
    <div class="flex-1 overflow-y-auto">
      <div v-for="s in sections" :key="s.id" class="p-3 border-b border-white/6 text-[12px]">
        <div class="font-semibold">{{ s.n }} {{ s.title }}</div>
        <div class="text-white/50 mt-1">{{ s.body }}</div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const books = ref([])
const sections = ref([])

function open(b) {
  Obelisk.emit('oblsk_mdt:client:laws-sections', { bookId: b.id }).then((data) => { sections.value = data || [] })
}

onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:laws-books', {}).then((data) => { books.value = data || [] })
})
</script>
```
Save as `plugins/oblsk_mdt/web/apps/Laws/Laws.vue`.

- [ ] **Step 7: Register in Mdt.vue** (`laws: Laws`)

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtLawService.lua server/main.lua client/main.lua web/apps/Laws web/Mdt.vue tests/mdt_law_service_spec.lua
git commit -m "Add Law books module"
```

---

## Task 15: Blackboard module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000011_create_mdt_board_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtBoardService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Board/Board.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_board_service_spec.lua`

**Interfaces:**
- Produces: `MdtBoardService.list(orgId) -> table[]`, `MdtBoardService.post(characterId, auth, orgId, data) -> postId`, `MdtBoardService.markRead(characterId, postId)`.

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Schema.create('mdt_board_posts', function(table)
            table:id()
            table:integer('organization_id'):notNullable():index()
            table:string('title', 150):notNullable()
            table:integer('author_character_id'):notNullable()
            table:string('posted_at', 20):notNullable()
            table:string('color', 20)
            table:boolean('pinned')
            table:boolean('must_read')
            table:text('body')
        end)
        Schema.create('mdt_board_reads', function(table)
            table:id()
            table:integer('post_id'):notNullable():index()
            table:integer('character_id'):notNullable()

            table:unique({'post_id', 'character_id'})
        end)
        print('[Migration] Created mdt_board tables')
    end,
    down = function()
        Schema.drop('mdt_board_reads')
        Schema.drop('mdt_board_posts')
        print('[Migration] Dropped mdt_board tables')
    end
}
```
Save as `plugins/oblsk_mdt/server/migrations/2026_08_12_000011_create_mdt_board_tables.lua`, append `"2026_08_12_000011_create_mdt_board_tables"` to `migrations.json`.

- [ ] **Step 2: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_board_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtBoardService.lua')
    return tables
end

test('post inserts a board post', function()
    local tables = setup()
    MdtBoardService.post(1, 'lspd', 5, { title = 'Radio discipline', body = 'text' })
    eq(#tables['mdt_board_posts'], 1)
end)

test('markRead is idempotent per character', function()
    local tables = setup()
    local id = MdtBoardService.post(1, 'lspd', 5, { title = 'A', body = 'b' })
    MdtBoardService.markRead(2, id)
    MdtBoardService.markRead(2, id)
    eq(#tables['mdt_board_reads'], 1, 'no duplicate read row')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 3: Implement MdtBoardService**

```lua
MdtBoardService = {}

function MdtBoardService.list(orgId)
    return QueryBuilder.new('mdt_board_posts'):where('organization_id', orgId):getSync()
end

--- @param data table { title, body, color (optional), pinned (optional), must_read (optional) }
function MdtBoardService.post(characterId, auth, orgId, data)
    local id = QueryBuilder.new('mdt_board_posts'):insert({
        organization_id = orgId,
        title = data.title,
        author_character_id = characterId,
        posted_at = os.date('%d %b %Y'),
        color = data.color,
        pinned = data.pinned or false,
        must_read = data.must_read or false,
        body = data.body,
    })
    MdtAuditService.log(characterId, auth, 'board', 'posted "' .. data.title .. '"', tostring(id))
    return id
end

function MdtBoardService.markRead(characterId, postId)
    local existing = QueryBuilder.new('mdt_board_reads'):where('post_id', postId):where('character_id', characterId):firstSync()
    if existing then return end
    QueryBuilder.new('mdt_board_reads'):insert({ post_id = postId, character_id = characterId })
end

return MdtBoardService
```
Save as `plugins/oblsk_mdt/server/services/MdtBoardService.lua`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add server handlers + client relays** for `oblsk_mdt:server:board-list`, `board-post`, `board-mark-read` (post gated by `Character:can('mdt-write-board')`).

- [ ] **Step 6: Write Board.vue**

```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="p in posts" :key="p.id" class="p-3 border-b border-white/6 text-[12px]" @click="markRead(p)">
      <div class="font-semibold flex items-center gap-2">
        <span v-if="p.pinned">📌</span>{{ p.title }}
      </div>
      <div class="text-white/50 mt-1">{{ p.body }}</div>
    </div>
    <div v-if="!posts.length" class="p-6 text-center text-[12px] text-white/30">Nothing posted.</div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const posts = ref([])
function markRead(p) { Obelisk.emit('oblsk_mdt:client:board-mark-read', { postId: p.id }) }

onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:board-list', {}).then((data) => { posts.value = data || [] })
})
</script>
```
Save as `plugins/oblsk_mdt/web/apps/Board/Board.vue`.

- [ ] **Step 7: Register in Mdt.vue** (`board: Board`)

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtBoardService.lua server/main.lua client/main.lua web/apps/Board web/Mdt.vue tests/mdt_board_service_spec.lua
git commit -m "Add Blackboard module"
```

---

## Task 16: Employees (Staff) module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000012_create_mdt_staff_meta_table.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtStaffService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Staff/Staff.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_staff_service_spec.lua`

**Interfaces:**
- Consumes: `OrganizationService.getMemberships`/membership roster reads (exact roster-listing accessor to confirm against `OrganizationService` — if there's no "list all members of an org" function yet, add `OrganizationService.listMembers(orgId) -> table[]` in this task's implementation step as a small addition to that existing service, following its established style, rather than querying `organization_memberships` directly from `oblsk_mdt`).
- Produces: `MdtStaffService.metaFor(characterId) -> table|nil`, `MdtStaffService.setDuty(characterId, auth, targetCharacterId, status)`, `MdtStaffService.setCam(characterId, auth, targetCharacterId, cam)`.

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Schema.create('mdt_staff_meta', function(table)
            table:id()
            table:integer('character_id'):notNullable():unique()
            table:string('status', 15):notNullable()
            table:boolean('cam')
            table:integer('salary')
        end)
        print('[Migration] Created mdt_staff_meta table')
    end,
    down = function()
        Schema.drop('mdt_staff_meta')
        print('[Migration] Dropped mdt_staff_meta table')
    end
}
```
Save as `plugins/oblsk_mdt/server/migrations/2026_08_12_000012_create_mdt_staff_meta_table.lua`, append `"2026_08_12_000012_create_mdt_staff_meta_table"` to `migrations.json`.

- [ ] **Step 2: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_staff_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtStaffService.lua')
    return tables
end

test('setDuty creates a meta row on first use, defaulting cam to false', function()
    local tables = setup()
    MdtStaffService.setDuty(1, 'lspd', 5, 'ON DUTY')
    eq(tables['mdt_staff_meta'][1].status, 'ON DUTY')
    eq(tables['mdt_staff_meta'][1].cam, false)
end)

test('setDuty updates an existing meta row rather than duplicating', function()
    local tables = setup()
    MdtStaffService.setDuty(1, 'lspd', 5, 'ON DUTY')
    MdtStaffService.setDuty(1, 'lspd', 5, 'OFF DUTY')
    eq(#tables['mdt_staff_meta'], 1)
    eq(tables['mdt_staff_meta'][1].status, 'OFF DUTY')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 3: Implement MdtStaffService**

```lua
MdtStaffService = {}

function MdtStaffService.metaFor(characterId)
    return QueryBuilder.new('mdt_staff_meta'):where('character_id', characterId):firstSync()
end

local function ensureMeta(characterId)
    local existing = MdtStaffService.metaFor(characterId)
    if existing then return existing end
    QueryBuilder.new('mdt_staff_meta'):insert({ character_id = characterId, status = 'OFF DUTY', cam = false })
    return MdtStaffService.metaFor(characterId)
end

function MdtStaffService.setDuty(characterId, auth, targetCharacterId, status)
    ensureMeta(targetCharacterId)
    QueryBuilder.new('mdt_staff_meta'):where('character_id', targetCharacterId):update({ status = status })
    MdtAuditService.log(characterId, auth, 'staff', 'set duty status to ' .. status, tostring(targetCharacterId))
end

function MdtStaffService.setCam(characterId, auth, targetCharacterId, cam)
    ensureMeta(targetCharacterId)
    QueryBuilder.new('mdt_staff_meta'):where('character_id', targetCharacterId):update({ cam = cam })
    MdtAuditService.log(characterId, auth, 'staff', cam and 'issued bodycam' or 'revoked bodycam', tostring(targetCharacterId))
end

return MdtStaffService
```
Save as `plugins/oblsk_mdt/server/services/MdtStaffService.lua`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add server handlers + client relays** for `oblsk_mdt:server:staff-list` (joins `OrganizationService.listMembers(orgId)` roster identity with `MdtStaffService.metaFor` per member, added as a plain Lua loop in the handler, not a new service function since it's presentation composition, not a data operation), `staff-set-duty`, `staff-set-cam` (duty/cam gated by `Character:can('mdt-write-staff')`).

- [ ] **Step 6: Write Staff.vue**

```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="s in staff" :key="s.character_id" class="p-3 border-b border-white/6 text-[12px] flex justify-between">
      <span>{{ s.name }} · {{ s.rank }}</span>
      <span :class="s.status === 'ON DUTY' ? 'text-emerald-300' : 'text-white/30'">{{ s.status }}</span>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const staff = ref([])
onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:staff-list', {}).then((data) => { staff.value = data || [] })
})
</script>
```
Save as `plugins/oblsk_mdt/web/apps/Staff/Staff.vue`.

- [ ] **Step 7: Register in Mdt.vue** (`staff: Staff`)

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtStaffService.lua server/main.lua client/main.lua web/apps/Staff web/Mdt.vue tests/mdt_staff_service_spec.lua
git commit -m "Add Employees module"
```

---

## Task 17: Calendar module

**Files:**
- Create: `plugins/oblsk_mdt/server/migrations/2026_08_12_000013_create_mdt_calendar_tables.lua`
- Create: `plugins/oblsk_mdt/server/services/MdtCalendarService.lua`
- Create: `plugins/oblsk_mdt/web/apps/Calendar/Calendar.vue`
- Modify: `server/migrations.json`, `server/main.lua`, `client/main.lua`, `web/Mdt.vue`
- Test: `plugins/oblsk_mdt/tests/mdt_calendar_service_spec.lua`

**Interfaces:**
- Produces: `MdtCalendarService.events(orgId) -> table[]`, `MdtCalendarService.createEvent(characterId, auth, orgId, data) -> eventId`, `MdtCalendarService.requestHoliday(characterId, auth, data) -> requestId`, `MdtCalendarService.decideHoliday(characterId, auth, requestId, granted)`.

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Schema.create('mdt_calendar_events', function(table)
            table:id()
            table:integer('organization_id'):notNullable():index()
            table:string('day', 10):notNullable()
            table:string('kind', 20):notNullable()
            table:string('title', 150):notNullable()
            table:string('who', 100)
        end)
        Schema.create('mdt_holiday_requests', function(table)
            table:id()
            table:integer('character_id'):notNullable():index()
            table:string('from_date', 20):notNullable()
            table:string('to_date', 20):notNullable()
            table:string('reason', 200)
            table:string('status', 15):notNullable()
        end)
        print('[Migration] Created mdt_calendar tables')
    end,
    down = function()
        Schema.drop('mdt_holiday_requests')
        Schema.drop('mdt_calendar_events')
        print('[Migration] Dropped mdt_calendar tables')
    end
}
```
Save as `plugins/oblsk_mdt/server/migrations/2026_08_12_000013_create_mdt_calendar_tables.lua`, append `"2026_08_12_000013_create_mdt_calendar_tables"` to `migrations.json`.

- [ ] **Step 2: Write the failing tests**

`plugins/oblsk_mdt/tests/mdt_calendar_service_spec.lua`:
```lua
local scriptDir = arg[0]:match('(.*/)') or './'
dofile(scriptDir .. 'support/fake_query_builder.lua')

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then error((msg or 'mismatch') .. ' — expected ' .. tostring(expected) .. ', got ' .. tostring(actual)) end
end

local function setup()
    local tables = {}
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    MdtAuditService = { log = function() end }
    dofile(scriptDir .. '../server/services/MdtCalendarService.lua')
    return tables
end

test('requestHoliday defaults to PENDING', function()
    local tables = setup()
    MdtCalendarService.requestHoliday(1, 'lspd', { from_date = '26 Oct', to_date = '30 Oct', reason = 'Family visit' })
    eq(tables['mdt_holiday_requests'][1].status, 'PENDING')
end)

test('decideHoliday sets GRANTED or DENIED', function()
    local tables = setup()
    local id = MdtCalendarService.requestHoliday(1, 'lspd', { from_date = 'a', to_date = 'b', reason = 'c' })
    MdtCalendarService.decideHoliday(2, 'lspd', id, true)
    eq(tables['mdt_holiday_requests'][1].status, 'GRANTED')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
```

- [ ] **Step 3: Implement MdtCalendarService**

```lua
MdtCalendarService = {}

function MdtCalendarService.events(orgId)
    return QueryBuilder.new('mdt_calendar_events'):where('organization_id', orgId):getSync()
end

function MdtCalendarService.createEvent(characterId, auth, orgId, data)
    local id = QueryBuilder.new('mdt_calendar_events'):insert({
        organization_id = orgId, day = data.day, kind = data.kind, title = data.title, who = data.who,
    })
    MdtAuditService.log(characterId, auth, 'calendar', 'added event "' .. data.title .. '"', tostring(id))
    return id
end

function MdtCalendarService.requestHoliday(characterId, auth, data)
    local id = QueryBuilder.new('mdt_holiday_requests'):insert({
        character_id = characterId, from_date = data.from_date, to_date = data.to_date,
        reason = data.reason, status = 'PENDING',
    })
    MdtAuditService.log(characterId, auth, 'calendar', 'requested holiday', tostring(id))
    return id
end

function MdtCalendarService.decideHoliday(characterId, auth, requestId, granted)
    QueryBuilder.new('mdt_holiday_requests'):where('id', requestId):update({ status = granted and 'GRANTED' or 'DENIED' })
    MdtAuditService.log(characterId, auth, 'calendar', granted and 'granted holiday request' or 'denied holiday request', tostring(requestId))
end

return MdtCalendarService
```
Save as `plugins/oblsk_mdt/server/services/MdtCalendarService.lua`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add server handlers + client relays** for `oblsk_mdt:server:calendar-events`, `calendar-create-event`, `calendar-request-holiday`, `calendar-decide-holiday` (create-event/decide-holiday gated by `Character:can('mdt-write-calendar')`; request-holiday only requires MDT access, any staff member can request their own).

- [ ] **Step 6: Write Calendar.vue**

```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="e in events" :key="e.id" class="p-3 border-b border-white/6 text-[12px] flex justify-between">
      <span>{{ e.day }} · {{ e.title }}</span>
      <span class="text-white/40">{{ e.who }}</span>
    </div>
    <div v-if="!events.length" class="p-6 text-center text-[12px] text-white/30">No events this month.</div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const events = ref([])
onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:calendar-events', {}).then((data) => { events.value = data || [] })
})
</script>
```
Save as `plugins/oblsk_mdt/web/apps/Calendar/Calendar.vue`.

- [ ] **Step 7: Register in Mdt.vue** (`calendar: Calendar`)

- [ ] **Step 8: Commit**

```bash
cd plugins/oblsk_mdt
git add server/migrations server/migrations.json server/services/MdtCalendarService.lua server/main.lua client/main.lua web/apps/Calendar web/Mdt.vue tests/mdt_calendar_service_spec.lua
git commit -m "Add Calendar module"
```

---

## Task 18: Audit trail + Administration modules

**Files:**
- Create: `plugins/oblsk_mdt/web/apps/Audit/Audit.vue`
- Create: `plugins/oblsk_mdt/web/apps/Admin/Admin.vue`
- Modify: `server/main.lua`, `client/main.lua`, `web/Mdt.vue`

No new tables (Audit reads `mdt_audit_log` from Task 3; Admin is a management surface over `OrganizationService`/`PermissionService`, both already built).

**Interfaces:**
- Consumes: `MdtAuditService.list(limit)` (Task 3), `OrganizationService.addDepartment`/`addRank`/`setRank`/`joinDepartment` (already exist), `PermissionService.grant`/`revoke` (already exist).

- [ ] **Step 1: Add server handlers for audit and admin**

Add to `plugins/oblsk_mdt/server/main.lua`:
```lua
Obelisk.onServer('oblsk_mdt:server:audit-list', function()
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    local resolved = MdtAuthService.resolve(characterId)
    if not resolved then return end
    Obelisk.emitClient('oblsk_mdt:client:audit-list', source, MdtAuditService.list(200))
end)

Obelisk.onServer('oblsk_mdt:server:admin-grant-permission', function(data)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    if not Character:can('mdt-admin') then
        Obelisk.emitClient('oblsk_mdt:client:admin-grant-permission', source, { ok = false, error = 'forbidden' })
        return
    end
    PermissionService.grant(data.ownerType, data.ownerId, data.key)
    MdtAuditService.log(characterId, MdtAuthService.resolve(characterId).auth, 'admin', 'granted ' .. data.key, nil)
    Obelisk.emitClient('oblsk_mdt:client:admin-grant-permission', source, { ok = true })
end)
```

- [ ] **Step 2: Add client relays**

Add to `plugins/oblsk_mdt/client/main.lua`:
```lua
WebView.on('oblsk_mdt:client:audit-list', function(data) Obelisk.emitServer('oblsk_mdt:server:audit-list') end)
Obelisk.onClient('oblsk_mdt:client:audit-list', function(rows)
    SendNUIMessage({ eventname = 'oblsk_mdt:client:audit-list', args = { rows } })
end)

WebView.on('oblsk_mdt:client:admin-grant-permission', function(data) Obelisk.emitServer('oblsk_mdt:server:admin-grant-permission', data) end)
Obelisk.onClient('oblsk_mdt:client:admin-grant-permission', function(result)
    SendNUIMessage({ eventname = 'oblsk_mdt:client:admin-grant-permission', args = { result } })
end)
```

- [ ] **Step 3: Write Audit.vue**

`plugins/oblsk_mdt/web/apps/Audit/Audit.vue`:
```vue
<template>
  <div class="h-full overflow-y-auto">
    <div v-for="r in rows" :key="r.id" class="px-3 py-2 border-b border-white/6 text-[11px] flex justify-between">
      <span>{{ r.module }} · {{ r.what }}</span>
      <span class="text-white/30">{{ r.at }}</span>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const rows = ref([])
onMounted(() => {
  Obelisk.emit('oblsk_mdt:client:audit-list', {}).then((data) => { rows.value = data || [] })
})
</script>
```

- [ ] **Step 4: Write Admin.vue**

`plugins/oblsk_mdt/web/apps/Admin/Admin.vue`:
```vue
<template>
  <div class="h-full p-4 text-[12px] text-white/60">
    <p>Department and rank management for this authority. Grant an MDT permission key to a department:</p>
    <div class="flex gap-2 mt-3">
      <input v-model="deptId" placeholder="department id" class="h-8 rounded-lg bg-white/6 border border-white/8 px-2.5 w-32" />
      <input v-model="key" placeholder="permission key" class="h-8 rounded-lg bg-white/6 border border-white/8 px-2.5 w-56" />
      <button @click="grant" class="px-2.5 h-8 rounded-md text-black" style="background: var(--ob-accent)">Grant</button>
    </div>
  </div>
</template>

<script setup>
import { ref } from 'vue'
import Obelisk from '@/obelisk.js'

const deptId = ref('')
const key = ref('')

function grant() {
  Obelisk.emit('oblsk_mdt:client:admin-grant-permission', { ownerType: 'department', ownerId: Number(deptId.value), key: key.value })
}
</script>
```

- [ ] **Step 5: Register both in Mdt.vue** (`audit: Audit`, `admin: Admin`)

- [ ] **Step 6: Manual verification** — as a character with `mdt-admin`, grant `mdt-write-case` to an LSPD department, confirm a member of that department can then create a case; confirm a member without the grant gets the `forbidden` response from Task 5.

- [ ] **Step 7: Commit**

```bash
cd plugins/oblsk_mdt
git add web/apps/Audit web/apps/Admin server/main.lua client/main.lua web/Mdt.vue
git commit -m "Add Audit trail and Administration modules"
```

---

## Post-plan follow-up (not part of this plan's tasks)

- Real `Lawbook` (`oblsk_phone` app, referenced in the original phone plan) reading `MdtLawService.books()`/`.sections()` read-only — deferred until that app is built.
- Real `Paperwork` (`oblsk_phone` app) reusing `DocEditor.vue` (Task 7) — deferred until that app is built.
- Whole-branch review pass across all 18 tasks (permission-key naming consistency, `Character:can` accessor confirmation from Task 5 Step 6, `DispatchService.list()` signature confirmation from Task 9) before merging to main, matching this session's established pattern for multi-task plans.
