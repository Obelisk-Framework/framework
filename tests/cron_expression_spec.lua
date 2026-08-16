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
