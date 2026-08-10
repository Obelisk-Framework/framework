--- Unit tests for ActionService.register's DB-backed upsert behavior.
--- Run from the repository root:  lua5.4 tests/action_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

-- ActionService.lua registers a net event handler via Obelisk.onServer at
-- module load time. These tests only exercise register/getDbId/resolveDbId
-- (never execute), so a minimal stub is enough to let the file load.
_G.Obelisk = _G.Obelisk or {onServer = function() end}

dofile(ROOT .. '/core/server/Services/ActionService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

--- Fakes the `actions` table as an in-memory list, so ActionService.register's
--- upsert logic (SELECT-then-INSERT-or-UPDATE) can be tested without a real
--- database. Resets between tests.
local function withFakeActionsTable(fn)
    local rows = {}
    local nextId = 1
    local inserts, updates = 0, 0

    local original = Database.executeQuery
    Database.executeQuery = function(query, params)
        if query:find('SELECT', 1, true) and query:find('FROM `actions`', 1, true) then
            for _, row in ipairs(rows) do
                if row.action_id == params[1] then
                    return {row}
                end
            end
            return {}
        elseif query:find('INSERT INTO', 1, true) then
            -- QueryBuilder.insert iterates the data table with pairs(), so the
            -- column order in the generated SQL (and therefore the position of
            -- each value in `params`) is not fixed. Map values back to columns
            -- by reading the column list straight out of the query instead of
            -- assuming a fixed params[1..4] order.
            local columnList = query:match('%((.-)%)%s*VALUES')
            local row = {id = nextId}
            local i = 0
            for col in columnList:gmatch('`([^`]+)`') do
                i = i + 1
                row[col] = params[i]
            end
            table.insert(rows, row)
            nextId = nextId + 1
            inserts = inserts + 1
            return {insertId = row.id}
        elseif query:find('UPDATE', 1, true) then
            updates = updates + 1
            return {affectedRows = 1}
        end
        return {}
    end

    local ok, err = pcall(fn, function() return {rows = rows, inserts = inserts, updates = updates} end)
    Database.executeQuery = original
    if not ok then error(err, 2) end
end

test('register: a brand-new actionId inserts exactly one row', function()
    withFakeActionsTable(function(get)
        ActionService.register('test:foo', function() end, {label = 'Foo'})
        local state = get()
        eq(#state.rows, 1)
        eq(state.rows[1].action_id, 'test:foo')
    end)
end)

test('register: registering the same actionId twice never inserts a second row', function()
    withFakeActionsTable(function(get)
        ActionService.register('test:foo', function() end, {label = 'Foo'})
        ActionService.register('test:foo', function() end, {label = 'Foo v2'})
        local state = get()
        eq(#state.rows, 1)
    end)
end)

test('getDbId: returns the integer id for a registered actionId', function()
    withFakeActionsTable(function()
        ActionService.register('test:bar', function() end, {})
        truthy(type(ActionService.getDbId('test:bar')) == 'number', 'getDbId returns a number')
    end)
end)

test('getDbId: returns nil for an actionId that was never registered', function()
    eq(ActionService.getDbId('test:never-registered'), nil)
end)

test('resolveDbId: reverse-resolves the integer id back to the string actionId', function()
    withFakeActionsTable(function()
        ActionService.register('test:baz', function() end, {})
        local dbId = ActionService.getDbId('test:baz')
        eq(ActionService.resolveDbId(dbId), 'test:baz')
    end)
end)

test('resolveDbId: returns nil for an unknown integer id', function()
    eq(ActionService.resolveDbId(999999), nil)
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running ActionService unit tests\n')
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
