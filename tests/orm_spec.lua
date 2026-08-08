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
        t:string('name', 100):notNullable()
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
