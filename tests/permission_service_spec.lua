--- Unit tests for PermissionService: entity-type registration and direct
--- grant/revoke/has/list. Delegated (PermissionService.can) behavior is
--- covered in permission_service_delegates_spec.lua (Task 2).
--- Run from the repository root:  lua5.4 tests/permission_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/Services/PermissionService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

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
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    -- Each test gets a clean registry too, so registerType calls in one
    -- test never leak into the next.
    local originalTypes, originalDelegates = PermissionService.registeredTypes, PermissionService.delegates
    PermissionService.registeredTypes = {}
    PermissionService.delegates = {}

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    PermissionService.registeredTypes = originalTypes
    PermissionService.delegates = originalDelegates
    if not ok then error(err, 2) end
end

test('grant: rejects an unregistered owner type', function()
    withFakeDb(function()
        local ok = pcall(PermissionService.grant, 'widget', 1, 'manage')
        eq(ok, false)
    end)
end)

test('grant: creates a row for a registered type', function()
    withFakeDb(function(tables)
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        eq(#tables.permissions, 1)
        eq(tables.permissions[1].owner_type, 'character')
        eq(tables.permissions[1].owner_id, 1)
        eq(tables.permissions[1].permission_key, 'manage_bank')
    end)
end)

test('grant: calling it twice never duplicates the row', function()
    withFakeDb(function(tables)
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        PermissionService.grant('character', 1, 'manage_bank')
        eq(#tables.permissions, 1)
    end)
end)

test('has: true only for an exact owner_type/owner_id/key match', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')

        truthy(PermissionService.has('character', 1, 'manage_bank'))
        eq(PermissionService.has('character', 2, 'manage_bank'), false)
        eq(PermissionService.has('character', 1, 'manage_fleet'), false)
    end)
end)

test('revoke: removes the grant', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        PermissionService.revoke('character', 1, 'manage_bank')

        eq(PermissionService.has('character', 1, 'manage_bank'), false)
    end)
end)

test('list: returns every granted key for that owner, no others', function()
    withFakeDb(function()
        PermissionService.registerType('character', {})
        PermissionService.grant('character', 1, 'manage_bank')
        PermissionService.grant('character', 1, 'manage_fleet')
        PermissionService.grant('character', 2, 'manage_bank')

        local keys = PermissionService.list('character', 1)
        table.sort(keys)
        eq(#keys, 2)
        eq(keys[1], 'manage_bank')
        eq(keys[2], 'manage_fleet')
    end)
end)

print('Running PermissionService unit tests\n')
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
