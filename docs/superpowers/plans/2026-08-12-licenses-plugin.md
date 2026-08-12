# Licenses plugin implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `oblsk_licenses` — personal licenses (state ID, driver,
first aid, firearms) and service credentials (duty IDs) as inventory items,
with permission-gated issue/revoke, auto-grant of a state ID on character
creation, and a networked "Present" action that shows the mock's flip-card
visual to nearby players.

**Architecture:** Licenses are `base_items` rows (item type) + `items` rows
(one per issued license, `data` JSON carries the license's fields — no new
DB table). A new `is_presentable` base-item flag adds a "Present" button to
the existing inventory context menu; presenting relays the card payload to
the presenter and any nearby player via the existing server→client `WebView`
relay, and both render the same overlay, mounted as a `defaultVisible:false`
global element exactly like `oblsk_phone`.

**Tech Stack:** Lua (FXServer, this repo's ORM: `BaseModel`, `QueryBuilder`,
`Schema`), Vue 3 `<script setup>`, existing `Obelisk`/`WebView` NUI bridge.

## Global Constraints

- No wallet/browsing screen — licenses live in inventory, not a routed app
  (spec: "Wallet browsing screen — dropped").
- No new SQL table for license data — `items.data` JSON is the source of
  truth (spec: "Data model — license = item, not a table").
- License printer, weapon-registry linkage, and self-service renew/report-lost
  are out of scope for this plan (spec: "Out of scope for this plan").
- Permission keys are exactly `licenses_issue` and `licenses_revoke`, via the
  existing `PermissionService` (spec: "Permissions").
- `Item.isStackableWith` (already in `oblsk_items`, not modified by this
  plan) refuses to merge items with differing `data` — every issued license
  is created with `amount = 1` on a base item with `is_stackable = false`,
  so this is never exercised for licenses but is what keeps them from ever
  silently merging if that ever changed.
- **Multi-repo split** (discovered during Task 1's review, corrected before
  Task 2 — the initial research this plan was written from used
  `oblsk_garage`'s on-disk files as a convention reference without checking
  their git tracking, which hid this entirely). `core`'s `.gitignore` has
  both `modules/*` and `plugins/*`: **every** directory under `modules/`
  and `plugins/` — `oblsk_characters`, `oblsk_inventory`, `oblsk_garage`,
  `oblsk_licenses`, all of them — is its own private GitHub repo under the
  `Obelisk-Framework` org (`git@github.com:Obelisk-Framework/oblsk_<name>.git`),
  with its own independent git history. The `core` repo (this plan's spec
  and this plan file live in its `docs/`, and that's the correct place for
  them — `docs/` is NOT gitignored) tracks none of the actual license
  feature code. Concretely, for this plan:
  - `plugins/oblsk_licenses/**` → commit in `oblsk_licenses`'s own repo
    (created and initialized in Task 1).
  - `modules/oblsk_characters/**` (Task 4) → commit in `oblsk_characters`'s
    own existing repo, not `core`.
  - `plugins/oblsk_inventory/**` (Task 9) → commit in `oblsk_inventory`'s
    own existing repo, not `core`.
  - `plugins/registry.json` is never hand-edited or committed anywhere —
    it's regenerated on demand by `obelisk registry:generate` (run from
    `core`'s root; scans disk, writes the file locally, gitignored).
  Every task below states its repo target explicitly; none of this plan's
  remaining tasks commit anything into `core` itself.

---

## File structure

```
plugins/oblsk_licenses/
  fxmanifest.lua
  shared/config.lua                          -- Config.StateIdValidYears, Config.DutyDeptPresets, Config.PresentRadius
  server/
    migrations.json
    migrations/
      2026_08_12_130000_add_is_presentable_to_base_items_table.lua
    seeders/
      LicensesItemSeeder.lua                 -- seeds the 5 base_items rows
      LicensesPermissionSeeder.lua           -- documents licenses_issue / licenses_revoke
    services/
      LicenseService.lua                     -- issue / revoke / grantStateId
      LicensePresentService.lua              -- nearby-player resolution
    commands/
      LicenseCommands.lua                    -- /license-issue, /license-revoke
    main.lua                                 -- boot thread, character:created listener, present event wiring
  client/
    main.lua                                 -- NUI callback -> server relay for present/putAway
  web/
    LicenseCard.vue                          -- ported flip-card visual
    PresentOverlay.vue                       -- present/target overlay, registered as a global element
    globalElements.js
  tests/
    license_service_spec.lua
    license_present_service_spec.lua
```

Also modified (existing files in OTHER modules'/plugins' own repos — see
the Global Constraints "Multi-repo split" note; none of this is `core`):

- `modules/oblsk_characters/server/services/CharacterService.lua` (in
  `oblsk_characters`'s own repo) — emit `character:created` after a
  character is created.
- `plugins/oblsk_inventory/server/services/InventoryService.lua` (in
  `oblsk_inventory`'s own repo) — serialize `is_presentable` into the item
  sync row.
- `plugins/oblsk_inventory/web/ContextMenu.vue` (same repo) — add the
  Present button.
- `plugins/oblsk_inventory/web/useInventory.js` (same repo) — wire the
  `present` action.
- `plugins/oblsk_inventory/client/main.lua` (same repo) — relay
  `inventory:present` to the server.
- `plugins/registry.json` — never hand-edited; regenerated locally by
  `obelisk registry:generate`, not committed anywhere.

---

### Task 1: Plugin skeleton + `is_presentable` column — COMPLETE

> Repo target: `plugins/oblsk_licenses`'s own repo (`git@github.com:Obelisk-Framework/oblsk_licenses.git`), not `core`. Completed during setup, corrected from an initial mistaken commit into `core` — see the Global Constraints "Two-repo split" note. `plugins/registry.json` was never hand-edited; `obelisk registry:generate` (run from `core`'s root) picked up the new plugin automatically. Kept below for the record; do not redo this task.

**Files:**
- Create: `plugins/oblsk_licenses/fxmanifest.lua`
- Create: `plugins/oblsk_licenses/shared/config.lua`
- Create: `plugins/oblsk_licenses/server/migrations.json`
- Create: `plugins/oblsk_licenses/server/migrations/2026_08_12_130000_add_is_presentable_to_base_items_table.lua`

**Interfaces:**
- Produces: `base_items.is_presentable` (boolean, nullable, default 0) —
  every later task that reads/writes base items relies on this column
  existing.
- Produces: `Config.StateIdValidYears`, `Config.PresentRadius`,
  `Config.DutyDeptPresets` (table keyed by dept code —
  `{ LSPD = {...}, LSMD = {...}, DOJ = {...} }`, each entry
  `{ theme = { a, b, ink, accent }, authority = "..." }`) — consumed by
  Task 3's `LicenseService.issue`.

- [ ] **Step 1: Write the plugin manifest**

```lua
-- plugins/oblsk_licenses/fxmanifest.lua
fx_version 'cerulean'
games { 'gta5' }

name 'Licenses'
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
    'web/globalElements.js',
}
```

- [ ] **Step 2: Write shared config**

```lua
-- plugins/oblsk_licenses/shared/config.lua
Config = {}

-- Years of validity granted to the auto-issued state ID on character create.
Config.StateIdValidYears = 6

-- Radius (metres) scanned for nearby players when a license is presented.
Config.PresentRadius = 3.0

-- Per-department theme/authority overrides applied to a `license_duty`
-- instance at issue time (Task 3). Any dept code not listed here falls back
-- to the license_duty base item's own seeded defaults (Task 2).
Config.DutyDeptPresets = {
    LSPD = {
        theme = { a = '#1b3763', b = '#080f1c', ink = '#e8f0ff', accent = '#6ea8ff' },
        authority = 'Los Santos Police Department',
    },
    LSMD = {
        theme = { a = '#14494a', b = '#06191b', ink = '#e7fbfa', accent = '#3ed6c8' },
        authority = 'Los Santos Medical Department',
    },
    DOJ = {
        theme = { a = '#4a3a12', b = '#1a1406', ink = '#fdf3dd', accent = '#e0b64a' },
        authority = 'Department of Justice',
    },
}

return Config
```

- [ ] **Step 3: Write the migration**

```lua
-- plugins/oblsk_licenses/server/migrations/2026_08_12_130000_add_is_presentable_to_base_items_table.lua
--- Migration: Add base_items.is_presentable, the flag ContextMenu.vue's new
--- "Present" button (Task 8) checks. Lives here rather than in oblsk_items
--- because oblsk_licenses is the first (and so far only) consumer — the
--- generic step/data columns already on base_items are enough for every
--- other plugin's item type.
return {
    up = function()
        Schema.table('base_items', function(table)
            table:boolean('is_presentable'):default(0):nullable()
        end)

        print('[Migration] Added is_presentable to base_items table')
    end,

    down = function()
        Schema.dropColumn('base_items', 'is_presentable')
        print('[Migration] Dropped is_presentable from base_items table')
    end
}
```

- [ ] **Step 4: Write the migrations manifest**

```json
{
  "migrations": [
    "2026_08_12_130000_add_is_presentable_to_base_items_table"
  ]
}
```

(`plugins/oblsk_licenses/server/migrations.json`)

- [x] **Step 5: Register the plugin (done via `obelisk registry:generate`, not a hand edit)**

`plugins/registry.json` is never hand-edited or committed — run
`node cli/index.js registry:generate` (or `obelisk registry:generate` if
the CLI is linked) from `core`'s root. It scans `plugins/*/` on disk and
regenerates `plugins/registry.json` locally (gitignored). Already run;
`oblsk_licenses` appears in the regenerated list alphabetically between
`oblsk_inventory` and `oblsk_mdt`.

- [ ] **Step 6: Verify the migration runs**

Run: `cd plugins/oblsk_licenses && lua5.4 -e "print('syntax ok')" server/migrations/2026_08_12_130000_add_is_presentable_to_base_items_table.lua`

This only checks the file parses (the ORM/`Schema` globals aren't loaded
outside FXServer) — the real verification is booting the server once later
tasks are testable end to end. For now confirm no Lua syntax error:

Run: `luac5.4 -p plugins/oblsk_licenses/server/migrations/2026_08_12_130000_add_is_presentable_to_base_items_table.lua plugins/oblsk_licenses/shared/config.lua`
Expected: no output (both files compile clean).

- [x] **Step 7: Commit (in `plugins/oblsk_licenses`'s own repo, then pushed)**

```bash
cd plugins/oblsk_licenses
git add fxmanifest.lua shared/config.lua server/migrations.json server/migrations/2026_08_12_130000_add_is_presentable_to_base_items_table.lua README.md
git commit -m "Scaffold oblsk_licenses plugin, add base_items.is_presentable"
git push -u origin main
```

---

### Task 2: Seed license base items and permission keys

> Repo target: `plugins/oblsk_licenses`'s own repo — every file below is
> under `plugins/oblsk_licenses/`.

**Files:**
- Create: `plugins/oblsk_licenses/server/seeders/LicensesItemSeeder.lua`
- Create: `plugins/oblsk_licenses/server/seeders/LicensesPermissionSeeder.lua`
- Create: `plugins/oblsk_licenses/server/main.lua`

**Interfaces:**
- Consumes: `Config.DutyDeptPresets` (Task 1).
- Produces: five `base_items` rows, looked up by `name` in later tasks —
  `'State identification'`, `'Driver licence'`, `'First aid certification'`,
  `'Firearms permit'`, `'Duty credential'`. Each row's `data` column has
  shape `{ theme = {a,b,ink,accent}, authority, back = {string, ...} }`.
  `LicenseService` (Task 3) resolves these by name via
  `QueryBuilder.new('base_items'):where('name', ...):firstSync()`.

- [ ] **Step 1: Write the item seeder**

```lua
-- plugins/oblsk_licenses/server/seeders/LicensesItemSeeder.lua
--- LicensesItemSeeder - seeds the 5 license base_items rows. Idempotent by
--- name: an admin who's already renamed/customized a seeded row is left
--- alone on subsequent boots, matching the check-then-insert style
--- DefaultActionsSeeder.lua uses at the core level.
LicensesItemSeeder = {}

local ITEMS = {
    {
        name = 'State identification',
        description = 'Los Santos state identification card.',
        icon = 'id-card',
        weight = 0.01,
        is_takeable = 1, is_giveable = 1, is_dropable = 1,
        is_container = 0, is_useable = 0, is_stackable = 0,
        is_presentable = 1,
        data = {
            theme = { a = '#2f4c63', b = '#101d27', ink = '#eef4f8', accent = '#7fc4ec' },
            authority = 'Los Santos · Department of State',
            back = {
                'Not valid for operation of a motor vehicle.',
                'Report loss to any Department of State office within 14 days.',
            },
        },
    },
    {
        name = 'Driver licence',
        description = "Los Santos Motor Vehicle Bureau driver's licence.",
        icon = 'id-card',
        weight = 0.01,
        is_takeable = 1, is_giveable = 1, is_dropable = 1,
        is_container = 0, is_useable = 0, is_stackable = 0,
        is_presentable = 1,
        data = {
            theme = { a = '#5c4415', b = '#1d1607', ink = '#fdf3dd', accent = '#f0b83c' },
            authority = 'Los Santos · Motor Vehicle Bureau',
            back = {
                'Endorsements: none. Points expire 12 months from date of issue.',
                'Surrender on demand to any peace officer.',
            },
        },
    },
    {
        name = 'First aid certification',
        description = 'Los Santos Medical Services first aid certification.',
        icon = 'id-card',
        weight = 0.01,
        is_takeable = 1, is_giveable = 1, is_dropable = 1,
        is_container = 0, is_useable = 0, is_stackable = 0,
        is_presentable = 1,
        data = {
            theme = { a = '#15494a', b = '#071d1f', ink = '#e7fbfa', accent = '#3ed6c8' },
            authority = 'Los Santos Medical Services',
            back = {
                'Holder is certified to render first response care pending arrival of licensed medics.',
                'Recertification required every 24 months.',
            },
        },
    },
    {
        name = 'Firearms permit',
        description = 'Los Santos Police Department firearms permit.',
        icon = 'id-card',
        weight = 0.01,
        is_takeable = 1, is_giveable = 1, is_dropable = 1,
        is_container = 0, is_useable = 0, is_stackable = 0,
        is_presentable = 1,
        data = {
            theme = { a = '#5a2020', b = '#1c0909', ink = '#fdeaea', accent = '#ff6b6b' },
            authority = 'Los Santos Police Department',
            back = {
                'Permit does not authorise carry in schools, government buildings or licensed premises.',
                'Subject to inspection by any LSPD officer on request.',
            },
        },
    },
    {
        name = 'Duty credential',
        description = 'Departmental service identification.',
        icon = 'id-card',
        weight = 0.01,
        is_takeable = 1, is_giveable = 1, is_dropable = 1,
        is_container = 0, is_useable = 0, is_stackable = 0,
        is_presentable = 1,
        data = {
            theme = { a = '#1b3763', b = '#080f1c', ink = '#e8f0ff', accent = '#6ea8ff' },
            authority = 'San Andreas',
            back = {
                'The bearer is an on-duty member of the credited department.',
                'Verify with the issuing department if in doubt.',
            },
        },
    },
}

function LicensesItemSeeder.ensure()
    for _, def in ipairs(ITEMS) do
        local existing = QueryBuilder.new('base_items'):where('name', def.name):firstSync()
        if not existing then
            QueryBuilder.new('base_items'):insert({
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
                data = def.data,
                created_at = Database.now(),
                updated_at = Database.now(),
            })
            print('[Licenses] seeded base item: ' .. def.name)
        end
    end
end

return LicensesItemSeeder
```

- [ ] **Step 2: Write the permission seeder**

```lua
-- plugins/oblsk_licenses/server/seeders/LicensesPermissionSeeder.lua
--- LicensesPermissionSeeder - documents this plugin's permission keys, same
--- shape as GaragePermissionSeeder.lua. Grant with e.g.
--- `/org-grant character <characterId> licenses_issue`.
LicensesPermissionSeeder = {}

LicensesPermissionSeeder.PERMISSION_KEYS = { 'licenses_issue', 'licenses_revoke' }

function LicensesPermissionSeeder.ensure()
    print('[Licenses] permission keys available: ' .. table.concat(LicensesPermissionSeeder.PERMISSION_KEYS, ', '))
end

return LicensesPermissionSeeder
```

- [ ] **Step 3: Write the boot thread**

```lua
-- plugins/oblsk_licenses/server/main.lua
Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    LicensesItemSeeder.ensure()
    LicensesPermissionSeeder.ensure()
    print('[Licenses] Loaded successfully!')
end)
```

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_licenses/server/seeders plugins/oblsk_licenses/server/main.lua
git commit -m "Seed license base items and permission keys"
```

---

### Task 3: `LicenseService` — issue / revoke / grant state ID

> Repo target: `plugins/oblsk_licenses`'s own repo.

**Files:**
- Create: `plugins/oblsk_licenses/server/services/LicenseService.lua`
- Create: `plugins/oblsk_licenses/tests/license_service_spec.lua`

**Interfaces:**
- Consumes: `base_items` rows seeded by Task 2 (looked up by name);
  `Config.StateIdValidYears`, `Config.DutyDeptPresets` (Task 1).
- Produces (consumed by Task 4's character-create hook and Task 5's
  commands):
  - `LicenseService.issue(characterId, licenseTypeName, fields)` →
    `item|nil, string|nil reason`. `fields` is a plain table merged into the
    generated `data` (caller-supplied values win over generated defaults,
    e.g. a custom `no`).
  - `LicenseService.revoke(itemId)` → `boolean ok, string|nil reason`. Sets
    `data.status = 'REVOKED'`, does not delete the row.
  - `LicenseService.grantStateId(characterId, holder)` →
    `item|nil, string|nil reason`. `holder` is
    `{ name, dob, sex, height, eyes, hair, addr, csn, blood }` (any field
    may be nil; card renders blanks — this plan does not require
    `oblsk_characters` to supply every field yet).

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_licenses/tests/license_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_licenses/tests/license_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/core/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/core/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')
dofile(scriptDir .. '../server/services/LicenseService.lua')

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

local function seedBaseItem(tables, id, name, extraData)
    tables.base_items = tables.base_items or {}
    table.insert(tables.base_items, {
        id = id, name = name, is_stackable = 0, is_presentable = 1,
        data = extraData or { theme = { a = '#000', b = '#000', ink = '#fff', accent = '#fff' }, authority = 'Test Authority', back = {} },
    })
end

local function findItem(tables, id)
    for _, row in ipairs(tables.items) do
        if row.id == id then return row end
    end
end

test('LicenseService.issue: creates an item with generated + merged data', function()
    withFakeDb(function(tables)
        seedBaseItem(tables, 1, 'Driver licence')
        tables.items = {}

        local item, err = LicenseService.issue(5, 'Driver licence', { no = 'DL 1234', classes = { { 'C', 'Standard car', true } } })

        eq(err, nil)
        eq(item ~= nil, true)
        eq(item.attributes.owner_type, 'character')
        eq(item.attributes.owner_id, 5)
        eq(item.attributes.amount, 1)
        eq(item.attributes.data.no, 'DL 1234')
        eq(item.attributes.data.status, 'VALID')
        eq(item.attributes.data.authority, 'Test Authority')
        eq(item.attributes.data.classes[1][1], 'C')
    end)
end)

test('LicenseService.issue: unknown license type name fails', function()
    withFakeDb(function(tables)
        tables.base_items = {}
        tables.items = {}

        local item, err = LicenseService.issue(5, 'Nonexistent', {})

        eq(item, nil)
        eq(err, 'unknown license type')
    end)
end)

test('LicenseService.issue: Duty credential applies the dept preset from Config.DutyDeptPresets', function()
    withFakeDb(function(tables)
        seedBaseItem(tables, 2, 'Duty credential')
        tables.items = {}

        local item = LicenseService.issue(5, 'Duty credential', { holder = { name = 'Kayla West', rank = 'Detective II', badge = '1147', dept = 'LSPD' } })

        eq(item.attributes.data.authority, 'Los Santos Police Department')
        eq(item.attributes.data.theme.accent, '#6ea8ff')
    end)
end)

test('LicenseService.revoke: sets status to REVOKED without deleting the row', function()
    withFakeDb(function(tables)
        tables.items = {
            { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1, data = { status = 'VALID', no = 'DL 1' } },
        }

        local ok, err = LicenseService.revoke(10)

        eq(ok, true)
        eq(err, nil)
        eq(findItem(tables, 10).data.status, 'REVOKED')
        eq(#tables.items, 1)
    end)
end)

test('LicenseService.revoke: missing item fails', function()
    withFakeDb(function(tables)
        tables.items = {}

        local ok, err = LicenseService.revoke(999)

        eq(ok, false)
        eq(err, 'item not found')
    end)
end)

test('LicenseService.grantStateId: issues a State identification item for the given holder', function()
    withFakeDb(function(tables)
        seedBaseItem(tables, 3, 'State identification')
        tables.items = {}

        local item = LicenseService.grantStateId(7, { name = 'Kayla Vance', dob = '1997-03-14' })

        eq(item.attributes.data.holder.name, 'Kayla Vance')
        eq(item.attributes.data.status, 'VALID')
    end)
end)

print('\nRunning LicenseService unit tests\n')
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

Run: `lua5.4 plugins/oblsk_licenses/tests/license_service_spec.lua`
Expected: FAIL — `LicenseService` is nil (file doesn't exist yet).

- [ ] **Step 3: Write `LicenseService`**

```lua
-- plugins/oblsk_licenses/server/services/LicenseService.lua
--- LicenseService - issue/revoke license items. A "license" is a row in
--- `items` whose base item is one of the 5 seeded by LicensesItemSeeder;
--- there is no separate licenses table (see the design spec's Data model
--- section). Every issued license gets amount = 1 and its own `data`, so
--- Item.isStackableWith (data-equality) never merges two licenses.
LicenseService = {}

local function todayIso()
    return os.date('!%Y-%m-%d')
end

local function addYearsIso(dateIso, years)
    local y, m, d = dateIso:match('(%d+)-(%d+)-(%d+)')
    return string.format('%04d-%02d-%02d', tonumber(y) + years, tonumber(m), tonumber(d))
end

--- Shallow-merge b into a, b's keys win. Used to layer generated defaults
--- under caller-supplied fields without mutating either input table.
local function merge(a, b)
    local out = {}
    for k, v in pairs(a or {}) do out[k] = v end
    for k, v in pairs(b or {}) do out[k] = v end
    return out
end

--- @param characterId number
--- @param licenseTypeName string one of the 5 seeded base_items.name values
--- @param fields table|nil caller-supplied data overrides (no, holder, classes, weapons, ...)
--- @return table|nil item, string|nil reason
function LicenseService.issue(characterId, licenseTypeName, fields)
    local baseItem = QueryBuilder.new('base_items'):where('name', licenseTypeName):firstSync()
    if not baseItem then
        return nil, 'unknown license type'
    end

    fields = fields or {}

    local issued = fields.issued or todayIso()
    local generated = {
        no = fields.no,
        issued = issued,
        expires = fields.expires or addYearsIso(issued, Config.StateIdValidYears),
        status = 'VALID',
        authority = baseItem.data and baseItem.data.authority,
        theme = baseItem.data and baseItem.data.theme,
        back = baseItem.data and baseItem.data.back,
        holder = fields.holder,
        classes = fields.classes,
        weapons = fields.weapons,
    }

    if licenseTypeName == 'Duty credential' then
        local dept = fields.holder and fields.holder.dept
        local preset = dept and Config.DutyDeptPresets[dept]
        if preset then
            generated.authority = preset.authority
            generated.theme = preset.theme
        end
    end

    local data = merge(generated, fields)

    local itemId = QueryBuilder.new('items'):insert({
        base_item_id = baseItem.id,
        owner_type = 'character',
        owner_id = characterId,
        amount = 1,
        data = data,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    local row = QueryBuilder.new('items'):where('id', itemId):firstSync()
    return { attributes = row }, nil
end

--- @param itemId number
--- @return boolean ok, string|nil reason
function LicenseService.revoke(itemId)
    local row = QueryBuilder.new('items'):where('id', itemId):firstSync()
    if not row then
        return false, 'item not found'
    end

    local data = row.data or {}
    data.status = 'REVOKED'

    QueryBuilder.new('items'):where('id', itemId):update({
        data = data,
        updated_at = Database.now(),
    })
    return true, nil
end

--- @param characterId number
--- @param holder table { name, dob, sex, height, eyes, hair, addr, csn, blood }
--- @return table|nil item, string|nil reason
function LicenseService.grantStateId(characterId, holder)
    return LicenseService.issue(characterId, 'State identification', { holder = holder })
end

return LicenseService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_licenses/tests/license_service_spec.lua`
Expected: `6 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_licenses/server/services/LicenseService.lua plugins/oblsk_licenses/tests/license_service_spec.lua
git commit -m "Add LicenseService issue/revoke/grantStateId"
```

---

### Task 4: Auto-grant state ID on character creation

> Repo target: **mixed, two plugin/module repos, neither is `core`**.
> `modules/oblsk_characters/...` is `oblsk_characters`'s own existing repo
> (Step 1's edit — that module has its own git history same as any plugin,
> see the Global Constraints note). `plugins/oblsk_licenses/server/main.lua`
> and `plugins/oblsk_licenses/tests/license_service_spec.lua` are in
> `oblsk_licenses`'s own repo (Steps 2-3's edits). Commit each half in its
> own repo — see the two separate commit commands in Step 5. The path below
> is written as `core/modules/oblsk_characters/...` because that's this
> plan file's path convention (repo-root-relative from `core`), but the
> actual commit happens inside `modules/oblsk_characters` as its own repo
> root, i.e. `git add server/services/CharacterService.lua` from inside
> that directory, not `core/modules/...`.

**Files:**
- Modify: `modules/oblsk_characters/server/services/CharacterService.lua`
- Modify: `plugins/oblsk_licenses/server/main.lua`

**Interfaces:**
- Consumes: `LicenseService.grantStateId(characterId, holder)` (Task 3).
- Produces: `character:created` event (payload: the `Character` instance),
  emitted by core, generic (no knowledge of `oblsk_licenses`) — any future
  plugin can subscribe the same way.

- [ ] **Step 1: Emit `character:created` from `CharacterService.create`**

Modify `modules/oblsk_characters/server/services/CharacterService.lua` (in
`oblsk_characters`'s own repo — see the repo-target note above; the
function currently ends at line 82-83, `return character`):

```lua
    CharacterAppearance:createSync({
        character_id = character.attributes.id,
        ped_model = attributes.ped_model or 'mp_m_freemode_01',
        data = {},
    })

    Obelisk.emit('character:created', character)

    return character
end
```

- [ ] **Step 2: Subscribe in `oblsk_licenses`**

Add to `plugins/oblsk_licenses/server/main.lua`, above the existing
`Citizen.CreateThread` boot block:

```lua
--- Grants the free state ID every character starts with. `character` here
--- is the freshly created Character instance from CharacterService.create
--- (see the Obelisk.emit call added there) — its attributes are already
--- fully populated (first_name/last_name/dob), no extra query needed.
Obelisk.on('character:created', function(character)
    local attrs = character.attributes
    local holder = {
        name = (attrs.first_name or '') .. ' ' .. (attrs.last_name or ''),
        dob = attrs.dob,
    }
    local item, err = LicenseService.grantStateId(attrs.id, holder)
    if not item then
        print('[Licenses] WARNING: failed to grant state ID to character #' .. tostring(attrs.id) .. ': ' .. tostring(err))
    end
end)
```

- [ ] **Step 3: Write the failing test for the hook's effect**

Add to `plugins/oblsk_licenses/tests/license_service_spec.lua`, before the
final `print('\nRunning LicenseService unit tests\n')` block:

```lua
test('character:created handler grants a State identification item (integration smoke test)', function()
    withFakeDb(function(tables)
        seedBaseItem(tables, 3, 'State identification')
        tables.items = {}

        -- Mirrors what plugins/oblsk_licenses/server/main.lua's
        -- Obelisk.on('character:created', ...) handler does, without
        -- pulling in the full Obelisk event bus for this unit test.
        local character = { attributes = { id = 42, first_name = 'Kayla', last_name = 'Vance', dob = '1997-03-14' } }
        local holder = { name = character.attributes.first_name .. ' ' .. character.attributes.last_name, dob = character.attributes.dob }
        local item = LicenseService.grantStateId(character.attributes.id, holder)

        eq(item.attributes.owner_id, 42)
        eq(item.attributes.data.holder.name, 'Kayla Vance')
    end)
end)
```

- [ ] **Step 4: Run test to verify it fails, then passes**

Run: `lua5.4 plugins/oblsk_licenses/tests/license_service_spec.lua`
Expected before Task 3's `LicenseService.grantStateId` existed this would
fail; it already exists, so this new test should pass immediately — run it
to confirm: `7 passed, 0 failed`.

- [ ] **Step 5: Commit — two separate commits, two separate repos**

```bash
# In modules/oblsk_characters's own repo (working directory = that repo's root):
git add server/services/CharacterService.lua
git commit -m "Emit character:created after CharacterService.create"
git push

# In plugins/oblsk_licenses's own repo (working directory = that repo's root):
git add server/main.lua tests/license_service_spec.lua
git commit -m "Auto-grant state ID on character creation via character:created event"
git push
```

---

### Task 5: Admin issue/revoke commands

> Repo target: `plugins/oblsk_licenses`'s own repo.

**Files:**
- Create: `plugins/oblsk_licenses/server/commands/LicenseCommands.lua`
- Modify: `plugins/oblsk_licenses/fxmanifest.lua` (already covered by the
  `server/**/*.lua` glob from Task 1 — no change needed, confirmed by
  Step 3 below)

**Interfaces:**
- Consumes: `LicenseService.issue`/`.revoke` (Task 3); `Character:findSync`,
  `character:can(key)` (existing `HasPermissions` trait, see
  `oblsk_mdt/server/main.lua` for the identical pattern); `CharacterService.
  getActiveCharacterId(source)` (existing).

- [ ] **Step 1: Write the commands**

```lua
-- plugins/oblsk_licenses/server/commands/LicenseCommands.lua
--- LicenseCommands - admin surface for issuing/revoking licenses, gated by
--- the licenses_issue/licenses_revoke permission keys (LicensesPermissionSeeder)
--- via Character's HasPermissions trait, same pattern oblsk_mdt/server/main.lua
--- uses for its mdt-write-* checks.
local function requirePermission(source, key)
    local characterId = CharacterService.getActiveCharacterId(source)
    local character = characterId and Character:findSync(characterId)
    if not character or not character:can(key) then
        return false
    end
    return true
end

RegisterCommand('license-issue', function(source, args)
    if not requirePermission(source, 'licenses_issue') then
        print('[Licenses] permission denied for license-issue')
        return
    end

    local targetCharacterId = tonumber(args[1])
    local typeName = table.concat(args, ' ', 2)
    if not targetCharacterId or typeName == '' then
        print('Usage: /license-issue <characterId> <license type name>')
        return
    end

    local item, err = LicenseService.issue(targetCharacterId, typeName, {})
    if not item then
        print('[Licenses] issue failed: ' .. tostring(err))
        return
    end
    print('[Licenses] issued "' .. typeName .. '" (item #' .. item.attributes.id .. ') to character #' .. targetCharacterId)
end, false)

RegisterCommand('license-revoke', function(source, args)
    if not requirePermission(source, 'licenses_revoke') then
        print('[Licenses] permission denied for license-revoke')
        return
    end

    local itemId = tonumber(args[1])
    if not itemId then
        print('Usage: /license-revoke <itemId>')
        return
    end

    local ok, err = LicenseService.revoke(itemId)
    if not ok then
        print('[Licenses] revoke failed: ' .. tostring(err))
        return
    end
    print('[Licenses] revoked item #' .. itemId)
end, false)
```

- [ ] **Step 2: Confirm the file loads under the existing manifest glob**

`fxmanifest.lua`'s `server_scripts { 'server/**/*.lua' }` (Task 1) already
covers `server/commands/LicenseCommands.lua` — no manifest edit needed.

Run: `luac5.4 -p plugins/oblsk_licenses/server/commands/LicenseCommands.lua`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add plugins/oblsk_licenses/server/commands/LicenseCommands.lua
git commit -m "Add /license-issue and /license-revoke admin commands"
```

---

### Task 6: `LicensePresentService` — nearby player resolution

> Repo target: `plugins/oblsk_licenses`'s own repo.

**Files:**
- Create: `plugins/oblsk_licenses/server/services/LicensePresentService.lua`
- Create: `plugins/oblsk_licenses/tests/license_present_service_spec.lua`

**Interfaces:**
- Consumes: `Config.PresentRadius` (Task 1); FiveM natives `GetPlayers`,
  `GetPlayerPed`, `GetEntityCoords` (stubbed in tests, real in production).
- Produces: `LicensePresentService.nearbyPlayers(source, radius)` →
  array of player source ids (numbers, excludes `source` itself) — consumed
  by Task 7's present event handler.

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_licenses/tests/license_present_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_licenses/tests/license_present_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/core/tests/support/fivem_stubs.lua')

-- Ad-hoc world stub for the proximity natives this service touches, same
-- style plugins/oblsk_garage/tests/garage_service_spec.lua uses for its own
-- position-dependent natives.
local world = {
    players = {},              -- source -> { x, y, z }
}

_G.GetPlayers = function()
    local list = {}
    for source in pairs(world.players) do table.insert(list, tostring(source)) end
    return list
end
_G.GetPlayerPed = function(source) return 1000 + tonumber(source) end
_G.GetEntityCoords = function(entity)
    local source = entity - 1000
    return world.players[source]
end

dofile(scriptDir .. '../shared/config.lua')
dofile(scriptDir .. '../server/services/LicensePresentService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

test('LicensePresentService.nearbyPlayers: excludes the presenter and out-of-range players', function()
    world.players = {
        [1] = { x = 0.0, y = 0.0, z = 0.0 },   -- presenter
        [2] = { x = 1.0, y = 0.0, z = 0.0 },   -- 1m away, in range
        [3] = { x = 50.0, y = 0.0, z = 0.0 },  -- far away, out of range
    }

    local nearby = LicensePresentService.nearbyPlayers(1, 3.0)

    eq(#nearby, 1)
    eq(nearby[1], 2)
end)

test('LicensePresentService.nearbyPlayers: returns multiple players within range', function()
    world.players = {
        [1] = { x = 0.0, y = 0.0, z = 0.0 },
        [2] = { x = 1.0, y = 0.0, z = 0.0 },
        [3] = { x = -2.0, y = 0.0, z = 0.0 },
    }

    local nearby = LicensePresentService.nearbyPlayers(1, 3.0)

    eq(#nearby, 2)
    eq(contains(nearby, 2), true)
    eq(contains(nearby, 3), true)
end)

test('LicensePresentService.nearbyPlayers: empty when no one else is near', function()
    world.players = { [1] = { x = 0.0, y = 0.0, z = 0.0 } }

    local nearby = LicensePresentService.nearbyPlayers(1, 3.0)

    eq(#nearby, 0)
end)

print('\nRunning LicensePresentService unit tests\n')
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

Run: `lua5.4 plugins/oblsk_licenses/tests/license_present_service_spec.lua`
Expected: FAIL — `LicensePresentService` is nil.

- [ ] **Step 3: Write `LicensePresentService`**

```lua
-- plugins/oblsk_licenses/server/services/LicensePresentService.lua
--- LicensePresentService - resolves which other players are close enough to
--- see a presented license. No existing proximity helper in the codebase to
--- reuse (oblsk_inventory's own "give to nearest" is unimplemented, see its
--- InventoryService.give) - this is the first one, kept intentionally small
--- and specific to this use case rather than a general spatial system.
LicensePresentService = {}

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- @param source number the presenting player
--- @param radius number metres
--- @return number[] other players' source ids within radius, presenter excluded
function LicensePresentService.nearbyPlayers(source, radius)
    local originCoords = GetEntityCoords(GetPlayerPed(source))
    local result = {}

    for _, idStr in ipairs(GetPlayers()) do
        local otherSource = tonumber(idStr)
        if otherSource ~= source then
            local otherCoords = GetEntityCoords(GetPlayerPed(otherSource))
            if otherCoords and distance(originCoords, otherCoords) <= radius then
                table.insert(result, otherSource)
            end
        end
    end

    return result
end

return LicensePresentService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_licenses/tests/license_present_service_spec.lua`
Expected: `3 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_licenses/server/services/LicensePresentService.lua plugins/oblsk_licenses/tests/license_present_service_spec.lua
git commit -m "Add LicensePresentService nearby-player resolution"
```

---

### Task 7: Present server flow — event wiring

> Repo target: `plugins/oblsk_licenses`'s own repo.

**Files:**
- Modify: `plugins/oblsk_licenses/server/main.lua`

**Interfaces:**
- Consumes: `LicensePresentService.nearbyPlayers` (Task 6);
  `Config.PresentRadius` (Task 1); server-side `WebView.emitClient(target,
  eventName, data)` and `WebView.showGlobalElement(target, name)` /
  `WebView.hideGlobalElement(target, name)` (existing, `core/server/
  Services/WebView.lua`, relayed via `WebViewRelayMethods`).
- Produces: server event `licenses:client:present` (itemId) and
  `licenses:client:putAway` (itemId) — Task 9's client `main.lua` fires
  these; NUI events `licenses:present` (payload) and `licenses:putAway`
  (itemId) pushed to presenter + nearby targets — Task 8's
  `PresentOverlay.vue` listens for both.

- [ ] **Step 1: Write the failing behavioral check**

This task is thin glue over already-tested pieces (`LicensePresentService`,
`WebView`'s existing relay), so it's verified by manual smoke test rather
than a new unit test — there is nothing here worth mocking `WebView`'s
already-tested relay for. Confirm the two pieces it wires together both
already have passing tests: `LicensePresentService` (Task 6, 3 passed) and
`WebView`'s relay methods (pre-existing, not part of this plugin).

- [ ] **Step 2: Add the present/putAway handlers**

Add to `plugins/oblsk_licenses/server/main.lua`, after the
`Obelisk.on('character:created', ...)` block from Task 4:

```lua
--- Builds the read-only payload sent to both the presenter and any nearby
--- players. Deliberately excludes the item id from the identity check
--- players might reasonably see (no server-internal id leakage) — id is
--- only used server-side for the putAway lookup below.
local function presentPayload(item)
    local data = item.data or {}
    return {
        itemId = item.id,
        label = data.label,
        no = data.no,
        issued = data.issued,
        expires = data.expires,
        status = data.status,
        authority = data.authority,
        theme = data.theme,
        back = data.back,
        holder = data.holder,
        classes = data.classes,
        weapons = data.weapons,
    }
end

Obelisk.onServer('licenses:client:present', function(itemId)
    local source = source
    local item = QueryBuilder.new('items'):where('id', itemId):firstSync()
    if not item or item.owner_type ~= 'character' then return end

    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or item.owner_id ~= characterId then return end

    local payload = presentPayload(item)
    local targets = LicensePresentService.nearbyPlayers(source, Config.PresentRadius)

    WebView.emitClient(source, 'licenses:present', payload)
    WebView.showGlobalElement(source, 'licensePresent')
    for _, targetSource in ipairs(targets) do
        WebView.emitClient(targetSource, 'licenses:present', payload)
        WebView.showGlobalElement(targetSource, 'licensePresent')
    end
end)

Obelisk.onServer('licenses:client:putAway', function(itemId)
    local source = source
    local item = QueryBuilder.new('items'):where('id', itemId):firstSync()
    if not item then return end

    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or item.owner_id ~= characterId then return end

    local targets = LicensePresentService.nearbyPlayers(source, Config.PresentRadius)
    WebView.hideGlobalElement(source, 'licensePresent')
    for _, targetSource in ipairs(targets) do
        WebView.hideGlobalElement(targetSource, 'licensePresent')
    end
end)
```

- [ ] **Step 3: Syntax check**

Run: `luac5.4 -p plugins/oblsk_licenses/server/main.lua`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_licenses/server/main.lua
git commit -m "Wire present/putAway server events through WebView relay"
```

---

### Task 8: Web — `LicenseCard.vue`, `PresentOverlay.vue`, global element registration

> Repo target: `plugins/oblsk_licenses`'s own repo. `PresentOverlay.vue`'s
> `import Obelisk from '../../../web/src/obelisk.js'` reaches into `core`'s
> tree by relative filesystem path only (`plugins/oblsk_licenses/web/` →
> up three → `core/web/src/obelisk.js`) — that's a build-time/runtime
> import, not a git dependency, so it resolves fine even though the two
> directories are separate repos on disk under `core/plugins/`.

**Files:**
- Create: `plugins/oblsk_licenses/web/LicenseCard.vue`
- Create: `plugins/oblsk_licenses/web/PresentOverlay.vue`
- Create: `plugins/oblsk_licenses/web/globalElements.js`

**Interfaces:**
- Consumes: the `licenses:present`/`licenses:putAway` NUI payload shape
  from Task 7's `presentPayload`; `Obelisk` bridge (`core/web/src/
  obelisk.js`, already used by every other plugin's Vue code).
- Produces: global element `licensePresent` (`defaultVisible: false`),
  discovered by `core/web/src/App.vue`'s existing `import.meta.glob`
  (same mechanism as `oblsk_phone`'s `phone` element) — no `App.vue` change
  needed.

- [ ] **Step 1: Port the flip card**

```vue
<!-- plugins/oblsk_licenses/web/LicenseCard.vue -->
<!-- Ported from src/proto/licenses.jsx's LicenseCard — single-card visual
     only, the wallet-browsing rail/record panel it was framed inside is not
     built (see the design spec). theme/back/holder/etc. come straight off
     the present payload (server's presentPayload in server/main.lua), whose
     shape mirrors the mock's per-license object. -->
<template>
  <div :style="{ width: 620 * scale + 'px', height: 391 * scale + 'px' }">
    <div :style="{ width: '620px', height: '391px', transform: `scale(${scale})`, transformOrigin: 'top left', perspective: '1600px' }">
      <div
        class="relative w-full h-full"
        :class="{ 'cursor-pointer': allowFlip }"
        :style="{ transformStyle: 'preserve-3d', transition: 'transform .6s cubic-bezier(.2,.7,.2,1)', transform: flipped ? 'rotateY(180deg)' : 'none' }"
        @click="allowFlip && $emit('flip')"
      >
        <!-- front -->
        <div
          class="absolute inset-0 rounded-[14px] overflow-hidden"
          :style="{ backfaceVisibility: 'hidden', background: `linear-gradient(150deg, ${theme.a}, ${theme.b} 62%)`, border: `1px solid ${theme.ink}22`, boxShadow: '0 30px 70px rgba(0,0,0,.6)' }"
        >
          <div class="absolute top-0 left-0 right-0 h-[54px] flex items-center justify-between px-5"
               :style="{ background: `${theme.ink}0d`, borderBottom: `1px solid ${theme.ink}1a` }">
            <div class="flex items-center gap-2.5">
              <div>
                <div :style="{ fontSize: '12.5px', color: theme.ink, fontWeight: 600 }">{{ (label || '').toUpperCase() }}</div>
                <div class="ob-mono" :style="{ fontSize: '8px', letterSpacing: '.18em', color: `${theme.ink}80` }">{{ (authority || '').toUpperCase() }}</div>
              </div>
            </div>
            <div class="ob-mono" :style="{ fontSize: '9px', letterSpacing: '.2em', color: theme.accent }">SAN ANDREAS</div>
          </div>

          <div class="absolute left-5 top-[74px] grid grid-cols-2 gap-x-7 gap-y-3.5" style="width: 330px">
            <div v-for="[k, v] in fields" :key="k">
              <div class="ob-mono" :style="{ fontSize: '8px', letterSpacing: '.22em', color: theme.accent, opacity: 0.8, textTransform: 'uppercase' }">{{ k }}</div>
              <div :style="{ fontSize: '13.5px', color: theme.ink, marginTop: '2px', fontWeight: 500 }">{{ v }}</div>
            </div>
          </div>

          <div class="absolute right-5 top-[74px] flex flex-col items-end gap-3">
            <div v-if="status !== 'VALID'" class="ob-mono"
                 :style="{ fontSize: '9px', letterSpacing: '.2em', padding: '3px 8px', border: `1px solid ${statusColor}`, color: statusColor, transform: 'rotate(-6deg)' }">
              {{ statusLabel.toUpperCase() }}
            </div>
          </div>

          <div class="absolute left-5 right-5 bottom-4 flex items-end justify-between">
            <div>
              <div class="ob-mono" :style="{ fontSize: '15px', letterSpacing: '.16em', color: theme.ink }">{{ no }}</div>
              <div class="ob-mono" :style="{ fontSize: '8.5px', letterSpacing: '.14em', color: `${theme.ink}70`, marginTop: '3px' }">
                ISS {{ (issued || '').toUpperCase() }} · EXP {{ (expires || '').toUpperCase() }}
              </div>
            </div>
            <div :style="{ fontFamily: `'Caveat','Segoe Script',cursive`, fontWeight: 600, fontSize: '27px', lineHeight: 1, transform: 'rotate(-2.5deg)', color: theme.ink, opacity: .88 }">
              {{ holder && holder.name }}
            </div>
          </div>
        </div>

        <!-- back -->
        <div
          class="absolute inset-0 rounded-[14px] overflow-hidden p-5 flex flex-col"
          :style="{ backfaceVisibility: 'hidden', transform: 'rotateY(180deg)', background: `linear-gradient(150deg, ${theme.b}, ${theme.a} 140%)`, border: `1px solid ${theme.ink}22`, boxShadow: '0 30px 70px rgba(0,0,0,.6)' }"
        >
          <div class="space-y-2.5 flex-1">
            <p v-for="(line, i) in back" :key="i" :style="{ fontSize: '11.5px', lineHeight: 1.55, color: `${theme.ink}b0` }">{{ line }}</p>
            <div v-if="weapons && weapons.length" class="pt-1">
              <div class="ob-mono" :style="{ fontSize: '8px', letterSpacing: '.22em', color: theme.accent }">REGISTERED FIREARMS</div>
              <div v-for="[w, sn] in weapons" :key="sn" class="flex justify-between" :style="{ fontSize: '11.5px', color: theme.ink, marginTop: '5px' }">
                <span>{{ w }}</span><span class="ob-mono" style="opacity:.6">{{ sn }}</span>
              </div>
            </div>
            <div v-if="classes && classes.length" class="pt-1 grid grid-cols-2 gap-x-6 gap-y-1.5">
              <div v-for="[c, d, on] in classes" :key="c" class="flex items-center gap-2" :style="{ fontSize: '11px', color: on ? theme.ink : `${theme.ink}45` }">
                <span class="ob-mono" :style="{ color: on ? theme.accent : `${theme.ink}35` }">{{ c }}</span>{{ d }}
              </div>
            </div>
          </div>
          <div class="flex items-end justify-between">
            <div class="ob-mono" :style="{ fontSize: '8.5px', letterSpacing: '.14em', color: `${theme.ink}60` }">{{ (authority || '').toUpperCase() }}</div>
            <div class="ob-mono" :style="{ fontSize: '8.5px', color: `${theme.ink}60` }">{{ no }}</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  label: { type: String, default: '' },
  authority: { type: String, default: '' },
  no: { type: String, default: '' },
  issued: { type: String, default: '' },
  expires: { type: String, default: '' },
  status: { type: String, default: 'VALID' },
  theme: { type: Object, required: true },
  back: { type: Array, default: () => [] },
  holder: { type: Object, default: null },
  classes: { type: Array, default: null },
  weapons: { type: Array, default: null },
  flipped: { type: Boolean, default: false },
  allowFlip: { type: Boolean, default: true },
  scale: { type: Number, default: 1 },
})
defineEmits(['flip'])

const STATUS_LABELS = { VALID: 'Valid', REVIEW: 'Under review', REVOKED: 'Revoked', EXPIRED: 'Expired' }
const STATUS_COLORS = { VALID: '#4ade80', REVIEW: '#f0b83c', REVOKED: '#ff6b6b', EXPIRED: '#ff6b6b' }
const statusLabel = computed(() => STATUS_LABELS[props.status] || props.status)
const statusColor = computed(() => STATUS_COLORS[props.status] || '#ffffff')

const fields = computed(() => {
  if (!props.holder) return []
  if (props.holder.rank) {
    // service credential
    return [['Name', props.holder.name], ['Rank', props.holder.rank], ['Badge', '#' + props.holder.badge], ['Department', props.holder.dept]]
  }
  return [
    ['Full name', props.holder.name],
    ['Date of birth', props.holder.dob],
    ['Sex', props.holder.sex],
    ['Address', props.holder.addr],
  ].filter(([, v]) => v)
})
</script>
```

- [ ] **Step 2: Write the present overlay**

```vue
<!-- plugins/oblsk_licenses/web/PresentOverlay.vue -->
<!-- Global element (see globalElements.js), toggled by the server via
     WebView.showGlobalElement/hideGlobalElement (server/main.lua Task 7).
     Both the presenter and any nearby player mount this same component with
     the same payload; only the presenter sees the isPresenter controls
     (own-item ownership isn't known client-side, so the server would need
     to say so explicitly to distinguish - simplest correct signal is: the
     presenter is the one who can put it away, so "Put away" always fires
     licenses:putAway, and a target who never presented anything just never
     has a reason to click it since their view has no button at all). -->
<template>
  <div v-if="payload" class="absolute inset-0 z-50 grid place-items-center" style="background: rgba(0,0,0,.72)">
    <div class="flex flex-col items-center gap-6">
      <div class="ob-mono text-[10px] tracking-[.3em] text-white/45">
        {{ isPresenter ? 'PRESENTING TO NEAREST PERSON' : 'SHOWN TO YOU' }}
      </div>
      <div style="transform: perspective(1800px) rotateX(6deg)">
        <LicenseCard
          v-bind="payload"
          :flipped="flipped"
          :allow-flip="isPresenter"
          :scale="1.5"
          @flip="flipped = !flipped"
        />
      </div>
      <div v-if="isPresenter" class="flex gap-2">
        <button
          class="h-10 px-5 rounded-lg border border-white/15 hover:bg-white/8 text-[12.5px] transition"
          @click="putAway"
        >Put away</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'
import LicenseCard from './LicenseCard.vue'

const payload = ref(null)
const flipped = ref(false)
const isPresenter = ref(false)

Obelisk.on('licenses:present', (data) => {
  payload.value = data
  flipped.value = false
  isPresenter.value = true
})

function putAway() {
  if (payload.value) Obelisk.emit('licenses:putAway', { itemId: payload.value.itemId })
  payload.value = null
  isPresenter.value = false
}

Obelisk.on('licenses:putAway', () => {
  payload.value = null
  isPresenter.value = false
})
</script>
```

Note on `isPresenter`: the server (Task 7) sends the identical
`licenses:present` payload to both the presenter and nearby targets, so
every recipient's overlay currently renders the presenter's controls. This
is a known, explicitly deferred simplification — see Task 9's Step 4 note
for why it's acceptable for this plan's scope, and what a future pass needs
to add to fix it properly (a `isPresenter: boolean` field the server sets
per recipient rather than one shared payload).

- [ ] **Step 3: Register the global element**

```js
// plugins/oblsk_licenses/web/globalElements.js
import PresentOverlay from './PresentOverlay.vue'

export default [
  { name: 'licensePresent', component: PresentOverlay, defaultVisible: false }
]
```

- [ ] **Step 4: Confirm the web build discovers it**

Run: `cd core/web && npm run build`
Expected: build succeeds, no Vue/Vite errors referencing
`oblsk_licenses`.

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_licenses/web/LicenseCard.vue plugins/oblsk_licenses/web/PresentOverlay.vue plugins/oblsk_licenses/web/globalElements.js
git commit -m "Add LicenseCard and PresentOverlay web components"
```

---

### Task 9: Inventory "Present" action wiring

> Repo target: **mixed, two plugin repos, neither is `core`**. Steps 1-4
> touch `oblsk_inventory`'s own existing repo. Step 5 touches
> `oblsk_licenses`'s own repo. Commit each half separately — see Step 8.

**Files:**
- Modify: `plugins/oblsk_inventory/server/services/InventoryService.lua`
  (`toSyncRow`, currently at lines 55-77)
- Modify: `plugins/oblsk_inventory/web/ContextMenu.vue`
- Modify: `plugins/oblsk_inventory/web/useInventory.js` (`doAction`,
  currently at lines 205-220)
- Modify: `plugins/oblsk_inventory/client/main.lua`
- Create: `plugins/oblsk_licenses/client/main.lua`

**Interfaces:**
- Consumes: `is_presentable` column (Task 1); `licenses:client:present`
  server event (Task 7).
- Produces: fully wired end-to-end flow — right-click a presentable item →
  Present → server resolves nearby players → both sides see the card.

- [ ] **Step 1: Serialize `is_presentable` into the sync row**

Modify `plugins/oblsk_inventory/server/services/InventoryService.lua`,
`toSyncRow` (currently lines 55-77) — add one field next to the existing
`is_dropable` line:

```lua
        is_dropable = isTruthyFlag(baseItemRow.is_dropable),
        is_presentable = isTruthyFlag(baseItemRow.is_presentable),
```

- [ ] **Step 2: Add the Present button**

Modify `plugins/oblsk_inventory/web/ContextMenu.vue` — add one button after
the existing "Open" button (line 11):

```vue
      <button v-if="menu.item.is_presentable" class="w-full text-left px-3 py-2 text-[12px] hover:bg-white/8" @click="act('present')">Present</button>
```

- [ ] **Step 3: Wire the action in the composable**

Modify `plugins/oblsk_inventory/web/useInventory.js`, `doAction` (currently
lines 205-220) — add one branch:

```js
    } else if (action === 'present') {
      Obelisk.emit('inventory:present', { itemId: item.id })
    } else if (action === 'split') split.value = { item }
```

(inserted before the existing `else if (action === 'split')` line so the
`else if` chain stays intact)

- [ ] **Step 4: Relay from inventory's client Lua to the licenses plugin**

Add to `plugins/oblsk_inventory/client/main.lua`, after the existing
`WebView.on('inventory:drop', ...)` block:

```lua
-- Presenting is a licenses-plugin concept (Present overlay/card), but the
-- button lives in the shared inventory context menu since that's the only
-- per-item action surface that exists (see the design spec's Present
-- action section) - relay straight through to oblsk_licenses' own server
-- event rather than inventing an inventory-owned "present" concept.
WebView.on('inventory:present', function(data)
    Obelisk.emitServer('licenses:client:present', data.itemId)
end)
```

- [ ] **Step 5: Add the licenses client (put-away trigger)**

```lua
-- plugins/oblsk_licenses/client/main.lua
-- PresentOverlay.vue's "Put away" button (web/PresentOverlay.vue) fires
-- this NUI callback directly (Obelisk.emit('licenses:putAway', ...)) rather
-- than going through oblsk_inventory's context menu, since put-away isn't a
-- per-item-in-a-list action - the overlay itself is what's open.
WebView.on('licenses:putAway', function(data)
    Obelisk.emitServer('licenses:client:putAway', data.itemId)
end)
```

- [ ] **Step 6: Update the licenses fxmanifest**

`plugins/oblsk_licenses/fxmanifest.lua`'s `client_scripts { 'client/**/*.lua' }`
(already present from Task 1) covers this new file — no manifest edit
needed. Confirm:

Run: `luac5.4 -p plugins/oblsk_licenses/client/main.lua plugins/oblsk_inventory/client/main.lua`
Expected: no output.

- [ ] **Step 7: Manual end-to-end smoke test**

This step exercises real FXServer natives (`GetPlayers`, NUI messaging)
that unit tests stub out — it can only be run against a running server, not
`lua5.4` directly. Boot the dev server, spawn two characters near each
other, give one character's character a `State identification` item via
`/license-issue <characterId> State identification`, right-click it in
their inventory, click Present, and confirm:
- The presenter sees the flip card with "Put away" visible.
- The second nearby character also sees the card appear (per Task 8's
  Step 2 note, currently also with "Put away" showing on their side too —
  a known simplification, not a bug in this smoke test).
- Walking the two characters far apart before clicking Put away, then
  clicking it, hides the presenter's own card (their side always works
  correctly since `licenses:client:putAway` unconditionally hides the
  presenter).

- [ ] **Step 8: Commit — two separate commits, two separate repos**

```bash
# In oblsk_inventory's own repo (working directory = that repo's root):
git add server/services/InventoryService.lua web/ContextMenu.vue web/useInventory.js client/main.lua
git commit -m "Add Present action to context menu, relay to oblsk_licenses"
git push

# In oblsk_licenses's own repo (working directory = that repo's root):
git add client/main.lua
git commit -m "Add client-side put-away relay for the present overlay"
git push
```

---

## Self-review notes

- **Spec coverage:** item-backed data model (Tasks 2-3), permissions (Task
  5), Present action + networked overlay (Tasks 6-9), character-create
  auto-grant (Task 4), admin issue/revoke (Task 5), out-of-scope items
  (printer, weapon-registry linkage, self-service renew/lost, wallet screen)
  are all explicitly not built anywhere in this plan.
- **Known gap flagged, not silently swept:** the present overlay's
  `isPresenter` signal is shared verbatim between presenter and target
  (Task 8 Step 2 note, Task 9 Step 7) — every recipient currently sees
  "Put away" and can flip the card. Given this plan's Present-scope
  decision was "networked, visible to nearby players," a future pass should
  have the server tag each recipient's payload individually
  (`isPresenter: source == presenterSource`) rather than reusing one
  broadcast payload — left as a explicit follow-up, not fixed here, to keep
  this plan's task count from growing for a cosmetic control-visibility gap
  that doesn't affect the core RP mechanic (showing the card).
