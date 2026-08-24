-- plugins/oblsk_auditlog/tests/audit_log_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_auditlog/tests/audit_log_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

dofile(scriptDir .. '../server/models/AuditLog.lua')
dofile(scriptDir .. '../server/services/AuditLogService.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

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

local function freshWidget()
    local Widget = BaseModel:extend('widgets')
    Widget.fillable = { 'name', 'count', 'secret' }
    return Widget
end

test('insert writes one audit row per non-nil configured field', function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        AuditLogConfig = { Watch = { Widget = { fields = { 'name', 'count' } } } }
        AuditLogService.init()

        Widget.new({ name = 'a', count = 1, secret = 'x' }):save()

        local rows = tables['audit_logs'] or {}
        eq(#rows, 2, 'expected exactly the two configured fields to be logged')
        local byField = {}
        for _, r in ipairs(rows) do byField[r.field] = r end
        eq(byField.name.action, 'insert')
        eq(byField.name.new_value, 'a')
        eq(byField.name.old_value, nil)
        eq(byField.count.new_value, '1')
    end)
end)

test('update writes a row only for fields that actually changed', function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        AuditLogConfig = { Watch = { Widget = { fields = { 'name', 'count' } } } }
        AuditLogService.init()

        local w = Widget.new({ name = 'a', count = 1, secret = 'x' })
        w:save()
        w:set('count', 2)
        w:save()

        local rows = tables['audit_logs']
        local updateRows = {}
        for _, r in ipairs(rows) do
            if r.action == 'update' then table.insert(updateRows, r) end
        end
        eq(#updateRows, 1, 'only count changed, name did not')
        eq(updateRows[1].field, 'count')
        eq(updateRows[1].old_value, '1')
        eq(updateRows[1].new_value, '2')
    end)
end)

test("fields = '*' audits every fillable field", function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        AuditLogConfig = { Watch = { Widget = { fields = '*' } } }
        AuditLogService.init()

        Widget.new({ name = 'a', count = 1, secret = 'x' }):save()

        eq(#tables['audit_logs'], 3)
    end)
end)

test("fields = '*' excludes fields the model marks hidden", function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        Widget.hidden = { 'secret' }
        AuditLogConfig = { Watch = { Widget = { fields = '*' } } }
        AuditLogService.init()

        Widget.new({ name = 'a', count = 1, secret = 'x' }):save()

        local rows = tables['audit_logs'] or {}
        eq(#rows, 2, 'hidden field secret should be excluded from wildcard auditing')
        for _, r in ipairs(rows) do
            if r.field == 'secret' then error('hidden field "secret" was audited under fields = \'*\'') end
        end
    end)
end)

test("explicitly-listed fields still include hidden fields (operator opt-in, not '*')", function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        Widget.hidden = { 'secret' }
        AuditLogConfig = { Watch = { Widget = { fields = { 'secret' } } } }
        AuditLogService.init()

        Widget.new({ name = 'a', count = 1, secret = 'x' }):save()

        local rows = tables['audit_logs'] or {}
        eq(#rows, 1)
        eq(rows[1].field, 'secret')
        eq(rows[1].new_value, 'x')
    end)
end)

test('delete writes one row per configured field with new_value = nil', function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        AuditLogConfig = { Watch = { Widget = { fields = { 'name' } } } }
        AuditLogService.init()

        local w = Widget.new({ name = 'a', count = 1 })
        w:save()
        w:delete()

        local deleteRows = {}
        for _, r in ipairs(tables['audit_logs']) do
            if r.action == 'delete' then table.insert(deleteRows, r) end
        end
        eq(#deleteRows, 1)
        eq(deleteRows[1].field, 'name')
        eq(deleteRows[1].old_value, 'a')
        eq(deleteRows[1].new_value, nil)
    end)
end)

test('a model not listed in Watch is never logged', function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        local Other = BaseModel:extend('others')
        Other.fillable = { 'name' }
        AuditLogConfig = { Watch = { Widget = { fields = '*' } } }
        AuditLogService.init()

        Other.new({ name = 'x' }):save()

        eq(tables['audit_logs'], nil)
    end)
end)

test('withActor attributes rows written during fn() to that player', function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        AuditLogConfig = { Watch = { Widget = { fields = { 'name' } } } }
        AuditLogService.init()

        AuditLogService.withActor(42, function()
            Widget.new({ name = 'a' }):save()
        end)

        local row = tables['audit_logs'][1]
        eq(row.actor_type, 'player')
        eq(row.actor_id, 42)
    end)
end)

test('writes outside withActor attribute to system', function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        AuditLogConfig = { Watch = { Widget = { fields = { 'name' } } } }
        AuditLogService.init()

        Widget.new({ name = 'a' }):save()

        local row = tables['audit_logs'][1]
        eq(row.actor_type, 'system')
        eq(row.actor_id, nil)
    end)
end)

test('withActor restores the previous actor after fn() returns, even on error', function()
    withFakeDb(function(tables)
        Widget = freshWidget()
        AuditLogConfig = { Watch = { Widget = { fields = { 'name' } } } }
        AuditLogService.init()

        AuditLogService.withActor(1, function()
            local ok = pcall(function()
                AuditLogService.withActor(2, function()
                    error('boom')
                end)
            end)
            eq(ok, false)
            -- back to actor 1 after the nested withActor unwound
            Widget.new({ name = 'a' }):save()
        end)

        local row = tables['audit_logs'][1]
        eq(row.actor_id, 1)
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
