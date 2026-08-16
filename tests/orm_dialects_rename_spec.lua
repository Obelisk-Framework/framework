-- core/tests/orm_dialects_rename_spec.lua
-- Run from the repository root: lua5.4 tests/orm_dialects_rename_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')

local MySQLDialect = Dialects.resolve('mysql')
local PostgresDialect = Dialects.resolve('postgres')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end
local function notContains(haystack, needle, msg)
    if haystack:find(needle, 1, true) then
        error((msg or 'unexpected substring found') .. '\n  did not expect: ' .. needle .. '\n  in: ' .. haystack, 2)
    end
end

test('MySQLDialect.renameColumnSQL uses RENAME COLUMN, not CHANGE...VARCHAR', function()
    local sql = MySQLDialect.renameColumnSQL('base_items', 'item_category_id', 'base_item_category_id')
    eq(sql, 'ALTER TABLE `base_items` RENAME COLUMN `item_category_id` TO `base_item_category_id`')
    notContains(sql, 'VARCHAR', 'must not retype the column on rename')
    notContains(sql, 'CHANGE', 'must use RENAME COLUMN syntax, not CHANGE')
end)

test('PostgresDialect.renameColumnSQL is unchanged (RENAME COLUMN)', function()
    local sql = PostgresDialect.renameColumnSQL('base_items', 'item_category_id', 'base_item_category_id')
    eq(sql, 'ALTER TABLE "base_items" RENAME COLUMN "item_category_id" TO "base_item_category_id"')
end)

test('MySQLDialect.renameTableSQL', function()
    local sql = MySQLDialect.renameTableSQL('item_categories', 'base_item_categories')
    eq(sql, 'ALTER TABLE `item_categories` RENAME TO `base_item_categories`')
end)

test('PostgresDialect.renameTableSQL', function()
    local sql = PostgresDialect.renameTableSQL('item_categories', 'base_item_categories')
    eq(sql, 'ALTER TABLE "item_categories" RENAME TO "base_item_categories"')
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = { name = t.name, err = err } end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print(string.format('FAIL: %s\n  %s', f.name, f.err)) end
os.exit(#failures == 0 and 0 or 1)
