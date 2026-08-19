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

local function falsy(v, msg)
    if v then error(msg or 'expected a falsy value', 2) end
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
-- QueryBuilder insert / update / delete sync + ...Async split
--------------------------------------------------------------------------------
test('QueryBuilder.insert: sync form returns insertId with no callback', function()
    local original = Database.insert
    Database.insert = function(sql, values) return 42 end
    local id = QueryBuilder.new('widgets'):insert({name = 'a'})
    Database.insert = original
    eq(id, 42, 'insert: sync insertId')
end)

test('QueryBuilder.insertAsync: calls back with insertId', function()
    local original = Database.insertAsync
    local capturedCallback
    Database.insertAsync = function(sql, values, callback) capturedCallback = callback end
    local received
    QueryBuilder.new('widgets'):insertAsync({name = 'a'}, function(id) received = id end)
    capturedCallback(7)
    Database.insertAsync = original
    eq(received, 7, 'insertAsync: callback receives insertId')
end)

test('QueryBuilder.update: sync form returns affectedRows with no callback', function()
    local original = Database.update
    Database.update = function(sql, values) return 3 end
    local affected = QueryBuilder.new('widgets'):where('id', 1):update({name = 'b'})
    Database.update = original
    eq(affected, 3, 'update: sync affectedRows')
end)

test('QueryBuilder.updateAsync: calls back with affectedRows', function()
    local original = Database.updateAsync
    local capturedCallback
    Database.updateAsync = function(sql, values, callback) capturedCallback = callback end
    local received
    QueryBuilder.new('widgets'):where('id', 1):updateAsync({name = 'b'}, function(affected) received = affected end)
    capturedCallback(1)
    Database.updateAsync = original
    eq(received, 1, 'updateAsync: callback receives affectedRows')
end)

test('QueryBuilder.delete: sync form returns affectedRows with no callback', function()
    local original = Database.update
    Database.update = function(sql, values) return 1 end
    local affected = QueryBuilder.new('widgets'):where('id', 1):delete()
    Database.update = original
    eq(affected, 1, 'delete: sync affectedRows')
end)

test('QueryBuilder.deleteAsync: calls back with affectedRows', function()
    local original = Database.updateAsync
    local capturedCallback
    Database.updateAsync = function(sql, values, callback) capturedCallback = callback end
    local received
    QueryBuilder.new('widgets'):where('id', 1):deleteAsync(function(affected) received = affected end)
    capturedCallback(2)
    Database.updateAsync = original
    eq(received, 2, 'deleteAsync: callback receives affectedRows')
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
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('users', function(t)
        t:id()
        t:string('name', 100)
        t:integer('age')
        t:timestamps()
    end)

    Database.query = original

    truthy(captured:find('CREATE TABLE IF NOT EXISTS `users`', 1, true), 'has CREATE TABLE header')
    truthy(captured:find('`id` INT NOT NULL AUTO_INCREMENT', 1, true), 'has auto-increment id')
    truthy(captured:find('PRIMARY KEY (`id`)', 1, true), 'has primary key')
    truthy(captured:find('`name` VARCHAR(100) NOT NULL', 1, true), 'has not-null varchar')
    truthy(captured:find('ENGINE=InnoDB', 1, true), 'has InnoDB engine')
end)

test('Schema.create: updated_at has no ON UPDATE clause (app layer owns it)', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('players', function(t)
        t:id()
        t:timestamps()
    end)

    Database.query = original

    truthy(captured:find('`updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP', 1, true),
        'updated_at defaults to CURRENT_TIMESTAMP')
    truthy(not captured:find('ON UPDATE', 1, true), 'no ON UPDATE clause (BaseModel sets updated_at itself)')
end)

test('Blueprint: string() defaults to NOT NULL', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:string('name', 50)
    end)

    Database.query = original

    truthy(captured:find('`name` VARCHAR(50) NOT NULL', 1, true), 'string() is NOT NULL by default')
end)

test('Blueprint: nullable() with no args makes the last column optional', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:string('nickname', 50):nullable()
    end)

    Database.query = original

    truthy(not captured:find('`nickname` VARCHAR(50) NOT NULL', 1, true), 'nullable() removes NOT NULL')
    truthy(captured:find('`nickname` VARCHAR(50)', 1, true), 'column still present')
end)

test('Blueprint: nullable(false) makes the last column required, same as the new default', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:integer('count'):nullable(false)
    end)

    Database.query = original

    truthy(captured:find('`count` INT NOT NULL', 1, true), 'nullable(false) is NOT NULL')
end)

test('Blueprint: index() with no args uses the last-defined column', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('widgets', function(t)
        t:id()
        t:string('name', 50):index()
    end)

    Database.query = original

    truthy(captured:find('KEY `widgets_name_index` (`name`)', 1, true),
        'index() with no args builds a non-unique index on the last column')
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
    local original = Database.query
    Database.query = function(query) captured = query return {} end

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

    Database.query = original

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
    local originalQuery = Database.query
    Database.query = function(query) table.insert(executed, query) return {} end

    Schema.table('widgets', function(t)
        t:string('name', 50):nullable(false):change()
    end)

    Database.query = originalQuery
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
    local original = Database.query
    Database.query = function(query) table.insert(captured, query) return {} end

    Schema.table('widgets', function(t)
        t:string('bio', 255)
    end)

    Database.query = original

    truthy(captured[1]:find('ADD COLUMN', 1, true), 'unmarked column still adds')
end)

test('Blueprint:foreignId/:constrained: guesses the referenced table and defaults to RESTRICT', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('vehicles', function(t)
        t:id()
        t:foreignId('garage_id'):constrained()
    end)

    Database.query = original

    truthy(captured:find('FOREIGN KEY (`garage_id`) REFERENCES `garages`(`id`)', 1, true),
        'guesses garages from garage_id')
    truthy(captured:find('ON DELETE RESTRICT ON UPDATE RESTRICT', 1, true), 'defaults to RESTRICT/RESTRICT')
end)

test('Blueprint:foreign: the :references():on():onDelete() chain resolves real names', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('items', function(t)
        t:id()
        t:integer('base_item_id')
        t:foreign('base_item_id'):references('id'):on('base_items'):onDelete('RESTRICT')
    end)

    Database.query = original

    -- Every call site in the codebase chains this with `:`, which passes the
    -- chain table as the first argument - the links must be real methods or
    -- `references`/`on` capture that table instead of the name.
    truthy(captured:find('FOREIGN KEY (`base_item_id`) REFERENCES `base_items`(`id`)', 1, true),
        'chain captured the column and table names, not the chain tables')
    truthy(captured:find('ON DELETE RESTRICT ON UPDATE RESTRICT', 1, true), 'actions applied')
end)

test('Blueprint:foreign: chaining onDelete then onUpdate registers exactly one key', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('items', function(t)
        t:id()
        t:integer('base_item_id')
        t:foreign('base_item_id'):references('id'):on('base_items'):onDelete('CASCADE'):onUpdate('CASCADE')
    end)

    Database.query = original

    local _, count = captured:gsub('FOREIGN KEY', '')
    eq(count, 1, 'the key is emitted once, not once per terminal call')
    truthy(captured:find('ON DELETE CASCADE ON UPDATE CASCADE', 1, true), 'both actions applied')
end)

test('Blueprint:foreignId: emits exactly the same column type as :id() (InnoDB FK requirement)', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('vehicles', function(t)
        t:id()
        t:foreignId('garage_id'):constrained('garages')
    end)

    Database.query = original

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
    local original = Database.query
    Database.query = function(query) captured = query return {} end

    Schema.create('vehicles', function(t)
        t:id()
        t:foreignId('garage_id'):constrained():onDelete('CASCADE')
    end)

    Database.query = original

    truthy(captured:find('ON DELETE CASCADE ON UPDATE RESTRICT', 1, true), 'CASCADE applied, UPDATE still RESTRICT')
end)

test('Schema.table: ALTER TABLE emits the foreign key constraint too', function()
    local captured = {}
    local original = Database.query
    Database.query = function(query) table.insert(captured, query) return {} end

    Schema.table('vehicles', function(t)
        t:foreignId('garage_id'):constrained():onDelete('SET NULL')
    end)

    Database.query = original

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
        local original = Database.query
        Database.query = function(query) captured = query return {} end

        Schema.create('users', function(t)
            t:id()
            t:string('name', 100)
            t:boolean('active')
        end)

        Database.query = original

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
        local original = Database.query
        Database.query = function(query) table.insert(captured, query) return {} end

        Schema.create('players', function(t)
            t:id()
            t:string('name', 100)
            t:index('name')
            t:unique('name', 'players_name_unique')
        end)

        Database.query = original

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
    local original = Database.query
    Database.query = function(query) captured = query return {{count = 1}} end

    local exists = Schema.hasTable('users')

    Database.query = original
    truthy(captured:find('TABLE_SCHEMA = DATABASE()', 1, true), 'uses DATABASE() to scope TABLE_SCHEMA')
    eq(exists, true)
end)

test('postgres: hasTable queries table_catalog/table_schema, not TABLE_SCHEMA = current_database()', function()
    withDialect('postgres', function()
        local captured
        local original = Database.query
        Database.query = function(query) captured = query return {{count = 1}} end

        local exists = Schema.hasTable('users')

        Database.query = original
        truthy(captured:find('table_catalog = current_database() AND table_schema = current_schema()', 1, true),
            'scopes by table_catalog + table_schema, not the MySQL-only TABLE_SCHEMA = current_database()')
        truthy(not captured:find('TABLE_SCHEMA = current_database()', 1, true),
            'does not use the MySQL-shaped predicate under postgres')
        eq(exists, true)
    end)
end)

test('postgres: hasTable copes with a string-typed COUNT(*) result (pg returns bigint as string)', function()
    withDialect('postgres', function()
        local original = Database.query
        Database.query = function() return {{count = '0'}} end
        local exists = Schema.hasTable('users')
        Database.query = original
        eq(exists, false)
    end)
end)

test('mysql: hasColumn queries TABLE_SCHEMA = DATABASE()', function()
    local captured
    local original = Database.query
    Database.query = function(query) captured = query return {{count = 1}} end

    local exists = Schema.hasColumn('users', 'name')

    Database.query = original
    truthy(captured:find('TABLE_SCHEMA = DATABASE()', 1, true), 'uses DATABASE() to scope TABLE_SCHEMA')
    eq(exists, true)
end)

test('postgres: hasColumn queries table_catalog/table_schema', function()
    withDialect('postgres', function()
        local captured
        local original = Database.query
        Database.query = function(query) captured = query return {{count = '1'}} end

        local exists = Schema.hasColumn('users', 'name')

        Database.query = original
        truthy(captured:find('table_catalog = current_database() AND table_schema = current_schema()', 1, true),
            'scopes by table_catalog + table_schema')
        eq(exists, true, 'a string "1" count (as pg returns) must still compare as existing')
    end)
end)

--------------------------------------------------------------------------------
-- QueryBuilder:count / countAsync coping with string-typed pg results
--------------------------------------------------------------------------------
test('count (sync): coerces a string count (pg bigint) to a number', function()
    local qb = QueryBuilder.new('users')
    qb.first = function() return {count = '3'} end
    local result = qb:count()
    eq(result, 3)
end)

test('count (async): coerces a string count (pg bigint) to a number', function()
    local qb = QueryBuilder.new('users')
    qb.firstAsync = function(_, callback) callback({count = '7'}) end
    local received
    qb:countAsync(function(n) received = n end)
    eq(received, 7)
end)

test('postgres: renameColumn uses RENAME COLUMN, not CHANGE', function()
    withDialect('postgres', function()
        local captured
        local original = Database.query
        Database.query = function(query) captured = query return {} end

        Schema.renameColumn('users', 'old_name', 'new_name')

        Database.query = original
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

        local player = Player:create({name = 'bob'})

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

        Player:where('level', '>=', 10):orderBy('name'):limit(5):get()

        eq(get().query, 'SELECT * FROM `players` WHERE `level` >= ? ORDER BY `name` ASC LIMIT 5')
        eqList(get().params, {10})
    end)
end)

test('BaseModel query proxy: works on an extend()-based subclass too', function()
    withCapture(function(get)
        local Item = BaseModel:extend('items')
        Item.primaryKey = 'id'

        Item:whereIn('kind', {'weapon', 'armor'}):get()

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

    local widget = Widget:find(1)
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
        widget:save()

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

    local widget = Widget:find(1)
    Database.executeQuery = original

    eqList(widget.attributes.meta, {})
end)

--------------------------------------------------------------------------------
-- BaseModel find()/load() must not double-wrap model instances
--
-- newQuery() attaches `.model`, so first()/get() (and their Async variants)
-- are already model-aware since Task 6: they decode JSON casts and wrap rows
-- via newFromQuery() themselves. find()/load() used to call newFromQuery()
-- again on that already-wrapped instance, treating the whole instance object
-- (its `table`/`hidden`/`casts`/`exists`/`relations`/etc. keys) as if it were
-- a raw DB row. These tests assert on the STRUCTURE of `.attributes` and on
-- the actual SQL save() emits -- checks the existing `.field`-access tests
-- don't cover, since `.field` resolves through the metatable and doesn't
-- reveal what's actually sitting inside `.attributes`.
--------------------------------------------------------------------------------
test('BaseModel find: does not double-wrap - attributes contains only real db columns', function()
    local original = Database.executeQuery
    Database.executeQuery = function(query, params)
        return {{ id = 1, name = 'gizmo' }}
    end

    local Widget = setmetatable({}, {__index = BaseModel})
    Widget.table = 'widgets'
    Widget.primaryKey = 'id'
    Widget.timestamps = false

    local widget = Widget:find(1)
    Database.executeQuery = original

    local keys = {}
    for k in pairs(widget.attributes) do keys[#keys + 1] = k end
    table.sort(keys)
    eqList(keys, {'id', 'name'},
        'attributes should contain only real db columns, not instance internals like table/hidden/casts/exists')
end)

test('BaseModel find: save() after find() emits UPDATE with real column names, not instance internals', function()
    local original = Database.executeQuery
    local updateQuery, updateParams
    Database.executeQuery = function(query, params)
        if query:find('^SELECT') then
            return {{ id = 1, name = 'gizmo' }}
        end
        updateQuery = query
        updateParams = params
        return {affectedRows = 1}
    end

    local Widget = setmetatable({}, {__index = BaseModel})
    Widget.table = 'widgets'
    Widget.primaryKey = 'id'
    Widget.timestamps = false

    local widget = Widget:find(1)
    widget:set('name', 'sprocket')
    widget:save()
    Database.executeQuery = original

    truthy(updateQuery ~= nil, 'save() issued an UPDATE')
    truthy(updateQuery:find('UPDATE `widgets` SET', 1, true), 'update statement targets the widgets table')
    truthy(updateQuery:find('`name` = ?', 1, true), 'update sets the real `name` column')
    truthy(updateQuery:find('`id` = ?', 1, true), 'update sets the real `id` column')
    falsy(updateQuery:find('`table`', 1, true), 'does not attempt to write the internal `table` field')
    falsy(updateQuery:find('`attributes`', 1, true), 'does not attempt to write the internal `attributes` field')
    falsy(updateQuery:find('`exists`', 1, true), 'does not attempt to write the internal `exists` field')
    falsy(updateQuery:find('`hidden`', 1, true), 'does not attempt to write the internal `hidden` field')
    falsy(updateQuery:find('`casts`', 1, true), 'does not attempt to write the internal `casts` field')
    falsy(updateQuery:find('`relations`', 1, true), 'does not attempt to write the internal `relations` field')
    eq(#updateParams, 3, 'SET id, SET name, WHERE id -- only real columns, none of the ~9 instance internals')
end)

test('BaseModel load: hasMany does not double-wrap related model instances', function()
    -- extend() (not the raw setmetatable({}, {__index = BaseModel}) pattern
    -- used elsewhere in this file) is required here because it makes
    -- instances resolve custom methods like `orders()` via the child's own
    -- __index, which `self[relationName](self)` inside load() depends on.
    local Customer = BaseModel:extend('customers')
    Customer.primaryKey = 'id'
    Customer.timestamps = false

    local Order = BaseModel:extend('orders')
    Order.primaryKey = 'id'
    Order.timestamps = false

    function Customer:orders() return self:hasMany(Order, 'customer_id') end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `customers`') then
            return {{ id = 1, name = 'Ada' }}
        elseif sql:find('FROM `orders`') then
            return {{ id = 10, customer_id = 1, total = 5 }}
        end
        return {}
    end

    local customer = Customer:find(1)
    local orders = customer:load('orders')
    Database.query = original

    eq(#orders, 1)
    local keys = {}
    for k in pairs(orders[1].attributes) do keys[#keys + 1] = k end
    table.sort(keys)
    eqList(keys, {'customer_id', 'id', 'total'},
        'related instance attributes should contain only real db columns')
end)

test('BaseModel load: belongsTo with a non-primary-key ownerKey matches on that column, not id', function()
    local Action = BaseModel:extend('actions')
    Action.primaryKey = 'id'
    Action.timestamps = false

    local ScheduledJob = BaseModel:extend('scheduled_jobs')
    ScheduledJob.primaryKey = 'id'
    ScheduledJob.timestamps = false

    function ScheduledJob:action() return self:belongsTo(Action, 'action_id', 'action_id') end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `scheduled_jobs`') then
            return {{ id = 1, action_id = 'give_item' }}
        elseif sql:find('FROM `actions`') then
            eqList(params, {'give_item'}, 'belongsTo: queried by ownerKey value, not the jobs.id row id')
            return {{ id = 99, action_id = 'give_item', label = 'Give Item' }}
        end
        return {}
    end

    local job = ScheduledJob:find(1)
    local action = job:load('action')
    Database.query = original

    truthy(action, 'belongsTo: related row found via ownerKey match')
    eq(action.label, 'Give Item', 'belongsTo: correct row returned despite id (99) != foreignValue (give_item)')
end)

test('BaseModel hasMany/hasOne: foreignKey defaults to singularize(self.table) .. "_id"', function()
    local Character = BaseModel:extend('characters')
    local ShellOwner = BaseModel:extend('shell_owners')
    function Character.relations:shellOwners() return self:hasMany(ShellOwner) end

    local capturedParams
    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `characters`') then return {{ id = 1 }} end
        if sql:find('FROM `shell_owners`') then
            capturedParams = params
            return {{ id = 10, character_id = 1, shell_id = 5 }}
        end
        return {}
    end

    local character = Character:find(1)
    local owners = character.shellOwners
    Database.query = original

    eq(#owners, 1)
    eqList(capturedParams, {1}, 'hasMany with no explicit foreignKey should filter by character_id')
end)

test('BaseModel.relations: bare property access lazily resolves and caches', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')

    function Customer.relations:orders()
        return self:hasMany(Order, 'customer_id')
    end

    local queryCount = 0
    Database.query = function(sql)
        queryCount = queryCount + 1
        if sql:find('FROM `customers`') then return {{ id = 1, name = 'Ada' }} end
        if sql:find('FROM `orders`') then return {{ id = 10, customer_id = 1, total = 5 }} end
        return {}
    end

    local customer = Customer:find(1)
    local orders = customer.orders
    eq(#orders, 1, 'bare .orders should lazily resolve via Model.relations')
    eq(orders[1].total, 5)

    local queryCountAfterFirst = queryCount
    local ordersAgain = customer.orders
    eq(ordersAgain, orders, 'second access should return the cached table')
    eq(queryCount, queryCountAfterFirst, 'second access should not requery')
end)

test('BaseModel.relations: does not collide with regular methods', function()
    local Widget = BaseModel:extend('widgets')
    function Widget:describe() return 'a widget' end

    local widget = Widget.new({id = 1})
    eq(widget:describe(), 'a widget', 'a plain method (not registered via .relations) is untouched')
end)

test('BaseModel:relation() returns the descriptor, both from a class and an instance', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Customer.relations:orders() return self:hasMany(Order, 'customer_id') end

    local fromClass = Customer:relation('orders')
    eq(fromClass.type, 'hasMany')
    eq(fromClass.relatedModel, Order)

    local customer = Customer.new({id = 1})
    local fromInstance = customer:relation('orders')
    eq(fromInstance.type, 'hasMany')
    eq(fromInstance.relatedModel, Order)
end)

test('BaseModel.relations: old-style (function directly on the model) relations still work via :with()', function()
    -- Backward compatibility: `function Model:xRelation() return
    -- self:hasOne(...) end` (not registered via `Model.relations`) must
    -- keep working for :with()/eagerLoad -- it just doesn't get the new
    -- bare-property lazy-load behavior.
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Customer:ordersRelation() return self:hasMany(Order, 'customer_id') end

    Database.query = function(sql)
        if sql:find('FROM `customers`') then return {{ id = 1, name = 'Ada' }} end
        if sql:find('FROM `orders`') then return {{ id = 10, customer_id = 1, total = 5 }} end
        return {}
    end

    local customers = Customer:with('ordersRelation'):get()
    eq(#customers[1].ordersRelation, 1, 'old-style definer still eager-loads via :with()')
end)

test('BaseModel instance: .field reads attributes directly', function()
    local Widget = BaseModel:extend('widgets')
    local widget = Widget.new({id = 1, name = 'gizmo'})
    eq(widget.name, 'gizmo', '.field should read attributes.field')
    eq(widget.attributes.name, 'gizmo', '.attributes.field should still work')
end)

test('BaseModel instance: .field falls through to relations then methods', function()
    local Widget = BaseModel:extend('widgets')
    function Widget:describe() return 'a widget' end
    local widget = Widget.new({id = 1})
    widget.relations.owner = {id = 9}
    eq(widget.owner.id, 9, '.field should fall through to relations')
    eq(widget:describe(), 'a widget', 'method calls should still resolve')
end)

test('BaseModel: get(key) attribute getter is removed', function()
    local Widget = BaseModel:extend('widgets')
    local widget = Widget.new({id = 1})
    -- get() is now the query-fetch method (class-level); calling it as an
    -- instance attribute getter with a key arg is no longer supported.
    truthy(widget.get == nil or type(widget.get) == 'function', 'get should not be an attribute getter')
end)

test('BaseModel: get() (no filter) decodes JSON casts and returns model instances', function()
    local Category = BaseModel:extend('categories')
    Category.casts = {fields = 'json'}

    local original = Database.query
    Database.query = function(sql, params)
        return {{id = 1, fields = '{"color":"red"}'}}
    end

    local results = Category:get()
    Database.query = original

    eq(#results, 1, 'get(): one row')
    truthy(type(results[1].fields) == 'table', 'get(): json cast decoded')
    eq(results[1].fields.color, 'red', 'get(): decoded value correct')
    eq(results[1].id, 1, 'get(): .field access on wrapped instance')
end)

test('BaseModel: where(...):get() (filtered) also decodes and wraps', function()
    local Category = BaseModel:extend('categories')
    Category.casts = {fields = 'json'}

    local original = Database.query
    Database.query = function(sql, params)
        return {{id = 2, fields = '{"color":"blue"}'}}
    end

    local results = Category:where('id', 2):get()
    Database.query = original

    eq(results[1].fields.color, 'blue', 'where():get(): decoded value correct')
end)

test('QueryBuilder.get(): bare QueryBuilder (no model) returns raw rows', function()
    local original = Database.query
    Database.query = function(sql, params) return {{id = 1, fields = '{"a":1}'}} end
    local results = QueryBuilder.new('categories'):get()
    Database.query = original

    eq(type(results[1].fields), 'string', 'bare QueryBuilder: no decoding, still a string')
end)

test('BaseModel.with: single-level eager load batches into one query per relation', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Order:customer() return self:belongsTo(Customer, 'customer_id') end

    local queries = {}
    local original = Database.query
    Database.query = function(sql, params)
        table.insert(queries, sql)
        if sql:find('FROM `orders`') then
            return {{id = 1, customer_id = 10}, {id = 2, customer_id = 11}}
        elseif sql:find('FROM `customers`') then
            eqList(params, {10, 11}, 'with: customer_id IN batch')
            return {{id = 10, name = 'Alice'}, {id = 11, name = 'Bob'}}
        end
        return {}
    end

    local orders = Order:with('customer'):get()
    Database.query = original

    eq(#orders, 2, 'with: base rows returned')
    eq(orders[1].customer.name, 'Alice', 'with: relation attached and .field-readable')
    eq(orders[2].customer.name, 'Bob', 'with: relation attached and .field-readable')
end)

test('BaseModel.with: nested dot-path batches one query per segment', function()
    local Address = BaseModel:extend('addresses')
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Order:customer() return self:belongsTo(Customer, 'customer_id') end
    function Customer:address() return self:hasOne(Address, 'customer_id') end

    local queryCount = 0
    local original = Database.query
    Database.query = function(sql, params)
        queryCount = queryCount + 1
        if sql:find('FROM `orders`') then
            return {{id = 1, customer_id = 10}}
        elseif sql:find('FROM `customers`') then
            return {{id = 10, name = 'Alice'}}
        elseif sql:find('FROM `addresses`') then
            return {{id = 100, customer_id = 10, city = 'Metropolis'}}
        end
        return {}
    end

    local orders = Order:with('customer.address'):get()
    Database.query = original

    eq(queryCount, 3, 'with nested: exactly 3 queries (base + 2 segments)')
    eq(orders[1].customer.address.city, 'Metropolis', 'with nested: deep .field access resolves')
end)

test('BaseModel.with: hasMany batches into an array per instance via .field access', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Customer:orders() return self:hasMany(Order, 'customer_id') end

    local queryCount = 0
    local original = Database.query
    Database.query = function(sql, params)
        queryCount = queryCount + 1
        if sql:find('FROM `customers`') then
            return {{id = 10, name = 'Alice'}, {id = 11, name = 'Bob'}}
        elseif sql:find('FROM `orders`') then
            eqList(params, {10, 11}, 'with hasMany: customer_id IN batch')
            return {
                {id = 1, customer_id = 10, total = 5},
                {id = 2, customer_id = 10, total = 7},
                {id = 3, customer_id = 11, total = 9},
            }
        end
        return {}
    end

    local customers = Customer:with('orders'):get()
    Database.query = original

    eq(queryCount, 2, 'with hasMany: exactly 2 queries (base + relation)')
    eq(#customers[1].orders, 2, 'with hasMany: first customer gets both matching orders')
    eq(#customers[2].orders, 1, 'with hasMany: second customer gets only its own order')
    eq(customers[1].orders[1].total, 5, 'with hasMany: .field access on nested order')
    eq(customers[1].orders[2].total, 7, 'with hasMany: .field access on nested order')
    eq(customers[2].orders[1].total, 9, 'with hasMany: .field access on nested order')
end)

test('BaseModel.with: belongsToMany assigns each instance only its own related rows', function()
    local Tag = BaseModel:extend('tags')
    local Post = BaseModel:extend('posts')
    function Post:tags() return self:belongsToMany(Tag, 'post_tags', 'post_id', 'tag_id') end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then
            return {{id = 1, title = 'First'}, {id = 2, title = 'Second'}, {id = 3, title = 'Third'}}
        elseif sql:find('FROM `post_tags`') then
            -- Post 1 -> tag A only, Post 2 -> tag B only, Post 3 -> no tags.
            return {
                {post_id = 1, tag_id = 100},
                {post_id = 2, tag_id = 200},
            }
        elseif sql:find('FROM `tags`') then
            return {
                {id = 100, name = 'A'},
                {id = 200, name = 'B'},
            }
        end
        return {}
    end

    local posts = Post:with('tags'):get()
    Database.query = original

    eq(#posts, 3, 'belongsToMany: base rows returned')
    eq(#posts[1].tags, 1, 'belongsToMany: post 1 gets only its own tag')
    eq(posts[1].tags[1].name, 'A', 'belongsToMany: post 1 tag is A')
    eq(#posts[2].tags, 1, 'belongsToMany: post 2 gets only its own tag')
    eq(posts[2].tags[1].name, 'B', 'belongsToMany: post 2 tag is B')
    eq(#posts[3].tags, 0, 'belongsToMany: post 3 has no tags')
end)

test('BaseModel.with: belongsToMany interns one shared instance per related row so nested paths populate for every owner', function()
    local Creator = BaseModel:extend('creators')
    local Tag = BaseModel:extend('tags')
    local Post = BaseModel:extend('posts')
    function Post:tags() return self:belongsToMany(Tag, 'post_tags', 'post_id', 'tag_id') end
    function Tag:creator() return self:hasOne(Creator, 'tag_id') end

    local creatorQueryCount = 0
    local creatorWhereInParams = nil
    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then
            return {{id = 1, title = 'First'}, {id = 2, title = 'Second'}}
        elseif sql:find('FROM `post_tags`') then
            -- Both posts share the SAME tag (id = 100) via two distinct pivot rows.
            return {
                {post_id = 1, tag_id = 100},
                {post_id = 2, tag_id = 100},
            }
        elseif sql:find('FROM `tags`') then
            return {{id = 100, name = 'A'}}
        elseif sql:find('FROM `creators`') then
            creatorQueryCount = creatorQueryCount + 1
            creatorWhereInParams = params
            return {{id = 1000, tag_id = 100, name = 'Ada'}}
        end
        return {}
    end

    local posts = Post:with('tags.creator'):get()
    Database.query = original

    eq(#posts, 2, 'shared tag: both base posts returned')
    eq(creatorQueryCount, 1, 'shared tag: creator segment batched into exactly one query')
    eqList(creatorWhereInParams, {100}, 'shared tag: dedup collapses both pivot rows to the one shared tag id')
    eq(posts[1].tags[1].creator.name, 'Ada', 'shared tag: post 1 tag creator populated')
    eq(posts[2].tags[1].creator.name, 'Ada', 'shared tag: post 2 tag creator populated')
    eq(posts[1].tags[1], posts[2].tags[1], 'shared tag: both posts reference the SAME interned tag instance')
end)

test('BaseModel.with: nested dot-path dedups shared related instances before the next batch', function()
    local Customer = BaseModel:extend('customers')
    local Address = BaseModel:extend('addresses')
    local Order = BaseModel:extend('orders')
    function Order:customer() return self:belongsTo(Customer, 'customer_id') end
    function Customer:address() return self:hasOne(Address, 'customer_id') end

    local addressWhereInParams = nil
    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `orders`') then
            -- 3 orders all sharing the same customer_id = 10.
            return {
                {id = 1, customer_id = 10},
                {id = 2, customer_id = 10},
                {id = 3, customer_id = 10},
            }
        elseif sql:find('FROM `customers`') then
            return {{id = 10, name = 'Alice'}}
        elseif sql:find('FROM `addresses`') then
            addressWhereInParams = params
            return {{id = 100, customer_id = 10, city = 'Metropolis'}}
        end
        return {}
    end

    local orders = Order:with('customer.address'):get()
    Database.query = original

    eq(#orders, 3, 'dedup: all 3 base orders returned')
    eqList(addressWhereInParams, {10}, 'dedup: address query received the shared customer id only once')
    eq(orders[1].customer.address.city, 'Metropolis', 'dedup: deep .field access still resolves')
    eq(orders[3].customer.address.city, 'Metropolis', 'dedup: deep .field access still resolves for all orders')
end)

--------------------------------------------------------------------------------
-- BaseModel firstOrNew / firstOrCreate / updateOrCreate / firstOr
--------------------------------------------------------------------------------
test('BaseModel.firstOrNew: found match returns it, issues no write query', function()
    local Widget = BaseModel:extend('widgets')

    local wroteAnything = false
    local originalQuery, originalInsert = Database.query, Database.insert
    Database.query = function(sql, params)
        eq(sql, 'SELECT * FROM `widgets` WHERE `sku` = ? LIMIT 1')
        eqList(params, {'abc'})
        return {{id = 1, sku = 'abc', name = 'gizmo'}}
    end
    Database.insert = function() wroteAnything = true return 99 end

    local widget = Widget:firstOrNew({sku = 'abc'}, {name = 'ignored'})
    Database.query, Database.insert = originalQuery, originalInsert

    falsy(wroteAnything, 'firstOrNew: found match must not write')
    eq(widget.sku, 'abc')
    eq(widget.name, 'gizmo', 'firstOrNew: found match keeps its own values, ignores `values` param')
    truthy(widget.exists, 'firstOrNew: found match is already persisted')
end)

test('BaseModel.firstOrNew: no match returns an unsaved instance with merged attributes', function()
    local Widget = BaseModel:extend('widgets')

    local wroteAnything = false
    local originalQuery, originalInsert = Database.query, Database.insert
    Database.query = function() return {} end
    Database.insert = function() wroteAnything = true return 99 end

    local widget = Widget:firstOrNew({sku = 'abc'}, {name = 'new gizmo'})
    Database.query, Database.insert = originalQuery, originalInsert

    falsy(wroteAnything, 'firstOrNew: no match must not save -- caller calls save() themselves')
    falsy(widget.exists, 'firstOrNew: no match returns an unsaved instance')
    eq(widget.sku, 'abc', 'firstOrNew: no match carries the lookup attributes')
    eq(widget.name, 'new gizmo', 'firstOrNew: no match carries the values attributes')
end)

test('BaseModel.firstOrCreate: found match returns it, issues no write query', function()
    local Widget = BaseModel:extend('widgets')

    local wroteAnything = false
    local originalQuery, originalInsert = Database.query, Database.insert
    Database.query = function() return {{id = 1, sku = 'abc', name = 'gizmo'}} end
    Database.insert = function() wroteAnything = true return 99 end

    local widget = Widget:firstOrCreate({sku = 'abc'}, {name = 'ignored'})
    Database.query, Database.insert = originalQuery, originalInsert

    falsy(wroteAnything, 'firstOrCreate: found match must not write')
    eq(widget.name, 'gizmo')
end)

test('BaseModel.firstOrCreate: no match creates and saves the merged attributes', function()
    local Widget = BaseModel:extend('widgets')

    local insertedSql, insertedValues
    local originalQuery, originalInsert = Database.query, Database.insert
    Database.query = function() return {} end
    Database.insert = function(sql, values) insertedSql, insertedValues = sql, values return 42 end

    local widget = Widget:firstOrCreate({sku = 'abc'}, {name = 'new gizmo'})
    Database.query, Database.insert = originalQuery, originalInsert

    truthy(insertedSql ~= nil, 'firstOrCreate: no match issues an INSERT')
    truthy(insertedSql:find('INSERT INTO `widgets`', 1, true))
    truthy(widget.exists, 'firstOrCreate: no match returns a saved instance')
    eq(widget.id, 42)
    eq(widget.sku, 'abc')
    eq(widget.name, 'new gizmo')
end)

test('BaseModel.firstOrCreateAsync: no match creates via the async path', function()
    local Widget = BaseModel:extend('widgets')

    local originalQueryAsync, originalInsertAsync = Database.queryAsync, Database.insertAsync
    Database.queryAsync = function(sql, params, callback) callback({}) end
    Database.insertAsync = function(sql, values, callback) callback(7) end

    local received
    Widget:firstOrCreateAsync({sku = 'abc'}, {name = 'async gizmo'}, function(widget) received = widget end)
    Database.queryAsync, Database.insertAsync = originalQueryAsync, originalInsertAsync

    truthy(received ~= nil, 'firstOrCreateAsync: callback received an instance')
    eq(received.id, 7)
    eq(received.name, 'async gizmo')
    truthy(received.exists, 'firstOrCreateAsync: callback instance is saved')
end)

test('BaseModel.updateOrCreate: found match applies values and saves an UPDATE', function()
    local Widget = BaseModel:extend('widgets')

    local updatedSql, updatedValues
    local originalQuery, originalUpdate = Database.query, Database.update
    Database.query = function() return {{id = 1, sku = 'abc', name = 'old name'}} end
    Database.update = function(sql, values) updatedSql, updatedValues = sql, values return 1 end

    local widget = Widget:updateOrCreate({sku = 'abc'}, {name = 'new name'})
    Database.query, Database.update = originalQuery, originalUpdate

    truthy(updatedSql ~= nil, 'updateOrCreate: found match issues an UPDATE')
    truthy(updatedSql:find('UPDATE `widgets`', 1, true))
    eq(widget.name, 'new name', 'updateOrCreate: found match applies the values param')
end)

test('BaseModel.updateOrCreate: no match creates the merged attributes', function()
    local Widget = BaseModel:extend('widgets')

    local insertedValues
    local originalQuery, originalInsert = Database.query, Database.insert
    Database.query = function() return {} end
    Database.insert = function(sql, values) insertedValues = values return 42 end

    local widget = Widget:updateOrCreate({sku = 'abc'}, {name = 'new gizmo'})
    Database.query, Database.insert = originalQuery, originalInsert

    truthy(insertedValues ~= nil, 'updateOrCreate: no match issues an INSERT')
    eq(widget.sku, 'abc')
    eq(widget.name, 'new gizmo')
end)

test('BaseModel.updateOrCreateAsync: found match applies values via the async path', function()
    local Widget = BaseModel:extend('widgets')

    local originalQueryAsync, originalUpdateAsync = Database.queryAsync, Database.updateAsync
    Database.queryAsync = function(sql, params, callback) callback({{id = 1, sku = 'abc', name = 'old name'}}) end
    Database.updateAsync = function(sql, values, callback) callback(1) end

    local received
    Widget:updateOrCreateAsync({sku = 'abc'}, {name = 'async new name'}, function(widget) received = widget end)
    Database.queryAsync, Database.updateAsync = originalQueryAsync, originalUpdateAsync

    truthy(received ~= nil, 'updateOrCreateAsync: callback received an instance')
    eq(received.name, 'async new name')
end)

test('QueryBuilder.firstOr: returns the found row without calling the fallback', function()
    local original = Database.query
    Database.query = function() return {{id = 1, sku = 'abc'}} end

    local fallbackCalled = false
    local result = QueryBuilder.new('widgets'):where('sku', 'abc'):firstOr(function()
        fallbackCalled = true
        return 'fallback value'
    end)
    Database.query = original

    falsy(fallbackCalled, 'firstOr: fallback must not run when a row is found')
    truthy(result ~= nil and result ~= 'fallback value', 'firstOr: returns the found row')
end)

test('QueryBuilder.firstOr: calls and returns the fallback when nothing is found', function()
    local original = Database.query
    Database.query = function() return {} end

    local result = QueryBuilder.new('widgets'):where('sku', 'missing'):firstOr(function()
        return 'fallback value'
    end)
    Database.query = original

    eq(result, 'fallback value', 'firstOr: returns the fallback callback\'s return value')
end)

test('BaseModel.firstOr: proxied onto the model like get/first', function()
    local Widget = BaseModel:extend('widgets')

    local original = Database.query
    Database.query = function() return {} end

    local result = Widget:where('sku', 'missing'):firstOr(function() return 'default widget' end)
    Database.query = original

    eq(result, 'default widget', 'BaseModel.firstOr: proxies through to QueryBuilder.firstOr')
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
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql, capturedParams = sql, params
        return {{DATA_TYPE = 'varchar', CHARACTER_MAXIMUM_LENGTH = 100, COLUMN_TYPE = 'varchar(100)', IS_NULLABLE = 'YES', COLUMN_DEFAULT = nil}}
    end

    local info = MySQLDialect.introspectColumn('widgets', 'name')

    Database.query = original

    truthy(capturedSql:find('information_schema.COLUMNS', 1, true), 'queries information_schema.COLUMNS')
    truthy(capturedSql:find('COLUMN_TYPE', 1, true), 'selects COLUMN_TYPE')
    eqList(capturedParams, {'widgets', 'name'})
    eq(info.type, 'varchar')
    eq(info.length, 100)
    eq(info.columnType, 'varchar(100)')
    eq(info.nullable, true)
    eq(info.default, nil)
end)

test('MySQLDialect.introspectColumn: returns nil when the column does not exist', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local original = Database.query
    Database.query = function() return {} end

    local info = MySQLDialect.introspectColumn('widgets', 'ghost')

    Database.query = original

    eq(info, nil)
end)

test('MySQLDialect.alterModifyColumnStatements: restates the full column, merging unstated attributes from introspection', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local q = MySQLDialect.quoteIdentifier
    -- The migration only changes nullability; type/length/default are NOT
    -- restated by the caller, and must come from currentInfo instead.
    local col = {name = 'name', kind = 'string', opts = {}, nullable = false}
    -- COLUMN_DEFAULT comes back as an already-quoted SQL literal.
    local currentInfo = {type = 'varchar', length = 100, columnType = 'varchar(100)', nullable = true, default = "'unknown'"}

    local statements = MySQLDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

    eq(#statements, 1)
    truthy(statements[1]:find('MODIFY COLUMN', 1, true), 'uses MODIFY COLUMN')
    truthy(statements[1]:find('varchar(100)', 1, true), 'restates the original length even though the migration did not specify it')
    truthy(statements[1]:find('NOT NULL', 1, true), 'applies the new nullability')
    truthy(statements[1]:find("DEFAULT 'unknown'", 1, true), 'restates the original default so it is not silently dropped')
end)

test('MySQLDialect.alterModifyColumnStatements: restates an introspected default verbatim, never re-formatting an already-SQL literal', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local q = MySQLDialect.quoteIdentifier

    -- MariaDB reports the 4-character string "NULL" for "no default". It must
    -- not become the string literal 'NULL' (nor a DEFAULT NULL on a NOT NULL
    -- column) — the cleanest correct output is no DEFAULT clause at all.
    local nullCol = {name = 'name', kind = 'string', opts = {}, nullable = false}
    local nullInfo = {type = 'varchar', length = 100, columnType = 'varchar(100)', nullable = true, default = 'NULL'}
    local nullStatements = MySQLDialect.alterModifyColumnStatements('widgets', nullCol, nullInfo, q)
    falsy(nullStatements[1]:find("DEFAULT 'NULL'", 1, true), "does not emit the no-default sentinel as a string literal")
    falsy(nullStatements[1]:find('DEFAULT', 1, true), 'omits the DEFAULT clause entirely for the no-default sentinel')

    -- An already-quoted string default must not be double-quoted.
    local strCol = {name = 'name', kind = 'string', opts = {}, nullable = false}
    local strInfo = {type = 'varchar', length = 100, columnType = 'varchar(100)', nullable = true, default = "'abc'"}
    local strStatements = MySQLDialect.alterModifyColumnStatements('widgets', strCol, strInfo, q)
    truthy(strStatements[1]:find("DEFAULT 'abc'", 1, true), 'restates the quoted string default verbatim')
    falsy(strStatements[1]:find("DEFAULT ''abc''", 1, true), 'does not double-quote an already-quoted default')

    -- A default expression must stay a function call, not become a string.
    local tsCol = {name = 'created_at', kind = 'timestamp', opts = {}, nullable = false}
    local tsInfo = {type = 'timestamp', length = nil, columnType = 'timestamp', nullable = true, default = 'current_timestamp()'}
    local tsStatements = MySQLDialect.alterModifyColumnStatements('widgets', tsCol, tsInfo, q)
    truthy(tsStatements[1]:find('DEFAULT current_timestamp()', 1, true), 'restates the default expression verbatim')
    falsy(tsStatements[1]:find("'current_timestamp()'", 1, true), 'does not turn the expression into a string literal')
end)

test('MySQLDialect.alterModifyColumnStatements: restates COLUMN_TYPE verbatim for non-string kinds (decimal/enum/unsigned), preserving precision/scale/values/unsigned', function()
    local MySQLDialect = Dialects.resolve('mysql')
    local q = MySQLDialect.quoteIdentifier

    -- decimal(p,s): CHARACTER_MAXIMUM_LENGTH is NULL for numeric types, so
    -- the old type+length reconstruction had no way to recover precision/scale.
    local decimalCol = {name = 'price', kind = 'decimal', opts = {}, nullable = false}
    local decimalInfo = {type = 'decimal', length = nil, columnType = 'decimal(10,2)', nullable = true, default = nil}
    local decimalStatements = MySQLDialect.alterModifyColumnStatements('widgets', decimalCol, decimalInfo, q)
    truthy(decimalStatements[1]:find('decimal(10,2)', 1, true), 'restates precision/scale verbatim from COLUMN_TYPE')

    -- enum(...): the old reconstruction had no way to recover the value list.
    local enumCol = {name = 'status', kind = 'enum', opts = {}, nullable = false}
    local enumInfo = {type = 'enum', length = nil, columnType = "enum('a','b')", nullable = true, default = nil}
    local enumStatements = MySQLDialect.alterModifyColumnStatements('widgets', enumCol, enumInfo, q)
    truthy(enumStatements[1]:find("enum('a','b')", 1, true), 'restates the enum value list verbatim from COLUMN_TYPE')

    -- unsigned integer: the old reconstruction had no way to recover UNSIGNED.
    local intCol = {name = 'count', kind = 'integer', opts = {}, nullable = false}
    local intInfo = {type = 'int', length = nil, columnType = 'int(10) unsigned', nullable = true, default = nil}
    local intStatements = MySQLDialect.alterModifyColumnStatements('widgets', intCol, intInfo, q)
    truthy(intStatements[1]:find('int(10) unsigned', 1, true), 'restates the UNSIGNED attribute verbatim from COLUMN_TYPE')
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

test('PostgresDialect.introspectColumn: queries information_schema.columns and parses the row', function()
    withDialect('postgres', function()
        local PostgresDialect = Dialects.resolve('postgres')
        local capturedSql, capturedParams
        local original = Database.query
        Database.query = function(sql, params)
            capturedSql, capturedParams = sql, params
            return {{data_type = 'character varying', character_maximum_length = 100, is_nullable = 'YES', column_default = nil}}
        end

        local info = PostgresDialect.introspectColumn('widgets', 'name')

        Database.query = original

        truthy(capturedSql:find('information_schema.columns', 1, true), 'queries information_schema.columns')
        eqList(capturedParams, {'widgets', 'name'})
        eq(info.type, 'character varying')
        eq(info.length, 100)
        eq(info.nullable, true)
    end)
end)

test('PostgresDialect.introspectColumn: returns nil when the column does not exist', function()
    withDialect('postgres', function()
        local PostgresDialect = Dialects.resolve('postgres')
        local original = Database.query
        Database.query = function() return {} end

        local info = PostgresDialect.introspectColumn('widgets', 'ghost')

        Database.query = original

        eq(info, nil)
    end)
end)

test('PostgresDialect.alterModifyColumnStatements: emits one independent clause per changed attribute', function()
    withDialect('postgres', function()
        local PostgresDialect = Dialects.resolve('postgres')
        local q = PostgresDialect.quoteIdentifier
        local col = {name = 'name', kind = 'string', opts = {}, nullable = false}
        local currentInfo = {type = 'character varying', length = 100, nullable = true, default = nil}

        local statements = PostgresDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

        eq(#statements, 1, 'only nullability changed, so only one clause')
        truthy(statements[1]:find('ALTER COLUMN "name" SET NOT NULL', 1, true), 'sets NOT NULL')
        truthy(not statements[1]:find('TYPE', 1, true), 'does not restate the unchanged type')
    end)
end)

test('PostgresDialect.alterModifyColumnStatements: reverting to nullable emits DROP NOT NULL', function()
    withDialect('postgres', function()
        local PostgresDialect = Dialects.resolve('postgres')
        local q = PostgresDialect.quoteIdentifier
        local col = {name = 'name', kind = 'string', opts = {}, nullable = true}
        local currentInfo = {type = 'character varying', length = 100, nullable = false, default = nil}

        local statements = PostgresDialect.alterModifyColumnStatements('widgets', col, currentInfo, q)

        truthy(statements[1]:find('DROP NOT NULL', 1, true), 'drops NOT NULL')
    end)
end)

--------------------------------------------------------------------------------
-- morphOne / morphMany / morphTo
--------------------------------------------------------------------------------
test('BaseModel load: morphOne returns the single related row for this owner', function()
    local ATMMachine = BaseModel:extend('atm_machines')
    ATMMachine.primaryKey = 'id'
    ATMMachine.timestamps = false

    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function ATMMachine.relations:interaction()
        return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ATMMachine')
    end

    local queriedSql, queriedParams
    local original = Database.query
    Database.query = function(sql, params)
        queriedSql = sql
        queriedParams = params
        if sql:find('FROM `atm_machines`') then
            return {{ id = 5, name = 'Test ATM' }}
        elseif sql:find('FROM `interactions`') then
            return {{ id = 99, owner_type = 'ATMMachine', owner_id = 5, x = 1.0, label = 'Use ATM' }}
        end
        return {}
    end

    local atm = ATMMachine:find(5)
    local interaction = atm:load('interaction')
    Database.query = original

    truthy(interaction, 'morphOne: related row found')
    eq(interaction.id, 99, 'morphOne: correct row returned')
    eq(interaction.label, 'Use ATM', 'morphOne: correct field value')
    truthy(queriedSql:find('owner_type'), 'morphOne: query filters by owner_type')
    truthy(queriedSql:find('owner_id'), 'morphOne: query filters by owner_id')
end)

test('BaseModel load: morphOne returns nil when no matching row exists', function()
    local Widget = BaseModel:extend('widgets')
    Widget.primaryKey = 'id'
    Widget.timestamps = false

    local Tag = BaseModel:extend('tags')
    Tag.primaryKey = 'id'
    Tag.timestamps = false

    function Widget.relations:tag() return self:morphOne(Tag, 'owner_id', 'owner_type', 'Widget') end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `widgets`') then return {{ id = 1 }} end
        return {}
    end

    local widget = Widget:find(1)
    local tag = widget:load('tag')
    Database.query = original

    falsy(tag, 'morphOne: nil returned when no related row exists')
end)

test('BaseModel load: morphMany returns all related rows for this owner', function()
    local Post = BaseModel:extend('posts')
    Post.primaryKey = 'id'
    Post.timestamps = false

    local Comment = BaseModel:extend('comments')
    Comment.primaryKey = 'id'
    Comment.timestamps = false

    function Post.relations:comments()
        return self:morphMany(Comment, 'owner_id', 'owner_type', 'Post')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then return {{ id = 10 }} end
        if sql:find('FROM `comments`') then
            return {
                { id = 1, owner_type = 'Post', owner_id = 10, body = 'First' },
                { id = 2, owner_type = 'Post', owner_id = 10, body = 'Second' },
            }
        end
        return {}
    end

    local post = Post:find(10)
    local comments = post:load('comments')
    Database.query = original

    eq(#comments, 2, 'morphMany: both related rows returned')
    eq(comments[1].body, 'First', 'morphMany: first row body correct')
    eq(comments[2].body, 'Second', 'morphMany: second row body correct')
end)

test('BaseModel load: morphMany returns empty table when no related rows exist', function()
    local Post = BaseModel:extend('posts')
    Post.primaryKey = 'id'
    Post.timestamps = false

    local Comment = BaseModel:extend('comments')
    Comment.primaryKey = 'id'
    Comment.timestamps = false

    function Post.relations:comments()
        return self:morphMany(Comment, 'owner_id', 'owner_type', 'Post')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then return {{ id = 10 }} end
        return {}
    end

    local post = Post:find(10)
    local comments = post:load('comments')
    Database.query = original

    truthy(comments, 'morphMany: non-nil result even when empty')
    eq(#comments, 0, 'morphMany: empty table returned when no related rows')
end)

test('BaseModel load: morphTo resolves owner via _G[owner_type]:find(owner_id)', function()
    local ATMMachine = BaseModel:extend('atm_machines')
    ATMMachine.primaryKey = 'id'
    ATMMachine.timestamps = false

    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function Interaction.relations:owner()
        return self:morphTo('owner_type', 'owner_id')
    end

    _G['ATMMachine'] = ATMMachine

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `interactions`') then
            return {{ id = 99, owner_type = 'ATMMachine', owner_id = 5, label = 'Use ATM' }}
        elseif sql:find('FROM `atm_machines`') then
            return {{ id = 5, name = 'Main ATM' }}
        end
        return {}
    end

    local interaction = Interaction:find(99)
    local owner = interaction:load('owner')
    Database.query = original
    _G['ATMMachine'] = nil

    truthy(owner, 'morphTo: owner resolved')
    eq(owner.id, 5, 'morphTo: correct owner id')
    eq(owner.name, 'Main ATM', 'morphTo: correct owner field')
end)

test('BaseModel load: morphTo returns nil when owner_type resolves to nil global', function()
    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function Interaction.relations:owner()
        return self:morphTo('owner_type', 'owner_id')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `interactions`') then
            return {{ id = 1, owner_type = 'NonExistentModel', owner_id = 42 }}
        end
        return {}
    end

    local interaction = Interaction:find(1)
    local owner = interaction:load('owner')
    Database.query = original

    falsy(owner, 'morphTo: nil returned when global model not found')
end)

test('BaseModel.with: morphOne batches one query for all instances with WHERE IN owner_id', function()
    local ATMMachine = BaseModel:extend('atm_machines')
    ATMMachine.primaryKey = 'id'
    ATMMachine.timestamps = false

    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function ATMMachine.relations:interaction()
        return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ATMMachine')
    end

    local interactionParams, interactionSql
    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `atm_machines`') then
            return {{ id = 1, name = 'ATM A' }, { id = 2, name = 'ATM B' }}
        elseif sql:find('FROM `interactions`') then
            interactionSql = sql
            interactionParams = params
            return {
                { id = 10, owner_type = 'ATMMachine', owner_id = 1, label = 'ATM A' },
                { id = 11, owner_type = 'ATMMachine', owner_id = 2, label = 'ATM B' },
            }
        end
        return {}
    end

    local atms = ATMMachine:with('interaction'):get()
    Database.query = original

    eq(#atms, 2, 'morphOne eagerLoad: both base rows returned')
    truthy(atms[1].interaction, 'morphOne eagerLoad: first instance has interaction')
    truthy(atms[2].interaction, 'morphOne eagerLoad: second instance has interaction')
    eq(atms[1].interaction.label, 'ATM A', 'morphOne eagerLoad: correct interaction for first')
    eq(atms[2].interaction.label, 'ATM B', 'morphOne eagerLoad: correct interaction for second')
    eqList(interactionParams, {1, 2}, 'morphOne eagerLoad: batched owner_id IN query')
    truthy(interactionSql:find('ATMMachine', 1, true), 'owner_type filter present in SQL')
end)

test('BaseModel.with: morphMany distributes all related rows per instance', function()
    local Post = BaseModel:extend('posts')
    Post.primaryKey = 'id'
    Post.timestamps = false

    local Comment = BaseModel:extend('comments')
    Comment.primaryKey = 'id'
    Comment.timestamps = false

    function Post.relations:comments()
        return self:morphMany(Comment, 'owner_id', 'owner_type', 'Post')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then
            return {{ id = 1 }, { id = 2 }}
        elseif sql:find('FROM `comments`') then
            return {
                { id = 10, owner_type = 'Post', owner_id = 1, body = 'A' },
                { id = 11, owner_type = 'Post', owner_id = 1, body = 'B' },
                { id = 12, owner_type = 'Post', owner_id = 2, body = 'C' },
            }
        end
        return {}
    end

    local posts = Post:with('comments'):get()
    Database.query = original

    eq(#posts[1].comments, 2, 'morphMany eagerLoad: post 1 gets 2 comments')
    eq(#posts[2].comments, 1, 'morphMany eagerLoad: post 2 gets 1 comment')
    eq(posts[1].comments[1].body, 'A', 'morphMany eagerLoad: first comment body')
    eq(posts[2].comments[1].body, 'C', 'morphMany eagerLoad: only post2 comment')
end)

test('BaseModel.with: morphTo eagerLoad batches by owner_type and groups correctly', function()
    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function Interaction.relations:owner()
        return self:morphTo('owner_type', 'owner_id')
    end

    local int1 = Interaction.new({ owner_type = 'ATMMachine', owner_id = 10 })
    int1.primaryKey = 'id'
    local int2 = Interaction.new({ owner_type = 'Garage', owner_id = 20 })
    int2.primaryKey = 'id'

    local atmQueries = {}
    local garageQueries = {}

    local origAtm = rawget(_G, 'ATMMachine')
    local origGarage = rawget(_G, 'Garage')

    local AtmModel = BaseModel:extend('atm_machines')
    AtmModel.primaryKey = 'id'
    AtmModel.timestamps = false

    local GarageModel = BaseModel:extend('garages')
    GarageModel.primaryKey = 'id'
    GarageModel.timestamps = false

    _G['ATMMachine'] = AtmModel
    _G['Garage'] = GarageModel

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `atm_machines`') then
            table.insert(atmQueries, {sql = sql, params = params})
            return {{ id = 10, name = 'Test ATM' }}
        elseif sql:find('FROM `garages`') then
            table.insert(garageQueries, {sql = sql, params = params})
            return {{ id = 20, name = 'Test Garage' }}
        end
        return {}
    end

    Interaction:eagerLoad({int1, int2}, 'owner')
    Database.query = original

    _G['ATMMachine'] = origAtm
    _G['Garage'] = origGarage

    eq(#atmQueries, 1, 'morphTo eagerLoad: one query for ATMMachine batch')
    eq(#garageQueries, 1, 'morphTo eagerLoad: one query for Garage batch')
    truthy(int1.relations['owner'], 'morphTo eagerLoad: int1 has owner loaded')
    truthy(int2.relations['owner'], 'morphTo eagerLoad: int2 has owner loaded')
    eq(int1.relations['owner'].name, 'Test ATM', 'morphTo eagerLoad: int1 owner is ATM')
    eq(int2.relations['owner'].name, 'Test Garage', 'morphTo eagerLoad: int2 owner is Garage')
end)

--------------------------------------------------------------------------------
-- whereHas / has / whereRelation / orWhereHas
--------------------------------------------------------------------------------

test('whereHas: hasMany emits a correlated EXISTS with the callback conditions applied', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Customer.relations:orders() return self:hasMany(Order, 'customer_id') end

    local capturedSql, capturedParams
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql, capturedParams = sql, params
        return {}
    end

    Customer:whereHas('orders', function(query)
        query:where('total', '>', 100)
    end):get()
    Database.query = original

    truthy(capturedSql:find('EXISTS %('), 'whereHas: wraps subquery in EXISTS')
    truthy(capturedSql:find('FROM `orders`'), 'whereHas: subquery selects from related table')
    truthy(capturedSql:find('`orders`%.`customer_id` = `customers`%.`id`'), 'whereHas: correlates on foreignKey = localKey')
    truthy(capturedSql:find('`total` > %?'), 'whereHas: callback condition present')
    eqList(capturedParams, {100}, 'whereHas: callback param bound')
end)

test('has: no callback still constrains to rows with at least one related row', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Customer.relations:orders() return self:hasMany(Order, 'customer_id') end

    local capturedSql
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql = sql
        return {}
    end

    Customer:has('orders'):get()
    Database.query = original

    truthy(capturedSql:find('EXISTS %('), 'has: wraps subquery in EXISTS')
    truthy(capturedSql:find('WHERE `orders`%.`customer_id` = `customers`%.`id`%)$'),
        'has: only the correlation condition, no extra callback conditions')
end)

test('whereRelation: shorthand for whereHas + single where', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    function Customer.relations:orders() return self:hasMany(Order, 'customer_id') end

    local capturedSql, capturedParams
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql, capturedParams = sql, params
        return {}
    end

    Customer:whereRelation('orders', 'status', 'paid'):get()
    Database.query = original

    truthy(capturedSql:find('`status` = %?'), 'whereRelation: equality condition on related column')
    eqList(capturedParams, {'paid'}, 'whereRelation: value bound as param')
end)

test('orWhereHas: joins the EXISTS clause with OR', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    local Invoice = BaseModel:extend('invoices')
    function Customer.relations:orders() return self:hasMany(Order, 'customer_id') end
    function Customer.relations:invoices() return self:hasMany(Invoice, 'customer_id') end

    local capturedSql
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql = sql
        return {}
    end

    Customer:has('orders'):orWhereHas('invoices'):get()
    Database.query = original

    truthy(capturedSql:find('EXISTS %(.-%) OR EXISTS %('), 'orWhereHas: two EXISTS clauses joined by OR')
end)

test('whereHas chained multiple times ANDs together', function()
    local Customer = BaseModel:extend('customers')
    local Order = BaseModel:extend('orders')
    local Invoice = BaseModel:extend('invoices')
    function Customer.relations:orders() return self:hasMany(Order, 'customer_id') end
    function Customer.relations:invoices() return self:hasMany(Invoice, 'customer_id') end

    local capturedSql
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql = sql
        return {}
    end

    Customer:has('orders'):has('invoices'):get()
    Database.query = original

    truthy(capturedSql:find('EXISTS %(.-%) AND EXISTS %('), 'whereHas chaining: two EXISTS clauses joined by AND')
end)

test('whereHas: belongsToMany correlates through the pivot table', function()
    local Tag = BaseModel:extend('tags')
    local Post = BaseModel:extend('posts')
    function Post.relations:tags() return self:belongsToMany(Tag, 'post_tags', 'post_id', 'tag_id') end

    local capturedSql
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql = sql
        return {}
    end

    Post:whereHas('tags', function(query)
        query:where('name', 'featured')
    end):get()
    Database.query = original

    truthy(capturedSql:find('FROM `tags`'), 'belongsToMany whereHas: subquery selects from related table')
    truthy(capturedSql:find('JOIN `post_tags`'), 'belongsToMany whereHas: subquery joins the pivot table')
    truthy(capturedSql:find('`post_tags`%.`post_id` = `posts`%.`id`'), 'belongsToMany whereHas: correlates pivot FK to outer PK')
end)

test('whereHas: morphMany correlates on owner_type literal + owner_id', function()
    local Post = BaseModel:extend('posts')
    local Comment = BaseModel:extend('comments')
    function Post.relations:comments()
        return self:morphMany(Comment, 'owner_id', 'owner_type', 'Post')
    end

    local capturedSql
    local original = Database.query
    Database.query = function(sql, params)
        capturedSql = sql
        return {}
    end

    Post:has('comments'):get()
    Database.query = original

    truthy(capturedSql:find("`comments`%.`owner_type` = 'Post'"), 'morphMany whereHas: owner_type literal embedded')
    truthy(capturedSql:find('`comments`%.`owner_id` = `posts`%.`id`'), 'morphMany whereHas: owner_id correlates to outer PK')
end)

test('whereHas: unsupported relation type (morphTo) raises', function()
    local Interaction = BaseModel:extend('interactions')
    function Interaction.relations:owner() return self:morphTo('owner_type', 'owner_id') end

    throws(function()
        Interaction:has('owner')
    end, 'whereHas: morphTo should raise since its target model is dynamic')
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
