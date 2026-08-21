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
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(ROOT .. '/core/server/Models/ScheduledJob.lua')
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

test('isDoe: cron job not matching the current minute is not due', function()
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
        _G.ActionService = { execute = function() return true end }
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

test('tick: a row with a malformed cron expression does not stop other rows from running', function()
    withFakeDb(function(tables)
        local calls = {}
        _G.ActionService = { execute = function(player, actionId, data) calls[#calls + 1] = actionId; return true end }

        -- Malformed: only 4 fields instead of 5.
        SchedulerService.create('broken_job', 'cron', { cronExpression = '0 3 * *' })
        SchedulerService.create('healthy_job', 'interval', { intervalSeconds = 3600 })

        SchedulerService.tick(1000000)

        eq(#calls, 1)
        eq(calls[1], 'healthy_job')
    end)
end)

test('tick: does not stamp last_run_at when ActionService.execute reports the action did not run', function()
    withFakeDb(function(tables)
        _G.ActionService = { execute = function() return false end }
        local id = SchedulerService.create('unregistered_action', 'interval', { intervalSeconds = 3600 })

        SchedulerService.tick(1000000)

        eq(tables.scheduled_jobs[1].last_run_at, nil)
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
