-- Run from the repository root: lua5.4 plugins/oblsk_propattach/tests/attachment_service_spec.lua
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
dofile(scriptDir .. '../server/services/AttachmentService.lua')

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

local function seedPoint(tables)
    tables.attach_points = {
        { id = 1, model = 'pounder', point_name = 'trunk_slot', slot_index = 0, bone_index = 20,
          offset_x = 0, offset_y = 0, offset_z = 0, rot_x = 0, rot_y = 0, rot_z = 0 },
    }
end

test('AttachmentService.attach: creates a row when the point exists', function()
    withFakeDb(function(tables)
        seedPoint(tables)
        tables.attachments = {}

        local row, err = AttachmentService.attach('vehicle', 555, 'pounder', 'prop_deer_carc_01', 'trunk_slot', 0,
            { ownerType = 'plugin:oblsk_hunting', data = { animal = 'deer' } })

        eq(err, nil)
        eq(row ~= nil, true)
        eq(row.prop_model, 'prop_deer_carc_01')
        eq(row.parent_entity_type, 'vehicle')
        eq(row.parent_net_id, 555)
        eq(row.owner_type, 'plugin:oblsk_hunting')
        eq(#tables.attachments, 1)
    end)
end)

test('AttachmentService.attach: fails when the attach point is undefined', function()
    withFakeDb(function(tables)
        tables.attach_points = {}
        tables.attachments = {}

        local row, err = AttachmentService.attach('vehicle', 555, 'pounder', 'prop_deer_carc_01', 'nope', 0, {})

        eq(row, nil)
        eq(err, 'unknown attach point')
        eq(#tables.attachments, 0)
    end)
end)

test('AttachmentService.detach: removes the row', function()
    withFakeDb(function(tables)
        tables.attachments = {
            { id = 9, prop_model = 'prop_deer_carc_01', parent_entity_type = 'vehicle', parent_net_id = 555,
              point_name = 'trunk_slot', slot_index = 0 },
        }

        local ok = AttachmentService.detach(9)

        eq(ok, true)
        eq(#tables.attachments, 0)
    end)
end)

test('AttachmentService.detach: returns false for an unknown id', function()
    withFakeDb(function(tables)
        tables.attachments = {}

        eq(AttachmentService.detach(999), false)
    end)
end)

test('AttachmentService.getAttachments: filters by parent type + net id', function()
    withFakeDb(function(tables)
        tables.attachments = {
            { id = 1, parent_entity_type = 'vehicle', parent_net_id = 555, point_name = 'trunk_slot', slot_index = 0 },
            { id = 2, parent_entity_type = 'vehicle', parent_net_id = 555, point_name = 'trunk_slot', slot_index = 1 },
            { id = 3, parent_entity_type = 'vehicle', parent_net_id = 777, point_name = 'trunk_slot', slot_index = 0 },
        }

        local rows = AttachmentService.getAttachments('vehicle', 555)

        eq(#rows, 2)
    end)
end)

test('AttachmentService.all: returns every live attachment', function()
    withFakeDb(function(tables)
        tables.attachments = {
            { id = 1, parent_entity_type = 'vehicle', parent_net_id = 555 },
            { id = 2, parent_entity_type = 'ped', parent_net_id = 200 },
        }

        eq(#AttachmentService.all(), 2)
    end)
end)

print('\nRunning AttachmentService unit tests\n')
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
