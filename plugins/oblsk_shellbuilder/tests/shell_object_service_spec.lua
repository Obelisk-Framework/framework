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
        eq(obj.locked, false)
        eq(obj.placed_by_character_id, 100)
        eq(OWNED[100]['shellbuilder.sofa_basic'], 4)
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

test('count reflects the number of placed objects', function()
    withFreshState(function()
        eq(ShellObjectService.count(1), 0)
        ShellObjectService.place(1, 1, 'shellbuilder.sofa_basic', 0, 0, 0, 0, 0, nil, false)
        eq(ShellObjectService.count(1), 1)
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
