-- plugins/oblsk_shellbuilder/tests/shell_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_shellbuilder/tests/shell_service_spec.lua
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

-- PermissionService stub: settable per-test.
local GRANTED = {}
PermissionService = {}
function PermissionService.can(ownerType, ownerId, key)
    return GRANTED[ownerType .. ':' .. ownerId .. ':' .. key] == true
end

-- CharacterService stub: every source maps to character 100 for these tests.
CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    return 100
end

-- IsPlayerAceAllowed stub: returns false by default (no admin ACE).
IsPlayerAceAllowed = function(source, ace) return false end

-- PolicyService stub: records registrations, doesn't execute them (the
-- policy's own validator function is exercised directly, see the tests
-- below).
PolicyService = { registry = {} }
function PolicyService.register(policyId, validator, options)
    PolicyService.registry[policyId] = validator
end

dofile(scriptDir .. '../server/policies/CanBuildShellsPolicy.lua')
dofile(scriptDir .. '../server/services/ShellService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    QueryBuilder = makeFakeQueryBuilderModule({})
    GRANTED = {}
    fn()
end

test('create inserts a shell with the default object budget from config', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test Hideout')
        eq(shell.name, 'Test Hideout')
        eq(shell.object_budget, ShellBuilderConfig.DefaultObjectBudget)
        eq(shell.created_by_character_id, 100)
    end)
end)

test('get returns the created shell by id', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test Hideout')
        local fetched = ShellService.get(shell.id)
        eq(fetched.id, shell.id)
        eq(fetched.name, 'Test Hideout')
    end)
end)

test('list returns every shell', function()
    withFreshState(function()
        ShellService.create(100, 'A')
        ShellService.create(100, 'B')
        eq(#ShellService.list(), 2)
    end)
end)

test('rename updates the shell name', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Old name')
        ShellService.rename(shell.id, 'New name')
        eq(ShellService.get(shell.id).name, 'New name')
    end)
end)

test('setEntryCoords updates the entry coordinates and heading', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        ShellService.setEntryCoords(shell.id, 1.5, 2.5, 3.5, 90.0)
        local fetched = ShellService.get(shell.id)
        eq(fetched.entry_x, 1.5)
        eq(fetched.entry_y, 2.5)
        eq(fetched.entry_z, 3.5)
        eq(fetched.entry_heading, 90.0)
    end)
end)

test('addOwner then isOwner reports true, removeOwner then isOwner reports false', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        eq(ShellService.isOwner(shell.id, 200), false)

        ShellService.addOwner(shell.id, 200)
        eq(ShellService.isOwner(shell.id, 200), true)

        ShellService.removeOwner(shell.id, 200)
        eq(ShellService.isOwner(shell.id, 200), false)
    end)
end)

test('a shell supports multiple owning characters', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Shared house')
        ShellService.addOwner(shell.id, 200)
        ShellService.addOwner(shell.id, 300)

        local owners = ShellService.listOwners(shell.id)
        eq(#owners, 2)
    end)
end)

test('listOwnedShellIds returns only the shells a character owns, in one query', function()
    withFreshState(function()
        local a = ShellService.create(100, 'A')
        local b = ShellService.create(100, 'B')
        local c = ShellService.create(100, 'C')
        ShellService.addOwner(a.id, 200)
        ShellService.addOwner(c.id, 200)
        ShellService.addOwner(b.id, 300)

        local owned = ShellService.listOwnedShellIds(200)
        table.sort(owned)
        eq(#owned, 2)
        eq(owned[1], a.id)
        eq(owned[2], c.id)
        eq(#ShellService.listOwnedShellIds(300), 1)
        eq(#ShellService.listOwnedShellIds(999), 0)
    end)
end)

test('delete removes the shell', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        ShellService.delete(shell.id)
        eq(ShellService.get(shell.id), nil)
    end)
end)

test('CanBuildShellsPolicy denies a character with no granted permission', function()
    withFreshState(function()
        local allowed, reason = PolicyService.registry['shellbuilder:canBuild'](7, { type = 'action', id = 1 }, {})
        eq(allowed, false)
        eq(reason, 'You do not have permission to build shells')
    end)
end)

test('CanBuildShellsPolicy allows a character with the granted permission', function()
    withFreshState(function()
        GRANTED['character:100:shellbuilder.build'] = true
        local allowed = PolicyService.registry['shellbuilder:canBuild'](7, { type = 'action', id = 1 }, {})
        eq(allowed, true)
    end)
end)

test('searchCharactersByName matches first or last name, case-insensitively', function()
    withFreshState(function()
        QueryBuilder.new('characters'):insert({ id = 1, first_name = 'John', last_name = 'Smith', deleted_at = nil })
        QueryBuilder.new('characters'):insert({ id = 2, first_name = 'Jane', last_name = 'Johnson', deleted_at = nil })
        QueryBuilder.new('characters'):insert({ id = 3, first_name = 'Bob', last_name = 'Lee', deleted_at = nil })

        local results = ShellService.searchCharactersByName('john')
        eq(#results, 2) -- John Smith (first name) + Jane Johnson (last name)
    end)
end)

test('searchCharactersByName returns an empty list for no matches', function()
    withFreshState(function()
        QueryBuilder.new('characters'):insert({ id = 1, first_name = 'John', last_name = 'Smith' })
        eq(#ShellService.searchCharactersByName('xyz'), 0)
    end)
end)

test('searchCharactersByName caps results at 20', function()
    withFreshState(function()
        for i = 1, 25 do
            QueryBuilder.new('characters'):insert({ id = i, first_name = 'Match' .. i, last_name = 'Test' })
        end
        eq(#ShellService.searchCharactersByName('match'), 20)
    end)
end)

test('searchCharactersByName returns {} for a query shorter than 2 characters, without scanning', function()
    withFreshState(function()
        QueryBuilder.new('characters'):insert({ id = 1, first_name = 'John', last_name = 'Smith' })
        eq(#ShellService.searchCharactersByName('j'), 0)
        eq(#ShellService.searchCharactersByName(''), 0)
        eq(#ShellService.searchCharactersByName('  '), 0, 'whitespace-only trims to under 2 chars')
        eq(#ShellService.searchCharactersByName(nil), 0)
    end)
end)

test('listOwnersWithNames resolves owning character ids to first/last names', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        QueryBuilder.new('characters'):insert({ id = 200, first_name = 'John', last_name = 'Smith' })
        QueryBuilder.new('characters'):insert({ id = 300, first_name = 'Jane', last_name = 'Doe' })
        ShellService.addOwner(shell.id, 200)
        ShellService.addOwner(shell.id, 300)

        local owners = ShellService.listOwnersWithNames(shell.id)
        table.sort(owners, function(a, b) return a.id < b.id end)

        eq(#owners, 2)
        eq(owners[1].id, 200)
        eq(owners[1].first_name, 'John')
        eq(owners[1].last_name, 'Smith')
        eq(owners[2].id, 300)
        eq(owners[2].first_name, 'Jane')
    end)
end)

test('listOwnersWithNames returns an empty list for a shell with no owners', function()
    withFreshState(function()
        local shell = ShellService.create(100, 'Test')
        eq(#ShellService.listOwnersWithNames(shell.id), 0)
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
