# Admin Panel — Organisations Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the admin Staff Panel shell (11-tab bar, ACE-gated open/close) as a new `oblsk_admin` plugin, with the Organisations tab fully functional (CRUD for orgs, departments, ranks, contact numbers), backed by additive schema/service changes to the existing `core/modules/oblsk_organizations` module.

**Architecture:** `oblsk_organizations` (inside the `core` repo) gets three new columns on `organizations` (`short_code`, `colour`, `type`) and a new `organization_contact_numbers` table, plus `OrganizationService.setDetails/list/addContactNumber/removeContactNumber/toggleContactNumber`. A new sibling repo `oblsk_admin` (checked out at `core/plugins/oblsk_admin`, gitignored by `core`, same as every other plugin) owns the panel: ACE-gated open/close via the codebase's inline `isAdmin(source)` convention, a Vue shell (`AdminPanel.vue`) with a tab bar where only `organisations` is wired (the other ten render a shared placeholder), and a three-hop push-reply NUI bridge (Vue → client Lua relay → server Lua → `Obelisk.emitClient` reply → client `SendNUIMessage` → Vue listener) matching `oblsk_keybinds`/`oblsk_phone`, since `WebView.on`'s NUI callback cannot return data.

**Tech Stack:** Lua 5.4 (FXServer), the framework's own ORM (`Schema`/`QueryBuilder`/`BaseModel`), Vue 3 `<script setup>` + Tailwind (via `core/web`'s central build), `lua5.4` CLI for hand-rolled test specs (no busted/luaunit — see Global Constraints).

**Spec:** `core/docs/superpowers/specs/2026-08-13-admin-panel-organisations-design.md`

## Global Constraints

- Lua files in this codebase use no external test framework — specs are hand-rolled `test(name, fn)` runners executed directly via `lua5.4 <path>`, following the exact skeleton in `core/modules/oblsk_organizations/tests/organization_service_crud_spec.lua`. Every new spec in this plan follows that skeleton.
- Pure logic (migrations, models, services) gets an automated spec. Thin framework-wiring files (`server/main.lua` action registration, `client/main.lua` NUI relays, `.vue` components) do **not** have specs anywhere in this codebase today (confirmed: `oblsk_keybinds/server/main.lua` has no matching spec) — those tasks end in a manual verification checklist instead, matching repo convention, not a gap in this plan.
- `WebView.on(eventName, handler)` always acks the NUI callback with the literal string `'ok'` — it can never return data to the Vue promise. Every NUI round trip that needs a reply uses the three-hop push pattern: Vue `Obelisk.emit` → client Lua `Obelisk.emitServer` relay → server Lua does the work and calls `Obelisk.emitClient(source, replyEvent, payload)` → client Lua `Obelisk.onClient(replyEvent, ...)` calls `SendNUIMessage({eventname=replyEvent, args={payload}})` → Vue `Obelisk.on(replyEvent, handler)`.
- `ActionService.register`'s `options.policies` field is a no-op today (nothing calls `PolicyService.attach('action', ...)`). Admin-gating uses the inline guard `local function isAdmin(source) return source == 0 or IsPlayerAceAllowed(source, 'admin') end`, copied verbatim into every file that needs it (matches `OrganizationCommands.lua`/`AccountCommands.lua` — this codebase does not share that guard via a common module).
- Plugin config lives at `<plugin>/shared/config.lua`, declared via `shared_scripts { 'shared/**/*.lua' }` in `fxmanifest.lua` — there is no top-level `config.lua` on any real plugin.
- `modules/oblsk_organizations` lives inside the `core` git repo (`core/modules/oblsk_organizations`) — Tasks 1-3 commit into `core`. `oblsk_admin` is a brand-new sibling plugin repo checked out at `core/plugins/oblsk_admin` (same pattern as `core/plugins/oblsk_phone`, remote `git@github.com:Obelisk-Framework/oblsk_admin.git`, gitignored by `core`'s `plugins/*` rule) — Tasks 4-8 commit into that repo instead.
- After any new plugin directory appears under `core/plugins/`, `node cli/index.js registry:generate` must be run from `core/` on the host (not in Docker) before the plugin's migrations/scripts will load — `core/core/server/bootstrap.lua` only runs migrations for names present in `plugins/registry.json`.

---

### Task 1: Migration — organisation admin fields + contact numbers table

**Files:**
- Create: `core/modules/oblsk_organizations/server/migrations/2026_08_13_150000_add_admin_fields_and_contacts_to_organizations.lua`
- Modify: `core/modules/oblsk_organizations/server/migrations.json`
- Test: `core/modules/oblsk_organizations/tests/organization_admin_fields_migration_spec.lua`

**Interfaces:**
- Produces: `organizations.short_code` (string, nullable), `organizations.colour` (string, nullable), `organizations.type` (string, default `'Government'`); table `organization_contact_numbers(id, organization_id, number, label, enabled, created_at, updated_at)`. Task 2/3 write to these directly via `QueryBuilder`/`Organization`.

- [ ] **Step 1: Write the failing migration spec**

```lua
-- core/modules/oblsk_organizations/tests/organization_admin_fields_migration_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_organizations/tests/organization_admin_fields_migration_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function contains(haystack, needle, msg)
    if not haystack:lower():find(needle:lower(), 1, true) then
        error((msg or 'expected substring not found') .. '\n  looking for: ' .. needle .. '\n  in: ' .. haystack, 2)
    end
end

local function captureStatements(fn)
    local statements = {}
    local original = Database.querySync
    Database.querySync = function(sql, params)
        table.insert(statements, sql)
        return {}
    end
    fn()
    Database.querySync = original
    return statements
end

test('adds short_code, colour and type columns to organizations', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_13_150000_add_admin_fields_and_contacts_to_organizations.lua')
    local statements = captureStatements(migration.up)
    local sql = table.concat(statements, '\n')
    contains(sql, 'organizations')
    contains(sql, 'short_code')
    contains(sql, 'colour')
    contains(sql, 'type')
end)

test('creates organization_contact_numbers with an organization_id FK', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_13_150000_add_admin_fields_and_contacts_to_organizations.lua')
    local statements = captureStatements(migration.up)
    local sql = table.concat(statements, '\n')
    contains(sql, 'organization_contact_numbers')
    contains(sql, 'organization_id')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_admin_fields_migration_spec.lua`
Expected: FAIL — `dofile` errors, migration file doesn't exist yet.

- [ ] **Step 3: Write the migration**

```lua
-- core/modules/oblsk_organizations/server/migrations/2026_08_13_150000_add_admin_fields_and_contacts_to_organizations.lua
--- Migration: Add admin-panel fields to organizations, and a contact
--- numbers table. Additive only — see
--- docs/superpowers/specs/2026-08-13-admin-panel-organisations-design.md.
return {
    up = function()
        Schema.table('organizations', function(table)
            table:string('short_code', 10):nullable()
            table:string('colour', 7):nullable()
            table:string('type', 20):default('Government')
        end)

        Schema.create('organization_contact_numbers', function(table)
            table:id()
            table:integer('organization_id')
            table:string('number', 20)
            table:string('label', 50)
            table:boolean('enabled'):default(1)
            table:timestamps()

            table:index({'organization_id'})
            table:foreign('organization_id'):references('id'):on('organizations'):onDelete('CASCADE')
        end)

        print('[Migration] Added admin fields to organizations and created organization_contact_numbers table')
    end,

    down = function()
        Schema.drop('organization_contact_numbers')
        Schema.dropColumn('organizations', 'short_code')
        Schema.dropColumn('organizations', 'colour')
        Schema.dropColumn('organizations', 'type')
        print('[Migration] Reverted admin fields and dropped organization_contact_numbers table')
    end
}
```

- [ ] **Step 4: Append the migration to the manifest**

Edit `core/modules/oblsk_organizations/server/migrations.json`, add the new filename stem to the `migrations` array (append, keep existing entries in order):

```json
{
  "migrations": [
    "2026_08_11_080000_create_organizations_table",
    "2026_08_11_080001_create_departments_table",
    "2026_08_11_080002_create_ranks_table",
    "2026_08_11_080003_create_organization_memberships_table",
    "2026_08_11_080004_create_organization_department_members_table",
    "2026_08_13_150000_add_admin_fields_and_contacts_to_organizations"
  ]
}
```

- [ ] **Step 5: Run the spec, confirm it passes**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_admin_fields_migration_spec.lua`
Expected: `2 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
cd core
git add modules/oblsk_organizations/server/migrations/2026_08_13_150000_add_admin_fields_and_contacts_to_organizations.lua \
        modules/oblsk_organizations/server/migrations.json \
        modules/oblsk_organizations/tests/organization_admin_fields_migration_spec.lua
git commit -m "feat(oblsk_organizations): add admin fields + contact numbers migration"
```

---

### Task 2: `Organization.fillable` + `OrganizationService.setDetails`/`list`

**Files:**
- Modify: `core/modules/oblsk_organizations/server/models/Organization.lua`
- Modify: `core/modules/oblsk_organizations/server/services/OrganizationService.lua`
- Test: `core/modules/oblsk_organizations/tests/organization_service_admin_spec.lua`

**Interfaces:**
- Consumes: `Organization:createSync/where/update` (`BaseModel`, existing), `Department:where`, `Rank:where` (existing), Task 1's new columns/table.
- Produces: `OrganizationService.setDetails(orgId, {shortCode, colour, type})` (returns `true`, or `false, reason` on validation failure), `OrganizationService.list()` (returns array of `{id, name, short_code, colour, type, departments={{id,name}}, ranks={{id,name,grade}} sorted by grade asc, contact_numbers={{id,number,label,enabled}}}`). Task 3 adds contact-number mutators that `list()` already reflects; Task 7's server handlers call both directly.

- [ ] **Step 1: Write the failing tests**

```lua
-- core/modules/oblsk_organizations/tests/organization_service_admin_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_organizations/tests/organization_service_admin_spec.lua
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
dofile(CORE_ROOT .. '/core/server/Traits/HasPermissions.lua')
dofile(scriptDir .. '../server/models/Department.lua')
dofile(scriptDir .. '../server/models/Rank.lua')
dofile(scriptDir .. '../server/models/Organization.lua')
dofile(scriptDir .. '../server/models/OrganizationMembership.lua')
dofile(scriptDir .. '../server/services/OrganizationService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

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
    PermissionService.registerType('rank', {})
    PermissionService.registerType('department', {})
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('setDetails: updates short_code, colour and type', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local ok = OrganizationService.setDetails(orgId, { shortCode = 'LSPD', colour = '#3b82f6', type = 'Government' })

        eq(ok, true)
        eq(tables.organizations[1].short_code, 'LSPD')
        eq(tables.organizations[1].colour, '#3b82f6')
        eq(tables.organizations[1].type, 'Government')
    end)
end)

test('setDetails: rejects an unknown type', function()
    withFakeDb(function()
        local orgId = OrganizationService.create('LSPD')
        local ok, reason = OrganizationService.setDetails(orgId, { shortCode = 'LSPD', colour = '#3b82f6', type = 'Cartel' })

        eq(ok, false)
        eq(reason, 'type must be Government or Business')
    end)
end)

test('setDetails: rejects a short code already used by a different organization', function()
    withFakeDb(function()
        local firstOrgId = OrganizationService.create('LSPD')
        OrganizationService.setDetails(firstOrgId, { shortCode = 'LSPD', colour = '#3b82f6', type = 'Government' })
        local secondOrgId = OrganizationService.create('Los Santos Police Dept (dupe)')

        local ok, reason = OrganizationService.setDetails(secondOrgId, { shortCode = 'LSPD', colour = '#10b981', type = 'Government' })

        eq(ok, false)
        eq(reason, 'short code already in use')
    end)
end)

test('setDetails: allows re-saving the same org with its own existing short code', function()
    withFakeDb(function()
        local orgId = OrganizationService.create('LSPD')
        OrganizationService.setDetails(orgId, { shortCode = 'LSPD', colour = '#3b82f6', type = 'Government' })

        local ok = OrganizationService.setDetails(orgId, { shortCode = 'LSPD', colour = '#10b981', type = 'Government' })

        eq(ok, true)
    end)
end)

test('list: returns organizations with departments, ranks (grade-ordered) and contact numbers', function()
    withFakeDb(function()
        local orgId = OrganizationService.create('LSPD')
        OrganizationService.setDetails(orgId, { shortCode = 'LSPD', colour = '#3b82f6', type = 'Government' })
        OrganizationService.addDepartment(orgId, 'Patrol')
        OrganizationService.addRank(orgId, 'Sergeant', 3)
        OrganizationService.addRank(orgId, 'Officer', 1)

        local orgs = OrganizationService.list()

        eq(#orgs, 1)
        eq(orgs[1].name, 'LSPD')
        eq(orgs[1].short_code, 'LSPD')
        eq(#orgs[1].departments, 1)
        eq(orgs[1].departments[1].name, 'Patrol')
        eq(#orgs[1].ranks, 2)
        eq(orgs[1].ranks[1].name, 'Officer')
        eq(orgs[1].ranks[2].name, 'Sergeant')
        eq(#orgs[1].contact_numbers, 0)
    end)
end)

print('Running OrganizationService admin unit tests\n')
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

- [ ] **Step 2: Run it, confirm it fails**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_service_admin_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'setDetails')`.

- [ ] **Step 3: Add the new columns to `Organization.fillable`**

Edit `core/modules/oblsk_organizations/server/models/Organization.lua`:

```lua
Organization.fillable = { 'name', 'short_code', 'colour', 'type' }
```

- [ ] **Step 4: Implement `setDetails` and `list`**

Add to `core/modules/oblsk_organizations/server/services/OrganizationService.lua` (before the final `return OrganizationService`):

```lua
--- @param orgId number
--- @param details table { shortCode, colour, type }
--- @return boolean ok
--- @return string|nil reason present only when ok is false
function OrganizationService.setDetails(orgId, details)
    if details.type ~= 'Government' and details.type ~= 'Business' then
        return false, 'type must be Government or Business'
    end

    if details.shortCode and details.shortCode ~= '' then
        local existing = Organization:where('short_code', details.shortCode):firstSync()
        if existing and existing.id ~= orgId then
            return false, 'short code already in use'
        end
    end

    Organization:where('id', orgId):update({
        short_code = details.shortCode,
        colour = details.colour,
        type = details.type,
        updated_at = Database.now(),
    })
    return true
end

--- Every organization with its departments, ranks (grade-ordered, lowest
--- first) and contact numbers eager-loaded, for the admin panel's org list.
--- @return table[]
function OrganizationService.list()
    local orgs = Organization:getSync()

    local result = {}
    for _, org in ipairs(orgs) do
        local departments = Department:where('organization_id', org.id):getSync()
        local ranks = Rank:where('organization_id', org.id):orderBy('grade', 'asc'):getSync()
        local contactNumbers = QueryBuilder.new('organization_contact_numbers')
            :where('organization_id', org.id):getSync()

        table.insert(result, {
            id = org.id,
            name = org.name,
            short_code = org.short_code,
            colour = org.colour,
            type = org.type,
            departments = departments,
            ranks = ranks,
            contact_numbers = contactNumbers,
        })
    end
    return result
end
```

- [ ] **Step 5: Run the spec, confirm it passes**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_service_admin_spec.lua`
Expected: `5 passed, 0 failed`

- [ ] **Step 6: Run the existing CRUD/membership specs to confirm no regression**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_service_crud_spec.lua && lua5.4 modules/oblsk_organizations/tests/organization_service_membership_spec.lua && lua5.4 modules/oblsk_organizations/tests/department_rank_model_spec.lua && lua5.4 modules/oblsk_organizations/tests/character_delegate_spec.lua`
Expected: all four print `0 failed`.

- [ ] **Step 7: Commit**

```bash
cd core
git add modules/oblsk_organizations/server/models/Organization.lua \
        modules/oblsk_organizations/server/services/OrganizationService.lua \
        modules/oblsk_organizations/tests/organization_service_admin_spec.lua
git commit -m "feat(oblsk_organizations): add OrganizationService.setDetails and list"
```

---

### Task 3: `OrganizationService` contact-number mutators + delete cascade

**Files:**
- Modify: `core/modules/oblsk_organizations/server/services/OrganizationService.lua`
- Modify: `core/modules/oblsk_organizations/tests/organization_service_admin_spec.lua`

**Interfaces:**
- Produces: `OrganizationService.addContactNumber(orgId, number, label)` (returns new contact id), `.removeContactNumber(contactId)`, `.toggleContactNumber(contactId, enabled)`. `OrganizationService.delete` (existing, Task 1/2 don't touch it) now also removes an org's contact numbers.

- [ ] **Step 1: Add the failing tests**

Append to `core/modules/oblsk_organizations/tests/organization_service_admin_spec.lua`, before the `print('Running ...` block:

```lua
test('addContactNumber: inserts a contact number scoped to the organization', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local contactId = OrganizationService.addContactNumber(orgId, '911', 'Emergency')

        eq(#tables.organization_contact_numbers, 1)
        eq(tables.organization_contact_numbers[1].id, contactId)
        eq(tables.organization_contact_numbers[1].organization_id, orgId)
        eq(tables.organization_contact_numbers[1].number, '911')
        eq(tables.organization_contact_numbers[1].label, 'Emergency')
        eq(tables.organization_contact_numbers[1].enabled, true)
    end)
end)

test('removeContactNumber: removes the contact number', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local contactId = OrganizationService.addContactNumber(orgId, '911', 'Emergency')

        OrganizationService.removeContactNumber(contactId)

        eq(#tables.organization_contact_numbers, 0)
    end)
end)

test('toggleContactNumber: flips enabled', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        local contactId = OrganizationService.addContactNumber(orgId, '911', 'Emergency')

        OrganizationService.toggleContactNumber(contactId, false)

        eq(tables.organization_contact_numbers[1].enabled, false)
    end)
end)

test('delete: also removes the organization''s contact numbers', function()
    withFakeDb(function(tables)
        local orgId = OrganizationService.create('LSPD')
        OrganizationService.addContactNumber(orgId, '911', 'Emergency')

        OrganizationService.delete(orgId)

        eq(#tables.organization_contact_numbers, 0)
    end)
end)
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_service_admin_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'addContactNumber')`.

- [ ] **Step 3: Implement the mutators and extend `delete`**

Add to `OrganizationService.lua`, near the other contact/detail methods:

```lua
--- @param orgId number
--- @param number string
--- @param label string
--- @return number contactId
function OrganizationService.addContactNumber(orgId, number, label)
    return QueryBuilder.new('organization_contact_numbers'):insert({
        organization_id = orgId,
        number = number,
        label = label,
        enabled = true,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param contactId number
function OrganizationService.removeContactNumber(contactId)
    QueryBuilder.new('organization_contact_numbers'):where('id', contactId):delete()
end

--- @param contactId number
--- @param enabled boolean
function OrganizationService.toggleContactNumber(contactId, enabled)
    QueryBuilder.new('organization_contact_numbers'):where('id', contactId):update({
        enabled = enabled,
        updated_at = Database.now(),
    })
end
```

Then edit the existing `OrganizationService.delete(orgId)` — add one line alongside the other cascade deletes (after the `OrganizationMembership:where('organization_id', orgId):delete()` line, before `Organization:where('id', orgId):delete()`):

```lua
    QueryBuilder.new('organization_contact_numbers'):where('organization_id', orgId):delete()
```

- [ ] **Step 4: Run the spec, confirm it passes**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_service_admin_spec.lua`
Expected: `9 passed, 0 failed`

- [ ] **Step 5: Re-run the full existing org test suite to confirm no regression**

Run: `cd core && lua5.4 modules/oblsk_organizations/tests/organization_service_crud_spec.lua && lua5.4 modules/oblsk_organizations/tests/organization_service_membership_spec.lua`
Expected: both `0 failed`.

- [ ] **Step 6: Commit**

```bash
cd core
git add modules/oblsk_organizations/server/services/OrganizationService.lua \
        modules/oblsk_organizations/tests/organization_service_admin_spec.lua
git commit -m "feat(oblsk_organizations): add contact number CRUD, cascade on org delete"
```

---

### Task 4: Scaffold the `oblsk_admin` plugin repo

**Files:**
- Create (new git repo, checked out at `core/plugins/oblsk_admin`): `fxmanifest.lua`, `shared/config.lua`, `.gitignore`

**Interfaces:**
- Produces: an empty-but-booting plugin registered in `plugins/registry.json`, with `Config.keybind` available for Task 5.

**⚠️ This task creates a new GitHub repository and runs `git push` — confirm with the user before running Steps 1-2 (repo creation) and Step 6 (push).**

- [ ] **Step 1: Create the GitHub repository**

```bash
gh repo create Obelisk-Framework/oblsk_admin --private --description "Obelisk staff admin panel"
```

- [ ] **Step 2: Clone it into place**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins
git clone git@github.com:Obelisk-Framework/oblsk_admin.git
cd oblsk_admin
```

- [ ] **Step 3: Write `fxmanifest.lua`**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Admin'
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
    'web/*.js',
}
```

- [ ] **Step 4: Write `shared/config.lua`**

```lua
Config = {}

--- Default key that opens/closes the staff panel. Players can't currently
--- override this (no per-plugin entry in oblsk_keybinds' resolver chain
--- yet) — editing this file is the only way to change it, matching how
--- every other plugin ships an unconfigurable default_key today.
Config.keybind = 'F6'

return Config
```

- [ ] **Step 5: Add a `.gitignore` matching sibling plugins**

```
node_modules/
.env
```

- [ ] **Step 6: Commit and push**

```bash
git add fxmanifest.lua shared/config.lua .gitignore
git commit -m "chore: scaffold oblsk_admin plugin"
git push -u origin main
```

- [ ] **Step 7: Register the plugin with the framework**

```bash
cd /home/andi/Projects/obelisk-framework/core
node cli/index.js registry:generate
```

- [ ] **Step 8: Verify (manual)**

Run: `cat /home/andi/Projects/obelisk-framework/core/plugins/registry.json`
Expected: the `plugins` array now includes `"oblsk_admin"`.

---

### Task 5: Access gate + panel toggle action + client open/close

**Files:**
- Create: `core/plugins/oblsk_admin/server/main.lua`
- Create: `core/plugins/oblsk_admin/client/main.lua`

**Interfaces:**
- Consumes: `ActionService.register` (core, existing), `Obelisk.emitClient`/`Obelisk.onClient` (core, existing), `WebView.showGlobalElement`/`hideGlobalElement`/`focus` (core, existing).
- Produces: server event `admin:client:toggle-panel` (no payload); the `isAdmin(source)` guard function, redefined identically in every server file in this plugin that needs it (Task 7 does the same).

- [ ] **Step 1: Write `server/main.lua`**

```lua
--- oblsk_admin server: panel open/close gate. Every other server file in
--- this plugin (organisations handlers, Task 7) redefines the same
--- isAdmin(source) guard locally — this codebase has no shared helper
--- module for it (see OrganizationCommands.lua/AccountCommands.lua for the
--- existing precedent). options.policies on ActionService.register is not
--- wired to anything today, so this guard is the real security boundary,
--- not a UX nicety layered on top of it.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

ActionService.register('admin:toggle-panel', function(source, data)
    if not isAdmin(source) then return end
    Obelisk.emitClient(source, 'admin:client:toggle-panel')
end, { label = 'Toggle admin panel', default_key = Config.keybind })
```

- [ ] **Step 2: Write `client/main.lua`**

```lua
--- oblsk_admin client: toggles the panel's global element and NUI focus.
--- Visibility lives entirely on the Vue side (core/web/src/App.vue's
--- `registry` Map, keyed by the globalElements.js name), driven by the
--- `core:client:webview-toggleGlobalElement` NUI message that
--- WebView.toggleGlobalElement sends -- so this file carries no local
--- open/closed state of its own, nothing to drift out of sync with ESC
--- (WebView.closeAll, wired NUI-side in App.vue) or the panel's own close
--- button (Task 6, emits the generic 'core:client:close' NUI callback).
Obelisk.onClient('admin:client:toggle-panel', function()
    WebView.toggleGlobalElement('admin')
    WebView.focus()
end)
```

- [ ] **Step 3: Manual verification**

1. Start the dev stack (`docker compose up fxserver` per repo convention) with the account you're testing as ACE'd `admin` in `server.cfg`.
2. In-game, press the configured keybind (`F6` by default).
3. Confirm: NUI focus is captured, a blank/placeholder panel background appears (no `AdminPanel.vue` yet — Task 6 adds the visible shell; this task's success criterion is that `WebView.showGlobalElement('admin')` is reached without a Lua error in the server console).
4. Press ESC, confirm focus releases.
5. Remove the `admin` ACE from the test account, confirm the keybind no longer opens anything (server console shows no `admin:client:toggle-panel` emission).

- [ ] **Step 4: Commit**

```bash
cd core/plugins/oblsk_admin
git add server/main.lua client/main.lua
git commit -m "feat: gate and wire the admin panel open/close action"
```

---

### Task 6: Web shell — `AdminPanel.vue` tab bar + placeholder

**Files:**
- Create: `core/plugins/oblsk_admin/web/globalElements.js`
- Create: `core/plugins/oblsk_admin/web/AdminPanel.vue`
- Create: `core/plugins/oblsk_admin/web/ComingSoon.vue`

**Interfaces:**
- Consumes: `Obelisk` (`core/web/src/obelisk.js`, `import Obelisk from '@/obelisk.js'`).
- Produces: tab state (`activeTab` ref) that Task 8's `OrganisationsTab.vue` slots into when `activeTab === 'organisations'`.

- [ ] **Step 1: Write `globalElements.js`**

```js
import AdminPanel from './AdminPanel.vue'

export default [
  { name: 'admin', component: AdminPanel, defaultVisible: false }
]
```

- [ ] **Step 2: Write `ComingSoon.vue`**

```vue
<script setup>
defineProps({ label: { type: String, required: true } })
</script>

<template>
  <div class="flex-1 grid place-items-center text-white/30">
    <div class="text-center">
      <div class="text-[13px]">{{ label }}</div>
      <div class="ob-mono text-[10px] mt-1 text-white/20">COMING SOON</div>
    </div>
  </div>
</template>
```

- [ ] **Step 3: Write `AdminPanel.vue`**

```vue
<script setup>
import { ref } from 'vue'
import Obelisk from '@/obelisk.js'
import ComingSoon from './ComingSoon.vue'
import OrganisationsTab from './OrganisationsTab.vue'

const TABS = [
  ['players', 'Players'], ['moderation', 'Moderation'], ['organisations', 'Organisations'],
  ['vehicles', 'Vehicles'], ['interactions', 'Interactions'], ['blips', 'Blips'],
  ['locations', 'Locations'], ['items', 'Items'], ['economy', 'Economy'],
  ['server', 'Server'], ['audit', 'Audit log'],
]

const activeTab = ref('organisations')

// 'core:client:close' is the framework-wide close NUI callback (WebView.on
// in core's client/main.lua calls WebView.closeAll() for it) -- the same
// path ESC already takes, so no plugin-local visibility state is needed.
const close = () => Obelisk.emit('core:client:close', {})
</script>

<template>
  <div class="absolute inset-0 flex flex-col" style="padding: 2.5vh 2vw">
    <div class="flex-1 rounded-2xl border border-white/12 bg-[#0d1012] shadow-2xl overflow-hidden flex flex-col">
      <div class="h-14 px-5 flex items-center justify-between border-b border-white/8 shrink-0">
        <div class="text-[14px] font-semibold">Staff Panel</div>
        <button @click="close" class="h-8 px-3 rounded-lg border border-white/12 text-[11.5px] hover:bg-white/8">Close</button>
      </div>

      <div class="h-11 px-5 flex items-center gap-1 border-b border-white/8 shrink-0 overflow-x-auto">
        <button v-for="[key, label] in TABS" :key="key" @click="activeTab = key"
          class="px-3 py-1.5 rounded-lg text-[12px] transition whitespace-nowrap"
          :class="activeTab === key ? 'text-black font-medium' : 'text-white/45 hover:text-white hover:bg-white/8'"
          :style="activeTab === key ? { background: 'var(--ob-accent)' } : undefined">
          {{ label }}
        </button>
      </div>

      <OrganisationsTab v-if="activeTab === 'organisations'" />
      <ComingSoon v-else :label="TABS.find(([k]) => k === activeTab)[1]" />
    </div>
  </div>
</template>
```

- [ ] **Step 4: Manual verification**

1. Since `OrganisationsTab.vue` doesn't exist yet (Task 8), temporarily comment out its `<script>` import and the `<OrganisationsTab ...>` line, replacing the template's `v-if` branch with `<ComingSoon label="Organisations" />` so the shell builds standalone.
2. Run the `core/web` dev server (`npm run dev` in `core/web`, per its own README/package.json scripts) and open the admin panel's dev route (check `core/web/src/router/index.js`'s glob — a global element isn't routed by default, so confirm with `oblsk_phone`'s dev-preview convention, e.g. a temporary `web/routes.js`, or toggle visibility via dev tools).
3. Confirm all 11 tabs render and switch correctly, each non-organisations tab shows "COMING SOON".
4. Revert the temporary comment-out once Task 8 lands.

- [ ] **Step 5: Commit**

```bash
cd core/plugins/oblsk_admin
git add web/globalElements.js web/AdminPanel.vue web/ComingSoon.vue
git commit -m "feat: admin panel shell with 11-tab bar"
```

---

### Task 7: Organisations NUI bridge (server + client relay)

**Files:**
- Create: `core/plugins/oblsk_admin/server/organisations.lua`
- Modify: `core/plugins/oblsk_admin/client/main.lua`

**Interfaces:**
- Consumes: `OrganizationService.list/create/setDetails/addDepartment/removeDepartment/addRank/removeRank/addContactNumber/removeContactNumber/toggleContactNumber` (Tasks 2/3), `NotificationService.error` (core, existing — same as `oblsk_keybinds/server/main.lua`'s usage).
- Produces: server events `admin:server:organisations-list`, `-create`, `-setDetails`, `-addDepartment`, `-removeDepartment`, `-addRank`, `-removeRank`, `-addContactNumber`, `-removeContactNumber`, `-toggleContactNumber`; client reply event `admin:client:organisations-reply` carrying `{ orgs }` (the full refreshed list, always — simplest correct approach: every mutation just re-sends `OrganizationService.list()`, avoiding the client having to reconcile partial updates). Task 8's Vue listens for `admin:client:organisations-reply`.

- [ ] **Step 1: Write `server/organisations.lua`**

```lua
--- oblsk_admin server: Organisations tab NUI handlers. Every mutation
--- replies with the full refreshed org list (OrganizationService.list())
--- rather than a partial patch -- the admin panel's org count is small
--- (tens, not thousands), so resending everything is simpler and can't
--- drift from what create/removeDepartment/etc. actually did.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

local function replyWithList(source)
    Obelisk.emitClient(source, 'admin:client:organisations-reply', { orgs = OrganizationService.list() })
end

Obelisk.onServer('admin:server:organisations-list', function()
    local source = source
    if not isAdmin(source) then return end
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-create', function(data)
    local source = source
    if not isAdmin(source) then return end
    local orgId = OrganizationService.create(data.name or 'New organisation')
    OrganizationService.setDetails(orgId, { shortCode = data.shortCode, colour = data.colour, type = data.type or 'Government' })
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-setDetails', function(data)
    local source = source
    if not isAdmin(source) then return end
    local ok, reason = OrganizationService.setDetails(data.orgId, { shortCode = data.shortCode, colour = data.colour, type = data.type })
    if not ok then
        NotificationService.error(source, 'Organisations', reason)
    end
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-addDepartment', function(data)
    local source = source
    if not isAdmin(source) then return end
    OrganizationService.addDepartment(data.orgId, data.name)
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-removeDepartment', function(data)
    local source = source
    if not isAdmin(source) then return end
    OrganizationService.removeDepartment(data.deptId)
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-addRank', function(data)
    local source = source
    if not isAdmin(source) then return end
    OrganizationService.addRank(data.orgId, data.name, data.grade or 0)
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-removeRank', function(data)
    local source = source
    if not isAdmin(source) then return end
    OrganizationService.removeRank(data.rankId)
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-addContactNumber', function(data)
    local source = source
    if not isAdmin(source) then return end
    OrganizationService.addContactNumber(data.orgId, data.number, data.label)
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-removeContactNumber', function(data)
    local source = source
    if not isAdmin(source) then return end
    OrganizationService.removeContactNumber(data.contactId)
    replyWithList(source)
end)

Obelisk.onServer('admin:server:organisations-toggleContactNumber', function(data)
    local source = source
    if not isAdmin(source) then return end
    OrganizationService.toggleContactNumber(data.contactId, data.enabled)
    replyWithList(source)
end)
```

- [ ] **Step 2: Add the client relays to `client/main.lua`**

Append to `core/plugins/oblsk_admin/client/main.lua`:

```lua
-- Thin relays: every admin:client:organisations-* NUI event forwards
-- verbatim to the matching admin:server:organisations-* handler.
local ORG_RELAYS = {
    'organisations-list', 'organisations-create', 'organisations-setDetails',
    'organisations-addDepartment', 'organisations-removeDepartment',
    'organisations-addRank', 'organisations-removeRank',
    'organisations-addContactNumber', 'organisations-removeContactNumber',
    'organisations-toggleContactNumber',
}
for _, name in ipairs(ORG_RELAYS) do
    WebView.on('admin:client:' .. name, function(data)
        Obelisk.emitServer('admin:server:' .. name, data)
    end)
end

Obelisk.onClient('admin:client:organisations-reply', function(payload)
    SendNUIMessage({ eventname = 'admin:client:organisations-reply', args = { payload } })
end)
```

- [ ] **Step 3: Manual verification**

1. Start the dev stack, open the browser devtools console on the NUI page (or FiveM's NUI devtools).
2. Run `Obelisk.emit('admin:client:organisations-list', {})` in the console.
3. Confirm the server console logs no errors, and (once Task 8's listener exists) `admin:client:organisations-reply` arrives with the seeded org list. Until Task 8 lands, confirm via `Obelisk.on('admin:client:organisations-reply', console.log)` registered manually in the console first.

- [ ] **Step 4: Commit**

```bash
cd core/plugins/oblsk_admin
git add server/organisations.lua client/main.lua
git commit -m "feat: organisations NUI bridge (server handlers + client relay)"
```

---

### Task 8: `OrganisationsTab.vue` — port the admin UI

**Files:**
- Create: `core/plugins/oblsk_admin/web/OrganisationsTab.vue`
- Modify: `core/plugins/oblsk_admin/web/AdminPanel.vue` (re-enable the real import/usage if Task 6 Step 4 commented it out)

**Interfaces:**
- Consumes: `admin:client:organisations-reply` (Task 7), emits `admin:client:organisations-*` events (Task 7's relays).

- [ ] **Step 1: Write `OrganisationsTab.vue`**

```vue
<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import Obelisk from '@/obelisk.js'

const orgs = ref([])
const selectedId = ref(null)
const draft = ref(null)
const newDept = ref('')
const newRankName = ref('')
const newRankGrade = ref(0)
const newContact = ref({ number: '', label: '' })

const selected = computed(() => orgs.value.find(o => o.id === selectedId.value) || orgs.value[0] || null)

const onReply = ({ orgs: nextOrgs }) => {
  orgs.value = nextOrgs
  if (!selectedId.value && nextOrgs.length) selectedId.value = nextOrgs[0].id
}

onMounted(() => {
  Obelisk.on('admin:client:organisations-reply', onReply)
  Obelisk.emit('admin:client:organisations-list', {})
})
onBeforeUnmount(() => Obelisk.off('admin:client:organisations-reply', onReply))

const createOrg = () => {
  draft.value = { name: '', shortCode: '', colour: '#3b82f6', type: 'Government' }
}
const submitCreate = () => {
  Obelisk.emit('admin:client:organisations-create', draft.value)
  draft.value = null
}

const setDetails = (org) => {
  Obelisk.emit('admin:client:organisations-setDetails', {
    orgId: org.id, shortCode: org.short_code, colour: org.colour, type: org.type,
  })
}

const addDepartment = (org) => {
  if (!newDept.value.trim()) return
  Obelisk.emit('admin:client:organisations-addDepartment', { orgId: org.id, name: newDept.value.trim() })
  newDept.value = ''
}
const removeDepartment = (deptId) => Obelisk.emit('admin:client:organisations-removeDepartment', { deptId })

const addRank = (org) => {
  if (!newRankName.value.trim()) return
  Obelisk.emit('admin:client:organisations-addRank', { orgId: org.id, name: newRankName.value.trim(), grade: Number(newRankGrade.value) || 0 })
  newRankName.value = ''
  newRankGrade.value = 0
}
const removeRank = (rankId) => Obelisk.emit('admin:client:organisations-removeRank', { rankId })

const addContactNumber = (org) => {
  if (!newContact.value.number.trim()) return
  Obelisk.emit('admin:client:organisations-addContactNumber', { orgId: org.id, number: newContact.value.number.trim(), label: newContact.value.label.trim() || 'Main line' })
  newContact.value = { number: '', label: '' }
}
const removeContactNumber = (contactId) => Obelisk.emit('admin:client:organisations-removeContactNumber', { contactId })
const toggleContactNumber = (contact) => Obelisk.emit('admin:client:organisations-toggleContactNumber', { contactId: contact.id, enabled: !contact.enabled })

const COLOURS = ['#3b82f6', '#10b981', '#e0b64a', '#f59e0b', '#ef4444', '#a78bfa']
</script>

<template>
  <div class="grid gap-3 min-h-0 p-5" style="grid-template-columns: 300px 1fr">
    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex flex-col">
      <div class="px-4 py-2.5 border-b border-white/8 flex items-center justify-between">
        <span class="text-[12.5px] font-medium">Organisations · {{ orgs.length }}</span>
        <button @click="createOrg" class="ob-mono text-[9px] px-1.5 py-0.5 rounded border border-white/12 hover:bg-white/8">+ NEW</button>
      </div>
      <div class="overflow-y-auto" style="max-height: 520px">
        <button v-for="o in orgs" :key="o.id" @click="selectedId = o.id; draft = null"
          class="w-full px-3.5 py-2.5 flex items-center gap-2.5 border-b border-white/6 text-left transition"
          :class="selectedId === o.id && !draft ? 'bg-white/[0.07]' : 'hover:bg-white/4'">
          <span class="w-2 h-8 rounded-full shrink-0" :style="{ background: o.colour || '#6b7280' }" />
          <span class="min-w-0 flex-1">
            <span class="block text-[12px] truncate">{{ o.name }}</span>
            <span class="block ob-mono text-[9px] text-white/35">{{ o.short_code || '—' }} · {{ o.departments.length }} DEPTS · {{ o.ranks.length }} RANKS</span>
          </span>
        </button>
        <div v-if="!orgs.length" class="py-6 text-center text-[11.5px] text-white/30">No organisations yet.</div>
      </div>
    </div>

    <div v-if="draft" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 space-y-3">
      <div class="text-[13px] font-medium">New organisation</div>
      <input v-model="draft.name" placeholder="Name" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
      <input v-model="draft.shortCode" placeholder="Short code" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
      <div class="flex gap-1.5">
        <button v-for="c in COLOURS" :key="c" @click="draft.colour = c" class="w-7 h-7 rounded-md"
          :style="{ background: c, outline: draft.colour === c ? '2px solid #fff' : '1px solid rgba(255,255,255,.12)' }" />
      </div>
      <div class="flex gap-1.5">
        <button v-for="t in ['Government', 'Business']" :key="t" @click="draft.type = t"
          class="h-8 px-2.5 rounded-lg text-[11.5px] transition"
          :class="draft.type === t ? 'text-black font-medium' : 'bg-white/[0.05] text-white/50'"
          :style="draft.type === t ? { background: 'var(--ob-accent)' } : undefined">{{ t }}</button>
      </div>
      <div class="flex gap-2 pt-1">
        <button @click="draft = null" class="h-9 px-3.5 rounded-lg border border-white/12 text-[12px]">Cancel</button>
        <button @click="submitCreate" class="h-9 px-4 rounded-lg text-black text-[12px] font-medium" style="background: var(--ob-accent)">Create organisation</button>
      </div>
    </div>

    <div v-else-if="selected" class="grid gap-3" style="grid-template-columns: 1fr 1fr">
      <div class="rounded-xl border border-white/10 bg-white/[0.03] p-4 col-span-2 grid gap-3" style="grid-template-columns: 1fr 140px 200px">
        <div>
          <div class="ob-mono text-[9px] tracking-[0.2em] text-white/30 uppercase mb-1.5">Name</div>
          <input v-model="selected.name" @change="setDetails(selected)" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
        </div>
        <div>
          <div class="ob-mono text-[9px] tracking-[0.2em] text-white/30 uppercase mb-1.5">Short code</div>
          <input v-model="selected.short_code" @change="setDetails(selected)" class="w-full h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
        </div>
        <div>
          <div class="ob-mono text-[9px] tracking-[0.2em] text-white/30 uppercase mb-1.5">Colour / type</div>
          <div class="flex gap-1.5 flex-wrap items-center">
            <button v-for="c in COLOURS" :key="c" @click="selected.colour = c; setDetails(selected)" class="w-7 h-7 rounded-md"
              :style="{ background: c, outline: selected.colour === c ? '2px solid #fff' : '1px solid rgba(255,255,255,.12)' }" />
            <button v-for="t in ['Government', 'Business']" :key="t" @click="selected.type = t; setDetails(selected)"
              class="h-7 px-2 rounded text-[10.5px]"
              :class="selected.type === t ? 'text-black font-medium' : 'bg-white/[0.05] text-white/50'"
              :style="selected.type === t ? { background: 'var(--ob-accent)' } : undefined">{{ t }}</button>
          </div>
        </div>
      </div>

      <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden">
        <div class="px-4 py-2.5 border-b border-white/8 text-[12.5px] font-medium">Departments · {{ selected.departments.length }}</div>
        <div class="p-3 space-y-1.5 overflow-y-auto" style="max-height: 220px">
          <div v-for="d in selected.departments" :key="d.id" class="flex items-center gap-2 rounded-lg border border-white/10 bg-black/30 px-2.5 h-9">
            <span class="text-[11.5px] flex-1 truncate">{{ d.name }}</span>
            <button @click="removeDepartment(d.id)" class="w-6 h-6 rounded text-white/30 hover:text-red-300">×</button>
          </div>
          <div v-if="!selected.departments.length" class="py-4 text-center text-[11.5px] text-white/30">No departments yet.</div>
        </div>
        <div class="p-3 border-t border-white/8 flex gap-2">
          <input v-model="newDept" placeholder="Add a department" class="flex-1 h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
          <button @click="addDepartment(selected)" class="h-9 px-3.5 rounded-lg text-black text-[12px] font-medium shrink-0" style="background: var(--ob-accent)">Add</button>
        </div>
      </div>

      <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden">
        <div class="px-4 py-2.5 border-b border-white/8 text-[12.5px] font-medium">Ranks · {{ selected.ranks.length }}</div>
        <div class="p-3 space-y-1.5 overflow-y-auto" style="max-height: 220px">
          <div v-for="r in selected.ranks" :key="r.id" class="flex items-center gap-2 rounded-lg border border-white/10 bg-black/30 px-2.5 h-9">
            <span class="ob-mono text-[9px] text-white/30 w-6 shrink-0">{{ r.grade }}</span>
            <span class="text-[11.5px] flex-1 truncate">{{ r.name }}</span>
            <button @click="removeRank(r.id)" class="w-6 h-6 rounded text-white/30 hover:text-red-300">×</button>
          </div>
          <div v-if="!selected.ranks.length" class="py-4 text-center text-[11.5px] text-white/30">No ranks yet.</div>
        </div>
        <div class="p-3 border-t border-white/8 flex gap-2">
          <input v-model="newRankName" placeholder="Rank name" class="flex-1 h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
          <input v-model.number="newRankGrade" type="number" placeholder="Grade" class="w-20 h-9 px-2 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
          <button @click="addRank(selected)" class="h-9 px-3.5 rounded-lg text-black text-[12px] font-medium shrink-0" style="background: var(--ob-accent)">Add</button>
        </div>
      </div>

      <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden col-span-2">
        <div class="px-4 py-2.5 border-b border-white/8 text-[12.5px] font-medium">Contact numbers · {{ selected.contact_numbers.length }}</div>
        <div class="p-3 flex flex-wrap gap-2">
          <div v-for="c in selected.contact_numbers" :key="c.id" class="flex items-center gap-2 rounded-lg border border-white/10 bg-black/30 px-2.5 h-9">
            <button @click="toggleContactNumber(c)" class="ob-mono text-[10px]" :style="{ color: c.enabled ? 'var(--ob-accent)' : 'rgba(255,255,255,.3)' }">{{ c.enabled ? 'ON' : 'OFF' }}</button>
            <span class="ob-mono text-[11px]">{{ c.number }}</span>
            <span class="text-[10.5px] text-white/40">{{ c.label }}</span>
            <button @click="removeContactNumber(c.id)" class="w-5 h-5 rounded text-white/30 hover:text-red-300">×</button>
          </div>
        </div>
        <div class="p-3 border-t border-white/8 flex gap-2">
          <input v-model="newContact.number" placeholder="Number" class="w-32 h-9 px-3 rounded-lg bg-black/40 border border-white/12 ob-mono text-[11.5px] outline-none" />
          <input v-model="newContact.label" placeholder="Label" class="flex-1 h-9 px-3 rounded-lg bg-black/40 border border-white/12 text-[11.5px] outline-none" />
          <button @click="addContactNumber(selected)" class="h-9 px-3.5 rounded-lg text-black text-[12px] font-medium shrink-0" style="background: var(--ob-accent)">Add</button>
        </div>
      </div>
    </div>

    <div v-else class="grid place-items-center text-white/30 text-[12px]">No organisation selected.</div>
  </div>
</template>
```

- [ ] **Step 2: Re-wire `AdminPanel.vue`**

If Task 6 Step 4 left `OrganisationsTab` commented out, uncomment the `import OrganisationsTab from './OrganisationsTab.vue'` line and the `<OrganisationsTab v-if="activeTab === 'organisations'" />` line in `AdminPanel.vue`.

- [ ] **Step 3: Manual verification (full flow)**

1. Rebuild `core/web` (or run its dev server) so the new component is picked up.
2. Start the dev stack, open the panel with the configured keybind as an ACE'd admin.
3. Click "+ NEW", fill name/short code/colour/type, submit — confirm it appears in the left list.
4. Select it, add a department, add a rank with a grade, add a contact number, toggle it off/on, remove each — confirm the left list's counts and the detail panel update live after every action (each round-trips through the server).
5. Try creating a second org with the same short code — confirm the server-side rejection surfaces (check `NotificationService.error`'s configured delivery — toast/chat, whatever `oblsk_keybinds`' equivalent call renders as — appears client-side).
6. Restart the dev stack (fresh NUI mount) and reopen the panel — confirm the list re-fetches via the `onMounted` → `admin:client:organisations-list` emit and shows the persisted data.

- [ ] **Step 4: Commit**

```bash
cd core/plugins/oblsk_admin
git add web/OrganisationsTab.vue web/AdminPanel.vue
git commit -m "feat: Organisations tab UI"
```

---

### Task 9: Final integration pass

**Files:** none new — verification only.

- [ ] **Step 1: Run every automated spec touched by this plan**

```bash
cd /home/andi/Projects/obelisk-framework/core
lua5.4 modules/oblsk_organizations/tests/organization_admin_fields_migration_spec.lua
lua5.4 modules/oblsk_organizations/tests/organization_service_admin_spec.lua
lua5.4 modules/oblsk_organizations/tests/organization_service_crud_spec.lua
lua5.4 modules/oblsk_organizations/tests/organization_service_membership_spec.lua
lua5.4 modules/oblsk_organizations/tests/department_rank_model_spec.lua
lua5.4 modules/oblsk_organizations/tests/character_delegate_spec.lua
lua5.4 tests/migration_audit_spec.lua
```
Expected: every one reports `0 failed`.

- [ ] **Step 2: Fresh-environment smoke test**

1. Bring up a clean dev database (`docker compose up mariadb` per `docs/guide/installation.md`, or reuse an existing dev DB you're fine wiping).
2. Start `fxserver`, confirm `[Migration] Added admin fields to organizations and created organization_contact_numbers table` prints once, no errors.
3. Confirm via a DB client: `DESCRIBE organizations;` shows `short_code`, `colour`, `type`; `DESCRIBE organization_contact_numbers;` exists with the FK.
4. Repeat Task 8 Step 3's full manual flow end-to-end once against this clean environment.

- [ ] **Step 3: Confirm the other ten tabs are inert, not broken**

Click through every non-Organisations tab in the panel — each must show "COMING SOON" with no console errors, confirming the shell doesn't assume tab-specific data that isn't there yet.

- [ ] **Step 4: Update the spec's status (optional but recommended)**

If this codebase tracks spec completion status anywhere (check the top of other completed specs under `core/docs/superpowers/specs/` for a convention, e.g. a "Status: Implemented" line) — apply the same marker to `2026-08-13-admin-panel-organisations-design.md` and commit.
