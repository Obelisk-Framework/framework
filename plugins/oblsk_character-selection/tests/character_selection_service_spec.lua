-- plugins/oblsk_character-selection/tests/character_selection_service_spec.lua
--- Unit tests for CharacterSelectionService, the thin list/create/delete/select
--- wrapper this plugin adds on top of oblsk_characters' CharacterService.
--- Run from the repository root:  lua5.4 plugins/oblsk_character-selection/tests/character_selection_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'
local CHAR_MODULE = scriptDir .. '../../../modules/oblsk_characters'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
-- CharacterService.create() emits 'character:created' via Obelisk.emit,
-- so the shared event wrapper must be loaded too (fivem_stubs.lua stubs
-- the underlying TriggerEvent/IsDuplicityVersion natives it calls).
dofile(CORE_ROOT .. '/core/shared/Obelisk.lua')
-- BaseModel:saveSync() reaches for Database.now()/Database.NULL, and
-- Database.lua itself resolves a dialect at load time, so the full ORM
-- load order from modules/oblsk_characters/tests/character_service_spec.lua
-- is needed here too, not just BaseModel.lua.
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
-- Character:accountRelation() references the global Account (from the
-- separate oblsk_accounts module, never loaded here) only inside the
-- relation function's body, so it's fine that Account never loads. But
-- HasPermissions.apply(Character, 'character') runs at Character.lua's
-- load time, so PermissionService + HasPermissions must load first (same
-- as modules/oblsk_characters/tests/character_service_spec.lua does).
dofile(CORE_ROOT .. '/core/server/Services/PermissionService.lua')
dofile(CORE_ROOT .. '/core/server/Traits/HasPermissions.lua')
dofile(CHAR_MODULE .. '/server/models/Character.lua')
dofile(CHAR_MODULE .. '/server/models/CharacterAppearance.lua')
dofile(CHAR_MODULE .. '/server/services/CharacterService.lua')
dofile(scriptDir .. '../shared/appearance.lua')

local makeFakeQueryBuilderModule = dofile(CHAR_MODULE .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../server/services/CharacterSelectionService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local function withFakeDb(fn)
    local tables = {
        accounts = { { id = 1, max_characters = 3 } },
        characters = {},
        character_appearances = {},
    }
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('createCharacter stores the submitted appearance on the CharacterAppearance row', function()
    withFakeDb(function(tables)
        local character = CharacterSelectionService.createCharacter(1, {
            first_name = 'Alex', last_name = 'Reyes', gender = 'female', dob = '1994-03-12', bio = '',
            appearance = Appearance.DEFAULT_APPEARANCE('female'),
        })
        truthy(character ~= nil)
        eq(#tables.character_appearances, 1)
        truthy(tables.character_appearances[1].data.headBlend ~= nil, 'appearance not persisted')
    end)
end)

test('createCharacter defaults the appearance when none is submitted', function()
    withFakeDb(function(tables)
        CharacterSelectionService.createCharacter(1, { first_name = 'Sam', last_name = 'Doe', gender = 'male', dob = '1990-01-01', bio = '' })
        truthy(tables.character_appearances[1].data.headBlend ~= nil, 'default appearance not applied')
    end)
end)

test('listWithAppearance returns each character joined with its appearance', function()
    withFakeDb(function()
        CharacterSelectionService.createCharacter(1, { first_name = 'A', last_name = 'B', gender = 'male', dob = '1990-01-01', bio = '' })
        local list = CharacterSelectionService.listWithAppearance(1)
        eq(#list, 1)
        eq(list[1].character.first_name, 'A')
        truthy(list[1].appearance ~= nil, 'appearance not joined')
    end)
end)

test('deleteCharacter soft-deletes via CharacterService.delete', function()
    withFakeDb(function(tables)
        local character = CharacterSelectionService.createCharacter(1, { first_name = 'A', last_name = 'B', gender = 'male', dob = '1990-01-01', bio = '' })
        CharacterSelectionService.deleteCharacter(character.attributes.id)
        eq(#CharacterSelectionService.listWithAppearance(1), 0)
    end)
end)

test('selectCharacter marks the session\'s active character and returns vitals + appearance', function()
    withFakeDb(function()
        local character = CharacterSelectionService.createCharacter(1, { first_name = 'A', last_name = 'B', gender = 'male', dob = '1990-01-01', bio = '' })
        local result = CharacterSelectionService.selectCharacter(5, character.attributes.id)
        eq(CharacterService.getActiveCharacterId(5), character.attributes.id)
        truthy(result.vitals ~= nil, 'missing vitals')
        truthy(result.appearance ~= nil, 'missing appearance')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('FAIL: ' .. t.name .. '\n  ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
