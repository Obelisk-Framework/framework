--- Unit tests for the server-side KeybindService's resolution model.
--- Run from the repository root:  lua5.4 tests/keybind_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

_G.Obelisk = _G.Obelisk or {
    on = function(eventName, callback) AddEventHandler(eventName, callback) end,
    onServer = function() end,
    onClient = function() end,
    emitClient = function() end,
}

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

--- Fresh ActionService + PreferenceService + KeybindService against a fake
--- DB, with one pre-registered action carrying a default_key.
local function freshServices(tables)
    _G.QueryBuilder = makeFakeQueryBuilderModule(tables or {})
    _G.Database = { isReady = function() return true end, now = function() return 0 end }
    dofile(ROOT .. '/core/server/Services/ActionService.lua')
    dofile(ROOT .. '/modules/oblsk_preferences/server/services/PreferenceService.lua')
    local KeybindService = dofile(ROOT .. '/core/server/Services/KeybindService.lua')

    ActionService.register('vehicle:seatbelt', function() end, {label = 'Seatbelt', default_key = 'B'})
    ActionService.register('interaction:point', function() end, {label = 'Point', default_key = 'B'})
    ActionService.register('phone:toggle-dock', function() end, {label = 'Toggle phone dock'})

    return KeybindService
end

test('resolve: returns the action default when no override exists', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    eq(KeybindService.resolve('vehicle:seatbelt', nil, nil), 'B')
end)

test('resolve: returns nil for an action with no default and no override', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    eq(KeybindService.resolve('phone:toggle-dock', nil, nil), nil)
end)

test('resolve: account override beats the default', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    KeybindService.setOverride('account', 1, 'vehicle:seatbelt', 'J')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, nil), 'J')
end)

test('resolve: character override beats account override', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    KeybindService.setOverride('account', 1, 'vehicle:seatbelt', 'J')
    KeybindService.setOverride('character', 5, 'vehicle:seatbelt', 'K')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, 5), 'K')
end)

test('resolve: nil accountId/characterId still resolves the default (no optional modules installed)', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    eq(KeybindService.resolve('vehicle:seatbelt', nil, nil), 'B')
end)

test('clearOverride: falls resolution back to the tier below', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    KeybindService.setOverride('account', 1, 'vehicle:seatbelt', 'J')
    KeybindService.setOverride('character', 5, 'vehicle:seatbelt', 'K')

    KeybindService.clearOverride('character', 5, 'vehicle:seatbelt')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, 5), 'J')

    KeybindService.clearOverride('account', 1, 'vehicle:seatbelt')
    eq(KeybindService.resolve('vehicle:seatbelt', 1, 5), 'B')
end)

test('resolveAll: returns every registered action, sharing a key across two actions is not an error', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    local all = KeybindService.resolveAll(nil, nil)
    eq(all['vehicle:seatbelt'], 'B')
    eq(all['interaction:point'], 'B')
    eq(all['phone:toggle-dock'], nil)
end)

test('setOverride: rejects an unknown scope', function()
    local tables = {}
    local KeybindService = freshServices(tables)
    local ok = pcall(KeybindService.setOverride, 'vehicle', 1, 'vehicle:seatbelt', 'J')
    eq(ok, false)
end)

print('Running KeybindService unit tests\n')
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
