-- core/modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua
-- Run from the repository root:  lua5.4 core/modules/oblsk_accounts/tests/moderation_logs_migration_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../../../'

dofile(ROOT .. 'tests/support/fivem_stubs.lua')
dofile(ROOT .. 'core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. 'core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. 'core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. 'core/server/ORM/Database.lua')
dofile(ROOT .. 'core/server/ORM/Schema.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end

-- Mock the Database connector to allow migrations to run without a real database
Database.connector = 'oxmysql'
Database.ready = true

-- Mock the exports.oxmysql connector
exports.oxmysql = {
    executeSync = function(self, query, params)
        -- Just return success without actually executing the query
        return { affectedRows = 0 }
    end
}

local migration = dofile(ROOT .. 'core/modules/oblsk_accounts/server/migrations/2026_08_15_120000_create_moderation_logs_table.lua')

test('up: creates moderation_logs without error', function()
    local ok = pcall(migration.up)
    truthy(ok, 'migration.up() should not error')
end)

test('down: drops moderation_logs without error', function()
    local ok = pcall(migration.down)
    truthy(ok, 'migration.down() should not error')
end)

print('Running moderation_logs migration tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1; print('  ok   - ' .. t.name)
    else failures[#failures + 1] = t.name; print('  FAIL - ' .. t.name); print('         ' .. tostring(err)) end
end
print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
