--- Unit tests for InjuryService: player binding resolution, state CRUD, and
--- state change events.
--- Run from the repository root:  lua5.4 tests/injury_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/Services/InjuryService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(a, e, m)
    if a ~= e then error(string.format('%s\n  exp: %s\n  got: %s', m or 'fail', tostring(e), tostring(a)), 2) end
end
local function truthy(v, m) if not v then error(m or 'expected truthy', 2) end end

local function withFakeDb(fn)
    local tables = {}
    local orig = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = orig
    if not ok then error(err, 2) end
end

test('getBinding: returns account type when CharacterService absent', function()
    _G.CharacterService = nil
    _G.PlayerService = { get = function(id)
        return { getIdentifier = function(_, k) return k == 'account' and 99 or nil end }
    end}
    local b = InjuryService.getBinding(7)
    eq(b.type, 'account')
    eq(b.id, 99)
end)

test('getBinding: returns character type when CharacterService has active character', function()
    _G.CharacterService = { getActiveCharacter = function(playerId) return { id = 42 } end }
    local b = InjuryService.getBinding(7)
    eq(b.type, 'character')
    eq(b.id, 42)
end)

test('getState: returns healthy when no row exists', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        local state = InjuryService.getState(7)
        eq(state, 'healthy')
    end)
end)

test('setState: writes row and fires state_changed event', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        local events = {}
        _G.TriggerEvent = function(name, ...) events[#events+1] = {name=name, args={...}} end

        InjuryService.setState(7, 'injured')
        eq(#(tables.player_states or {}), 1)
        eq(tables.player_states[1].state, 'injured')
        truthy(#events > 0, 'expected event')
        eq(events[1].name, 'oblsk:injury:state_changed')
    end)
end)

-- runner
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed+1; io.write('.')
    else failures[#failures+1] = {name=t.name, err=err}; io.write('F') end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
for _, f in ipairs(failures) do print('FAIL: '..f.name..'\n  '..f.err) end
if #failures > 0 then os.exit(1) end
