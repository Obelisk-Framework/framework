-- Run from the repository root: lua5.4 plugins/oblsk_propattach/tests/attach_point_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/services/AttachPointService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
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

test('AttachPointService.upsert: inserts a new point', function()
    withFakeDb(function(tables)
        tables.attach_points = {}

        local id = AttachPointService.upsert('pounder', 'trunk_slot', 0, 20,
            { x = 0.1, y = 0.2, z = 0.3 }, { x = 0, y = 0, z = 90 })

        eq(id ~= nil, true)
        eq(#tables.attach_points, 1)
        eq(tables.attach_points[1].model, 'pounder')
        eq(tables.attach_points[1].point_name, 'trunk_slot')
        eq(tables.attach_points[1].bone_index, 20)
        eq(tables.attach_points[1].offset_x, 0.1)
        eq(tables.attach_points[1].rot_z, 90)
    end)
end)

test('AttachPointService.upsert: updates an existing point instead of duplicating', function()
    withFakeDb(function(tables)
        tables.attach_points = {
            { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0,
              bone_index = 20, offset_x = 0, offset_y = 0, offset_z = 0,
              rot_x = 0, rot_y = 0, rot_z = 0 },
        }

        local id = AttachPointService.upsert('pounder', 'trunk_slot', 0, 25,
            { x = 1, y = 1, z = 1 }, { x = 0, y = 0, z = 0 })

        eq(id, 1)
        eq(#tables.attach_points, 1)
        eq(tables.attach_points[1].bone_index, 25)
        eq(tables.attach_points[1].offset_x, 1)
    end)
end)

test('AttachPointService.find: returns the matching row', function()
    withFakeDb(function(tables)
        tables.attach_points = {
            { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0, bone_index = 20 },
            { id = 2, model = 'pounder', point_name = 'trunk_slot', slot_index = 1, bone_index = 21 },
        }

        local row = AttachPointService.find('pounder', 'trunk_slot', 1)

        eq(row.id, 2)
        eq(row.bone_index, 21)
    end)
end)

test('AttachPointService.find: returns nil for an unknown combination', function()
    withFakeDb(function(tables)
        tables.attach_points = {}

        eq(AttachPointService.find('pounder', 'nope', 0), nil)
    end)
end)

test('AttachPointService.listForModel: returns every point for a model', function()
    withFakeDb(function(tables)
        tables.attach_points = {
            { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0 },
            { id = 2, model = 'pounder', point_name = 'trunk_slot', slot_index = 1 },
            { id = 3, model = 'other', point_name = 'trunk_slot', slot_index = 0 },
        }

        local rows = AttachPointService.listForModel('pounder')

        eq(#rows, 2)
    end)
end)

print('\nRunning AttachPointService unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err))
    end
end

print('\n' .. passed .. ' passed, ' .. #failures .. ' failed')
os.exit(#failures > 0 and 1 or 0)
