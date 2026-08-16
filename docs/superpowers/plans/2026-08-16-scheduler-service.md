# Core Scheduler Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a core Scheduler service — DB-configured, admin-editable scheduled jobs (interval or cron) that run an existing `ActionService`-registered action when due — so future work (starting with a 24/7/ATM/clothes-shop restock job) has a shared mechanism instead of every plugin hand-rolling its own `Citizen.CreateThread` poll loop.

**Architecture:** Two new core service files (`SchedulerService.lua`, `CronExpression.lua`) under `core/core/server/Services/` (core-tracked, no nested-repo complexity, auto-loaded by the existing `core/server/Services/*.lua` glob in `core/fxmanifest.lua` — no manifest edit needed). One new core migration (`scheduled_jobs` table). A boot-time tick loop wired explicitly from `bootstrap.lua` (NOT a top-level `Citizen.CreateThread` inside the service file itself — see the Task 4 rationale, this matters for testability). Admin UI in `oblsk_admin`, following the exact same server-relay + client-relay + Vue-tab pattern as the recently-shipped Jobs tab.

**Tech Stack:** Lua 5.4 (FXServer), the framework's own ORM (`QueryBuilder`/`Schema` — no `BaseModel`, core services use raw `QueryBuilder` for their own infra tables, matching `ActionService.lua`'s own `actions` table), Vue 3 (admin web), `lua5.4` CLI for running specs.

**Spec:** `core/docs/superpowers/specs/2026-08-16-scheduler-service-design.md`

## Global Constraints

- A scheduled job's work is an existing `ActionService.register`'d action — `scheduled_jobs.action_id` references `actions.action_id`. No new handler-registration API.
- Two schedule types sharing the same table and the same `action_id` column: `interval` (`interval_seconds`) and `cron` (`cron_expression`, standard 5-field: minute hour day month weekday, supporting `*`, numbers, comma-lists, ranges `a-b`, and steps `*/n`/`a-b/n`). No timezone handling — cron fields evaluate against the server process's local wall clock.
- Interval jobs self-heal after downtime (next tick just fires them since `last_run_at` is stale). Cron jobs do NOT catch up missed fires.
- Single ticking thread — one full pass over all rows, then sleep — so no concurrent/overlapping runs are possible by construction.
- `ActionService.execute(nil, actionId, {})` is how the scheduler invokes an action (no player). This only works safely for actions with no policy attached (`PolicyService.check` short-circuits to allow when a resource has zero attached policies, without ever touching the `player` argument) — scheduled actions must never have a policy attached.
- **Lesson from the jobs-module plan's final review**: that plan's admin-UI tasks never listed `oblsk_admin/client/main.lua` under Files, so the NUI relay bridge (`TAB_RELAYS`/`TAB_REPLIES`) was never wired and the whole tab silently did nothing end-to-end — caught only by the final whole-branch review, not any task review. This plan's admin task explicitly includes `client/main.lua` in its Files list for exactly that reason. Do not drop it.
- `oblsk_admin`'s working tree has other, unrelated, pre-existing uncommitted work sitting on top of a clean history (a routed-page admin-panel refactor). Any task touching a file that's part of that WIP (`client/main.lua`, `web/AdminPanel.vue` at minimum — check `git status --short` fresh at execution time, since this is ambient state from other concurrent work, not something this plan controls) MUST use a stash-isolate sequence (stash just that file, edit the clean version, commit, stash pop) rather than a plain edit+`git add`, so the unrelated WIP is never swept into a scheduler commit. Full sequence given in Task 5/6.

---

## Task 1: `scheduled_jobs` migration + SchedulerService CRUD

**Files:**
- Create: `core/server/database/migrations/2026_08_16_150000_create_scheduled_jobs_table.lua`
- Modify: `core/server/database/migrations.json`
- Create: `core/server/Services/SchedulerService.lua`
- Create: `tests/scheduler_service_spec.lua`

**Interfaces:**
- Produces: global `SchedulerService` table with `create(actionId, scheduleType, config)`, `update(id, attrs)`, `delete(id)`, `list()`. `config` is `{intervalSeconds = N}` or `{cronExpression = '...'}`. Later tasks (2, 3) add `isDue`/`tick`/`startTickLoop` to this same file/global.

- [ ] **Step 1: Write the migration**

`core/server/database/migrations/2026_08_16_150000_create_scheduled_jobs_table.lua`:

```lua
--- Migration: Create scheduled_jobs table
--- Admin-configured schedule for an existing ActionService-registered
--- action. action_id references actions.action_id (string), not a
--- foreign key to actions.id -- actions can be registered after this
--- migration runs (they're code-registered at plugin/module load time),
--- so there's nothing to FK against at migration time.
return {
    up = function()
        Schema.create('scheduled_jobs', function(table)
            table:id()
            table:string('action_id', 100)
            table:string('schedule_type', 20) -- 'interval' | 'cron'
            table:integer('interval_seconds'):nullable()
            table:string('cron_expression', 100):nullable()
            table:boolean('enabled'):default(1)
            table:integer('last_run_at'):nullable() -- unix epoch seconds, NOT a DATETIME string (Database.now() format) -- SchedulerService.isDue does plain numeric arithmetic against os.time()
            table:timestamps()

            table:index({'action_id'})
        end)

        print('[Migration] Created scheduled_jobs table')
    end,

    down = function()
        Schema.drop('scheduled_jobs')
        print('[Migration] Dropped scheduled_jobs table')
    end
}
```

- [ ] **Step 2: Register the migration**

Edit `core/server/database/migrations.json`, add `"2026_08_16_150000_create_scheduled_jobs_table"` as the last entry in the `migrations` array (after `"2026_08_15_095900_create_instance_buckets_table"`).

- [ ] **Step 3: Write the failing test**

`tests/scheduler_service_spec.lua`:

```lua
--- Unit tests for SchedulerService's CRUD (create/update/delete/list).
--- isDue/tick are covered in scheduler_service_tick_spec.lua (Task 3).
--- Run from the repository root: lua5.4 tests/scheduler_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/Services/SchedulerService.lua')

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

test('create: interval job inserts a row with interval_seconds set', function()
    withFakeDb(function(tables)
        local id = SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        eq(#tables.scheduled_jobs, 1)
        eq(tables.scheduled_jobs[1].id, id)
        eq(tables.scheduled_jobs[1].action_id, 'refill_shops')
        eq(tables.scheduled_jobs[1].schedule_type, 'interval')
        eq(tables.scheduled_jobs[1].interval_seconds, 3600)
        eq(tables.scheduled_jobs[1].cron_expression, nil)
        eq(tables.scheduled_jobs[1].enabled, 1)
    end)
end)

test('create: cron job inserts a row with cron_expression set', function()
    withFakeDb(function(tables)
        local id = SchedulerService.create('refill_shops', 'cron', { cronExpression = '0 3 * * *' })
        eq(tables.scheduled_jobs[1].id, id)
        eq(tables.scheduled_jobs[1].schedule_type, 'cron')
        eq(tables.scheduled_jobs[1].cron_expression, '0 3 * * *')
        eq(tables.scheduled_jobs[1].interval_seconds, nil)
    end)
end)

test('update: changes fields on an existing row', function()
    withFakeDb(function(tables)
        local id = SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        SchedulerService.update(id, { interval_seconds = 7200, enabled = 0 })
        eq(tables.scheduled_jobs[1].interval_seconds, 7200)
        eq(tables.scheduled_jobs[1].enabled, 0)
    end)
end)

test('delete: removes the row', function()
    withFakeDb(function(tables)
        local id = SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        SchedulerService.delete(id)
        eq(#tables.scheduled_jobs, 0)
    end)
end)

test('list: returns every row', function()
    withFakeDb(function()
        SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        SchedulerService.create('cleanup_bins', 'cron', { cronExpression = '0 4 * * *' })
        eq(#SchedulerService.list(), 2)
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

- [ ] **Step 4: Run test to verify it fails**

Run: `lua5.4 tests/scheduler_service_spec.lua`
Expected: FAIL — `attempt to index a nil value (global 'SchedulerService')` (service doesn't exist yet).

- [ ] **Step 5: Write the implementation**

`core/server/Services/SchedulerService.lua`:

```lua
--- SchedulerService - runs ActionService-registered actions on a schedule
--- (interval or cron) configured via admin-editable scheduled_jobs rows.
--- See docs/superpowers/specs/2026-08-16-scheduler-service-design.md.
--- isDue/tick/startTickLoop are added in Tasks 3-4; this file starts with
--- just the CRUD surface.
SchedulerService = {}

--- @param actionId string an ActionService-registered action_id
--- @param scheduleType string 'interval' | 'cron'
--- @param config table { intervalSeconds = number } or { cronExpression = string }
--- @return number id
function SchedulerService.create(actionId, scheduleType, config)
    config = config or {}
    return QueryBuilder.new('scheduled_jobs'):insert({
        action_id = actionId,
        schedule_type = scheduleType,
        interval_seconds = config.intervalSeconds,
        cron_expression = config.cronExpression,
        enabled = 1,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @param attrs table fields to update (action_id, schedule_type, interval_seconds, cron_expression, enabled)
function SchedulerService.update(id, attrs)
    attrs.updated_at = Database.now()
    QueryBuilder.new('scheduled_jobs'):where('id', id):update(attrs)
end

--- @param id number
function SchedulerService.delete(id)
    QueryBuilder.new('scheduled_jobs'):where('id', id):delete()
end

--- @return table[]
function SchedulerService.list()
    return QueryBuilder.new('scheduled_jobs'):getSync()
end

return SchedulerService
```

- [ ] **Step 6: Run test to verify it passes**

Run: `lua5.4 tests/scheduler_service_spec.lua`
Expected: `5/5 tests passed`

- [ ] **Step 7: Commit**

```bash
git add core/server/database/migrations/2026_08_16_150000_create_scheduled_jobs_table.lua core/server/database/migrations.json core/server/Services/SchedulerService.lua tests/scheduler_service_spec.lua
git commit -m "feat(scheduler): add scheduled_jobs migration and SchedulerService CRUD"
```

---

## Task 2: CronExpression parser/matcher

**Files:**
- Create: `core/server/Services/CronExpression.lua`
- Create: `tests/cron_expression_spec.lua`

**Interfaces:**
- Produces: global `CronExpression` table with `CronExpression.matches(expression, timestamp)` → boolean. `expression` is a 5-field string (`'minute hour day month weekday'`); `timestamp` is unix epoch seconds. Used by Task 3's `SchedulerService.isDue`.

- [ ] **Step 1: Write the failing test**

`tests/cron_expression_spec.lua`:

```lua
--- Unit tests for CronExpression.matches: field types (*, list, range,
--- step) individually and combined.
--- Run from the repository root: lua5.4 tests/cron_expression_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(ROOT .. '/core/server/Services/CronExpression.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

--- Builds a unix timestamp for a specific wall-clock moment via os.time,
--- so tests read as calendar dates rather than raw epoch numbers.
--- @param y number @param mo number @param d number @param h number @param mi number
local function at(y, mo, d, h, mi)
    return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
end

test('* matches every value in a field', function()
    -- 2026-08-17 is a Monday
    local ts = at(2026, 8, 17, 14, 30)
    eq(CronExpression.matches('* * * * *', ts), true)
end)

test('single number matches only that value', function()
    local ts = at(2026, 8, 17, 3, 0)
    eq(CronExpression.matches('0 3 * * *', ts), true)
    eq(CronExpression.matches('0 4 * * *', ts), false)
end)

test('comma list matches any listed value', function()
    local ts = at(2026, 8, 17, 9, 0)
    eq(CronExpression.matches('0 9,12,18 * * *', ts), true)
    eq(CronExpression.matches('0 10,12,18 * * *', ts), false)
end)

test('range matches any value within bounds inclusive', function()
    local ts = at(2026, 8, 17, 12, 0)
    eq(CronExpression.matches('0 9-17 * * *', ts), true)
    eq(CronExpression.matches('0 13-17 * * *', ts), false)
end)

test('step matches every nth value starting from field minimum', function()
    -- minute 30 is a multiple of 15 (0,15,30,45)
    local ts30 = at(2026, 8, 17, 9, 30)
    local ts20 = at(2026, 8, 17, 9, 20)
    eq(CronExpression.matches('*/15 * * * *', ts30), true)
    eq(CronExpression.matches('*/15 * * * *', ts20), false)
end)

test('range with step matches every nth value within the range', function()
    -- hour 9 is in 9-17 stepping by 4 -> 9,13,17
    local ts9 = at(2026, 8, 17, 9, 0)
    local ts11 = at(2026, 8, 17, 11, 0)
    eq(CronExpression.matches('0 9-17/4 * * *', ts9), true)
    eq(CronExpression.matches('0 9-17/4 * * *', ts11), false)
end)

test('weekday field: Monday matches weekday 1, Sunday matches weekday 0', function()
    local monday = at(2026, 8, 17, 9, 0) -- Monday
    local sunday = at(2026, 8, 16, 9, 0) -- Sunday
    eq(CronExpression.matches('0 9 * * 1-5', monday), true)
    eq(CronExpression.matches('0 9 * * 1-5', sunday), false)
    eq(CronExpression.matches('0 9 * * 0', sunday), true)
end)

test('full combined expression: every 15 min, 9-17, weekdays', function()
    local mondayInRange = at(2026, 8, 17, 9, 15)
    local mondayOutOfRange = at(2026, 8, 17, 18, 15)
    local saturdayInRange = at(2026, 8, 22, 9, 15)
    eq(CronExpression.matches('*/15 9-17 * * 1-5', mondayInRange), true)
    eq(CronExpression.matches('*/15 9-17 * * 1-5', mondayOutOfRange), false)
    eq(CronExpression.matches('*/15 9-17 * * 1-5', saturdayInRange), false)
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

Run: `lua5.4 tests/cron_expression_spec.lua`
Expected: FAIL — `attempt to index a nil value (global 'CronExpression')`.

- [ ] **Step 3: Write the implementation**

`core/server/Services/CronExpression.lua`:

```lua
--- CronExpression - parses and matches standard 5-field cron expressions
--- ('minute hour day month weekday') against a unix timestamp. Supports
--- *, single numbers, comma-lists, ranges (a-b), and steps (*/n, a-b/n).
--- No timezone handling: fields are evaluated against the server
--- process's local wall clock via os.date. See
--- docs/superpowers/specs/2026-08-16-scheduler-service-design.md.
CronExpression = {}

--- @param field string one cron field, e.g. '*/15', '9-17', '1,3,5', '*'
--- @param min number field's minimum valid value
--- @param max number field's maximum valid value
--- @return table set of allowed values (allowed[v] == true)
local function parseField(field, min, max)
    local allowed = {}
    for part in field:gmatch('[^,]+') do
        local range = part
        local step = 1

        local slashPos = part:find('/')
        if slashPos then
            range = part:sub(1, slashPos - 1)
            step = tonumber(part:sub(slashPos + 1))
        end

        local rangeMin, rangeMax
        if range == '*' then
            rangeMin, rangeMax = min, max
        elseif range:find('-') then
            local a, b = range:match('(%d+)-(%d+)')
            rangeMin, rangeMax = tonumber(a), tonumber(b)
        else
            rangeMin, rangeMax = tonumber(range), tonumber(range)
        end

        for v = rangeMin, rangeMax, step do
            allowed[v] = true
        end
    end
    return allowed
end

--- @param expression string 5-field cron expression
--- @param timestamp number unix epoch seconds
--- @return boolean
function CronExpression.matches(expression, timestamp)
    local minuteField, hourField, dayField, monthField, weekdayField =
        expression:match('^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$')
    if not minuteField then
        error('CronExpression.matches: invalid expression "' .. tostring(expression) .. '"')
    end

    local minutes = parseField(minuteField, 0, 59)
    local hours = parseField(hourField, 0, 23)
    local days = parseField(dayField, 1, 31)
    local months = parseField(monthField, 1, 12)
    local weekdays = parseField(weekdayField, 0, 6)

    local d = os.date('*t', timestamp)
    -- Lua's os.date wday: 1=Sunday..7=Saturday. Cron weekday: 0=Sunday..6=Saturday.
    local cronWeekday = d.wday - 1

    return minutes[d.min] == true
        and hours[d.hour] == true
        and days[d.day] == true
        and months[d.month] == true
        and weekdays[cronWeekday] == true
end

return CronExpression
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 tests/cron_expression_spec.lua`
Expected: `8/8 tests passed`

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/CronExpression.lua tests/cron_expression_spec.lua
git commit -m "feat(scheduler): add CronExpression parser/matcher"
```

---

## Task 3: SchedulerService.isDue + tick

**Files:**
- Modify: `core/server/Services/SchedulerService.lua`
- Create: `tests/scheduler_service_tick_spec.lua`

**Interfaces:**
- Consumes: `CronExpression.matches` (Task 2); `ActionService.execute` (existing, `core/server/Services/ActionService.lua`).
- Produces: `SchedulerService.isDue(row, now)` → boolean (pure function, no I/O — `row` is a `scheduled_jobs` row, `now` is unix epoch seconds); `SchedulerService.tick(now)` — fetches enabled rows, runs due ones via `ActionService.execute(nil, row.action_id, {})`, stamps `last_run_at = now`.

- [ ] **Step 1: Write the failing test**

`tests/scheduler_service_tick_spec.lua`:

```lua
--- Unit tests for SchedulerService.isDue/tick.
--- Run from the repository root: lua5.4 tests/scheduler_service_tick_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/Services/CronExpression.lua')
dofile(ROOT .. '/core/server/Services/SchedulerService.lua')

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

-- isDue: interval

test('isDue: interval job never run is due', function()
    eq(SchedulerService.isDue({ schedule_type = 'interval', interval_seconds = 3600, last_run_at = nil }, 1000000), true)
end)

test('isDue: interval job not due until interval elapses', function()
    local row = { schedule_type = 'interval', interval_seconds = 3600, last_run_at = 1000000 }
    eq(SchedulerService.isDue(row, 1000000 + 1800), false)
    eq(SchedulerService.isDue(row, 1000000 + 3600), true)
end)

-- isDue: cron

test('isDue: cron job never run and matching is due', function()
    -- 2026-08-17 09:00 is a Monday
    local ts = os.time({ year = 2026, month = 8, day = 17, hour = 9, min = 0, sec = 0 })
    local row = { schedule_type = 'cron', cron_expression = '0 9 * * 1-5', last_run_at = nil }
    eq(SchedulerService.isDue(row, ts), true)
end)

test('isDue: cron job not matching the current minute is not due', function()
    local ts = os.time({ year = 2026, month = 8, day = 17, hour = 9, min = 5, sec = 0 })
    local row = { schedule_type = 'cron', cron_expression = '0 9 * * 1-5', last_run_at = nil }
    eq(SchedulerService.isDue(row, ts), false)
end)

test('isDue: cron job does not re-fire within the same matching minute', function()
    local minuteStart = os.time({ year = 2026, month = 8, day = 17, hour = 9, min = 0, sec = 0 })
    local row = { schedule_type = 'cron', cron_expression = '0 9 * * 1-5', last_run_at = minuteStart }
    eq(SchedulerService.isDue(row, minuteStart + 20), false)
end)

test('isDue: cron job fires again once the matching minute has passed and comes back around', function()
    local firstMatch = os.time({ year = 2026, month = 8, day = 17, hour = 9, min = 0, sec = 0 })
    local nextDayMatch = os.time({ year = 2026, month = 8, day = 18, hour = 9, min = 0, sec = 0 })
    local row = { schedule_type = 'cron', cron_expression = '0 9 * * 1-5', last_run_at = firstMatch }
    eq(SchedulerService.isDue(row, nextDayMatch), true)
end)

-- tick

test('tick: runs a due interval job and stamps last_run_at', function()
    withFakeDb(function(tables)
        _G.ActionService = { execute = function() end }
        local id = SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        SchedulerService.tick(1000000)
        eq(tables.scheduled_jobs[1].last_run_at, 1000000)
    end)
end)

test('tick: calls ActionService.execute(nil, action_id, {}) for each due job', function()
    withFakeDb(function()
        local calls = {}
        _G.ActionService = { execute = function(player, actionId, data) calls[#calls + 1] = { player = player, actionId = actionId, data = data } end }
        SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        SchedulerService.tick(1000000)
        eq(#calls, 1)
        eq(calls[1].player, nil)
        eq(calls[1].actionId, 'refill_shops')
    end)
end)

test('tick: skips a job that is not due yet', function()
    withFakeDb(function()
        local calls = 0
        _G.ActionService = { execute = function() calls = calls + 1 end }
        local id = SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        SchedulerService.update(id, { last_run_at = 1000000 })
        SchedulerService.tick(1000000 + 60)
        eq(calls, 0)
    end)
end)

test('tick: skips a disabled job even if due', function()
    withFakeDb(function()
        local calls = 0
        _G.ActionService = { execute = function() calls = calls + 1 end }
        local id = SchedulerService.create('refill_shops', 'interval', { intervalSeconds = 3600 })
        SchedulerService.update(id, { enabled = 0 })
        SchedulerService.tick(1000000)
        eq(calls, 0)
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

Run: `lua5.4 tests/scheduler_service_tick_spec.lua`
Expected: FAIL — `attempt to call a nil value (field 'isDue')`.

- [ ] **Step 3: Write the implementation**

Append to `core/server/Services/SchedulerService.lua` (after `SchedulerService.list`, before the final `return SchedulerService`):

```lua
--- @param row table scheduled_jobs row
--- @param now number unix epoch seconds
--- @return boolean
function SchedulerService.isDue(row, now)
    if row.schedule_type == 'interval' then
        if not row.last_run_at then
            return true
        end
        return (now - row.last_run_at) >= row.interval_seconds
    elseif row.schedule_type == 'cron' then
        if not CronExpression.matches(row.cron_expression, now) then
            return false
        end
        if not row.last_run_at then
            return true
        end
        -- Don't re-fire within the same matching minute: compare against
        -- the start of "now"'s minute.
        local nowMinuteStart = now - (now % 60)
        return row.last_run_at < nowMinuteStart
    end
    return false
end

--- @param now number unix epoch seconds
function SchedulerService.tick(now)
    local rows = QueryBuilder.new('scheduled_jobs'):where('enabled', 1):getSync()
    for _, row in ipairs(rows) do
        if SchedulerService.isDue(row, now) then
            ActionService.execute(nil, row.action_id, {})
            QueryBuilder.new('scheduled_jobs'):where('id', row.id):update({
                last_run_at = now,
                updated_at = Database.now(),
            })
        end
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua5.4 tests/scheduler_service_tick_spec.lua`
Expected: `10/10 tests passed`

Also re-run Task 1's spec to confirm nothing broke:

Run: `lua5.4 tests/scheduler_service_spec.lua`
Expected: `5/5 tests passed`

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/SchedulerService.lua tests/scheduler_service_tick_spec.lua
git commit -m "feat(scheduler): add isDue and tick"
```

---

## Task 4: boot-time tick loop wiring

**Files:**
- Modify: `core/server/Services/SchedulerService.lua`
- Modify: `core/server/bootstrap.lua`

**Interfaces:**
- Produces: `SchedulerService.startTickLoop()` — starts the persistent `Citizen.CreateThread` poll loop. Called explicitly once from `bootstrap.lua`, NOT auto-invoked at file load.

**Why not a top-level `Citizen.CreateThread` in the service file itself** (like `oblsk_crafting`'s or `oblsk_doors`' `main.lua` do): those files are plugin/module `main.lua` wiring files that unit tests never `dofile` directly — only their underlying `*Service.lua` files get loaded in tests. `SchedulerService.lua` IS the file every scheduler test in this plan `dofile`s directly. The test harness's `Citizen.CreateThread` stub (`fivem_stubs.lua`) runs its function body synchronously once and its `Citizen.Wait` stub is a no-op — so a top-level `while true do ... Citizen.Wait(...) end` loop placed directly in this file would hang every test in this plan forever the moment it's `dofile`'d. Wrapping the loop in an explicit `startTickLoop()` function that only `bootstrap.lua` calls (and which no test ever calls) avoids this entirely.

- [ ] **Step 1: Add startTickLoop to SchedulerService.lua**

Append to `core/server/Services/SchedulerService.lua` (after `SchedulerService.tick`, before the final `return SchedulerService`):

```lua
local TICK_INTERVAL_MS = 30000

--- Starts the persistent scheduler poll loop. Call exactly once, from
--- bootstrap.lua after the database and core actions are ready -- never
--- call this from a test (see this task's note in the implementation
--- plan for why: the CreateThread test stub runs synchronously, so an
--- infinite loop here would hang any test that dofiles this file).
function SchedulerService.startTickLoop()
    Citizen.CreateThread(function()
        while not Database.isReady() do
            Citizen.Wait(200)
        end
        while true do
            SchedulerService.tick(os.time())
            Citizen.Wait(TICK_INTERVAL_MS)
        end
    end)
end
```

- [ ] **Step 2: Verify no test calls startTickLoop and all specs still pass**

Run: `grep -rn "startTickLoop" tests/` — expected: no matches (only `SchedulerService.lua` itself defines it).

Run: `lua5.4 tests/scheduler_service_spec.lua && lua5.4 tests/scheduler_service_tick_spec.lua && lua5.4 tests/cron_expression_spec.lua`
Expected: all three print their full pass counts (5/5, 10/10, 8/8) with no hang (if any of these hangs past a few seconds, `startTickLoop` was called somewhere it shouldn't be — stop and fix before proceeding, don't just kill and ignore).

- [ ] **Step 3: Wire into bootstrap.lua**

In `core/server/bootstrap.lua`, add the call right before the final "READY" banner print (after `print('[Obelisk] Core actions registered')`, shown in the plan's research as line 171):

```lua
    print('[Obelisk] Core actions registered')

    -- Start the scheduler's poll loop last, once every other boot step
    -- (migrations, seeders, core actions) has completed -- scheduled jobs
    -- may reference actions that were only just registered above.
    SchedulerService.startTickLoop()

    print([[
```

(the existing `print([[` line and everything after it stays exactly as-is — this only adds the `SchedulerService.startTickLoop()` call and its two comment lines directly above that existing print statement)

- [ ] **Step 4: Verify bootstrap.lua still parses**

Run: `lua5.4 -e "assert(loadfile('core/server/bootstrap.lua'))" && echo OK`
Expected: `OK`

(`bootstrap.lua` can't be fully executed standalone outside a real FXServer — this loadfile-based syntax check is the appropriate bar here, matching how other core boot-wiring changes in this codebase are verified without a live server.)

- [ ] **Step 5: Commit**

```bash
git add core/server/Services/SchedulerService.lua core/server/bootstrap.lua
git commit -m "feat(scheduler): wire startTickLoop into bootstrap"
```

---

## Task 5: Admin server relay + client NUI relay

**Files:**
- Create: `core/plugins/oblsk_admin/server/scheduler.lua`
- Modify: `core/plugins/oblsk_admin/client/main.lua`

**Interfaces:**
- Consumes: `SchedulerService.create/update/delete/list` (Task 1); `ActionService.getAll()` (existing) for the admin UI's action-picker dropdown.
- Produces: NUI-facing events for `SchedulerTab.vue` (Task 6): `admin:server:scheduler-list` → replies `admin:client:scheduler-reply` with `{ jobs, actions }` (`actions` is the list of known `ActionService`-registered action ids + labels, for the picker dropdown); `admin:server:scheduler-create`, `scheduler-update`, `scheduler-delete` (each re-replies with the refreshed list).

**Repo-structure fact:** `core/plugins/oblsk_admin` is its own git repo. `client/main.lua` currently has other, unrelated, pre-existing UNCOMMITTED changes (a routed-page admin-panel refactor) sitting on top of clean history — check `git status --short` yourself before touching anything; this is ambient state from other work, not something this plan controls. `server/scheduler.lua` is a brand-new file (no overlap risk, plain `git add`). `client/main.lua` needs the same care Task 6/7 of the `oblsk_jobs` module plan used: stash-isolate JUST that file, edit the clean version, commit, stash pop.

- [ ] **Step 1: Write the server relay**

`core/plugins/oblsk_admin/server/scheduler.lua`:

```lua
-- core/plugins/oblsk_admin/server/scheduler.lua
--- oblsk_admin server: Scheduler tab NUI handlers.
local function isAdmin(player)
    local source = player:getSource()
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

--- @return table[] { action_id, label } for every ActionService-registered action
local function listAvailableActions()
    local result = {}
    for actionId, entry in pairs(ActionService.getAll()) do
        table.insert(result, { action_id = actionId, label = entry.options and entry.options.label or actionId })
    end
    table.sort(result, function(a, b) return a.action_id < b.action_id end)
    return result
end

local function replyWithList(player)
    player:emit('admin:client:scheduler-reply', {
        jobs = SchedulerService.list(),
        actions = listAvailableActions(),
    })
end

Obelisk.onClient('admin:server:scheduler-list', function(player)
    if not isAdmin(player) then return end
    replyWithList(player)
end)

Obelisk.onClient('admin:server:scheduler-create', function(player, data)
    if not isAdmin(player) then return end
    SchedulerService.create(data.actionId, data.scheduleType, {
        intervalSeconds = data.intervalSeconds,
        cronExpression = data.cronExpression,
    })
    replyWithList(player)
end)

Obelisk.onClient('admin:server:scheduler-update', function(player, data)
    if not isAdmin(player) then return end
    SchedulerService.update(data.id, data.attributes or {})
    replyWithList(player)
end)

Obelisk.onClient('admin:server:scheduler-delete', function(player, data)
    if not isAdmin(player) then return end
    SchedulerService.delete(data.id)
    replyWithList(player)
end)
```

- [ ] **Step 2: Verify it parses**

Run: `cd core/plugins/oblsk_admin && lua5.4 -e "assert(loadfile('server/scheduler.lua'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit the server relay**

```bash
cd core/plugins/oblsk_admin
git add server/scheduler.lua
git commit -m "feat(admin): add Scheduler tab NUI relay"
```

- [ ] **Step 4: Stash-isolate client/main.lua**

```bash
cd core/plugins/oblsk_admin
git status --short  # confirm client/main.lua (and whatever else) is dirty as expected -- if the dirty-file list looks materially different from prior sessions, stop and investigate before continuing
git stash push -m "pre-existing admin panel refactor WIP" -- client/main.lua
git status --short client/main.lua  # must show nothing -- clean now
```

- [ ] **Step 5: Add TAB_RELAYS/TAB_REPLIES entries**

In the now-clean `client/main.lua`, add `'scheduler-list', 'scheduler-create', 'scheduler-update', 'scheduler-delete'` to the existing `TAB_RELAYS` array (alongside the `jobs-*`/`printers-*` entries), and `'scheduler-reply'` to the existing `TAB_REPLIES` array.

- [ ] **Step 6: Verify and commit**

```bash
lua5.4 -e "assert(loadfile('client/main.lua'))" && echo OK
git add client/main.lua
git commit -m "feat(admin): wire Scheduler tab client NUI relay (TAB_RELAYS/TAB_REPLIES)"
git stash pop
```

Read the `stash pop` output carefully — it must report a clean merge with no conflicts (the edit is two array-literal additions, unrelated to whatever the stashed WIP touches). If it reports a conflict, do NOT resolve it yourself (no `--ours`/`--theirs`, no discarding anything) — stop and report it as-is; it needs a human decision, not an implementer's guess.

- [ ] **Step 7: Final verification**

```bash
git status --short  # should be back to exactly what step 4's first `git status --short` showed, plus your two new commits in `git log`
```

---

## Task 6: Admin UI — SchedulerTab.vue

**Files:**
- Create: `core/plugins/oblsk_admin/web/SchedulerTab.vue`
- Modify: `core/plugins/oblsk_admin/web/AdminPanel.vue`

**Interfaces:**
- Consumes/produces: the events Task 5 defines — emits `admin:client:scheduler-list`, `scheduler-create`, `scheduler-update`, `scheduler-delete`; listens for `admin:client:scheduler-reply`. Same `Obelisk.emit`/`Obelisk.on` + `import.meta.env.DEV` fixture + `inject('obelisk:globalElementsRegistry', null)` re-fetch-on-visible pattern as `JobsTab.vue`/`ItemsTab.vue`.
- Produces: a `['scheduler', 'Scheduler']` entry in `AdminPanel.vue`'s `TABS` array and render block, positioned after the `items`/`jobs` entries, following the exact same wiring `JobsTab.vue` used.

**Same git-hygiene requirement as Task 5**: `web/AdminPanel.vue` is part of the same pre-existing WIP. Stash-isolate just that file before editing (check `git status --short` fresh — by the time this task runs, `client/main.lua` from Task 5 is back in its WIP state via the stash pop, so only `web/AdminPanel.vue` needs stashing here, but verify rather than assume).

- [ ] **Step 1: Write SchedulerTab.vue**

`core/plugins/oblsk_admin/web/SchedulerTab.vue`:

```vue
<!-- plugins/oblsk_admin/web/SchedulerTab.vue -->
<script setup>
import { ref, onMounted, onBeforeUnmount, inject, watch } from 'vue'
import Obelisk from '@/obelisk.js'

const jobs = ref([])
const actions = ref([])
const createDraft = ref(null)

const DEV_JOBS = [
  { id: 1, action_id: 'refill_shops', schedule_type: 'interval', interval_seconds: 3600, cron_expression: null, enabled: 1, last_run_at: null },
  { id: 2, action_id: 'cleanup_bins', schedule_type: 'cron', interval_seconds: null, cron_expression: '0 4 * * *', enabled: 1, last_run_at: null },
]
const DEV_ACTIONS = [
  { action_id: 'refill_shops', label: 'Refill Shops' },
  { action_id: 'cleanup_bins', label: 'Cleanup Bins' },
]

const fetchList = () => {
  if (import.meta.env.DEV) { jobs.value = DEV_JOBS; actions.value = DEV_ACTIONS; return }
  Obelisk.emit('admin:client:scheduler-list', {})
}

const onReply = ({ jobs: next, actions: nextActions }) => { jobs.value = next; actions.value = nextActions }

onMounted(() => {
  Obelisk.on('admin:client:scheduler-reply', onReply)
  fetchList()
})
onBeforeUnmount(() => Obelisk.off('admin:client:scheduler-reply', onReply))

const registry = inject('obelisk:globalElementsRegistry', null)
if (registry) {
  watch(() => registry.get('admin')?.visible, (visible) => { if (visible) fetchList() })
}

const openCreate = () => { createDraft.value = { actionId: '', scheduleType: 'interval', intervalSeconds: 3600, cronExpression: '' } }
const submitCreate = () => {
  Obelisk.emit('admin:client:scheduler-create', {
    actionId: createDraft.value.actionId,
    scheduleType: createDraft.value.scheduleType,
    intervalSeconds: createDraft.value.scheduleType === 'interval' ? Number(createDraft.value.intervalSeconds) : null,
    cronExpression: createDraft.value.scheduleType === 'cron' ? createDraft.value.cronExpression : null,
  })
  createDraft.value = null
}

const toggleEnabled = (job) => {
  Obelisk.emit('admin:client:scheduler-update', { id: job.id, attributes: { enabled: job.enabled ? 0 : 1 } })
}
const deleteJob = (job) => Obelisk.emit('admin:client:scheduler-delete', { id: job.id })
</script>

<template>
  <div class="flex flex-col gap-3 min-h-0 p-5">
    <div class="flex items-center justify-between">
      <span class="text-[12.5px] font-medium">Scheduled Jobs · {{ jobs.length }}</span>
      <button class="text-[11px] text-white/60 hover:text-white" @click="openCreate">+ New</button>
    </div>

    <div v-if="createDraft" class="rounded-xl border border-white/10 bg-white/[0.03] p-4 flex flex-col gap-2">
      <select v-model="createDraft.actionId" class="bg-white/5 rounded px-2 py-1 text-[12px]">
        <option value="" disabled>Select an action</option>
        <option v-for="a in actions" :key="a.action_id" :value="a.action_id">{{ a.label }} ({{ a.action_id }})</option>
      </select>
      <select v-model="createDraft.scheduleType" class="bg-white/5 rounded px-2 py-1 text-[12px]">
        <option value="interval">Interval</option>
        <option value="cron">Cron</option>
      </select>
      <input v-if="createDraft.scheduleType === 'interval'" v-model.number="createDraft.intervalSeconds" type="number" placeholder="Interval (seconds)" class="bg-white/5 rounded px-2 py-1 text-[12px]" />
      <input v-else v-model="createDraft.cronExpression" placeholder="Cron expression (min hour day month weekday)" class="bg-white/5 rounded px-2 py-1 text-[12px]" />
      <div class="flex gap-2">
        <button class="text-[11px] px-2 py-1 rounded" style="background: var(--ob-accent)" @click="submitCreate">Create</button>
        <button class="text-[11px] px-2 py-1 rounded bg-white/10" @click="createDraft = null">Cancel</button>
      </div>
    </div>

    <div class="rounded-xl border border-white/10 bg-white/[0.03] overflow-y-auto flex-1">
      <div v-for="job in jobs" :key="job.id" class="flex items-center justify-between px-4 py-2.5 border-b border-white/5 text-[12px]">
        <div>
          <div class="font-medium">{{ job.action_id }}</div>
          <div class="text-white/45">
            {{ job.schedule_type === 'interval' ? `every ${job.interval_seconds}s` : job.cron_expression }}
            — last run: {{ job.last_run_at ? new Date(job.last_run_at * 1000).toLocaleString() : 'never' }}
          </div>
        </div>
        <div class="flex items-center gap-2">
          <button class="text-[11px] px-2 py-1 rounded" :class="job.enabled ? 'bg-white/10' : ''" @click="toggleEnabled(job)">{{ job.enabled ? 'Enabled' : 'Disabled' }}</button>
          <button class="text-white/40 hover:text-red-300" @click="deleteJob(job)">×</button>
        </div>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Stash-isolate and wire AdminPanel.vue**

```bash
cd core/plugins/oblsk_admin
git status --short  # confirm current dirty-file list
git stash push -m "pre-existing admin panel refactor WIP" -- web/AdminPanel.vue
git status --short web/AdminPanel.vue  # must be clean now
```

In the now-clean `web/AdminPanel.vue`, add (following exactly where the `jobs`/`JobsTab` wiring sits, added by the `oblsk_jobs` plan's Task 7 — look for the `ItemsTab`/`JobsTab` import and `TABS` lines and add these directly after them):

Import (after `import JobsTab from './JobsTab.vue'`):
```js
import SchedulerTab from './SchedulerTab.vue'
```

TABS entry (after `['jobs', 'Jobs']`):
```js
['scheduler', 'Scheduler'],
```

Render branch (after `<JobsTab v-else-if="activeTab === 'jobs'" />`):
```html
<SchedulerTab v-else-if="activeTab === 'scheduler'" />
```

- [ ] **Step 3: Verify, commit, pop**

```bash
git add web/AdminPanel.vue web/SchedulerTab.vue
git commit -m "feat(admin): add Scheduler tab UI for scheduled-job CRUD"
git stash pop
```

Same conflict-handling rule as Task 5 Step 6: a clean pop is expected; if it conflicts, stop and report as-is rather than resolving it yourself.

- [ ] **Step 4: Manual verification (best effort)**

Attempt `cd core/web && npm run dev` (or check `core/web/package.json` scripts) and click the Scheduler tab in a browser if the environment allows it. If not possible in this environment, note that in the completion report rather than blocking on it — this mirrors how the `oblsk_jobs` plan's admin-UI task handled the same constraint.

- [ ] **Step 5: Final verification**

```bash
git status --short  # back to exactly the pre-Task-5 dirty-file list, plus 4 new commits total across Tasks 5-6 in `git log`
```

---

## Plan Self-Review Notes

- **Spec coverage:** data model (Task 1), `CronExpression` (Task 2), `isDue`/`tick` (Task 3), boot wiring (Task 4), admin server+client relay (Task 5), admin UI (Task 6) — every section of the spec has a task. The spec's testing list (CronExpression field types, isDue interval/cron/no-double-fire, CRUD, tick due/enabled filtering) is covered by Tasks 1-3's specs.
- **The jobs-module plan's exact final-review Critical finding — a task touching the admin UI without also touching `client/main.lua`'s relay arrays — cannot recur here**: Task 5 explicitly owns `client/main.lua` as a Files entry, with the full stash-isolate procedure spelled out, not left implicit.
- **Type consistency:** `SchedulerService.create(actionId, scheduleType, config)` takes a `config` table with `intervalSeconds`/`cronExpression` camelCase keys (matching the calling convention job-plugin code would use), but the underlying `scheduled_jobs` row stores snake_case `interval_seconds`/`cron_expression` (matching every other table in this codebase) — `create` and `update` bridge this consistently (`update` takes already-snake_case `attrs` since it's a direct passthrough to `QueryBuilder.update`, matching `JobService.updateJob`'s convention in the `oblsk_jobs` module).
- **No placeholders:** every step has full code, no TODOs.
