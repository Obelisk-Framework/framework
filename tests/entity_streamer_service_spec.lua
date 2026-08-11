--- Unit tests for the server-side EntityStreamerService.
--- Run from the repository root:  lua5.4 tests/entity_streamer_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

-- EntityStreamerService.lua registers net event handlers via Obelisk.onServer
-- and broadcasts via Obelisk.emitClient at module load time (and from
-- register(), which init() calls immediately via Citizen.CreateThread's
-- synchronous stub -- see fivem_stubs.lua). A minimal stub is enough since
-- these tests never assert on network traffic.
_G.Obelisk = _G.Obelisk or { onServer = function() end, emitClient = function() end }

local failures = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then table.insert(failures, name .. ': ' .. tostring(err)) end
end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'mismatch') .. ' -- expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    end
end

local function freshService(tables)
    _G.QueryBuilder = makeFakeQueryBuilderModule(tables or {})
    dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
    dofile(ROOT .. '/core/server/Models/Entity.lua')
    return dofile(ROOT .. '/core/server/Services/EntityStreamerService.lua')
end

test('init() loads enabled entities from the Entity model and registers each one', function()
    local tables = {
        entities = {
            { id = 1, entity_type = 'ped', model = 'a_m_y_business_01', x = 10.0, y = 20.0, z = 30.0,
              heading = 0.0, networked = false, enabled = true },
            { id = 2, entity_type = 'object', model = 'prop_box', x = 110.0, y = 20.0, z = 30.0,
              heading = 0.0, networked = false, enabled = true },
            { id = 3, entity_type = 'ped', model = 'a_m_y_business_02', x = 999.0, y = 999.0, z = 30.0,
              heading = 0.0, networked = false, enabled = false },
        }
    }
    local Streamer = freshService(tables)

    Streamer.init()

    -- register() mints its own runtime entityId (entityType_timestamp_rand),
    -- not the DB row id, so look up the registered ped by its coordinates
    -- rather than assuming the id round-trips.
    local foundPed = false
    for _, entity in pairs(Streamer.entities.ped) do
        if entity.x == 10.0 and entity.y == 20.0 then foundPed = true end
    end
    eq(foundPed, true, 'ped from row #1 registered')
    local chunk1 = Streamer.getChunkKey(10.0, 20.0)
    local chunk2 = Streamer.getChunkKey(110.0, 20.0)
    eq(Streamer.chunks[chunk1] ~= nil and Streamer.chunks[chunk1].ped ~= nil, true, 'chunk1 has a ped')
    eq(Streamer.chunks[chunk2] ~= nil and Streamer.chunks[chunk2].object ~= nil, true, 'chunk2 has an object')

    local disabledChunk = Streamer.getChunkKey(999.0, 999.0)
    eq(Streamer.chunks[disabledChunk], nil, 'disabled entity #3 never registered')
end)

if #failures > 0 then
    for _, f in ipairs(failures) do print('FAIL: ' .. f) end
    os.exit(1)
else
    print('All tests passed')
    os.exit(0)
end
