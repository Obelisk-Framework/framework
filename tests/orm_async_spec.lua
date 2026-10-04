--- Callback adapters must execute the canonical ORM operations in a yieldable thread.
--- Run from the repository root: lua5.4 tests/orm_async_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'
dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

local tests, passed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected)
    assert(actual == expected, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

-- Unlike the immediate global stub, this scheduler proves non-blocking calls
-- and lets connector spies suspend I/O before returning their results.
local threads
Citizen.CreateThread = function(fn)
    threads[#threads + 1] = coroutine.create(fn)
end
local function resume(thread)
    local ok, result = coroutine.resume(thread)
    assert(ok, result)
    return result
end
local function finish()
    for _, thread in ipairs(threads) do
        while coroutine.status(thread) ~= 'dead' do resume(thread) end
    end
end

local function checkAdapter(target, name, args, static)
    local original = rawget(target, name)
    local called, completed = 0, 0
    local result = {}
    target[name] = function(...)
        local received = table.pack(...)
        local offset = static and 0 or 1
        if not static then eq(received[1], target) end
        eq(received.n, args.n + offset)
        for i = 1, args.n do eq(received[i + offset], args[i]) end
        called = called + 1
        coroutine.yield('io')
        return result
    end
    local ok, err = pcall(function()
        local supplied = table.pack(table.unpack(args, 1, args.n))
        supplied[supplied.n + 1] = function(value)
            eq(value, result)
            completed = completed + 1
        end
        supplied.n = supplied.n + 1
        if static then
            eq(target[name .. 'Async'](table.unpack(supplied, 1, supplied.n)), nil)
        else
            eq(target[name .. 'Async'](target, table.unpack(supplied, 1, supplied.n)), nil)
        end
        eq(called, 0)
        eq(completed, 0)
        eq(#threads, 1)
        eq(resume(threads[1]), 'io')
        eq(called, 1)
        eq(completed, 0)
        finish()
        eq(completed, 1)
    end)
    target[name] = original
    assert(ok, err)
end

for _, name in ipairs({ 'query', 'insert', 'update' }) do
    test('Database.' .. name .. 'Async delegates to its canonical operation', function()
        checkAdapter(Database, name, table.pack('SQL', nil), true)
    end)
end
local modelArgs = {
    all = table.pack(), find = table.pack(42), create = table.pack({ name = 'a' }),
    firstOrCreate = table.pack({ name = 'a' }, nil),
    updateOrCreate = table.pack({ name = 'a' }, { name = 'b' }),
    save = table.pack(), delete = table.pack(), load = table.pack('related'),
}
for name, args in pairs(modelArgs) do
    test('BaseModel:' .. name .. 'Async delegates to its canonical operation', function()
        local model = BaseModel:extend('widgets').new({ id = 42 })
        model.exists = true
        checkAdapter(model, name, args)
    end)
end
local queryArgs = {
    get = table.pack(), first = table.pack(), count = table.pack(),
    insert = table.pack({ name = 'a' }), update = table.pack({ name = 'b' }), delete = table.pack(),
}
for name, args in pairs(queryArgs) do
    test('QueryBuilder:' .. name .. 'Async delegates to its canonical operation', function()
        checkAdapter(QueryBuilder.new('widgets'), name, args)
    end)
end

test('save/update/delete complete state tracking and hooks before callbacks', function()
    local Widget = BaseModel:extend('widgets')
    Widget.casts = { metadata = 'json' }
    local model = Widget.new({ name = 'before', metadata = { enabled = true } })
    local writes, hooks, callbacks = 0, {}, 0
    Database.executeQuery = function(sql, params)
        writes = writes + 1
        coroutine.yield('write')
        if sql:match('^INSERT') or sql:match('^UPDATE') then
            local encoded, timestamp = false, false
            for _, value in ipairs(params) do
                if value == '{"enabled":true}' then encoded = true end
                if type(value) == 'string' and value:match('^%d%d%d%d%-%d%d%-%d%d ') then timestamp = true end
            end
            assert(encoded and timestamp)
        end
        return { insertId = 42, affectedRows = 1 }
    end
    Widget.hooks:afterSave(function(instance, ctx)
        eq(instance, model)
        eq(instance.exists, true)
        eq(instance.original.name, instance.name)
        hooks[#hooks + 1] = ctx
    end)
    Widget.hooks:afterDelete(function(instance, ctx)
        eq(instance.exists, false)
        hooks[#hooks + 1] = ctx
    end)
    local function onSave(value)
        eq(value, model)
        callbacks = callbacks + 1
        eq(#hooks, callbacks)
    end
    model:saveAsync(onSave)
    eq(writes, 0)
    eq(model.exists, false)
    eq(resume(threads[1]), 'write')
    eq(model.exists, false)
    eq(callbacks, 0)
    finish()
    eq(model.id, 42)
    eq(hooks[1].action, 'insert')
    eq(hooks[1].before, nil)
    eq(hooks[1].after.metadata.enabled, true)
    eq(type(model.metadata), 'table')
    model:set('name', 'after')
    model:saveAsync(onSave)
    finish()
    eq(hooks[2].action, 'update')
    eq(hooks[2].before.name, 'before')
    eq(hooks[2].after.name, 'after')
    model:deleteAsync(function(value)
        eq(value, true)
        callbacks = callbacks + 1
        eq(#hooks, callbacks)
    end)
    finish()
    eq(hooks[3].before.name, 'after')
    eq(writes, 3)
    eq(callbacks, 3)
end)

test('getAsync waits for hydration and nested eager-load I/O before completion', function()
    local Parent = BaseModel:extend('parents')
    local Child = BaseModel:extend('children')
    local Detail = BaseModel:extend('details')
    Parent.casts = { metadata = 'json' }
    function Parent.relations:children() return self:hasMany(Child, 'parent_id') end
    function Child.relations:detail() return self:hasOne(Detail, 'child_id') end
    local queries, completed = 0, 0
    Database.executeQuery = function(sql)
        queries = queries + 1
        coroutine.yield('read')
        if sql:find('FROM `parents`', 1, true) then return {{ id = 1, metadata = '{"ready":true}' }} end
        if sql:find('FROM `children`', 1, true) then return {{ id = 2, parent_id = 1 }} end
        return {{ id = 3, child_id = 2 }}
    end
    Parent:with('children.detail'):getAsync(function(models)
        completed = completed + 1
        eq(models[1].metadata.ready, true)
        eq(models[1].children[1].detail.id, 3)
    end)
    for i = 1, 3 do
        eq(resume(threads[1]), 'read')
        eq(queries, i)
        eq(completed, 0)
    end
    finish()
    eq(completed, 1)
end)

for _, kind in ipairs({ 'hasOne', 'hasMany', 'belongsTo', 'belongsToMany', 'morphOne', 'morphMany', 'morphTo' }) do
    test('loadAsync shares ' .. kind .. ' resolution and caching', function()
        local Owner = BaseModel:extend('owners')
        local Related = BaseModel:extend('related')
        _G.ORMAsyncRelated = Related
        function Owner.relations:related()
            if kind == 'belongsToMany' then return self:belongsToMany(Related, 'pivot', 'owner_id', 'related_id') end
            if kind == 'morphTo' then return self:morphTo('owner_type', 'owner_id') end
            if kind == 'morphOne' or kind == 'morphMany' then
                return self[kind](self, Related, 'owner_id', 'owner_type', 'Owner')
            end
            return self[kind](self, Related, 'related_id')
        end
        local queries, callbacks = 0, 0
        Database.executeQuery = function()
            queries = queries + 1
            coroutine.yield('read')
            return {{ id = 9 }}
        end
        local owner = Owner.new({ id = 1, related_id = 9, owner_type = 'ORMAsyncRelated', owner_id = 9 })
        local result
        owner:loadAsync('related', function(value) callbacks = callbacks + 1; result = value end)
        eq(queries, 0)
        eq(resume(threads[1]), 'read')
        eq(owner.__loaded.related, nil)
        finish()
        eq(owner.__loaded.related, true)
        local isList = kind == 'hasMany' or kind == 'belongsToMany' or kind == 'morphMany'
        eq((isList and result[1] or result).id, 9)
        owner:loadAsync('related', function(value) eq(value, result); callbacks = callbacks + 1 end)
        eq(callbacks, 2)
        eq(queries, 1)
        eq(#threads, 1)
        _G.ORMAsyncRelated = nil
    end)
end

test('nil relations are cached and unsaved deletion completes immediately', function()
    local Owner, Related = BaseModel:extend('owners'), BaseModel:extend('related')
    function Owner.relations:related() return self:hasOne(Related, 'owner_id') end
    Database.executeQuery = function() coroutine.yield('read'); return {} end
    local owner, callbacks = Owner.new({ id = 1 }), 0
    owner:loadAsync('related', function(value) eq(value, nil); callbacks = callbacks + 1 end)
    finish()
    owner:loadAsync('related', function(value) eq(value, nil); callbacks = callbacks + 1 end)
    owner:deleteAsync(function(value) eq(value, false); callbacks = callbacks + 1 end)
    eq(callbacks, 3)
    eq(#threads, 1)
end)

test('writes work without callbacks and failed writes do not fire success hooks', function()
    local Widget = BaseModel:extend('widgets')
    local hooks = 0
    Widget.hooks:afterSave(function() hooks = hooks + 1 end)
    Database.executeQuery = function() coroutine.yield('write'); return { insertId = 42, affectedRows = 1 } end
    local model = Widget.new({})
    model:saveAsync()
    finish()
    eq(model.exists, true)
    model:deleteAsync()
    finish()
    eq(model.exists, false)
    eq(hooks, 1)
    Database.executeQuery = function() coroutine.yield('write'); error('connector failed') end
    local failed, callbacks = Widget.new({}), 0
    failed:saveAsync(function() callbacks = callbacks + 1 end)
    local thread = threads[#threads]
    eq(resume(thread), 'write')
    local ok, err = coroutine.resume(thread)
    eq(ok, false)
    assert(err:find('connector failed', 1, true))
    eq(failed.exists, false)
    eq(next(failed.original), nil)
    eq(callbacks, 0)
    eq(hooks, 1)
end)

test('callback errors propagate once rather than being retried', function()
    local callbacks = 0
    Database.runAsync(function() return false end, function(value)
        eq(value, false)
        callbacks = callbacks + 1
        error('callback failed')
    end)
    local ok, err = coroutine.resume(threads[1])
    eq(ok, false)
    assert(err:find('callback failed', 1, true))
    eq(callbacks, 1)
end)

local originalExecute = Database.executeQuery
for _, t in ipairs(tests) do
    threads = {}
    local ok, err = pcall(t.fn)
    Database.executeQuery = originalExecute
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end
print(('\n%d passed, %d failed'):format(passed, #tests - passed))
os.exit(passed == #tests and 0 or 1)
