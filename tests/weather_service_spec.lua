--- Unit tests for WeatherService: forecast generation algorithm, temperature
--- calculation, weather type transitions, and DB read/write.
--- Run from the repository root:  lua5.4 tests/weather_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/Config/WeatherConfig.lua')
dofile(ROOT .. '/core/server/Services/WeatherService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(a, e, m)
    if a ~= e then
        error(string.format('%s\n  expected: %s\n  actual:   %s', m or 'fail', tostring(e), tostring(a)), 2)
    end
end
local function truthy(v, m) if not v then error(m or 'expected truthy', 2) end end

test('getTemperature: summer month returns above base', function()
    local temp = WeatherService.getTemperature(7, 0)
    truthy(temp > WeatherConfig.climate.base_temp_c, 'summer should be warmer than base')
end)

test('getTemperature: winter month returns below base', function()
    local temp = WeatherService.getTemperature(1, 0)
    truthy(temp < WeatherConfig.climate.base_temp_c, 'winter should be colder than base')
end)

test('getWeatherType: snow only in snow_months', function()
    -- force rng to always pick snow-weighted option
    local summerType = WeatherService.getWeatherType(7, 'CLEAR', function() return 0.99 end)
    truthy(summerType ~= 'SNOW', 'no snow in summer')
    -- in winter with high rng, snow is possible
    local winterType = WeatherService.getWeatherType(12, 'OVERCAST', function() return 0.01 end)
    -- just verify it returns a string
    truthy(type(winterType) == 'string', 'returns a string')
end)

test('generateForecast: inserts lookahead_days * 12 windows', function()
    local withFakeDb = dofile(scriptDir .. 'support/fake_query_builder.lua')
    local tables = {}
    local orig = QueryBuilder
    QueryBuilder = withFakeDb(tables)
    local now = 1700000000
    WeatherService.generateForecast(now)
    QueryBuilder = orig
    local expected = WeatherConfig.lookahead_days * (86400 / WeatherConfig.window_duration)
    eq(#(tables.weather_forecast or {}), expected, 'wrong window count')
end)

test('tick: advances window when expired', function()
    local withFakeDb = dofile(scriptDir .. 'support/fake_query_builder.lua')
    local tables = {}
    local orig = QueryBuilder
    QueryBuilder = withFakeDb(tables)

    local now = 1700000000
    WeatherService.generateForecast(now)

    -- expire the current window
    local expiredNow = now + WeatherConfig.window_duration + 1
    local synced = {}
    _G.TriggerClientEvent = function(event, target, data)
        synced[#synced+1] = { event=event, data=data }
    end

    WeatherService.tick(expiredNow)
    QueryBuilder = orig

    truthy(#synced > 0, 'expected a sync event')
    eq(synced[1].event, 'oblsk:weather:sync')
end)

test('tick: no-op when window still valid', function()
    local withFakeDb = dofile(scriptDir .. 'support/fake_query_builder.lua')
    local tables = {}
    local orig = QueryBuilder
    QueryBuilder = withFakeDb(tables)

    local now = 1700000000
    WeatherService.generateForecast(now)

    local synced = {}
    _G.TriggerClientEvent = function(e, t, d) synced[#synced+1] = d end
    -- Reset _currentWindow so tick sees window fresh, then call once to prime it
    WeatherService._currentWindow = nil
    WeatherService.tick(now + 10)  -- prime: sets _currentWindow
    local syncedAfterPrime = #synced
    WeatherService.tick(now + 10)  -- same window: should not fire again
    QueryBuilder = orig

    eq(#synced, syncedAfterPrime, 'should not sync again for same window')
end)

-- runner
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; io.write('.')
    else failures[#failures+1] = {name=t.name, err=err}; io.write('F') end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
for _, f in ipairs(failures) do print('FAIL: '..f.name..'\n  '..f.err) end
if #failures > 0 then os.exit(1) end
