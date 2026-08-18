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
