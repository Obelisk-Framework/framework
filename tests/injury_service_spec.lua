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

test('addInjury: inserts row and fires injury_added event', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        local events = {}
        _G.TriggerEvent = function(name, ...) events[#events+1] = {name=name, args={...}} end

        local id = InjuryService.addInjury(7, 'thorax', 'bullet')
        truthy(id ~= nil, 'expected an id')
        eq(#(tables.player_injuries or {}), 1)
        eq(tables.player_injuries[1].zone, 'thorax')
        eq(tables.player_injuries[1].wound_type, 'bullet')
        eq(tables.player_injuries[1].hit_count, 1)
        truthy(#events > 0)
        eq(events[1].name, 'oblsk:injury:injury_added')
    end)
end)

test('addInjury: stacks hit_count on same zone', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        _G.TriggerEvent = function() end
        InjuryService.addInjury(7, 'lower_leg_l', 'bullet')
        InjuryService.addInjury(7, 'lower_leg_l', 'bullet')
        eq(#(tables.player_injuries or {}), 1)
        eq(tables.player_injuries[1].hit_count, 2)
    end)
end)

test('treatInjury: sets treated_at on the row', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        _G.TriggerEvent = function() end
        local id = InjuryService.addInjury(7, 'hand_r', 'stab')
        InjuryService.treatInjury(7, id)
        eq(tables.player_injuries[1].treated_at ~= nil, true)
    end)
end)

test('getInjuries: returns only untreated rows', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        _G.TriggerEvent = function() end
        local id1 = InjuryService.addInjury(7, 'thorax', 'bullet')
        local id2 = InjuryService.addInjury(7, 'hand_r', 'bullet')
        InjuryService.treatInjury(7, id1)
        local injuries = InjuryService.getInjuries(7)
        eq(#injuries, 1)
        eq(injuries[1].zone, 'hand_r')
    end)
end)

test('addIllness: inserts incubating row', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        _G.TriggerEvent = function() end
        local id = InjuryService.addIllness(7, 'pneumonia')
        eq(#(tables.player_illnesses or {}), 1)
        eq(tables.player_illnesses[1].illness_type, 'pneumonia')
        eq(tables.player_illnesses[1].stage, 'incubating')
    end)
end)

test('progressIllness: updates stage and fires event', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        local events = {}
        _G.TriggerEvent = function(name, ...) events[#events+1] = {name=name} end
        local id = InjuryService.addIllness(7, 'pneumonia')
        InjuryService.progressIllness(7, id, 'active')
        eq(tables.player_illnesses[1].stage, 'active')
        local found = false
        for _, e in ipairs(events) do
            if e.name == 'oblsk:injury:illness_progressed' then found = true end
        end
        truthy(found, 'expected illness_progressed event')
    end)
end)

test('getIllnesses: returns only untreated', function()
    withFakeDb(function(tables)
        _G.CharacterService = nil
        _G.PlayerService = { get = function() return { getIdentifier = function() return 1 end } end }
        _G.TriggerEvent = function() end
        local id1 = InjuryService.addIllness(7, 'pneumonia')
        InjuryService.addIllness(7, 'heatstroke')
        InjuryService.treatIllness(7, id1)
        local ill = InjuryService.getIllnesses(7)
        eq(#ill, 1)
        eq(ill[1].illness_type, 'heatstroke')
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
