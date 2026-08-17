--- Database Manager - thin layer over a MySQL connector resource.
--- A real connector (oxmysql / ghmattimysql / mysql-async / oblsk_connector)
--- is REQUIRED; there is no in-memory fallback. If none is present the
--- framework fails fast rather than silently pretending to persist data.
Database = {}

--- Sentinel value for QueryBuilder:update({ column = Database.NULL }) to
--- express "set this column to SQL NULL". Lua tables can never store a
--- key whose value is literal `nil` (a table constructor with a nil
--- value simply omits the key), so a real value is needed to represent
--- "set to NULL" through an update() data table.
Database.NULL = setmetatable({}, { __tostring = function() return 'NULL' end })

Database.ready = false
Database.connector = nil -- name of the detected connector resource
Database.config = {
    host = 'mariadb',
    port = 3306,
    user = 'obelisk',
    password = 'obelisk_password',
    database = 'fivem',
    charset = 'utf8mb4'
}
Database.debug = false

-- Default dialect: MySQL, matching Database.config's default host/port. Real
-- driver selection (from db_driver convar or connection-string scheme)
-- happens in Database.init(); this default lets QueryBuilder/Schema build
-- correct SQL even before init() runs (e.g. in unit tests).
Database.dialect = Dialects.resolve('mysql')

--- MySQL connector resources, in order of preference.
local CONNECTORS = { 'oblsk_connector', 'oxmysql', 'ghmattimysql', 'mysql-async' }

--- Parse MySQL connection string
--- Format: mysql://user:password@host:port/database
--- @param connectionString string
--- @return table config
function Database.parseConnectionString(connectionString)
    local config = {}

    local scheme, userPass, hostPath = connectionString:match('^(%a+)://([^@]+)@(.+)$')
    if scheme then
        config.driver = (scheme == 'postgres' or scheme == 'postgresql') and 'postgres' or 'mysql'
    end

    if userPass then
        config.user, config.password = userPass:match('([^:]+):(.+)')
    end

    if hostPath then
        local hostPort, database = hostPath:match('([^/]+)/(.+)')
        if hostPort then
            local host, port = hostPort:match('([^:]+):?(%d*)')
            config.host = host
            config.port = tonumber(port) or (config.driver == 'postgres' and 5432 or 3306)
            config.database = database
        end
    end

    return config
end

--- Detect the first available MySQL connector resource.
--- @return string|nil connector resource name, or nil if none is started
function Database.detectConnector()
    for _, name in ipairs(CONNECTORS) do
        if GetResourceState(name) == 'started' then
            return name
        end
    end
    return nil
end

--- Initialize database.
--- @return boolean ready True if a connector was found; false means the
--- framework must not continue (there is no in-memory fallback).
function Database.init()
    local connectionString = GetConvar('mysql_connection_string', '')
    Database.debug = GetConvarInt('db_debug', 0) == 1

    if connectionString ~= '' then
        local parsed = Database.parseConnectionString(connectionString)
        for k, v in pairs(parsed) do
            -- driver is deliberately excluded here: the sibling oblsk_connector
            -- resource (a separate process/repo) has no visibility into this
            -- connection string and resolves its own driver purely from the
            -- db_driver convar. If core also inferred a driver from the
            -- connection-string scheme, the two sides could silently disagree
            -- (e.g. core generates Postgres SQL while the connector's sidecar
            -- stays on a MySQL pool). So db_driver is the ONLY source of truth
            -- for Database.config.driver, matching the connector exactly.
            if k ~= 'driver' and v and v ~= '' then
                Database.config[k] = v
            end
        end
    end

    -- db_driver convar is the sole source of truth for the driver; defaults
    -- to mysql when unset. See the comment above the connection-string merge
    -- for why the connection-string scheme is deliberately NOT consulted.
    local driverConvar = GetConvar('db_driver', '')
    if driverConvar ~= '' then
        Database.config.driver = driverConvar
    end
    Database.config.driver = Database.config.driver or 'mysql'
    Database.dialect = Dialects.resolve(Database.config.driver)

    Database.connector = Database.detectConnector()

    if not Database.connector then
        Database.ready = false
        print('[Database] ============================================================')
        print('[Database] FATAL: No MySQL connector resource found.')
        print('[Database] Obelisk requires a database and has no in-memory fallback.')
        print('[Database] Start one of these BEFORE obelisk in your server.cfg:')
        print('[Database]   ensure oxmysql        (recommended)')
        print('[Database]   ensure ghmattimysql')
        print('[Database]   ensure mysql-async')
        print('[Database]   ensure oblsk_connector')
        print('[Database] ============================================================')
        return false
    end

    if Database.config.driver == 'postgres' and Database.connector ~= 'oblsk_connector' then
        Database.ready = false
        print('[Database] ============================================================')
        print('[Database] FATAL: db_driver "postgres" requires oblsk_connector.')
        print('[Database] Connector "' .. Database.connector .. '" only speaks MySQL.')
        print('[Database] Start oblsk_connector instead, or set db_driver back to mysql.')
        print('[Database] ============================================================')
        return false
    end

    Database.ready = true
    print('[Database] Initialized (connector: ' .. Database.connector .. ', driver: ' .. Database.config.driver .. ')')
    print('[Database] Config: ' .. Database.config.user .. '@' .. Database.config.host .. ':' .. Database.config.port .. '/' .. Database.config.database)

    return true
end

--- Execute query synchronously
--- @param query string SQL query
--- @param params table Parameters
--- @return table result
function Database.query(query, params)
    params = params or {}
    return Database.executeQuery(query, params)
end

--- Execute query asynchronously
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback function
function Database.queryAsync(query, params, callback)
    params = params or {}

    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        if callback then
            callback(result)
        end
    end)
end

--- Insert query sync
--- @param query string SQL query
--- @param params table Parameters
--- @return number insertId
function Database.insert(query, params)
    params = params or {}
    local result = Database.executeQuery(query, params)
    return result and result.insertId or 0
end

--- Insert query async
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback with insertId
function Database.insertAsync(query, params, callback)
    params = params or {}

    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        local insertId = result and result.insertId or 0
        if callback then
            callback(insertId)
        end
    end)
end

--- Update query sync
--- @param query string SQL query
--- @param params table Parameters
--- @return number affectedRows
function Database.update(query, params)
    params = params or {}
    local result = Database.executeQuery(query, params)
    return result and result.affectedRows or 0
end

--- Update query async
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback with affectedRows
function Database.updateAsync(query, params, callback)
    params = params or {}

    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        local affectedRows = result and result.affectedRows or 0
        if callback then
            callback(affectedRows)
        end
    end)
end

--- Delete query sync (alias for update)
function Database.delete(query, params)
    return Database.update(query, params)
end

--- Delete query async (alias for update)
function Database.deleteAsync(query, params, callback)
    Database.updateAsync(query, params, callback)
end

--- Execute raw query sync
function Database.execute(query, params)
    return Database.query(query, params)
end

--- Execute raw query async
function Database.executeAsync(query, params, callback)
    Database.queryAsync(query, params, callback)
end

--- Prepare query (replace ? with values)
--- @param query string Query with ? placeholders
--- @param params table Parameters
--- @return string preparedQuery
function Database.prepareQuery(query, params)
    if not params or #params == 0 then
        return query
    end
    
    -- Substitute each ? placeholder left-to-right with its escaped value.
    -- A function replacement is used deliberately: the returned value is
    -- inserted literally, so a '%' inside a value is not misinterpreted as a
    -- gsub capture reference, and a '?' inside an already-substituted value is
    -- never re-scanned (both were bugs with the previous one-at-a-time gsub).
    local index = 0
    local prepared = query:gsub('?', function()
        index = index + 1
        if index > #params then
            return '?'
        end
        return Database.escape(params[index])
    end)

    if Database.debug then
        print('[Database] Query: ' .. prepared)
    end

    return prepared
end

--- Execute a query against the detected MySQL connector.
--- oxmysql and ghmattimysql bind parameters themselves (real prepared
--- statements), so the raw query + params array is forwarded to them untouched.
--- Connectors whose parameter API we can't rely on (oblsk_connector /
--- mysql-async) receive an interpolated string built by prepareQuery(), which
--- escapes every value via Database.escape(). There is no in-memory fallback:
--- if no connector is available this errors rather than silently losing data.
--- @param query string SQL query
--- @param params table Parameters
--- @return table result
function Database.executeQuery(query, params)
    params = params or {}

    if Database.debug then
        print('[Database] SQL: ' .. query)
    end

    local connector = Database.connector
    if not connector then
        error('[Database] No MySQL connector available (Database.init must succeed first)', 2)
    end

    if connector == 'oblsk_connector' then
        -- oblsk_connector escapes/interpolates the params itself, so forward
        -- them rather than pre-interpolating (single source of escaping).
        return exports.oblsk_connector:executeSync(query, params)
    elseif connector == 'oxmysql' then
        return exports.oxmysql:executeSync(query, params)
    elseif connector == 'ghmattimysql' then
        return exports.ghmattimysql:executeSync(query, params)
    elseif connector == 'mysql-async' then
        return exports['mysql-async']:mysql_fetch_all_sync(Database.prepareQuery(query, params))
    end

    error('[Database] Unknown connector: ' .. tostring(connector), 2)
end

--- Create a transaction accumulator. Statements queued on it are executed
--- together by Database.transaction.
--- @return table tx
function Database.newTransaction()
    local tx = { queries = {} }

    --- Queue a raw statement.
    --- @param query string
    --- @param params table|nil
    --- @return table tx (chainable)
    function tx:add(query, params)
        table.insert(self.queries, { query = query, params = params or {} })
        return self
    end

    return tx
end

--- Run a set of write statements atomically.
---
--- FiveM MySQL connectors pool connections, so issuing START TRANSACTION and
--- COMMIT as separate executeSync() calls can land on different connections and
--- would NOT be atomic. Statements are therefore collected and submitted
--- together to the connector's native transaction API (oxmysql / ghmattimysql),
--- which wraps them in a single START TRANSACTION ... COMMIT, rolling back on
--- any error. Because the whole batch is sent at once, the callback cannot
--- branch on the result of an earlier statement in the same transaction.
---
--- Usage:
---   Database.transaction(function(tx)
---     tx:add('UPDATE accounts SET balance = balance - ? WHERE id = ?', {100, 1})
---     tx:add('UPDATE accounts SET balance = balance + ? WHERE id = ?', {100, 2})
---   end)
---
--- @param callback function Receives the transaction accumulator (tx)
--- @return boolean success True on commit (or when nothing was queued)
function Database.transaction(callback)
    if type(callback) ~= 'function' then
        return false
    end

    local tx = Database.newTransaction()

    -- If the callback errors, nothing is committed (rollback-before-commit).
    local ok, err = pcall(callback, tx)
    if not ok then
        print('[Database] Transaction aborted before commit: ' .. tostring(err))
        return false
    end

    if #tx.queries == 0 then
        return true
    end

    return Database.commitTransaction(tx.queries)
end

--- Commit a list of { query, params } statements atomically.
--- Prefers the connector's native batch-transaction API; otherwise falls back
--- to a manual START TRANSACTION / COMMIT wrapper (see caveat below).
--- @param queries table Array of { query = string, params = table }
--- @return boolean success
function Database.commitTransaction(queries)
    local success, result = pcall(function()
        -- Any connector that exports transactionSync gets the native atomic
        -- path. oblsk_connector is listed here so it wires up automatically
        -- once it gains a transaction endpoint.
        local resName = Database.connector
        if resName == 'oxmysql' or resName == 'ghmattimysql' or resName == 'oblsk_connector' then
            local connector = exports[resName]
            if connector and connector.transactionSync then
                -- Connectors take an array of { query = , values = }.
                local batch = {}
                for _, q in ipairs(queries) do
                    batch[#batch + 1] = { query = q.query, values = q.params }
                end
                return connector:transactionSync(batch)
            end
        end

        return nil
    end)

    if success and result ~= nil then
        return result and true or false
    end

    -- Fallback: connectors without a batch-transaction API (oblsk_connector /
    -- mysql-async) and the in-memory store. Best effort only — with a
    -- connection-pooling connector this is NOT guaranteed atomic, which is why
    -- the native path above is strongly preferred.
    return Database.commitTransactionFallback(queries)
end

--- Manual START TRANSACTION / COMMIT / ROLLBACK fallback.
--- @param queries table
--- @return boolean success
Database._warnedNonAtomic = Database._warnedNonAtomic or {}

function Database.commitTransactionFallback(queries)
    -- Warn once per connector: the manual wrapper is NOT guaranteed atomic on a
    -- connection-pooling connector (each statement may run on a different
    -- connection). Surfaced loudly rather than failing silently.
    local key = Database.connector or 'none'
    if not Database._warnedNonAtomic[key] then
        print('[Database] WARNING: connector "' .. tostring(Database.connector) ..
              '" has no native transaction API; using a manual START TRANSACTION/COMMIT ' ..
              'wrapper that is NOT guaranteed atomic on a pooling connector.')
        Database._warnedNonAtomic[key] = true
    end

    Database.executeQuery('START TRANSACTION', {})

    for _, q in ipairs(queries) do
        local ok = pcall(Database.executeQuery, q.query, q.params)
        if not ok then
            pcall(Database.executeQuery, 'ROLLBACK', {})
            print('[Database] Transaction rolled back')
            return false
        end
    end

    Database.executeQuery('COMMIT', {})
    return true
end

--- Escape value for SQL
--- @param value any Value to escape
--- @return string escapedValue
function Database.escape(value)
    if value == nil then
        return 'NULL'
    end
    
    local valueType = type(value)
    
    if valueType == 'number' then
        return tostring(value)
    elseif valueType == 'boolean' then
        return value and '1' or '0'
    elseif valueType == 'string' then
        value = value:gsub("'", "''")
        value = value:gsub("\\", "\\\\")
        return "'" .. value .. "'"
    elseif valueType == 'table' then
        return "'" .. json.encode(value):gsub("'", "''") .. "'"
    end
    
    return 'NULL'
end

--- Current timestamp formatted for DATETIME / TIMESTAMP columns.
--- MySQL expects 'YYYY-MM-DD HH:MM:SS' for these column types; passing a raw
--- os.time() integer is rejected (or stored as 0000-00-00) under strict mode.
--- @return string
function Database.now()
    return os.date('%Y-%m-%d %H:%M:%S')
end

--- Check if database is ready
--- @return boolean
function Database.isReady()
    return Database.ready
end
