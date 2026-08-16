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
