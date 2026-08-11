--- Unit tests for the pure ORM layer.
--- Run from the repository root:  lua5.4 tests/orm_spec.lua
---
--- These cover the code that generates SQL strings, escapes values and builds
--- schema definitions — logic that runs identically off-server. They do NOT
--- cover net events, NUI, natives or real database I/O (those need a live
--- FiveM server and are not unit testable here).

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

-- Load stubs first so the ORM files can reference FiveM globals safely.
dofile(scriptDir .. 'support/fivem_stubs.lua')

-- Load the ORM source (each file assigns a global and/or returns the module).
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')

--------------------------------------------------------------------------------
-- Tiny test framework
--------------------------------------------------------------------------------
local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function eqList(actual, expected, msg)
    msg = msg or 'list'
    eq(#actual, #expected, msg .. ': length')
    for i = 1, #expected do
        eq(actual[i], expected[i], msg .. ': index ' .. i)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local function throws(fn, msg)
    if pcall(fn) then error(msg or 'expected an error but none was raised', 2) end
end

local BS = string.char(92) -- a single backslash

--------------------------------------------------------------------------------
-- Database.escape
--------------------------------------------------------------------------------
test('escape: single quotes are doubled', function()
    eq(Database.escape("O'Brien"), "'O''Brien'")
end)

test('escape: numbers are unquoted', function()
    eq(Database.escape(5), '5')
end)

test('escape: booleans map to 1/0', function()
    eq(Database.escape(true), '1')
    eq(Database.escape(false), '0')
end)

test('escape: nil becomes NULL', function()
    eq(Database.escape(nil), 'NULL')
end)

test('escape: backslashes are doubled', function()
    eq(Database.escape('a' .. BS .. 'b'), "'a" .. BS .. BS .. "b'")
end)

--------------------------------------------------------------------------------
-- Dialect wiring
--------------------------------------------------------------------------------
test('Database.dialect defaults to mysql before init() runs', function()
    eq(Database.dialect.quoteIdentifier('users'), '`users`')
end)

test('QueryBuilder.quoteIdentifier delegates to Database.dialect', function()
    local original = Database.dialect
    Database.dialect = Dialects.resolve('postgres')
    local ok, result = pcall(QueryBuilder.quoteIdentifier, 'users')
    Database.dialect = original
    truthy(ok, 'quoteIdentifier should not error')
    eq(result, '"users"')
end)

--------------------------------------------------------------------------------
-- Database.prepareQuery  (regression tests for the substitution bugs)
--------------------------------------------------------------------------------
test('prepareQuery: no params returns the query unchanged', function()
    eq(Database.prepareQuery('SELECT 1', {}), 'SELECT 1')
end)

test('prepareQuery: a % in a value does not blow up gsub', function()
    -- Previously errored: "invalid use of '%' in replacement string".
    eq(Database.prepareQuery('SELECT ?', {'50%'}), "SELECT '50%'")
end)

test('prepareQuery: a ? inside a value is not re-substituted', function()
    -- Previously the 2nd param was injected into the 1st value's literal '?'.
    eq(Database.prepareQuery('VALUES (?, ?)', {'a?b', 'c'}), "VALUES ('a?b', 'c')")
end)

test('prepareQuery: leftover placeholders are preserved', function()
    eq(Database.prepareQuery('VALUES (?, ?)', {'x'}), "VALUES ('x', ?)")
end)

--------------------------------------------------------------------------------
-- QueryBuilder:toSql
--------------------------------------------------------------------------------
test('toSql: select with where/order/limit', function()
    local sql, params = QueryBuilder.new('users')
        :where('age', '>', 18)
        :orderBy('name', 'asc')
        :limit(5)
        :toSql()
    eq(sql, 'SELECT * FROM `users` WHERE `age` > ? ORDER BY `name` ASC LIMIT 5')
    eqList(params, {18})
end)

test('toSql: whereIn expands placeholders', function()
    local sql, params = QueryBuilder.new('users'):whereIn('id', {1, 2, 3}):toSql()
    eq(sql, 'SELECT * FROM `users` WHERE `id` IN (?, ?, ?)')
    eqList(params, {1, 2, 3})
end)

test('toSql: AND / OR chaining and whereNull', function()
    local sql, params = QueryBuilder.new('players')
        :where('level', '>=', 10)
        :orWhere('vip', true)
        :whereNull('banned_at')
        :toSql()
    eq(sql, 'SELECT * FROM `players` WHERE `level` >= ? OR `vip` = ? AND `banned_at` IS NULL')
    eqList(params, {10, true})
end)

test('toSql: two-arg where defaults operator to =', function()
    local sql, params = QueryBuilder.new('users'):where('id', 7):toSql()
    eq(sql, 'SELECT * FROM `users` WHERE `id` = ?')
    eqList(params, {7})
end)

--------------------------------------------------------------------------------
-- QueryBuilder insert / update / delete  (spy on executeQuery)
--------------------------------------------------------------------------------
local function withCapture(fn)
    local captured
    local original = Database.executeQuery
    Database.executeQuery = function(query, params)
        captured = {query = query, params = params or {}}
        return {insertId = 1, affectedRows = 1}
    end
    local ok, err = pcall(fn, function() return captured end)
    Database.executeQuery = original
    if not ok then error(err, 2) end
end

test('insert: mysql adds no RETURNING clause', function()
    withCapture(function(get)
        QueryBuilder.new('users'):insert({name = 'bob'})
        truthy(not get().query:find('RETURNING', 1, true), 'mysql insert has no RETURNING')
    end)
end)

test('insert: builds INSERT with placeholders', function()
    withCapture(function(get)
        local id = QueryBuilder.new('users'):insert({name = 'bob'})
        eq(id, 1)
        eq(get().query, 'INSERT INTO `users` (`name`) VALUES (?)')
        eqList(get().params, {'bob'})
    end)
end)

test('update: SET values precede WHERE params', function()
    withCapture(function(get)
        QueryBuilder.new('users'):where('id', 42):update({name = 'bob'})
        eq(get().query, 'UPDATE `users` SET `name` = ? WHERE `id` = ?')
        eqList(get().params, {'bob', 42})
    end)
end)

test('update: Database.NULL sets a literal NULL with no placeholder/bound value', function()
    withCapture(function(get)
        QueryBuilder.new('users'):where('id', 42):update({ name = 'bob', rank_id = Database.NULL })
        local query, params = get().query, get().params

        truthy(query:find('`rank_id` = NULL', 1, true), 'rank_id set to literal NULL')
        truthy(not query:find('`rank_id` = ?', 1, true), 'rank_id has no placeholder')
        truthy(query:find('`name` = ?', 1, true), 'name still uses a placeholder')

        -- Only name's value and the WHERE id value should be bound; NULL never
        -- appears as a positional param (a real Lua nil must never be bound).
        eqList(params, {'bob', 42})
    end)
end)

test('delete: builds DELETE with where params', function()
    withCapture(function(get)
        QueryBuilder.new('users'):where('id', 42):delete()
        eq(get().query, 'DELETE FROM `users` WHERE `id` = ?')
        eqList(get().params, {42})
    end)
end)

--------------------------------------------------------------------------------
-- Identifier hardening (SQL-injection defence)
--------------------------------------------------------------------------------
test('quoteIdentifier: bare, qualified and star', function()
    eq(QueryBuilder.quoteIdentifier('users'), '`users`')
    eq(QueryBuilder.quoteIdentifier('k.action_id'), '`k`.`action_id`')
    eq(QueryBuilder.quoteIdentifier('*'), '*')
    eq(QueryBuilder.quoteIdentifier('users.*'), '`users`.*')
end)

test('quoteIdentifier: rejects injection attempts', function()
    throws(function() QueryBuilder.quoteIdentifier('id; DROP TABLE users') end, 'semicolon')
    throws(function() QueryBuilder.quoteIdentifier('id`') end, 'stray backtick')
    throws(function() QueryBuilder.quoteIdentifier('(SELECT 1)') end, 'subquery')
    throws(function() QueryBuilder.quoteIdentifier('a b') end, 'space')
    throws(function() QueryBuilder.quoteIdentifier('') end, 'empty')
end)

test('where: a malicious column name is rejected', function()
    throws(function()
        QueryBuilder.new('users'):where('name = 1 OR 1=1 -- ', 'x'):toSql()
    end)
end)

test('where: an operator outside the allowlist is rejected', function()
    throws(function()
        QueryBuilder.new('users'):where('id', 'UNION SELECT', 1):toSql()
    end)
end)

test('orderBy: a non-ASC/DESC direction is rejected', function()
    throws(function()
        QueryBuilder.new('users'):orderBy('name', 'ASC; DROP TABLE users'):toSql()
    end)
end)

test('limit: a non-numeric limit is rejected', function()
    throws(function()
        QueryBuilder.new('users'):limit('1; DROP TABLE users'):toSql()
    end)
end)

test('selectRaw: aggregate expression passes through unquoted', function()
    local sql = QueryBuilder.new('users'):selectRaw('COUNT(*) as count'):toSql()
    eq(sql, 'SELECT COUNT(*) as count FROM `users`')
end)

test('join: qualified identifiers quote each part (belongsToMany path)', function()
    local sql = QueryBuilder.new('items')
        :join('inventory_items', 'items.id', '=', 'inventory_items.item_id')
        :where('inventory_items.inventory_id', 5)
        :toSql()
    eq(sql, 'SELECT * FROM `items` INNER JOIN `inventory_items` ON `items`.`id` = ' ..
        '`inventory_items`.`item_id` WHERE `inventory_items`.`inventory_id` = ?')
end)

--------------------------------------------------------------------------------
-- Schema blueprint -> CREATE TABLE
--------------------------------------------------------------------------------
test('Schema.create: generates a CREATE TABLE statement', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('users', function(t)
        t:id()
        t:string('name', 100)
        t:integer('age')
        t:timestamps()
    end)

    Database.querySync = original

    truthy(captured:find('CREATE TABLE IF NOT EXISTS `users`', 1, true), 'has CREATE TABLE header')
    truthy(captured:find('`id` INT NOT NULL AUTO_INCREMENT', 1, true), 'has auto-increment id')
    truthy(captured:find('PRIMARY KEY (`id`)', 1, true), 'has primary key')
    truthy(captured:find('`name` VARCHAR(100) NOT NULL', 1, true), 'has not-null varchar')
    truthy(captured:find('ENGINE=InnoDB', 1, true), 'has InnoDB engine')
end)

test('Schema.create: updated_at has no ON UPDATE clause (app layer owns it)', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('players', function(t)
        t:id()
        t:timestamps()
    end)

    Database.querySync = original

    truthy(captured:find('`updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP', 1, true),
        'updated_at defaults to CURRENT_TIMESTAMP')
    truthy(not captured:find('ON UPDATE', 1, true), 'no ON UPDATE clause (BaseModel sets updated_at itself)')
end)

test('Blueprint: string() defaults to NOT NULL', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:string('name', 50)
    end)

    Database.querySync = original

    truthy(captured:find('`name` VARCHAR(50) NOT NULL', 1, true), 'string() is NOT NULL by default')
end)

test('Blueprint: nullable() with no args makes the last column optional', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:string('nickname', 50):nullable()
    end)

    Database.querySync = original

    truthy(not captured:find('`nickname` VARCHAR(50) NOT NULL', 1, true), 'nullable() removes NOT NULL')
    truthy(captured:find('`nickname` VARCHAR(50)', 1, true), 'column still present')
end)

test('Blueprint: nullable(false) makes the last column required, same as the new default', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:integer('count'):nullable(false)
    end)

    Database.querySync = original

    truthy(captured:find('`count` INT NOT NULL', 1, true), 'nullable(false) is NOT NULL')
end)

test('Blueprint: calling the removed notNullable() raises an error', function()
    throws(function()
        Schema.create('widgets', function(t)
            t:id()
            t:string('name', 50):notNullable()
        end)
    end, 'notNullable() must no longer exist on Blueprint')
end)

test('Blueprint: every column builder except id() defaults to NOT NULL', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('kitchen_sink', function(t)
        t:id()
        t:string('a', 10)
        t:text('b')
        t:json('c')
        t:integer('d')
        t:bigInteger('e')
        t:unsignedInteger('f')
        t:float('g')
        t:decimal('h')
        t:boolean('i')
        t:date('j')
        t:datetime('k')
        t:timestamp('l')
        t:enum('m', {'x', 'y'})
    end)

    Database.querySync = original

    for _, col in ipairs({'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm'}) do
        truthy(captured:find('`' .. col .. '`.-NOT NULL', 1, false) ~= nil or captured:find('`' .. col .. '` .- NOT NULL'),
            col .. ' should be NOT NULL by default')
    end
end)

test('Blueprint: change() marks only the most-recently-defined column', function()
    local blueprint = Schema.Blueprint.new('widgets')
    blueprint:string('a', 50)
    blueprint:string('b', 50):nullable(false):change()

    eq(blueprint.columns[1].change, nil, 'first column untouched')
    eq(blueprint.columns[2].change, true, 'second column marked for change')
end)

test('Schema.table: a :change()-marked column calls the dialect introspect+alter path, not ADD COLUMN', function()
    local introspectCalledWith, alterCalledWith
    local fakeDialect = {
        quoteIdentifier = Database.dialect.quoteIdentifier,
        columnType = Database.dialect.columnType,
        formatDefault = Database.dialect.formatDefault,
        alterAddIndexStatements = Database.dialect.alterAddIndexStatements,
        introspectColumn = function(tableName, columnName)
            introspectCalledWith = {tableName, columnName}
            return {type = 'varchar', length = 50, nullable = true, default = nil}
        end,
        alterModifyColumnStatements = function(tableName, col, currentInfo, q)
            alterCalledWith = {tableName, col, currentInfo}
            return {'-- fake alter statement --'}
        end,
    }

    local original = Database.dialect
    Database.dialect = fakeDialect

    local executed = {}
    local originalQuery = Database.querySync
    Database.querySync = function(query) table.insert(executed, query) return {} end

    Schema.table('widgets', function(t)
        t:string('name', 50):nullable(false):change()
    end)

    Database.querySync = originalQuery
    Database.dialect = original

    truthy(introspectCalledWith ~= nil, 'introspectColumn was called')
    eq(introspectCalledWith[1], 'widgets')
    eq(introspectCalledWith[2], 'name')
    truthy(alterCalledWith ~= nil, 'alterModifyColumnStatements was called')
    eq(#executed, 1, 'exactly one statement executed')
    eq(executed[1], '-- fake alter statement --')
end)

test('Schema.table: an unmarked column still uses ADD COLUMN (existing behavior)', function()
    local captured = {}
    local original = Database.querySync
    Database.querySync = function(query) table.insert(captured, query) return {} end

    Schema.table('widgets', function(t)
        t:string('bio', 255)
    end)

    Database.querySync = original

    truthy(captured[1]:find('ADD COLUMN', 1, true), 'unmarked column still adds')
end)

test('Blueprint:foreignId/:constrained: guesses the referenced table and defaults to RESTRICT', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('vehicles', function(t)
        t:id()
        t:foreignId('garage_id'):constrained()
    end)

    Database.querySync = original

    truthy(captured:find('FOREIGN KEY (`garage_id`) REFERENCES `garages`(`id`)', 1, true),
        'guesses garages from garage_id')
    truthy(captured:find('ON DELETE RESTRICT ON UPDATE RESTRICT', 1, true), 'defaults to RESTRICT/RESTRICT')
end)

test('Blueprint:foreign: the :references():on():onDelete() chain resolves real names', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('items', function(t)
        t:id()
        t:integer('base_item_id')
        t:foreign('base_item_id'):references('id'):on('base_items'):onDelete('RESTRICT')
    end)

    Database.querySync = original

    -- Every call site in the codebase chains this with `:`, which passes the
    -- chain table as the first argument - the links must be real methods or
    -- `references`/`on` capture that table instead of the name.
    truthy(captured:find('FOREIGN KEY (`base_item_id`) REFERENCES `base_items`(`id`)', 1, true),
        'chain captured the column and table names, not the chain tables')
    truthy(captured:find('ON DELETE RESTRICT ON UPDATE RESTRICT', 1, true), 'actions applied')
end)

test('Blueprint:foreign: chaining onDelete then onUpdate registers exactly one key', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('items', function(t)
        t:id()
        t:integer('base_item_id')
        t:foreign('base_item_id'):references('id'):on('base_items'):onDelete('CASCADE'):onUpdate('CASCADE')
    end)

    Database.querySync = original

    local _, count = captured:gsub('FOREIGN KEY', '')
    eq(count, 1, 'the key is emitted once, not once per terminal call')
    truthy(captured:find('ON DELETE CASCADE ON UPDATE CASCADE', 1, true), 'both actions applied')
end)

test('Blueprint:foreignId: emits exactly the same column type as :id() (InnoDB FK requirement)', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('vehicles', function(t)
        t:id()
        t:foreignId('garage_id'):constrained('garages')
    end)

    Database.querySync = original

    -- InnoDB requires the FK column and the referenced column to have an
    -- identical type AND signedness. `id()` emits plain `INT`, so `foreignId`
    -- must too: `BIGINT UNSIGNED` (the old behaviour) or `INT UNSIGNED` both
    -- make the CREATE TABLE fail with MySQL error 3780 on a real database.
    truthy(captured:find('`garage_id` INT NOT NULL,', 1, true) or captured:find('`garage_id` INT NOT NULL\n', 1, true),
        'garage_id is plain INT, not BIGINT and not INT UNSIGNED')
    truthy(not captured:find('`garage_id` BIGINT', 1, true), 'not BIGINT')
    truthy(not captured:find('`garage_id` INT UNSIGNED', 1, true), 'not unsigned')
    truthy(captured:find('`id` INT NOT NULL AUTO_INCREMENT', 1, true),
        'referenced id column is plain INT (the type foreignId must match)')
end)

test('Blueprint:constrained/:onDelete: overrides the ON DELETE action', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {} end

    Schema.create('vehicles', function(t)
        t:id()
        t:foreignId('garage_id'):constrained():onDelete('CASCADE')
    end)

    Database.querySync = original

    truthy(captured:find('ON DELETE CASCADE ON UPDATE RESTRICT', 1, true), 'CASCADE applied, UPDATE still RESTRICT')
end)

test('Schema.table: ALTER TABLE emits the foreign key constraint too', function()
    local captured = {}
    local original = Database.querySync
    Database.querySync = function(query) table.insert(captured, query) return {} end

    Schema.table('vehicles', function(t)
        t:foreignId('garage_id'):constrained():onDelete('SET NULL')
    end)

    Database.querySync = original

    local addColumn, addConstraint
    for _, sql in ipairs(captured) do
        if sql:find('ADD COLUMN', 1, true) then addColumn = sql end
        if sql:find('ADD CONSTRAINT', 1, true) then addConstraint = sql end
    end

    truthy(addColumn, 'emitted ADD COLUMN')
    truthy(addConstraint, 'emitted ADD CONSTRAINT (this used to be silently dropped)')
    truthy(addConstraint:find('FOREIGN KEY (`garage_id`) REFERENCES `garages`(`id`)', 1, true),
        'constraint references the guessed table')
    truthy(addConstraint:find('ON DELETE SET NULL', 1, true), 'ON DELETE action carried through')
end)

--------------------------------------------------------------------------------
-- Postgres dialect
--------------------------------------------------------------------------------
local function withDialect(name, fn)
    local original = Database.dialect
    Database.dialect = Dialects.resolve(name)
    local ok, err = pcall(fn)
    Database.dialect = original
    if not ok then error(err, 2) end
end

test('postgres: quoteIdentifier uses double quotes', function()
    withDialect('postgres', function()
        eq(QueryBuilder.quoteIdentifier('users'), '"users"')
        eq(QueryBuilder.quoteIdentifier('items.id'), '"items"."id"')
    end)
end)

test('postgres: quoteIdentifier still rejects illegal identifiers', function()
    withDialect('postgres', function()
        throws(function() QueryBuilder.quoteIdentifier('name; DROP TABLE users') end)
    end)
end)

test('postgres: toSql uses double-quoted identifiers', function()
    withDialect('postgres', function()
        local sql, params = QueryBuilder.new('users'):where('age', '>', 18):toSql()
        eq(sql, 'SELECT * FROM "users" WHERE "age" > ?')
        eqList(params, {18})
    end)
end)

test('postgres: Schema.create produces SERIAL PRIMARY KEY, no ENGINE clause', function()
    withDialect('postgres', function()
        local captured
        local original = Database.querySync
        Database.querySync = function(query) captured = query return {} end

        Schema.create('users', function(t)
            t:id()
            t:string('name', 100)
            t:boolean('active')
        end)

        Database.querySync = original

        truthy(captured:find('CREATE TABLE IF NOT EXISTS "users"', 1, true), 'has CREATE TABLE header')
        truthy(captured:find('"id" SERIAL NOT NULL', 1, true), 'has SERIAL id')
        truthy(captured:find('PRIMARY KEY ("id")', 1, true), 'has primary key')
        truthy(captured:find('"name" VARCHAR(100) NOT NULL', 1, true), 'has not-null varchar')
        truthy(captured:find('"active" BOOLEAN NOT NULL DEFAULT FALSE', 1, true), 'boolean default renders as FALSE')
        truthy(not captured:find('ENGINE', 1, true), 'no MySQL ENGINE clause')
    end)
end)

test('postgres: plain index becomes a standalone CREATE INDEX, unique stays inline', function()
    withDialect('postgres', function()
        local captured = {}
        local original = Database.querySync
        Database.querySync = function(query) table.insert(captured, query) return {} end

        Schema.create('players', function(t)
            t:id()
            t:string('name', 100)
            t:index('name')
            t:unique('name', 'players_name_unique')
        end)

        Database.querySync = original

        eq(#captured, 2, 'one CREATE TABLE + one standalone CREATE INDEX')
        truthy(captured[1]:find('CONSTRAINT "players_name_unique" UNIQUE ("name")', 1, true),
            'unique constraint is inline')
        truthy(not captured[1]:find('CREATE INDEX', 1, true), 'CREATE TABLE has no inline plain index')
        truthy(captured[2]:find('CREATE INDEX IF NOT EXISTS "players_name_index" ON "players" ("name")', 1, true),
            'plain index is a standalone, idempotent statement (safe to re-run against an existing table)')
    end)
end)

test('postgres: ALTER TABLE ADD INDEX is also idempotent (CREATE INDEX IF NOT EXISTS)', function()
    withDialect('postgres', function()
        local q = Database.dialect.quoteIdentifier
        local stmts = Database.dialect.alterAddIndexStatements('players', {name = 'players_name_index', columns = {'name'}, unique = false}, q)
        eq(#stmts, 1)
        eq(stmts[1], 'CREATE INDEX IF NOT EXISTS "players_name_index" ON "players" ("name");')
    end)
end)

--------------------------------------------------------------------------------
-- Schema.hasTable / Schema.hasColumn dialect parity
--------------------------------------------------------------------------------
test('mysql: hasTable queries TABLE_SCHEMA = DATABASE()', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {{count = 1}} end

    local exists = Schema.hasTable('users')

    Database.querySync = original
    truthy(captured:find('TABLE_SCHEMA = DATABASE()', 1, true), 'uses DATABASE() to scope TABLE_SCHEMA')
    eq(exists, true)
end)

test('postgres: hasTable queries table_catalog/table_schema, not TABLE_SCHEMA = current_database()', function()
    withDialect('postgres', function()
        local captured
        local original = Database.querySync
        Database.querySync = function(query) captured = query return {{count = 1}} end

        local exists = Schema.hasTable('users')

        Database.querySync = original
        truthy(captured:find('table_catalog = current_database() AND table_schema = current_schema()', 1, true),
            'scopes by table_catalog + table_schema, not the MySQL-only TABLE_SCHEMA = current_database()')
        truthy(not captured:find('TABLE_SCHEMA = current_database()', 1, true),
            'does not use the MySQL-shaped predicate under postgres')
        eq(exists, true)
    end)
end)

test('postgres: hasTable copes with a string-typed COUNT(*) result (pg returns bigint as string)', function()
    withDialect('postgres', function()
        local original = Database.querySync
        Database.querySync = function() return {{count = '0'}} end
        local exists = Schema.hasTable('users')
        Database.querySync = original
        eq(exists, false)
    end)
end)

test('mysql: hasColumn queries TABLE_SCHEMA = DATABASE()', function()
    local captured
    local original = Database.querySync
    Database.querySync = function(query) captured = query return {{count = 1}} end

    local exists = Schema.hasColumn('users', 'name')

    Database.querySync = original
    truthy(captured:find('TABLE_SCHEMA = DATABASE()', 1, true), 'uses DATABASE() to scope TABLE_SCHEMA')
    eq(exists, true)
end)

test('postgres: hasColumn queries table_catalog/table_schema', function()
    withDialect('postgres', function()
        local captured
        local original = Database.querySync
        Database.querySync = function(query) captured = query return {{count = '1'}} end

        local exists = Schema.hasColumn('users', 'name')

        Database.querySync = original
        truthy(captured:find('table_catalog = current_database() AND table_schema = current_schema()', 1, true),
            'scopes by table_catalog + table_schema')
        eq(exists, true, 'a string "1" count (as pg returns) must still compare as existing')
    end)
end)

--------------------------------------------------------------------------------
-- QueryBuilder:count / countSync coping with string-typed pg results
--------------------------------------------------------------------------------
test('countSync: coerces a string count (pg bigint) to a number', function()
    local qb = QueryBuilder.new('users')
    qb.firstSync = function() return {count = '3'} end
    local result = qb:countSync()
    eq(result, 3)
end)

test('count (async): coerces a string count (pg bigint) to a number', function()
    local qb = QueryBuilder.new('users')
    qb.first = function(_, callback) callback({count = '7'}) end
    local received
    qb:count(function(n) received = n end)
    eq(received, 7)
end)

test('postgres: renameColumn uses RENAME COLUMN, not CHANGE', function()
    withDialect('postgres', function()
        local captured
        local original = Database.querySync
        Database.querySync = function(query) captured = query return {} end

        Schema.renameColumn('users', 'old_name', 'new_name')

        Database.querySync = original
        eq(captured, 'ALTER TABLE "users" RENAME COLUMN "old_name" TO "new_name"')
    end)
end)

test('postgres: insert appends RETURNING <primaryKey>', function()
    withDialect('postgres', function()
        withCapture(function(get)
            QueryBuilder.new('users', 'id'):insert({name = 'bob'})
            truthy(get().query:find('RETURNING "id"', 1, true), 'insert has RETURNING clause')
        end)
    end)
end)

--------------------------------------------------------------------------------
-- BaseModel timestamps (regression test for the DATETIME fix)
--------------------------------------------------------------------------------
test('BaseModel.createSync: writes DATETIME-formatted timestamps', function()
    withCapture(function()
        local Player = setmetatable({}, {__index = BaseModel})
        Player.table = 'players'
        Player.primaryKey = 'id'
        Player.timestamps = true

        local player = Player:createSync({name = 'bob'})

        eq(player.attributes.id, 1)
        truthy(player.attributes.created_at:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$'),
            'created_at is YYYY-MM-DD HH:MM:SS, got: ' .. tostring(player.attributes.created_at))
        truthy(player.attributes.updated_at:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$'),
            'updated_at is YYYY-MM-DD HH:MM:SS')
    end)
end)

test('BaseModel query proxy: Model:where(...) starts a query directly', function()
    withCapture(function(get)
        local Player = setmetatable({}, {__index = BaseModel})
        Player.table = 'players'
        Player.primaryKey = 'id'

        Player:where('level', '>=', 10):orderBy('name'):limit(5):getSync()

        eq(get().query, 'SELECT * FROM `players` WHERE `level` >= ? ORDER BY `name` ASC LIMIT 5')
        eqList(get().params, {10})
    end)
end)

test('BaseModel query proxy: works on an extend()-based subclass too', function()
    withCapture(function(get)
        local Item = BaseModel:extend('items')
        Item.primaryKey = 'id'

        Item:whereIn('kind', {'weapon', 'armor'}):getSync()

        eq(get().query, 'SELECT * FROM `items` WHERE `kind` IN (?, ?)')
        eqList(get().params, {'weapon', 'armor'})
    end)
end)

--------------------------------------------------------------------------------
-- BaseModel JSON casts
--------------------------------------------------------------------------------
test('BaseModel casts: json cast field decodes from a JSON string on find', function()
    local original = Database.executeQuery
    Database.executeQuery = function(query, params)
        return {{ id = 1, name = 'Test', meta = '{"a":1}' }}
    end

    local Widget = setmetatable({}, {__index = BaseModel})
    Widget.table = 'widgets'
    Widget.primaryKey = 'id'
    Widget.timestamps = false
    Widget.casts = { meta = 'json' }

    local widget = Widget:findSync(1)
    Database.executeQuery = original

    truthy(type(widget.attributes.meta) == 'table', 'meta decoded into a table')
    eq(widget.attributes.meta.a, 1)
end)

test('BaseModel casts: json cast field is JSON-encoded for the write, stays a table in memory', function()
    withCapture(function(get)
        local Widget = setmetatable({}, {__index = BaseModel})
        Widget.table = 'widgets'
        Widget.primaryKey = 'id'
        Widget.timestamps = false
        Widget.casts = { meta = 'json' }

        local widget = Widget.new({ meta = { a = 1 } })
        -- BaseModel.new() (unlike Widget:create()/newFromQuery()) doesn't
        -- copy class config onto the instance, so mirror that copy step here.
        widget.table = Widget.table
        widget.primaryKey = Widget.primaryKey
        widget.timestamps = Widget.timestamps
        widget.casts = Widget.casts
        widget:saveSync()

        truthy(type(widget.attributes.meta) == 'table', 'in-memory meta stays a table after save')

        local metaParam
        for _, p in ipairs(get().params) do
            if type(p) == 'string' and p:find('"a"', 1, true) then
                metaParam = p
            end
        end
        truthy(metaParam ~= nil, 'meta was JSON-encoded in the write params')
    end)
end)

test('BaseModel casts: malformed json cast field decodes to an empty table, no error', function()
    local original = Database.executeQuery
    Database.executeQuery = function() return {{ id = 1, meta = 'not-json{' }} end

    local Widget = setmetatable({}, {__index = BaseModel})
    Widget.table = 'widgets'
    Widget.primaryKey = 'id'
    Widget.timestamps = false
    Widget.casts = { meta = 'json' }

    local widget = Widget:findSync(1)
    Database.executeQuery = original

    eqList(widget.attributes.meta, {})
end)

--------------------------------------------------------------------------------
-- Connector detection / hard-fail (no in-memory fallback)
--------------------------------------------------------------------------------
test('detectConnector: nil when none is started', function()
    local original = GetResourceState
    _G.GetResourceState = function() return 'stopped' end
    local connector = Database.detectConnector()
    _G.GetResourceState = original
    eq(connector, nil)
end)

test('detectConnector: returns the started connector', function()
    local original = GetResourceState
    _G.GetResourceState = function(name) return name == 'oxmysql' and 'started' or 'stopped' end
    local connector = Database.detectConnector()
    _G.GetResourceState = original
    eq(connector, 'oxmysql')
end)

test('init: fails and stays not-ready when no connector is present', function()
    local originalGRS, savedConnector = GetResourceState, Database.connector
    _G.GetResourceState = function() return 'stopped' end
    local ok = Database.init()
    _G.GetResourceState, Database.connector = originalGRS, savedConnector
    eq(ok, false)
    eq(Database.ready, false)
end)

test('init: succeeds and records the connector when one is present', function()
    local originalGRS, savedConnector = GetResourceState, Database.connector
    _G.GetResourceState = function(name) return name == 'ghmattimysql' and 'started' or 'stopped' end
    local ok = Database.init()
    local detected = Database.connector
    _G.GetResourceState, Database.connector = originalGRS, savedConnector
    eq(ok, true)
    eq(detected, 'ghmattimysql')
end)

test('executeQuery: errors instead of silently falling back when no connector', function()
    local savedConnector = Database.connector
    Database.connector = nil
    throws(function() Database.executeQuery('SELECT 1', {}) end)
    Database.connector = savedConnector
end)

test('executeQuery: forwards raw query + params to oblsk_connector', function()
    local savedConnector, captured = Database.connector, nil
    exports.oblsk_connector = {
        executeSync = function(_, q, p) captured = {query = q, params = p} return {} end,
    }
    Database.connector = 'oblsk_connector'

    Database.executeQuery('SELECT * FROM users WHERE id = ?', {5})

    exports.oblsk_connector = nil
    Database.connector = savedConnector

    -- The connector escapes params itself, so core must pass the placeholder
    -- query and the params array through untouched (not a pre-interpolated string).
    eq(captured.query, 'SELECT * FROM users WHERE id = ?')
    eqList(captured.params, {5})
end)

--------------------------------------------------------------------------------
-- Database driver resolution
--------------------------------------------------------------------------------
test('parseConnectionString: mysql scheme (default port 3306)', function()
    local cfg = Database.parseConnectionString('mysql://obelisk:secret@db:3307/fivem')
    eq(cfg.driver, 'mysql')
    eq(cfg.user, 'obelisk')
    eq(cfg.password, 'secret')
    eq(cfg.host, 'db')
    eq(cfg.port, 3307)
    eq(cfg.database, 'fivem')
end)

test('parseConnectionString: postgres scheme defaults port 5432', function()
    local cfg = Database.parseConnectionString('postgres://obelisk:secret@db/fivem')
    eq(cfg.driver, 'postgres')
    eq(cfg.port, 5432)
end)

test('Database.init: db_driver convar wins over connection-string scheme', function()
    local originalConvar, originalConnStr = _G.GetConvar, nil
    _G.GetConvar = function(name, default)
        if name == 'mysql_connection_string' then return 'postgres://obelisk:secret@db/fivem' end
        if name == 'db_driver' then return 'mysql' end
        return default
    end
    _G.GetResourceState = function(name) return name == 'oxmysql' and 'started' or 'stopped' end

    local ok = Database.init()
    _G.GetConvar = originalConvar
    _G.GetResourceState = function() return 'stopped' end

    truthy(ok, 'init should succeed (mysql driver + mysql-only connector is valid)')
    eq(Database.config.driver, 'mysql')
    eq(Database.dialect.quoteIdentifier('x'), '`x`')
end)

test('Database.init: postgres driver with a mysql-only connector fails fast', function()
    local originalConvar = _G.GetConvar
    _G.GetConvar = function(name, default)
        if name == 'db_driver' then return 'postgres' end
        return default
    end
    _G.GetResourceState = function(name) return name == 'oxmysql' and 'started' or 'stopped' end

    local ok = Database.init()
    _G.GetConvar = originalConvar
    _G.GetResourceState = function() return 'stopped' end

    -- Reset global state (immediately, before any assertion can error) so later
    -- tests (which assume the mysql default) aren't affected.
    Database.config.driver = 'mysql'
    Database.dialect = Dialects.resolve('mysql')

    truthy(not ok, 'init should fail: oxmysql cannot serve postgres')
    truthy(not Database.ready, 'Database.ready must stay false')
end)

test('Database.init: postgres-scheme connection string alone does NOT select postgres (db_driver is the only source)', function()
    local originalConvar = _G.GetConvar
    _G.GetConvar = function(name, default)
        if name == 'mysql_connection_string' then return 'postgres://obelisk:secret@db/fivem' end
        -- db_driver deliberately left unset here.
        return default
    end
    _G.GetResourceState = function(name) return name == 'oxmysql' and 'started' or 'stopped' end

    Database.config.driver = nil
    local ok = Database.init()
    _G.GetConvar = originalConvar
    _G.GetResourceState = function() return 'stopped' end

    truthy(ok, 'init should succeed: with no db_driver convar the driver must default to mysql, ' ..
        'a valid pairing with the mysql-only oxmysql connector')
    eq(Database.config.driver, 'mysql',
        'a postgres:// connection string must NOT set the driver by itself; only db_driver may')
    eq(Database.dialect.quoteIdentifier('x'), '`x`')
end)

test('Database.init: postgres driver with oblsk_connector succeeds', function()
    local originalConvar = _G.GetConvar
    _G.GetConvar = function(name, default)
        if name == 'db_driver' then return 'postgres' end
        return default
    end
    _G.GetResourceState = function(name) return name == 'oblsk_connector' and 'started' or 'stopped' end

    local ok = Database.init()
    _G.GetConvar = originalConvar
    _G.GetResourceState = function() return 'stopped' end

    -- Reset global state (immediately, before any assertion can error) so later
    -- tests (which assume the mysql default) aren't affected.
    local dialectAtInit = Database.dialect
    Database.config.driver = 'mysql'
    Database.dialect = Dialects.resolve('mysql')

    truthy(ok, 'init should succeed')
    eq(dialectAtInit.quoteIdentifier('x'), '"x"')
end)

--------------------------------------------------------------------------------
-- Database.transaction orchestration
--------------------------------------------------------------------------------
test('transaction: queues statements in order and commits them', function()
    local committed
    local original = Database.commitTransaction
    Database.commitTransaction = function(queries) committed = queries return true end

    local ok = Database.transaction(function(tx)
        tx:add('UPDATE accounts SET balance = balance - ? WHERE id = ?', {100, 1})
        tx:add('UPDATE accounts SET balance = balance + ? WHERE id = ?', {100, 2})
    end)

    Database.commitTransaction = original

    eq(ok, true)
    eq(#committed, 2)
    eq(committed[1].query, 'UPDATE accounts SET balance = balance - ? WHERE id = ?')
    eqList(committed[1].params, {100, 1})
    eqList(committed[2].params, {100, 2})
end)

test('transaction: a callback error aborts without committing', function()
    local called = false
    local original = Database.commitTransaction
    Database.commitTransaction = function() called = true return true end

    local ok = Database.transaction(function(tx)
        tx:add('INSERT INTO t (a) VALUES (?)', {1})
        error('boom')
    end)

    Database.commitTransaction = original

    eq(ok, false)
    eq(called, false, 'commit must not run when the callback errors')
end)

test('transaction: an empty transaction commits nothing and succeeds', function()
    local called = false
    local original = Database.commitTransaction
    Database.commitTransaction = function() called = true return true end

    local ok = Database.transaction(function() end)

    Database.commitTransaction = original

    eq(ok, true)
    eq(called, false)
end)

test('commitTransactionFallback: wraps statements in BEGIN/COMMIT', function()
    local calls = {}
    local original = Database.executeQuery
    Database.executeQuery = function(query) calls[#calls + 1] = query return {} end

    local ok = Database.commitTransactionFallback({
        {query = 'INSERT INTO t (a) VALUES (?)', params = {1}},
        {query = 'UPDATE t SET a = ? WHERE id = ?', params = {2, 1}},
    })

    Database.executeQuery = original

    eq(ok, true)
    eqList(calls, {
        'START TRANSACTION',
        'INSERT INTO t (a) VALUES (?)',
        'UPDATE t SET a = ? WHERE id = ?',
        'COMMIT',
    })
end)

test('commitTransactionFallback: rolls back and stops on a failing statement', function()
    local calls = {}
    local original = Database.executeQuery
    Database.executeQuery = function(query)
        calls[#calls + 1] = query
        if query == 'BOOM' then error('statement failed') end
        return {}
    end

    local ok = Database.commitTransactionFallback({
        {query = 'INSERT INTO t (a) VALUES (?)', params = {1}},
        {query = 'BOOM', params = {}},
        {query = 'SHOULD NOT RUN', params = {}},
    })

    Database.executeQuery = original

    eq(ok, false)
    eqList(calls, {
        'START TRANSACTION',
        'INSERT INTO t (a) VALUES (?)',
        'BOOM',
        'ROLLBACK',
    })
end)

test('MySQLDialect.introspectColumn: queries information_schema and parses the row', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local capturedSql, capturedParams
    local original = Database.querySync
    Database.querySync = function(sql, params)
        capturedSql, capturedParams = sql, params
        return {{DATA_TYPE = 'varchar', CHARACTER_MAXIMUM_LENGTH = 100, IS_NULLABLE = 'YES', COLUMN_DEFAULT = nil}}
    end

    local info = MySQLDialect.introspectColumn('widgets', 'name')

    Database.querySync = original

    truthy(capturedSql:find('information_schema.COLUMNS', 1, true), 'queries information_schema.COLUMNS')
    eqList(capturedParams, {'widgets', 'name'})
    eq(info.type, 'varchar')
    eq(info.length, 100)
    eq(info.nullable, true)
    eq(info.default, nil)
end)

test('MySQLDialect.introspectColumn: returns nil when the column does not exist', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local original = Database.querySync
    Database.querySync = function() return {} end

    local info = MySQLDialect.introspectColumn('widgets', 'ghost')

    Database.querySync = original

    eq(info, nil)
end)

test('MySQLDialect.alterModifyColumnStatements: restates the full column, merging unstated attributes from introspection', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local q = MySQLDialect.quoteIdentifier
    -- The migration only changes nullability; type/length/default are NOT
    -- restated by the caller, and must come from currentInfo instead.
    local col = {name = 'name', kind = 'string', opts = {}, nullable = false}
    local currentInfo = {type = 'varchar', length = 100, nullable = true, default = 'unknown'}

    local statements = MySQLDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

    eq(#statements, 1)
    truthy(statements[1]:find('MODIFY COLUMN', 1, true), 'uses MODIFY COLUMN')
    truthy(statements[1]:find('VARCHAR(100)', 1, true), 'restates the original length even though the migration did not specify it')
    truthy(statements[1]:find('NOT NULL', 1, true), 'applies the new nullability')
    truthy(statements[1]:find("DEFAULT 'unknown'", 1, true), 'restates the original default so it is not silently dropped')
end)

test('MySQLDialect.alterModifyColumnStatements: an explicit new type/default on the migration overrides introspection', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local q = MySQLDialect.quoteIdentifier
    local col = {name = 'name', kind = 'string', opts = {length = 150}, nullable = true, default = 'fallback', _explicitType = true, _explicitDefault = true}
    local currentInfo = {type = 'varchar', length = 100, nullable = false, default = nil}

    local statements = MySQLDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

    truthy(statements[1]:find('VARCHAR(150)', 1, true), "uses the migration's new length, not the introspected one")
    truthy(statements[1]:find("DEFAULT 'fallback'", 1, true), "uses the migration's new default")
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running ORM unit tests\n')
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
