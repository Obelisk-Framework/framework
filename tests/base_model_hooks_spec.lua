--- Unit tests for BaseModel lifecycle hooks (afterSave/afterDelete).
--- Run from the repository root:  lua5.4 tests/base_model_hooks_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)
    local ok, err = pcall(fn, tables)
    QueryBuilder = original
    if not ok then error(err, 0) end
end

local function freshModel()
    local Widget = BaseModel:extend('widgets')
    Widget.fillable = { 'name', 'count' }
    return Widget
end

test('afterSave fires on insert with action=insert, before=nil, after=attrs', function()
    withFakeDb(function()
        local Widget = freshModel()
        local seen
        Widget.hooks:afterSave(function(instance, ctx) seen = ctx end)

        local w = Widget.new({ name = 'a', count = 1 })
        w:save()

        truthy(seen, 'hook did not fire')
        eq(seen.action, 'insert')
        eq(seen.before, nil)
        eq(seen.after.name, 'a')
        eq(seen.after.count, 1)
    end)
end)

test('afterSave fires on update with before = pre-write attrs, after = post-write attrs', function()
    withFakeDb(function()
        local Widget = freshModel()
        local w = Widget.new({ name = 'a', count = 1 })
        w:save()

        local seen
        Widget.hooks:afterSave(function(instance, ctx) seen = ctx end)

        w:set('count', 2)
        w:save()

        truthy(seen, 'hook did not fire')
        eq(seen.action, 'update')
        eq(seen.before.count, 1)
        eq(seen.after.count, 2)
    end)
end)

test('afterDelete fires with before = attrs at time of delete', function()
    withFakeDb(function()
        local Widget = freshModel()
        local w = Widget.new({ name = 'a', count = 1 })
        w:save()

        local seen
        Widget.hooks:afterDelete(function(instance, ctx) seen = ctx end)
        w:delete()

        truthy(seen, 'hook did not fire')
        eq(seen.before.name, 'a')
        eq(seen.before.count, 1)
    end)
end)

test('multiple hooks on the same model run in registration order', function()
    withFakeDb(function()
        local Widget = freshModel()
        local order = {}
        Widget.hooks:afterSave(function() table.insert(order, 1) end)
        Widget.hooks:afterSave(function() table.insert(order, 2) end)

        Widget.new({ name = 'a' }):save()

        eq(#order, 2)
        eq(order[1], 1)
        eq(order[2], 2)
    end)
end)

test('a hook on one model does not fire for a different model', function()
    withFakeDb(function()
        local Widget = freshModel()
        local Other = BaseModel:extend('others')
        Other.fillable = { 'name' }

        local fired = false
        Widget.hooks:afterSave(function() fired = true end)

        Other.new({ name = 'x' }):save()

        eq(fired, false)
    end)
end)

test('a hook that errors does not stop the save or propagate', function()
    withFakeDb(function()
        local Widget = freshModel()
        Widget.hooks:afterSave(function() error('boom') end)

        local ok = pcall(function()
            Widget.new({ name = 'a' }):save()
        end)

        eq(ok, true, 'save() must not raise even if a hook errors')
    end)
end)

test('afterSave fires on saveAsync insert with action=insert, before=nil, after=attrs', function()
    withFakeDb(function()
        local Widget = freshModel()
        local seen
        Widget.hooks:afterSave(function(instance, ctx) seen = ctx end)

        local w = Widget.new({ name = 'a', count = 1 })
        w:saveAsync(function() end)

        truthy(seen, 'hook did not fire')
        eq(seen.action, 'insert')
        eq(seen.before, nil)
        eq(seen.after.name, 'a')
        eq(seen.after.count, 1)
    end)
end)

test('afterSave fires on saveAsync update with before = pre-write attrs, after = post-write attrs', function()
    withFakeDb(function()
        local Widget = freshModel()
        local w = Widget.new({ name = 'a', count = 1 })
        w:save()

        local seen
        Widget.hooks:afterSave(function(instance, ctx) seen = ctx end)

        w:set('count', 2)
        w:saveAsync(function() end)

        truthy(seen, 'hook did not fire')
        eq(seen.action, 'update')
        eq(seen.before.count, 1)
        eq(seen.after.count, 2)
    end)
end)

test('afterDelete fires with deleteAsync with before = attrs at time of delete', function()
    withFakeDb(function()
        local Widget = freshModel()
        local w = Widget.new({ name = 'a', count = 1 })
        w:save()

        local seen
        Widget.hooks:afterDelete(function(instance, ctx) seen = ctx end)
        w:deleteAsync(function() end)

        truthy(seen, 'hook did not fire')
        eq(seen.before.name, 'a')
        eq(seen.before.count, 1)
    end)
end)

-- runner
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
