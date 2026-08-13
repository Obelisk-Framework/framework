-- tests/settings_spec.lua
-- Run: lua5.4 tests/settings_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

-- Convars are stubbed via a table the test can populate before Settings.init().
local convarValues
_G.GetConvar = function(name, default)
    return (convarValues and convarValues[name]) or default
end
_G.GetConvarInt = function(name, default)
    return (convarValues and convarValues[name]) or default
end

local function loadSettings()
    _G.Settings = nil
    dofile(ROOT .. '/core/shared/Settings.lua')
    return _G.Settings
end

test('defaults apply when no convars are set', function()
    convarValues = {}
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.format.dateFormat, 'YYYY-MM-DD')
    eq(Settings.format.decimalSep, '.')
    eq(Settings.format.thousandsSep, ',')
    eq(Settings.format.currencySymbol, '$')
    eq(Settings.format.currencyPosition, 'before')
    eq(Settings.format.timezoneOffsetMinutes, 0)
end)

test('convars override defaults', function()
    convarValues = {
        date_format = 'DD/MM/YYYY',
        number_decimal_sep = ',',
        number_thousands_sep = '.',
        currency_symbol = '\xe2\x82\xac',
        currency_position = 'after',
        timezone_offset_minutes = -300,
    }
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.format.dateFormat, 'DD/MM/YYYY')
    eq(Settings.format.decimalSep, ',')
    eq(Settings.format.thousandsSep, '.')
    eq(Settings.format.currencySymbol, '\xe2\x82\xac')
    eq(Settings.format.currencyPosition, 'after')
    eq(Settings.format.timezoneOffsetMinutes, -300)
end)

test('formatDate renders YYYY-MM-DD by default', function()
    convarValues = {}
    local Settings = loadSettings()
    Settings.init()
    -- 2026-08-13 00:00:00 UTC
    eq(Settings.formatDate(1786579200), '2026-08-13')
end)

test('formatDate honors a DD/MM/YYYY format', function()
    convarValues = { date_format = 'DD/MM/YYYY' }
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.formatDate(1786579200), '13/08/2026')
end)

test('formatDate shifts by the configured timezone offset', function()
    -- 2026-08-13 00:00:00 UTC, -300 minutes (UTC-5) -> 2026-08-12 19:00:00
    convarValues = { date_format = 'YYYY-MM-DD HH:mm', timezone_offset_minutes = -300 }
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.formatDate(1786579200), '2026-08-12 19:00')
end)

test('formatNumber inserts thousands separators', function()
    convarValues = {}
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.formatNumber(1234567), '1,234,567')
end)

test('formatNumber preserves decimal places with the configured separator', function()
    convarValues = { number_decimal_sep = ',', number_thousands_sep = '.' }
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.formatNumber(1234567.89), '1.234.567,89')
end)

test('formatNumber handles negative values', function()
    convarValues = {}
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.formatNumber(-1234), '-1,234')
end)

test('formatCurrency prepends the symbol by default', function()
    convarValues = {}
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.formatCurrency(1234), '$1,234')
end)

test('formatCurrency appends the symbol when configured', function()
    convarValues = { currency_symbol = '\xe2\x82\xac', currency_position = 'after' }
    local Settings = loadSettings()
    Settings.init()
    eq(Settings.formatCurrency(1234), '1,234\xe2\x82\xac')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = {name = t.name, err = err}
    end
end

print(string.format('%d/%d passed', passed, #tests))
if #failures > 0 then
    for _, f in ipairs(failures) do
        print(string.format('FAIL: %s\n  %s', f.name, f.err))
    end
    os.exit(1)
end
