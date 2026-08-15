-- plugins/oblsk_barber/tests/barber_chairs_migration_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_barber/tests/barber_chairs_migration_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function contains(haystack, needle, msg)
    if not haystack:lower():find(needle:lower(), 1, true) then
        error((msg or 'expected substring not found') .. '\n  looking for: ' .. needle .. '\n  in: ' .. haystack, 2)
    end
end

local function captureStatements(fn)
    local statements = {}
    local original = Database.querySync
    Database.querySync = function(sql, params)
        table.insert(statements, sql)
        return {}
    end
    fn()
    Database.querySync = original
    return statements
end

test('barber_chairs migration creates the table with an interaction_id FK', function()
    local migration = dofile(scriptDir .. '../server/migrations/2026_08_15_150000_create_barber_chairs_table.lua')
    local statements = captureStatements(migration.up)
    local sql = table.concat(statements, '\n')
    contains(sql, 'barber_chairs')
    contains(sql, 'interaction_id')
    contains(sql, 'name')
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
