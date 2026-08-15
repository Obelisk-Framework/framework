# Notebook Item Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `oblsk_notebook` plugin: an in-inventory notebook item you write in, flip through (corner-drag or ←/→), and can tear pages out of; a torn page becomes its own readable item you can flip over with the mouse.

**Architecture:** New plugin, `oblsk_notebook`, following `oblsk_licenses`' item-binding conventions exactly. Two seeded `base_items` (`notebook.notebook`, `notebook.torn_page`) bound via `item_bindings`. The notebook's pages live in its own `items.data.pages` (per-instance, not on the base item). Opening/using either item routes through the existing `Use` → `ItemService.use` → `ActionService` pipeline (same mechanism as core's `item:notify`), driving a new routed page (`/Notebook`, ported from `notebook.jsx`) and a read-only global overlay (`NotePageView.vue`, ported from `note-page.jsx`).

**Tech Stack:** Lua 5.4 (FXServer server-side, tested with the repo's `tests/support/fake_query_builder.lua` harness), Vue 3 `<script setup>` (NUI web app, Tailwind utility classes matching the rest of the codebase).

**Spec:** `core/docs/superpowers/specs/2026-08-15-notebook-item-plugin-design.md`

## Global Constraints

- Every DB lookup goes through `QueryBuilder` (never raw SQL) — matches every existing plugin service.
- Never hardcode a `base_item_id`; resolve `notebook.notebook` / `notebook.torn_page` through `ItemService.binding(key)` or `item_bindings`, same as `oblsk_licenses`.
- Every mutating server function re-checks ownership against the caller's *active character* server-side — never trust a client-supplied owner id (see `InventoryService.checkOwnership`, `LicenseService.revoke`).
- JSON columns (`items.data`, `base_items.data`, `base_items.actions`) come back from raw `QueryBuilder` reads as encoded strings, never auto-decoded — every read needs a `decodeRowData`-style guard (see `LicenseService.decodeRowData`).
- Lua specs run standalone: `lua5.4 core/plugins/oblsk_notebook/tests/<name>_spec.lua` from the repo root, loading `tests/support/fivem_stubs.lua` + the ORM files + `tests/support/fake_query_builder.lua`, exactly like `core/plugins/oblsk_licenses/tests/license_service_spec.lua`.
- `oblsk_notebook` is its own git repository nested inside `core/plugins/` (same as every other plugin — `oblsk_licenses`, `oblsk_cardealer`, etc. each have their own `.git`), separate from commits to the `core` repo itself (`plugins/registry.json`, the spec/plan docs).
- Web files import the shared NUI client as `import Obelisk from '../../../web/src/obelisk.js'` (three levels up from `plugins/oblsk_notebook/web/`), matching `oblsk_licenses/web/PresentOverlay.vue`.

---

### Task 1: Plugin scaffold

**Files:**
- Create: `core/plugins/oblsk_notebook/fxmanifest.lua`
- Create: `core/plugins/oblsk_notebook/shared/config.lua`
- Modify: `core/plugins/registry.json`

**Interfaces:**
- Produces: `Config.Requires.bindings` with keys `notebook.notebook` and `notebook.torn_page` — consumed by core's `bootstrap.lua` (auto-calls `ItemService.registerRequirements('oblsk_notebook', Config.Requires.bindings)`) and by every later task's `ItemService.binding(...)` calls.

- [ ] **Step 1: Create the plugin directory and its own git repo**

```bash
mkdir -p /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook/{server/actions,server/services,server/seeders,client,web,tests}
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git init -q
```

- [ ] **Step 2: Write `fxmanifest.lua`**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Notebook'
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

- [ ] **Step 3: Write `shared/config.lua`**

```lua
Config = {}

-- See docs/superpowers/specs/2026-08-15-notebook-item-plugin-design.md.
-- Loaded by core/core/server/bootstrap.lua at boot and handed to
-- ItemService.registerRequirements('oblsk_notebook', Config.Requires.bindings).
Config.Requires = {
    bindings = {
        ['notebook.notebook'] = {
            live = false,
            description = 'The physical notebook item, opened via Use',
            hint = 'This plugin\'s own Notebook item',
        },
        ['notebook.torn_page'] = {
            live = false,
            description = 'A page torn out of a notebook, viewed via Use',
            hint = 'This plugin\'s own Torn note page item',
        },
    },
}

return Config
```

- [ ] **Step 4: Register the plugin in the core repo**

Add `"oblsk_notebook"` to the `plugins` array in
`/home/andi/Projects/obelisk-framework/core/plugins/registry.json` (keep the
list alphabetically ordered — it goes right after `"oblsk_mdt"` and before
`"oblsk_notifications"`).

- [ ] **Step 5: Commit both repos**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add fxmanifest.lua shared/config.lua
git commit -q -m "Scaffold oblsk_notebook plugin"

cd /home/andi/Projects/obelisk-framework/core
git add plugins/registry.json
git commit -q -m "Register oblsk_notebook in plugins/registry.json"
```

---

### Task 2: NotebookItemSeeder

**Files:**
- Create: `core/plugins/oblsk_notebook/server/seeders/NotebookItemSeeder.lua`
- Test: `core/plugins/oblsk_notebook/tests/notebook_item_seeder_spec.lua`

**Interfaces:**
- Consumes: `ActionService.getDbId(actionId) -> number|nil` (core, stubbed in the test).
- Produces: `NotebookItemSeeder.ensure()` — no return value; consumed by Task 5's boot thread.

- [ ] **Step 1: Write the failing test**

```lua
-- core/plugins/oblsk_notebook/tests/notebook_item_seeder_spec.lua
-- Run from the repository root: lua5.4 core/plugins/oblsk_notebook/tests/notebook_item_seeder_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

local ACTION_DB_IDS = { ['notebook:open'] = 501, ['notebook:viewPage'] = 502 }
ActionService = { getDbId = function(actionId) return ACTION_DB_IDS[actionId] end }

dofile(scriptDir .. '../server/seeders/NotebookItemSeeder.lua')

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

local function findByName(tables, name)
    for _, row in ipairs(tables.base_items) do
        if row.name == name then return row end
    end
end

local function findBinding(tables, key)
    for _, row in ipairs(tables.item_bindings) do
        if row.key == key then return row end
    end
end

test('NotebookItemSeeder.ensure: seeds and binds notebook.notebook with its action wired', function()
    withFakeDb(function(tables)
        NotebookItemSeeder.ensure()

        local item = findByName(tables, 'Notebook')
        eq(item ~= nil, true)
        eq(item.is_useable, 1)
        eq(json.decode(item.data).max_pages, 12)
        eq(json.decode(item.actions)[1].action_id, 501)

        local binding = findBinding(tables, 'notebook.notebook')
        eq(binding ~= nil, true)
        eq(binding.base_item_id, item.id)
    end)
end)

test('NotebookItemSeeder.ensure: seeds and binds notebook.torn_page with its action wired', function()
    withFakeDb(function(tables)
        NotebookItemSeeder.ensure()

        local item = findByName(tables, 'Torn note page')
        eq(item ~= nil, true)
        eq(item.is_useable, 1)
        eq(json.decode(item.actions)[1].action_id, 502)

        local binding = findBinding(tables, 'notebook.torn_page')
        eq(binding ~= nil, true)
        eq(binding.base_item_id, item.id)
    end)
end)

test('NotebookItemSeeder.ensure: is idempotent, does not duplicate bindings on a second run', function()
    withFakeDb(function(tables)
        NotebookItemSeeder.ensure()
        NotebookItemSeeder.ensure()

        local count = 0
        for _, row in ipairs(tables.item_bindings) do
            if row.key == 'notebook.notebook' then count = count + 1 end
        end
        eq(count, 1)

        local itemCount = 0
        for _, row in ipairs(tables.base_items) do
            if row.name == 'Notebook' then itemCount = itemCount + 1 end
        end
        eq(itemCount, 1)
    end)
end)

test('NotebookItemSeeder.ensure: seeds an empty actions pipeline (not an error) when the action has no db id yet', function()
    withFakeDb(function(tables)
        local originalGetDbId = ActionService.getDbId
        ActionService.getDbId = function() return nil end

        local ok = pcall(NotebookItemSeeder.ensure)
        eq(ok, true)

        local item = findByName(tables, 'Notebook')
        eq(#json.decode(item.actions), 0)

        ActionService.getDbId = originalGetDbId
    end)
end)

print('\nRunning NotebookItemSeeder unit tests\n')
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

Run: `lua5.4 core/plugins/oblsk_notebook/tests/notebook_item_seeder_spec.lua`
Expected: FAIL — `NotebookItemSeeder` is nil (file doesn't exist yet).

- [ ] **Step 3: Write `server/seeders/NotebookItemSeeder.lua`**

```lua
-- core/plugins/oblsk_notebook/server/seeders/NotebookItemSeeder.lua
--- NotebookItemSeeder - seeds the Notebook and Torn note page base_items
--- rows and their item_bindings, idempotent by name (same check-then-insert
--- style as oblsk_licenses/server/seeders/LicensesItemSeeder.lua). Each
--- item's `actions` pipeline references its Use-triggered action by the
--- actions table's numeric id, resolved through ActionService.getDbId -
--- see server/actions/NotebookActions.lua, which registers both actions at
--- module load time. By the time this runs (server/main.lua's boot thread,
--- after Database.isReady()), core's bootstrap.lua has already flushed
--- every plugin's pending action registrations, so the db id is available.
NotebookItemSeeder = {}

local ITEMS = {
    {
        key = 'notebook.notebook',
        name = 'Notebook',
        description = 'A pocket notebook. Flip through its pages, write, or tear one out.',
        icon = 'notebook',
        weight = 0.2,
        is_takeable = 1, is_giveable = 1, is_dropable = 1,
        is_container = 0, is_useable = 1, is_stackable = 0,
        actionKey = 'notebook:open',
        data = { max_pages = 12 },
    },
    {
        key = 'notebook.torn_page',
        name = 'Torn note page',
        description = 'A page torn from a notebook.',
        icon = 'note-page',
        weight = 0.01,
        is_takeable = 1, is_giveable = 1, is_dropable = 1,
        is_container = 0, is_useable = 1, is_stackable = 0,
        actionKey = 'notebook:viewPage',
        data = {},
    },
}

function NotebookItemSeeder.ensure()
    for _, def in ipairs(ITEMS) do
        local existing = QueryBuilder.new('base_items'):where('name', def.name):firstSync()
        local baseItemId

        if not existing then
            local actionDbId = ActionService.getDbId(def.actionKey)
            local actions = actionDbId and { { action_id = actionDbId, data = {} } } or {}
            if not actionDbId then
                print('[Notebook] WARNING: action "' .. def.actionKey .. '" has no db id yet, seeding '
                    .. def.name .. ' with an empty actions pipeline')
            end

            baseItemId = QueryBuilder.new('base_items'):insert({
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
                -- QueryBuilder forwards insert params straight to the
                -- connector untouched, so JSON columns need encoding by hand.
                data = json.encode(def.data),
                actions = json.encode(actions),
                created_at = Database.now(),
                updated_at = Database.now(),
            })
            print('[Notebook] seeded base item: ' .. def.name)
        else
            baseItemId = existing.id
        end

        local existingBinding = QueryBuilder.new('item_bindings'):where('key', def.key):firstSync()
        if not existingBinding then
            QueryBuilder.new('item_bindings'):insert({
                key = def.key,
                base_item_id = baseItemId,
                updated_by = 'NotebookItemSeeder',
                updated_at = Database.now(),
            })
            print('[Notebook] bound ' .. def.key .. ' -> ' .. def.name .. ' (#' .. tostring(baseItemId) .. ')')
        end
    end
end

return NotebookItemSeeder
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_notebook/tests/notebook_item_seeder_spec.lua`
Expected: `4 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add server/seeders/NotebookItemSeeder.lua tests/notebook_item_seeder_spec.lua
git commit -q -m "Add NotebookItemSeeder"
```

---

### Task 3: NotebookService

**Files:**
- Create: `core/plugins/oblsk_notebook/server/services/NotebookService.lua`
- Test: `core/plugins/oblsk_notebook/tests/notebook_service_spec.lua`

**Interfaces:**
- Consumes: `CharacterService.getActiveCharacterId(source) -> number|nil`, `ItemService.binding(key) -> table|nil` (both core, faked in the test).
- Produces (consumed by Task 4's actions and Task 5's server/main.lua):
  - `NotebookService.buildOpenPayload(source, itemId) -> ok:boolean, reason:string|nil, payload:table|nil` where `payload = { itemId, name, pages, maxPages }`
  - `NotebookService.save(source, itemId, pages) -> ok:boolean, reason:string|nil`
  - `NotebookService.tearOut(source, itemId, pageIndex) -> ok:boolean, reason:string|nil, tornItemId:number|nil`
  - `NotebookService.buildViewPayload(source, itemId) -> ok:boolean, reason:string|nil, payload:table|nil` where `payload = { itemId, title, body, from, meta }`

- [ ] **Step 1: Write the failing test**

```lua
-- core/plugins/oblsk_notebook/tests/notebook_service_spec.lua
-- Run from the repository root: lua5.4 core/plugins/oblsk_notebook/tests/notebook_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

CharacterService = { sessionCharacters = { [999] = 5, [888] = 6 } }
function CharacterService.getActiveCharacterId(source)
    return CharacterService.sessionCharacters[source]
end

-- ItemService.binding is stubbed per-test since only tearOut() calls it;
-- most tests never bind a torn-page item at all.
ItemService = { binding = function() return nil end }

dofile(scriptDir .. '../server/services/NotebookService.lua')

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

local function storedData(row)
    if type(row.data) == 'string' then return json.decode(row.data) end
    return row.data
end

local function findItem(tables, id)
    for _, row in ipairs(tables.items) do
        if row.id == id then return row end
    end
end

local NOTEBOOK_BASE = { id = 1, name = 'Notebook', is_useable = 1, data = json.encode({ max_pages = 12 }) }
local TORN_PAGE_BASE = { id = 2, name = 'Torn note page', is_useable = 1, data = json.encode({}) }

test('buildOpenPayload: seeds a single blank page and persists it when the item has none yet', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = { { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1, data = json.encode({}) } }

        local ok, reason, payload = NotebookService.buildOpenPayload(999, 10)

        eq(ok, true)
        eq(reason, nil)
        eq(payload.itemId, 10)
        eq(payload.name, 'Notebook')
        eq(payload.maxPages, 12)
        eq(#payload.pages, 1)
        eq(payload.pages[1].title, 'Untitled page')
        eq(storedData(findItem(tables, 10)).pages[1].title, 'Untitled page')
    end)
end)

test('buildOpenPayload: returns existing pages unchanged', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = {
            { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1,
              data = json.encode({ pages = { { id = 'p1', title = 'Groceries', body = 'Coffee' } } }) },
        }

        local ok, reason, payload = NotebookService.buildOpenPayload(999, 10)

        eq(ok, true)
        eq(#payload.pages, 1)
        eq(payload.pages[1].title, 'Groceries')
        eq(payload.pages[1].body, 'Coffee')
    end)
end)

test('buildOpenPayload: refuses an item owned by another character', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = { { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 6, amount = 1, data = json.encode({}) } }

        local ok, reason, payload = NotebookService.buildOpenPayload(999, 10)

        eq(ok, false)
        eq(reason, 'not the owner')
        eq(payload, nil)
    end)
end)

test('buildOpenPayload: refuses a missing item', function()
    withFakeDb(function(tables)
        tables.items = {}

        local ok, reason = NotebookService.buildOpenPayload(999, 999)

        eq(ok, false)
        eq(reason, 'item not found')
    end)
end)

test('save: persists the submitted pages', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = { { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1, data = json.encode({ pages = {} }) } }

        local ok, reason = NotebookService.save(999, 10, {
            { id = 'p1', title = 'Delivery route', body = 'Depot to Sandy' },
        })

        eq(ok, true)
        eq(reason, nil)
        local pages = storedData(findItem(tables, 10)).pages
        eq(#pages, 1)
        eq(pages[1].title, 'Delivery route')
    end)
end)

test('save: clamps to the notebook\'s max_pages', function()
    withFakeDb(function(tables)
        tables.base_items = { { id = 1, name = 'Notebook', is_useable = 1, data = json.encode({ max_pages = 2 }) } }
        tables.items = { { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1, data = json.encode({ pages = {} }) } }

        local ok = NotebookService.save(999, 10, {
            { id = 'p1', title = 'One', body = '' },
            { id = 'p2', title = 'Two', body = '' },
            { id = 'p3', title = 'Three', body = '' },
        })

        eq(ok, true)
        local pages = storedData(findItem(tables, 10)).pages
        eq(#pages, 2)
        eq(pages[2].title, 'Two')
    end)
end)

test('save: an empty submission falls back to one blank page', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = { { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1, data = json.encode({ pages = {} }) } }

        NotebookService.save(999, 10, {})

        local pages = storedData(findItem(tables, 10)).pages
        eq(#pages, 1)
        eq(pages[1].title, 'Untitled page')
    end)
end)

test('save: refuses a non-owner', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = { { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 6, amount = 1, data = json.encode({ pages = {} }) } }

        local ok, reason = NotebookService.save(999, 10, { { id = 'p1', title = 'X', body = '' } })

        eq(ok, false)
        eq(reason, 'not the owner')
    end)
end)

test('tearOut: creates a torn_page item and resets the source page without changing page count', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = {
            { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1,
              data = json.encode({ pages = {
                  { id = 'p1', title = 'Sultan build list', body = 'Turbo ordered' },
                  { id = 'p2', title = 'Groceries', body = 'Coffee' },
              } }) },
        }
        ItemService.binding = function(key)
            if key == 'notebook.torn_page' then return TORN_PAGE_BASE end
            return nil
        end

        local ok, reason, tornItemId = NotebookService.tearOut(999, 10, 1)

        eq(ok, true)
        eq(reason, nil)
        eq(type(tornItemId), 'number')

        local torn = findItem(tables, tornItemId)
        eq(torn.base_item_id, 2)
        eq(torn.owner_type, 'character')
        eq(torn.owner_id, 5)
        local tornData = storedData(torn)
        eq(tornData.title, 'Sultan build list')
        eq(tornData.body, 'Turbo ordered')
        eq(tornData.from, 'Notebook')

        local pages = storedData(findItem(tables, 10)).pages
        eq(#pages, 2, 'page count must not change')
        eq(pages[1].title, 'Untitled page')
        eq(pages[2].title, 'Groceries', 'the untouched page must survive as-is')

        ItemService.binding = function() return nil end
    end)
end)

test('tearOut: refuses an out-of-range page index', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = {
            { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1,
              data = json.encode({ pages = { { id = 'p1', title = 'Only page', body = '' } } }) },
        }

        local ok, reason = NotebookService.tearOut(999, 10, 5)

        eq(ok, false)
        eq(reason, 'page not found')
    end)
end)

test('tearOut: fails cleanly if notebook.torn_page has no bound item yet', function()
    withFakeDb(function(tables)
        tables.base_items = { NOTEBOOK_BASE }
        tables.items = {
            { id = 10, base_item_id = 1, owner_type = 'character', owner_id = 5, amount = 1,
              data = json.encode({ pages = { { id = 'p1', title = 'Only page', body = '' } } }) },
        }
        ItemService.binding = function() return nil end

        local ok, reason = NotebookService.tearOut(999, 10, 1)

        eq(ok, false)
        eq(reason, 'torn page item not bound')
    end)
end)

test('buildViewPayload: returns the torn page\'s title/body/from/meta', function()
    withFakeDb(function(tables)
        tables.base_items = { TORN_PAGE_BASE }
        tables.items = {
            { id = 20, base_item_id = 2, owner_type = 'character', owner_id = 5, amount = 1,
              data = json.encode({ title = 'Numbers', body = 'Marco 555-0114', from = 'Notebook', meta = 1234567890 }) },
        }

        local ok, reason, payload = NotebookService.buildViewPayload(999, 20)

        eq(ok, true)
        eq(reason, nil)
        eq(payload.itemId, 20)
        eq(payload.title, 'Numbers')
        eq(payload.body, 'Marco 555-0114')
        eq(payload.from, 'Notebook')
        eq(payload.meta, 1234567890)
    end)
end)

test('buildViewPayload: refuses a non-owner', function()
    withFakeDb(function(tables)
        tables.base_items = { TORN_PAGE_BASE }
        tables.items = {
            { id = 20, base_item_id = 2, owner_type = 'character', owner_id = 6, amount = 1,
              data = json.encode({ title = 'Numbers', body = '' }) },
        }

        local ok, reason = NotebookService.buildViewPayload(999, 20)

        eq(ok, false)
        eq(reason, 'not the owner')
    end)
end)

print('\nRunning NotebookService unit tests\n')
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

Run: `lua5.4 core/plugins/oblsk_notebook/tests/notebook_service_spec.lua`
Expected: FAIL — `NotebookService` is nil.

- [ ] **Step 3: Write `server/services/NotebookService.lua`**

```lua
-- core/plugins/oblsk_notebook/server/services/NotebookService.lua
--- NotebookService - persists/mutates a notebook item's own pages, and
--- creates torn-out page items. Every lookup re-checks ownership against
--- the caller's active character. The torn-page base item is resolved
--- through ItemService.binding('notebook.torn_page') - never a hardcoded
--- base_item_id - same convention as oblsk_licenses' issue().
NotebookService = {}

NotebookService.NOTEBOOK_KEY = 'notebook.notebook'
NotebookService.TORN_PAGE_KEY = 'notebook.torn_page'
NotebookService.DEFAULT_MAX_PAGES = 12

--- Mirrors oblsk_licenses/server/services/LicenseService.lua's
--- decodeRowData: a raw QueryBuilder read hands JSON columns back as a
--- string, never auto-decoded.
--- @param row table|nil
--- @return table|nil row the same row, with `.data` decoded in place
local function decodeRowData(row)
    if row and type(row.data) == 'string' then
        local ok, decoded = pcall(json.decode, row.data)
        row.data = ok and decoded or nil
    end
    return row
end
NotebookService.decodeRowData = decodeRowData

--- @param id string
--- @return table
local function blankPage(id)
    return { id = id, title = 'Untitled page', body = '' }
end

--- @param baseItem table decoded base_items row
--- @return number
local function maxPagesFor(baseItem)
    return (baseItem.data and baseItem.data.max_pages) or NotebookService.DEFAULT_MAX_PAGES
end

--- @param source number
--- @param itemId number
--- @return boolean ok, string|nil reason, table|nil item, table|nil baseItem
local function loadOwned(source, itemId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return false, 'no active character', nil, nil end

    local item = decodeRowData(QueryBuilder.new('items'):where('id', itemId):firstSync())
    if not item then return false, 'item not found', nil, nil end
    if item.owner_type ~= 'character' or tonumber(item.owner_id) ~= tonumber(characterId) then
        return false, 'not the owner', nil, nil
    end

    local baseItem = decodeRowData(QueryBuilder.new('base_items'):where('id', item.base_item_id):firstSync())
    if not baseItem then return false, 'base item not found', nil, nil end

    return true, nil, item, baseItem
end

--- @param source number
--- @param itemId number the notebook item
--- @return boolean ok, string|nil reason, table|nil payload { itemId, name, pages, maxPages }
function NotebookService.buildOpenPayload(source, itemId)
    local ok, reason, item, baseItem = loadOwned(source, itemId)
    if not ok then return false, reason, nil end

    local pages = (item.data and item.data.pages) or {}
    if #pages == 0 then
        pages = { blankPage('p1') }
        QueryBuilder.new('items'):where('id', itemId):update({
            data = json.encode({ pages = pages }),
            updated_at = Database.now(),
        })
    end

    return true, nil, { itemId = item.id, name = baseItem.name, pages = pages, maxPages = maxPagesFor(baseItem) }
end

--- @param source number
--- @param itemId number the notebook item
--- @param pages table[] client-submitted { id, title, body } pages
--- @return boolean ok, string|nil reason
function NotebookService.save(source, itemId, pages)
    local ok, reason, item, baseItem = loadOwned(source, itemId)
    if not ok then return false, reason end
    if type(pages) ~= 'table' then return false, 'invalid pages' end

    local max = maxPagesFor(baseItem)
    local clamped = {}
    for i, page in ipairs(pages) do
        if i > max then break end
        table.insert(clamped, { id = page.id, title = page.title or '', body = page.body or '' })
    end
    if #clamped == 0 then clamped = { blankPage('p1') } end

    QueryBuilder.new('items'):where('id', itemId):update({
        data = json.encode({ pages = clamped }),
        updated_at = Database.now(),
    })
    return true, nil
end

--- Rip a page out of the notebook: it becomes its own `notebook.torn_page`
--- item, and the source page is reset to blank in place - page count never
--- changes, matching the source prototype's "rip and keep writing
--- underneath" behaviour.
--- @param source number
--- @param itemId number the notebook item
--- @param pageIndex number 1-based index into the notebook's current pages
--- @return boolean ok, string|nil reason, number|nil tornItemId
function NotebookService.tearOut(source, itemId, pageIndex)
    local ok, reason, item, baseItem = loadOwned(source, itemId)
    if not ok then return false, reason, nil end

    local pages = (item.data and item.data.pages) or {}
    local torn = pages[pageIndex]
    if not torn then return false, 'page not found', nil end

    local tornPageBase = ItemService.binding(NotebookService.TORN_PAGE_KEY)
    if not tornPageBase then return false, 'torn page item not bound', nil end

    local tornItemId = QueryBuilder.new('items'):insert({
        base_item_id = tornPageBase.id,
        owner_type = 'character',
        owner_id = item.owner_id,
        amount = 1,
        data = json.encode({
            title = torn.title,
            body = torn.body,
            from = baseItem.name,
            meta = Database.now(),
        }),
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    local newPages = {}
    for i, page in ipairs(pages) do
        newPages[i] = (i == pageIndex) and blankPage(page.id .. '-torn') or page
    end

    QueryBuilder.new('items'):where('id', itemId):update({
        data = json.encode({ pages = newPages }),
        updated_at = Database.now(),
    })

    return true, nil, tornItemId
end

--- @param source number
--- @param itemId number the torn-page item
--- @return boolean ok, string|nil reason, table|nil payload { itemId, title, body, from, meta }
function NotebookService.buildViewPayload(source, itemId)
    local ok, reason, item, baseItem = loadOwned(source, itemId)
    if not ok then return false, reason, nil end

    local data = item.data or {}
    return true, nil, {
        itemId = item.id,
        title = data.title or baseItem.name,
        body = data.body or '',
        from = data.from,
        meta = data.meta,
    }
end

return NotebookService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/plugins/oblsk_notebook/tests/notebook_service_spec.lua`
Expected: `12 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add server/services/NotebookService.lua tests/notebook_service_spec.lua
git commit -q -m "Add NotebookService"
```

---

### Task 4: NotebookActions

**Files:**
- Create: `core/plugins/oblsk_notebook/server/actions/NotebookActions.lua`

**Interfaces:**
- Consumes: `NotebookService.buildOpenPayload`, `NotebookService.buildViewPayload` (Task 3); `ActionService.register(actionId, handler, options)`, `WebView.emitClient/openPage/focus/showGlobalElement`, `NotificationService.notify` (all core, no test harness — see the note below).
- Produces: registers the `notebook:open` and `notebook:viewPage` actions that `NotebookItemSeeder` (Task 2) references by db id, and that `ItemService.use` (core) invokes when a player uses either seeded item.

No unit test for this file — it's thin action-registration glue with no
pure logic of its own, same as core's own
`core/modules/oblsk_items/server/actions/ItemActions.lua` and
`oblsk_licenses/server/main.lua`, neither of which has a spec file either.
It's exercised end-to-end in Task 9's manual verification.

- [ ] **Step 1: Write `server/actions/NotebookActions.lua`**

```lua
-- core/plugins/oblsk_notebook/server/actions/NotebookActions.lua
--- NotebookActions - the two Use-triggered actions this plugin's base
--- items reference in their `actions` pipeline (see NotebookItemSeeder.lua).
--- Registered once at module load, same mechanism as core's ItemActions.lua.
--- InventoryService.use (oblsk_inventory) already checked the caller owns
--- `data.item` before ItemService.use ever reaches here, so these handlers
--- don't re-check ownership for the open/view trigger itself - but every
--- NotebookService call they delegate to re-checks it anyway, since that's
--- also reachable straight from the NUI round trips in server/main.lua.

ActionService.register('notebook:open', function(source, data)
    if not data.item then return end
    local ok, reason, payload = NotebookService.buildOpenPayload(source, data.item.attributes.id)
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Notebook', description = reason })
        return
    end
    WebView.emitClient(source, 'notebook:open', payload)
    WebView.openPage(source, '/Notebook')
    WebView.focus(source)
end, { label = 'Open a notebook item for reading/writing' })

ActionService.register('notebook:viewPage', function(source, data)
    if not data.item then return end
    local ok, reason, payload = NotebookService.buildViewPayload(source, data.item.attributes.id)
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Notebook', description = reason })
        return
    end
    WebView.emitClient(source, 'notebook:viewPage', payload)
    WebView.showGlobalElement(source, 'notePageView')
end, { label = 'View a single torn-out note page' })
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add server/actions/NotebookActions.lua
git commit -q -m "Add NotebookActions (notebook:open, notebook:viewPage)"
```

---

### Task 5: server/main.lua — save/tearOut events and boot seeding

**Files:**
- Create: `core/plugins/oblsk_notebook/server/main.lua`

**Interfaces:**
- Consumes: `NotebookService.save`, `NotebookService.tearOut`, `NotebookService.buildOpenPayload` (Task 3); `NotebookItemSeeder.ensure` (Task 2).
- Produces: net events `notebook:client:save(itemId, pages)`, `notebook:client:tearOut(itemId, pageIndex)` — consumed by Task 6's `client/main.lua`.

No unit test — matches `oblsk_licenses/server/main.lua` (event-wiring glue,
no spec file). Verified in Task 9.

- [ ] **Step 1: Write `server/main.lua`**

```lua
-- core/plugins/oblsk_notebook/server/main.lua
local function notifyFailure(source, reason)
    NotificationService.notify(source, { type = 'error', title = 'Notebook', description = reason })
end

--- Re-sends the notebook's current state after a mutation, so the open book
--- (if the player still has it open) reflects what the server actually
--- persisted - e.g. the clamp in NotebookService.save, or the fresh blank
--- page tearOut() leaves behind.
local function pushOpen(source, itemId)
    local ok, reason, payload = NotebookService.buildOpenPayload(source, itemId)
    if ok then WebView.emitClient(source, 'notebook:open', payload) end
    return ok, reason
end

Obelisk.onServer('notebook:client:save', function(itemId, pages)
    local source = source
    local ok, reason = NotebookService.save(source, itemId, pages)
    if not ok then
        notifyFailure(source, reason)
        return
    end
    pushOpen(source, itemId)
end)

Obelisk.onServer('notebook:client:tearOut', function(itemId, pageIndex)
    local source = source
    local ok, reason = NotebookService.tearOut(source, itemId, pageIndex)
    if not ok then
        notifyFailure(source, reason)
        return
    end
    NotificationService.notify(source, { type = 'success', title = 'Notebook', description = 'Page torn out.' })
    pushOpen(source, itemId)
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    NotebookItemSeeder.ensure()
    print('[Notebook] Loaded successfully!')
end)
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add server/main.lua
git commit -q -m "Wire notebook save/tearOut events and boot seeding"
```

---

### Task 6: client/main.lua

**Files:**
- Create: `core/plugins/oblsk_notebook/client/main.lua`

**Interfaces:**
- Consumes: `WebView.on/hide/hideGlobalElement` (core client), `Obelisk.emitServer` (core).
- Produces: NUI callback names `notebook:save`, `notebook:tearOut`, `notebook:close`, `notebook:closeView` — consumed by Task 8/9's Vue components.

No unit test — matches `oblsk_licenses/client/main.lua` and
`oblsk_keybinds/client/main.lua` (both pure NUI-relay files, no spec).

- [ ] **Step 1: Write `client/main.lua`**

```lua
-- core/plugins/oblsk_notebook/client/main.lua
-- Notebook.vue's Close button and NotePageView.vue's Close button both hide
-- purely client-side (no server round trip needed - the server has nothing
-- to clean up on close, unlike oblsk_licenses' present sessions, which have
-- to tell OTHER nearby players to close too). Same move as
-- oblsk_keybinds/client/main.lua's 'keybinds:client:close' handler.

WebView.on('notebook:save', function(data)
    Obelisk.emitServer('notebook:client:save', data.itemId, data.pages)
end)

WebView.on('notebook:tearOut', function(data)
    Obelisk.emitServer('notebook:client:tearOut', data.itemId, data.pageIndex)
end)

WebView.on('notebook:close', function()
    WebView.hide()
end)

WebView.on('notebook:closeView', function()
    WebView.hideGlobalElement('notePageView')
end)
```

- [ ] **Step 2: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add client/main.lua
git commit -q -m "Add notebook client NUI relays"
```

---

### Task 7: Web — NotebookPageEditor.vue and NotebookStaticPage.vue

**Files:**
- Create: `core/plugins/oblsk_notebook/web/NotebookPageEditor.vue`
- Create: `core/plugins/oblsk_notebook/web/NotebookStaticPage.vue`

**Interfaces:**
- Produces: `NotebookPageEditor` — props `{ page: { id, title, body } }`, emits `change(html, text)` and `select()`, exposes `getEl(): HTMLElement|null`. `NotebookStaticPage` — props `{ page: { title, body } }`. Both consumed by Task 8's `Notebook.vue`.

No unit test — this codebase has no Vue component tests anywhere
(`oblsk_licenses`, `oblsk_terminal`, etc. all rely on manual/dev-sandbox
verification, done in Task 9).

- [ ] **Step 1: Write `web/NotebookPageEditor.vue`**

```vue
<!-- core/plugins/oblsk_notebook/web/NotebookPageEditor.vue -->
<!-- Ported from src/proto/notebook.jsx's NotePage — the contentEditable
     writing surface for the page currently open in the book. Typing "[]"
     turns into a tickable checkbox, same as the prototype. -->
<template>
  <div
    ref="el"
    contenteditable="true"
    @input="onInput"
    @click="onClick"
    @keyup="$emit('select')"
    @mouseup="$emit('select')"
    @blur="$emit('select')"
    class="relative w-full h-full overflow-y-auto ob-no-scroll outline-none pl-16 pr-8 pt-[6px]"
    style="user-select: text; color: #1e2a38; font-family: Georgia, serif; font-size: 15px; line-height: 28px"
  />
</template>

<script setup>
import { ref, watch, onMounted } from 'vue'

const props = defineProps({
  page: { type: Object, required: true },
})
const emit = defineEmits(['change', 'select'])

const el = ref(null)

function applyCheckboxes(root) {
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const hits = []
  let node
  while ((node = walk.nextNode())) {
    const m = node.nodeValue.match(/\[\s?\]/)
    if (m) hits.push([node, m.index, m[0].length])
  }
  let placed = null
  hits.forEach(([node, idx, len]) => {
    const after = node.splitText(idx)
    after.nodeValue = after.nodeValue.slice(len)
    const box = document.createElement('span')
    box.className = 'nb-cb'
    box.contentEditable = 'false'
    box.dataset.on = '0'
    box.textContent = '☐'
    node.parentNode.insertBefore(box, after)
    placed = box
  })
  if (placed) {
    const sel = window.getSelection()
    const r = document.createRange()
    r.setStartAfter(placed)
    r.collapse(true)
    sel.removeAllRanges()
    sel.addRange(r)
  }
}

function onInput(e) {
  applyCheckboxes(e.currentTarget)
  emit('change', e.currentTarget.innerHTML, e.currentTarget.innerText)
}

function onClick(e) {
  const box = e.target.closest && e.target.closest('.nb-cb')
  if (!box) return
  const on = box.dataset.on === '1'
  box.dataset.on = on ? '0' : '1'
  box.textContent = on ? '☐' : '☑'
  if (el.value) emit('change', el.value.innerHTML, el.value.innerText)
}

function syncFromPage() {
  if (el.value) el.value.innerHTML = props.page.body
}
watch(() => props.page.id, syncFromPage)
onMounted(syncFromPage)

defineExpose({ getEl: () => el.value })
</script>
```

- [ ] **Step 2: Write `web/NotebookStaticPage.vue`**

```vue
<!-- core/plugins/oblsk_notebook/web/NotebookStaticPage.vue -->
<!-- Ported from src/proto/notebook.jsx's NbStaticPage — a read-only
     rendering of a single page, used only as the visual under/turning
     sheet during the corner-drag page-turn animation in Notebook.vue. -->
<template>
  <div class="w-full h-full flex flex-col relative">
    <div class="absolute left-0 top-0 bottom-0 w-10" style="background: linear-gradient(90deg, rgba(0,0,0,.22), transparent)" />
    <div class="absolute left-[56px] top-0 bottom-0 w-px" style="background: rgba(200,60,60,.35)" />
    <div class="pl-16 pr-8 pt-7 pb-2 text-[24px] font-semibold text-[#1b1f24]" style="font-family: Georgia, serif">{{ page.title }}</div>
    <div class="flex-1 relative">
      <div class="absolute inset-0" style="background: repeating-linear-gradient(180deg, transparent 0 27px, rgba(30,50,80,.16) 27px 28px)" />
      <div class="relative pl-16 pr-8" style="color: #1e2a38; font-family: Georgia, serif; font-size: 15px; line-height: 28px" v-html="page.body" />
    </div>
  </div>
</template>

<script setup>
defineProps({ page: { type: Object, required: true } })
</script>
```

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add web/NotebookPageEditor.vue web/NotebookStaticPage.vue
git commit -q -m "Add NotebookPageEditor and NotebookStaticPage components"
```

---

### Task 8: Web — Notebook.vue and routes.js

**Files:**
- Create: `core/plugins/oblsk_notebook/web/Notebook.vue`
- Create: `core/plugins/oblsk_notebook/web/routes.js`

**Interfaces:**
- Consumes: `NotebookPageEditor`, `NotebookStaticPage` (Task 7); NUI events `notebook:save`, `notebook:tearOut`, `notebook:close` (Task 6); server push `notebook:open` (Tasks 4/5).
- Produces: the `/Notebook` route, auto-discovered by `core/web/src/router/index.js`'s `import.meta.glob(['.../plugins/*/web/routes.js'])` — no manual registration needed.

- [ ] **Step 1: Write `web/Notebook.vue`**

```vue
<!-- core/plugins/oblsk_notebook/web/Notebook.vue -->
<!-- Ported from src/proto/notebook.jsx — a pocket notebook you flip
     through, write in, and can tear pages out of. Routed page (like
     Inventory.vue/Keybinds.vue), not a global element: it's a dedicated
     full-screen surface, opened by the notebook:open action
     (server/actions/NotebookActions.lua) via WebView.openPage. -->
<template>
  <div class="absolute inset-0 grid place-items-center">
    <div v-if="payload" class="relative" style="width: 720px; height: 700px; perspective: 2200px">
      <button
        class="absolute -top-9 right-0 h-8 w-8 rounded-lg border border-white/12 hover:bg-white/8 grid place-items-center transition text-white/70"
        title="Close"
        @click="close"
      >✕</button>

      <!-- book -->
      <div
        class="w-full h-full rounded-2xl border border-white/12 overflow-hidden flex flex-col relative"
        style="background: #f6f3e9; box-shadow: 0 40px 100px rgba(0,0,0,.75)"
      >
        <div class="absolute left-0 top-0 bottom-0 w-10" style="background: linear-gradient(90deg, rgba(0,0,0,.22), transparent)" />
        <div class="absolute left-[56px] top-0 bottom-0 w-px" style="background: rgba(200,60,60,.35)" />
        <div class="absolute left-[18px] top-0 bottom-0 flex flex-col justify-evenly py-10">
          <span v-for="n in 5" :key="n" class="w-3 h-3 rounded-full" style="background: rgba(0,0,0,.22); box-shadow: inset 0 1px 2px rgba(0,0,0,.4)" />
        </div>

        <div
          :key="page.id"
          class="flex-1 min-h-0 flex flex-col"
          :style="{ animation: flip ? `nbFlip${flip === 'next' ? 'N' : 'P'} .26s ease-out` : 'none', visibility: turn ? 'hidden' : 'visible' }"
        >
          <div class="pl-16 pr-8 pt-7 pb-2 shrink-0">
            <input
              :value="page.title"
              @input="patch({ title: $event.target.value })"
              @keydown.stop
              class="w-full bg-transparent outline-none text-[24px] font-semibold text-[#1b1f24] placeholder:text-black/25"
              placeholder="Untitled page"
              style="user-select: text; font-family: Georgia, serif"
            />
            <div class="flex items-center gap-3 mt-2">
              <span class="text-[10.5px] text-black/40">Page {{ i + 1 }} of {{ pages.length }}</span>
              <div class="ml-auto flex items-center gap-1.5">
                <button
                  v-for="c in swatches" :key="c" @mousedown.prevent @click="paint(c)" title="Colour the selected text"
                  class="w-5 h-5 rounded-full border transition"
                  :style="{ background: c, borderColor: ink === c ? '#000' : 'rgba(0,0,0,.15)', transform: ink === c ? 'scale(1.15)' : 'none' }"
                />
                <label class="relative w-5 h-5 rounded-full border border-dashed border-black/30 grid place-items-center cursor-pointer hover:border-black/60 transition" title="Custom colour">
                  <span class="text-[11px] leading-none text-black/45">+</span>
                  <input type="color" @input="paint($event.target.value)" @blur="addSwatch($event.target.value)"
                    class="absolute inset-0 w-full h-full opacity-0 cursor-pointer" />
                </label>
              </div>
            </div>
          </div>

          <div class="flex-1 min-h-0 relative">
            <div class="absolute inset-0 pointer-events-none" style="background: repeating-linear-gradient(180deg, transparent 0 27px, rgba(30,50,80,.16) 27px 28px)" />
            <NotebookPageEditor ref="editor" :page="page" @select="rememberSelection" @change="onChange" />
          </div>
        </div>

        <!-- footer -->
        <div class="h-11 shrink-0 pl-16 pr-5 flex items-center justify-between border-t border-black/10">
          <div class="flex items-center gap-3">
            <span class="text-[10.5px] text-black/35">{{ chars || plainLength }} characters</span>
            <span class="text-[10.5px] transition" :style="{ color: saved ? '#047857' : 'rgba(0,0,0,.3)' }">{{ saved ? 'Saved' : 'Autosave on' }}</span>
          </div>
          <div class="flex items-center gap-2">
            <div class="flex items-center gap-1 mr-2">
              <button
                v-for="(p, pi) in pages" :key="p.id" @click="goTo(pi)" :title="p.title"
                class="rounded-full transition"
                :style="{ width: pi === i ? '16px' : '6px', height: '6px', background: pi === i ? '#1b1f24' : 'rgba(0,0,0,.22)' }"
              />
            </div>
            <button @click="tearOut" :disabled="!!tearing" class="h-7 px-2.5 rounded-md text-[11px] text-black/45 hover:text-red-700 hover:bg-black/5 disabled:opacity-25 transition">Tear out</button>
            <button @click="addPage" :disabled="pages.length >= maxPages" class="h-7 px-3 rounded-md text-[11px] text-white font-medium disabled:opacity-40" style="background: #1b1f24">+ New page</button>
          </div>
        </div>
      </div>

      <!-- torn sheet + stub -->
      <template v-if="tearing">
        <div class="absolute left-0 top-0 bottom-0 pointer-events-none z-20" :style="{ width: '74px', background: '#f6f3e9', clipPath: NB_STUB_CLIP, animation: 'nbStub .62s ease-out forwards' }" />
        <div class="absolute inset-0 z-30 pointer-events-none overflow-hidden rounded-2xl">
          <div class="absolute inset-0" :style="{ background: '#f6f3e9', clipPath: NB_TEAR_CLIP, transformOrigin: '0% 100%', animation: 'nbTear .62s cubic-bezier(.34,.9,.5,1) forwards', boxShadow: '0 30px 60px rgba(0,0,0,.6)' }">
            <div class="absolute inset-0" style="background: repeating-linear-gradient(180deg, transparent 0 27px, rgba(30,50,80,.16) 27px 28px)" />
            <div class="pl-16 pr-8 pt-7">
              <div class="text-[24px] font-semibold text-[#1b1f24]" style="font-family: Georgia, serif">{{ tearing.title }}</div>
              <div class="mt-4 text-[15px] leading-[28px] text-[#1e2a38]" style="font-family: Georgia, serif" v-html="tearing.body" />
            </div>
          </div>
        </div>
      </template>

      <!-- corner grabs -->
      <div v-if="i < pages.length - 1" @pointerdown="startTurn('next')" title="Drag to turn the page"
        class="absolute bottom-0 right-0 z-40 cursor-grab active:cursor-grabbing"
        style="width: 96px; height: 96px; background: linear-gradient(315deg, rgba(0,0,0,.14) 0 42%, transparent 42%); border-bottom-right-radius: var(--ob-radius)" />
      <div v-if="i > 0" @pointerdown="startTurn('prev')" title="Drag to turn back"
        class="absolute bottom-0 left-0 z-40 cursor-grab active:cursor-grabbing"
        style="width: 96px; height: 96px; background: linear-gradient(45deg, rgba(0,0,0,.14) 0 42%, transparent 42%); border-bottom-left-radius: var(--ob-radius)" />

      <!-- page under the one being turned -->
      <div v-if="turn && underPage" class="absolute inset-0 rounded-2xl overflow-hidden border border-white/12 z-20" style="background: #f6f3e9">
        <NotebookStaticPage :page="underPage" />
      </div>
      <!-- the turning sheet itself -->
      <div v-if="turn && turningPage" class="absolute inset-0 z-30"
        :style="{ transformStyle: 'preserve-3d', transformOrigin: '0% 50%', transform: `rotateY(${turningAngle}deg)`, transition: turn.easing ? 'transform .4s cubic-bezier(.22,1,.36,1)' : 'none' }">
        <div class="absolute inset-0 rounded-2xl overflow-hidden border border-white/12" style="background: #f6f3e9; backface-visibility: hidden; box-shadow: 0 30px 60px rgba(0,0,0,.5)">
          <NotebookStaticPage :page="turningPage" />
        </div>
        <div class="absolute inset-0 rounded-2xl overflow-hidden border border-white/12" style="background: #efeadd; transform: rotateY(180deg); backface-visibility: hidden">
          <div class="absolute inset-0" style="background: repeating-linear-gradient(180deg, transparent 0 27px, rgba(30,50,80,.1) 27px 28px)" />
        </div>
      </div>

      <div class="ob-mono text-[9px] text-white/25 text-center mt-3">DRAG A BOTTOM CORNER TO TURN THE PAGE · ← → ALSO WORK</div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'
import NotebookPageEditor from './NotebookPageEditor.vue'
import NotebookStaticPage from './NotebookStaticPage.vue'

const NB_TEAR_CLIP = 'polygon(9% 0%, 100% 0%, 100% 100%, 9% 100%, 7.6% 96%, 9.4% 92%, 7.2% 88%, 9.6% 84%, 7.4% 80%, 9.2% 76%, 7% 72%, 9.6% 68%, 7.5% 64%, 9.3% 60%, 7.1% 56%, 9.5% 52%, 7.3% 48%, 9.1% 44%, 7.2% 40%, 9.6% 36%, 7.4% 32%, 9.2% 28%, 7% 24%, 9.5% 20%, 7.6% 16%, 9.3% 12%, 7.1% 8%, 9.4% 4%)'
const NB_STUB_CLIP = 'polygon(0% 0%, 82% 0%, 68% 4%, 86% 8%, 64% 12%, 84% 16%, 66% 20%, 88% 24%, 62% 28%, 85% 32%, 67% 36%, 87% 40%, 63% 44%, 84% 48%, 66% 52%, 88% 56%, 64% 60%, 86% 64%, 65% 68%, 87% 72%, 63% 76%, 85% 80%, 67% 84%, 86% 88%, 64% 92%, 84% 96%, 70% 100%, 0% 100%)'
const BASE_SWATCHES = ['#1e2a38', '#1d4ed8', '#b91c1c', '#047857']

const payload = ref(null) // { itemId, name, pages, maxPages }
const i = ref(0)
const ink = ref('#1e2a38')
const swatches = ref([...BASE_SWATCHES])
const chars = ref(0)
const flip = ref(null)     // 'next' | 'prev'
const tearing = ref(null)  // the page being ripped out
const saved = ref(false)
const editor = ref(null)
const rangeRef = ref(null)
const isDev = import.meta.env.DEV

const pages = computed(() => (payload.value ? payload.value.pages : []))
const maxPages = computed(() => (payload.value ? payload.value.maxPages : 0))
const page = computed(() => pages.value[i.value] || { id: 'blank', title: '', body: '' })
const plainLength = computed(() => (page.value.body || '').replace(/<[^>]*>/g, '').length)

function rememberSelection() {
  const s = window.getSelection()
  const el = editor.value && editor.value.getEl()
  if (s && s.rangeCount && el && el.contains(s.anchorNode)) rangeRef.value = s.getRangeAt(0).cloneRange()
}

function goTo(pi) {
  flip.value = pi > i.value ? 'next' : 'prev'
  i.value = pi
}

function go(d) {
  const n = i.value + d
  if (n < 0 || n >= pages.value.length) return
  goTo(n)
}

function save(nextPages) {
  if (!payload.value) return
  Obelisk.emit('notebook:save', { itemId: payload.value.itemId, pages: nextPages })
  saved.value = true
}

function patch(p) {
  if (!payload.value) return
  const nextPages = pages.value.map((x, xi) => (xi === i.value ? { ...x, ...p } : x))
  payload.value.pages = nextPages
  save(nextPages)
}

function onChange(html, text) {
  chars.value = text.length
  patch({ body: html })
}

function paint(col) {
  ink.value = col
  const el = editor.value && editor.value.getEl()
  if (!el) return
  el.focus()
  const sel = window.getSelection()
  if (rangeRef.value) {
    sel.removeAllRanges()
    sel.addRange(rangeRef.value)
  } else {
    const r = document.createRange()
    r.selectNodeContents(el)
    r.collapse(false)
    sel.removeAllRanges()
    sel.addRange(r)
  }
  document.execCommand('styleWithCSS', false, true)
  document.execCommand('foreColor', false, col)
  rangeRef.value = window.getSelection().rangeCount ? window.getSelection().getRangeAt(0).cloneRange() : null
}

function addSwatch(col) {
  if (!swatches.value.includes(col)) {
    const custom = swatches.value.filter((c) => !BASE_SWATCHES.includes(c))
    swatches.value = [...BASE_SWATCHES, ...custom, col].slice(0, BASE_SWATCHES.length + 4)
  }
  paint(col)
}

function addPage() {
  if (!payload.value || pages.value.length >= maxPages.value) return
  const id = `p${Date.now()}`
  const nextPages = [...pages.value.slice(0, i.value + 1), { id, title: 'Untitled page', body: '' }, ...pages.value.slice(i.value + 1)]
  payload.value.pages = nextPages
  save(nextPages)
  flip.value = 'next'
  i.value += 1
}

function tearOut() {
  if (tearing.value || !payload.value) return
  tearing.value = page.value
  const pageIndex = i.value
  setTimeout(() => {
    // Server pages are 1-based (Lua), the client array is 0-based.
    Obelisk.emit('notebook:tearOut', { itemId: payload.value.itemId, pageIndex: pageIndex + 1 })
    chars.value = 0
    tearing.value = null
  }, 620)
}

function close() {
  Obelisk.emit('notebook:close', {})
}

// Drag a page corner to turn the sheet.
const turn = ref(null) // { dir, p, easing }
let turnState = null

function startTurn(dir) {
  return (e) => {
    if (dir === 'next' && i.value === pages.value.length - 1) return
    if (dir === 'prev' && i.value === 0) return
    e.preventDefault()
    turnState = { dir, x0: e.clientX }
    turn.value = { dir, p: 0, easing: false }
  }
}

function onPointerMove(e) {
  const t = turnState
  if (!t) return
  const dx = t.dir === 'next' ? t.x0 - e.clientX : e.clientX - t.x0
  turn.value = { dir: t.dir, p: Math.max(0, Math.min(1, dx / 540)), easing: false }
}

function onPointerUp() {
  const t = turnState
  const cur = turn.value
  if (!t || !cur) return
  const done = cur.p > 0.3
  turn.value = { dir: cur.dir, p: done ? 1 : 0, easing: true }
  setTimeout(() => {
    if (done) i.value = Math.max(0, Math.min(pages.value.length - 1, i.value + (t.dir === 'next' ? 1 : -1)))
    turnState = null
    turn.value = null
    chars.value = 0
  }, 400)
}

const turningAngle = computed(() => (!turn.value ? 0 : turn.value.dir === 'next' ? -180 * turn.value.p : -180 * (1 - turn.value.p)))
const turningPage = computed(() => (!turn.value ? null : turn.value.dir === 'next' ? pages.value[i.value] : pages.value[i.value - 1]))
const underPage = computed(() => (!turn.value ? null : turn.value.dir === 'next' ? pages.value[i.value + 1] : pages.value[i.value]))

function onKeydown(e) {
  if (document.activeElement && document.activeElement.isContentEditable) return
  if (e.key === 'ArrowRight') go(1)
  if (e.key === 'ArrowLeft') go(-1)
}

let savedTimer = null
watch(saved, (v) => {
  if (!v) return
  clearTimeout(savedTimer)
  savedTimer = setTimeout(() => {
    saved.value = false
  }, 1200)
})

function applyPayload(data) {
  payload.value = data
  i.value = 0
  chars.value = 0
}
Obelisk.on('notebook:open', applyPayload)

onMounted(() => {
  window.addEventListener('keydown', onKeydown)
  window.addEventListener('pointermove', onPointerMove)
  window.addEventListener('pointerup', onPointerUp)
  if (isDev) {
    applyPayload({
      itemId: 'dev-notebook',
      name: 'Notebook',
      maxPages: 12,
      pages: [
        { id: 'p1', title: 'Sultan build list', body: 'Turbo — twin scroll, ordered<br>Coilovers — waiting on parts<br><br>[] Order rear diff' },
        { id: 'p2', title: 'Numbers', body: 'Marco — 555-0114<br>Denise — 555-0193' },
      ],
    })
  }
})
onUnmounted(() => {
  window.removeEventListener('keydown', onKeydown)
  window.removeEventListener('pointermove', onPointerMove)
  window.removeEventListener('pointerup', onPointerUp)
  Obelisk.off('notebook:open', applyPayload)
})
</script>

<style>
.nb-cb { display: inline-block; width: 1.1em; cursor: pointer; user-select: none; color: #1b1f24 }
.nb-cb:hover { color: #047857 }
@keyframes nbFlipN { from { opacity: 0; transform: translateX(26px) rotateY(-6deg) } to { opacity: 1; transform: none } }
@keyframes nbFlipP { from { opacity: 0; transform: translateX(-26px) rotateY(6deg) } to { opacity: 1; transform: none } }
@keyframes nbTear { 0% { transform: none; opacity: 1 } 35% { transform: rotate(-2.5deg) translate(14px,6px) } 100% { transform: rotate(11deg) translate(220px,760px); opacity: .15 } }
@keyframes nbStub { from { opacity: 0 } 30% { opacity: 1 } to { opacity: 1 } }
</style>
```

- [ ] **Step 2: Write `web/routes.js`**

```js
export default [
  {
    path: '/Notebook',
    name: 'Notebook',
    component: () => import('./Notebook.vue')
  }
]
```

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add web/Notebook.vue web/routes.js
git commit -q -m "Add Notebook.vue routed page"
```

---

### Task 9: Web — NoteFace.vue, NotePageView.vue and globalElements.js

**Files:**
- Create: `core/plugins/oblsk_notebook/web/NoteFace.vue`
- Create: `core/plugins/oblsk_notebook/web/NotePageView.vue`
- Create: `core/plugins/oblsk_notebook/web/globalElements.js`

**Interfaces:**
- Produces: `NoteFace` — props `{ title, meta, html, showHead }`, consumed by `NotePageView.vue`. Registers the `notePageView` global element, auto-discovered by `core/web/src/App.vue`'s `import.meta.glob(['.../plugins/*/web/globalElements.js'])`.
- Consumes: server push `notebook:viewPage` (Task 4); NUI event `notebook:closeView` (Task 6).

- [ ] **Step 1: Write `web/NoteFace.vue`**

```vue
<!-- core/plugins/oblsk_notebook/web/NoteFace.vue -->
<!-- One face (front or back) of a torn note page — ragged left tear edge,
     margin rule, ruled paper. Ported from src/proto/note-page.jsx's
     NoteFace. The tear clip-path is shared with NotePageView.vue via the
     --nv-tear-clip custom property NotePageView.vue's <style> block
     defines, so both stay in sync with a single polygon definition. -->
<template>
  <div class="w-full h-full relative overflow-hidden" style="background: #f6f3e9; clip-path: var(--nv-tear-clip)">
    <div class="absolute left-0 top-0 bottom-0 w-[13%] pointer-events-none" style="background: linear-gradient(90deg, rgba(120,105,80,.34), rgba(120,105,80,.10) 45%, transparent)" />
    <div class="absolute left-[13%] top-0 bottom-0 w-6 pointer-events-none" style="background: linear-gradient(90deg, rgba(0,0,0,.10), transparent)" />
    <div class="absolute left-[19%] top-0 bottom-0 w-px" style="background: rgba(200,60,60,.35)" />
    <div class="absolute inset-0 pointer-events-none mix-blend-multiply" style="opacity: .5; background: radial-gradient(120% 90% at 20% 0%, rgba(150,135,100,.18), transparent 60%), radial-gradient(90% 80% at 100% 100%, rgba(150,135,100,.16), transparent 55%)" />

    <div class="relative h-full flex flex-col pl-[23%] pr-10">
      <div v-if="showHead" class="pt-9 pb-1">
        <div class="text-[26px] font-semibold text-[#1b1f24]" style="font-family: Georgia, serif">{{ title }}</div>
        <div class="ob-mono text-[9px] tracking-[0.18em] text-[#1b1f24]/35 mt-1">{{ meta }}</div>
      </div>
      <div class="flex-1 relative -ml-[23%] mt-3">
        <div class="absolute inset-0" style="background: repeating-linear-gradient(180deg, transparent 0 27px, rgba(30,50,80,.16) 27px 28px)" />
        <div class="relative pl-[23%] pr-10" style="color: #1e2a38; font-family: Georgia, serif; font-size: 15.5px; line-height: 28px" v-html="html" />
      </div>
    </div>
  </div>
</template>

<script setup>
defineProps({
  title: { type: String, default: '' },
  meta: { type: String, default: '' },
  html: { type: String, default: '' },
  showHead: { type: Boolean, default: false },
})
</script>
```

- [ ] **Step 2: Write `web/NotePageView.vue`**

```vue
<!-- core/plugins/oblsk_notebook/web/NotePageView.vue -->
<!-- Global element (see globalElements.js), toggled by notebook:viewPage
     (server/actions/NotebookActions.lua) via WebView.showGlobalElement.
     Ported from src/proto/note-page.jsx — a single torn-out sheet, read
     only, flipped over with the mouse to read the back. Unlike
     oblsk_licenses' PresentOverlay this is never broadcast to nearby
     players: reading your own note is private, not something shown off to
     bystanders. Front face shows title/body (the note itself); back shows
     where it was torn from - the source prototype's freeform "back" text
     doesn't map to this plugin's data model (title/body/from/meta only),
     so this is an intentional simplification of the ported design. -->
<template>
  <div v-if="payload" class="absolute inset-0 grid place-items-center select-none" style="background: rgba(0,0,0,.35)">
    <div class="flex flex-col items-center gap-5">
      <div style="perspective: 1600px">
        <div style="width: 470px; height: 620px; animation: nvIn .55s cubic-bezier(.22,1,.36,1) both; transform: rotate(-1.2deg)">
          <div class="relative w-full h-full" style="perspective: 1600px">
            <div class="absolute inset-0 pointer-events-none" style="filter: drop-shadow(0 34px 46px rgba(0,0,0,.62))">
              <div class="w-full h-full" style="background: #0a0c0d; clip-path: var(--nv-tear-clip)" />
            </div>
            <div
              class="relative w-full h-full"
              @pointerdown="down" @pointermove="move" @pointerup="up" @pointercancel="up"
              :style="{
                transformStyle: 'preserve-3d',
                transition: dragging ? 'none' : 'transform .55s cubic-bezier(.3,.9,.3,1)',
                transform: `rotateX(${rot.x}deg) rotateY(${rot.y}deg)`,
                cursor: dragging ? 'grabbing' : 'grab',
                touchAction: 'none',
              }"
            >
              <div class="absolute inset-0" style="backface-visibility: hidden">
                <NoteFace :title="payload.title" :meta="metaLine" :html="payload.body" show-head />
              </div>
              <div class="absolute inset-0" style="backface-visibility: hidden; transform: rotateY(180deg)">
                <NoteFace :html="backHtml" />
              </div>
            </div>
          </div>
        </div>
      </div>
      <div class="ob-mono text-[9px] tracking-[0.22em] text-white/25">DRAG TO TURN THE PAGE OVER</div>
      <button class="h-9 px-4 rounded-lg border border-white/15 hover:bg-white/8 text-[12px] text-white/70 transition" @click="close">Close</button>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'
import NoteFace from './NoteFace.vue'

const payload = ref(null)
const rot = ref({ y: 0, x: 0 })
const dragging = ref(false)
let drag = null
const isDev = import.meta.env.DEV

const metaLine = computed(() => {
  if (!payload.value || !payload.value.from) return ''
  return `${payload.value.from.toUpperCase()} · ${formatMeta(payload.value.meta)}`
})
const backHtml = computed(() => (payload.value && payload.value.from ? `Torn from ${payload.value.from}` : ''))

function formatMeta(ts) {
  if (!ts) return ''
  const d = new Date(ts * 1000)
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleString()
}

function down(e) {
  drag = { x: e.clientX, y: e.clientY, y0: rot.value.y, x0: rot.value.x }
  dragging.value = true
  e.currentTarget.setPointerCapture(e.pointerId)
}
function move(e) {
  if (!drag) return
  rot.value = { y: drag.y0 + (e.clientX - drag.x) * 0.55, x: Math.max(-24, Math.min(24, drag.x0 - (e.clientY - drag.y) * 0.22)) }
}
function up() {
  if (!drag) return
  drag = null
  dragging.value = false
  rot.value = { y: Math.round(rot.value.y / 180) * 180, x: 0 }
}

function close() {
  Obelisk.emit('notebook:closeView', {})
  payload.value = null
}

Obelisk.on('notebook:viewPage', (data) => {
  payload.value = data && data.itemId ? data : null
  rot.value = { y: 0, x: 0 }
})

if (isDev) {
  payload.value = {
    itemId: 'dev-page',
    title: 'Sultan build list',
    body: 'Turbo — twin scroll, ordered<br>Coilovers — waiting on parts<br><br>☑ Deposit taken — $400',
    from: 'Notebook',
    meta: Math.floor(Date.now() / 1000),
  }
}
</script>

<style>
:root { --nv-tear-clip: polygon(9% 0%, 100% 0%, 100% 100%, 9% 100%, 7.6% 96%, 9.4% 92%, 7.2% 88%, 9.6% 84%, 7.4% 80%, 9.2% 76%, 7% 72%, 9.6% 68%, 7.5% 64%, 9.3% 60%, 7.1% 56%, 9.5% 52%, 7.3% 48%, 9.1% 44%, 7.2% 40%, 9.6% 36%, 7.4% 32%, 9.2% 28%, 7% 24%, 9.5% 20%, 7.6% 16%, 9.3% 12%, 7.1% 8%, 9.4% 4%) }
@keyframes nvIn { 0% { transform: translateY(26px) rotate(-3deg) scale(.96); opacity: 0 } 100% { transform: translateY(0) rotate(-1.2deg) scale(1); opacity: 1 } }
</style>
```

- [ ] **Step 3: Write `web/globalElements.js`**

```js
// core/plugins/oblsk_notebook/web/globalElements.js
import NotePageView from './NotePageView.vue'

export default [
  { name: 'notePageView', component: NotePageView, defaultVisible: false }
]
```

- [ ] **Step 4: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_notebook
git add web/NoteFace.vue web/NotePageView.vue web/globalElements.js
git commit -q -m "Add NotePageView global element"
```

---

### Task 10: Manual verification

**Files:** none (verification only).

- [ ] **Step 1: Run every Lua spec**

```bash
lua5.4 core/plugins/oblsk_notebook/tests/notebook_item_seeder_spec.lua
lua5.4 core/plugins/oblsk_notebook/tests/notebook_service_spec.lua
```

Expected: both print `... passed, 0 failed`.

- [ ] **Step 2: Start the web dev server and open the dev sandbox**

Use the `run` skill (or the project's existing dev-server launch
convention — check `core/web/package.json`'s scripts) to start
`core/web`'s Vite dev server, then use the Dev HUD Helper page (see
`core/web/src/pages/DevHudHelper.vue`, the same panel `oblsk_licenses`'
sandbox preset relies on) to toggle the `notePageView` global element on,
and navigate directly to `/Notebook` for the routed page. Both components'
`import.meta.env.DEV` branches supply mock payloads, so both render without
a live FiveM server.

- [ ] **Step 3: Verify Notebook.vue in the browser**

Check, using the chrome-devtools MCP or Playwright MCP tools:
- The book renders with the two dev-fixture pages, ruled paper, and punch holes.
- Typing in the page body updates the character count and shows "Saved" briefly.
- Typing `[]` in the body turns into a clickable checkbox that toggles ☐/☑.
- Clicking an ink swatch, then typing, changes the ink color; the custom-color `+` swatch works and is appended after the four base swatches.
- Dragging the bottom-right corner turns the page forward with the 3D flip animation; the bottom-left corner turns it back; ← and → also work.
- Clicking "Tear out" plays the rip animation and (against a live server) replaces the page with a blank one while creating a new `Torn note page` item.
- The "+ New page" button is disabled once `pages.length >= maxPages` (12 in the dev fixture).
- The ✕ button closes the page (`WebView.hide()`).

- [ ] **Step 4: Verify NotePageView.vue in the browser**

Check:
- The torn page renders with the ragged tear edge, ruled lines, and the dev fixture's title/body.
- Dragging left/right rotates the sheet in 3D; releasing snaps to the nearest face (front or back, 180° increments).
- The back face shows "Torn from Notebook".
- The "Close" button hides the overlay.

- [ ] **Step 5: Note anything that can't be verified without a live FiveM server**

Ownership checks, the actual item-creation-on-tear-out round trip, and the
`Use` context-menu action wiring all require a running FXServer + database
and are covered instead by Task 3's `NotebookService` spec plus a read
of `NotebookActions.lua`/`server/main.lua`/`client/main.lua` for wiring
correctness — call this out explicitly rather than claiming full
end-to-end verification.

---
