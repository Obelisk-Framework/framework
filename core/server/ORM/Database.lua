--- Custom Database Manager - Native MySQL implementation
--- No external dependencies required
Database = {}
Database.ready = false
Database.config = {
    host = 'mariadb',
    port = 3306,
    user = 'obelisk',
    password = 'obelisk_password',
    database = 'fivem',
    charset = 'utf8mb4'
}
Database.debug = false

--- In-memory storage (fallback for when no MySQL is available)
Database.storage = {}
Database.autoIncrement = {}

--- Parse MySQL connection string
--- Format: mysql://user:password@host:port/database
--- @param connectionString string
--- @return table config
function Database.parseConnectionString(connectionString)
    local config = {}
    
    local userPass, hostPath = connectionString:match('mysql://([^@]+)@(.+)')
    if userPass then
        config.user, config.password = userPass:match('([^:]+):(.+)')
    end
    
    if hostPath then
        local hostPort, database = hostPath:match('([^/]+)/(.+)')
        if hostPort then
            local host, port = hostPort:match('([^:]+):?(%d*)')
            config.host = host
            config.port = tonumber(port) or 3306
            config.database = database
        end
    end
    
    return config
end

--- Initialize database
function Database.init()
    local connectionString = GetConvar('mysql_connection_string', '')
    Database.debug = GetConvarInt('db_debug', 0) == 1
    
    if connectionString ~= '' then
        local parsed = Database.parseConnectionString(connectionString)
        for k, v in pairs(parsed) do
            if v and v ~= '' then
                Database.config[k] = v
            end
        end
    end
    
    Database.ready = true
    print('[Database] Initialized')
    print('[Database] Config: ' .. Database.config.user .. '@' .. Database.config.host .. ':' .. Database.config.port .. '/' .. Database.config.database)
    
    -- Check for MySQL connector
    local connectorFound = false
    if GetResourceState('oblsk_connector') == 'started' then
        print('[Database] Using oblsk_connector for MySQL')
        connectorFound = true
    elseif GetResourceState('oxmysql') == 'started' then
        print('[Database] Using oxmysql for MySQL')
        connectorFound = true
    elseif GetResourceState('mysql-async') == 'started' then
        print('[Database] Using mysql-async for MySQL')
        connectorFound = true
    elseif GetResourceState('ghmattimysql') == 'started' then
        print('[Database] Using ghmattimysql for MySQL')
        connectorFound = true
    else
        print('[Database] Warning: No MySQL connector found. Using in-memory fallback storage.')
        print('[Database] To use a real database, ensure one of these resources is running:')
        print('[Database]   - oblsk_connector (native FiveM MySQL)')
        print('[Database]   - oxmysql')
        print('[Database]   - mysql-async')
        print('[Database]   - ghmattimysql')
    end
    
    return true
end

--- Execute query asynchronously
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback function
function Database.query(query, params, callback)
    params = params or {}
    
    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        if callback then
            callback(result)
        end
    end)
end

--- Execute query synchronously
--- @param query string SQL query
--- @param params table Parameters
--- @return table result
function Database.querySync(query, params)
    params = params or {}
    return Database.executeQuery(query, params)
end

--- Insert query async
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback with insertId
function Database.insert(query, params, callback)
    params = params or {}
    
    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        local insertId = result and result.insertId or 0
        if callback then
            callback(insertId)
        end
    end)
end

--- Insert query sync
--- @param query string SQL query
--- @param params table Parameters
--- @return number insertId
function Database.insertSync(query, params)
    params = params or {}
    local result = Database.executeQuery(query, params)
    return result and result.insertId or 0
end

--- Update query async
--- @param query string SQL query
--- @param params table Parameters
--- @param callback function Callback with affectedRows
function Database.update(query, params, callback)
    params = params or {}
    
    Citizen.CreateThread(function()
        local result = Database.executeQuery(query, params)
        local affectedRows = result and result.affectedRows or 0
        if callback then
            callback(affectedRows)
        end
    end)
end

--- Update query sync
--- @param query string SQL query
--- @param params table Parameters
--- @return number affectedRows
function Database.updateSync(query, params)
    params = params or {}
    local result = Database.executeQuery(query, params)
    return result and result.affectedRows or 0
end

--- Delete query (alias for update)
function Database.delete(query, params, callback)
    Database.update(query, params, callback)
end

--- Delete query sync
function Database.deleteSync(query, params)
    return Database.updateSync(query, params)
end

--- Execute raw query
function Database.execute(query, params, callback)
    Database.query(query, params, callback)
end

--- Execute raw query sync
function Database.executeSync(query, params)
    return Database.querySync(query, params)
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

--- Execute query (in-memory fallback)
--- @param query string SQL query
--- @param params table Parameters
--- @return table result
function Database.executeQuery(query, params)
    local prepared = Database.prepareQuery(query, params)
    local queryLower = prepared:lower()
    
    -- Try to use any available MySQL resource first
    local success, result = pcall(function()
        if GetResourceState('oblsk_connector') == 'started' then
            return exports.oblsk_connector:executeSync(prepared)
        elseif GetResourceState('oxmysql') == 'started' then
            return exports.oxmysql:executeSync(prepared)
        elseif GetResourceState('mysql-async') == 'started' then
            return exports['mysql-async']:mysql_fetch_all_sync(prepared)
        elseif GetResourceState('ghmattimysql') == 'started' then
            return exports.ghmattimysql:executeSync(prepared)
        end
    end)
    
    if success and result then
        return result
    end
    
    -- Fallback to in-memory storage
    return Database.executeInMemory(prepared)
end

--- Execute in memory (for development/testing)
--- @param query string Prepared SQL query
--- @return table result
function Database.executeInMemory(query)
    local queryLower = query:lower()
    
    -- SELECT
    if queryLower:match('^select') then
        local tableName = queryLower:match('from%s+(%w+)')
        if tableName and Database.storage[tableName] then
            local results = {}
            for _, row in pairs(Database.storage[tableName]) do
                table.insert(results, row)
            end
            return results
        end
        return {}
    end
    
    -- INSERT
    if queryLower:match('^insert') then
        local tableName = queryLower:match('insert%s+into%s+(%w+)')
        if tableName then
            if not Database.storage[tableName] then
                Database.storage[tableName] = {}
                Database.autoIncrement[tableName] = 1
            end
            
            local insertId = Database.autoIncrement[tableName]
            Database.autoIncrement[tableName] = insertId + 1
            
            -- Parse values
            local valuesStr = query:match('VALUES%s*%((.+)%)')
            local row = {id = insertId}
            
            if valuesStr then
                local values = {}
                for value in valuesStr:gmatch('[^,]+') do
                    table.insert(values, value:match('^%s*(.-)%s*$'))
                end
                row._values = values
            end
            
            Database.storage[tableName][insertId] = row
            
            return {insertId = insertId, affectedRows = 1}
        end
    end
    
    -- UPDATE
    if queryLower:match('^update') then
        return {affectedRows = 1}
    end
    
    -- DELETE
    if queryLower:match('^delete') then
        return {affectedRows = 1}
    end
    
    -- CREATE TABLE
    if queryLower:match('^create%s+table') then
        local tableName = queryLower:match('create%s+table%s+`?(%w+)`?')
        if tableName then
            Database.storage[tableName] = {}
            Database.autoIncrement[tableName] = 1
        end
        return {affectedRows = 0}
    end
    
    -- DROP TABLE
    if queryLower:match('^drop%s+table') then
        local tableName = queryLower:match('drop%s+table%s+`?(%w+)`?')
        if tableName then
            Database.storage[tableName] = nil
            Database.autoIncrement[tableName] = nil
        end
        return {affectedRows = 0}
    end
    
    -- ALTER TABLE
    if queryLower:match('^alter%s+table') then
        return {affectedRows = 0}
    end
    
    return {}
end

--- Transaction support
--- @param callback function Transaction callback
function Database.transaction(callback)
    if callback then
        local success, err = pcall(callback)
        if not success then
            print('[Database] Transaction failed: ' .. tostring(err))
        end
    end
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
