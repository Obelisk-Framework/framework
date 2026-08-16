# oblsk_jobs Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `oblsk_jobs` core module — job definitions, per-job XP/level tracking, on-duty state, and admin CRUD — so individual job plugins (`oblsk_busdriver`, etc., built later) can plug in via a shared `Jobs.*` API instead of reimplementing this machinery.

**Architecture:** A new `core/modules/oblsk_jobs` module following the existing module convention (see `oblsk_organizations`): BaseModel-backed tables, a global `Jobs` table extended across two service files (`JobService.lua` for admin CRUD, `JobProgressService.lua` for on-duty/XP/payout), migrations run automatically via `core/modules/registry.json`. Admin UI lives in `oblsk_admin` (`JobsTab.vue` + a relay file), matching how `ItemsTab.vue` talks to `ItemService` — no dependency from the module back to the admin plugin.

**Tech Stack:** Lua 5.4 (FXServer), the framework's own ORM (`BaseModel`/`QueryBuilder`/`Schema`), Vue 3 (admin web), `lua5.4` CLI for running specs.

**Spec:** `core/docs/superpowers/specs/2026-08-16-jobs-module-design.md`

## Global Constraints

- Per-job XP/level: each job tracks XP/level independently per character (spec §Scope decisions).
- Walk-up engagement: no assignment/hiring step; any character can go on-duty for any active job.
- Only one active job per character at a time; switching requires going off-duty first.
- Active job persists across reconnect automatically — it's a DB row keyed by `character_id`, read on demand. No explicit "restore" step is needed or should be built.
- The module owns pay + XP. `Jobs.completeTask` credits cash directly via `ItemService` (binding `currency.cash`) and updates XP/level — job plugins never pay players themselves.
- Follow the existing module conventions exactly: `BaseModel:extend(tableName)`, migrations via `Schema.create`, tests as standalone `dofile`-chained spec files run with `lua5.4`, using the project's fake in-memory `QueryBuilder` for service specs (no real DB in tests).

---

## Task 1: Module scaffold — migrations and models

**Files:**
- Create: `core/modules/oblsk_jobs/README.md`
- Create: `core/modules/oblsk_jobs/server/migrations.json`
- Create: `core/modules/oblsk_jobs/server/migrations/2026_08_16_130000_create_jobs_table.lua`
- Create: `core/modules/oblsk_jobs/server/migrations/2026_08_16_130001_create_job_levels_table.lua`
- Create: `core/modules/oblsk_jobs/server/migrations/2026_08_16_130002_create_job_tasks_table.lua`
- Create: `core/modules/oblsk_jobs/server/migrations/2026_08_16_130003_create_bus_routes_table.lua`
- Create: `core/modules/oblsk_jobs/server/migrations/2026_08_16_130004_create_character_job_progress_table.lua`
- Create: `core/modules/oblsk_jobs/server/migrations/2026_08_16_130005_create_character_active_job_table.lua`
- Create: `core/modules/oblsk_jobs/server/models/Job.lua`
- Create: `core/modules/oblsk_jobs/server/models/JobLevel.lua`
- Create: `core/modules/oblsk_jobs/server/models/JobTask.lua`
- Create: `core/modules/oblsk_jobs/server/models/BusRoute.lua`
- Create: `core/modules/oblsk_jobs/server/models/CharacterJobProgress.lua`
- Create: `core/modules/oblsk_jobs/server/models/CharacterActiveJob.lua`
- Modify: `core/modules/registry.json`

**Interfaces:**
- Produces: global models `Job`, `JobLevel`, `JobTask`, `BusRoute`, `CharacterJobProgress`, `CharacterActiveJob`, each `BaseModel:extend('<table>')` with `primaryKey='id'`, `timestamps=true`. Later tasks' services use these via `Model:createSync(attrs)`, `Model:where(col, val)`, `:firstSync()`, `:getSync()`, `:update(attrs)`, `:get(key)`.

- [ ] **Step 1: Write the migrations**

`core/modules/oblsk_jobs/server/migrations/2026_08_16_130000_create_jobs_table.lua`:

```lua
--- Migration: Create jobs table
return {
    up = function()
        Schema.create('jobs', function(table)
            table:id()
            table:string('key', 64):unique()
            table:string('name')
            table:string('icon'):nullable()
            table:text('description'):nullable()
            table:boolean('active'):default(1)
            table:timestamps()
        end)

        print('[Migration] Created jobs table')
    end,

    down = function()
        Schema.drop('jobs')
        print('[Migration] Dropped jobs table')
    end
}
```

`core/modules/oblsk_jobs/server/migrations/2026_08_16_130001_create_job_levels_table.lua`:

```lua
--- Migration: Create job_levels table
--- One row per level an admin has defined for a job. xp_required is the
--- total XP a character needs to be at this level (not a delta).
return {
    up = function()
        Schema.create('job_levels', function(table)
            table:id()
            table:integer('job_id')
            table:integer('level')
            table:integer('xp_required')
            table:string('label'):nullable()
            table:timestamps()

            table:index({'job_id'})
            table:unique({'job_id', 'level'})
        end)

        print('[Migration] Created job_levels table')
    end,

    down = function()
        Schema.drop('job_levels')
        print('[Migration] Dropped job_levels table')
    end
}
```

`core/modules/oblsk_jobs/server/migrations/2026_08_16_130002_create_job_tasks_table.lua`:

```lua
--- Migration: Create job_tasks table
--- Admin-configured payout table. Job plugins report completed work by
--- task_key; pay_amount/xp_amount are looked up here, not hardcoded in the
--- job plugin.
return {
    up = function()
        Schema.create('job_tasks', function(table)
            table:id()
            table:integer('job_id')
            table:string('task_key', 64)
            table:integer('pay_amount')
            table:integer('xp_amount')
            table:timestamps()

            table:index({'job_id'})
            table:unique({'job_id', 'task_key'})
        end)

        print('[Migration] Created job_tasks table')
    end,

    down = function()
        Schema.drop('job_tasks')
        print('[Migration] Dropped job_tasks table')
    end
}
```

`core/modules/oblsk_jobs/server/migrations/2026_08_16_130003_create_bus_routes_table.lua`:

```lua
--- Migration: Create bus_routes table
--- Route data is admin-managed job configuration (same category as
--- job_tasks), so it lives in oblsk_jobs even though only oblsk_busdriver
--- reads it. stops is an ordered JSON array of {x,y,z,label}.
return {
    up = function()
        Schema.create('bus_routes', function(table)
            table:id()
            table:integer('job_id')
            table:string('name')
            table:integer('min_level'):default(1)
            table:json('stops')
            table:timestamps()

            table:index({'job_id'})
        end)

        print('[Migration] Created bus_routes table')
    end,

    down = function()
        Schema.drop('bus_routes')
        print('[Migration] Dropped bus_routes table')
    end
}
```

`core/modules/oblsk_jobs/server/migrations/2026_08_16_130004_create_character_job_progress_table.lua`:

```lua
--- Migration: Create character_job_progress table
--- Per-character, per-job XP/level. One row per (character_id, job_id)
--- pair, created lazily the first time a character earns XP for a job.
return {
    up = function()
        Schema.create('character_job_progress', function(table)
            table:id()
            table:integer('character_id')
            table:integer('job_id')
            table:integer('xp'):default(0)
            table:integer('level'):default(1)
            table:timestamps()

            table:index({'character_id'})
            table:unique({'character_id', 'job_id'})
        end)

        print('[Migration] Created character_job_progress table')
    end,

    down = function()
        Schema.drop('character_job_progress')
        print('[Migration] Dropped character_job_progress table')
    end
}
```

`core/modules/oblsk_jobs/server/migrations/2026_08_16_130005_create_character_active_job_table.lua`:

```lua
--- Migration: Create character_active_job table
--- At most one row per character: the job they're currently on-duty for.
--- Row absence means off-duty. Persists naturally across reconnect since
--- it's read from the DB on demand, not held in server memory.
return {
    up = function()
        Schema.create('character_active_job', function(table)
            table:id()
            table:integer('character_id')
            table:integer('job_id')
            table:timestamps()

            table:unique({'character_id'})
        end)

        print('[Migration] Created character_active_job table')
    end,

    down = function()
        Schema.drop('character_active_job')
        print('[Migration] Dropped character_active_job table')
    end
}
```

`core/modules/oblsk_jobs/server/migrations.json`:

```json
{
  "migrations": [
    "2026_08_16_130000_create_jobs_table",
    "2026_08_16_130001_create_job_levels_table",
    "2026_08_16_130002_create_job_tasks_table",
    "2026_08_16_130003_create_bus_routes_table",
    "2026_08_16_130004_create_character_job_progress_table",
    "2026_08_16_130005_create_character_active_job_table"
  ]
}
```

- [ ] **Step 2: Write the models**

`core/modules/oblsk_jobs/server/models/Job.lua`:

```lua
--- Job Model - a job definition (bus driver, gardener, ...). See
--- docs/superpowers/specs/2026-08-16-jobs-module-design.md.
Job = BaseModel:extend('jobs')

Job.primaryKey = 'id'
Job.timestamps = true
Job.fillable = { 'key', 'name', 'icon', 'description', 'active' }
Job.hidden = {}

return Job
```

`core/modules/oblsk_jobs/server/models/JobLevel.lua`:

```lua
--- JobLevel Model - one admin-defined level threshold for a job.
JobLevel = BaseModel:extend('job_levels')

JobLevel.primaryKey = 'id'
JobLevel.timestamps = true
JobLevel.fillable = { 'job_id', 'level', 'xp_required', 'label' }
JobLevel.hidden = {}

return JobLevel
```

`core/modules/oblsk_jobs/server/models/JobTask.lua`:

```lua
--- JobTask Model - admin-configured pay/XP for one task_key of a job.
JobTask = BaseModel:extend('job_tasks')

JobTask.primaryKey = 'id'
JobTask.timestamps = true
JobTask.fillable = { 'job_id', 'task_key', 'pay_amount', 'xp_amount' }
JobTask.hidden = {}

return JobTask
```

`core/modules/oblsk_jobs/server/models/BusRoute.lua`:

```lua
--- BusRoute Model - one admin-defined bus route, gated by min_level.
BusRoute = BaseModel:extend('bus_routes')

BusRoute.primaryKey = 'id'
BusRoute.timestamps = true
BusRoute.fillable = { 'job_id', 'name', 'min_level', 'stops' }
BusRoute.hidden = {}

return BusRoute
```

`core/modules/oblsk_jobs/server/models/CharacterJobProgress.lua`:

```lua
--- CharacterJobProgress Model - a character's XP/level for one job.
CharacterJobProgress = BaseModel:extend('character_job_progress')

CharacterJobProgress.primaryKey = 'id'
CharacterJobProgress.timestamps = true
CharacterJobProgress.fillable = { 'character_id', 'job_id', 'xp', 'level' }
CharacterJobProgress.hidden = {}

return CharacterJobProgress
```

`core/modules/oblsk_jobs/server/models/CharacterActiveJob.lua`:

```lua
--- CharacterActiveJob Model - the job a character is currently on-duty
--- for. Row absence means off-duty.
CharacterActiveJob = BaseModel:extend('character_active_job')

CharacterActiveJob.primaryKey = 'id'
CharacterActiveJob.timestamps = true
CharacterActiveJob.fillable = { 'character_id', 'job_id' }
CharacterActiveJob.hidden = {}

return CharacterActiveJob
```

`core/modules/oblsk_jobs/README.md`:

```markdown
# oblsk_jobs

Core module owning job definitions, per-job XP/level tracking, on-duty
state, and payout. Individual job plugins (`oblsk_busdriver`, etc.) consume
the global `Jobs` table this module defines — see
`docs/superpowers/specs/2026-08-16-jobs-module-design.md`.
```

- [ ] **Step 3: Register the module**

Edit `core/modules/registry.json`, add `"oblsk_jobs"` to the `modules` array (alphabetical, between `"oblsk_items"` and `"oblsk_organizations"`).

- [ ] **Step 4: Verify every new file parses**

Run:

```bash
for f in core/modules/oblsk_jobs/server/migrations/*.lua core/modules/oblsk_jobs/server/models/*.lua; do
  lua5.4 -e "assert(loadfile('$f'))" && echo "OK: $f" || echo "FAIL: $f"
done
```

Expected: `OK:` for every file, no `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
git add core/modules/oblsk_jobs core/modules/registry.json
git commit -m "feat(jobs): scaffold oblsk_jobs module migrations and models"
```

---

## Task 2: JobService — admin CRUD for jobs/levels/tasks/routes

**Files:**
- Create: `core/modules/oblsk_jobs/server/services/JobService.lua`
- Create: `core/modules/oblsk_jobs/tests/support/fake_query_builder.lua`
- Create: `core/modules/oblsk_jobs/tests/job_service_crud_spec.lua`

**Interfaces:**
- Consumes: `Job`, `JobLevel`, `JobTask`, `BusRoute` models (Task 1).
- Produces: global `Jobs` table (created here, extended further in Task 3) with:
  - `Jobs.admin.listJobs()` → `table[]` all job rows
  - `Jobs.admin.createJob(attrs)` → `number jobId` (`attrs` has `key`, `name`, `icon`, `description`)
  - `Jobs.admin.updateJob(jobId, attrs)` → nothing
  - `Jobs.admin.deleteJob(jobId)` → nothing; cascades levels/tasks/routes
  - `Jobs.admin.listLevels(jobId)` / `upsertLevel(jobId, level, xpRequired, label)` → `number levelId` / `deleteLevel(levelId)`
  - `Jobs.admin.listTasks(jobId)` / `upsertTask(jobId, taskKey, payAmount, xpAmount)` → `number taskId` / `deleteTask(taskId)`
  - `Jobs.admin.listRoutes(jobId)` / `upsertRoute(jobId, name, minLevel, stops)` → `number routeId` / `deleteRoute(routeId)`
  - `upsertLevel`/`upsertTask` are keyed by the compound unique index (`job_id`+`level` / `job_id`+`task_key`): if a row with that key exists, update it and return its id; otherwise insert.

- [ ] **Step 1: Write the failing test**

`core/modules/oblsk_jobs/tests/support/fake_query_builder.lua` — copy verbatim from `core/modules/oblsk_organizations/tests/support/fake_query_builder.lua` (already read in full above; same in-memory fake, no changes needed).

`core/modules/oblsk_jobs/tests/job_service_crud_spec.lua`:

```lua
--- Unit tests for JobService (Jobs.admin.*): jobs/levels/tasks/routes CRUD.
--- Run from the repository root: lua5.4 core/modules/oblsk_jobs/tests/job_service_crud_spec.lua
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
dofile(scriptDir .. '../server/models/Job.lua')
dofile(scriptDir .. '../server/models/JobLevel.lua')
dofile(scriptDir .. '../server/models/JobTask.lua')
dofile(scriptDir .. '../server/models/BusRoute.lua')
dofile(scriptDir .. '../server/services/JobService.lua')

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

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('createJob: inserts a job row and returns its id', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        eq(#tables.jobs, 1)
        eq(tables.jobs[1].id, jobId)
        eq(tables.jobs[1].key, 'busdriver')
        eq(tables.jobs[1].name, 'Bus Driver')
    end)
end)

test('listJobs: returns every job row', function()
    withFakeDb(function()
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.createJob({ key = 'gardener', name = 'Gardener' })
        eq(#Jobs.admin.listJobs(), 2)
    end)
end)

test('updateJob: updates fields on an existing job', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.updateJob(jobId, { name = 'City Bus Driver' })
        eq(tables.jobs[1].name, 'City Bus Driver')
    end)
end)

test('deleteJob: removes the job and its levels/tasks/routes', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.upsertLevel(jobId, 1, 0, 'Rookie')
        Jobs.admin.upsertTask(jobId, 'drop_off_passenger', 50, 10)
        Jobs.admin.upsertRoute(jobId, 'Downtown Loop', 1, {})

        Jobs.admin.deleteJob(jobId)

        eq(#tables.jobs, 0)
        eq(#tables.job_levels, 0)
        eq(#tables.job_tasks, 0)
        eq(#tables.bus_routes, 0)
    end)
end)

test('upsertLevel: inserts a new level', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local levelId = Jobs.admin.upsertLevel(jobId, 1, 0, 'Rookie')
        eq(#tables.job_levels, 1)
        eq(tables.job_levels[1].id, levelId)
        eq(tables.job_levels[1].xp_required, 0)
    end)
end)

test('upsertLevel: updates the existing row for the same job_id+level', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local firstId = Jobs.admin.upsertLevel(jobId, 1, 0, 'Rookie')
        local secondId = Jobs.admin.upsertLevel(jobId, 1, 100, 'Rookie Driver')

        eq(secondId, firstId)
        eq(#tables.job_levels, 1)
        eq(tables.job_levels[1].xp_required, 100)
        eq(tables.job_levels[1].label, 'Rookie Driver')
    end)
end)

test('deleteLevel: removes only the targeted level', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.upsertLevel(jobId, 1, 0, 'Rookie')
        local level2Id = Jobs.admin.upsertLevel(jobId, 2, 500, 'Veteran')

        Jobs.admin.deleteLevel(level2Id)

        eq(#tables.job_levels, 1)
        eq(tables.job_levels[1].level, 1)
    end)
end)

test('upsertTask: inserts, then updates the existing row for the same job_id+task_key', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local firstId = Jobs.admin.upsertTask(jobId, 'drop_off_passenger', 50, 10)
        local secondId = Jobs.admin.upsertTask(jobId, 'drop_off_passenger', 75, 15)

        eq(secondId, firstId)
        eq(#tables.job_tasks, 1)
        eq(tables.job_tasks[1].pay_amount, 75)
        eq(tables.job_tasks[1].xp_amount, 15)
    end)
end)

test('upsertRoute: inserts a route with its stops', function()
    withFakeDb(function(tables)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local stops = { { x = 1, y = 2, z = 3, label = 'Stop A' } }
        local routeId = Jobs.admin.upsertRoute(jobId, 'Downtown Loop', 2, stops)

        eq(#tables.bus_routes, 1)
        eq(tables.bus_routes[1].id, routeId)
        eq(tables.bus_routes[1].min_level, 2)
        eq(#tables.bus_routes[1].stops, 1)
    end)
end)

test('listTasks/listRoutes: scoped to the given job', function()
    withFakeDb(function()
        local jobA = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local jobB = Jobs.admin.createJob({ key = 'gardener', name = 'Gardener' })
        Jobs.admin.upsertTask(jobA, 'drop_off_passenger', 50, 10)
        Jobs.admin.upsertTask(jobB, 'water_plants', 20, 5)

        eq(#Jobs.admin.listTasks(jobA), 1)
        eq(#Jobs.admin.listTasks(jobB), 1)
        eq(Jobs.admin.listTasks(jobA)[1].task_key, 'drop_off_passenger')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
    end
end

print(string.format('%d/%d tests passed', passed, #tests))
if #failures > 0 then
    for _, f in ipairs(failures) do
        print(string.format('FAIL: %s\n  %s', f.name, f.err))
    end
    os.exit(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_service_crud_spec.lua`
Expected: FAIL — `attempt to index a nil value (global 'Jobs')` (service doesn't exist yet).

- [ ] **Step 3: Write the implementation**

`core/modules/oblsk_jobs/server/services/JobService.lua`:

```lua
--- JobService (Jobs.admin.*) - admin CRUD for job definitions, levels,
--- tasks, and bus routes. See
--- docs/superpowers/specs/2026-08-16-jobs-module-design.md.
Jobs = Jobs or {}
Jobs.admin = Jobs.admin or {}

--- @return table[] every jobs row
function Jobs.admin.listJobs()
    return QueryBuilder.new('jobs'):getSync()
end

--- @param attrs table { key, name, icon?, description?, active? }
--- @return number jobId
function Jobs.admin.createJob(attrs)
    return Job:createSync({
        key = attrs.key,
        name = attrs.name,
        icon = attrs.icon,
        description = attrs.description,
        active = attrs.active == nil and 1 or attrs.active,
    }):get('id')
end

--- @param jobId number
--- @param attrs table fields to update
function Jobs.admin.updateJob(jobId, attrs)
    attrs.updated_at = Database.now()
    Job:where('id', jobId):update(attrs)
end

--- Cascades: removes this job's levels, tasks, routes, and character
--- progress/active-job rows, so nothing is left pointing at a deleted
--- job_id.
--- @param jobId number
function Jobs.admin.deleteJob(jobId)
    JobLevel:where('job_id', jobId):delete()
    JobTask:where('job_id', jobId):delete()
    BusRoute:where('job_id', jobId):delete()
    CharacterJobProgress:where('job_id', jobId):delete()
    CharacterActiveJob:where('job_id', jobId):delete()
    Job:where('id', jobId):delete()
end

--- @param jobId number
--- @return table[]
function Jobs.admin.listLevels(jobId)
    return JobLevel:where('job_id', jobId):getSync()
end

--- Inserts a new level, or updates the existing row for this job_id+level.
--- @param jobId number
--- @param level number
--- @param xpRequired number
--- @param label string|nil
--- @return number levelId
function Jobs.admin.upsertLevel(jobId, level, xpRequired, label)
    local existing = JobLevel:where('job_id', jobId):where('level', level):firstSync()
    if existing then
        JobLevel:where('id', existing.id):update({
            xp_required = xpRequired,
            label = label,
            updated_at = Database.now(),
        })
        return existing.id
    end

    return JobLevel:createSync({
        job_id = jobId,
        level = level,
        xp_required = xpRequired,
        label = label,
    }):get('id')
end

--- @param levelId number
function Jobs.admin.deleteLevel(levelId)
    JobLevel:where('id', levelId):delete()
end

--- @param jobId number
--- @return table[]
function Jobs.admin.listTasks(jobId)
    return JobTask:where('job_id', jobId):getSync()
end

--- Inserts a new task, or updates the existing row for this
--- job_id+task_key.
--- @param jobId number
--- @param taskKey string
--- @param payAmount number
--- @param xpAmount number
--- @return number taskId
function Jobs.admin.upsertTask(jobId, taskKey, payAmount, xpAmount)
    local existing = JobTask:where('job_id', jobId):where('task_key', taskKey):firstSync()
    if existing then
        JobTask:where('id', existing.id):update({
            pay_amount = payAmount,
            xp_amount = xpAmount,
            updated_at = Database.now(),
        })
        return existing.id
    end

    return JobTask:createSync({
        job_id = jobId,
        task_key = taskKey,
        pay_amount = payAmount,
        xp_amount = xpAmount,
    }):get('id')
end

--- @param taskId number
function Jobs.admin.deleteTask(taskId)
    JobTask:where('id', taskId):delete()
end

--- @param jobId number
--- @return table[]
function Jobs.admin.listRoutes(jobId)
    return BusRoute:where('job_id', jobId):getSync()
end

--- @param jobId number
--- @param name string
--- @param minLevel number
--- @param stops table ordered array of {x,y,z,label}
--- @return number routeId
function Jobs.admin.upsertRoute(jobId, name, minLevel, stops)
    return BusRoute:createSync({
        job_id = jobId,
        name = name,
        min_level = minLevel,
        stops = stops,
    }):get('id')
end

--- @param routeId number
function Jobs.admin.deleteRoute(routeId)
    BusRoute:where('id', routeId):delete()
end

return Jobs
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_service_crud_spec.lua`
Expected: `10/10 tests passed`

- [ ] **Step 5: Commit**

```bash
git add core/modules/oblsk_jobs/server/services/JobService.lua core/modules/oblsk_jobs/tests
git commit -m "feat(jobs): add JobService admin CRUD for jobs/levels/tasks/routes"
```

---

## Task 3: JobProgressService — on-duty state, single-active-job enforcement

**Files:**
- Create: `core/modules/oblsk_jobs/server/services/JobProgressService.lua`
- Create: `core/modules/oblsk_jobs/tests/job_progress_service_duty_spec.lua`

**Interfaces:**
- Consumes: `Job`, `CharacterActiveJob` models (Task 1); global `Jobs` table (Task 2, extended here).
- Produces:
  - `Jobs.goOnDuty(characterId, jobKey)` → `boolean ok, string|nil reason`. Rejects with `'Job not found'` if no active job matches `jobKey`, or `'Already on duty for another job'` if `character_active_job` has a row for a *different* `job_id`. Idempotent if already on duty for the same job.
  - `Jobs.goOffDuty(characterId)` → deletes the character's `character_active_job` row (no-op if none).
  - `Jobs.getActiveJob(characterId)` → `string|nil` the active job's `key`, or nil if off-duty.

  These take `characterId` directly (not a `Player`) — callers in job plugins resolve `characterId` via `CharacterService.getActiveCharacterId(player:getSource())` first, same as `CraftingService.start` does with `source`. This keeps the module testable without any FiveM/Player stubbing.

- [ ] **Step 1: Write the failing test**

`core/modules/oblsk_jobs/tests/job_progress_service_duty_spec.lua`:

```lua
--- Unit tests for JobProgressService (Jobs.goOnDuty/goOffDuty/getActiveJob).
--- Run from the repository root: lua5.4 core/modules/oblsk_jobs/tests/job_progress_service_duty_spec.lua
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
dofile(scriptDir .. '../server/models/Job.lua')
dofile(scriptDir .. '../server/models/JobLevel.lua')
dofile(scriptDir .. '../server/models/JobTask.lua')
dofile(scriptDir .. '../server/models/BusRoute.lua')
dofile(scriptDir .. '../server/models/CharacterJobProgress.lua')
dofile(scriptDir .. '../server/models/CharacterActiveJob.lua')
dofile(scriptDir .. '../server/services/JobService.lua')
dofile(scriptDir .. '../server/services/JobProgressService.lua')

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

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('goOnDuty: sets the active job for a character with none', function()
    withFakeDb(function()
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local ok, reason = Jobs.goOnDuty(1, 'busdriver')
        eq(ok, true)
        eq(reason, nil)
        eq(Jobs.getActiveJob(1), 'busdriver')
    end)
end)

test('goOnDuty: unknown job key fails', function()
    withFakeDb(function()
        local ok, reason = Jobs.goOnDuty(1, 'nonexistent')
        eq(ok, false)
        eq(reason, 'Job not found')
    end)
end)

test('goOnDuty: idempotent when already on duty for the same job', function()
    withFakeDb(function(tables)
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.goOnDuty(1, 'busdriver')
        local ok = Jobs.goOnDuty(1, 'busdriver')
        eq(ok, true)
        eq(#tables.character_active_job, 1)
    end)
end)

test('goOnDuty: rejects switching to a different job while on duty', function()
    withFakeDb(function()
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.createJob({ key = 'gardener', name = 'Gardener' })
        Jobs.goOnDuty(1, 'busdriver')

        local ok, reason = Jobs.goOnDuty(1, 'gardener')

        eq(ok, false)
        eq(reason, 'Already on duty for another job')
        eq(Jobs.getActiveJob(1), 'busdriver')
    end)
end)

test('goOffDuty: clears the active job', function()
    withFakeDb(function()
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.goOnDuty(1, 'busdriver')
        Jobs.goOffDuty(1)
        eq(Jobs.getActiveJob(1), nil)
    end)
end)

test('goOffDuty: no-op when not on duty', function()
    withFakeDb(function(tables)
        Jobs.goOffDuty(1)
        eq(#tables.character_active_job, 0)
    end)
end)

test('getActiveJob: two characters track independently', function()
    withFakeDb(function()
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.createJob({ key = 'gardener', name = 'Gardener' })
        Jobs.goOnDuty(1, 'busdriver')
        Jobs.goOnDuty(2, 'gardener')

        eq(Jobs.getActiveJob(1), 'busdriver')
        eq(Jobs.getActiveJob(2), 'gardener')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
    end
end

print(string.format('%d/%d tests passed', passed, #tests))
if #failures > 0 then
    for _, f in ipairs(failures) do
        print(string.format('FAIL: %s\n  %s', f.name, f.err))
    end
    os.exit(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_progress_service_duty_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'goOnDuty')`.

- [ ] **Step 3: Write the implementation**

`core/modules/oblsk_jobs/server/services/JobProgressService.lua`:

```lua
--- JobProgressService (Jobs.goOnDuty/goOffDuty/getActiveJob/completeTask/
--- getProgress/getRoutes) - on-duty state, XP/level, and payout. Extends
--- the same global `Jobs` table JobService.lua defines. See
--- docs/superpowers/specs/2026-08-16-jobs-module-design.md.
Jobs = Jobs or {}

--- @param jobKey string
--- @return table|nil jobs row
local function findJobByKey(jobKey)
    return Job:where('key', jobKey):firstSync()
end

--- @param characterId number
--- @param jobKey string
--- @return boolean ok
--- @return string|nil reason
function Jobs.goOnDuty(characterId, jobKey)
    local job = findJobByKey(jobKey)
    if not job then
        return false, 'Job not found'
    end

    local existing = CharacterActiveJob:where('character_id', characterId):firstSync()
    if existing then
        if existing.job_id == job.id then
            return true
        end
        return false, 'Already on duty for another job'
    end

    CharacterActiveJob:createSync({ character_id = characterId, job_id = job.id })
    return true
end

--- @param characterId number
function Jobs.goOffDuty(characterId)
    CharacterActiveJob:where('character_id', characterId):delete()
end

--- @param characterId number
--- @return string|nil the active job's key, or nil if off-duty
function Jobs.getActiveJob(characterId)
    local active = CharacterActiveJob:where('character_id', characterId):firstSync()
    if not active then
        return nil
    end

    local job = Job:where('id', active.job_id):firstSync()
    return job and job.key or nil
end

return Jobs
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_progress_service_duty_spec.lua`
Expected: `7/7 tests passed`

- [ ] **Step 5: Commit**

```bash
git add core/modules/oblsk_jobs/server/services/JobProgressService.lua core/modules/oblsk_jobs/tests/job_progress_service_duty_spec.lua
git commit -m "feat(jobs): add on-duty state with single-active-job enforcement"
```

---

## Task 4: JobProgressService — completeTask (pay, XP, level-up) and getProgress

**Files:**
- Modify: `core/modules/oblsk_jobs/server/services/JobProgressService.lua`
- Create: `core/modules/oblsk_jobs/tests/job_progress_service_task_spec.lua`

**Interfaces:**
- Consumes: `Jobs.getActiveJob` (Task 3); `Jobs.admin.listTasks`/model rows (Task 2); `ItemService.binding`/`ItemService.add` (existing `oblsk_items` module — same pattern as `BankingService.deposit`, `SafeCrackingService`).
- Produces:
  - `Jobs.completeTask(characterId, source, jobKey, taskKey)` → `boolean ok, string|nil reason`. Rejects `'Not on duty for this job'` if `Jobs.getActiveJob(characterId) ~= jobKey`, `'Unknown task'` if no `job_tasks` row matches, `'Cash payouts are not available on this server'` if the `currency.cash` binding is unset. On success: credits `pay_amount` cash to `source` via `ItemService.add`, adds `xp_amount` to `character_job_progress` (creating the row if absent), recomputes `level` against `job_levels` thresholds, and returns `true`.

    Takes both `characterId` and `source` (unlike `goOnDuty`/`goOffDuty`, which only need `characterId`) because paying cash requires `ItemService.add(source, ...)` — `source` is the numeric player id, `characterId` is already resolved by the caller. Job plugins have both on hand from `player:getSource()` + `CharacterService.getActiveCharacterId(source)`, same as `CraftingService.start`.
  - `Jobs.getProgress(characterId, jobKey)` → `table {xp, level}`, defaulting to `{xp = 0, level = 1}` if no progress row exists yet.

- [ ] **Step 1: Write the failing test**

`core/modules/oblsk_jobs/tests/job_progress_service_task_spec.lua`:

```lua
--- Unit tests for JobProgressService.completeTask/getProgress: payout, XP
--- accumulation, level-up.
--- Run from the repository root: lua5.4 core/modules/oblsk_jobs/tests/job_progress_service_task_spec.lua
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
dofile(scriptDir .. '../server/models/Job.lua')
dofile(scriptDir .. '../server/models/JobLevel.lua')
dofile(scriptDir .. '../server/models/JobTask.lua')
dofile(scriptDir .. '../server/models/BusRoute.lua')
dofile(scriptDir .. '../server/models/CharacterJobProgress.lua')
dofile(scriptDir .. '../server/models/CharacterActiveJob.lua')
dofile(scriptDir .. '../server/services/JobService.lua')
dofile(scriptDir .. '../server/services/JobProgressService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

--- Fakes ItemService.binding/add so this spec doesn't need real item rows.
--- addedCash accumulates every ItemService.add(source, cash, amount) call
--- so tests can assert on payout amounts.
local function withFakeDbAndItems(fn)
    local tables = {}
    local originalQB = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local addedCash = {}
    local originalItemService = ItemService
    ItemService = {
        binding = function(key)
            if key == 'currency.cash' then return { id = 1, name = 'cash' } end
            return nil
        end,
        add = function(source, item, amount)
            addedCash[#addedCash + 1] = { source = source, amount = amount }
            return true
        end,
    }

    local ok, err = pcall(fn, tables, addedCash)

    QueryBuilder = originalQB
    ItemService = originalItemService
    if not ok then error(err, 2) end
end

test('completeTask: rejects when not on duty for that job', function()
    withFakeDbAndItems(function()
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local ok, reason = Jobs.completeTask(1, 101, 'busdriver', 'drop_off_passenger')
        eq(ok, false)
        eq(reason, 'Not on duty for this job')
    end)
end)

test('completeTask: rejects an unknown task_key', function()
    withFakeDbAndItems(function()
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.goOnDuty(1, 'busdriver')
        local ok, reason = Jobs.completeTask(1, 101, 'busdriver', 'nonexistent')
        eq(ok, false)
        eq(reason, 'Unknown task')
    end)
end)

test('completeTask: pays cash and grants XP', function()
    withFakeDbAndItems(function(_, addedCash)
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.upsertTask(jobId, 'drop_off_passenger', 50, 10)
        Jobs.goOnDuty(1, 'busdriver')

        local ok = Jobs.completeTask(1, 101, 'busdriver', 'drop_off_passenger')

        eq(ok, true)
        eq(#addedCash, 1)
        eq(addedCash[1].source, 101)
        eq(addedCash[1].amount, 50)
        eq(Jobs.getProgress(1, 'busdriver').xp, 10)
    end)
end)

test('completeTask: accumulates XP across multiple tasks', function()
    withFakeDbAndItems(function()
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.upsertTask(jobId, 'drop_off_passenger', 50, 10)
        Jobs.goOnDuty(1, 'busdriver')

        Jobs.completeTask(1, 101, 'busdriver', 'drop_off_passenger')
        Jobs.completeTask(1, 101, 'busdriver', 'drop_off_passenger')

        eq(Jobs.getProgress(1, 'busdriver').xp, 20)
    end)
end)

test('completeTask: crossing an xp_required threshold levels up', function()
    withFakeDbAndItems(function()
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.upsertLevel(jobId, 1, 0, 'Rookie')
        Jobs.admin.upsertLevel(jobId, 2, 20, 'Veteran')
        Jobs.admin.upsertTask(jobId, 'drop_off_passenger', 50, 10)
        Jobs.goOnDuty(1, 'busdriver')

        eq(Jobs.getProgress(1, 'busdriver').level, 1)

        Jobs.completeTask(1, 101, 'busdriver', 'drop_off_passenger')
        eq(Jobs.getProgress(1, 'busdriver').level, 1)

        Jobs.completeTask(1, 101, 'busdriver', 'drop_off_passenger')
        eq(Jobs.getProgress(1, 'busdriver').xp, 20)
        eq(Jobs.getProgress(1, 'busdriver').level, 2)
    end)
end)

test('getProgress: defaults to xp=0, level=1 with no progress row', function()
    withFakeDbAndItems(function()
        Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        local progress = Jobs.getProgress(1, 'busdriver')
        eq(progress.xp, 0)
        eq(progress.level, 1)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
    end
end

print(string.format('%d/%d tests passed', passed, #tests))
if #failures > 0 then
    for _, f in ipairs(failures) do
        print(string.format('FAIL: %s\n  %s', f.name, f.err))
    end
    os.exit(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_progress_service_task_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'completeTask')`.

- [ ] **Step 3: Write the implementation**

Append to `core/modules/oblsk_jobs/server/services/JobProgressService.lua` (after `Jobs.getActiveJob`, before the final `return Jobs`):

```lua
--- @param jobId number
--- @param xp number total accumulated xp
--- @return number the highest level whose xp_required <= xp (defaults to 1
---   if the job has no levels defined, or none are reached yet)
local function levelForXp(jobId, xp)
    local levels = JobLevel:where('job_id', jobId):getSync()
    local best = 1
    for _, lvl in ipairs(levels) do
        if lvl.xp_required <= xp and lvl.level > best then
            best = lvl.level
        end
    end
    return best
end

--- @param characterId number
--- @param jobKey string
--- @return table {xp, level}
function Jobs.getProgress(characterId, jobKey)
    local job = findJobByKey(jobKey)
    if not job then
        return { xp = 0, level = 1 }
    end

    local progress = CharacterJobProgress
        :where('character_id', characterId):where('job_id', job.id):firstSync()
    if not progress then
        return { xp = 0, level = 1 }
    end

    return { xp = progress.xp, level = progress.level }
end

--- @param characterId number
--- @param source number player server id, used to credit cash
--- @param jobKey string
--- @param taskKey string
--- @return boolean ok
--- @return string|nil reason
function Jobs.completeTask(characterId, source, jobKey, taskKey)
    if Jobs.getActiveJob(characterId) ~= jobKey then
        return false, 'Not on duty for this job'
    end

    local job = findJobByKey(jobKey)
    local task = JobTask:where('job_id', job.id):where('task_key', taskKey):firstSync()
    if not task then
        return false, 'Unknown task'
    end

    local cash = ItemService.binding('currency.cash')
    if not cash then
        return false, 'Cash payouts are not available on this server'
    end

    ItemService.add(source, cash, task.pay_amount)

    local progress = CharacterJobProgress
        :where('character_id', characterId):where('job_id', job.id):firstSync()
    local newXp = (progress and progress.xp or 0) + task.xp_amount
    local newLevel = levelForXp(job.id, newXp)

    if progress then
        CharacterJobProgress:where('id', progress.id):update({
            xp = newXp,
            level = newLevel,
            updated_at = Database.now(),
        })
    else
        CharacterJobProgress:createSync({
            character_id = characterId,
            job_id = job.id,
            xp = newXp,
            level = newLevel,
        })
    end

    return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_progress_service_task_spec.lua`
Expected: `6/6 tests passed`

Also re-run the earlier specs to confirm nothing broke:

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_service_crud_spec.lua && lua5.4 core/modules/oblsk_jobs/tests/job_progress_service_duty_spec.lua`
Expected: both print all-passed with no `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
git add core/modules/oblsk_jobs/server/services/JobProgressService.lua core/modules/oblsk_jobs/tests/job_progress_service_task_spec.lua
git commit -m "feat(jobs): add completeTask payout/XP/level-up and getProgress"
```

---

## Task 5: getRoutes and module boot registration

**Files:**
- Modify: `core/modules/oblsk_jobs/server/services/JobProgressService.lua`
- Create: `core/modules/oblsk_jobs/server/main.lua`
- Modify: `core/modules/oblsk_jobs/tests/job_service_crud_spec.lua` (add coverage for `getRoutes`)

**Interfaces:**
- Consumes: `ItemService.registerRequirements` (existing `oblsk_items` API, same call `oblsk_doors`' `server/main.lua` makes at boot).
- Produces: `Jobs.getRoutes(jobKey)` → `table[]` every `bus_routes` row for that job (unfiltered by level — filtering by the requesting character's level is `oblsk_busdriver`'s job, since only it knows which character is asking).

- [ ] **Step 1: Write the failing test**

Add to `core/modules/oblsk_jobs/tests/job_service_crud_spec.lua`, immediately before the `for _, t in ipairs(tests) do` loop at the bottom:

```lua
test('getRoutes: returns every route for a job, unfiltered by level', function()
    withFakeDb(function()
        local jobId = Jobs.admin.createJob({ key = 'busdriver', name = 'Bus Driver' })
        Jobs.admin.upsertRoute(jobId, 'Downtown Loop', 1, {})
        Jobs.admin.upsertRoute(jobId, 'Airport Express', 5, {})

        eq(#Jobs.getRoutes('busdriver'), 2)
    end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_service_crud_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'getRoutes')`.

- [ ] **Step 3: Write the implementation**

Append to `core/modules/oblsk_jobs/server/services/JobProgressService.lua` (after `Jobs.completeTask`, before `return Jobs`):

```lua
--- @param jobKey string
--- @return table[] every bus_routes row for this job
function Jobs.getRoutes(jobKey)
    local job = findJobByKey(jobKey)
    if not job then
        return {}
    end
    return BusRoute:where('job_id', job.id):getSync()
end
```

`core/modules/oblsk_jobs/server/main.lua`:

```lua
--- oblsk_jobs - Server Main
--- Registers the currency.cash binding this module needs to pay out
--- completed tasks. Called directly at load (rather than via bootstrap's
--- static Config.Requires.bindings scan, which only covers plugins/) --
--- same approach as oblsk_doors' dynamic registerRequirements call.
print('[oblsk_jobs] Loading...')

ItemService.registerRequirements('oblsk_jobs', {
    ['currency.cash'] = { live = false, description = 'Job task payouts' },
})

print('[oblsk_jobs] Loaded successfully!')
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 core/modules/oblsk_jobs/tests/job_service_crud_spec.lua`
Expected: `11/11 tests passed`

- [ ] **Step 5: Commit**

```bash
git add core/modules/oblsk_jobs/server/services/JobProgressService.lua core/modules/oblsk_jobs/server/main.lua core/modules/oblsk_jobs/tests/job_service_crud_spec.lua
git commit -m "feat(jobs): add getRoutes and register currency.cash requirement at boot"
```

---

## Task 6: Admin relay — oblsk_admin/server/jobs.lua

**Files:**
- Create: `core/plugins/oblsk_admin/server/jobs.lua`

**Interfaces:**
- Consumes: `Jobs.admin.*` (Task 2/5).
- Produces: NUI-facing events for `JobsTab.vue` (Task 7): `admin:server:jobs-list` → replies `admin:client:jobs-reply` with `{ jobs }`; `admin:server:jobs-detail` → replies `admin:client:jobs-detail-reply` with `{ jobId, levels, tasks, routes }`; `admin:server:jobs-create`, `jobs-update`, `jobs-delete`; `admin:server:jobs-upsert-level`, `jobs-delete-level`; `admin:server:jobs-upsert-task`, `jobs-delete-task`; `admin:server:jobs-upsert-route`, `jobs-delete-route`. Every handler re-replies with the refreshed list/detail, same pattern as `items.lua`.

This task has no dedicated unit test — `oblsk_admin`'s other NUI relay files (`items.lua`, `moderation.lua`, etc.) have none either; they're verified through the admin panel UI itself (Task 7's manual check covers this file too, since `JobsTab.vue` can't be exercised without it).

- [ ] **Step 1: Write the relay file**

`core/plugins/oblsk_admin/server/jobs.lua`:

```lua
-- core/plugins/oblsk_admin/server/jobs.lua
--- oblsk_admin server: Jobs tab NUI handlers.
local function isAdmin(player)
    local source = player:getSource()
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

local function replyWithList(player)
    player:emit('admin:client:jobs-reply', { jobs = Jobs.admin.listJobs() })
end

local function replyWithDetail(player, jobId)
    player:emit('admin:client:jobs-detail-reply', {
        jobId = jobId,
        levels = Jobs.admin.listLevels(jobId),
        tasks = Jobs.admin.listTasks(jobId),
        routes = Jobs.admin.listRoutes(jobId),
    })
end

Obelisk.onClient('admin:server:jobs-list', function(player)
    if not isAdmin(player) then return end
    replyWithList(player)
end)

Obelisk.onClient('admin:server:jobs-detail', function(player, data)
    if not isAdmin(player) then return end
    replyWithDetail(player, data.jobId)
end)

Obelisk.onClient('admin:server:jobs-create', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.createJob(data.attributes or {})
    replyWithList(player)
end)

Obelisk.onClient('admin:server:jobs-update', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.updateJob(data.jobId, data.attributes or {})
    replyWithList(player)
end)

Obelisk.onClient('admin:server:jobs-delete', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.deleteJob(data.jobId)
    replyWithList(player)
end)

Obelisk.onClient('admin:server:jobs-upsert-level', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.upsertLevel(data.jobId, data.level, data.xpRequired, data.label)
    replyWithDetail(player, data.jobId)
end)

Obelisk.onClient('admin:server:jobs-delete-level', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.deleteLevel(data.levelId)
    replyWithDetail(player, data.jobId)
end)

Obelisk.onClient('admin:server:jobs-upsert-task', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.upsertTask(data.jobId, data.taskKey, data.payAmount, data.xpAmount)
    replyWithDetail(player, data.jobId)
end)

Obelisk.onClient('admin:server:jobs-delete-task', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.deleteTask(data.taskId)
    replyWithDetail(player, data.jobId)
end)

Obelisk.onClient('admin:server:jobs-upsert-route', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.upsertRoute(data.jobId, data.name, data.minLevel, data.stops or {})
    replyWithDetail(player, data.jobId)
end)

Obelisk.onClient('admin:server:jobs-delete-route', function(player, data)
    if not isAdmin(player) then return end
    Jobs.admin.deleteRoute(data.routeId)
    replyWithDetail(player, data.jobId)
end)
```

- [ ] **Step 2: Verify the file parses**

Run: `lua5.4 -e "assert(loadfile('core/plugins/oblsk_admin/server/jobs.lua'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add core/plugins/oblsk_admin/server/jobs.lua
git commit -m "feat(admin): add Jobs tab NUI relay"
```

---

## Task 7: Admin UI — JobsTab.vue

**Files:**
- Create: `core/plugins/oblsk_admin/web/JobsTab.vue`
- Modify: `core/plugins/oblsk_admin/web/AdminPanel.vue`

**Interfaces:**
- Consumes: the events Task 6 defines (`admin:client:jobs-reply`, `admin:client:jobs-detail-reply`) and emits (`admin:client:jobs-list`, `admin:client:jobs-detail`, `admin:client:jobs-create`, `admin:client:jobs-update`, `admin:client:jobs-delete`, `admin:client:jobs-upsert-level`, `admin:client:jobs-delete-level`, `admin:client:jobs-upsert-task`, `admin:client:jobs-delete-task`, `admin:client:jobs-upsert-route`, `admin:client:jobs-delete-route`) via `Obelisk.emit`/`Obelisk.on`, same as `ItemsTab.vue` does for the `admin:*:items-*` events.
- Produces: a `'jobs'` entry in `AdminPanel.vue`'s `TABS` array and render block, following `ItemsTab`'s wiring exactly.

- [ ] **Step 1: Write JobsTab.vue**

`core/plugins/oblsk_admin/web/JobsTab.vue`:

```vue
<!-- plugins/oblsk_admin/web/JobsTab.vue -->
<script setup>
import { ref, computed, onMounted, onBeforeUnmount, inject, watch } from 'vue'
import Obelisk from '@/obelisk.js'

const jobs = ref([])
const selectedId = ref(null)
const detail = ref({ levels: [], tasks: [], routes: [] })
const createDraft = ref(null)

const selected = computed(() => jobs.value.find(j => j.id === selectedId.value) || null)

const DEV_JOBS = [
  { id: 1, key: 'busdriver', name: 'Bus Driver', icon: 'bus', description: 'Drive scheduled routes.', active: 1 },
  { id: 2, key: 'gardener', name: 'Gardener', icon: 'leaf', description: 'Tend to public greenery.', active: 1 },
]
const DEV_DETAIL = {
  levels: [{ id: 1, level: 1, xp_required: 0, label: 'Rookie' }, { id: 2, level: 2, xp_required: 500, label: 'Veteran' }],
  tasks: [{ id: 1, task_key: 'drop_off_passenger', pay_amount: 50, xp_amount: 10 }],
  routes: [{ id: 1, name: 'Downtown Loop', min_level: 1, stops: [] }],
}

const fetchList = () => {
  if (import.meta.env.DEV) { jobs.value = DEV_JOBS; return }
  Obelisk.emit('admin:client:jobs-list', {})
}

const fetchDetail = (jobId) => {
  if (import.meta.env.DEV) { detail.value = DEV_DETAIL; return }
  Obelisk.emit('admin:client:jobs-detail', { jobId })
}

const selectJob = (job) => {
  selectedId.value = job.id
  fetchDetail(job.id)
}

const onListReply = ({ jobs: next }) => { jobs.value = next }
const onDetailReply = ({ levels, tasks, routes }) => { detail.value = { levels, tasks, routes } }

onMounted(() => {
  Obelisk.on('admin:client:jobs-reply', onListReply)
  Obelisk.on('admin:client:jobs-detail-reply', onDetailReply)
  fetchList()
})
onBeforeUnmount(() => {
  Obelisk.off('admin:client:jobs-reply', onListReply)
  Obelisk.off('admin:client:jobs-detail-reply', onDetailReply)
})

const registry = inject('obelisk:globalElementsRegistry', null)
if (registry) {
  watch(() => registry.get('admin')?.visible, (visible) => { if (visible) fetchList() })
}

const openCreate = () => { createDraft.value = { key: '', name: '', icon: '', description: '' } }
const submitCreate = () => {
  Obelisk.emit('admin:client:jobs-create', { attributes: createDraft.value })
  createDraft.value = null
}
const deleteJob = (job) => {
  Obelisk.emit('admin:client:jobs-delete', { jobId: job.id })
  if (selectedId.value === job.id) selectedId.value = null
}

const levelDraft = ref(null)
const openAddLevel = () => { levelDraft.value = { level: (detail.value.levels.length + 1), xpRequired: 0, label: '' } }
const submitLevel = () => {
  Obelisk.emit('admin:client:jobs-upsert-level', { jobId: selectedId.value, ...levelDraft.value })
  levelDraft.value = null
}
const deleteLevel = (level) => Obelisk.emit('admin:client:jobs-delete-level', { jobId: selectedId.value, levelId: level.id })

const taskDraft = ref(null)
const openAddTask = () => { taskDraft.value = { taskKey: '', payAmount: 0, xpAmount: 0 } }
const submitTask = () => {
  Obelisk.emit('admin:client:jobs-upsert-task', { jobId: selectedId.value, ...taskDraft.value })
  taskDraft.value = null
}
const deleteTask = (task) => Obelisk.emit('admin:client:jobs-delete-task', { jobId: selectedId.value, taskId: task.id })

const routeDraft = ref(null)
const openAddRoute = () => { routeDraft.value = { name: '', minLevel: 1, stops: [] } }
const submitRoute = () => {
  Obelisk.emit('admin:client:jobs-upsert-route', { jobId: selectedId.value, ...routeDraft.value })
  routeDraft.value = null
}
const deleteRoute = (route) => Obelisk.emit('admin:client:jobs-delete-route', { jobId: selectedId.value, routeId: route.id })
</script>

<template>
  <div class="grid gap-3 min-h-0 p-5" style="grid-template-columns: 300px 1fr">
    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-hidden flex flex-col">
      <div class="px-4 py-2.5 border-b border-white/8 flex items-center justify-between">
        <span class="text-[12.5px] font-medium">Jobs · {{ jobs.length }}</span>
        <button class="text-[11px] text-white/60 hover:text-white" @click="openCreate">+ New</button>
      </div>
      <div class="overflow-y-auto flex-1">
        <button v-for="job in jobs" :key="job.id" @click="selectJob(job)"
          class="w-full text-left px-4 py-2.5 border-b border-white/5 hover:bg-white/5"
          :class="selectedId === job.id ? 'bg-white/8' : ''">
          <div class="text-[13px] font-medium">{{ job.name }}</div>
          <div class="text-[11px] text-white/45">{{ job.key }}</div>
        </button>
      </div>
    </div>

    <div v-if="createDraft" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 flex flex-col gap-2">
      <input v-model="createDraft.key" placeholder="key (e.g. busdriver)" class="bg-white/5 rounded px-2 py-1 text-[12px]" />
      <input v-model="createDraft.name" placeholder="Name" class="bg-white/5 rounded px-2 py-1 text-[12px]" />
      <input v-model="createDraft.icon" placeholder="Icon" class="bg-white/5 rounded px-2 py-1 text-[12px]" />
      <input v-model="createDraft.description" placeholder="Description" class="bg-white/5 rounded px-2 py-1 text-[12px]" />
      <div class="flex gap-2">
        <button class="text-[11px] px-2 py-1 rounded" style="background: var(--ob-accent)" @click="submitCreate">Create</button>
        <button class="text-[11px] px-2 py-1 rounded bg-white/10" @click="createDraft = null">Cancel</button>
      </div>
    </div>

    <div v-else-if="selected" class="rounded-xl border border-white/10 bg-white/[0.03] overflow-y-auto flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between">
        <div class="text-[14px] font-medium">{{ selected.name }}</div>
        <button class="text-[11px] text-red-400 hover:text-red-300" @click="deleteJob(selected)">Delete job</button>
      </div>

      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-[12px] font-medium text-white/70">Levels</span>
          <button class="text-[11px] text-white/60 hover:text-white" @click="openAddLevel">+ Add</button>
        </div>
        <div v-for="lvl in detail.levels" :key="lvl.id" class="flex items-center justify-between text-[12px] py-1 border-b border-white/5">
          <span>Lvl {{ lvl.level }} — {{ lvl.label }} ({{ lvl.xp_required }} xp)</span>
          <button class="text-white/40 hover:text-red-300" @click="deleteLevel(lvl)">×</button>
        </div>
        <div v-if="levelDraft" class="flex gap-2 mt-2">
          <input v-model.number="levelDraft.level" type="number" class="w-14 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <input v-model.number="levelDraft.xpRequired" type="number" placeholder="xp" class="w-20 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <input v-model="levelDraft.label" placeholder="label" class="flex-1 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <button class="text-[11px] px-2 rounded" style="background: var(--ob-accent)" @click="submitLevel">Save</button>
        </div>
      </div>

      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-[12px] font-medium text-white/70">Tasks</span>
          <button class="text-[11px] text-white/60 hover:text-white" @click="openAddTask">+ Add</button>
        </div>
        <div v-for="t in detail.tasks" :key="t.id" class="flex items-center justify-between text-[12px] py-1 border-b border-white/5">
          <span>{{ t.task_key }} — ${{ t.pay_amount }} / {{ t.xp_amount }} xp</span>
          <button class="text-white/40 hover:text-red-300" @click="deleteTask(t)">×</button>
        </div>
        <div v-if="taskDraft" class="flex gap-2 mt-2">
          <input v-model="taskDraft.taskKey" placeholder="task_key" class="flex-1 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <input v-model.number="taskDraft.payAmount" type="number" placeholder="pay" class="w-16 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <input v-model.number="taskDraft.xpAmount" type="number" placeholder="xp" class="w-16 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <button class="text-[11px] px-2 rounded" style="background: var(--ob-accent)" @click="submitTask">Save</button>
        </div>
      </div>

      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-[12px] font-medium text-white/70">Bus routes</span>
          <button class="text-[11px] text-white/60 hover:text-white" @click="openAddRoute">+ Add</button>
        </div>
        <div v-for="r in detail.routes" :key="r.id" class="flex items-center justify-between text-[12px] py-1 border-b border-white/5">
          <span>{{ r.name }} — min lvl {{ r.min_level }} ({{ (r.stops || []).length }} stops)</span>
          <button class="text-white/40 hover:text-red-300" @click="deleteRoute(r)">×</button>
        </div>
        <div v-if="routeDraft" class="flex gap-2 mt-2">
          <input v-model="routeDraft.name" placeholder="Route name" class="flex-1 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <input v-model.number="routeDraft.minLevel" type="number" placeholder="min lvl" class="w-20 bg-white/5 rounded px-2 py-1 text-[12px]" />
          <button class="text-[11px] px-2 rounded" style="background: var(--ob-accent)" @click="submitRoute">Save</button>
        </div>
      </div>
    </div>

    <div v-else class="rounded-xl border border-white/10 bg-white/[0.03] flex items-center justify-center text-white/40 text-[12px]">
      Select a job
    </div>
  </div>
</template>
```

- [ ] **Step 2: Wire into AdminPanel.vue**

In `core/plugins/oblsk_admin/web/AdminPanel.vue`, add the import after `import ItemsTab from './ItemsTab.vue'` (line 10):

```js
import JobsTab from './JobsTab.vue'
```

Add `['jobs', 'Jobs']` to the `TABS` array (after `['items', 'Items']`):

```js
const TABS = [
  ['players', 'Players'], ['moderation', 'Moderation'], ['organisations', 'Organisations'],
  ['vehicles', 'Vehicles'], ['interactions', 'Interactions'], ['blips', 'Blips'],
  ['locations', 'Locations'], ['items', 'Items'], ['jobs', 'Jobs'], ['fishing', 'Fishing'], ['printers', 'Printers'], ['economy', 'Economy'],
  ['server', 'Server'], ['audit', 'Audit log'],
]
```

Add the render branch after `<ItemsTab v-else-if="activeTab === 'items'" />`:

```html
<JobsTab v-else-if="activeTab === 'jobs'" />
```

- [ ] **Step 3: Manually verify in the dev server**

Run: `cd core/web && npm run dev` (or the project's existing dev-server command — check `core/web/package.json` scripts if `dev` isn't present), then open the Admin panel route in a browser and click the Jobs tab.

Expected: the two `DEV_JOBS` fixture rows render in the left list; clicking one shows the `DEV_DETAIL` fixture's levels/tasks/routes in the right panel; the "+ New"/"+ Add" buttons open their inline forms without console errors.

- [ ] **Step 4: Commit**

```bash
git add core/plugins/oblsk_admin/web/JobsTab.vue core/plugins/oblsk_admin/web/AdminPanel.vue
git commit -m "feat(admin): add Jobs tab UI for job/level/task/route CRUD"
```

---

## Plan Self-Review Notes

- **Spec coverage:** data model (Task 1), server API incl. `Jobs.admin.*`/`Jobs.goOnDuty`/`goOffDuty`/`getActiveJob`/`completeTask`/`getProgress`/`getRoutes` (Tasks 2–5), admin UI (Tasks 6–7), testing list from the spec is covered by Tasks 2–4's specs (CRUD, on-duty/switch-rejected/off-duty, completeTask pay/xp/level-up). The spec's "reconnect restores active job" test is intentionally **not** a separate task — Global Constraints explains why: the module holds no in-memory session state, so there's nothing to restore; `Jobs.getActiveJob` reading the DB *is* the reconnect behavior, already covered by Task 3's persistence-across-calls tests.
- **Type consistency:** `Jobs.goOnDuty`/`goOffDuty`/`getActiveJob`/`getProgress` take `characterId`; `Jobs.completeTask` additionally takes `source` for the `ItemService.add` call — called out explicitly in Task 4's Interfaces block so a reader of Task 6 (which calls none of these directly — that's for `oblsk_busdriver` later) isn't surprised.
- **No placeholders:** every step has full code, no TODOs.
