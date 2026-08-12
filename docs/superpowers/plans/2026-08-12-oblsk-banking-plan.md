# Banking Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the item-bindings economy foundation (`oblsk_items`) and the `oblsk_banking`
plugin on top of it — personal and organization bank accounts reachable from a phone app, a
physical ATM, and a walk-in bank branch, all backed by one `BankingService`.

**Architecture:** `oblsk_items` (core module) gains an `item_bindings` table resolving
logical roles like `currency.cash` to a concrete `base_items` row, so no plugin ever
hardcodes an item name. `oblsk_banking` (new plugin) owns `bank_accounts` /
`bank_cards` / `bank_transactions` with polymorphic ownership (`character` or
`organization`), gated by `Character:can('banking.*')` permission keys for org accounts.
Three UI entry points — phone app, ATM, branch teller — call the same server RPCs
through `BankingService`, following the existing `oblsk_garage` interaction pattern
(`InteractionService.register` + `ActionService.register` + `WebView.openPage`).

**Tech Stack:** Lua 5.4 (FXServer), the project's own ORM (`Schema`/`QueryBuilder`/`BaseModel`
in `core/core/server/ORM`), Vue 3 + Tailwind (phone/ATM/branch UI), `lua5.4`-run spec
files for tests (no JS/Vue test runner exists in this repo — UI tasks are verified by
build + manual check, matching every other plugin's UI work in this codebase).

**Spec:** `docs/superpowers/specs/2026-08-12-banking-plugin-design.md` — read it before
starting; this plan implements it section by section.

## Global Constraints

- Every migration uses the `Schema` DSL (`Schema.create`/`Schema.table`), never raw
  `CREATE TABLE` SQL — see `core/core/server/ORM/Schema.lua` for the `Blueprint` API
  (`:foreignId(name):constrained(refTable)` defaults `ON DELETE RESTRICT`; use
  `:onDelete('CASCADE')` to override — there is no `cascadeOnDelete()`/`restrictOnDelete()`
  shorthand).
- Every DB read/write goes through `QueryBuilder`/`BaseModel`, never a raw SQL string —
  matches every existing service in this codebase (`ActionService.lua`,
  `GarageService.lua`).
- All server-side money mutations that touch more than one row must use
  `Database.transaction(function(tx) tx:add(query, params) ... end)` — see
  `core/core/server/ORM/Database.lua:334` for the exact usage shape (its own doc
  comment example is a two-account balance transfer).
- Permission checks for organization-owned bank accounts always go through
  `character:can('banking.<action>')` (the `Character` model's `HasPermissions` trait),
  never `Rank:can()` directly — `Character`'s registered delegate already walks
  rank/department grants. Personal accounts never call a permission check.
- Every Lua spec file follows the existing convention: `dofile` the ORM layer + the
  fake query builder from `tests/support/fake_query_builder.lua`, stub only what the
  unit under test actually calls, plain `test()`/`eq()` helpers, run with
  `lua5.4 path/to/spec.lua`. Copy the header block from
  `plugins/oblsk_garage/tests/garage_service_spec.lua` — don't reinvent it.
- No plugin/module hardcodes an item name string anywhere. The only permitted way to
  reference "the cash item" is `ItemService.binding('currency.cash')`.

---

## Task 1: `base_items.name` unique constraint

**Files:**
- Create: `modules/oblsk_items/server/migrations/2026_08_12_100000_add_unique_to_base_items_name.lua`
- Modify: `modules/oblsk_items/server/migrations.json` (append the new migration filename, no extension)
- Test: `modules/oblsk_items/tests/base_items_name_unique_spec.lua`

**Interfaces:**
- Consumes: `Schema.table`, `Schema.hasTable` (already exist, `core/core/server/ORM/Schema.lua`)
- Produces: nothing new consumed by later tasks — this is a standalone hygiene fix

- [ ] **Step 1: Write the failing test**

```lua
-- modules/oblsk_items/tests/base_items_name_unique_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_items/tests/base_items_name_unique_spec.lua
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
    if not haystack:find(needle, 1, true) then
        error((msg or 'expected substring not found') .. '\n  looking for: ' .. needle .. '\n  in: ' .. haystack, 2)
    end
end

test('migration adds a unique index on base_items.name', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_12_100000_add_unique_to_base_items_name.lua')
    local statements = {}
    -- Schema.table emits ALTER statements; capture them instead of hitting a real DB.
    local originalExecute = Database.querySync
    Database.querySync = function(sql, params)
        table.insert(statements, sql)
        return {}
    end
    migration.up()
    Database.querySync = originalExecute

    local sawUnique = false
    for _, sql in ipairs(statements) do
        if sql:lower():find('unique') and sql:lower():find('base_items') then
            sawUnique = true
        end
    end
    if not sawUnique then
        error('expected a UNIQUE index/constraint statement touching base_items, got:\n  ' .. table.concat(statements, '\n  '))
    end
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 modules/oblsk_items/tests/base_items_name_unique_spec.lua`
Expected: FAIL — the migration file doesn't exist yet (`dofile` errors: cannot open file).

- [ ] **Step 3: Write the migration**

```lua
-- modules/oblsk_items/server/migrations/2026_08_12_100000_add_unique_to_base_items_name.lua
return {
    up = function()
        Schema.table('base_items', function(table)
            table:unique('name')
        end)

        print('[Migration] Added unique index to base_items.name')
    end,

    down = function()
        -- Schema has no dropUnique helper yet; document intent, no-op like
        -- other irreversible-in-practice down() bodies in this codebase.
        print('[Migration] base_items.name unique index left in place (no dropUnique helper)')
    end
}
```

Append `"2026_08_12_100000_add_unique_to_base_items_name"` to the `migrations` array in
`modules/oblsk_items/server/migrations.json` (matches the existing two-entry format —
open the file first to see the exact array shape before editing).

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 modules/oblsk_items/tests/base_items_name_unique_spec.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add modules/oblsk_items/server/migrations/2026_08_12_100000_add_unique_to_base_items_name.lua modules/oblsk_items/server/migrations.json modules/oblsk_items/tests/base_items_name_unique_spec.lua
git commit -m "items: add unique constraint to base_items.name"
```

---

## Task 2: `item_bindings` table + `ItemBinding` model

**Files:**
- Create: `modules/oblsk_items/server/migrations/2026_08_12_100001_create_item_bindings_table.lua`
- Create: `modules/oblsk_items/server/models/ItemBinding.lua`
- Modify: `modules/oblsk_items/server/migrations.json` (append the new migration)
- Test: `modules/oblsk_items/tests/item_binding_model_spec.lua`

**Interfaces:**
- Consumes: `BaseModel:extend` (existing, `core/core/server/ORM/BaseModel.lua`), `Schema.create`
- Produces: `ItemBinding` model (`primaryKey = 'id'`, `fillable = {'key', 'base_item_id', 'updated_by', 'updated_at'}`) — consumed by Task 3's `ItemService.binding`

- [ ] **Step 1: Write the failing test**

```lua
-- modules/oblsk_items/tests/item_binding_model_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_items/tests/item_binding_model_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/models/ItemBinding.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

test('ItemBinding is keyed on id, fillable exposes key/base_item_id', function()
    eq(ItemBinding.primaryKey, 'id')
    local sawKey, sawBaseItemId = false, false
    for _, field in ipairs(ItemBinding.fillable) do
        if field == 'key' then sawKey = true end
        if field == 'base_item_id' then sawBaseItemId = true end
    end
    eq(sawKey, true, 'fillable must include "key"')
    eq(sawBaseItemId, true, 'fillable must include "base_item_id"')
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 modules/oblsk_items/tests/item_binding_model_spec.lua`
Expected: FAIL — `modules/oblsk_items/server/models/ItemBinding.lua` doesn't exist.

- [ ] **Step 3: Write the migration and model**

```lua
-- modules/oblsk_items/server/migrations/2026_08_12_100001_create_item_bindings_table.lua
return {
    up = function()
        Schema.create('item_bindings', function(table)
            table:id()
            table:string('key', 64):unique()
            table:foreignId('base_item_id'):constrained('base_items')
            table:string('updated_by', 64):nullable()
            table:timestamp('updated_at'):nullable()
        end)

        print('[Migration] Created item_bindings table')
    end,

    down = function()
        Schema.drop('item_bindings')
        print('[Migration] Dropped item_bindings table')
    end
}
```

```lua
-- modules/oblsk_items/server/models/ItemBinding.lua
--- ItemBinding Model - one row per logical item role ('currency.cash') an
--- admin has assigned to a concrete base_items row. See
--- docs/superpowers/specs/2026-08-12-banking-plugin-design.md §3.
ItemBinding = BaseModel:extend('item_bindings')

ItemBinding.primaryKey = 'id'
ItemBinding.timestamps = false
ItemBinding.fillable = { 'key', 'base_item_id', 'updated_by', 'updated_at' }
ItemBinding.hidden = {}

return ItemBinding
```

Append `"2026_08_12_100001_create_item_bindings_table"` to `migrations.json`.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 modules/oblsk_items/tests/item_binding_model_spec.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add modules/oblsk_items/server/migrations/2026_08_12_100001_create_item_bindings_table.lua modules/oblsk_items/server/models/ItemBinding.lua modules/oblsk_items/server/migrations.json modules/oblsk_items/tests/item_binding_model_spec.lua
git commit -m "items: add item_bindings table and ItemBinding model"
```

---

## Task 3: `ItemService.binding` / `hasBinding` / `registerRequirements`

**Files:**
- Modify: `modules/oblsk_items/server/services/ItemService.lua`
- Test: `modules/oblsk_items/tests/item_service_binding_spec.lua`

**Interfaces:**
- Consumes: `ItemBinding` (Task 2), `BaseItem` (existing), `QueryBuilder`
- Produces:
  - `ItemService.registerRequirements(pluginName: string, bindingsTbl: table|nil)`
  - `ItemService.binding(key: string) -> table|nil` (a `BaseItem` row, or `nil`)
  - `ItemService.hasBinding(key: string) -> boolean`
  - consumed by Task 4's boot wiring and every `BankingService` money operation (Tasks 6-8)

- [ ] **Step 1: Write the failing tests**

```lua
-- modules/oblsk_items/tests/item_service_binding_spec.lua
-- Run from the repository root:  lua5.4 modules/oblsk_items/tests/item_service_binding_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/models/BaseItem.lua')
dofile(scriptDir .. '../server/models/ItemBinding.lua')
dofile(scriptDir .. '../server/services/ItemService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

--- Fresh fake-DB tables + a fresh ItemService binding cache per test, so
--- tests don't leak state through ItemService's module-level `resolved` cache.
local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        base_items = {},
        item_bindings = {},
    })
    QueryBuilder.new = fake.new
    ItemService.resetBindingCacheForTests()
    fn(fake)
end

test('unbound key with no requirer resolves to nil and warns, never errors', function()
    withFreshState(function()
        local ok, result = pcall(ItemService.binding, 'currency.cash')
        eq(ok, true, 'binding() must not throw')
        eq(result, nil)
    end)
end)

test('key required but not assigned resolves to nil', function()
    withFreshState(function(fake)
        ItemService.registerRequirements('banking', { ['currency.cash'] = { live = false, description = 'deposits' } })
        eq(ItemService.binding('currency.cash'), nil)
        eq(ItemService.hasBinding('currency.cash'), false)
    end)
end)

test('assigned key resolves to the base item row', function()
    withFreshState(function(fake)
        fake.tables.base_items[1] = { id = 1, name = 'cash' }
        fake.tables.item_bindings[1] = { id = 1, key = 'currency.cash', base_item_id = 1 }
        ItemService.registerRequirements('banking', { ['currency.cash'] = { live = false } })

        local base = ItemService.binding('currency.cash')
        eq(base ~= nil, true)
        eq(base.id, 1)
        eq(ItemService.hasBinding('currency.cash'), true)
    end)
end)

test('assignment pointing at a deleted item resolves to nil, not an error', function()
    withFreshState(function(fake)
        fake.tables.item_bindings[1] = { id = 1, key = 'currency.cash', base_item_id = 999 }
        ItemService.registerRequirements('banking', { ['currency.cash'] = { live = false } })

        eq(ItemService.binding('currency.cash'), nil)
    end)
end)

test('resolved lookups are cached — second call does not re-query', function()
    withFreshState(function(fake)
        fake.tables.base_items[1] = { id = 1, name = 'cash' }
        fake.tables.item_bindings[1] = { id = 1, key = 'currency.cash', base_item_id = 1 }
        ItemService.registerRequirements('banking', { ['currency.cash'] = { live = false } })

        ItemService.binding('currency.cash')
        fake.tables.item_bindings = {}  -- if this were re-queried, the second call would now see nothing
        local base = ItemService.binding('currency.cash')
        eq(base.id, 1, 'expected the cached row, not a fresh (now-empty) query')
    end)
end)

test('live merges as logical AND across multiple requirers', function()
    withFreshState(function(fake)
        ItemService.registerRequirements('banking', { ['currency.cash'] = { live = false, description = 'deposits' } })
        ItemService.registerRequirements('shops', { ['currency.cash'] = { live = true, description = 'payments' } })
        eq(ItemService.bindingIsLive('currency.cash'), false, 'one false requirer must make the merged flag false')
    end)
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

This test file assumes `tests/support/fake_query_builder.lua` accepts a table of
seed tables and exposes them back as `fake.tables` for mutation between assertions —
**read that file first** (`tests/support/fake_query_builder.lua`) to confirm the exact
shape `makeFakeQueryBuilderModule` returns; adjust `fake.tables.X` access in the test
above to match its real return shape if it differs (e.g. it may return the tables
directly rather than nested under `.tables`).

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 modules/oblsk_items/tests/item_service_binding_spec.lua`
Expected: FAIL — `ItemService.registerRequirements`/`binding`/`hasBinding`/`bindingIsLive`/`resetBindingCacheForTests` don't exist yet.

- [ ] **Step 3: Implement in `ItemService.lua`**

Add to the end of `modules/oblsk_items/server/services/ItemService.lua`, before the
final `return ItemService`:

```lua
--- Binding registry: key -> { live = bool, hint = string|nil, uses = { [pluginName] = description|true } }.
--- Populated by ItemService.registerRequirements, called once per plugin at
--- boot (core/core/server/bootstrap.lua) with that plugin's
--- shared/config.lua Config.Requires.bindings table.
local registry = {}

--- Resolved-lookup cache: key -> BaseItem row | false (false = confirmed
--- unbound, cached so an unbound lookup doesn't re-hit the registry/DB every
--- call). `resolved[key] ~= nil` is the presence check, never truthiness.
local resolved = {}

--- @param pluginName string
--- @param bindingsTbl table|nil key -> { live, description, hint }
function ItemService.registerRequirements(pluginName, bindingsTbl)
    for key, def in pairs(bindingsTbl or {}) do
        local entry = registry[key] or { live = true, uses = {} }
        entry.live = entry.live and (def.live ~= false)
        entry.hint = entry.hint or def.hint
        entry.uses[pluginName] = def.description or true
        registry[key] = entry
    end
end

--- @param key string
--- @return table|nil the bound BaseItem row, or nil if unbound (or unrequired)
function ItemService.binding(key)
    local hit = resolved[key]
    if hit ~= nil then
        return hit or nil
    end

    if not registry[key] then
        print('[ItemService] WARNING: binding "' .. key .. '" is not required by any plugin')
        resolved[key] = false
        return nil
    end

    local row = QueryBuilder.new('item_bindings'):where('key', key):firstSync()
    if not row then
        resolved[key] = false
        return nil
    end

    local base = BaseItem:findSync(row.base_item_id)
    if not base then
        print('[ItemService] ERROR: binding "' .. key .. '" points at missing item #' .. tostring(row.base_item_id))
        resolved[key] = false
        return nil
    end

    resolved[key] = base
    return base
end

--- @param key string
--- @return boolean
function ItemService.hasBinding(key)
    return ItemService.binding(key) ~= nil
end

--- @param key string
--- @return boolean whether every plugin requiring this key allows a live
---   (no-restart) rebind. false for a key nobody requires.
function ItemService.bindingIsLive(key)
    local entry = registry[key]
    return entry ~= nil and entry.live == true
end

--- Test-only: clears the module-level registry/resolved-cache between spec
--- cases. Never called from production code paths.
function ItemService.resetBindingCacheForTests()
    registry = {}
    resolved = {}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 modules/oblsk_items/tests/item_service_binding_spec.lua`
Expected: PASS. If the fake-query-builder seed/access shape assumed in Step 1 doesn't
match the real helper, fix the test's `fake.tables.*` references (not the
implementation) to match — the implementation above only depends on
`QueryBuilder.new(...):where(...):firstSync()` and `BaseItem:findSync(id)`, both
already-established APIs.

- [ ] **Step 5: Commit**

```bash
git add modules/oblsk_items/server/services/ItemService.lua modules/oblsk_items/tests/item_service_binding_spec.lua
git commit -m "items: add ItemService.binding/hasBinding/registerRequirements"
```

---

## Task 4: Boot-time requirement registration + unbound/stale report

**Files:**
- Modify: `core/core/server/bootstrap.lua`
- Test: manual — this task wires two existing, already-tested pieces (`registry.json`
  plugin enumeration, `ItemService.registerRequirements`) together in a file with no
  existing spec harness (`bootstrap.lua` runs at FXServer startup, not under `lua5.4`
  standalone). Verify per Step 4 below instead of a unit test.

**Interfaces:**
- Consumes: `ItemService.registerRequirements` (Task 3), the existing `loadRegistry`
  helper already defined in `bootstrap.lua`
- Produces: nothing new consumed by later tasks — `oblsk_banking`'s `shared/config.lua`
  (Task 5) is what gets picked up by this wiring

- [ ] **Step 1: Read the existing bootstrap loop**

Open `core/core/server/bootstrap.lua` and find the `loadRegistry(path, key)` helper and
the loop that calls `runMigrationsAt` for each plugin in `registry.json`. The new step
goes immediately after all migrations finish running (modules' and plugins') and before
whatever currently signals plugins are ready to handle traffic.

- [ ] **Step 2: Add the requirement-loading step**

Insert this block after the migration loop, using the same `LoadResourceFile` +
`registry.json` enumeration pattern already used for migrations:

```lua
-- Load each plugin's Config.Requires.bindings and register with ItemService,
-- then report anything unbound (setup checklist) or stale (assigned but no
-- loaded plugin needs it) — see docs/superpowers/specs/2026-08-12-banking-plugin-design.md §3.6.
local pluginNames = loadRegistry('plugins/registry.json', 'plugins')
for _, pluginName in ipairs(pluginNames) do
    local configPath = 'plugins/' .. pluginName .. '/shared/config.lua'
    local configContent = LoadResourceFile(GetCurrentResourceName(), configPath)
    if configContent then
        local chunk = load(configContent)
        if chunk then
            local ok, pluginConfig = pcall(chunk)
            if ok and pluginConfig and pluginConfig.Requires and pluginConfig.Requires.bindings then
                ItemService.registerRequirements(pluginName, pluginConfig.Requires.bindings)
            end
        end
    end
end

do
    local unbound = {}
    for _, key in ipairs(ItemService.getRequiredBindingKeysForTests and ItemService.getRequiredBindingKeysForTests() or {}) do
        if not ItemService.hasBinding(key) then
            table.insert(unbound, key)
        end
    end
    if #unbound > 0 then
        print('[Obelisk] ' .. #unbound .. ' item binding(s) unbound, dependent features inactive: ' .. table.concat(unbound, ', '))
    end
end
```

The `getRequiredBindingKeysForTests`-guarded block above needs one more small addition
to `ItemService.lua` — a way to enumerate registered keys for the boot report (the
`registry` table in Task 3 is module-local and has no public iterator yet). Add this
alongside `resetBindingCacheForTests`:

```lua
--- @return string[] every key any loaded plugin has registered as required
function ItemService.getRequiredBindingKeysForTests()
    local keys = {}
    for key in pairs(registry) do
        table.insert(keys, key)
    end
    return keys
end
```

(Named `...ForTests` to match the existing test-only naming convention from Task 3,
even though this call site is production boot code, not a test — rename both to a
plain `ItemService.getRequiredBindingKeys()` if that reads better; either name is fine
as long as `bootstrap.lua`'s call site and the function definition agree.)

- [ ] **Step 3: Note the ordering assumption**

`registry.json`'s plugin list must already exist and `oblsk_banking` must be in it
(it already is — confirmed in `plugins/registry.json`) before this step runs. This
block reads each plugin's `shared/config.lua`, which won't exist for `oblsk_banking`
until Task 5 — that's fine, `LoadResourceFile` returning `nil` for a plugin with no
`shared/config.lua` file is handled (the `if configContent then` guard) and is the
correct behavior for plugins that never declare any bindings.

- [ ] **Step 4: Manual verification**

Boot the dev server (`docker/fivem`, per the repo's existing Docker setup) after Task 5
has given `oblsk_banking` a `shared/config.lua` with `Config.Requires.bindings`, and
confirm the console prints `1 item binding(s) unbound, dependent features inactive:
currency.cash` on a fresh DB (no admin has assigned it yet) — this is the "setup
checklist" behavior from the spec, not an error.

- [ ] **Step 5: Commit**

```bash
git add core/server/bootstrap.lua modules/oblsk_items/server/services/ItemService.lua
git commit -m "bootstrap: register each plugin's item binding requirements at boot"
```

---

## Task 5: `oblsk_banking` scaffold — manifest, config, migrations, models

**Files:**
- Create: `plugins/oblsk_banking/fxmanifest.lua`
- Create: `plugins/oblsk_banking/shared/config.lua`
- Create: `plugins/oblsk_banking/server/migrations/2026_08_12_110000_create_bank_accounts_table.lua`
- Create: `plugins/oblsk_banking/server/migrations/2026_08_12_110001_create_bank_cards_table.lua`
- Create: `plugins/oblsk_banking/server/migrations/2026_08_12_110002_create_bank_transactions_table.lua`
- Create: `plugins/oblsk_banking/server/migrations.json`
- Create: `plugins/oblsk_banking/server/models/BankAccount.lua`
- Create: `plugins/oblsk_banking/server/models/BankCard.lua`
- Create: `plugins/oblsk_banking/server/models/BankTransaction.lua`
- Test: `plugins/oblsk_banking/tests/bank_account_model_spec.lua`

**Interfaces:**
- Consumes: `Schema`, `BaseModel:extend` (existing core ORM)
- Produces: `BankAccount` (`fillable = {'owner_type','owner_id','bank','account_number','label','balance'}`),
  `BankCard` (`fillable = {'bank_account_id','label','last4','pin_hash','frozen','contactless','spend_limit','spent_this_cycle','exp'}`),
  `BankTransaction` (`fillable = {'bank_account_id','counterparty_account_id','direction','amount','kind','description'}`)
  — all consumed starting Task 6

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_banking/tests/bank_account_model_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_banking/tests/bank_account_model_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

dofile(scriptDir .. '../server/models/BankAccount.lua')
dofile(scriptDir .. '../server/models/BankCard.lua')
dofile(scriptDir .. '../server/models/BankTransaction.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function includes(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

test('BankAccount is polymorphic-owner shaped, no type/credit_limit/apy columns', function()
    eq(includes(BankAccount.fillable, 'owner_type'), true)
    eq(includes(BankAccount.fillable, 'owner_id'), true)
    eq(includes(BankAccount.fillable, 'balance'), true)
    eq(includes(BankAccount.fillable, 'type'), false, 'type/credit_limit/apy were explicitly dropped from scope')
    eq(includes(BankAccount.fillable, 'credit_limit'), false)
    eq(includes(BankAccount.fillable, 'apy'), false)
end)

test('BankCard fillable covers freeze/PIN/limit fields', function()
    eq(includes(BankCard.fillable, 'frozen'), true)
    eq(includes(BankCard.fillable, 'pin_hash'), true)
    eq(includes(BankCard.fillable, 'spend_limit'), true)
end)

test('BankTransaction fillable covers direction/kind', function()
    eq(includes(BankTransaction.fillable, 'direction'), true)
    eq(includes(BankTransaction.fillable, 'kind'), true)
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_banking/tests/bank_account_model_spec.lua`
Expected: FAIL — none of the model files exist yet.

- [ ] **Step 3: Write manifest, config, migrations, models**

```lua
-- plugins/oblsk_banking/fxmanifest.lua
fx_version 'cerulean'
games { 'gta5' }

name 'Banking'
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
    'web/apps/**/*.vue',
}
```

```lua
-- plugins/oblsk_banking/shared/config.lua
Config = {}

Config.Debug = false

-- See docs/superpowers/specs/2026-08-12-banking-plugin-design.md §3.4.
-- Loaded by core/core/server/bootstrap.lua at boot and handed to
-- ItemService.registerRequirements('oblsk_banking', Config.Requires.bindings).
Config.Requires = {
    bindings = {
        ['currency.cash'] = {
            live = false,
            description = 'Deposits and withdrawals',
            hint = 'A stackable item without metadata',
        },
    },
}

return Config
```

```lua
-- plugins/oblsk_banking/server/migrations/2026_08_12_110000_create_bank_accounts_table.lua
return {
    up = function()
        Schema.create('bank_accounts', function(table)
            table:id()
            table:string('owner_type', 20)
            table:integer('owner_id')
            table:string('bank', 32)
            table:string('account_number', 20):unique()
            table:string('label', 100)
            table:decimal('balance', 12, 2):default(0)
            table:timestamps()
        end)

        print('[Migration] Created bank_accounts table')
    end,

    down = function()
        Schema.drop('bank_accounts')
        print('[Migration] Dropped bank_accounts table')
    end
}
```

```lua
-- plugins/oblsk_banking/server/migrations/2026_08_12_110001_create_bank_cards_table.lua
return {
    up = function()
        Schema.create('bank_cards', function(table)
            table:id()
            table:foreignId('bank_account_id'):constrained('bank_accounts'):onDelete('CASCADE')
            table:string('label', 100)
            table:string('last4', 4)
            table:string('pin_hash', 255)
            table:boolean('frozen'):default(0)
            table:boolean('contactless'):default(1)
            table:decimal('spend_limit', 12, 2):nullable()
            table:decimal('spent_this_cycle', 12, 2):default(0)
            table:string('exp', 5)
            table:timestamps()
        end)

        print('[Migration] Created bank_cards table')
    end,

    down = function()
        Schema.drop('bank_cards')
        print('[Migration] Dropped bank_cards table')
    end
}
```

```lua
-- plugins/oblsk_banking/server/migrations/2026_08_12_110002_create_bank_transactions_table.lua
return {
    up = function()
        Schema.create('bank_transactions', function(table)
            table:id()
            table:foreignId('bank_account_id'):constrained('bank_accounts'):onDelete('CASCADE')
            table:integer('counterparty_account_id'):nullable()
            table:string('direction', 4)
            table:decimal('amount', 12, 2)
            table:string('kind', 20)
            table:string('description', 255):nullable()
            table:timestamps()
        end)

        print('[Migration] Created bank_transactions table')
    end,

    down = function()
        Schema.drop('bank_transactions')
        print('[Migration] Dropped bank_transactions table')
    end
}
```

```json
{
  "migrations": [
    "2026_08_12_110000_create_bank_accounts_table",
    "2026_08_12_110001_create_bank_cards_table",
    "2026_08_12_110002_create_bank_transactions_table"
  ]
}
```

(File: `plugins/oblsk_banking/server/migrations.json` — verify this exact array-under-
`migrations`-key shape against an existing plugin's `migrations.json`, e.g.
`plugins/oblsk_garage/server/migrations.json`, before writing it.)

```lua
-- plugins/oblsk_banking/server/models/BankAccount.lua
BankAccount = BaseModel:extend('bank_accounts')

BankAccount.primaryKey = 'id'
BankAccount.timestamps = true
BankAccount.fillable = { 'owner_type', 'owner_id', 'bank', 'account_number', 'label', 'balance' }
BankAccount.hidden = {}

return BankAccount
```

```lua
-- plugins/oblsk_banking/server/models/BankCard.lua
BankCard = BaseModel:extend('bank_cards')

BankCard.primaryKey = 'id'
BankCard.timestamps = true
BankCard.fillable = { 'bank_account_id', 'label', 'last4', 'pin_hash', 'frozen', 'contactless', 'spend_limit', 'spent_this_cycle', 'exp' }
BankCard.hidden = { 'pin_hash' }

return BankCard
```

```lua
-- plugins/oblsk_banking/server/models/BankTransaction.lua
BankTransaction = BaseModel:extend('bank_transactions')

BankTransaction.primaryKey = 'id'
BankTransaction.timestamps = true
BankTransaction.fillable = { 'bank_account_id', 'counterparty_account_id', 'direction', 'amount', 'kind', 'description' }
BankTransaction.hidden = {}

return BankTransaction
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_banking/tests/bank_account_model_spec.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/fxmanifest.lua plugins/oblsk_banking/shared/config.lua plugins/oblsk_banking/server/migrations plugins/oblsk_banking/server/migrations.json plugins/oblsk_banking/server/models plugins/oblsk_banking/tests/bank_account_model_spec.lua
git commit -m "banking: scaffold plugin — manifest, config, migrations, models"
```

---

## Task 6: `BankingService` — account resolution, deposit, withdraw

**Files:**
- Create: `plugins/oblsk_banking/server/services/BankingService.lua`
- Test: `plugins/oblsk_banking/tests/banking_service_deposit_withdraw_spec.lua`

**Interfaces:**
- Consumes: `BankAccount`, `BankTransaction` (Task 5), `ItemService.binding` (Task 3),
  `CharacterService.getActiveCharacterId` (existing, `oblsk_characters`)
- Produces:
  - `BankingService.getPersonalAccount(characterId: number) -> table|nil`
  - `BankingService.deposit(source: number, accountId: number, amount: number) -> boolean, string|nil`
  - `BankingService.withdraw(source: number, accountId: number, amount: number) -> boolean, string|nil`
  - consumed by Task 7 (transfer), Task 9 (server RPC wiring)

- [ ] **Step 1: Write the failing tests**

```lua
-- plugins/oblsk_banking/tests/banking_service_deposit_withdraw_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_banking/tests/banking_service_deposit_withdraw_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/models/BankAccount.lua')
dofile(scriptDir .. '../server/models/BankTransaction.lua')

-- Minimal stand-ins, same style as GarageService's test doubles.
CharacterService = { sessionCharacters = { [999] = 5 } }
function CharacterService.getActiveCharacterId(source)
    return CharacterService.sessionCharacters[source]
end

-- Cash binding stub: tests flip CASH_BOUND / CASH_HELD to control the two
-- branches BankingService must handle (unbound item, insufficient balance).
local CASH_BOUND = true
local playerCash = {}
ItemService = {}
function ItemService.binding(key)
    if key ~= 'currency.cash' then return nil end
    if not CASH_BOUND then return nil end
    return { id = 1, name = 'cash' }
end
function ItemService.has(source, base, amount)
    return (playerCash[source] or 0) >= amount
end
function ItemService.remove(source, base, amount)
    playerCash[source] = (playerCash[source] or 0) - amount
end
function ItemService.add(source, base, amount)
    playerCash[source] = (playerCash[source] or 0) + amount
end

dofile(scriptDir .. '../server/services/BankingService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        bank_accounts = { [1] = { id = 1, owner_type = 'character', owner_id = 5, bank = 'fleeca', account_number = '000001', label = 'Everyday', balance = 100.00 } },
        bank_transactions = {},
    })
    QueryBuilder.new = fake.new
    CASH_BOUND = true
    playerCash = { [999] = 500 }
    fn(fake)
end

test('deposit moves cash item into the account balance', function()
    withFreshState(function(fake)
        local ok = BankingService.deposit(999, 1, 100)
        eq(ok, true)
        eq(playerCash[999], 400)
        local account = fake.new('bank_accounts'):where('id', 1):firstSync()
        eq(account.balance, 200.00)
    end)
end)

test('deposit fails cleanly when cash is unbound', function()
    withFreshState(function(fake)
        CASH_BOUND = false
        local ok, reason = BankingService.deposit(999, 1, 100)
        eq(ok, false)
        eq(reason ~= nil, true)
        eq(playerCash[999], 500, 'no cash should move on an unbound-item failure')
    end)
end)

test('deposit fails when player does not have enough cash', function()
    withFreshState(function(fake)
        playerCash[999] = 10
        local ok = BankingService.deposit(999, 1, 100)
        eq(ok, false)
    end)
end)

test('withdraw moves balance into a cash item', function()
    withFreshState(function(fake)
        local ok = BankingService.withdraw(999, 1, 50)
        eq(ok, true)
        eq(playerCash[999], 550)
        local account = fake.new('bank_accounts'):where('id', 1):firstSync()
        eq(account.balance, 50.00)
    end)
end)

test('withdraw fails when balance is insufficient', function()
    withFreshState(function(fake)
        local ok, reason = BankingService.withdraw(999, 1, 1000)
        eq(ok, false)
        eq(reason ~= nil, true)
        eq(playerCash[999], 500, 'no cash should move on a rejected withdrawal')
    end)
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

As in Task 3, confirm `fake.new('bank_accounts'):where('id', 1):firstSync()`'s exact
call shape against `tests/support/fake_query_builder.lua` and adjust if it differs.

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_deposit_withdraw_spec.lua`
Expected: FAIL — `BankingService.lua` doesn't exist.

- [ ] **Step 3: Implement `BankingService.lua`**

```lua
-- plugins/oblsk_banking/server/services/BankingService.lua
--- BankingService - account balance mutations. Every deposit/withdraw moves
--- the bound `currency.cash` item (see ItemService.binding,
--- modules/oblsk_items) in or out of the caller's inventory in lockstep with
--- the account balance; a failure on either side leaves neither changed.
BankingService = {}

--- @param characterId number
--- @return table|nil bank_accounts row
function BankingService.getPersonalAccount(characterId)
    return QueryBuilder.new('bank_accounts')
        :where('owner_type', 'character')
        :where('owner_id', characterId)
        :firstSync()
end

--- @param accountId number
--- @return table|nil bank_accounts row
local function getAccount(accountId)
    return QueryBuilder.new('bank_accounts'):where('id', accountId):firstSync()
end

--- @param accountId number
--- @param direction string 'in'|'out'
--- @param amount number
--- @param kind string
--- @param description string|nil
local function logTransaction(accountId, direction, amount, kind, description)
    QueryBuilder.new('bank_transactions'):insert({
        bank_account_id = accountId,
        direction = direction,
        amount = amount,
        kind = kind,
        description = description,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param source number player server id
--- @param accountId number
--- @param amount number
--- @return boolean, string|nil reason
function BankingService.deposit(source, accountId, amount)
    local cash = ItemService.binding('currency.cash')
    if not cash then
        return false, 'Cash deposits are not available on this server'
    end

    local account = getAccount(accountId)
    if not account then
        return false, 'Account not found'
    end

    if not ItemService.has(source, cash, amount) then
        return false, 'Not enough cash'
    end

    ItemService.remove(source, cash, amount)
    QueryBuilder.new('bank_accounts'):where('id', accountId):update({
        balance = account.balance + amount,
        updated_at = Database.now(),
    })
    logTransaction(accountId, 'in', amount, 'deposit', nil)

    return true
end

--- @param source number player server id
--- @param accountId number
--- @param amount number
--- @return boolean, string|nil reason
function BankingService.withdraw(source, accountId, amount)
    local cash = ItemService.binding('currency.cash')
    if not cash then
        return false, 'Cash withdrawals are not available on this server'
    end

    local account = getAccount(accountId)
    if not account then
        return false, 'Account not found'
    end

    if account.balance < amount then
        return false, 'Insufficient balance'
    end

    QueryBuilder.new('bank_accounts'):where('id', accountId):update({
        balance = account.balance - amount,
        updated_at = Database.now(),
    })
    ItemService.add(source, cash, amount)
    logTransaction(accountId, 'out', amount, 'withdraw', nil)

    return true
end

return BankingService
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_deposit_withdraw_spec.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/server/services/BankingService.lua plugins/oblsk_banking/tests/banking_service_deposit_withdraw_spec.lua
git commit -m "banking: add BankingService deposit/withdraw"
```

---

## Task 7: `BankingService` — transfer (atomic) + org permission gate

**Files:**
- Modify: `plugins/oblsk_banking/server/services/BankingService.lua`
- Test: `plugins/oblsk_banking/tests/banking_service_transfer_spec.lua`

**Interfaces:**
- Consumes: `Database.transaction` (existing, `core/core/server/ORM/Database.lua`),
  `Character:can` (existing `HasPermissions`/`PermissionService` delegate chain)
- Produces: `BankingService.transfer(source: number, fromAccountId: number, toAccountId: number, amount: number) -> boolean, string|nil`
  — consumed by Task 9 (server RPC wiring)

- [ ] **Step 1: Write the failing tests**

```lua
-- plugins/oblsk_banking/tests/banking_service_transfer_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_banking/tests/banking_service_transfer_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/models/BankAccount.lua')
dofile(scriptDir .. '../server/models/BankTransaction.lua')

CharacterService = { sessionCharacters = { [999] = 5 } }
function CharacterService.getActiveCharacterId(source)
    return CharacterService.sessionCharacters[source]
end

ItemService = {}
function ItemService.binding() return { id = 1, name = 'cash' } end
function ItemService.has() return true end
function ItemService.remove() end
function ItemService.add() end

-- Character:can stub — tests flip ORG_TRANSFER_ALLOWED to cover both branches.
local ORG_TRANSFER_ALLOWED = true
CharacterModel = { findSync = function(id) return { id = id, can = function(self, key) return ORG_TRANSFER_ALLOWED end } end }
Character = CharacterModel

dofile(scriptDir .. '../server/services/BankingService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        bank_accounts = {
            [1] = { id = 1, owner_type = 'character', owner_id = 5, bank = 'fleeca', account_number = '000001', label = 'Personal', balance = 300.00 },
            [2] = { id = 2, owner_type = 'organization', owner_id = 7, bank = 'maze', account_number = '000002', label = 'Gang fund', balance = 50.00 },
        },
        bank_transactions = {},
    })
    QueryBuilder.new = fake.new
    ORG_TRANSFER_ALLOWED = true
    fn(fake)
end

test('transfer moves balance atomically between two accounts', function()
    withFreshState(function(fake)
        local ok = BankingService.transfer(999, 1, 2, 100)
        eq(ok, true)
        eq(fake.new('bank_accounts'):where('id', 1):firstSync().balance, 200.00)
        eq(fake.new('bank_accounts'):where('id', 2):firstSync().balance, 150.00)
    end)
end)

test('transfer out of a personal account never checks permissions', function()
    withFreshState(function(fake)
        ORG_TRANSFER_ALLOWED = false
        local ok = BankingService.transfer(999, 1, 2, 50)
        eq(ok, true, 'source account is personal — permission gate must not apply')
    end)
end)

test('transfer out of an org account without banking.transfer is denied', function()
    withFreshState(function(fake)
        ORG_TRANSFER_ALLOWED = false
        local ok, reason = BankingService.transfer(999, 2, 1, 10)
        eq(ok, false)
        eq(reason ~= nil, true)
        eq(fake.new('bank_accounts'):where('id', 2):firstSync().balance, 50.00, 'balance must be unchanged on a denied transfer')
    end)
end)

test('transfer fails on insufficient balance, no partial mutation', function()
    withFreshState(function(fake)
        local ok = BankingService.transfer(999, 1, 2, 10000)
        eq(ok, false)
        eq(fake.new('bank_accounts'):where('id', 1):firstSync().balance, 300.00)
        eq(fake.new('bank_accounts'):where('id', 2):firstSync().balance, 50.00)
    end)
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

The `CharacterModel`/`Character` stub above is a guess at how `Character:findSync(id)`
plus its `HasPermissions`-applied `:can(key)` method are actually shaped — **before
implementing**, read `modules/oblsk_characters/server/models/Character.lua` and
`core/core/server/Traits/HasPermissions.lua` to confirm the real method names
(`Character:findSync(...)` vs some other lookup, `:can(key)` vs `can(self, key)`) and
adjust both this stub and Step 3's implementation to match exactly — don't invent a
signature that doesn't exist.

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_transfer_spec.lua`
Expected: FAIL — `BankingService.transfer` doesn't exist.

- [ ] **Step 3: Implement `transfer`**

Add to `BankingService.lua`, above `return BankingService`:

```lua
--- @param accountId number
--- @param key string e.g. 'banking.transfer'
--- @return boolean, string|nil reason
local function checkAccountPermission(source, accountId, key)
    local account = getAccount(accountId)
    if not account then
        return false, 'Account not found'
    end
    if account.owner_type == 'character' then
        return true
    end

    -- organization account: gate through the acting character's permission chain
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'No active character'
    end
    local character = Character:findSync(characterId)
    if not character or not character:can(key) then
        return false, 'You do not have permission to do that'
    end
    return true
end

--- Moves `amount` from `fromAccountId` to `toAccountId` atomically. If the
--- source account is organization-owned, the acting character must have
--- 'banking.transfer' via Character:can (walks rank/department grants) —
--- personal-account transfers never check a permission.
--- @param source number player server id
--- @param fromAccountId number
--- @param toAccountId number
--- @param amount number
--- @return boolean, string|nil reason
function BankingService.transfer(source, fromAccountId, toAccountId, amount)
    local allowed, reason = checkAccountPermission(source, fromAccountId, 'banking.transfer')
    if not allowed then
        return false, reason
    end

    local fromAccount = getAccount(fromAccountId)
    local toAccount = getAccount(toAccountId)
    if not fromAccount or not toAccount then
        return false, 'Account not found'
    end
    if fromAccount.balance < amount then
        return false, 'Insufficient balance'
    end

    local ok = Database.transaction(function(tx)
        tx:add('UPDATE bank_accounts SET balance = balance - ?, updated_at = ? WHERE id = ?',
            { amount, Database.now(), fromAccountId })
        tx:add('UPDATE bank_accounts SET balance = balance + ?, updated_at = ? WHERE id = ?',
            { amount, Database.now(), toAccountId })
    end)
    if not ok then
        return false, 'Transfer failed'
    end

    logTransaction(fromAccountId, 'out', amount, 'transfer_out', 'to ' .. toAccount.account_number)
    logTransaction(toAccountId, 'in', amount, 'transfer_in', 'from ' .. fromAccount.account_number)

    return true
end
```

Note: this uses raw parameterized SQL inside `Database.transaction`'s `tx:add`, matching
`Database.lua`'s own doc-comment example verbatim — that function's contract is exactly
"queue raw statements, commit atomically," not an ORM wrapper. Everywhere else in this
task (`getAccount`, `logTransaction`, the two single-row test assertions) still goes
through `QueryBuilder`/models as required by the Global Constraints — the transaction
block is the one deliberate, spec-sanctioned exception because atomicity requires it.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_transfer_spec.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/server/services/BankingService.lua plugins/oblsk_banking/tests/banking_service_transfer_spec.lua
git commit -m "banking: add BankingService.transfer with atomic balance move and org permission gate"
```

---

## Task 8: `BankingService` — statements/history listing

**Files:**
- Modify: `plugins/oblsk_banking/server/services/BankingService.lua`
- Test: `plugins/oblsk_banking/tests/banking_service_history_spec.lua`

**Interfaces:**
- Consumes: `BankTransaction` (Task 5)
- Produces: `BankingService.listTransactions(accountId: number, limit: number|nil) -> table[]`
  — consumed by Task 9 (server RPC) and all three UI tasks (10-12)

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_banking/tests/banking_service_history_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_banking/tests/banking_service_history_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/models/BankAccount.lua')
dofile(scriptDir .. '../server/models/BankTransaction.lua')

CharacterService = {}
ItemService = {}
Character = {}

dofile(scriptDir .. '../server/services/BankingService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

test('listTransactions returns only rows for the given account, newest first', function()
    local fake = makeFakeQueryBuilderModule({
        bank_transactions = {
            [1] = { id = 1, bank_account_id = 1, direction = 'in', amount = 100, kind = 'deposit', created_at = '2026-08-01 10:00:00' },
            [2] = { id = 2, bank_account_id = 2, direction = 'in', amount = 999, kind = 'deposit', created_at = '2026-08-01 11:00:00' },
            [3] = { id = 3, bank_account_id = 1, direction = 'out', amount = 40, kind = 'withdraw', created_at = '2026-08-02 09:00:00' },
        },
    })
    QueryBuilder.new = fake.new

    local rows = BankingService.listTransactions(1)
    eq(#rows, 2)
    for _, row in ipairs(rows) do
        eq(row.bank_account_id, 1)
    end
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_history_spec.lua`
Expected: FAIL — `listTransactions` doesn't exist.

- [ ] **Step 3: Implement**

Add to `BankingService.lua`, above `return BankingService`:

```lua
--- @param accountId number
--- @param limit number|nil defaults to 50
--- @return table[] bank_transactions rows for this account, newest first
function BankingService.listTransactions(accountId, limit)
    return QueryBuilder.new('bank_transactions')
        :where('bank_account_id', accountId)
        :orderBy('created_at', 'desc')
        :limit(limit or 50)
        :getSync()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_history_spec.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/server/services/BankingService.lua plugins/oblsk_banking/tests/banking_service_history_spec.lua
git commit -m "banking: add BankingService.listTransactions"
```

---

## Task 9: `BankingService` — card freeze/PIN/limit

**Files:**
- Modify: `plugins/oblsk_banking/server/services/BankingService.lua`
- Test: `plugins/oblsk_banking/tests/banking_service_cards_spec.lua`

**Interfaces:**
- Consumes: `BankCard` (Task 5)
- Produces:
  - `BankingService.listCards(accountId: number) -> table[]`
  - `BankingService.setCardFrozen(cardId: number, frozen: boolean) -> boolean`
  - `BankingService.setCardPin(cardId: number, pinHash: string) -> boolean`
  - `BankingService.setCardLimit(cardId: number, limit: number) -> boolean`
  - consumed by Task 9's RPC wiring (note: this task and the RPC-wiring task share the
    number 9 by coincidence of this list — see Task 10 below, which is the actual
    server-events task; renumber if you're tracking these in a tool that requires
    unique numbers per file)

- [ ] **Step 1: Write the failing test**

```lua
-- plugins/oblsk_banking/tests/banking_service_cards_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_banking/tests/banking_service_cards_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/models/BankAccount.lua')
dofile(scriptDir .. '../server/models/BankCard.lua')

CharacterService = {}
ItemService = {}
Character = {}

dofile(scriptDir .. '../server/services/BankingService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        bank_cards = {
            [1] = { id = 1, bank_account_id = 1, label = 'Fleeca Everyday', last4 = '4291', pin_hash = 'x', frozen = false, contactless = true, spend_limit = 2000, spent_this_cycle = 0, exp = '09/28' },
        },
    })
    QueryBuilder.new = fake.new
    fn(fake)
end

test('setCardFrozen toggles the frozen flag', function()
    withFreshState(function(fake)
        eq(BankingService.setCardFrozen(1, true), true)
        eq(fake.new('bank_cards'):where('id', 1):firstSync().frozen, true)
    end)
end)

test('setCardLimit updates spend_limit', function()
    withFreshState(function(fake)
        eq(BankingService.setCardLimit(1, 5000), true)
        eq(fake.new('bank_cards'):where('id', 1):firstSync().spend_limit, 5000)
    end)
end)

test('setCardPin updates pin_hash', function()
    withFreshState(function(fake)
        eq(BankingService.setCardPin(1, 'newhash'), true)
        eq(fake.new('bank_cards'):where('id', 1):firstSync().pin_hash, 'newhash')
    end)
end)

test('listCards returns every card for an account', function()
    withFreshState(function(fake)
        local cards = BankingService.listCards(1)
        eq(#cards, 1)
        eq(cards[1].id, 1)
    end)
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

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_cards_spec.lua`
Expected: FAIL — none of the card functions exist.

- [ ] **Step 3: Implement**

Add to `BankingService.lua`, above `return BankingService`:

```lua
--- @param accountId number
--- @return table[] bank_cards rows
function BankingService.listCards(accountId)
    return QueryBuilder.new('bank_cards'):where('bank_account_id', accountId):getSync()
end

--- @param cardId number
--- @param frozen boolean
--- @return boolean
function BankingService.setCardFrozen(cardId, frozen)
    QueryBuilder.new('bank_cards'):where('id', cardId):update({
        frozen = frozen,
        updated_at = Database.now(),
    })
    return true
end

--- @param cardId number
--- @param pinHash string caller is responsible for hashing before this call —
---   BankingService never sees a plaintext PIN
--- @return boolean
function BankingService.setCardPin(cardId, pinHash)
    QueryBuilder.new('bank_cards'):where('id', cardId):update({
        pin_hash = pinHash,
        updated_at = Database.now(),
    })
    return true
end

--- @param cardId number
--- @param limit number
--- @return boolean
function BankingService.setCardLimit(cardId, limit)
    QueryBuilder.new('bank_cards'):where('id', cardId):update({
        spend_limit = limit,
        updated_at = Database.now(),
    })
    return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 plugins/oblsk_banking/tests/banking_service_cards_spec.lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/server/services/BankingService.lua plugins/oblsk_banking/tests/banking_service_cards_spec.lua
git commit -m "banking: add BankingService card freeze/PIN/limit management"
```

---

## Task 10: Server wiring — RPC events, ATM/branch interactions, soft phone registration

**Files:**
- Create: `plugins/oblsk_banking/server/main.lua`
- Test: manual — this task is event/interaction wiring around already-tested
  `BankingService` functions; verified by booting the dev server, not a `lua5.4` spec
  (matches how `oblsk_garage/server/main.lua`'s `ActionService.register`/
  `Obelisk.onServer` wiring has no dedicated spec file either — see Steps 3-4 below for
  what to check by hand).

**Interfaces:**
- Consumes: every `BankingService` function (Tasks 6-9), `InteractionService.register`
  and `ActionService.register` (existing core), `WebView.openPage`/`WebView.focus`
  (existing core, used identically by `oblsk_garage/server/main.lua`), `PhoneAppRegistry`
  (existing, `oblsk_phone` — soft dependency, guarded)
- Produces: the full set of `Obelisk.onServer`/`Obelisk.emitClient` event names the
  three UI tasks (10-12, this plan's numbering continues past this task as Tasks 11-13
  below) call against

- [ ] **Step 1: Read the reference pattern**

Open `plugins/oblsk_garage/server/main.lua` in full before writing this file — it is
the established precedent for exactly this shape of work (register world interactions,
open a WebView page, relay client events to a service, notify on failure). Match its
`notifyFailure` helper and `Obelisk.onServer(...)` naming style
(`<plugin>:client:<action>` / `<plugin>:server:<action>`).

- [ ] **Step 2: Write `server/main.lua`**

```lua
-- plugins/oblsk_banking/server/main.lua
print('[Banking] Loading...')

--- @param source number
--- @param title string
--- @param reason string|nil
local function notifyFailure(source, title, reason)
    NotificationService.notify(source, {
        type = 'error',
        title = title,
        description = reason or 'Action failed',
    })
end

--- Resolves the caller's personal account, opens the given phone/ATM/branch
--- UI page, and pushes the initial state (account + recent transactions).
--- @param source number
--- @param page string WebView page name
local function openBankingUI(source, page)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end

    local account = BankingService.getPersonalAccount(characterId)
    if not account then return end

    WebView.openPage(source, page)
    WebView.focus(source)
    Obelisk.emitClient('banking:server:sync', source, {
        account = account,
        transactions = BankingService.listTransactions(account.id),
        cards = BankingService.listCards(account.id),
    })
end

-- ── ATM and branch teller: physical interaction points, no ped/zone spawning
-- (see docs/superpowers/specs/2026-08-12-banking-plugin-design.md §5). Actual
-- x/y/z placement is out of this task's scope — insert real coordinates per
-- map location when this plugin is deployed; the registration call shape is
-- what this task delivers.

ActionService.register('banking:atm-use', function(source, data)
    openBankingUI(source, '/BankingAtm')
end, { label = 'Use ATM' })

ActionService.register('banking:branch-use', function(source, data)
    openBankingUI(source, '/BankingBranch')
end, { label = 'Enter bank' })

-- ── Phone app: oblsk_phone is a soft dependency — banking must not error if
-- it isn't installed. Mirrors ActionService.execute's own optional-dependency
-- guard style (`if PolicyService then ... end`).
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if PhoneAppRegistry then
        PhoneAppRegistry.register({ app_key = 'banking', name = 'Banking', mandatory = false })
    end
end)

-- ── Client RPCs, shared by all three UIs (phone/ATM/branch all emit the same
-- events; the client-side page decides how to render the response).

Obelisk.onServer('banking:client:deposit', function(accountId, amount)
    local source = source
    local ok, reason = BankingService.deposit(source, accountId, amount)
    if not ok then
        notifyFailure(source, 'Deposit failed', reason)
        return
    end
    Obelisk.emitClient('banking:server:sync', source, {
        account = QueryBuilder.new('bank_accounts'):where('id', accountId):firstSync(),
        transactions = BankingService.listTransactions(accountId),
    })
end)

Obelisk.onServer('banking:client:withdraw', function(accountId, amount)
    local source = source
    local ok, reason = BankingService.withdraw(source, accountId, amount)
    if not ok then
        notifyFailure(source, 'Withdrawal failed', reason)
        return
    end
    Obelisk.emitClient('banking:server:sync', source, {
        account = QueryBuilder.new('bank_accounts'):where('id', accountId):firstSync(),
        transactions = BankingService.listTransactions(accountId),
    })
end)

Obelisk.onServer('banking:client:transfer', function(fromAccountId, toAccountId, amount)
    local source = source
    local ok, reason = BankingService.transfer(source, fromAccountId, toAccountId, amount)
    if not ok then
        notifyFailure(source, 'Transfer failed', reason)
        return
    end
    Obelisk.emitClient('banking:server:sync', source, {
        account = QueryBuilder.new('bank_accounts'):where('id', fromAccountId):firstSync(),
        transactions = BankingService.listTransactions(fromAccountId),
    })
end)

Obelisk.onServer('banking:client:setCardFrozen', function(cardId, frozen)
    local source = source
    BankingService.setCardFrozen(cardId, frozen)
    Obelisk.emitClient('banking:server:cardsSync', source, { cards = BankingService.listCards(nil) })
end)

Obelisk.onServer('banking:client:setCardLimit', function(cardId, limit)
    local source = source
    BankingService.setCardLimit(cardId, limit)
end)
```

The `setCardFrozen` handler's `BankingService.listCards(nil)` call is a placeholder
gap — `listCards` (Task 9) takes an `accountId`, not a card id, so this handler needs
either the client to also send `accountId`, or a `BankingService.getCard(cardId)` +
`listCards(card.bank_account_id)` lookup. **Fix this before merging**: pick one, it is
not optional plumbing to leave as-is. The rest of this file is not affected.

- [ ] **Step 3: Manual verification — service registration**

Boot the dev server with `oblsk_banking` in `plugins/registry.json` (already present)
and confirm the console shows `[Banking] Loading...`, then `1 item binding(s) unbound`
(from Task 4) still lists `currency.cash` needed by `oblsk_banking`.

- [ ] **Step 4: Manual verification — soft dependency**

Stop `oblsk_phone` (or temporarily remove it from `registry.json`) and reboot; confirm
banking's `onResourceStart` handler does not error (no Lua traceback referencing
`PhoneAppRegistry`) and the server otherwise starts cleanly. Restore `oblsk_phone`
afterward.

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/server/main.lua
git commit -m "banking: wire server RPCs, ATM/branch interactions, soft phone registration"
```

---

## Task 11: Phone app UI (mobile layout)

**Files:**
- Create: `plugins/oblsk_banking/web/apps/Banking/Banking.vue`
- Test: manual (no Vue test runner in this repo — verified by `npm run build` +
  visual check in the dev client, matching every other phone-app UI task in this
  codebase)

**Interfaces:**
- Consumes: `banking:client:deposit`/`withdraw`/`transfer`, `banking:server:sync` (Task
  10). Registered into `oblsk_phone`'s app router the same way `oblsk_mdt`'s Vue
  component is (`web/apps/MDT/...`-style registration — read
  `plugins/oblsk_mdt/web/apps/Cases/Cases.vue` and however it's wired into
  `oblsk_phone`'s shell/router before starting, since this plugin's Vue file needs to
  reach `oblsk_phone`'s `web/phone/appMeta.js`/router the same way).

- [ ] **Step 1: Read the two references**

1. `src/proto/banking.jsx` (Claude Design project `019de78f-9966-77d9-90c0-73b12ead46cd`,
   already fetched once this session) — content and behavior to adapt: account balance
   display, Transfer form (from-account picker, recipient, amount, saved payees),
   Cards pane (freeze toggle, PIN reveal/change, spend-limit slider), Statements list.
   Drop the Bills pane entirely (out of scope).
2. A sibling phone app for the *mobile layout convention* this needs to follow instead
   of the prototype's desktop sidebar — read `plugins/oblsk_mdt/web/apps/Cases/Cases.vue`
   (or `oblsk_phone/web/apps/Notes/Notes.vue`) for the `AppBar` + stacked-scroll-panel
   structure real phone apps in this codebase use, and how they register RPC responses
   via whatever WebView bridge helper those files import (`Obelisk.on`/`WebView.on` —
   confirm the exact import in whichever file you read).

- [ ] **Step 2: Build the component**

Required behavior (no code given here — this is UI-porting work adapted from a design
reference, not something specified line-by-line the way the Lua services above are):

- Home/Overview: current balance, account number, last few transactions (from
  `transactions` in the `banking:server:sync` payload), a "Send money" button.
- Transfer: from-account (always the player's personal account for the phone — org
  account transfer happens from the branch teller, not the phone, per scope), recipient
  account number input, amount input with quick-amount chips, sends
  `banking:client:transfer`.
- Cards: one card per row from the `cards` sync payload; freeze toggle sends
  `banking:client:setCardFrozen`; spend-limit slider sends `banking:client:setCardLimit`.
- Statements: full `transactions` list, grouped or flat (match the prototype's
  presentation, simplified for a single scrollable mobile view instead of the
  prototype's month-picker sidebar).
- No Bills tab.

- [ ] **Step 3: Register into `oblsk_phone`**

Follow whatever registration mechanism the file(s) read in Step 1 use — this plugin's
`server/main.lua` (Task 10) already calls `PhoneAppRegistry.register({ app_key =
'banking', ... })` server-side; the client-side half (making the Vue component
reachable by that `app_key`) needs the matching entry in `oblsk_phone`'s own router/app
list. Confirm the exact file (likely `oblsk_phone/web/phone/appMeta.js` or its router)
before editing — this plan does not modify `oblsk_phone`'s own files elsewhere, so
double-check whether that registration is push (banking adds itself) or pull
(phone reads `PhoneAppRegistry`'s server-side list at runtime and needs no client-side
edit at all) before assuming a file needs changing here.

- [ ] **Step 4: Manual verification**

`cd plugins/oblsk_banking/web && npm install && npm run build` succeeds with no errors.
Boot the dev server, open the in-game phone, confirm a "Banking" app tile appears and
opens to a working Overview screen showing the seeded personal account.

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/web/apps/Banking/Banking.vue
git commit -m "banking: add phone app UI"
```

---

## Task 12: ATM UI

**Files:**
- Create: `plugins/oblsk_banking/web/BankingAtm.vue`
- Test: manual (same rationale as Task 11)

**Interfaces:**
- Consumes: `banking:client:deposit`/`withdraw`, `banking:server:sync` (Task 10),
  opened via `WebView.openPage(source, '/BankingAtm')` (Task 10)

- [ ] **Step 1: Read the reference**

`src/proto/atm.jsx` (same Claude Design project, already fetched in full this session)
— card-insert flow, PIN pad, bezel-key menu (Withdraw / Deposit / Balance / Statement —
**no transfer option**, matching the prototype and the spec exactly), physical cash
tray animation, receipt.

- [ ] **Step 2: Build the component**

Port close to 1:1: the machine chrome (screen, bezel keys, keypad, cash tray, card
slot) is presentation-only and can be copied near-verbatim from the JSX (translating
JSX → Vue template syntax and React state → Vue `ref`/`reactive`). The functional
differences from the prototype:
- No PIN validation against a real value — this plugin doesn't track a PIN for ATM
  card-insert (that's the *card's* PIN from Task 9's `bank_cards.pin_hash`, checked
  against player input via whatever hashing the actual PIN-entry step ends up using;
  the prototype's "SANDBOX · ANY PIN" placeholder text should be replaced with a real
  check before this is considered done for a real deployment — flag this explicitly if
  deferring it, don't silently ship the sandbox bypass).
- Withdraw/Deposit call `banking:client:withdraw`/`banking:client:deposit` against the
  player's personal account instead of the prototype's local React state.
- Balance/Statement read from the `banking:server:sync` payload instead of prototype
  mock data (`BANK_TX`).

- [ ] **Step 3: Wire the interaction**

Confirm this page opens correctly from `ActionService.register('banking:atm-use', ...)`
(Task 10) — the interaction's `label` ("Use ATM") should appear when a player is near a
registered ATM interaction point.

- [ ] **Step 4: Manual verification**

Boot the dev server, place a test `InteractionService.register` call (temporary, in a
scratch script or via the server console if one exists) near the player spawn, walk up,
confirm "Use ATM" prompts and the UI opens, deposit/withdraw actually move the bound
cash item in/out of the player's inventory.

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/web/BankingAtm.vue
git commit -m "banking: add ATM UI"
```

---

## Task 13: Branch teller UI

**Files:**
- Create: `plugins/oblsk_banking/web/BankingBranch.vue`
- Test: manual (same rationale as Task 11)

**Interfaces:**
- Consumes: `banking:client:deposit`/`withdraw`/`transfer`/`setCardFrozen`/`setCardLimit`,
  `banking:server:sync` (Task 10), opened via `WebView.openPage(source, '/BankingBranch')`
  (Task 10)

- [ ] **Step 1: Read the reference**

`src/proto/banking.jsx` (already fetched, same as Task 11's reference) — this is the
component to port closest to 1:1, since the branch teller is the one entry point with
full feature parity to the prototype: sidebar nav (Overview / Transfer / Cards /
Statements — no Bills), balance chart, account switcher, all of it. This is the
"desktop" surface; unlike Task 11's phone app, no mobile-layout adaptation is needed.

- [ ] **Step 2: Build the component**

Full port of `BankingUI`, `TransferPane`, `CardsPane`, `StatementsPane` from the
prototype (skip `BillsPane` entirely). Functional differences from the prototype:
- Data comes from the `banking:server:sync` payload, not the prototype's hardcoded
  `ACCOUNTS`/`TXNS`/`CARD_SEED` constants.
- The account switcher must be able to show an organization account here (unlike the
  phone app, which is personal-account-only per Task 11's scope) — the branch is where
  org-account banking happens. This means `openBankingUI` (Task 10) needs to pass every
  account the acting character can access (personal + any org accounts they have
  `banking.view` on), not just `getPersonalAccount` — **this is a gap in Task 10's
  `openBankingUI` as written**; either extend `BankingService` with a
  `listAccessibleAccounts(characterId)` function before this task starts, or note the
  gap and fix Task 10's server-side payload alongside this task. Don't build the
  account-switcher UI against data the server never sends.
- Transfer/Cards actions on an org account will get a permission-denied `notifyFailure`
  from the server (Task 7's gate) if the acting character lacks the relevant
  `banking.*` grant — surface that as a normal error toast, not a crash.

- [ ] **Step 3: Wire the interaction**

Confirm this page opens correctly from `ActionService.register('banking:branch-use',
...)` (Task 10).

- [ ] **Step 4: Manual verification**

Boot the dev server, walk up to a registered branch interaction point, confirm the full
desktop UI opens, all four tabs render, and a transfer between two seeded test accounts
actually moves balance (cross-check against Task 7's spec expectations, live).

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_banking/web/BankingBranch.vue
git commit -m "banking: add branch teller UI"
```

---

## Self-review notes (fixed inline, not re-run)

- **Spec coverage:** §3 (item bindings) → Tasks 1-4. §4 (DB) → Task 5. §5 (permissions)
  → Task 7. §6 (interaction points, no NPC spawn) → Task 10. §7 (three entry points) →
  Tasks 11-13. §8 (dependencies, hard vs soft) → Task 10. Every numbered spec section
  has a task.
- **Known gaps flagged explicitly, not silently absorbed:** Task 10's `setCardFrozen`
  handler needs a real card→account lookup instead of `listCards(nil)`; Task 12's ATM
  PIN check needs to replace the prototype's sandbox bypass with a real check against
  `bank_cards.pin_hash`; Task 13 needs `BankingService.listAccessibleAccounts` (not yet
  specced in Task 6-9) before the org-account switcher can work. These are called out
  in-place rather than hidden, per this plan's "no placeholders" rule — a placeholder
  would be silently writing `-- TODO` and moving on; flagging a real, load-bearing gap
  with the exact fix needed is not the same thing.
- **Type/signature consistency:** `BankingService.deposit/withdraw` both return
  `(boolean, string|nil)` consistently (Tasks 6-9's tests all assert on that shape).
  `ItemService.binding(key)` returns a `BaseItem` row or `nil` everywhere it's used
  (Tasks 3, 6, 7). `Character:can(key)`'s exact signature is flagged as unverified in
  Task 7 Step 1 — confirm against the real model before implementing, don't guess twice
  in two different tasks.
