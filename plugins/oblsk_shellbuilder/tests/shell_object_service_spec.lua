-- core/plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_shellbuilder/tests/shell_object_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- ItemService stub: a tiny in-memory bindings registry + owned-amount ledger.
local BINDINGS = {}   -- key -> { id, name, data = { shell_tool, shell_category, shell_model } }
local OWNED = {}       -- characterId -> key -> amount
ItemService = {}
function ItemService.getRequiredBindingKeys()
    local keys = {}
    for key in pairs(BINDINGS) do table.insert(keys, key) end
    return keys
end
function ItemService.binding(key)
    return BINDINGS[key]
end
function ItemService.remove(source, baseItem, amount)
    local characterId = CharacterService.getActiveCharacterId(source)
    local owned = (OWNED[characterId] or {})[baseItem.key] or 0
    if owned < amount then return false, 'Not enough items' end
    OWNED[characterId][baseItem.key] = owned - amount
    return true
end
function ItemService.add(source, baseItem, amount)
    local characterId = CharacterService.getActiveCharacterId(source)
    OWNED[characterId] = OWNED[characterId] or {}
    OWNED[characterId][baseItem.key] = (OWNED[characterId][baseItem.key] or 0) + amount
    return true
end

CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    if source == 1 then return 100 end
    return nil
end

local STREAMER_CALLS = { register = {}, unregister = {} }
EntityStreamerService = {}
function EntityStreamerService.registerGroupEntity(groupKey, entityType, entityData, targetSources)
    table.insert(STREAMER_CALLS.register, { groupKey = groupKey, entityType = entityType, entityData = entityData, targetSources = targetSources })
    return entityType .. '_' .. tostring(entityData.id)
end
function EntityStreamerService.unregisterGroupEntity(groupKey, entityType, entityId, targetSources)
    table.insert(STREAMER_CALLS.unregister, { groupKey = groupKey, entityType = entityType, entityId = entityId, targetSources = targetSources })
end

InstanceService = {}
function InstanceService.getPlayersIn(key)
    return {}
end

dofile(scriptDir .. '../server/services/ShellObjectService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    QueryBuilder = makeFakeQueryBuilderModule({
        shells = { [1] = { id = 1, object_budget = 2 } },
    })
    BINDINGS = {
        ['shellbuilder.floor_wood'] = { key = 'shellbuilder.floor_wood', id = 1, name = 'Wooden Floor', data = { shell_tool = 'build', shell_category = 'Floors', shell_model = 'prop_floor_wood_01' } },
        ['shellbuilder.sofa_basic'] = { key = 'shellbuilder.sofa_basic', id = 2, name = 'Sofa', data = { shell_tool = 'decor', shell_category = 'Seating', shell_model = 'prop_sofa_01' } },
    }
    OWNED = { [100] = { ['shellbuilder.floor_wood'] = 5, ['shellbuilder.sofa_basic'] = 5 } }
    STREAMER_CALLS = { register = {}, unregister = {} }
    fn()
end

test('catalog returns only bindings whose shell_tool matches', function()
    withFreshState(function()
        local build = ShellObjectService.catalog('build')
        eq(#build, 1)
        eq(build[1].key, 'shellbuilder.floor_wood')

        local decor = ShellObjectService.catalog('decor')
        eq(#decor, 1)
        eq(decor[1].key, 'shellbuilder.sofa_basic')
    end)
end)

test('place consumes one item and inserts an unlocked object row for the placing character', function()
    withFreshState(function()
        local ok, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 1.0, 2.0, 3.0, 0, 0, nil, false)
        eq(ok, true)
        eq(obj.shell_id, 1)
        eq(obj.item_key, 'shellbuilder.sofa_basic')
        -- Stored as integer 0/1 (matches a MySQL TINYINT(1) round-trip),
        -- not a Lua boolean - see ShellObjectService.place/.remove.
        eq(obj.locked, 0)
        eq(obj.placed_by_character_id, 100)
        eq(OWNED[100]['shellbuilder.sofa_basic'], 4)
    end)
end)

test('place sets placed_by_character_id to nil for locked pieces', function()
    withFreshState(function()
        local ok, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 1.0, 2.0, 3.0, 0, 0, nil, true)
        eq(ok, true)
        eq(obj.locked, 1)
        eq(obj.placed_by_character_id, nil)
    end)
end)

test('place JSON-encodes colorData before insert', function()
    withFreshState(function()
        local ok, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 1.0, 2.0, 3.0, 0, 0, { r = 10, g = 20, b = 30 }, false)
        eq(ok, true)
        eq(type(obj.color_data), 'string')
    end)
end)

test('place rejects an unknown item_key', function()
    withFreshState(function()
        local ok, reason = ShellObjectService.place(1, 1, 'shellbuilder.does_not_exist', 0, 0, 0, 0, 0, nil, false)
        eq(ok, false)
        eq(reason, 'Unknown item')
    end)
end)

test('place rejects once the shell hits its object_budget', function()
    withFreshState(function()
        ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 1, 0, 0, 0, 0, nil, false)
        local ok, reason = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 2, 0, 0, 0, 0, nil, false)
        eq(ok, false)
        eq(reason, 'Shell has reached its object budget')
    end)
end)

test('place rejects when the character does not own the item', function()
    withFreshState(function()
        OWNED[100]['shellbuilder.sofa_basic'] = 0
        local ok, reason = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        eq(ok, false)
        eq(reason, 'Not enough items')
    end)
end)

test('remove deletes an unlocked object and refunds the item', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        local ok = ShellObjectService.remove(1, 1, obj.id)
        eq(ok, true)
        eq(#ShellObjectService.list(1), 0)
        eq(OWNED[100]['shellbuilder.sofa_basic'], 5)
    end)
end)

test('remove refuses to delete a locked object', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, true)
        local ok, reason = ShellObjectService.remove(1, 1, obj.id)
        eq(ok, false)
        eq(reason, 'This piece is locked')
        eq(#ShellObjectService.list(1), 1)
    end)
end)

-- Regression coverage for the truthiness bug: `locked` round-trips from a
-- real MySQL TINYINT(1) as the integer 1 or 0, not a Lua boolean. The fake
-- QueryBuilder above stores whatever Lua value ShellObjectService.place
-- inserts (now integers), but these two tests bypass place() entirely and
-- manually seed a row the way a real driver would hand it back, so the
-- read-side check is verified against both representations.
test('remove refuses to delete a row with integer locked = 1', function()
    withFreshState(function()
        QueryBuilder.new('shell_objects'):insert({
            id = 999, shell_id = 1, item_key = 'shellbuilder.sofa_basic',
            x = 0, y = 0, z = 0, heading = 0, floor_level = 0,
            locked = 1, placed_by_character_id = nil,
        })
        local ok, reason = ShellObjectService.remove(1, 1, 999)
        eq(ok, false)
        eq(reason, 'This piece is locked')
    end)
end)

test('remove deletes a row with integer locked = 0', function()
    withFreshState(function()
        QueryBuilder.new('shell_objects'):insert({
            id = 999, shell_id = 1, item_key = 'shellbuilder.sofa_basic',
            x = 0, y = 0, z = 0, heading = 0, floor_level = 0,
            locked = 0, placed_by_character_id = 100,
        })
        local ok = ShellObjectService.remove(1, 1, 999)
        eq(ok, true)
        eq(#ShellObjectService.list(1), 0)
    end)
end)

test('count reflects the number of placed objects', function()
    withFreshState(function()
        eq(ShellObjectService.count(1), 0)
        ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        eq(ShellObjectService.count(1), 1)
    end)
end)

test('place inserts a matching entities row and registers a group entity', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 5.0, 6.0, 7.0, 45.0, 0, nil, false)
        local entityRow = QueryBuilder.new('entities'):where('owner_type', 'shellbuilder_shell_object'):where('owner_id', obj.id):firstSync()
        eq(entityRow ~= nil, true)
        eq(entityRow.entity_type, 'object')
        eq(entityRow.x, 5.0)
        eq(entityRow.y, 6.0)
        eq(entityRow.z, 7.0)
        eq(entityRow.heading, 45.0)

        eq(#STREAMER_CALLS.register, 1)
        eq(STREAMER_CALLS.register[1].groupKey, 'shellbuilder:shell:1')
        eq(STREAMER_CALLS.register[1].entityType, 'object')
        eq(STREAMER_CALLS.register[1].entityData.id, obj.id)
        eq(STREAMER_CALLS.register[1].entityData.freeze, true, 'placed furniture is registered frozen, so it cannot drift or be pushed')

        local entityRow = QueryBuilder.new('entities'):where('owner_type', 'shellbuilder_shell_object'):where('owner_id', obj.id):firstSync()
        local decoded = json.decode(entityRow.data)
        eq(decoded.freeze, true, 'freeze is also persisted in the entities.data json blob, so a reload agrees')
    end)
end)

test('remove deletes the matching entities row and unregisters the group entity', function()
    withFreshState(function()
        local _, obj = ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        STREAMER_CALLS = { register = {}, unregister = {} }
        ShellObjectService.remove(1, 1, obj.id)

        local entityRow = QueryBuilder.new('entities'):where('owner_type', 'shellbuilder_shell_object'):where('owner_id', obj.id):firstSync()
        eq(entityRow, nil)
        eq(#STREAMER_CALLS.unregister, 1)
        eq(STREAMER_CALLS.unregister[1].groupKey, 'shellbuilder:shell:1')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures > 0 and 1 or 0)
