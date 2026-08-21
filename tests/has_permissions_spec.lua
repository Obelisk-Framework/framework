--- Unit tests for the HasPermissions trait: applying it to a plain
--- BaseModel subclass wires up PermissionService.registerType and adds
--- :can/:grant/:revoke/:permissionList. Uses a throwaway model so this
--- stays independent of any specific module's real models (see
--- modules/oblsk_characters/tests/character_model_spec.lua and
--- modules/oblsk_accounts/tests/account_model_spec.lua for the real ones).
--- Run from the repository root:  lua5.4 tests/has_permissions_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(ROOT .. '/core/server/Models/Permission.lua')
dofile(ROOT .. '/core/server/Services/PermissionService.lua')
dofile(ROOT .. '/core/server/Traits/HasPermissions.lua')

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

    local originalTypes, originalDelegates = PermissionService.registeredTypes, PermissionService.delegates
    PermissionService.registeredTypes = {}
    PermissionService.delegates = {}

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    PermissionService.registeredTypes = originalTypes
    PermissionService.delegates = originalDelegates
    if not ok then error(err, 2) end
end

test('apply: sets permissionType and registers with PermissionService', function()
    withFakeDb(function()
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        eq(Widget.permissionType, 'widget')
        truthy(PermissionService.registeredTypes.widget ~= nil)
    end)
end)

test('grant/can: an instance can grant itself a key and then see it as true', function()
    withFakeDb(function(tables)
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        tables.widgets = { { id = 7, name = 'thingamajig' } }
        local instance = Widget:find(7)

        eq(instance:can('spin'), false)
        instance:grant('spin')
        truthy(instance:can('spin'))
    end)
end)

test('revoke: removes a previously granted key', function()
    withFakeDb(function(tables)
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        tables.widgets = { { id = 7, name = 'thingamajig' } }
        local instance = Widget:find(7)

        instance:grant('spin')
        instance:revoke('spin')
        eq(instance:can('spin'), false)
    end)
end)

test('permissionList: returns every key granted to this instance', function()
    withFakeDb(function(tables)
        local Widget = BaseModel:extend('widgets')
        HasPermissions.apply(Widget, 'widget')

        tables.widgets = { { id = 7, name = 'thingamajig' } }
        local instance = Widget:find(7)

        instance:grant('spin')
        instance:grant('paint')

        local keys = instance:permissionList()
        table.sort(keys)
        eq(#keys, 2)
        eq(keys[1], 'paint')
        eq(keys[2], 'spin')
    end)
end)

print('Running HasPermissions unit tests\n')
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
