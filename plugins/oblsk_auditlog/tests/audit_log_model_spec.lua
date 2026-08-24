-- plugins/oblsk_auditlog/tests/audit_log_model_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_auditlog/tests/audit_log_model_spec.lua
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

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function includes(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

test('AuditLog targets audit_logs table, has no timestamps auto-management', function()
    eq(AuditLog.table, 'audit_logs')
    eq(AuditLog.timestamps, false)
end)

test('AuditLog fillable covers diff-row fields', function()
    eq(includes(AuditLog.fillable, 'table_name'), true)
    eq(includes(AuditLog.fillable, 'row_id'), true)
    eq(includes(AuditLog.fillable, 'action'), true)
    eq(includes(AuditLog.fillable, 'actor_type'), true)
    eq(includes(AuditLog.fillable, 'actor_id'), true)
    eq(includes(AuditLog.fillable, 'field'), true)
    eq(includes(AuditLog.fillable, 'old_value'), true)
    eq(includes(AuditLog.fillable, 'new_value'), true)
end)

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
