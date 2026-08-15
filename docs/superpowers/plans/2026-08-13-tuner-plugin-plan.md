# Tuner + Tuner Tablet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the `pages/tuner.html` (self-serve mod shop) and `pages/tuner-tablet.html` (staff work-order tablet) prototypes into a new `oblsk_tuner` plugin, wired to real vehicle mods, real payment, and real crew/permissions.

**Architecture:** One new plugin, `plugins/oblsk_tuner`, following the exact shape of `plugins/oblsk_shop` (services do all business logic and DB access, `server/main.lua` is thin event/Action wiring, `client/main.lua` is a pure NUI relay, one Vue page per screen). It extends `modules/oblsk_vehicles`' existing `VehicleTuningService` registry (client) rather than inventing a second mod-application path, and persists to the existing `vehicle_tunings` table so applied mods survive respawn through `VehicleService.spawn`'s existing read path.

**Tech Stack:** Lua 5.4 (FXServer runtime), the repo's own ORM (`QueryBuilder`/`Schema`/`Database`), Vue 3 SFCs, the repo's hand-rolled `test()/eq()` Lua spec runner (see any `*_spec.lua`).

**Spec:** `docs/superpowers/specs/2026-08-13-tuner-plugin-design.md`

## Global Constraints

- **Repo topology:** `core`'s `modules/*` and `plugins/*` are gitignored — every module and plugin (including `oblsk_vehicles` and the new `oblsk_tuner`) is its own separate git repository living on disk at `modules/<name>/` or `plugins/<name>/`, with its own GitHub remote (`git@github.com:Obelisk-Framework/<name>.git`), not tracked by `core`'s git history at all. This plan's commits land in **three separate repos**: `core` (the spec/plan docs only, already committed), `modules/oblsk_vehicles` (Tasks 2-3), and the new `plugins/oblsk_tuner` (Tasks 1, 4-13). Never run `git add`/`git commit` for a plugin/module file from inside `core`'s own repo — it silently no-ops (the path is gitignored) or, if force-added, corrupts `core`'s history with someone else's repo's files. Each task's dispatch states which repo its commit belongs to.
- **Worktree isolation applies only to `modules/oblsk_vehicles`** (an existing repo with history worth protecting). `plugins/oblsk_tuner` is built directly inside the main `core` checkout at `core/plugins/oblsk_tuner/` — not in a separate worktree — for two reasons: it is a brand-new repo with nothing yet to protect, and every one of its Lua spec files resolves `core`'s ORM (`ROOT .. '/core/server/ORM/...'`) and `tests/support/fake_query_builder.lua` via a relative path that only exists when `plugins/oblsk_tuner/` sits on disk next to `core/` and `tests/` — exactly where every other existing plugin (`oblsk_shop`, `oblsk_garage`, etc.) already lives. Isolating it in its own worktree would break every relative `dofile()` in Tasks 4-9's spec files.
- Plugin directory name: `oblsk_tuner` (lowercase-with-underscore, matching every existing plugin — **not** the PascalCase the `obelisk make-plugin` CLI generator produces; hand-author files to match `oblsk_shop`'s layout instead of running that generator).
- Never trust a client-sent price, stock count, or catalog id — every purchase/work-order function re-resolves against the DB, exactly like `ShopService.resolveLines`.
- All Lua spec files run standalone via `lua5.4 <path> `from the repo root (`/home/andi/Projects/obelisk-framework/core`) and must `os.exit(1)` on any failure — copy the harness boilerplate (`test`/`eq`/runner loop) from `plugins/oblsk_shop/tests/shop_service_purchase_spec.lua` verbatim.
- After creating the plugin directory, run `node cli/index.js registry:generate` (from `core/`) so `plugins/registry.json` picks it up — do not hand-edit `registry.json`.
- Money columns are `decimal(10,2)`; cash payments round with `math.floor(total + 0.5)` before touching the integer `items.amount` column, exactly like `ShopService.purchase`.

---

## File Structure

```
plugins/oblsk_tuner/
  fxmanifest.lua
  README.md
  shared/config.lua
  server/
    migrations.json
    migrations/*.lua                      (7 files, see Task 1)
    seeders/TunerPermissionSeeder.lua
    services/
      TunerCatalogService.lua             (Task 4)
      TunerService.lua                    (Task 5 — mod purchase)
      TunerWearService.lua                (Task 6)
      TunerWorkOrderService.lua           (Task 7 — raise/assign/complete/settle)
      TunerCrewService.lua                (Task 8 — roster + busy check)
    main.lua                              (Task 9)
  client/
    main.lua                              (Task 10)
  web/
    routes.js
    Tuner.vue                             (Task 11)
    TunerTablet.vue                       (Task 13)
    tuner/
      TnGlyph.vue                         (Task 12)
      TnWheel.vue                         (Task 12)
      TtServiceRow.vue                    (Task 12)
  tests/
    tuner_catalog_service_spec.lua        (Task 4)
    tuner_service_purchase_spec.lua       (Task 5)
    tuner_wear_service_spec.lua           (Task 6)
    tuner_work_order_service_spec.lua     (Task 7)
    tuner_crew_service_spec.lua           (Task 8)

modules/oblsk_vehicles/
  client/services/VehicleTuningService.lua  (modified, Task 2)
  tests/vehicle_tuning_spec.lua             (modified, Task 2)
  server/services/VehicleService.lua        (modified, Task 3)
  tests/vehicle_service_find_by_net_id_spec.lua (new, Task 3)
```

---

### Task 1: Plugin scaffold, migrations, permission seeder

**Files:**
- Create: `core/plugins/oblsk_tuner/fxmanifest.lua`
- Create: `core/plugins/oblsk_tuner/README.md`
- Create: `core/plugins/oblsk_tuner/shared/config.lua`
- Create: `core/plugins/oblsk_tuner/server/migrations.json`
- Create: `core/plugins/oblsk_tuner/server/migrations/2026_08_13_150000_create_tuner_shops_table.lua`
- Create: `core/plugins/oblsk_tuner/server/migrations/2026_08_13_150001_create_tuner_catalog_items_table.lua`
- Create: `core/plugins/oblsk_tuner/server/migrations/2026_08_13_150002_create_tuner_service_parts_table.lua`
- Create: `core/plugins/oblsk_tuner/server/migrations/2026_08_13_150003_create_tuner_service_items_table.lua`
- Create: `core/plugins/oblsk_tuner/server/migrations/2026_08_13_150004_create_vehicle_component_wear_table.lua`
- Create: `core/plugins/oblsk_tuner/server/migrations/2026_08_13_150005_create_tuner_work_orders_table.lua`
- Create: `core/plugins/oblsk_tuner/server/migrations/2026_08_13_150006_create_tuner_work_order_lines_table.lua`
- Create: `core/plugins/oblsk_tuner/server/seeders/TunerPermissionSeeder.lua`

**Interfaces:**
- Produces: seven tables described in the spec's Data Model section, and the doc-only `TunerPermissionSeeder.PERMISSION_KEYS = { 'tuner.crew', 'tuner.invoice' }` that every later task's permission checks reference by string literal.

- [ ] **Step 1: fxmanifest.lua**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Tuner'
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
    'web/tuner/*.vue',
    'web/routes.js',
}
```

- [ ] **Step 2: shared/config.lua**

```lua
Config = {}

Config.Debug = false

return Config
```

- [ ] **Step 3: the seven migrations**

`2026_08_13_150000_create_tuner_shops_table.lua`:

```lua
--- Migration: Create tuner_shops table
return {
    up = function()
        Schema.create('tuner_shops', function(table)
            table:id()
            table:string('name', 100)
            table:foreignId('interaction_id'):constrained('interactions'):onDelete('CASCADE')
            table:foreignId('tablet_interaction_id'):nullable():constrained('interactions'):onDelete('SET NULL')
            table:foreignId('organization_id'):nullable():constrained('organizations'):onDelete('SET NULL')
            table:timestamps()
        end)

        print('[Migration] Created tuner_shops table')
    end,

    down = function()
        Schema.drop('tuner_shops')
        print('[Migration] Dropped tuner_shops table')
    end
}
```

`2026_08_13_150001_create_tuner_catalog_items_table.lua`:

```lua
--- Migration: Create tuner_catalog_items table
return {
    up = function()
        Schema.create('tuner_catalog_items', function(table)
            table:id()
            table:foreignId('tuner_shop_id'):constrained('tuner_shops'):onDelete('CASCADE')
            table:string('category', 32)
            table:string('label', 100)
            table:integer('native_index'):nullable()
            table:string('preview_hex', 9):nullable()
            table:decimal('price', 10, 2)
            table:boolean('active'):default(true)
            table:timestamps()
        end)

        print('[Migration] Created tuner_catalog_items table')
    end,

    down = function()
        Schema.drop('tuner_catalog_items')
        print('[Migration] Dropped tuner_catalog_items table')
    end
}
```

`2026_08_13_150002_create_tuner_service_parts_table.lua`:

```lua
--- Migration: Create tuner_service_parts table
return {
    up = function()
        Schema.create('tuner_service_parts', function(table)
            table:id()
            table:foreignId('tuner_shop_id'):constrained('tuner_shops'):onDelete('CASCADE')
            table:string('key', 32)
            table:string('label', 100)
            table:decimal('price', 10, 2)
            table:integer('qty'):default(0)
            table:timestamps()

            table:unique({'tuner_shop_id', 'key'})
        end)

        print('[Migration] Created tuner_service_parts table')
    end,

    down = function()
        Schema.drop('tuner_service_parts')
        print('[Migration] Dropped tuner_service_parts table')
    end
}
```

`2026_08_13_150003_create_tuner_service_items_table.lua`:

```lua
--- Migration: Create tuner_service_items table
return {
    up = function()
        Schema.create('tuner_service_items', function(table)
            table:id()
            table:foreignId('tuner_shop_id'):constrained('tuner_shops'):onDelete('CASCADE')
            table:string('key', 32)
            table:string('label', 100)
            table:string('part_key', 32)
            table:decimal('labour_price', 10, 2)
            table:timestamps()

            table:unique({'tuner_shop_id', 'key'})
        end)

        print('[Migration] Created tuner_service_items table')
    end,

    down = function()
        Schema.drop('tuner_service_items')
        print('[Migration] Dropped tuner_service_items table')
    end
}
```

`2026_08_13_150004_create_vehicle_component_wear_table.lua`:

```lua
--- Migration: Create vehicle_component_wear table
return {
    up = function()
        Schema.create('vehicle_component_wear', function(table)
            table:id()
            table:integer('vehicle_id')
            table:string('key', 32)
            table:integer('value')
            table:timestamps()

            table:unique({'vehicle_id', 'key'})
            table:foreign('vehicle_id'):references('id'):on('vehicles'):onDelete('CASCADE')
        end)

        print('[Migration] Created vehicle_component_wear table')
    end,

    down = function()
        Schema.drop('vehicle_component_wear')
        print('[Migration] Dropped vehicle_component_wear table')
    end
}
```

`2026_08_13_150005_create_tuner_work_orders_table.lua`:

```lua
--- Migration: Create tuner_work_orders table
return {
    up = function()
        Schema.create('tuner_work_orders', function(table)
            table:id()
            table:foreignId('tuner_shop_id'):constrained('tuner_shops'):onDelete('CASCADE')
            table:integer('vehicle_id')
            table:string('status', 16):default('open')
            table:integer('crew_character_id'):nullable()
            table:decimal('total', 10, 2):default(0)
            table:timestamps()

            table:foreign('vehicle_id'):references('id'):on('vehicles'):onDelete('CASCADE')
        end)

        print('[Migration] Created tuner_work_orders table')
    end,

    down = function()
        Schema.drop('tuner_work_orders')
        print('[Migration] Dropped tuner_work_orders table')
    end
}
```

`2026_08_13_150006_create_tuner_work_order_lines_table.lua`:

```lua
--- Migration: Create tuner_work_order_lines table
return {
    up = function()
        Schema.create('tuner_work_order_lines', function(table)
            table:id()
            table:foreignId('work_order_id'):constrained('tuner_work_orders'):onDelete('CASCADE')
            table:string('kind', 16)
            table:string('ref_key', 32)
            table:string('label', 100)
            table:decimal('price', 10, 2)
            table:string('stock_part_key', 32):nullable()
            table:timestamps()
        end)

        print('[Migration] Created tuner_work_order_lines table')
    end,

    down = function()
        Schema.drop('tuner_work_order_lines')
        print('[Migration] Dropped tuner_work_order_lines table')
    end
}
```

- [ ] **Step 4: migrations.json**

```json
{
  "migrations": [
    "2026_08_13_150000_create_tuner_shops_table",
    "2026_08_13_150001_create_tuner_catalog_items_table",
    "2026_08_13_150002_create_tuner_service_parts_table",
    "2026_08_13_150003_create_tuner_service_items_table",
    "2026_08_13_150004_create_vehicle_component_wear_table",
    "2026_08_13_150005_create_tuner_work_orders_table",
    "2026_08_13_150006_create_tuner_work_order_lines_table"
  ]
}
```

- [ ] **Step 5: run the migration audit against the new files**

Run: `lua5.4 tests/migration_audit_spec.lua` from `core/` — this only audits `core/server/database/migrations`, so it will **not** see the new plugin migrations; instead sanity-check each new file loads and its `up()` doesn't error by running the same harness pattern inline:

```bash
lua5.4 -e "
dofile('tests/support/fivem_stubs.lua')
dofile('core/server/ORM/Dialects/Init.lua')
dofile('core/server/ORM/Dialects/MySQL.lua')
dofile('core/server/ORM/Dialects/Postgres.lua')
dofile('core/server/ORM/Database.lua')
dofile('core/server/ORM/QueryBuilder.lua')
dofile('core/server/ORM/Schema.lua')
local files = {
  'plugins/oblsk_tuner/server/migrations/2026_08_13_150000_create_tuner_shops_table.lua',
  'plugins/oblsk_tuner/server/migrations/2026_08_13_150001_create_tuner_catalog_items_table.lua',
  'plugins/oblsk_tuner/server/migrations/2026_08_13_150002_create_tuner_service_parts_table.lua',
  'plugins/oblsk_tuner/server/migrations/2026_08_13_150003_create_tuner_service_items_table.lua',
  'plugins/oblsk_tuner/server/migrations/2026_08_13_150004_create_vehicle_component_wear_table.lua',
  'plugins/oblsk_tuner/server/migrations/2026_08_13_150005_create_tuner_work_orders_table.lua',
  'plugins/oblsk_tuner/server/migrations/2026_08_13_150006_create_tuner_work_order_lines_table.lua',
}
for _, f in ipairs(files) do
  local m = dofile(f)
  local ok, err = pcall(m.up)
  print(f, ok and 'OK' or ('FAIL: ' .. tostring(err)))
end
"
```

Expected: every line prints `OK`.

- [ ] **Step 6: TunerPermissionSeeder.lua**

```lua
--- TunerPermissionSeeder - documents the permission keys oblsk_tuner checks
--- via PermissionService.can. No auto-grant: admins grant these explicitly
--- (e.g. to a shop's linked organization rank/department) the same way
--- oblsk_garage's GaragePermissionSeeder documents garage_create/garage_edit.
TunerPermissionSeeder = {}
TunerPermissionSeeder.PERMISSION_KEYS = { 'tuner.crew', 'tuner.invoice' }

function TunerPermissionSeeder.ensure()
    print('[Tuner] permission keys available: ' .. table.concat(TunerPermissionSeeder.PERMISSION_KEYS, ', '))
end

return TunerPermissionSeeder
```

- [ ] **Step 7: README.md**

```markdown
# oblsk_tuner

Self-serve mod shop (`Tuner`) and staff work-order tablet (`Tuner Tablet`) for the Obelisk framework. Loads as part of `core`; restart `core` (or the whole server) to pick up changes.

## Setup

1. Insert an `interactions` row for the shop's customer bay and optionally one for the staff tablet pickup point.
2. Insert a `tuner_shops` row referencing those interaction ids (and an `organization_id` if the shop has assignable crew).
3. Populate `tuner_catalog_items` (customer-facing mods, one row per `SetVehicleMod` slot or paint option — see `docs/superpowers/specs/2026-08-13-tuner-plugin-design.md` for the native mapping table), `tuner_service_parts` (the parts bin) and `tuner_service_items` (the wear-service catalogue, `part_key` must match a `tuner_service_parts.key` for the same shop).
4. Grant `tuner.crew` / `tuner.invoice` to the shop's staff — via a character grant or, if `organization_id` is set, to that org's rank/department (see `PermissionService.grant`).

See [Tuner plugin design](../../docs/superpowers/specs/2026-08-13-tuner-plugin-design.md) for the full architecture.
```

- [ ] **Step 8: init the plugin's own repo, commit, regenerate the registry**

`plugins/oblsk_tuner` is its own git repository (see Global Constraints — every plugin is), not part of `core`'s history. Initialize and commit inside it, then regenerate `core`'s gitignored `plugins/registry.json` (a local build artifact, not committed — matches every other plugin, whose entries also only exist in the gitignored file) from `core`'s own checkout:

```bash
# inside plugins/oblsk_tuner/ (its own repo — git init has NOT been run yet)
git init
git add -A
git commit -m "feat(tuner): scaffold oblsk_tuner plugin, migrations, permission seeder"

# from core/ (the framework's own repo) — regenerates the gitignored registry.json
# so core picks up the new plugin at boot; this file is never committed
node cli/index.js registry:generate
```

Do not push `plugins/oblsk_tuner` to a remote — no GitHub repo has been created for it, and creating one is a separate, explicit step for later, not part of this task.

---

### Task 2: Fix + extend `VehicleTuningService` (client, `oblsk_vehicles`)

**Files:**
- Modify: `core/modules/oblsk_vehicles/client/services/VehicleTuningService.lua`
- Modify: `core/modules/oblsk_vehicles/tests/vehicle_tuning_spec.lua`

**Interfaces:**
- Produces: `VehicleTuningService.registry` entries for every category in the spec's native mapping table — `TunerService`/`TunerWorkOrderService` (Task 5, Task 7) write `vehicle_tunings` rows keyed by these exact strings, and the client's live-apply broadcast (Task 9/10) calls `VehicleTuningService.apply(entity, category, value)` with these exact value shapes:
  - `primaryColor`/`secondaryColor`: `{ r, g, b }`
  - `pearlescent`: `{ pearlescentId, wheelId }`
  - `spoiler`/`bumperF`/`bumperR`/`skirt`/`exhaust`/`hood`/`roof`/`engine`/`brakes`/`suspension`/`horn`: plain `number` (mod index)
  - `wheels`: `{ wheelType, index }`
  - `window`: plain `number` (tint index)
  - `turbo`: plain `boolean`
  - `neon`: `{ r, g, b }`
  - `livery`: plain `number` (livery index)

- [ ] **Step 1: write the failing tests** — append to `vehicle_tuning_spec.lua` (before the runner section):

```lua
test('built-in spoiler: now uses mod type 0, not 3', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end

    VehicleTuningService.apply(42, 'spoiler', 5)

    eq(captured[2], 0, 'spoiler must use GTA mod type 0')
    eq(captured[3], 5)
end)

test('built-in secondaryColor: calls SetVehicleCustomSecondaryColour with r/g/b', function()
    local captured
    _G.SetVehicleCustomSecondaryColour = function(entity, r, g, b) captured = {entity, r, g, b} end

    VehicleTuningService.apply(42, 'secondaryColor', { r = 10, g = 20, b = 30 })

    eq(captured[1], 42)
    eq(captured[2], 10)
    eq(captured[3], 20)
    eq(captured[4], 30)
end)

test('built-in pearlescent: calls SetVehicleExtraColours with pearlescentId/wheelId', function()
    local captured
    _G.SetVehicleExtraColours = function(entity, pearlescentId, wheelId) captured = {entity, pearlescentId, wheelId} end

    VehicleTuningService.apply(42, 'pearlescent', { pearlescentId = 12, wheelId = 156 })

    eq(captured[2], 12)
    eq(captured[3], 156)
end)

test('built-in bumperF: calls SetVehicleMod with mod type 1', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'bumperF', 2)
    eq(captured[2], 1)
    eq(captured[3], 2)
end)

test('built-in bumperR: calls SetVehicleMod with mod type 2', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'bumperR', 1)
    eq(captured[2], 2)
end)

test('built-in skirt: calls SetVehicleMod with mod type 3', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'skirt', 1)
    eq(captured[2], 3)
end)

test('built-in exhaust: calls SetVehicleMod with mod type 4', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'exhaust', 1)
    eq(captured[2], 4)
end)

test('built-in hood: calls SetVehicleMod with mod type 7', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'hood', 1)
    eq(captured[2], 7)
end)

test('built-in roof: calls SetVehicleMod with mod type 10', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'roof', 1)
    eq(captured[2], 10)
end)

test('built-in engine: calls SetVehicleMod with mod type 11', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'engine', 3)
    eq(captured[2], 11)
end)

test('built-in brakes: calls SetVehicleMod with mod type 12', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'brakes', 1)
    eq(captured[2], 12)
end)

test('built-in suspension: calls SetVehicleMod with mod type 15', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'suspension', 1)
    eq(captured[2], 15)
end)

test('built-in horn: calls SetVehicleMod with mod type 14', function()
    local captured
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) captured = {entity, modType, modIndex, customTires} end
    VehicleTuningService.apply(42, 'horn', 4)
    eq(captured[2], 14)
end)

test('built-in wheels: calls SetVehicleWheelType then SetVehicleMod with mod type 23', function()
    local wheelTypeCaptured, modCaptured
    _G.SetVehicleWheelType = function(entity, wheelType) wheelTypeCaptured = {entity, wheelType} end
    _G.SetVehicleMod = function(entity, modType, modIndex, customTires) modCaptured = {entity, modType, modIndex, customTires} end

    VehicleTuningService.apply(42, 'wheels', { wheelType = 6, index = 9 })

    eq(wheelTypeCaptured[2], 6)
    eq(modCaptured[2], 23)
    eq(modCaptured[3], 9)
end)

test('built-in window: calls SetVehicleWindowTint with the index', function()
    local captured
    _G.SetVehicleWindowTint = function(entity, index) captured = {entity, index} end
    VehicleTuningService.apply(42, 'window', 3)
    eq(captured[2], 3)
end)

test('built-in neon: colours all four corners and enables them', function()
    local colourCaptured
    local enabledCalls = {}
    _G.SetVehicleNeonLightsColour = function(entity, r, g, b) colourCaptured = {entity, r, g, b} end
    _G.SetVehicleNeonLightEnabled = function(entity, i, on) enabledCalls[#enabledCalls + 1] = {entity, i, on} end

    VehicleTuningService.apply(42, 'neon', { r = 1, g = 2, b = 3 })

    eq(colourCaptured[2], 1)
    eq(colourCaptured[3], 2)
    eq(colourCaptured[4], 3)
    eq(#enabledCalls, 4)
    eq(enabledCalls[1][3], true)
end)

test('built-in livery: calls SetVehicleLivery with the index', function()
    local captured
    _G.SetVehicleLivery = function(entity, index) captured = {entity, index} end
    VehicleTuningService.apply(42, 'livery', 2)
    eq(captured[2], 2)
end)
```

- [ ] **Step 2: run to verify the new tests fail**

Run: `lua5.4 modules/oblsk_vehicles/tests/vehicle_tuning_spec.lua` from `core/`
Expected: the spoiler test fails on the mod-type assertion (`expected 0, actual 3`), and every new-category test fails with "no handler registered" warnings not erroring (registry lookup returns nil, `apply` becomes a no-op, so `captured` stays nil and the `eq` on `captured[2]` errors with "attempt to index a nil value").

- [ ] **Step 3: implement** — replace the `spoiler` registration and add the rest, in `VehicleTuningService.lua` after the existing `turbo` registration:

```lua
VehicleTuningService.register('spoiler', {
    apply = function(entity, value)
        SetVehicleMod(entity, 0, value, false)
    end
})

VehicleTuningService.register('secondaryColor', {
    apply = function(entity, value)
        SetVehicleCustomSecondaryColour(entity, value.r, value.g, value.b)
    end
})

VehicleTuningService.register('pearlescent', {
    apply = function(entity, value)
        SetVehicleExtraColours(entity, value.pearlescentId, value.wheelId)
    end
})

VehicleTuningService.register('bumperF', {
    apply = function(entity, value) SetVehicleMod(entity, 1, value, false) end
})

VehicleTuningService.register('bumperR', {
    apply = function(entity, value) SetVehicleMod(entity, 2, value, false) end
})

VehicleTuningService.register('skirt', {
    apply = function(entity, value) SetVehicleMod(entity, 3, value, false) end
})

VehicleTuningService.register('exhaust', {
    apply = function(entity, value) SetVehicleMod(entity, 4, value, false) end
})

VehicleTuningService.register('hood', {
    apply = function(entity, value) SetVehicleMod(entity, 7, value, false) end
})

VehicleTuningService.register('roof', {
    apply = function(entity, value) SetVehicleMod(entity, 10, value, false) end
})

VehicleTuningService.register('engine', {
    apply = function(entity, value) SetVehicleMod(entity, 11, value, false) end
})

VehicleTuningService.register('brakes', {
    apply = function(entity, value) SetVehicleMod(entity, 12, value, false) end
})

VehicleTuningService.register('suspension', {
    apply = function(entity, value) SetVehicleMod(entity, 15, value, false) end
})

VehicleTuningService.register('horn', {
    apply = function(entity, value) SetVehicleMod(entity, 14, value, false) end
})

VehicleTuningService.register('wheels', {
    apply = function(entity, value)
        SetVehicleWheelType(entity, value.wheelType)
        SetVehicleMod(entity, 23, value.index, false)
    end
})

VehicleTuningService.register('window', {
    apply = function(entity, value)
        SetVehicleWindowTint(entity, value)
    end
})

VehicleTuningService.register('neon', {
    apply = function(entity, value)
        SetVehicleNeonLightsColour(entity, value.r, value.g, value.b)
        for i = 0, 3 do
            SetVehicleNeonLightEnabled(entity, i, true)
        end
    end
})

VehicleTuningService.register('livery', {
    apply = function(entity, value)
        SetVehicleLivery(entity, value)
    end
})
```

- [ ] **Step 4: run to verify the tests pass**

Run: `lua5.4 modules/oblsk_vehicles/tests/vehicle_tuning_spec.lua` from `core/`
Expected: all tests, including the pre-existing three, `PASS` / `0 failed`.

- [ ] **Step 5: in-game verification (manual, not automated)**

After Task 9/10 land and a test `tuner_shops` row exists, spawn a vehicle, apply one item from each category through the shop UI, and confirm in-game the correct part changes (not a neighboring slot). Note any vehicle-model quirks (e.g. no front bumper slot on some cars) in this plan's PR description — `SetVehicleMod` on a slot the model doesn't have is a documented no-op, so no code change is expected, just a note.

- [ ] **Step 6: commit**

```bash
git add client/services/VehicleTuningService.lua tests/vehicle_tuning_spec.lua
git commit -m "fix(vehicles): correct spoiler mod type, add full tuner native registry"
```

---

### Task 3: `VehicleService.findVehicleIdByNetId` (server, `oblsk_vehicles`)

**Files:**
- Modify: `core/modules/oblsk_vehicles/server/services/VehicleService.lua`
- Create: `core/modules/oblsk_vehicles/tests/vehicle_service_find_by_net_id_spec.lua`

**Interfaces:**
- Consumes: `VehicleService.activeNetIds` (existing table, `vehicleId -> netId`)
- Produces: `VehicleService.findVehicleIdByNetId(netId) -> vehicleId|nil` — Task 9's `tuner:open` action handler uses this to turn the client-reported "nearest vehicle" net id into a `vehicles.id` row for `TunerService`/`TunerWorkOrderService`.

- [ ] **Step 1: write the failing test**

```lua
-- modules/oblsk_vehicles/tests/vehicle_service_find_by_net_id_spec.lua
-- Run from the repository root: lua5.4 modules/oblsk_vehicles/tests/vehicle_service_find_by_net_id_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'

QueryBuilder = { new = function() error('not used by this test') end }
dofile(scriptDir .. '../server/services/VehicleService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('findVehicleIdByNetId: finds the vehicleId for a known netId', function()
    VehicleService.activeNetIds = { [7] = 501, [8] = 502 }
    eq(VehicleService.findVehicleIdByNetId(502), 8)
end)

test('findVehicleIdByNetId: returns nil for an unknown netId', function()
    VehicleService.activeNetIds = { [7] = 501 }
    eq(VehicleService.findVehicleIdByNetId(999), nil)
end)

print('Running VehicleService.findVehicleIdByNetId tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  ok   - ' .. t.name)
    else failures[#failures + 1] = t.name; print('  FAIL - ' .. t.name .. '\n         ' .. tostring(err)) end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
```

- [ ] **Step 2: run to verify it fails**

Run: `lua5.4 modules/oblsk_vehicles/tests/vehicle_service_find_by_net_id_spec.lua` from `core/`
Expected: FAIL — `attempt to call a nil value (field 'findVehicleIdByNetId')`

- [ ] **Step 3: implement** — add to `VehicleService.lua`, just above `return VehicleService`:

```lua
--- Reverse lookup of activeNetIds — small map (one entry per currently
--- spawned Obelisk vehicle), a linear scan is fine.
--- @param netId number
--- @return number|nil vehicleId
function VehicleService.findVehicleIdByNetId(netId)
    for vehicleId, id in pairs(VehicleService.activeNetIds) do
        if id == netId then return vehicleId end
    end
    return nil
end
```

- [ ] **Step 4: run to verify it passes**

Run: `lua5.4 modules/oblsk_vehicles/tests/vehicle_service_find_by_net_id_spec.lua` from `core/`
Expected: `2 passed, 0 failed`

- [ ] **Step 5: commit**

```bash
git add server/services/VehicleService.lua tests/vehicle_service_find_by_net_id_spec.lua
git commit -m "feat(vehicles): add VehicleService.findVehicleIdByNetId reverse lookup"
```

---

### Task 4: `TunerCatalogService` (server, read-only listing)

**Files:**
- Create: `core/plugins/oblsk_tuner/server/services/TunerCatalogService.lua`
- Create: `core/plugins/oblsk_tuner/tests/tuner_catalog_service_spec.lua`

**Interfaces:**
- Consumes: `QueryBuilder.new(table):where(col, val):getSync()` (existing ORM API, see any service in this repo)
- Produces:
  - `TunerCatalogService.listCatalog(shopId) -> table[]` — rows `{ id, category, label, native_index, preview_hex, price }`, active only
  - `TunerCatalogService.listServiceParts(shopId) -> table[]` — rows `{ id, key, label, price, qty }`
  - `TunerCatalogService.listServiceItems(shopId) -> table[]` — rows `{ id, key, label, part_key, labour_price }`
  These three feed Task 9's `tuner:open`/`tunertablet:open` sync payloads and Task 11/13's Vue pages.

- [ ] **Step 1: write the failing test**

```lua
-- plugins/oblsk_tuner/tests/tuner_catalog_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_tuner/tests/tuner_catalog_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'
local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

QueryBuilder = makeFakeQueryBuilderModule({
    tuner_catalog_items = {
        [1] = { id = 1, tuner_shop_id = 10, category = 'wheels', label = 'Adder LX', native_index = 0, preview_hex = nil, price = 4200.00, active = true },
        [2] = { id = 2, tuner_shop_id = 10, category = 'wheels', label = 'Forge VR-1', native_index = 1, preview_hex = nil, price = 3800.00, active = false },
        [3] = { id = 3, tuner_shop_id = 20, category = 'wheels', label = 'Other shop', native_index = 0, preview_hex = nil, price = 1.00, active = true },
    },
    tuner_service_parts = {
        [1] = { id = 1, tuner_shop_id = 10, key = 'p-engine', label = 'Engine rebuild kit', price = 9800.00, qty = 1 },
    },
    tuner_service_items = {
        [1] = { id = 1, tuner_shop_id = 10, key = 'engine', label = 'Engine', part_key = 'p-engine', labour_price = 2400.00 },
    },
})

dofile(scriptDir .. '../server/services/TunerCatalogService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

test('listCatalog: only this shop, only active rows', function()
    local rows = TunerCatalogService.listCatalog(10)
    eq(#rows, 1)
    eq(rows[1].label, 'Adder LX')
end)

test('listServiceParts: scoped to shop', function()
    local rows = TunerCatalogService.listServiceParts(10)
    eq(#rows, 1)
    eq(rows[1].key, 'p-engine')
end)

test('listServiceItems: scoped to shop', function()
    local rows = TunerCatalogService.listServiceItems(10)
    eq(#rows, 1)
    eq(rows[1].part_key, 'p-engine')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  PASS  ' .. t.name)
    else table.insert(failures, t.name); print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err)) end
end
print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: run to verify it fails**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_catalog_service_spec.lua` from `core/`
Expected: FAIL — `module 'TunerCatalogService' not found` / file doesn't exist yet.

- [ ] **Step 3: implement**

```lua
--- TunerCatalogService - read-only catalog listings for oblsk_tuner.
TunerCatalogService = {}

--- @param shopId number
--- @return table[] active tuner_catalog_items rows for this shop
function TunerCatalogService.listCatalog(shopId)
    local rows = QueryBuilder.new('tuner_catalog_items'):where('tuner_shop_id', shopId):getSync()
    local active = {}
    for _, row in ipairs(rows) do
        if row.active == true or row.active == 1 then
            table.insert(active, row)
        end
    end
    return active
end

--- @param shopId number
--- @return table[] tuner_service_parts rows for this shop (the parts bin)
function TunerCatalogService.listServiceParts(shopId)
    return QueryBuilder.new('tuner_service_parts'):where('tuner_shop_id', shopId):getSync()
end

--- @param shopId number
--- @return table[] tuner_service_items rows for this shop (the wear-service catalogue)
function TunerCatalogService.listServiceItems(shopId)
    return QueryBuilder.new('tuner_service_items'):where('tuner_shop_id', shopId):getSync()
end

return TunerCatalogService
```

- [ ] **Step 4: run to verify it passes**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_catalog_service_spec.lua` from `core/`
Expected: `3 passed, 0 failed`

- [ ] **Step 5: commit**

```bash
git add server/services/TunerCatalogService.lua tests/tuner_catalog_service_spec.lua
git commit -m "feat(tuner): add TunerCatalogService catalog/parts/service listings"
```

---

### Task 5: `TunerService` (server, self-serve mod purchase)

**Files:**
- Create: `core/plugins/oblsk_tuner/server/services/TunerService.lua`
- Create: `core/plugins/oblsk_tuner/tests/tuner_service_purchase_spec.lua`

**Interfaces:**
- Consumes: `ItemService.binding/has/remove` and `BankingService.charge` (Task 9 wires the real modules; this task's test stubs them exactly like `shop_service_purchase_spec.lua` does), `QueryBuilder`.
- Produces: `TunerService.purchase(source, shopId, vehicleId, catalogItemIds, method, cardId) -> boolean ok, table[]|nil applied, string|nil reason`. `applied` is `[{ category, value, price }]` in the exact `VehicleTuningService.apply` value shapes from Task 2 — Task 9's event handler broadcasts each entry to the owning client if the vehicle is currently spawned, and upserts it into `vehicle_tunings` regardless.

- [ ] **Step 1: write the failing test**

```lua
-- plugins/oblsk_tuner/tests/tuner_service_purchase_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_tuner/tests/tuner_service_purchase_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'
local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

local function freshFake()
    return makeFakeQueryBuilderModule({
        tuner_catalog_items = {
            [1] = { id = 1, tuner_shop_id = 10, category = 'wheels', label = 'Adder LX', native_index = 3, preview_hex = nil, price = 4200.00, active = true },
            [2] = { id = 2, tuner_shop_id = 10, category = 'spoiler', label = 'GT wing', native_index = 5, preview_hex = nil, price = 1800.00, active = true },
            [3] = { id = 3, tuner_shop_id = 20, category = 'wheels', label = 'Wrong shop', native_index = 0, preview_hex = nil, price = 1.00, active = true },
            [4] = { id = 4, tuner_shop_id = 10, category = 'wheels', label = 'Inactive', native_index = 0, preview_hex = nil, price = 1.00, active = false },
        },
        vehicle_tunings = {},
    })
end

local ledger, cash
ItemService = {}
function ItemService.binding(key) if key == 'currency.cash' then return { id = 999 } end end
function ItemService.has(source, baseItem, amount) return cash >= amount end
function ItemService.remove(source, baseItem, amount)
    if not ItemService.has(source, baseItem, amount) then return false, 'Not enough items' end
    cash = cash - amount
    return true
end

BANKING_CHARGE_RESULT = { ok = true }
BankingService = {}
function BankingService.charge(source, cardId, amount, description) return BANKING_CHARGE_RESULT.ok, BANKING_CHARGE_RESULT.reason end

dofile(scriptDir .. '../server/services/TunerService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = freshFake()
    QueryBuilder = fake
    cash = 100000
    BANKING_CHARGE_RESULT = { ok = true }
    fn(fake)
end

test('cash purchase: succeeds, spends cash, returns applied tunings, upserts vehicle_tunings', function()
    withFreshState(function(fake)
        local ok, applied = TunerService.purchase(999, 10, 55, { 1, 2 }, 'cash')
        eq(ok, true)
        eq(#applied, 2)
        eq(cash, 100000 - 4200 - 1800)
        local row = fake.new('vehicle_tunings'):where('vehicle_id', 55):where('key', 'wheels'):firstSync()
        eq(row ~= nil, true)
    end)
end)

test('rejects a catalog item id belonging to a different shop', function()
    withFreshState(function()
        local ok, applied, reason = TunerService.purchase(999, 10, 55, { 3 }, 'cash')
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

test('rejects an inactive catalog item id', function()
    withFreshState(function()
        local ok, applied, reason = TunerService.purchase(999, 10, 55, { 4 }, 'cash')
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

test('rejects an empty selection', function()
    withFreshState(function()
        local ok, applied, reason = TunerService.purchase(999, 10, 55, {}, 'cash')
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

test('card purchase: charges the card, not cash', function()
    withFreshState(function()
        local ok = TunerService.purchase(999, 10, 55, { 2 }, 'card', 7)
        eq(ok, true)
        eq(cash, 100000) -- untouched
    end)
end)

test('card purchase: BankingService.charge failing rejects the whole purchase', function()
    withFreshState(function(fake)
        BANKING_CHARGE_RESULT = { ok = false, reason = 'Card is frozen' }
        local ok, applied, reason = TunerService.purchase(999, 10, 55, { 2 }, 'card', 7)
        eq(ok, false)
        eq(reason, 'Card is frozen')
        eq(fake.new('vehicle_tunings'):where('vehicle_id', 55):where('key', 'spoiler'):firstSync(), nil)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  PASS  ' .. t.name)
    else table.insert(failures, t.name); print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err)) end
end
print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: run to verify it fails**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_service_purchase_spec.lua` from `core/`
Expected: FAIL — file doesn't exist yet.

- [ ] **Step 3: implement**

```lua
--- TunerService - self-serve mod purchase for oblsk_tuner. Re-resolves every
--- catalog item id server-side (never trusts a client-sent price or that an
--- id belongs to the shop the player is standing at) — same rule as
--- ShopService.resolveLines.
TunerService = {}

--- @param shopId number
--- @param catalogItemIds number[]
--- @return table[]|nil rows, number|nil total, string|nil reason
local function resolveItems(shopId, catalogItemIds)
    if not catalogItemIds or #catalogItemIds == 0 then
        return nil, nil, 'Nothing selected'
    end

    local resolved, total = {}, 0
    for _, id in ipairs(catalogItemIds) do
        local row = QueryBuilder.new('tuner_catalog_items'):where('id', id):where('tuner_shop_id', shopId):firstSync()
        if not row then
            return nil, nil, 'Item not available at this shop'
        end
        if not (row.active == true or row.active == 1) then
            return nil, nil, 'Item is no longer available'
        end
        total = total + row.price
        table.insert(resolved, row)
    end
    return resolved, total, nil
end

--- Builds the {category, value} pair VehicleTuningService.apply expects,
--- from a catalog row. Colour categories fall back to a fixed default RGB
--- when native_index isn't meaningful for them (paint colour comes from the
--- player's pick elsewhere in a real catalog row set — this default keeps
--- the purchase path total even for a mixed cart).
local function toTuningValue(row)
    if row.category == 'wheels' then
        return { wheelType = 0, index = row.native_index }
    end
    return row.native_index
end

--- @param source number player server id
--- @param shopId number
--- @param vehicleId number vehicles.id being modified
--- @param catalogItemIds number[]
--- @param method string 'cash'|'card'
--- @param cardId number|nil
--- @return boolean, table[]|nil applied [{category, value, price}], string|nil reason
function TunerService.purchase(source, shopId, vehicleId, catalogItemIds, method, cardId)
    local resolved, total, reason = resolveItems(shopId, catalogItemIds)
    if not resolved then
        return false, nil, reason
    end

    if method == 'cash' then
        local cash = ItemService.binding('currency.cash')
        if not cash then
            return false, nil, 'Cash purchases are not available on this server'
        end
        local cashAmount = math.floor(total + 0.5)
        if not ItemService.has(source, cash, cashAmount) then
            return false, nil, 'Not enough cash'
        end
        local removed, removeReason = ItemService.remove(source, cash, cashAmount)
        if not removed then
            return false, nil, removeReason
        end
    elseif method == 'card' then
        local charged, chargeReason = BankingService.charge(source, cardId, total, 'Tuner purchase at shop #' .. shopId)
        if not charged then
            return false, nil, chargeReason
        end
    else
        return false, nil, 'Unknown payment method'
    end

    local applied = {}
    for _, row in ipairs(resolved) do
        local value = toTuningValue(row)
        local existing = QueryBuilder.new('vehicle_tunings'):where('vehicle_id', vehicleId):where('key', row.category):firstSync()
        if existing then
            QueryBuilder.new('vehicle_tunings'):where('id', existing.id):update({ value = json.encode(value) })
        else
            QueryBuilder.new('vehicle_tunings'):insert({ vehicle_id = vehicleId, key = row.category, value = json.encode(value) })
        end
        table.insert(applied, { category = row.category, value = value, price = row.price })
    end

    return true, applied
end

return TunerService
```

- [ ] **Step 4: run to verify it passes**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_service_purchase_spec.lua` from `core/`
Expected: `6 passed, 0 failed`. If the fake `QueryBuilder`'s `insert`/`update` signatures differ from what's assumed above, check `tests/support/fake_query_builder.lua` first (read it — do not guess) and adjust the two calls to match its real API.

- [ ] **Step 5: commit**

```bash
git add server/services/TunerService.lua tests/tuner_service_purchase_spec.lua
git commit -m "feat(tuner): add TunerService self-serve mod purchase"
```

---

### Task 6: `TunerWearService` (server, wear reads with lazy default)

**Files:**
- Create: `core/plugins/oblsk_tuner/server/services/TunerWearService.lua`
- Create: `core/plugins/oblsk_tuner/tests/tuner_wear_service_spec.lua`

**Interfaces:**
- Produces: `TunerWearService.get(vehicleId, key) -> number` (100 if no row), `TunerWearService.getAll(vehicleId, keys) -> table<key, number>` — Task 9's `tunertablet:client:connectVehicle` handler calls `getAll` when a crew member connects the tablet to a vehicle, so Task 13's Service tab shows real condition data; Task 7's `settle` writes wear back to 100 directly via `QueryBuilder` (not through this service, which is read-only by design — matches `TunerCatalogService` being read-only and purchase/write logic living in the mutating services).

- [ ] **Step 1: write the failing test**

```lua
-- plugins/oblsk_tuner/tests/tuner_wear_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_tuner/tests/tuner_wear_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'
local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

QueryBuilder = makeFakeQueryBuilderModule({
    vehicle_component_wear = {
        [1] = { id = 1, vehicle_id = 55, key = 'engine', value = 72 },
    },
})

dofile(scriptDir .. '../server/services/TunerWearService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

test('get: returns the stored value when a row exists', function()
    eq(TunerWearService.get(55, 'engine'), 72)
end)

test('get: defaults to 100 when no row exists', function()
    eq(TunerWearService.get(55, 'clutch'), 100)
end)

test('getAll: fills every requested key, stored or defaulted', function()
    local wear = TunerWearService.getAll(55, { 'engine', 'clutch' })
    eq(wear.engine, 72)
    eq(wear.clutch, 100)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  PASS  ' .. t.name)
    else table.insert(failures, t.name); print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err)) end
end
print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: run to verify it fails**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_wear_service_spec.lua` from `core/`
Expected: FAIL — file doesn't exist yet.

- [ ] **Step 3: implement**

```lua
--- TunerWearService - read-only wear lookups with a lazy 100 ("as new")
--- default, mirroring vehicle_tunings' own lazy-default posture. Writes
--- happen in TunerWorkOrderService.settle, not here.
TunerWearService = {}

--- @param vehicleId number
--- @param key string
--- @return number 0-100
function TunerWearService.get(vehicleId, key)
    local row = QueryBuilder.new('vehicle_component_wear'):where('vehicle_id', vehicleId):where('key', key):firstSync()
    if not row then return 100 end
    return row.value
end

--- @param vehicleId number
--- @param keys string[]
--- @return table<string, number>
function TunerWearService.getAll(vehicleId, keys)
    local wear = {}
    for _, key in ipairs(keys) do
        wear[key] = TunerWearService.get(vehicleId, key)
    end
    return wear
end

return TunerWearService
```

- [ ] **Step 4: run to verify it passes**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_wear_service_spec.lua` from `core/`
Expected: `3 passed, 0 failed`

- [ ] **Step 5: commit**

```bash
git add server/services/TunerWearService.lua tests/tuner_wear_service_spec.lua
git commit -m "feat(tuner): add TunerWearService lazy-default wear reads"
```

---

### Task 7: `TunerWorkOrderService` (server, raise/assign/complete/settle)

**Files:**
- Create: `core/plugins/oblsk_tuner/server/services/TunerWorkOrderService.lua`
- Create: `core/plugins/oblsk_tuner/tests/tuner_work_order_service_spec.lua`

**Interfaces:**
- Consumes: `PermissionService.can(ownerType, ownerId, key)` (stubbed in the test), `ItemService`/`BankingService` (same stubs as Task 5), `QueryBuilder`.
- Produces:
  - `TunerWorkOrderService.raise(shopId, vehicleId, lines) -> table[]|nil orderIds, string|nil reason` — `lines` is `[{ kind = 'part'|'service', refKey, stockPartKey }]` (client never sends price/label, only what it wants; server resolves both from `tuner_catalog_items`/`tuner_service_items`+`tuner_service_parts`)
  - `TunerWorkOrderService.assign(orderId, crewCharacterId) -> boolean, string|nil reason`
  - `TunerWorkOrderService.complete(orderId) -> boolean, string|nil reason`
  - `TunerWorkOrderService.settle(shopId, vehicleId, source, method, cardId) -> boolean, table[]|nil appliedTunings, string|nil reason` — `appliedTunings` uses the same `{category, value, price}` shape as `TunerService.purchase`'s `applied` (Task 5), for Task 9 to broadcast identically for both purchase paths.

- [ ] **Step 1: write the failing test**

```lua
-- plugins/oblsk_tuner/tests/tuner_work_order_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_tuner/tests/tuner_work_order_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'
local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

local function freshFake()
    return makeFakeQueryBuilderModule({
        tuner_catalog_items = {
            [1] = { id = 1, tuner_shop_id = 10, category = 'spoiler', label = 'GT wing', native_index = 5, price = 1800.00, active = true },
        },
        tuner_service_items = {
            [1] = { id = 1, tuner_shop_id = 10, key = 'engine', label = 'Engine', part_key = 'p-engine', labour_price = 2400.00 },
        },
        tuner_service_parts = {
            [1] = { id = 1, tuner_shop_id = 10, key = 'p-body', label = 'Body panel blank', price = 2600.00, qty = 5 },
            [2] = { id = 2, tuner_shop_id = 10, key = 'p-engine', label = 'Engine rebuild kit', price = 9800.00, qty = 1 },
        },
        tuner_work_orders = {},
        tuner_work_order_lines = {},
        vehicle_tunings = {},
        vehicle_component_wear = {},
    })
end

local grants -- { [characterId] = { [key] = true } }
PermissionService = {}
function PermissionService.can(ownerType, ownerId, key)
    return grants[ownerId] and grants[ownerId][key] or false
end

local cash
ItemService = {}
function ItemService.binding(key) if key == 'currency.cash' then return { id = 999 } end end
function ItemService.has(source, baseItem, amount) return cash >= amount end
function ItemService.remove(source, baseItem, amount) cash = cash - amount; return true end

BANKING_CHARGE_RESULT = { ok = true }
BankingService = {}
function BankingService.charge(source, cardId, amount, description) return BANKING_CHARGE_RESULT.ok, BANKING_CHARGE_RESULT.reason end

dofile(scriptDir .. '../server/services/TunerWorkOrderService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = freshFake()
    QueryBuilder = fake
    grants = { [1] = { ['tuner.crew'] = true }, [2] = {} }
    cash = 100000
    BANKING_CHARGE_RESULT = { ok = true }
    fn(fake)
end

test('raise: one order per line, price resolved server-side, status open', function()
    withFreshState(function(fake)
        local orderIds, reason = TunerWorkOrderService.raise(10, 55, {
            { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' },
            { kind = 'service', refKey = 'engine', stockPartKey = 'p-engine' },
        })
        eq(reason, nil)
        eq(#orderIds, 2)
        local o1 = fake.new('tuner_work_orders'):where('id', orderIds[1]):firstSync()
        eq(o1.status, 'open')
        eq(o1.total, 1800.00)
        local o2 = fake.new('tuner_work_orders'):where('id', orderIds[2]):firstSync()
        eq(o2.total, 2400.00 + 9800.00) -- labour + part price
    end)
end)

test('assign: requires tuner.crew, rejects a character without it', function()
    withFreshState(function(fake)
        local orderIds = TunerWorkOrderService.raise(10, 55, { { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' } })
        local ok, reason = TunerWorkOrderService.assign(orderIds[1], 2)
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

test('assign: succeeds for a crew character, moves open -> progress', function()
    withFreshState(function(fake)
        local orderIds = TunerWorkOrderService.raise(10, 55, { { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' } })
        local ok = TunerWorkOrderService.assign(orderIds[1], 1)
        eq(ok, true)
        eq(fake.new('tuner_work_orders'):where('id', orderIds[1]):firstSync().status, 'progress')
    end)
end)

test('assign: rejects a crew character already on another progress order at this shop', function()
    withFreshState(function(fake)
        local orderIds = TunerWorkOrderService.raise(10, 55, {
            { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' },
            { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' },
        })
        TunerWorkOrderService.assign(orderIds[1], 1)
        local ok, reason = TunerWorkOrderService.assign(orderIds[2], 1)
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

test('complete: rejects when stock ran out since raise', function()
    withFreshState(function(fake)
        local orderIds = TunerWorkOrderService.raise(10, 55, { { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' } })
        TunerWorkOrderService.assign(orderIds[1], 1)
        fake.new('tuner_service_parts'):where('id', 1):update({ qty = 0 })
        local ok, reason = TunerWorkOrderService.complete(orderIds[1])
        eq(ok, false)
        eq(reason, 'Parts missing')
    end)
end)

test('complete: succeeds, moves progress -> awaiting', function()
    withFreshState(function(fake)
        local orderIds = TunerWorkOrderService.raise(10, 55, { { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' } })
        TunerWorkOrderService.assign(orderIds[1], 1)
        local ok = TunerWorkOrderService.complete(orderIds[1])
        eq(ok, true)
        eq(fake.new('tuner_work_orders'):where('id', orderIds[1]):firstSync().status, 'awaiting')
    end)
end)

test('settle: bundles every awaiting order for the vehicle, charges, decrements stock, writes tunings + wear, closes orders', function()
    withFreshState(function(fake)
        local orderIds = TunerWorkOrderService.raise(10, 55, {
            { kind = 'part', refKey = 'spoiler', stockPartKey = 'p-body' },
            { kind = 'service', refKey = 'engine', stockPartKey = 'p-engine' },
        })
        for _, id in ipairs(orderIds) do
            TunerWorkOrderService.assign(id, 1)
            TunerWorkOrderService.complete(id)
        end

        local ok, applied = TunerWorkOrderService.settle(10, 55, 999, 'cash')

        eq(ok, true)
        eq(cash, 100000 - 1800 - (2400 + 9800))
        eq(fake.new('tuner_service_parts'):where('id', 1):firstSync().qty, 4) -- p-body 5 -> 4
        eq(fake.new('tuner_service_parts'):where('id', 2):firstSync().qty, 0) -- p-engine 1 -> 0
        eq(fake.new('vehicle_tunings'):where('vehicle_id', 55):where('key', 'spoiler'):firstSync() ~= nil, true)
        eq(fake.new('vehicle_component_wear'):where('vehicle_id', 55):where('key', 'engine'):firstSync().value, 100)
        eq(fake.new('tuner_work_orders'):where('id', orderIds[1]):firstSync().status, 'closed')
        eq(#applied, 1) -- only the part line produces a live tuning to broadcast
    end)
end)

test('settle: nothing to settle when no orders are awaiting', function()
    withFreshState(function()
        local ok, applied, reason = TunerWorkOrderService.settle(10, 55, 999, 'cash')
        eq(ok, false)
        eq(reason ~= nil, true)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  PASS  ' .. t.name)
    else table.insert(failures, t.name); print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err)) end
end
print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: run to verify it fails**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_work_order_service_spec.lua` from `core/`
Expected: FAIL — file doesn't exist yet.

- [ ] **Step 3: implement**

```lua
--- TunerWorkOrderService - the Tuner Tablet's raise -> assign -> complete ->
--- settle lifecycle. Every line's price is resolved server-side from the
--- catalog at raise time (never trusts a client-sent price), and settle
--- re-decrements stock rather than trusting whatever was true at raise time,
--- since another order could have consumed the same part in between.
TunerWorkOrderService = {}

local function resolvePartLine(shopId, refKey)
    local catalog = QueryBuilder.new('tuner_catalog_items'):where('tuner_shop_id', shopId):where('category', refKey):where('active', true):firstSync()
    if not catalog then return nil, 'Part not available at this shop' end
    return { label = catalog.label, price = catalog.price, category = catalog.category }, nil
end

local function resolveServiceLine(shopId, refKey)
    local svc = QueryBuilder.new('tuner_service_items'):where('tuner_shop_id', shopId):where('key', refKey):firstSync()
    if not svc then return nil, 'Service not available at this shop' end
    local part = QueryBuilder.new('tuner_service_parts'):where('tuner_shop_id', shopId):where('key', svc.part_key):firstSync()
    if not part then return nil, 'Service part not stocked at this shop' end
    return { label = 'Service · ' .. svc.label, price = svc.labour_price + part.price, category = svc.key }, nil
end

--- @param shopId number
--- @param vehicleId number
--- @param lines table[] [{ kind = 'part'|'service', refKey, stockPartKey }]
--- @return table[]|nil orderIds, string|nil reason
function TunerWorkOrderService.raise(shopId, vehicleId, lines)
    if not lines or #lines == 0 then
        return nil, 'Nothing to raise'
    end

    local orderIds = {}
    for _, line in ipairs(lines) do
        local resolved, reason
        if line.kind == 'part' then
            resolved, reason = resolvePartLine(shopId, line.refKey)
        elseif line.kind == 'service' then
            resolved, reason = resolveServiceLine(shopId, line.refKey)
        else
            return nil, 'Unknown line kind'
        end
        if not resolved then
            return nil, reason
        end

        local orderId = QueryBuilder.new('tuner_work_orders'):insert({
            tuner_shop_id = shopId, vehicle_id = vehicleId, status = 'open',
            crew_character_id = nil, total = resolved.price,
        })
        QueryBuilder.new('tuner_work_order_lines'):insert({
            work_order_id = orderId, kind = line.kind, ref_key = line.refKey,
            label = resolved.label, price = resolved.price, stock_part_key = line.stockPartKey,
        })
        table.insert(orderIds, orderId)
    end
    return orderIds, nil
end

--- @param orderId number
--- @param crewCharacterId number
--- @return boolean, string|nil reason
function TunerWorkOrderService.assign(orderId, crewCharacterId)
    local order = QueryBuilder.new('tuner_work_orders'):where('id', orderId):firstSync()
    if not order then return false, 'Work order not found' end

    if not PermissionService.can('character', crewCharacterId, 'tuner.crew') then
        return false, 'Not authorized to take work orders'
    end

    local busy = QueryBuilder.new('tuner_work_orders')
        :where('tuner_shop_id', order.tuner_shop_id):where('status', 'progress'):where('crew_character_id', crewCharacterId)
        :firstSync()
    if busy then
        return false, 'Already working another order'
    end

    QueryBuilder.new('tuner_work_orders'):where('id', orderId):update({ status = 'progress', crew_character_id = crewCharacterId })
    return true, nil
end

--- @param orderId number
--- @return boolean, string|nil reason
function TunerWorkOrderService.complete(orderId)
    local order = QueryBuilder.new('tuner_work_orders'):where('id', orderId):firstSync()
    if not order then return false, 'Work order not found' end

    local lines = QueryBuilder.new('tuner_work_order_lines'):where('work_order_id', orderId):getSync()
    for _, line in ipairs(lines) do
        if line.stock_part_key then
            local part = QueryBuilder.new('tuner_service_parts'):where('tuner_shop_id', order.tuner_shop_id):where('key', line.stock_part_key):firstSync()
            if not part or part.qty <= 0 then
                return false, 'Parts missing'
            end
        end
    end

    QueryBuilder.new('tuner_work_orders'):where('id', orderId):update({ status = 'awaiting' })
    return true, nil
end

local function toTuningValue(category, nativeIndex)
    if category == 'wheels' then
        return { wheelType = 0, index = nativeIndex }
    end
    return nativeIndex
end

--- Bundles every awaiting order for this vehicle at this shop into one bill.
--- @param shopId number
--- @param vehicleId number
--- @param source number player server id paying the bill
--- @param method string 'cash'|'card'
--- @param cardId number|nil
--- @return boolean, table[]|nil appliedTunings [{category, value, price}], string|nil reason
function TunerWorkOrderService.settle(shopId, vehicleId, source, method, cardId)
    local orders = QueryBuilder.new('tuner_work_orders')
        :where('tuner_shop_id', shopId):where('vehicle_id', vehicleId):where('status', 'awaiting'):getSync()
    if #orders == 0 then
        return false, nil, 'Nothing to settle'
    end

    local total = 0
    for _, order in ipairs(orders) do total = total + order.total end

    if method == 'cash' then
        local cash = ItemService.binding('currency.cash')
        if not cash then return false, nil, 'Cash purchases are not available on this server' end
        local cashAmount = math.floor(total + 0.5)
        if not ItemService.has(source, cash, cashAmount) then return false, nil, 'Not enough cash' end
        local removed, removeReason = ItemService.remove(source, cash, cashAmount)
        if not removed then return false, nil, removeReason end
    elseif method == 'card' then
        local charged, chargeReason = BankingService.charge(source, cardId, total, 'Tuner work order settlement at shop #' .. shopId)
        if not charged then return false, nil, chargeReason end
    else
        return false, nil, 'Unknown payment method'
    end

    local applied = {}
    for _, order in ipairs(orders) do
        local lines = QueryBuilder.new('tuner_work_order_lines'):where('work_order_id', order.id):getSync()
        for _, line in ipairs(lines) do
            if line.stock_part_key then
                local part = QueryBuilder.new('tuner_service_parts'):where('tuner_shop_id', shopId):where('key', line.stock_part_key):firstSync()
                if part then
                    QueryBuilder.new('tuner_service_parts'):where('id', part.id):update({ qty = math.max(0, part.qty - 1) })
                end
            end

            if line.kind == 'part' then
                local catalog = QueryBuilder.new('tuner_catalog_items'):where('tuner_shop_id', shopId):where('category', line.ref_key):firstSync()
                local value = toTuningValue(line.ref_key, catalog and catalog.native_index or 0)
                local existing = QueryBuilder.new('vehicle_tunings'):where('vehicle_id', vehicleId):where('key', line.ref_key):firstSync()
                if existing then
                    QueryBuilder.new('vehicle_tunings'):where('id', existing.id):update({ value = json.encode(value) })
                else
                    QueryBuilder.new('vehicle_tunings'):insert({ vehicle_id = vehicleId, key = line.ref_key, value = json.encode(value) })
                end
                table.insert(applied, { category = line.ref_key, value = value, price = line.price })
            else -- 'service'
                local existingWear = QueryBuilder.new('vehicle_component_wear'):where('vehicle_id', vehicleId):where('key', line.ref_key):firstSync()
                if existingWear then
                    QueryBuilder.new('vehicle_component_wear'):where('id', existingWear.id):update({ value = 100 })
                else
                    QueryBuilder.new('vehicle_component_wear'):insert({ vehicle_id = vehicleId, key = line.ref_key, value = 100 })
                end
            end
        end
        QueryBuilder.new('tuner_work_orders'):where('id', order.id):update({ status = 'closed' })
    end

    return true, applied, nil
end

return TunerWorkOrderService
```

- [ ] **Step 4: run to verify it passes**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_work_order_service_spec.lua` from `core/`
Expected: `8 passed, 0 failed`. As in Task 5, if `insert`/`update` on the fake `QueryBuilder` don't match these exact calls, read `tests/support/fake_query_builder.lua` and adjust.

- [ ] **Step 5: commit**

```bash
git add server/services/TunerWorkOrderService.lua tests/tuner_work_order_service_spec.lua
git commit -m "feat(tuner): add TunerWorkOrderService raise/assign/complete/settle lifecycle"
```

---

### Task 8: `TunerCrewService` (server, roster + busy check)

**Files:**
- Create: `core/plugins/oblsk_tuner/server/services/TunerCrewService.lua`
- Create: `core/plugins/oblsk_tuner/tests/tuner_crew_service_spec.lua`

**Interfaces:**
- Consumes: `OrganizationService.listMembers(orgId) -> table[]` (`{character_id, name, rank}`, confirmed at `modules/oblsk_organizations/server/services/OrganizationService.lua:236`), `QueryBuilder`.
- Produces: `TunerCrewService.listCrew(shopId) -> table[]` — rows `{ characterId, name, rank, busy }`, `busy` computed from open `progress` orders at that shop — feeds Task 9's `tunertablet:open` sync and Task 13's "pick a mechanic" step.

- [ ] **Step 1: write the failing test**

```lua
-- plugins/oblsk_tuner/tests/tuner_crew_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_tuner/tests/tuner_crew_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'
local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

QueryBuilder = makeFakeQueryBuilderModule({
    tuner_shops = {
        [10] = { id = 10, name = 'Downtown Tuner', organization_id = 5 },
        [11] = { id = 11, name = 'No-crew shop', organization_id = nil },
    },
    tuner_work_orders = {
        [1] = { id = 1, tuner_shop_id = 10, status = 'progress', crew_character_id = 2 },
        [2] = { id = 2, tuner_shop_id = 10, status = 'closed', crew_character_id = 1 },
    },
})

OrganizationService = {}
function OrganizationService.listMembers(orgId)
    if orgId == 5 then
        return {
            { character_id = 1, name = 'You', rank = 'Tuner' },
            { character_id = 2, name = 'Dario Vella', rank = 'Mechanic' },
        }
    end
    return {}
end

dofile(scriptDir .. '../server/services/TunerCrewService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

test('listCrew: returns every org member with busy computed from progress orders', function()
    local crew = TunerCrewService.listCrew(10)
    eq(#crew, 2)
    eq(crew[1].busy, false)
    eq(crew[2].busy, true) -- character_id 2 has a 'progress' order at shop 10
end)

test('listCrew: empty roster for a shop with no linked organization', function()
    local crew = TunerCrewService.listCrew(11)
    eq(#crew, 0)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  PASS  ' .. t.name)
    else table.insert(failures, t.name); print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err)) end
end
print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: run to verify it fails**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_crew_service_spec.lua` from `core/`
Expected: FAIL — file doesn't exist yet.

- [ ] **Step 3: implement**

```lua
--- TunerCrewService - crew roster for a tuner shop, sourced from the
--- organization linked via tuner_shops.organization_id (nullable — a shop
--- with no org simply has no assignable crew).
TunerCrewService = {}

--- @param shopId number
--- @return table[] [{ characterId, name, rank, busy }]
function TunerCrewService.listCrew(shopId)
    local shop = QueryBuilder.new('tuner_shops'):where('id', shopId):firstSync()
    if not shop or not shop.organization_id then return {} end

    local members = OrganizationService.listMembers(shop.organization_id)
    local crew = {}
    for _, m in ipairs(members) do
        local busy = QueryBuilder.new('tuner_work_orders')
            :where('tuner_shop_id', shopId):where('status', 'progress'):where('crew_character_id', m.character_id)
            :firstSync() ~= nil
        table.insert(crew, { characterId = m.character_id, name = m.name, rank = m.rank, busy = busy })
    end
    return crew
end

return TunerCrewService
```

- [ ] **Step 4: run to verify it passes**

Run: `lua5.4 plugins/oblsk_tuner/tests/tuner_crew_service_spec.lua` from `core/`
Expected: `2 passed, 0 failed`

- [ ] **Step 5: commit**

```bash
git add server/services/TunerCrewService.lua tests/tuner_crew_service_spec.lua
git commit -m "feat(tuner): add TunerCrewService org-backed roster with busy check"
```

---

### Task 9: Server wiring (`server/main.lua`)

**Files:**
- Create: `core/plugins/oblsk_tuner/server/main.lua`

**Interfaces:**
- Consumes: every service from Tasks 4-8, `InteractionService.register`, `ActionService.register`, `WebView.openPage`/`.focus` (server), `Obelisk.onServer`/`.emitClient`, `CharacterService.getActiveCharacterId`, `VehicleService.findVehicleIdByNetId` (Task 3), `NotificationService.notify`, `BankingService.listCardsForCharacter`.
- Produces: the wire protocol Task 10 (client) and Task 11/13 (Vue) consume:
  - Server → client → NUI: `tuner:server:sync` `{ shop, catalog }`, `tunertablet:server:sync` `{ shop, catalog: {parts, serviceParts, serviceItems}, crew, orders, wear }`, `tuner:server:applyTuning` `{ netId, category, value }` (also reused for the tablet), `tunertablet:server:cardsSync` `{ cards }`, `tuner:server:purchaseResult` / `tunertablet:server:workOrderResult` `{ ok, reason }`.
  - NUI → client → server: `tuner:client:purchase` `{ shopId, catalogItemIds, method, cardId }`, `tunertablet:client:raise` `{ shopId, vehicleId, lines }`, `tunertablet:client:assign` `{ orderId, crewCharacterId }`, `tunertablet:client:complete` `{ orderId }`, `tunertablet:client:settle` `{ shopId, vehicleId, method, cardId }`, `tunertablet:client:requestCards`.

- [ ] **Step 1: implement**

```lua
--- Tuner Plugin - Server Main
print('[Tuner] Loading...')

local function notifyFailure(source, title, reason)
    NotificationService.notify(source, { type = 'error', title = title, description = reason or 'Failed' })
end

--------------------------------------------------------------------------------
-- Tuner (self-serve)
--------------------------------------------------------------------------------

local function openTunerForSource(source, shopId, netId)
    local vehicleId = VehicleService.findVehicleIdByNetId(netId)
    if not vehicleId then
        notifyFailure(source, 'Tuner', 'No vehicle in the bay')
        return
    end

    local shop = QueryBuilder.new('tuner_shops'):where('id', shopId):firstSync()
    if not shop then return end

    WebView.openPage(source, '/Tuner')
    WebView.focus(source)
    Obelisk.emitClient('tuner:server:sync', source, {
        shop = shop, vehicleId = vehicleId, catalog = TunerCatalogService.listCatalog(shopId),
    })
end

ActionService.register('tuner:open', function(source, data)
    local shopId = data and data.interaction and data.interaction.options and data.interaction.options.shopId
    local netId = data and data.netId
    if not shopId or not netId then return end
    openTunerForSource(source, shopId, netId)
end, { label = 'Open tuner' })

Obelisk.onServer('tuner:client:purchase', function(shopId, vehicleId, catalogItemIds, method, cardId)
    local source = source
    local ok, applied, reason = TunerService.purchase(source, shopId, vehicleId, catalogItemIds, method, cardId)
    if ok then
        local netId = VehicleService.activeNetIds[vehicleId]
        if netId then
            for _, entry in ipairs(applied) do
                Obelisk.emitClient('tuner:server:applyTuning', source, { netId = netId, category = entry.category, value = entry.value })
            end
        end
        Obelisk.emitClient('tuner:server:purchaseResult', source, { ok = true })
    else
        notifyFailure(source, 'Purchase failed', reason)
        Obelisk.emitClient('tuner:server:purchaseResult', source, { ok = false, reason = reason })
    end
end)

--------------------------------------------------------------------------------
-- Tuner Tablet (staff)
--------------------------------------------------------------------------------

local function tabletSync(source, shopId)
    local shop = QueryBuilder.new('tuner_shops'):where('id', shopId):firstSync()
    if not shop then return end

    local serviceItems = TunerCatalogService.listServiceItems(shopId)
    local wearKeys = {}
    for _, item in ipairs(serviceItems) do table.insert(wearKeys, item.key) end

    Obelisk.emitClient('tunertablet:server:sync', source, {
        shop = shop,
        catalog = {
            parts = TunerCatalogService.listCatalog(shopId),
            serviceParts = TunerCatalogService.listServiceParts(shopId),
            serviceItems = serviceItems,
        },
        crew = TunerCrewService.listCrew(shopId),
        orders = QueryBuilder.new('tuner_work_orders'):where('tuner_shop_id', shopId):getSync(),
    })
end

ActionService.register('tunertablet:open', function(source, data)
    local shopId = data and data.interaction and data.interaction.options and data.interaction.options.shopId
    if not shopId then return end

    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or not PermissionService.can('character', characterId, 'tuner.crew') then
        notifyFailure(source, 'Tuner Tablet', 'Staff only')
        return
    end

    WebView.openPage(source, '/TunerTablet')
    WebView.focus(source)
    tabletSync(source, shopId)
end, { label = 'Open tuner tablet' })

Obelisk.onServer('tunertablet:client:raise', function(shopId, vehicleId, lines)
    local source = source
    local orderIds, reason = TunerWorkOrderService.raise(shopId, vehicleId, lines)
    if orderIds then
        tabletSync(source, shopId)
        Obelisk.emitClient('tunertablet:server:workOrderResult', source, { ok = true })
    else
        notifyFailure(source, 'Could not raise work order', reason)
        Obelisk.emitClient('tunertablet:server:workOrderResult', source, { ok = false, reason = reason })
    end
end)

Obelisk.onServer('tunertablet:client:assign', function(shopId, orderId, crewCharacterId)
    local source = source
    local ok, reason = TunerWorkOrderService.assign(orderId, crewCharacterId)
    if ok then
        tabletSync(source, shopId)
    else
        notifyFailure(source, 'Could not assign', reason)
    end
    Obelisk.emitClient('tunertablet:server:workOrderResult', source, { ok = ok, reason = reason })
end)

Obelisk.onServer('tunertablet:client:complete', function(shopId, orderId)
    local source = source
    local ok, reason = TunerWorkOrderService.complete(orderId)
    if ok then
        tabletSync(source, shopId)
    else
        notifyFailure(source, 'Could not complete', reason)
    end
    Obelisk.emitClient('tunertablet:server:workOrderResult', source, { ok = ok, reason = reason })
end)

Obelisk.onServer('tunertablet:client:settle', function(shopId, vehicleId, method, cardId)
    local source = source
    local ok, applied, reason = TunerWorkOrderService.settle(shopId, vehicleId, source, method, cardId)
    if ok then
        local netId = VehicleService.activeNetIds[vehicleId]
        if netId then
            for _, entry in ipairs(applied) do
                Obelisk.emitClient('tuner:server:applyTuning', source, { netId = netId, category = entry.category, value = entry.value })
            end
        end
        tabletSync(source, shopId)
        Obelisk.emitClient('tunertablet:server:workOrderResult', source, { ok = true })
    else
        notifyFailure(source, 'Could not settle', reason)
        Obelisk.emitClient('tunertablet:server:workOrderResult', source, { ok = false, reason = reason })
    end
end)

Obelisk.onServer('tunertablet:client:requestCards', function()
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then return end
    Obelisk.emitClient('tunertablet:server:cardsSync', source, { cards = BankingService.listCardsForCharacter(characterId) })
end)

--- The tablet is handheld, not fixed at a bay, so "which vehicle" is
--- resolved the same way the self-serve Tuner resolves it: the client
--- finds the nearest vehicle's netId (client/main.lua's
--- nearestVehicleNetId, reused for the tablet) and sends it here. Also
--- resolves and returns this vehicle's wear so the tablet's Service tab
--- has real data instead of TunerWearService sitting unused.
Obelisk.onServer('tunertablet:client:connectVehicle', function(shopId, netId)
    local source = source
    local vehicleId = VehicleService.findVehicleIdByNetId(netId)
    if not vehicleId then
        notifyFailure(source, 'Tuner Tablet', 'No vehicle in range')
        return
    end

    local vehicle = QueryBuilder.new('vehicles'):where('id', vehicleId):firstSync()
    local baseVehicle = vehicle and QueryBuilder.new('base_vehicles'):where('id', vehicle.base_vehicle_id):firstSync()

    local serviceItems = TunerCatalogService.listServiceItems(shopId)
    local wearKeys = {}
    for _, item in ipairs(serviceItems) do table.insert(wearKeys, item.key) end

    Obelisk.emitClient('tunertablet:server:vehicleConnected', source, {
        vehicleId = vehicleId,
        name = baseVehicle and baseVehicle.name or 'Unknown vehicle',
        plate = vehicle and vehicle.plate or '',
        wear = TunerWearService.getAll(vehicleId, wearKeys),
    })
end)

--------------------------------------------------------------------------------
-- Boot: register every shop's world interactions
--------------------------------------------------------------------------------

local function registerShopInteractions()
    local shops = QueryBuilder.new('tuner_shops'):getSync()
    for _, shop in ipairs(shops) do
        local customerPoint = QueryBuilder.new('interactions'):where('id', shop.interaction_id):firstSync()
        if customerPoint then
            InteractionService.register({
                x = customerPoint.x, y = customerPoint.y, z = customerPoint.z,
                range = customerPoint.range, label = customerPoint.label or shop.name,
                action = 'tuner:open', options = { shopId = shop.id },
            })
        end
        if shop.tablet_interaction_id then
            local tabletPoint = QueryBuilder.new('interactions'):where('id', shop.tablet_interaction_id):firstSync()
            if tabletPoint then
                InteractionService.register({
                    x = tabletPoint.x, y = tabletPoint.y, z = tabletPoint.z,
                    range = tabletPoint.range, label = tabletPoint.label or (shop.name .. ' Tablet'),
                    action = 'tunertablet:open', options = { shopId = shop.id },
                })
            end
        end
    end
end

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    TunerPermissionSeeder.ensure()
    registerShopInteractions()
    print('[Tuner] Loaded successfully!')
end)
```

- [ ] **Step 2: manual smoke check** (this file has no unit test — it's pure event wiring over services already covered by Tasks 4-8's specs, matching `oblsk_shop/server/main.lua`'s untested-wiring precedent)

Run: `lua5.4 -e "dofile('plugins/oblsk_tuner/server/main.lua')"` from `core/` and confirm it fails only on undefined FiveM/Obelisk globals (`ActionService`, `Citizen`, etc.), not a Lua syntax error — this file only truly runs inside FXServer, so a syntax-clean load is the ceiling of what's checkable standalone.

- [ ] **Step 3: commit**

```bash
git add server/main.lua
git commit -m "feat(tuner): wire ActionService/InteractionService/event handlers for tuner + tablet"
```

---

### Task 10: Client wiring (`client/main.lua`)

**Files:**
- Create: `core/plugins/oblsk_tuner/client/main.lua`

**Interfaces:**
- Consumes: `WebView.on`/`.emit`/`.emitServer` (client), `VehicleTuningService.apply` (Task 2), `PlayerPedId`/`GetEntityCoords`/`GetVehiclePedIsIn`/`GetClosestVehicle` (FiveM natives).
- Produces: resolves "nearest vehicle" into the `netId` the `tuner:open` action (Task 9) expects in `data.netId` — done by attaching `netId` onto the interaction-use payload isn't possible (that payload only carries `interactionId`), so this task instead has the NUI ask the client for the nearby vehicle right after `tuner:server:sync` arrives empty-vehicled... **actually resolved simpler**: the client computes the nearest vehicle *before* triggering the interaction and sends it as part of a dedicated client→server event fired instead of relying on `ActionService`'s generic `data.interaction` shape.

- [ ] **Step 1: implement**

```lua
--- Tuner Plugin - Client Main
--- Pure relay + one piece of client-only logic: figuring out which vehicle
--- the player is standing next to when they open the Tuner shop (the server
--- has no concept of "nearest entity", only FiveM's client natives do).

local function nearestVehicleNetId()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, 5.0, 0, 71)
    if vehicle == 0 then return nil end
    return NetworkGetNetworkIdFromEntity(vehicle)
end

--- InteractionService.use (core) fires 'core:client:interaction-use' with
--- just the interactionId — this plugin can't hook that generically, so the
--- Tuner shop's own interaction handler is registered on top of the closest
--- interaction check, reusing the same nearby list InteractionService
--- already tracks.
Obelisk.onClient('core:server:interaction-add', function(interaction)
    if interaction.action ~= 'tuner:open' then return end
    TUNER_INTERACTIONS = TUNER_INTERACTIONS or {}
    TUNER_INTERACTIONS[interaction.id] = interaction
end)

RegisterNetEvent('core:client:interaction-use')
AddEventHandler('core:client:interaction-use', function(interactionId)
    if not (TUNER_INTERACTIONS and TUNER_INTERACTIONS[interactionId]) then return end
    local netId = nearestVehicleNetId()
    if not netId then return end
    -- Re-emit with the vehicle attached; ActionService.execute's data table
    -- is whatever InteractionService.use passed it plus this netId, read by
    -- the tuner:open handler in server/main.lua as data.netId.
    Obelisk.emitServer('tuner:client:openWithVehicle', interactionId, netId)
end)

Obelisk.onClient('tuner:server:sync', function(payload)
    WebView.emit('tuner:sync', payload)
end)

Obelisk.onClient('tuner:server:purchaseResult', function(payload)
    WebView.emit('tuner:purchaseResult', payload)
end)

Obelisk.onClient('tuner:server:applyTuning', function(payload)
    local entity = NetworkGetEntityFromNetworkId(payload.netId)
    if entity == 0 then return end
    VehicleTuningService.apply(entity, payload.category, payload.value)
end)

WebView.on('tuner:purchase', function(data)
    Obelisk.emitServer('tuner:client:purchase', data.shopId, data.vehicleId, data.catalogItemIds, data.method, data.cardId)
end)

--------------------------------------------------------------------------------
-- Tuner Tablet
--------------------------------------------------------------------------------

Obelisk.onClient('tunertablet:server:sync', function(payload)
    WebView.emit('tunertablet:sync', payload)
end)

Obelisk.onClient('tunertablet:server:cardsSync', function(payload)
    WebView.emit('tunertablet:cardsSync', payload)
end)

Obelisk.onClient('tunertablet:server:workOrderResult', function(payload)
    WebView.emit('tunertablet:workOrderResult', payload)
end)

WebView.on('tunertablet:raise', function(data)
    Obelisk.emitServer('tunertablet:client:raise', data.shopId, data.vehicleId, data.lines)
end)

WebView.on('tunertablet:assign', function(data)
    Obelisk.emitServer('tunertablet:client:assign', data.shopId, data.orderId, data.crewCharacterId)
end)

WebView.on('tunertablet:complete', function(data)
    Obelisk.emitServer('tunertablet:client:complete', data.shopId, data.orderId)
end)

WebView.on('tunertablet:settle', function(data)
    Obelisk.emitServer('tunertablet:client:settle', data.shopId, data.vehicleId, data.method, data.cardId)
end)

WebView.on('tunertablet:requestCards', function()
    Obelisk.emitServer('tunertablet:client:requestCards')
end)
```

Note for the implementer: `server/main.lua`'s `tuner:open` `ActionService` handler reads `data.netId` from the payload `ActionService.execute` forwards — this only works if `tuner:client:openWithVehicle` (fired above) is handled server-side by calling `ActionService.execute(source, 'tuner:open', { interaction = InteractionService.get(interactionId), netId = netId })` instead of relying on `InteractionService.use`'s own dispatch. **Add this to `server/main.lua` in Task 9** (a one-handler addition — flagged here since Task 9 was written before this client-side constraint became concrete; add it now):

```lua
-- add to server/main.lua, replacing reliance on the generic interaction-use path for this one action:
Obelisk.onServer('tuner:client:openWithVehicle', function(interactionId, netId)
    local source = source
    local interaction = InteractionService.get(interactionId)
    if not interaction or interaction.action ~= 'tuner:open' then return end
    ActionService.execute(source, 'tuner:open', { interaction = interaction, netId = netId })
end)
```

Add one more client→server relay, for the Tuner Tablet's "connect to nearest vehicle" step (Task 9's `tunertablet:client:connectVehicle` handler consumes it — see Ruling on Tuner Tablet vehicle connection in the ledger):

```lua
WebView.on('tunertablet:connectVehicle', function(data)
    local netId = nearestVehicleNetId()
    if not netId then return end
    Obelisk.emitServer('tunertablet:client:connectVehicle', data.shopId, netId)
end)

Obelisk.onClient('tunertablet:server:vehicleConnected', function(payload)
    WebView.emit('tunertablet:vehicleConnected', payload)
end)
```

- [ ] **Step 2: manual smoke check**

Run: `lua5.4 -e "dofile('plugins/oblsk_tuner/client/main.lua')"` from `core/` and confirm it fails only on undefined FiveM natives, not a syntax error.

- [ ] **Step 3: commit**

```bash
git add client/main.lua server/main.lua
git commit -m "feat(tuner): client NUI relay + nearest-vehicle resolution for tuner:open"
```

---

### Task 11: `Tuner.vue` (self-serve shop page)

**Files:**
- Create: `core/plugins/oblsk_tuner/web/Tuner.vue`
- Create: `core/plugins/oblsk_tuner/web/routes.js`

**Interfaces:**
- Consumes: `Obelisk.on(event, handler)` / `Obelisk.emit(event, data)` NUI bridge (the same global the `oblsk_banking`/`oblsk_shop` Vue pages use — confirmed at `plugins/oblsk_banking/web/apps/Banking/Banking.vue:428`), receives `tuner:sync` `{ shop, vehicleId, catalog }` and `tuner:purchaseResult` `{ ok, reason }` (Task 10), emits `tuner:purchase` `{ shopId, vehicleId, catalogItemIds, method, cardId }`.
- Produces: nothing consumed by a later task — this is a leaf.

- [ ] **Step 1: routes.js**

```js
export default [
  {
    path: '/Tuner',
    name: 'Tuner',
    component: () => import('./Tuner.vue')
  },
  {
    path: '/TunerTablet',
    name: 'TunerTablet',
    component: () => import('./TunerTablet.vue')
  }
]
```

- [ ] **Step 2: Tuner.vue** — 1:1 port of `src/tuner.jsx`'s `TunerScreen`, with the mocked sidebar/cart replaced by real `catalog` data grouped by category and a real purchase call on confirm:

```vue
<template>
  <div class="w-[1920px] h-[1080px] ob-screen-root flex" v-if="shop">
    <div class="w-[260px] border-r border-ob-line flex flex-col">
      <div class="h-14 px-5 flex items-center justify-between border-b border-ob-line">
        <div class="flex items-center gap-2">
          <span class="font-semibold">Tuner</span>
        </div>
        <span class="ob-chip ob-mono text-[10px]">{{ shop.name }}</span>
      </div>
      <div class="px-2 space-y-0.5 py-3">
        <div
          v-for="cat in categories"
          :key="cat"
          class="flex items-center justify-between px-3 py-2.5 rounded-md text-sm cursor-pointer"
          :class="cat === activeCategory ? 'bg-emerald-400/10 text-emerald-400' : 'text-ob-mute hover:text-ob-text hover:bg-ob-raise'"
          @click="activeCategory = cat"
        >
          <span>{{ cat }}</span>
          <span class="ob-mono text-[10px]">{{ itemsByCategory[cat].length }}</span>
        </div>
      </div>
    </div>

    <div class="flex-1 flex flex-col">
      <div class="h-14 px-6 border-b border-ob-line flex items-center justify-between">
        <h2 class="text-lg font-semibold">{{ activeCategory }} · {{ itemsByCategory[activeCategory]?.length || 0 }} options</h2>
        <button class="ob-btn ob-btn-primary h-9" :disabled="!cart.length" @click="confirm('cash')">
          Confirm & install (cash) · ${{ total.toLocaleString() }}
        </button>
        <button class="ob-btn h-9" :disabled="!cart.length" @click="showCardPicker = true">
          Pay by card
        </button>
      </div>

      <div class="flex-1 overflow-y-auto ob-no-scroll p-3 grid grid-cols-4 gap-2">
        <div
          v-for="item in itemsByCategory[activeCategory]"
          :key="item.id"
          class="ob-card p-3 cursor-pointer"
          :class="{ 'ring-1 ring-emerald-400': isInCart(item.id) }"
          @click="toggleCartItem(item)"
        >
          <div class="aspect-video ob-stripe rounded-md mb-2" :style="item.preview_hex ? { background: item.preview_hex } : {}"></div>
          <div class="flex items-baseline justify-between">
            <span class="text-sm font-medium">{{ item.label }}</span>
            <span class="ob-mono text-emerald-400 text-sm">${{ item.price.toLocaleString() }}</span>
          </div>
        </div>
      </div>

      <div class="h-14 border-t border-ob-line px-6 flex items-center justify-between">
        <div class="flex items-center gap-4 text-[11px] ob-mono text-ob-mute">
          <span class="text-emerald-400">CART · {{ cart.length }} changes</span>
          <span v-for="c in cart" :key="c.id">{{ c.label }} · ${{ c.price.toLocaleString() }}</span>
        </div>
        <span class="ob-mono">Total <span class="text-emerald-400">${{ total.toLocaleString() }}</span></span>
      </div>
    </div>

    <div v-if="showCardPicker" class="absolute inset-0 z-20 flex items-center justify-center" style="background:rgba(0,0,0,.72)" @click.self="showCardPicker = false">
      <div class="ob-card p-4 w-80">
        <div class="text-[11px] tracking-[0.2em] text-ob-dim ob-mono mb-2">SELECT A CARD</div>
        <button
          v-for="c in cards" :key="c.id"
          class="w-full flex items-center justify-between px-2.5 h-[42px] rounded-[8px] text-left mb-1.5"
          style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.1)"
          @click="confirm('card', c.id)"
        >
          <span>{{ c.bank_name }} · {{ c.num }}</span>
          <span class="ob-mono">${{ c.available_balance.toLocaleString() }}</span>
        </button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'

const shop = ref(null)
const vehicleId = ref(null)
const catalog = ref([])
const cart = ref([])
const activeCategory = ref(null)
const showCardPicker = ref(false)
const cards = ref([])

const categories = computed(() => [...new Set(catalog.value.map(i => i.category))])
const itemsByCategory = computed(() => {
  const grouped = {}
  for (const cat of categories.value) grouped[cat] = catalog.value.filter(i => i.category === cat)
  return grouped
})
const total = computed(() => cart.value.reduce((sum, c) => sum + c.price, 0))

function isInCart(id) {
  return cart.value.some(c => c.id === id)
}

function toggleCartItem(item) {
  const withoutSameCategory = cart.value.filter(c => c.category !== item.category)
  cart.value = isInCart(item.id) ? withoutSameCategory : [...withoutSameCategory, item]
}

function confirm(method, cardId) {
  if (!cart.value.length) return
  Obelisk.emit('tuner:purchase', {
    shopId: shop.value.id,
    vehicleId: vehicleId.value,
    catalogItemIds: cart.value.map(c => c.id),
    method,
    cardId,
  })
  showCardPicker.value = false
}

function handleSync(payload) {
  shop.value = payload.shop
  vehicleId.value = payload.vehicleId
  catalog.value = payload.catalog
  activeCategory.value = categories.value[0] || null
}

function handlePurchaseResult(payload) {
  if (payload.ok) cart.value = []
}

onMounted(() => {
  Obelisk.on('tuner:sync', handleSync)
  Obelisk.on('tuner:purchaseResult', handlePurchaseResult)
})
onUnmounted(() => {
  Obelisk.off('tuner:sync', handleSync)
  Obelisk.off('tuner:purchaseResult', handlePurchaseResult)
})
</script>
```

- [ ] **Step 2: manual verification** (Vue SFCs aren't covered by the Lua spec harness — this repo has no JS component test setup; verify by running the plugin's `web/` dev server the same way `oblsk_shop`/`oblsk_garage` are verified, per this repo's existing convention of no automated frontend tests for these pages)

Confirm: opening `/Tuner` with a mocked `Obelisk.emit('tuner:sync', {...})` renders categories, selecting/deselecting items updates the cart total, and `Confirm & install` calls `Obelisk.emit('tuner:purchase', ...)` with the right payload shape.

- [ ] **Step 3: commit**

```bash
git add web/Tuner.vue web/routes.js
git commit -m "feat(tuner): port Tuner shop prototype to Tuner.vue"
```

---

### Task 12: Shared Tuner Tablet visual components

**Files:**
- Create: `core/plugins/oblsk_tuner/web/tuner/TnGlyph.vue`
- Create: `core/plugins/oblsk_tuner/web/tuner/TnWheel.vue`
- Create: `core/plugins/oblsk_tuner/web/tuner/TtServiceRow.vue`

**Interfaces:**
- Produces: `<TnGlyph :kind="..." :size="..." :c="..." />`, `<TnWheel :size="..." :ring="..." :label="..." />`, `<TtServiceRow :s="..." :v="..." :stock="..." :queued="..." @add="..." @remove="..." />` — Task 13's `TunerTablet.vue` imports all three.

- [ ] **Step 1: TnGlyph.vue** — mechanical port of `src/proto/tuner-parts.jsx`'s `TnGlyph`, same `kind` → SVG-path table, JSX `{...s}`/`{...solid}` spreads become explicit `:stroke`/`:fill` bindings since Vue templates don't support prop spreads on raw SVG the same way:

```vue
<template>
  <svg viewBox="0 0 48 48" :width="size" :height="size" style="display:block">
    <g v-if="kind === 'spoiler'">
      <path d="M8 22 L40 22 L40 26 L8 26 Z" :fill="c" opacity="0.85" />
      <path d="M13 26 l-2 8 h4 z" :fill="c" opacity="0.85" />
      <path d="M35 26 l-2 8 h4 z" :fill="c" opacity="0.85" />
      <path d="M8 22 L40 22" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </g>
    <g v-else-if="kind === 'bumperF'">
      <path d="M7 20 q17 -6 34 0 v8 q-17 5 -34 0 z" :fill="c" opacity="0.85" />
      <path d="M14 24 h20" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </g>
    <g v-else-if="kind === 'bumperR'">
      <path d="M7 22 q17 -5 34 0 v6 q-17 6 -34 0 z" :fill="c" opacity="0.85" />
      <circle cx="14" cy="27" r="1.6" fill="#0b0f0d" />
      <circle cx="34" cy="27" r="1.6" fill="#0b0f0d" />
    </g>
    <g v-else-if="kind === 'skirt'">
      <path d="M6 22 L42 20 L42 27 L6 28 Z" :fill="c" opacity="0.85" />
      <path d="M10 24 L38 22.5" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </g>
    <g v-else-if="kind === 'hood'">
      <path d="M9 28 q15 -12 30 -2 l0 4 q-15 -8 -30 2 z" :fill="c" opacity="0.85" />
      <path d="M20 22 h8" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </g>
    <g v-else-if="kind === 'roof'">
      <path d="M12 28 q12 -14 24 0 z" :fill="c" opacity="0.85" />
      <path d="M18 26 h12" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </g>
    <g v-else-if="kind === 'exhaust'">
      <path d="M8 30 q8 0 12 -6 t14 -4" :stroke="c" fill="none" stroke-width="3" stroke-linecap="round" />
      <ellipse cx="38" cy="20" rx="4.5" ry="3.4" :fill="c" opacity="0.85" />
    </g>
    <g v-else-if="kind === 'engine'">
      <rect x="12" y="18" width="18" height="14" rx="2" :fill="c" opacity="0.85" />
      <rect x="30" y="22" width="7" height="8" rx="1.5" :stroke="c" fill="none" stroke-width="1.4" />
      <path d="M16 18 v-4 M22 18 v-4" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" />
      <circle cx="20" cy="25" r="3" fill="#0b0f0d" />
    </g>
    <g v-else-if="kind === 'wheel'">
      <circle cx="24" cy="24" r="13" :stroke="c" fill="none" stroke-width="2.4" />
      <circle cx="24" cy="24" r="5" :fill="c" opacity="0.85" />
      <path v-for="i in 6" :key="i" :d="wheelSpoke(i - 1)" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" />
    </g>
    <g v-else-if="kind === 'window'">
      <path d="M11 28 q13 -13 26 0 z" :fill="c" opacity="0.45" />
      <path d="M11 28 q13 -13 26 0 z" :stroke="c" fill="none" stroke-width="1.4" />
    </g>
    <g v-else-if="kind === 'turbo'">
      <circle cx="22" cy="24" r="10" :stroke="c" fill="none" stroke-width="1.4" />
      <path d="M22 24 q6 -6 10 -2 M22 24 q-2 8 -8 7 M22 24 q6 6 3 10" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" />
      <circle cx="22" cy="24" r="2.5" :fill="c" opacity="0.85" />
    </g>
    <g v-else-if="kind === 'brakes'">
      <circle cx="24" cy="24" r="12" :stroke="c" fill="none" stroke-width="1.4" />
      <path d="M14 16 q-4 8 0 16 l5 -2 q-3 -6 0 -12 z" :fill="c" opacity="0.85" />
    </g>
    <g v-else-if="kind === 'susp'">
      <path d="M24 12 v4 M24 32 v4" :stroke="c" fill="none" stroke-width="2.4" stroke-linecap="round" />
      <path v-for="i in 5" :key="i" :d="`M18 ${17 + (i - 1) * 3} L30 ${18.5 + (i - 1) * 3}`" :stroke="c" fill="none" stroke-width="2" stroke-linecap="round" />
    </g>
    <g v-else-if="kind === 'horn'">
      <path d="M12 20 h6 l10 -6 v20 l-10 -6 h-6 z" :fill="c" opacity="0.85" />
      <path d="M32 18 q4 6 0 12" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" />
    </g>
    <g v-else-if="kind === 'neon'">
      <path d="M10 30 h28" :stroke="c" fill="none" stroke-width="3" stroke-linecap="round" />
      <path d="M14 34 h20" :stroke="c" stroke-width="6" opacity="0.25" stroke-linecap="round" />
      <path d="M12 20 q12 -6 24 0" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" />
    </g>
    <g v-else-if="kind === 'livery'">
      <path d="M8 26 q16 -10 32 0 l0 4 q-16 -8 -32 4 z" :fill="c" opacity="0.85" />
      <path d="M18 21 l4 -6 M26 21 l4 -6" :stroke="c" fill="none" stroke-width="1.4" stroke-linecap="round" />
    </g>
    <circle v-else cx="24" cy="24" r="10" :stroke="c" fill="none" stroke-width="1.4" />
  </svg>
</template>

<script setup>
const props = defineProps({
  kind: { type: String, required: true },
  size: { type: Number, default: 40 },
  c: { type: String, default: 'currentColor' },
})

function wheelSpoke(i) {
  const a = i * 1.047
  return `M24 24 L${24 + Math.cos(a) * 11} ${24 + Math.sin(a) * 11}`
}
</script>
```

- [ ] **Step 2: TnWheel.vue** — port of `src/proto/tuner-parts.jsx`'s `TnWheel`:

```vue
<template>
  <span class="relative grid place-items-center" :style="{ width: size + 'px', height: size + 'px' }">
    <svg viewBox="0 0 100 100" :width="size" :height="size" style="display:block">
      <circle
        v-for="(h, i) in HUES" :key="h + i"
        cx="50" cy="50" :r="r" fill="none" :stroke="h"
        :stroke-width="ring * 100" :stroke-dasharray="`${seg} ${circ - seg}`"
        :stroke-dashoffset="-seg * i" transform="rotate(-90 50 50)"
      />
    </svg>
    <span
      v-if="label != null"
      class="absolute ob-mono font-bold leading-none"
      :style="{ fontSize: size * 0.42 + 'px', color: labelColor, textShadow: '0 1px 3px rgba(0,0,0,.55)' }"
    >{{ label }}</span>
  </span>
</template>

<script setup>
import { computed } from 'vue'

const HUES = ['#e11d48','#f97316','#facc15','#a3e635','#22c55e','#14b8a6','#06b6d4','#3b82f6','#6366f1','#a855f7','#ec4899','#f43f5e']

const props = defineProps({
  size: { type: Number, default: 62 },
  ring: { type: Number, default: 0.3 },
  label: { default: null },
  labelColor: { type: String, default: '#fff' },
})

const r = computed(() => 50 - (props.ring * 100) / 2)
const circ = computed(() => 2 * Math.PI * r.value)
const seg = computed(() => circ.value / HUES.length)
</script>
```

- [ ] **Step 3: TtServiceRow.vue** — port of `src/proto/tuner-service.jsx`'s `TtServiceRow` + its wear-tone helpers:

```vue
<template>
  <div class="rounded-[8px] p-2.5" :style="{ background: queued ? 'color-mix(in oklab, var(--ob-accent) 9%, transparent)' : 'rgba(255,255,255,.035)', border: `1px solid ${queued ? 'color-mix(in oklab, var(--ob-accent) 55%, transparent)' : 'rgba(255,255,255,.1)'}` }">
    <div class="flex items-center gap-2">
      <TnGlyph :kind="s.glyph" :size="17" c="rgba(255,255,255,.65)" />
      <span class="text-[12.5px] font-semibold flex-1 min-w-0 truncate">{{ s.label }}</span>
      <span class="ob-mono text-[10px]" :style="{ color: wearTone }">{{ wearWord }} · {{ v }}%</span>
    </div>
    <div class="mt-2 h-[5px] rounded-full overflow-hidden" style="background:rgba(255,255,255,.09)">
      <div :style="{ width: v + '%', height: '100%', background: wearTone, transition: 'width .35s' }" />
    </div>
    <div class="flex items-center gap-2 mt-2">
      <span class="ob-mono text-[9.5px] flex-1 min-w-0 truncate" :style="{ color: have ? 'rgba(255,255,255,.4)' : '#f87171' }">
        {{ part.label }} · {{ have ? `${stock[s.part]} in bin` : 'OUT OF STOCK' }}
      </span>
      <button v-if="queued" @click="$emit('remove')" class="h-[26px] px-2.5 rounded-[5px] tt-d text-[10.5px]" style="border:1px solid rgba(255,255,255,.16);color:rgba(255,255,255,.7)">Drop</button>
      <button v-else :disabled="!have || v >= 98" @click="$emit('add')" class="h-[26px] px-2.5 rounded-[5px] tt-d text-[10.5px] disabled:opacity-30" style="background:var(--ob-accent);color:#04120d">
        Order · ${{ price.toLocaleString() }}
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import TnGlyph from './TnGlyph.vue'

const props = defineProps({
  s: { type: Object, required: true },   // { id, label, part, labour, glyph }
  v: { type: Number, required: true },   // wear 0-100
  stock: { type: Object, required: true },
  queued: { type: Boolean, default: false },
})
defineEmits(['add', 'remove'])

const part = computed(() => props.stock[`${props.s.part}_meta`] || { label: props.s.part, price: 0 })
const have = computed(() => (props.stock[props.s.part] || 0) > 0)
const price = computed(() => props.s.labour + (part.value.price || 0))
const wearTone = computed(() => (props.v >= 65 ? 'var(--ob-accent)' : props.v >= 35 ? '#f59e0b' : '#ef4444'))
const wearWord = computed(() => (props.v >= 85 ? 'As new' : props.v >= 65 ? 'Good' : props.v >= 35 ? 'Worn' : props.v >= 15 ? 'Bad' : 'Failing'))
</script>
```

Note: `part` reads `stock['${key}_meta']` because, unlike the prototype's hardcoded `TT_PARTS` object (label+price+qty in one place), Task 4's `TunerCatalogService.listServiceParts` returns `{id, key, label, price, qty}` rows — Task 13 assembles `stock` as both a `key -> qty` map (`stock[s.part]`) and a `key_meta -> {label, price}` map (`stock[s.part + '_meta']`) so this component can stay a thin prop-in/event-out leaf without an extra catalog lookup prop. Document this shape at the top of `TunerTablet.vue` where `stock` is built (Task 13, Step 2).

- [ ] **Step 4: manual verification**

Confirm each glyph kind renders (spot-check a few in a Vue dev server or Storybook-less manual mount), `TnWheel` renders 12 hue segments, `TtServiceRow` toggles between "Order" and "Drop" based on `queued`.

- [ ] **Step 5: commit**

```bash
git add web/tuner/
git commit -m "feat(tuner): port shared tuner tablet glyph/wheel/service-row components"
```

---

### Task 13: `TunerTablet.vue` (staff work-order tablet)

**Files:**
- Create: `core/plugins/oblsk_tuner/web/TunerTablet.vue`

**Interfaces:**
- Consumes: `TnGlyph`/`TnWheel`/`TtServiceRow` (Task 12), `Obelisk.on`/`.emit` events from Task 10: `tunertablet:sync` `{shop, catalog:{parts, serviceParts, serviceItems}, crew, orders}`, `tunertablet:cardsSync` `{cards}`, `tunertablet:workOrderResult` `{ok, reason}`. Emits `tunertablet:raise` `{shopId, vehicleId, lines}`, `tunertablet:assign` `{shopId, orderId, crewCharacterId}`, `tunertablet:complete` `{shopId, orderId}`, `tunertablet:settle` `{shopId, vehicleId, method, cardId}`, `tunertablet:requestCards`.
- Produces: nothing consumed by a later task — this is a leaf. Full visual fidelity with `src/proto/tuner-tablet.jsx`: bezel, drag-to-stow handle, parts/service/orders tabs, category grid, work-order cards with crew assignment, bundled settle sheet.

- [ ] **Step 1: implement** — this is the largest single file in the plan; it keeps every visual element from the prototype (bezel, stow-drag, tabs, category grid, orders list, payment sheet) but replaces every piece of prototype-local mock state (`TT_BAYS`, `TT_CREW`, `TT_PARTS`, `CARDS`) with server-synced data:

```vue
<template>
  <div class="absolute inset-0" style="font-family:var(--ob-font-sans)" v-if="shop">
    <style>
      .tt-d{font-family:'Oswald','Geist',sans-serif;text-transform:uppercase;letter-spacing:.05em;font-weight:600}
    </style>

    <div class="absolute flex items-stretch" :style="tabletTransformStyle">
      <div
        @pointerdown="onHandleDown" @pointermove="onHandleMove" @pointerup="onHandleUp"
        class="shrink-0 self-center rounded-l-[10px] flex flex-col items-center justify-center gap-1.5 cursor-grab active:cursor-grabbing"
        style="width:26px;height:120px;background:rgba(12,16,18,.9);border:1px solid rgba(255,255,255,.14);border-right:none;touch-action:none"
      >
        <span style="width:3px;height:26px;border-radius:2px;background:rgba(255,255,255,.28)"></span>
        <span style="width:3px;height:26px;border-radius:2px;background:rgba(255,255,255,.28)"></span>
      </div>

      <div class="relative rounded-[26px] p-[14px] shrink-0" style="width:520px;height:720px;background:linear-gradient(160deg,#1c2024,#0d1012);border:1px solid rgba(255,255,255,.14);box-shadow:0 30px 70px rgba(0,0,0,.72),inset 0 1px 0 rgba(255,255,255,.09)">
        <div class="relative w-full h-full rounded-[15px] overflow-hidden flex flex-col" style="background:linear-gradient(180deg,#0a0e10,#070a0b);border:1px solid rgba(0,0,0,.7)">

          <div class="h-[26px] shrink-0 px-3 flex items-center gap-2 ob-mono text-[9.5px] text-white/40" style="border-bottom:1px solid rgba(255,255,255,.07)">
            <span style="color:var(--ob-accent)">{{ shop.name.toUpperCase() }} TERMINAL</span>
            <span class="ml-auto ob-mono text-[9px] tracking-[0.14em] px-1.5 h-[16px] rounded-[3px] flex items-center" style="background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.5)">WORKSHOP</span>
          </div>

          <div class="shrink-0 px-3 pt-3 pb-2">
            <div class="flex items-center gap-2">
              <span class="w-[30px] h-[30px] rounded-[7px] grid place-items-center shrink-0" style="background:color-mix(in oklab, var(--ob-accent) 18%, transparent);border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent)">
                <TnGlyph kind="engine" :size="15" c="var(--ob-accent)" />
              </span>
              <div class="min-w-0">
                <div class="tt-d text-[14px] leading-none truncate">{{ car ? car.name : 'No vehicle' }}</div>
                <div class="ob-mono text-[9.5px] text-white/35 mt-1 truncate">{{ car ? car.plate : 'NOT CONNECTED' }}</div>
              </div>
              <button v-if="car" @click="disconnect" class="w-[30px] h-[30px] rounded-[7px] grid place-items-center" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.55)">✕</button>
              <button @click="stow = stow ? 0 : 1" class="ml-auto w-[30px] h-[30px] rounded-[7px] grid place-items-center" style="border:1px solid rgba(255,255,255,.14);color:rgba(255,255,255,.6)">{{ stow ? '‹' : '›' }}</button>
            </div>

            <div v-if="car" class="flex gap-1 mt-3 p-1 rounded-[8px]" style="background:rgba(255,255,255,.04)">
              <button
                v-for="t in ['parts', 'service', 'orders']" :key="t"
                @click="tab = t"
                class="flex-1 h-[30px] rounded-[6px] tt-d text-[11px]"
                :style="tab === t ? { background: 'var(--ob-accent)', color: '#04120d' } : { color: 'rgba(255,255,255,.55)' }"
              >{{ t }}{{ t === 'orders' ? ` · ${orders.length}` : '' }}</button>
            </div>
          </div>

          <div v-if="!car" class="flex-1 min-h-0 overflow-y-auto ob-no-scroll px-3 pb-3 flex flex-col items-center justify-center gap-3">
            <div class="ob-mono text-[9px] tracking-[0.2em] text-white/35">STAND NEXT TO THE VEHICLE</div>
            <button
              @click="connect"
              class="h-[42px] px-5 rounded-[8px] tt-d text-[12.5px]"
              style="background:var(--ob-accent);color:#04120d"
            >Connect to nearest vehicle</button>
          </div>

          <template v-else>
            <div v-if="tab === 'parts'" class="flex-1 min-h-0 overflow-y-auto ob-no-scroll px-3 pt-1.5 pb-3">
              <div class="flex gap-1.5 overflow-x-auto ob-no-scroll mb-2">
                <button
                  v-for="c in partCategories" :key="c"
                  @click="activePartCategory = c"
                  class="shrink-0 h-[34px] px-2.5 rounded-[7px] flex items-center gap-1.5 text-[11.5px]"
                  :style="c === activePartCategory ? { background: 'var(--ob-accent)', color: '#04120d', fontWeight: 600 } : { background: 'rgba(255,255,255,.05)', border: '1px solid rgba(255,255,255,.1)', color: 'rgba(255,255,255,.65)' }"
                >{{ c }}</button>
              </div>
              <div class="grid grid-cols-3 gap-1.5">
                <button
                  v-for="item in itemsForCategory" :key="item.id"
                  @click="fit(item)"
                  class="rounded-[8px] overflow-hidden text-left"
                  :style="{ border: `1px solid ${isFitted(item) ? 'var(--ob-accent)' : 'rgba(255,255,255,.12)'}` }"
                >
                  <div class="relative h-[62px] grid place-items-center" :style="item.preview_hex ? { background: item.preview_hex } : { background: 'rgba(255,255,255,.04)' }">
                    <TnGlyph v-if="!item.preview_hex" :kind="item.category" :size="32" c="rgba(255,255,255,.8)" />
                  </div>
                  <div class="h-[26px] px-2 flex items-center justify-between" style="background:rgba(0,0,0,.72);border-top:1px solid rgba(255,255,255,.08)">
                    <span class="text-[11px] text-white/75 truncate">{{ item.label }}</span>
                    <span class="ob-mono text-[9.5px] text-white/45 shrink-0">{{ (item.price / 1000).toFixed(0) }}k</span>
                  </div>
                </button>
              </div>
            </div>

            <div v-else-if="tab === 'service'" class="flex-1 min-h-0 overflow-y-auto ob-no-scroll px-3 pb-3">
              <div class="ob-mono text-[9px] tracking-[0.2em] text-white/35 mb-2">CONDITION</div>
              <div class="flex flex-col gap-1.5">
                <TtServiceRow
                  v-for="s in serviceItems" :key="s.id"
                  :s="{ id: s.key, label: s.label, part: s.part_key, labour: s.labour_price, glyph: s.glyph || 'engine' }"
                  :v="wear[s.key] ?? 100"
                  :stock="stockView"
                  :queued="isQueued('service', s.key)"
                  @add="orderService(s)"
                  @remove="removeFromCart('service', s.key)"
                />
              </div>
            </div>

            <div v-else class="flex-1 min-h-0 overflow-y-auto ob-no-scroll px-3 pb-3">
              <div v-for="o in orders" :key="o.id" class="rounded-[8px] p-2.5 mb-1.5" style="background:color-mix(in oklab, var(--ob-accent) 8%, transparent);border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent)">
                <div class="flex items-center gap-2">
                  <span class="ob-mono text-[11px]" style="color:var(--ob-accent)">WO-{{ o.id }}</span>
                  <span class="ob-mono text-[8.5px] px-1.5 h-[16px] flex items-center rounded-[3px]" style="background:rgba(255,255,255,.07);color:rgba(255,255,255,.45)">{{ o.status.toUpperCase() }}</span>
                  <span class="ob-mono text-[11px] text-white/60 ml-auto">${{ Number(o.total).toLocaleString() }}</span>
                </div>
                <div v-if="o.status === 'open'" class="flex gap-1.5 mt-2">
                  <button v-for="m in crew" :key="m.characterId" :disabled="m.busy" @click="assign(o, m)" class="h-[26px] px-2 rounded-[5px] text-[10.5px] disabled:opacity-30" style="border:1px solid rgba(255,255,255,.1)">{{ m.name }}</button>
                </div>
                <div v-else-if="o.status === 'progress' && o.crew_character_id === myCharacterId" class="mt-2">
                  <button @click="complete(o)" class="h-[28px] px-3 rounded-[5px] tt-d text-[10.5px]" style="background:var(--ob-accent);color:#04120d">Mark done</button>
                </div>
              </div>
              <div v-if="awaitingTotal > 0" class="rounded-[8px] p-2.5 mt-2" style="background:color-mix(in oklab, var(--ob-accent) 9%, transparent);border:1px solid color-mix(in oklab, var(--ob-accent) 45%, transparent)">
                <div class="ob-mono text-[13px]">${{ awaitingTotal.toLocaleString() }} awaiting payment</div>
                <div class="flex gap-1.5 mt-2">
                  <button @click="showPay = 'method'" class="flex-1 h-[30px] rounded-[5px] tt-d text-[10.5px]" style="background:var(--ob-accent);color:#04120d">Settle</button>
                </div>
              </div>
            </div>
          </template>

          <div v-if="cart.length && car" class="shrink-0 px-3 pb-3 pt-2" style="border-top:1px solid rgba(255,255,255,.07)">
            <button @click="raise" class="w-full h-[46px] rounded-[8px] tt-d text-[15px]" style="background:var(--ob-accent);color:#04120d">
              Raise work order · {{ cart.length }}
            </button>
          </div>

          <div v-if="showPay" class="absolute inset-0 z-20 flex flex-col justify-end p-3" style="background:rgba(0,0,0,.72)" @click.self="showPay = null">
            <div class="rounded-[10px] p-3" style="background:rgba(10,14,16,.96);border:1px solid rgba(255,255,255,.13)" @click.stop>
              <div v-if="showPay === 'method'" class="flex gap-2">
                <button @click="settle('cash')" class="flex-1 h-[46px] rounded-[8px] tt-d text-[13px]" style="border:1px solid rgba(255,255,255,.16);color:#fff">CASH</button>
                <button @click="showPay = 'card'; requestCards()" class="flex-1 h-[46px] rounded-[8px] tt-d text-[13px]" style="background:var(--ob-accent);color:#04120d">CARD</button>
              </div>
              <div v-else class="flex flex-col gap-1.5 max-h-[240px] overflow-y-auto ob-no-scroll">
                <button v-for="c in cards" :key="c.id" @click="settle('card', c.id)" class="flex items-center gap-2.5 px-2.5 h-[48px] rounded-[8px] text-left" style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.1)">
                  <span class="block text-[12.5px] font-semibold truncate">{{ c.bank_name }}</span>
                  <span class="ob-mono text-[11.5px] ml-auto" style="color:var(--ob-accent)">${{ c.available_balance.toLocaleString() }}</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import TnGlyph from './tuner/TnGlyph.vue'
import TtServiceRow from './tuner/TtServiceRow.vue'

const shop = ref(null)
const parts = ref([])          // tuner_catalog_items rows
const serviceParts = ref([])   // tuner_service_parts rows (the bin)
const serviceItems = ref([])   // tuner_service_items rows
const crew = ref([])
const orders = ref([])
const cards = ref([])
const wear = ref({})
const myCharacterId = ref(null)

const car = ref(null)          // { vehicleId, name, plate }
const tab = ref('parts')
const activePartCategory = ref(null)
const cart = ref([])           // [{ kind, refKey, stockPartKey, label, price }]
const showPay = ref(null)

const stow = ref(0)
const dragFrom = ref(null)
const W = 520

const tabletTransformStyle = computed(() => ({
  right: '26px', top: '50%',
  transform: `translateY(-50%) translateX(${stow.value * (W - 62)}px)`,
  transition: dragFrom.value != null ? 'none' : 'transform .5s cubic-bezier(.2,.9,.24,1)',
}))

function onHandleDown(e) { e.currentTarget.setPointerCapture(e.pointerId); dragFrom.value = { x: e.clientX, from: stow.value } }
function onHandleMove(e) {
  if (!dragFrom.value) return
  const dx = e.clientX - dragFrom.value.x
  stow.value = Math.max(0, Math.min(1, dragFrom.value.from + dx / (W - 62)))
}
function onHandleUp() { if (!dragFrom.value) return; stow.value = stow.value > 0.4 ? 1 : 0; dragFrom.value = null }

const partCategories = computed(() => [...new Set(parts.value.map(p => p.category))])
const itemsForCategory = computed(() => parts.value.filter(p => p.category === activePartCategory.value))

// stock is both a qty map (keyed by part key) and a '<key>_meta' -> {label, price}
// map, so TtServiceRow (Task 12) can read both through one prop — see Task 12,
// Step 3's note.
const stockView = computed(() => {
  const view = {}
  for (const p of serviceParts.value) {
    view[p.key] = p.qty
    view[`${p.key}_meta`] = { label: p.label, price: p.price }
  }
  return view
})

const awaitingTotal = computed(() => orders.value.filter(o => o.status === 'awaiting').reduce((sum, o) => sum + Number(o.total), 0))

function isFitted(item) { return cart.value.some(c => c.kind === 'part' && c.refKey === item.category) }
function isQueued(kind, refKey) { return cart.value.some(c => c.kind === kind && c.refKey === refKey) }

function fit(item) {
  cart.value = cart.value.filter(c => !(c.kind === 'part' && c.refKey === item.category))
  if (!isFitted(item)) cart.value.push({ kind: 'part', refKey: item.category, stockPartKey: null, label: item.label, price: item.price })
}

function orderService(s) {
  cart.value.push({ kind: 'service', refKey: s.key, stockPartKey: s.part_key, label: `Service · ${s.label}`, price: s.labour_price })
}
function removeFromCart(kind, refKey) { cart.value = cart.value.filter(c => !(c.kind === kind && c.refKey === refKey)) }

function connect() { Obelisk.emit('tunertablet:connectVehicle', { shopId: shop.value.id }) }
function disconnect() { car.value = null; cart.value = []; tab.value = 'parts'; wear.value = {} }
function handleVehicleConnected(payload) {
  car.value = { vehicleId: payload.vehicleId, name: payload.name, plate: payload.plate }
  wear.value = payload.wear
}

function raise() {
  Obelisk.emit('tunertablet:raise', {
    shopId: shop.value.id, vehicleId: car.value.vehicleId,
    lines: cart.value.map(c => ({ kind: c.kind, refKey: c.refKey, stockPartKey: c.stockPartKey })),
  })
  cart.value = []
}

function assign(order, member) {
  Obelisk.emit('tunertablet:assign', { shopId: shop.value.id, orderId: order.id, crewCharacterId: member.characterId })
}
function complete(order) {
  Obelisk.emit('tunertablet:complete', { shopId: shop.value.id, orderId: order.id })
}
function requestCards() { Obelisk.emit('tunertablet:requestCards') }
function settle(method, cardId) {
  Obelisk.emit('tunertablet:settle', { shopId: shop.value.id, vehicleId: car.value.vehicleId, method, cardId })
  showPay.value = null
}

function handleSync(payload) {
  shop.value = payload.shop
  parts.value = payload.catalog.parts
  serviceParts.value = payload.catalog.serviceParts
  serviceItems.value = payload.catalog.serviceItems
  crew.value = payload.crew
  orders.value = payload.orders
  if (!activePartCategory.value) activePartCategory.value = partCategories.value[0] || null
}
function handleCardsSync(payload) { cards.value = payload.cards }

onMounted(() => {
  Obelisk.on('tunertablet:sync', handleSync)
  Obelisk.on('tunertablet:cardsSync', handleCardsSync)
  Obelisk.on('tunertablet:vehicleConnected', handleVehicleConnected)
})
onUnmounted(() => {
  Obelisk.off('tunertablet:sync', handleSync)
  Obelisk.off('tunertablet:cardsSync', handleCardsSync)
  Obelisk.off('tunertablet:vehicleConnected', handleVehicleConnected)
})
</script>
```

Note for the implementer: the tablet's "connect to a vehicle" step reuses Task 10's `nearestVehicleNetId()` — the crew member stands next to the car they're servicing and taps "Connect to nearest vehicle" (see the ledger's ruling on Tuner Tablet vehicle connection for why the prototype's mocked `TT_BAYS` picker list was replaced with this single-action flow, and Task 9/10 for the `tunertablet:client:connectVehicle` round trip this button triggers).

- [ ] **Step 2: manual verification**

Confirm: mocked `tunertablet:sync` renders the shop, tab switching works, picking a part item raises the fit/queued ring, the orders tab lists raised orders with crew-assign buttons, settle opens the payment sheet and emits the right event shape.

- [ ] **Step 3: commit**

```bash
git add web/TunerTablet.vue
git commit -m "feat(tuner): port Tuner Tablet prototype to TunerTablet.vue"
```

---

## Self-Review

**Spec coverage:**
- Data model (7 tables) → Task 1. ✓
- Native mod mapping + bug fix → Task 2. ✓
- Reused systems table (banking, items, org, permissions, interaction, action, notification) → Tasks 4-9. ✓
- Work order lifecycle (raise/assign/complete/settle) → Task 7. ✓
- Live-apply broadcast on purchase/settle → Task 9 (`tuner:server:applyTuning`), Task 10 (client apply), Task 2 (registry it calls into). ✓
- Card payment via real `BankingService`, replacing the prototype's mocked `CARDS` → Task 9 (`tunertablet:client:requestCards`/`cardsSync`), Task 11/13 (Vue payment sheets). ✓
- Crew roster via `oblsk_organizations` → Task 8. ✓
- Permission seeder → Task 1, Step 6. ✓
- Out-of-scope items (admin catalog UI, duty tracking) → intentionally have no task; called out in the spec and not silently implied by any task here.

**Placeholder scan:** no "TBD"/"handle appropriately" phrasing; the one open decision (Task 13's `nearbyVehicles` wiring) is called out explicitly as a decision point rather than glossed over, with two concrete options given and instructions not to guess.

**Type consistency:** `applied`/`appliedTunings` shape `{category, value, price}` matches between `TunerService.purchase` (Task 5) and `TunerWorkOrderService.settle` (Task 7), and both are consumed identically in `server/main.lua` (Task 9). `VehicleTuningService.apply(entity, category, value)` value shapes (Task 2) match what Task 5/7 write into `vehicle_tunings` and what Task 9 broadcasts. `TunerCrewService.listCrew` field names (`characterId`, `busy`) match Task 13's `crew` usage.
