--- Runs every migration file's up() against a stubbed Schema/Database and
--- asserts none of them error. This is what actually catches a stray call
--- to the removed Blueprint:notNullable() — a plain dofile() would not,
--- since dofile only defines the up()/down() closures, it doesn't call them.
---
--- Run from the repository root:  lua5.4 tests/migration_audit_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')

local AuditMigrations = dofile(scriptDir .. 'support/audit_migrations.lua')

local result = AuditMigrations.run(ROOT .. '/core/server/database/migrations')

if #result.failed > 0 then
    print('FAILED migrations:')
    for _, f in ipairs(result.failed) do
        print('  ' .. f.file .. ': ' .. f.error)
    end
    os.exit(1)
end

print(#result.passed .. ' migration files passed audit, 0 failed')
os.exit(0)
