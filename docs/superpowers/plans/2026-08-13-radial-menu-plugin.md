# Radial Menu Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `oblsk_radialmenu`, a global-component plugin providing a multi-level, database-backed radial interaction wheel (like `oblsk_phone`/`oblsk_hud`), ported 1:1 in UX from the Claude Design prototype `src/proto/radial.jsx`.

**Architecture:** Server owns menu/entry storage (`radial_menus`/`radial_menu_entries` tables, self-referencing tree) behind `RadialMenuService`; a keybind (`G`, via `ActionService`) opens the `'default'` menu by pushing its full tree to the client in one shot; the Vue global component drills through the tree client-side (no per-level round trip) and dispatches the chosen leaf's `action_id` back through `ActionService.execute`.

**Tech Stack:** Lua 5.4 (FXServer), Vue 3 SFC (`<script setup>`), Tailwind (core's CDN build, `--ob-accent`/`ob-mono` tokens), this framework's ORM (`Schema`/`QueryBuilder`), hand-rolled Lua test runner (`lua5.4 *_spec.lua`, inline `test()`/`eq()`/`truthy()` per file — no shared harness module).

## Global Constraints

- `oblsk_radialmenu` is a genuinely separate, standalone git repository (own `git init`, own remote), nested at `core/plugins/oblsk_radialmenu/` on disk. `core/.gitignore` has `plugins/*`, so core's repo never tracks its contents — do not attempt to `git add`/commit plugin files from inside the `core` repo.
- No plugin-local `fxmanifest.lua` or `web/package.json` — every other current plugin (`oblsk_phone`, `oblsk_hud`) has neither; core's own `fxmanifest.lua` globs (`plugins/*/{shared,server,client}/**/*.lua`) and Vite's `import.meta.glob` pick everything up automatically. Do not add one.
- Server code is globals with dot notation (`RadialMenuService.foo`, not `RadialMenuService:foo`), matching `PermissionService`/`ActionService`/`WebView`.
- DB access goes through `QueryBuilder.new(tableName)` directly (`:where(...):firstSync()`, `:insert(...)`, `:update(...)`), the same style as `PermissionService`/`ActionService` — no `BaseModel` subclass for this plugin's tables (they're simple keyed registries, not rich entities).
- Event naming: `<plugin>:server:<action>` for client→server RPCs, `<plugin>:client:<action>` for both (a) server→client relays via `Obelisk.emitClient`/`Obelisk.onClient`, and (b) NUI(Vue)→Lua callbacks registered via `WebView.on` — this framework reuses the `:client:` segment for both directions (confirmed by `core:client:navigate`/`core:client:close` in `WebView.lua`).
- No icon library dependency (no lucide/heroicons in this repo) — icons are a hand-rolled `Icon.vue` with an inline SVG glyph dictionary, same pattern as `oblsk_phone/web/phone/Icon.vue`.
- Lua tests: each `*_spec.lua` is fully self-contained (re-declares `test`/`eq`/`truthy` inline, no shared harness file), `dofile`s the real ORM/service source plus a local `tests/support/fake_query_builder.lua`, and is run directly with `lua5.4 <path>`.
- No admin UI for authoring menus in this plugin (future work) — menus are seeded via a plugin-side seed service, called once from `server/main.lua`, following `oblsk_mdt`'s `MdtSeedService`/`oblsk_garage`'s `GaragePermissionSeeder` pattern.
- No real game actions are wired to leaf entries — every seeded leaf points at one shared placeholder action this plugin registers itself (see Task 6), per the spec's non-goals.

---

### Task 1: Scaffold the plugin repository

**Files:**
- Create: `core/plugins/oblsk_radialmenu/` (new standalone git repo)
- Create: `core/plugins/oblsk_radialmenu/README.md`
- Modify: `core/plugins/registry.json` (local-only edit, not committed — see Global Constraints)

**Interfaces:**
- Produces: the repo root every later task writes into.

- [ ] **Step 1: Create the directory and initialize its own git repo**

```bash
mkdir -p /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git init
```

- [ ] **Step 2: Write the README**

Create `core/plugins/oblsk_radialmenu/README.md`:

```markdown
# oblsk_radialmenu

Global-component plugin: a multi-level, database-backed radial interaction
wheel. See `core/docs/superpowers/specs/2026-08-13-radial-menu-plugin-design.md`
in the core repo for the full design.

- Default keybind `G` opens the `'default'` menu.
- Other plugins open any menu by calling `RadialMenuService.open(source, menuKey)`.
- Menus/entries live in `radial_menus`/`radial_menu_entries`, seeded idempotently
  by `RadialMenuSeedService.ensureDefaultMenu()` (called from `server/main.lua`).
```

- [ ] **Step 3: Add and commit the README in the new repo**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add README.md
git commit -m "Scaffold oblsk_radialmenu plugin"
```

- [ ] **Step 4: Register the plugin locally**

Read `core/plugins/registry.json`, add `"oblsk_radialmenu"` to the `plugins` array (keep the existing entries, alphabetical position doesn't matter — match the existing list's ordering style). Do NOT run `git add`/`git commit` in the `core` repo for this — `core/.gitignore` has `plugins/*` and this file is local dev config, not tracked history (see Global Constraints; this exact mistake was made and reverted earlier in this project).

---

### Task 2: Database migrations for `radial_menus` and `radial_menu_entries`

**Files:**
- Create: `core/plugins/oblsk_radialmenu/server/migrations.json`
- Create: `core/plugins/oblsk_radialmenu/server/migrations/2026_08_13_020000_create_radial_menus_table.lua`
- Create: `core/plugins/oblsk_radialmenu/server/migrations/2026_08_13_020001_create_radial_menu_entries_table.lua`

**Interfaces:**
- Produces: tables `radial_menus(menu_key PK, label)` and `radial_menu_entries(id PK, menu_key, entry_key, parent_entry_key, label, icon, action_id, sort_order, created_at, updated_at)`, with a unique index on `(menu_key, entry_key)`, that Task 3's `RadialMenuService` reads/writes via `QueryBuilder`.

- [ ] **Step 1: Write the migrations list**

Create `core/plugins/oblsk_radialmenu/server/migrations.json`:

```json
{
  "migrations": [
    "2026_08_13_020000_create_radial_menus_table",
    "2026_08_13_020001_create_radial_menu_entries_table"
  ]
}
```

- [ ] **Step 2: Write the `radial_menus` migration**

Create `core/plugins/oblsk_radialmenu/server/migrations/2026_08_13_020000_create_radial_menus_table.lua`:

```lua
--- Migration: Create radial_menus table
--- One row per named menu (e.g. 'default'). menu_key is the primary key so
--- RadialMenuService can look menus up by name without a separate id join.
return {
    up = function()
        Schema.create('radial_menus', function(table)
            table:string('menu_key', 64):primary()
            table:string('label', 128)
            table:timestamps()
        end)

        print('[Migration] Created radial_menus table')
    end,

    down = function()
        Schema.drop('radial_menus')
        print('[Migration] Dropped radial_menus table')
    end
}
```

- [ ] **Step 3: Write the `radial_menu_entries` migration**

Create `core/plugins/oblsk_radialmenu/server/migrations/2026_08_13_020001_create_radial_menu_entries_table.lua`:

```lua
--- Migration: Create radial_menu_entries table
--- Flat storage for an arbitrary-depth tree: parent_entry_key self-references
--- entry_key within the SAME menu_key (null = root-level wedge). A row is a
--- branch if some other row in the same menu has parent_entry_key equal to
--- its entry_key; otherwise it's a leaf and action_id must be set.
return {
    up = function()
        Schema.create('radial_menu_entries', function(table)
            table:id()
            table:string('menu_key', 64)
            table:string('entry_key', 64)
            table:string('parent_entry_key', 64):nullable()
            table:string('label', 128)
            table:string('icon', 32)
            table:string('action_id', 128):nullable()
            table:integer('sort_order'):default(0)
            table:timestamps()

            table:unique({'menu_key', 'entry_key'})
            table:index({'menu_key', 'parent_entry_key'})
        end)

        print('[Migration] Created radial_menu_entries table')
    end,

    down = function()
        Schema.drop('radial_menu_entries')
        print('[Migration] Dropped radial_menu_entries table')
    end
}
```

- [ ] **Step 4: Verify migration file shape against a real example**

Run `cat /home/andi/Projects/obelisk-framework/core/plugins/oblsk_phone/server/migrations/2026_08_11_163802_create_phone_thread_members_table.lua` and confirm the `Schema.create(...)`/`table:unique({...})`/`up`/`down` shape above matches it exactly (same `Schema`/`Blueprint` API). If `table:string(name, len):primary()` isn't accepted by this repo's `Schema.lua` (some ORMs require `table:id()`-style primary keys only), fall back to `table:string('menu_key', 64)` plus `table:unique({'menu_key'})` and adjust `RadialMenuService` in Task 3 to use `:where('menu_key', ...)` lookups only (it already does).

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add server/migrations.json server/migrations/
git commit -m "Add radial_menus and radial_menu_entries migrations"
```

---

### Task 3: `RadialMenuService.registerMenu` / `addEntry` (idempotent seeding API)

**Files:**
- Create: `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua`
- Create: `core/plugins/oblsk_radialmenu/tests/support/fake_query_builder.lua`
- Test: `core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(tableName):where(col, val):firstSync()`, `:insert(row)`, `:update(row)` (framework ORM, stubbed in tests by the fake).
- Produces: `RadialMenuService.registerMenu(menuKey, label)`, `RadialMenuService.addEntry(menuKey, { entryKey, parentEntryKey, label, icon, actionId, sortOrder })` — both idempotent (safe to call every boot). Used by Task 6's seeder.

- [ ] **Step 1: Copy the fake QueryBuilder test double**

Copy `core/plugins/oblsk_phone/tests/support/fake_query_builder.lua` verbatim to `core/plugins/oblsk_radialmenu/tests/support/fake_query_builder.lua`:

```bash
mkdir -p /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu/tests/support
cp /home/andi/Projects/obelisk-framework/core/plugins/oblsk_phone/tests/support/fake_query_builder.lua \
   /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu/tests/support/fake_query_builder.lua
```

- [ ] **Step 2: Write the failing test**

Create `core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua`:

```lua
--- Unit tests for RadialMenuService: idempotent menu/entry registration,
--- tree assembly, and selection dispatch.
--- Run: lua5.4 tests/radial_menu_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(scriptDir .. '../server/services/RadialMenuService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('registerMenu: creates a row once, and is idempotent on repeat calls', function()
    withFakeDb(function(tables)
        RadialMenuService.registerMenu('default', 'Actions')
        RadialMenuService.registerMenu('default', 'Actions')

        eq(#tables.radial_menus, 1)
        eq(tables.radial_menus[1].menu_key, 'default')
        eq(tables.radial_menus[1].label, 'Actions')
    end)
end)

test('addEntry: creates a row once, and is idempotent on repeat calls with the same key', function()
    withFakeDb(function(tables)
        RadialMenuService.registerMenu('default', 'Actions')
        RadialMenuService.addEntry('default', { entryKey = 'vehicle', label = 'Vehicle', icon = 'car' })
        RadialMenuService.addEntry('default', { entryKey = 'vehicle', label = 'Vehicle', icon = 'car' })

        eq(#tables.radial_menu_entries, 1)
        eq(tables.radial_menu_entries[1].entry_key, 'vehicle')
        eq(tables.radial_menu_entries[1].parent_entry_key, nil)
    end)
end)

test('addEntry: stores parentEntryKey, actionId and sortOrder', function()
    withFakeDb(function(tables)
        RadialMenuService.registerMenu('default', 'Actions')
        RadialMenuService.addEntry('default', { entryKey = 'vehicle', label = 'Vehicle', icon = 'car' })
        RadialMenuService.addEntry('default', {
            entryKey = 'vehicle.engine', parentEntryKey = 'vehicle',
            label = 'Engine', icon = 'key', actionId = 'radialmenu:placeholder-action', sortOrder = 1
        })

        local row = tables.radial_menu_entries[2]
        eq(row.parent_entry_key, 'vehicle')
        eq(row.action_id, 'radialmenu:placeholder-action')
        eq(row.sort_order, 1)
    end)
end)

print('Running RadialMenuService unit tests\n')
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

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /home/andi/Projects/obelisk-framework
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua
```

Expected: fails immediately — `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua` doesn't exist yet.

- [ ] **Step 4: Write `RadialMenuService.registerMenu`/`addEntry`**

Create `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua`:

```lua
--- RadialMenuService - stores and serves named, tree-shaped radial menus.
--- Menus/entries are seeded idempotently by plugins (see RadialMenuSeedService)
--- and read at open-time via getTree. See
--- docs/superpowers/specs/2026-08-13-radial-menu-plugin-design.md (core repo).
RadialMenuService = {}

--- Idempotent: safe to call on every boot.
--- @param menuKey string
--- @param label string
function RadialMenuService.registerMenu(menuKey, label)
    local existing = QueryBuilder.new('radial_menus'):where('menu_key', menuKey):firstSync()
    if existing then
        return
    end

    QueryBuilder.new('radial_menus'):insert({
        menu_key = menuKey,
        label = label,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- Idempotent by (menuKey, entryKey): safe to call on every boot.
--- @param menuKey string
--- @param opts table { entryKey, parentEntryKey?, label, icon, actionId?, sortOrder? }
function RadialMenuService.addEntry(menuKey, opts)
    local existing = QueryBuilder.new('radial_menu_entries')
        :where('menu_key', menuKey):where('entry_key', opts.entryKey):firstSync()
    if existing then
        return
    end

    QueryBuilder.new('radial_menu_entries'):insert({
        menu_key = menuKey,
        entry_key = opts.entryKey,
        parent_entry_key = opts.parentEntryKey,
        label = opts.label,
        icon = opts.icon,
        action_id = opts.actionId,
        sort_order = opts.sortOrder or 0,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

return RadialMenuService
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua
```

Expected: `3 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add server/services/RadialMenuService.lua tests/radial_menu_service_spec.lua tests/support/fake_query_builder.lua
git commit -m "Add RadialMenuService.registerMenu/addEntry with idempotent seeding tests"
```

---

### Task 4: `RadialMenuService.getTree` (flat rows → nested tree)

**Files:**
- Modify: `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua`
- Test: `core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new('radial_menus'/'radial_menu_entries'):where(...):firstSync()/getSync()` (assume the fake/real QueryBuilder supports `:where(...):orderBy(col):getSync()` returning an array of matching rows — same shape used by `NotesService.list` in the phone plugin).
- Produces: `RadialMenuService.getTree(menuKey)` → `{ menuKey, label, items }` or `nil` if the menu doesn't exist, where each item is `{ entryKey, label, icon, actionId, items? }` (items present and non-empty only on branches), ordered by `sort_order`. Task 5 and Task 7 depend on this exact shape.

- [ ] **Step 1: Write the failing tests**

Append to `core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua` (before the `print('Running ...')` line):

```lua
test('getTree: returns nil for an unknown menu', function()
    withFakeDb(function()
        eq(RadialMenuService.getTree('nope'), nil)
    end)
end)

test('getTree: nests multi-level entries and orders by sort_order', function()
    withFakeDb(function()
        RadialMenuService.registerMenu('default', 'Actions')
        RadialMenuService.addEntry('default', { entryKey = 'emotes', label = 'Emotes', icon = 'users', sortOrder = 2 })
        RadialMenuService.addEntry('default', { entryKey = 'vehicle', label = 'Vehicle', icon = 'car', sortOrder = 1 })
        RadialMenuService.addEntry('default', {
            entryKey = 'vehicle.engine', parentEntryKey = 'vehicle',
            label = 'Engine', icon = 'key', actionId = 'radialmenu:placeholder-action', sortOrder = 1
        })
        RadialMenuService.addEntry('default', {
            entryKey = 'vehicle.doors', parentEntryKey = 'vehicle',
            label = 'Doors', icon = 'lock', actionId = 'radialmenu:placeholder-action', sortOrder = 2
        })

        local tree = RadialMenuService.getTree('default')
        truthy(tree)
        eq(tree.menuKey, 'default')
        eq(tree.label, 'Actions')
        eq(#tree.items, 2)
        eq(tree.items[1].entryKey, 'vehicle', 'lower sort_order should come first')
        eq(tree.items[2].entryKey, 'emotes')

        local vehicle = tree.items[1]
        eq(#vehicle.items, 2)
        eq(vehicle.items[1].entryKey, 'vehicle.engine')
        eq(vehicle.items[2].entryKey, 'vehicle.doors')
        eq(vehicle.items[1].actionId, 'radialmenu:placeholder-action')
        eq(vehicle.items[1].items, nil, 'a leaf must not have an items field')
    end)
end)
```

- [ ] **Step 2: Run to verify it fails**

```bash
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua
```

Expected: FAIL — `getTree` is nil.

- [ ] **Step 3: Implement `getTree`**

Add to `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua` (after `addEntry`, before `return RadialMenuService`):

```lua
--- @param menuKey string
--- @return table|nil { menuKey, label, items } nested by parent_entry_key, or nil if the menu doesn't exist
function RadialMenuService.getTree(menuKey)
    local menu = QueryBuilder.new('radial_menus'):where('menu_key', menuKey):firstSync()
    if not menu then
        return nil
    end

    local rows = QueryBuilder.new('radial_menu_entries')
        :where('menu_key', menuKey):orderBy('sort_order'):getSync()

    local byKey = {}
    for _, row in ipairs(rows) do
        byKey[row.entry_key] = {
            entryKey = row.entry_key,
            label = row.label,
            icon = row.icon,
            actionId = row.action_id,
        }
    end

    local roots = {}
    for _, row in ipairs(rows) do
        local node = byKey[row.entry_key]
        if row.parent_entry_key and byKey[row.parent_entry_key] then
            local parent = byKey[row.parent_entry_key]
            parent.items = parent.items or {}
            table.insert(parent.items, node)
        else
            table.insert(roots, node)
        end
    end

    return { menuKey = menu.menu_key, label = menu.label, items = roots }
end
```

- [ ] **Step 4: Run to verify it passes**

```bash
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua
```

Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Confirm the fake QueryBuilder supports `:orderBy(...):getSync()` returning an ordered array**

Run `grep -n "getSync\|orderBy" /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu/tests/support/fake_query_builder.lua`. If `getSync` isn't present on the fake (only `firstSync`), add it to the copied fake: it should return every row in the fake's table matching the accumulated `:where(...)` filters, sorted by whatever column `:orderBy(col)` recorded, as a plain array — mirror however `firstSync` already filters rows in that file, just returning all matches instead of the first.

- [ ] **Step 6: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add server/services/RadialMenuService.lua tests/radial_menu_service_spec.lua tests/support/fake_query_builder.lua
git commit -m "Add RadialMenuService.getTree with nesting/ordering tests"
```

---

### Task 5: `RadialMenuService.open` / `selectEntry` (dispatch)

**Files:**
- Modify: `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua`
- Test: `core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua`

**Interfaces:**
- Consumes: `Obelisk.emitClient(eventName, source, ...)` (global, stub it in the test — see Step 1), `ActionService.execute(source, actionId, data)` (global, stub it in the test).
- Produces: `RadialMenuService.open(source, menuKey)` → `true`/`false`, emits `'radialmenu:client:open'` to `source` with the tree on success. `RadialMenuService.selectEntry(source, menuKey, entryKey)` → `true`/`false`, calls `ActionService.execute(source, entry.action_id, {entryKey, label})` on a known leaf. Used by Task 7's `server/main.lua` wiring.

- [ ] **Step 1: Write the failing tests**

Append to `core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua` (before the final `print('Running ...')` line):

```lua
local function withStubs(fn)
    local emitted, executed = {}, {}
    _G.Obelisk = _G.Obelisk or {}
    local originalEmitClient = Obelisk.emitClient
    local originalExecute = _G.ActionService and ActionService.execute

    Obelisk.emitClient = function(eventName, source, data)
        table.insert(emitted, { eventName = eventName, source = source, data = data })
    end
    _G.ActionService = _G.ActionService or {}
    ActionService.execute = function(source, actionId, data)
        table.insert(executed, { source = source, actionId = actionId, data = data })
    end

    local ok, err = pcall(fn, emitted, executed)

    Obelisk.emitClient = originalEmitClient
    ActionService.execute = originalExecute
    if not ok then error(err, 2) end
end

test('open: emits the tree to the given source on a known menu', function()
    withFakeDb(function()
        withStubs(function(emitted)
            RadialMenuService.registerMenu('default', 'Actions')
            RadialMenuService.addEntry('default', { entryKey = 'vehicle', label = 'Vehicle', icon = 'car' })

            local ok = RadialMenuService.open(7, 'default')

            truthy(ok)
            eq(#emitted, 1)
            eq(emitted[1].eventName, 'radialmenu:client:open')
            eq(emitted[1].source, 7)
            eq(emitted[1].data.menuKey, 'default')
        end)
    end)
end)

test('open: returns false and emits nothing for an unknown menu', function()
    withFakeDb(function()
        withStubs(function(emitted)
            local ok = RadialMenuService.open(7, 'nope')
            eq(ok, false)
            eq(#emitted, 0)
        end)
    end)
end)

test('selectEntry: executes the entry action_id via ActionService', function()
    withFakeDb(function()
        withStubs(function(_, executed)
            RadialMenuService.registerMenu('default', 'Actions')
            RadialMenuService.addEntry('default', {
                entryKey = 'vehicle.engine', label = 'Engine', icon = 'key',
                actionId = 'radialmenu:placeholder-action'
            })

            local ok = RadialMenuService.selectEntry(7, 'default', 'vehicle.engine')

            truthy(ok)
            eq(#executed, 1)
            eq(executed[1].source, 7)
            eq(executed[1].actionId, 'radialmenu:placeholder-action')
            eq(executed[1].data.entryKey, 'vehicle.engine')
            eq(executed[1].data.label, 'Engine')
        end)
    end)
end)

test('selectEntry: returns false for an unknown entry and executes nothing', function()
    withFakeDb(function()
        withStubs(function(_, executed)
            local ok = RadialMenuService.selectEntry(7, 'default', 'nope')
            eq(ok, false)
            eq(#executed, 0)
        end)
    end)
end)
```

- [ ] **Step 2: Run to verify it fails**

```bash
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua
```

Expected: FAIL — `open`/`selectEntry` are nil.

- [ ] **Step 3: Implement `open` and `selectEntry`**

Add to `core/plugins/oblsk_radialmenu/server/services/RadialMenuService.lua` (after `getTree`, before `return RadialMenuService`):

```lua
--- @param source number
--- @param menuKey string
--- @return boolean
function RadialMenuService.open(source, menuKey)
    local tree = RadialMenuService.getTree(menuKey)
    if not tree then
        print('[RadialMenuService] open: unknown menu "' .. tostring(menuKey) .. '"')
        return false
    end

    Obelisk.emitClient('radialmenu:client:open', source, tree)
    return true
end

--- @param source number
--- @param menuKey string
--- @param entryKey string
--- @return boolean
function RadialMenuService.selectEntry(source, menuKey, entryKey)
    local entry = QueryBuilder.new('radial_menu_entries')
        :where('menu_key', menuKey):where('entry_key', entryKey):firstSync()
    if not entry or not entry.action_id then
        print('[RadialMenuService] selectEntry: unknown or non-leaf entry "' .. tostring(entryKey) .. '"')
        return false
    end

    ActionService.execute(source, entry.action_id, { entryKey = entry.entry_key, label = entry.label })
    return true
end
```

- [ ] **Step 4: Run to verify it passes**

```bash
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_service_spec.lua
```

Expected: `9 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add server/services/RadialMenuService.lua tests/radial_menu_service_spec.lua
git commit -m "Add RadialMenuService.open/selectEntry dispatch with stubbed-collaborator tests"
```

---

### Task 6: Default menu seed data (`RadialMenuSeedService`)

**Files:**
- Create: `core/plugins/oblsk_radialmenu/server/seeders/RadialMenuSeedService.lua`
- Test: `core/plugins/oblsk_radialmenu/tests/radial_menu_seed_service_spec.lua`

**Interfaces:**
- Consumes: `RadialMenuService.registerMenu`/`addEntry` (Task 3).
- Produces: `RadialMenuSeedService.ensureDefaultMenu()` — idempotent, seeds the `'default'` menu with the Vehicle/Emotes/Inventory/Comms/Self/Job tree, every leaf's `action_id` set to `'radialmenu:placeholder-action'` (registered in Task 7). Called once from `server/main.lua` in Task 7.

- [ ] **Step 1: Write the failing test**

Create `core/plugins/oblsk_radialmenu/tests/radial_menu_seed_service_spec.lua`:

```lua
--- Unit tests for RadialMenuSeedService: seeds the default menu, and is
--- idempotent (safe to run every boot without duplicating rows).
--- Run: lua5.4 tests/radial_menu_seed_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(scriptDir .. '../server/services/RadialMenuService.lua')
dofile(scriptDir .. '../server/seeders/RadialMenuSeedService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('ensureDefaultMenu: creates the default menu with 6 top-level wedges', function()
    withFakeDb(function(tables)
        RadialMenuSeedService.ensureDefaultMenu()

        eq(#tables.radial_menus, 1)
        eq(tables.radial_menus[1].menu_key, 'default')

        local tree = RadialMenuService.getTree('default')
        eq(#tree.items, 6)
    end)
end)

test('ensureDefaultMenu: every leaf has the placeholder action_id', function()
    withFakeDb(function()
        RadialMenuSeedService.ensureDefaultMenu()

        local tree = RadialMenuService.getTree('default')
        local function assertLeavesHaveAction(node)
            if node.items and #node.items > 0 then
                for _, child in ipairs(node.items) do
                    assertLeavesHaveAction(child)
                end
            else
                eq(node.actionId, 'radialmenu:placeholder-action', 'leaf ' .. node.entryKey .. ' must have an action_id')
            end
        end
        for _, top in ipairs(tree.items) do
            assertLeavesHaveAction(top)
        end
    end)
end)

test('ensureDefaultMenu: running twice does not duplicate rows', function()
    withFakeDb(function(tables)
        RadialMenuSeedService.ensureDefaultMenu()
        local countAfterFirst = #tables.radial_menu_entries

        RadialMenuSeedService.ensureDefaultMenu()

        eq(#tables.radial_menu_entries, countAfterFirst)
    end)
end)

print('Running RadialMenuSeedService unit tests\n')
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

- [ ] **Step 2: Run to verify it fails**

```bash
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_seed_service_spec.lua
```

Expected: fails — the seeder file doesn't exist.

- [ ] **Step 3: Implement `RadialMenuSeedService`**

Create `core/plugins/oblsk_radialmenu/server/seeders/RadialMenuSeedService.lua`:

```lua
--- RadialMenuSeedService - seeds the 'default' radial menu (Vehicle / Emotes
--- / Inventory / Comms / Self / Job) via RadialMenuService. Idempotent: safe
--- to call on every resource boot. Every leaf points at the shared
--- 'radialmenu:placeholder-action' (registered in server/main.lua) since no
--- real vehicle/inventory/emote systems are wired up by this plugin yet —
--- see docs/superpowers/specs/2026-08-13-radial-menu-plugin-design.md (core repo).
RadialMenuSeedService = {}

local PLACEHOLDER_ACTION = 'radialmenu:placeholder-action'

--- { parentKey|nil, entryKey, label, icon }. Order defines default sort_order.
local ENTRIES = {
    { nil, 'vehicle', 'Vehicle', 'car' },
    { 'vehicle', 'vehicle.engine', 'Engine', 'key' },
    { 'vehicle', 'vehicle.doors', 'Doors', 'lock' },
    { 'vehicle', 'vehicle.lights', 'Lights', 'zap' },
    { 'vehicle', 'vehicle.seat', 'Change seat', 'users' },

    { nil, 'emotes', 'Emotes', 'users' },
    { 'emotes', 'emotes.wave', 'Wave', 'users' },
    { 'emotes', 'emotes.point', 'Point', 'flag' },
    { 'emotes', 'emotes.sit', 'Sit down', 'user' },
    { 'emotes', 'emotes.cancel', 'Cancel emote', 'close' },

    { nil, 'inventory', 'Inventory', 'folder' },
    { 'inventory', 'inventory.open', 'Open bag', 'folder' },
    { 'inventory', 'inventory.give', 'Give item', 'send' },
    { 'inventory', 'inventory.drop', 'Drop item', 'trash' },
    { 'inventory', 'inventory.id', 'Show ID', 'user' },

    { nil, 'comms', 'Comms', 'radio' },
    { 'comms', 'comms.radio', 'Radio', 'radio' },
    { 'comms', 'comms.phone', 'Phone', 'phone' },
    { 'comms', 'comms.911', 'Call 911', 'phone' },

    { nil, 'self', 'Self', 'heart' },
    { 'self', 'self.hands', 'Hands up', 'users' },
    { 'self', 'self.pulse', 'Check pulse', 'heart' },
    { 'self', 'self.bandage', 'Bandage', 'plus' },

    { nil, 'job', 'Job', 'shield' },
    { 'job', 'job.duty', 'Toggle duty', 'shield' },
    { 'job', 'job.search', 'Search', 'search' },
    { 'job', 'job.fine', 'Write fine', 'file' },
}

--- Idempotent: safe to call on every boot.
function RadialMenuSeedService.ensureDefaultMenu()
    RadialMenuService.registerMenu('default', 'Actions')

    for sortOrder, entry in ipairs(ENTRIES) do
        local parentEntryKey, entryKey, label, icon = entry[1], entry[2], entry[3], entry[4]
        local isLeaf = parentEntryKey ~= nil -- every top-level entry here is a branch; every child is a leaf

        RadialMenuService.addEntry('default', {
            entryKey = entryKey,
            parentEntryKey = parentEntryKey,
            label = label,
            icon = icon,
            actionId = isLeaf and PLACEHOLDER_ACTION or nil,
            sortOrder = sortOrder,
        })
    end
end

return RadialMenuSeedService
```

- [ ] **Step 4: Run to verify it passes**

```bash
lua5.4 core/plugins/oblsk_radialmenu/tests/radial_menu_seed_service_spec.lua
```

Expected: `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add server/seeders/RadialMenuSeedService.lua tests/radial_menu_seed_service_spec.lua
git commit -m "Seed the default radial menu tree"
```

---

### Task 7: Server wiring (`server/main.lua`) — keybind, placeholder action, selection event

**Files:**
- Create: `core/plugins/oblsk_radialmenu/server/main.lua`

**Interfaces:**
- Consumes: `RadialMenuSeedService.ensureDefaultMenu()` (Task 6), `RadialMenuService.open`/`selectEntry` (Task 5), `ActionService.register`/`execute` (framework), `Obelisk.onServer` (framework), `NotificationService.notify` (framework, optional — guarded).
- Produces: the `'radialmenu:open-default'` action (default key `G`), the `'radialmenu:placeholder-action'` action, and the `'radialmenu:server:selected'` net event. Task 8's client relies on the client-side events this triggers (`radialmenu:client:open` via `RadialMenuService.open`).

- [ ] **Step 1: Write `server/main.lua`**

Create `core/plugins/oblsk_radialmenu/server/main.lua`:

```lua
--- oblsk_radialmenu server bootstrap: seeds the default menu, registers the
--- open keybind and the shared placeholder leaf action, and relays client
--- selections into RadialMenuService.selectEntry.
RadialMenuSeedService.ensureDefaultMenu()

--- Every seeded leaf points here for now — no real vehicle/inventory/emote
--- systems are wired up by this plugin (see design doc's non-goals). Once
--- those systems exist, their own plugins can call
--- RadialMenuService.addEntry with their own action_id to take over a wedge.
ActionService.register('radialmenu:placeholder-action', function(source, data)
    local label = data and data.label or 'Action'
    if NotificationService then
        NotificationService.notify(source, {
            type = 'info',
            title = 'Radial Menu',
            description = label .. ' selected',
        })
    end
    print('[RadialMenu] placeholder action executed: ' .. label)
end, { label = 'Radial menu placeholder action' })

ActionService.register('radialmenu:open-default', function(source, data)
    RadialMenuService.open(source, 'default')
end, { label = 'Open interaction wheel', default_key = 'G' })

--- Client -> server: a leaf was chosen in the UI.
Obelisk.onServer('radialmenu:server:selected', function(menuKey, entryKey)
    local source = source
    RadialMenuService.selectEntry(source, menuKey, entryKey)
end)
```

- [ ] **Step 2: Sanity-check the file loads without syntax errors**

```bash
lua5.4 -p core/plugins/oblsk_radialmenu/server/main.lua 2>&1 | head -5
```

`-p` isn't a real lua5.4 flag for parse-only; instead run:

```bash
luac5.4 -p core/plugins/oblsk_radialmenu/server/main.lua
```

Expected: no output (valid syntax). If `luac5.4` isn't installed, skip this check — the file will be exercised live in Task 11's in-game verification.

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add server/main.lua
git commit -m "Wire radial menu keybind, placeholder action, and selection relay"
```

---

### Task 8: Client relay (`client/main.lua`)

**Files:**
- Create: `core/plugins/oblsk_radialmenu/client/main.lua`

**Interfaces:**
- Consumes: `Obelisk.onClient` (server→client relay, framework), `WebView.showGlobalElement`/`hideGlobalElement`/`emit`/`on` (framework), `Obelisk.emitServer` (framework).
- Produces: pushes `{menuKey, tree}` into the Vue component via NUI event `'radialmenu:client:tree'`, and relays the Vue component's `'radialmenu:client:selected'`/`'radialmenu:client:closed'` NUI callbacks to the server/`WebView`. Task 10's Vue component listens for `'radialmenu:client:tree'` and emits the two NUI callbacks this consumes.

- [ ] **Step 1: Write `client/main.lua`**

Create `core/plugins/oblsk_radialmenu/client/main.lua`:

```lua
--- oblsk_radialmenu client relay: shows the global element and pushes the
--- tree payload when the server opens a menu; relays the Vue component's
--- selection/close callbacks back out.

Obelisk.onClient('radialmenu:client:open', function(tree)
    WebView.showGlobalElement('radialmenu')
    WebView.emit('radialmenu:client:tree', tree)
end)

--- NUI (Vue) -> here: a leaf was chosen. Relay straight to the server.
WebView.on('radialmenu:client:selected', function(data)
    WebView.emitServer('radialmenu:server:selected', data.menuKey, data.entryKey)
end)

--- NUI (Vue) -> here: the whole wheel closed (root ESC/centre-click, or a
--- leaf was chosen). Submenu back-steps stay client-side UI state and never
--- reach this handler.
WebView.on('radialmenu:client:closed', function()
    WebView.hideGlobalElement('radialmenu')
end)
```

- [ ] **Step 2: Sanity-check syntax**

```bash
luac5.4 -p core/plugins/oblsk_radialmenu/client/main.lua
```

Expected: no output. Skip if `luac5.4` isn't installed.

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add client/main.lua
git commit -m "Add client relay for open/selected/closed radial menu events"
```

---

### Task 9: `Icon.vue` — glyph dictionary for the seeded menu

**Files:**
- Create: `core/plugins/oblsk_radialmenu/web/Icon.vue`

**Interfaces:**
- Produces: `<Icon :name="..." :size="..." :sw="..." :fill="..." />`, same prop contract as `oblsk_phone/web/phone/Icon.vue`. Task 10's `RadialMenu.vue` renders every seeded icon name through this: `car, key, lock, zap, users, flag, user, close, folder, send, trash, radio, phone, heart, plus, shield, search, file, chevL, chevR`.

- [ ] **Step 1: Confirm the prop/shape contract against the precedent file**

```bash
cat /home/andi/Projects/obelisk-framework/core/plugins/oblsk_phone/web/phone/Icon.vue
```

Confirm the `defineProps({ name, size, sw, fill })` shape and the `ICONS[name] -> [{ tag, attrs }]` rendering approach (`<component :is="shape.tag" v-for="(shape, i) in shapes" :key="i" v-bind="shape.attrs" />`) — this task's file follows the same contract but with its own, smaller glyph dictionary (it does not import from `oblsk_phone`, which is a separate git repo).

- [ ] **Step 2: Write `web/Icon.vue`**

Create `core/plugins/oblsk_radialmenu/web/Icon.vue`:

```vue
<template>
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    :fill="fill ? 'currentColor' : 'none'"
    stroke="currentColor"
    :stroke-width="sw"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <component :is="shape.tag" v-for="(shape, i) in shapes" :key="i" v-bind="shape.attrs" />
  </svg>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  name: { type: String, required: true },
  size: { type: [Number, String], default: 16 },
  sw: { type: [Number, String], default: 1.6 },
  fill: { type: Boolean, default: false }
})

const ICONS = {
  car: [
    { tag: 'path', attrs: { d: 'M1 3h15v13H1z' } },
    { tag: 'path', attrs: { d: 'M16 8h4l3 3v5h-7V8z' } },
    { tag: 'circle', attrs: { cx: 5.5, cy: 18.5, r: 2.5 } },
    { tag: 'circle', attrs: { cx: 18.5, cy: 18.5, r: 2.5 } },
  ],
  key: [
    { tag: 'path', attrs: { d: 'M21 2l-2 2m-7.61 7.61a5.5 5.5 0 11-7.778 7.778 5.5 5.5 0 017.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4' } },
  ],
  lock: [
    { tag: 'rect', attrs: { x: 3, y: 11, width: 18, height: 11, rx: 2, ry: 2 } },
    { tag: 'path', attrs: { d: 'M7 11V7a5 5 0 0110 0v4' } },
  ],
  zap: [
    { tag: 'polygon', attrs: { points: '13 2 3 14 12 14 11 22 21 10 12 10 13 2' } },
  ],
  users: [
    { tag: 'path', attrs: { d: 'M17 21v-2a4 4 0 00-4-4H5a4 4 0 00-4 4v2' } },
    { tag: 'circle', attrs: { cx: 9, cy: 7, r: 4 } },
    { tag: 'path', attrs: { d: 'M23 21v-2a4 4 0 00-3-3.87' } },
    { tag: 'path', attrs: { d: 'M16 3.13a4 4 0 010 7.75' } },
  ],
  user: [
    { tag: 'path', attrs: { d: 'M20 21v-2a4 4 0 00-4-4H8a4 4 0 00-4 4v2' } },
    { tag: 'circle', attrs: { cx: 12, cy: 7, r: 4 } },
  ],
  flag: [
    { tag: 'path', attrs: { d: 'M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z' } },
    { tag: 'line', attrs: { x1: 4, y1: 22, x2: 4, y2: 15 } },
  ],
  close: [
    { tag: 'line', attrs: { x1: 18, y1: 6, x2: 6, y2: 18 } },
    { tag: 'line', attrs: { x1: 6, y1: 6, x2: 18, y2: 18 } },
  ],
  folder: [
    { tag: 'path', attrs: { d: 'M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z' } },
  ],
  send: [
    { tag: 'line', attrs: { x1: 22, y1: 2, x2: 11, y2: 13 } },
    { tag: 'polygon', attrs: { points: '22 2 15 22 11 13 2 9 22 2' } },
  ],
  trash: [
    { tag: 'polyline', attrs: { points: '3 6 5 6 21 6' } },
    { tag: 'path', attrs: { d: 'M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2' } },
  ],
  radio: [
    { tag: 'circle', attrs: { cx: 12, cy: 12, r: 2 } },
    { tag: 'path', attrs: { d: 'M16.24 7.76a6 6 0 010 8.49m-8.48-.01a6 6 0 010-8.49m11.31-2.82a10 10 0 010 14.14m-14.14 0a10 10 0 010-14.14' } },
  ],
  phone: [
    { tag: 'path', attrs: { d: 'M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.127.96.361 1.903.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.907.339 1.85.573 2.81.7A2 2 0 0122 16.92z' } },
  ],
  heart: [
    { tag: 'path', attrs: { d: 'M20.84 4.61a5.5 5.5 0 00-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 00-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 000-7.78z' } },
  ],
  plus: [
    { tag: 'line', attrs: { x1: 12, y1: 5, x2: 12, y2: 19 } },
    { tag: 'line', attrs: { x1: 5, y1: 12, x2: 19, y2: 12 } },
  ],
  shield: [
    { tag: 'path', attrs: { d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' } },
  ],
  search: [
    { tag: 'circle', attrs: { cx: 11, cy: 11, r: 8 } },
    { tag: 'line', attrs: { x1: 21, y1: 21, x2: 16.65, y2: 16.65 } },
  ],
  file: [
    { tag: 'path', attrs: { d: 'M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z' } },
    { tag: 'polyline', attrs: { points: '14 2 14 8 20 8' } },
  ],
  chevL: [
    { tag: 'polyline', attrs: { points: '15 18 9 12 15 6' } },
  ],
  chevR: [
    { tag: 'polyline', attrs: { points: '9 18 15 12 9 6' } },
  ],
}

const shapes = computed(() => ICONS[props.name] || ICONS.file)
</script>
```

- [ ] **Step 3: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add web/Icon.vue
git commit -m "Add radial menu icon glyph set"
```

---

### Task 10: `RadialMenu.vue` — the global component, ported from `src/proto/radial.jsx`

**Files:**
- Create: `core/plugins/oblsk_radialmenu/web/RadialMenu.vue`
- Create: `core/plugins/oblsk_radialmenu/web/globalElements.js`

**Interfaces:**
- Consumes: `Icon.vue` (Task 9), `Obelisk.on`/`off`/`emit` from `core/web/src/obelisk.js` (framework — path resolved in Step 1 below), the `{menuKey, label, items}` tree shape pushed via NUI event `'radialmenu:client:tree'` (Task 8/Task 4).
- Produces: registers as global element `'radialmenu'` (`defaultVisible: false`) via `web/globalElements.js`, consumed automatically by `core/web/src/App.vue`'s `import.meta.glob`. Emits NUI callbacks `'radialmenu:client:selected'` `{menuKey, entryKey}` and `'radialmenu:client:closed'` `{}`, both consumed by Task 8's `client/main.lua`.

- [ ] **Step 1: Resolve the exact relative import path for `Obelisk`**

```bash
grep -n "obelisk" /home/andi/Projects/obelisk-framework/core/plugins/oblsk_phone/web/Phone.vue | head -3
```

`oblsk_phone/web/Phone.vue` and `oblsk_radialmenu/web/RadialMenu.vue` are at the same directory depth relative to `core/`, so use the identical relative path string that grep shows (expected: `../../../web/src/obelisk.js`, i.e. `core/plugins/oblsk_radialmenu/web/` → up to `core/` → `web/src/obelisk.js`). Use that exact string in Step 3.

- [ ] **Step 2: Write `web/globalElements.js`**

Create `core/plugins/oblsk_radialmenu/web/globalElements.js`:

```js
import RadialMenu from './RadialMenu.vue'

export default [
  { name: 'radialmenu', component: RadialMenu, defaultVisible: false }
]
```

- [ ] **Step 3: Write `web/RadialMenu.vue`**

Create `core/plugins/oblsk_radialmenu/web/RadialMenu.vue`:

```vue
<template>
  <div v-if="tree" class="absolute inset-0 grid place-items-center" @pointermove="track">
    <div class="relative" :style="{ width: SIZE + 'px', height: SIZE + 'px' }">
      <svg ref="svgRef" :viewBox="`0 0 ${SIZE} ${SIZE}`" class="w-full h-full" style="filter: drop-shadow(0 25px 60px rgba(0,0,0,.7))">
        <circle :cx="C" :cy="C" :r="R1 + 6" fill="rgba(0,0,0,.45)" stroke="rgba(255,255,255,.06)" />
        <g v-for="(it, i) in items" :key="it.entryKey"
           @pointerenter="hover = i" @click="choose(i)" style="cursor:pointer">
          <path :d="wedgePath(C, C, R0, R1, angleStart(i), angleEnd(i))"
                :fill="hover === i ? 'color-mix(in oklab, var(--ob-accent) 30%, transparent)' : 'rgba(255,255,255,.055)'"
                :stroke="hover === i ? 'var(--ob-accent)' : 'rgba(255,255,255,.1)'"
                :stroke-width="hover === i ? 1.6 : 1"
                style="transition: fill .12s, stroke .12s" />
          <foreignObject :x="labelX(i) - 52" :y="labelY(i) - 34" width="104" height="68" style="pointer-events:none">
            <div class="w-full h-full flex flex-col items-center justify-center gap-1 text-center">
              <Icon :name="it.icon" :size="hover === i ? 22 : 19"
                    :style="{ color: hover === i ? 'var(--ob-accent)' : 'rgba(255,255,255,.65)', transition: 'all .12s' }" />
              <span v-if="labels" class="text-[11px] leading-tight px-1"
                    :style="{ color: hover === i ? '#fff' : 'rgba(255,255,255,.55)' }">{{ it.label }}</span>
              <span v-if="it.items && it.items.length" class="ob-mono text-[8px]"
                    :style="{ color: hover === i ? 'var(--ob-accent)' : 'rgba(255,255,255,.25)' }">{{ it.items.length }} ▸</span>
            </div>
          </foreignObject>
        </g>
        <circle :cx="C" :cy="C" :r="R0 - 8" fill="rgba(8,10,11,.92)" stroke="rgba(255,255,255,.12)"
                @click="back" style="cursor:pointer" />
      </svg>

      <div class="absolute inset-0 grid place-items-center pointer-events-none">
        <div class="text-center px-6" :style="{ width: (R0 * 2) + 'px' }">
          <template v-if="hover != null && items[hover]">
            <div class="text-[14px] font-semibold leading-tight">{{ items[hover].label }}</div>
            <div class="ob-mono text-[9px] text-white/35 mt-1">{{ items[hover].items && items[hover].items.length ? 'SUBMENU' : 'ACTION' }}</div>
          </template>
          <template v-else>
            <div class="ob-mono text-[9px] tracking-[0.2em] text-white/30 uppercase">{{ path.length ? 'Level ' + (path.length + 1) : 'Wheel' }}</div>
            <div class="text-[14px] font-semibold mt-1">{{ current.label }}</div>
            <div class="ob-mono text-[9px] text-white/25 mt-1">{{ path.length ? 'CENTRE · BACK' : 'ESC · CLOSE' }}</div>
          </template>
        </div>
      </div>

      <div class="absolute left-1/2 -translate-x-1/2 flex items-center gap-1.5" style="top: -46px">
        <button @click="path = []"
                class="px-2.5 h-7 rounded-lg text-[11.5px] transition"
                :class="path.length ? 'bg-white/6 text-white/55 hover:text-white' : 'text-black font-medium'"
                :style="!path.length ? { background: 'var(--ob-accent)' } : undefined">{{ tree.label }}</button>
        <template v-for="(idx, d) in path" :key="d">
          <Icon name="chevR" :size="12" class="text-white/25" />
          <button @click="path = path.slice(0, d + 1)"
                  class="px-2.5 h-7 rounded-lg text-[11.5px] transition"
                  :class="d === path.length - 1 ? 'text-black font-medium' : 'bg-white/6 text-white/55 hover:text-white'"
                  :style="d === path.length - 1 ? { background: 'var(--ob-accent)' } : undefined">{{ nodeAt(path.slice(0, d + 1)).label }}</button>
        </template>
      </div>

      <div class="absolute left-1/2 -translate-x-1/2 flex items-center gap-4" style="bottom: -52px">
        <div v-for="[k, l] in HINTS" :key="k" class="flex items-center gap-1.5">
          <span class="ob-mono inline-grid place-items-center h-[17px] rounded"
                style="min-width:17px;padding:0 5px;font-size:9px;background:rgba(255,255,255,.13);border:1px solid rgba(255,255,255,.2)">{{ k }}</span>
          <span class="text-[10px] text-white/45">{{ l }}</span>
        </div>
        <button @click="labels = !labels" class="ob-mono text-[9px] text-white/30 hover:text-white/70 ml-2">{{ labels ? 'ICONS ONLY' : 'SHOW LABELS' }}</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import Icon from './Icon.vue'
import Obelisk from '../../../web/src/obelisk.js'

const tree = ref(null)
const path = ref([])
const hover = ref(null)
const labels = ref(true)
const svgRef = ref(null)

const SIZE = 620
const C = SIZE / 2
const R0 = 96
const R1 = 210
const HINTS = [['MOVE', 'Highlight'], ['CLICK', 'Select'], ['CENTRE', 'Back'], ['ESC', 'Close']]

function nodeAt(p) {
  return p.reduce((n, i) => n.items[i], tree.value)
}

const current = computed(() => (tree.value ? nodeAt(path.value) : { label: '' }))
const items = computed(() => (current.value && current.value.items) || [])

function angleStart(i) {
  const step = (Math.PI * 2) / Math.max(items.value.length, 1)
  return -Math.PI / 2 + i * step + 0.012
}
function angleEnd(i) {
  const step = (Math.PI * 2) / Math.max(items.value.length, 1)
  return -Math.PI / 2 + (i + 1) * step - 0.012
}
function labelX(i) {
  const mid = (angleStart(i) + angleEnd(i)) / 2
  return C + ((R0 + R1) / 2) * Math.cos(mid)
}
function labelY(i) {
  const mid = (angleStart(i) + angleEnd(i)) / 2
  return C + ((R0 + R1) / 2) * Math.sin(mid)
}

function wedgePath(cx, cy, r0, r1, a0, a1) {
  const p = (r, a) => [cx + r * Math.cos(a), cy + r * Math.sin(a)]
  const [x0, y0] = p(r1, a0)
  const [x1, y1] = p(r1, a1)
  const [x2, y2] = p(r0, a1)
  const [x3, y3] = p(r0, a0)
  const large = a1 - a0 > Math.PI ? 1 : 0
  return `M${x0} ${y0} A${r1} ${r1} 0 ${large} 1 ${x1} ${y1} L${x2} ${y2} A${r0} ${r0} 0 ${large} 0 ${x3} ${y3} Z`
}

function track(e) {
  const el = svgRef.value
  if (!el || !items.value.length) return
  const b = el.getBoundingClientRect()
  const x = e.clientX - (b.left + b.width / 2)
  const y = e.clientY - (b.top + b.height / 2)
  const dist = Math.hypot(x, y) / (b.width / SIZE)
  if (dist < R0 * 0.9) { hover.value = null; return }
  let a = Math.atan2(y, x) + Math.PI / 2
  if (a < 0) a += Math.PI * 2
  hover.value = Math.floor((a / (Math.PI * 2)) * items.value.length) % items.value.length
}

function choose(i) {
  const item = items.value[i]
  if (!item) return
  if (item.items && item.items.length) {
    path.value = [...path.value, i]
    hover.value = null
  } else {
    Obelisk.emit('radialmenu:client:selected', { menuKey: tree.value.menuKey, entryKey: item.entryKey })
    close()
  }
}

function back() {
  if (path.value.length) path.value = path.value.slice(0, -1)
  else close()
}

function close() {
  Obelisk.emit('radialmenu:client:closed', {})
  tree.value = null
  path.value = []
  hover.value = null
}

function onTree(payload) {
  tree.value = payload
  path.value = []
  hover.value = null
}

function onKeydown(e) {
  if (!tree.value) return
  if (e.code === 'Escape') back()
}

onMounted(() => {
  Obelisk.on('radialmenu:client:tree', onTree)
  window.addEventListener('keydown', onKeydown)
})
onBeforeUnmount(() => {
  Obelisk.off('radialmenu:client:tree', onTree)
  window.removeEventListener('keydown', onKeydown)
})
</script>
```

- [ ] **Step 4: Commit**

```bash
cd /home/andi/Projects/obelisk-framework/core/plugins/oblsk_radialmenu
git add web/RadialMenu.vue web/globalElements.js
git commit -m "Port radial menu UI from the Claude Design prototype"
```

---

### Task 11: End-to-end verification

**Files:** none (verification only)

**Interfaces:** none — this task exercises everything from Tasks 1–10 together.

- [ ] **Step 1: Run every Lua spec in the plugin**

```bash
cd /home/andi/Projects/obelisk-framework
for f in core/plugins/oblsk_radialmenu/tests/*_spec.lua; do
  echo "== $f =="
  lua5.4 "$f" || exit 1
done
```

Expected: every spec prints `N passed, 0 failed` and the loop exits 0.

- [ ] **Step 2: Confirm registry + core-repo hygiene**

```bash
grep -n oblsk_radialmenu /home/andi/Projects/obelisk-framework/core/plugins/registry.json
cd /home/andi/Projects/obelisk-framework/core && git status --short
```

Expected: the grep finds the entry; `git status` in `core` shows nothing under `plugins/oblsk_radialmenu` (it's gitignored) and no unintended changes to `registry.json` staged for the `core` repo's own history.

- [ ] **Step 3: In-game manual verification checklist**

With the FiveM server running this framework and `oblsk_radialmenu` in `registry.json`:

- [ ] Press `G` in-game → the wheel opens centered on screen with 6 wedges (Vehicle/Emotes/Inventory/Comms/Self/Job), icons render (no broken/missing glyphs).
- [ ] Moving the mouse around the ring highlights the wedge under the cursor angle (hover state: accent border/fill, larger icon, label turns white).
- [ ] Clicking a branch wedge (e.g. Vehicle) drills into its submenu; the breadcrumb shows `Actions › Vehicle`; the centre hub shows "CENTRE · BACK".
- [ ] Clicking the centre hub while in a submenu goes back one level; clicking it at the root closes the wheel.
- [ ] Pressing `Esc` while in a submenu goes back one level; pressing it again at the root closes the wheel.
- [ ] Clicking a leaf wedge (e.g. Vehicle → Engine) closes the wheel and triggers a "Engine selected" notification (from the placeholder action) — confirms the full round trip: Vue → NUI → `client/main.lua` → server `radialmenu:server:selected` → `RadialMenuService.selectEntry` → `ActionService.execute`.
- [ ] Clicking "ICONS ONLY" / "SHOW LABELS" toggles labels without closing the wheel.
- [ ] Re-opening with `G` after a full close resets to the root level (no stale submenu path).

- [ ] **Step 4: Record results**

If every checklist item passes, note completion in the plan's tracking (or PR description, per `superpowers:finishing-a-development-branch`). If any item fails, treat it as a bug against the relevant task above (e.g. a hover/angle bug is a Task 10 fix, a missing notification is a Task 7 fix) rather than patching ad hoc — follow `superpowers:systematic-debugging` if the cause isn't immediately obvious.
