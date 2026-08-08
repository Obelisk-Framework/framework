--- QueryBuilder - Fluent interface for building SQL queries
--- Inspired by Laravel's Eloquent Query Builder
QueryBuilder = {}
QueryBuilder.__index = QueryBuilder

--- Operators permitted in WHERE / JOIN clauses. A caller-supplied operator
--- outside this set is rejected, so an operator can never smuggle in SQL.
local ALLOWED_OPERATORS = {
    ['='] = true, ['!='] = true, ['<>'] = true,
    ['<'] = true, ['<='] = true, ['>'] = true, ['>='] = true,
    ['LIKE'] = true, ['NOT LIKE'] = true, ['IS'] = true, ['IS NOT'] = true,
}

--- Permitted JOIN types.
local ALLOWED_JOIN_TYPES = {
    INNER = true, LEFT = true, RIGHT = true, FULL = true, CROSS = true,
}

--- Quote a column/table identifier for safe interpolation into SQL.
--- Values are parameterized, but identifiers (table/column names, operators,
--- directions) are interpolated, so they are the injection surface. Accepts a
--- bare identifier ("users"), a qualified one ("k.action_id"), "*" or
--- "table.*". Every part must match [A-Za-z0-9_$]+; anything else (quotes,
--- spaces, parentheses, semicolons, comment markers, ...) throws. That throw
--- is what stops identifier-based SQL injection.
--- @param identifier string
--- @return string quoted
function QueryBuilder.quoteIdentifier(identifier)
    return Database.dialect.quoteIdentifier(identifier)
end

--- Validate a WHERE/JOIN operator against the allowlist.
--- @param operator any
--- @return string normalized upper-cased operator
local function normalizeOperator(operator)
    local op = tostring(operator):upper()
    if not ALLOWED_OPERATORS[op] then
        error('QueryBuilder: illegal operator "' .. tostring(operator) .. '"', 2)
    end
    return op
end

--- Create a new QueryBuilder instance
--- @param tableName string
--- @return QueryBuilder
function QueryBuilder.new(tableName, primaryKey)
    local self = setmetatable({}, QueryBuilder)
    self.tableName = tableName
    self.primaryKey = primaryKey or 'id'
    self.selectColumns = {'*'}
    self.rawSelect = nil
    self.whereConditions = {}
    self.orderByList = {}
    self.limitValue = nil
    self.offsetValue = nil
    self.joins = {}
    self.groupByColumns = {}
    self.havingConditions = {}
    self.params = {}
    self.paramIndex = 1
    return self
end

--- Select specific columns
--- @param columns table|string
--- @return QueryBuilder
function QueryBuilder:select(columns)
    if type(columns) == 'string' then
        self.selectColumns = {columns}
    else
        self.selectColumns = columns
    end
    self.rawSelect = nil
    return self
end

--- Set a raw, unquoted SELECT expression (e.g. an aggregate like COUNT(*)).
--- Library-internal only: never pass caller-supplied input here, as it is
--- interpolated verbatim.
--- @param expression string
--- @return QueryBuilder
function QueryBuilder:selectRaw(expression)
    self.rawSelect = expression
    return self
end

--- Add a WHERE clause
--- @param column string
--- @param operator string|any If only 2 args, this is the value
--- @param value any Optional value if operator provided
--- @return QueryBuilder
function QueryBuilder:where(column, operator, value)
    if value == nil then
        -- where(column, value) syntax
        value = operator
        operator = '='
    end
    
    table.insert(self.whereConditions, {
        type = 'basic',
        column = column,
        operator = operator,
        value = value,
        boolean = 'AND'
    })
    return self
end

--- Add an OR WHERE clause
--- @param column string
--- @param operator string|any
--- @param value any
--- @return QueryBuilder
function QueryBuilder:orWhere(column, operator, value)
    if value == nil then
        value = operator
        operator = '='
    end
    
    table.insert(self.whereConditions, {
        type = 'basic',
        column = column,
        operator = operator,
        value = value,
        boolean = 'OR'
    })
    return self
end

--- WHERE IN clause
--- @param column string
--- @param values table
--- @return QueryBuilder
function QueryBuilder:whereIn(column, values)
    table.insert(self.whereConditions, {
        type = 'in',
        column = column,
        values = values,
        boolean = 'AND'
    })
    return self
end

--- WHERE NULL clause
--- @param column string
--- @return QueryBuilder
function QueryBuilder:whereNull(column)
    table.insert(self.whereConditions, {
        type = 'null',
        column = column,
        boolean = 'AND'
    })
    return self
end

--- WHERE NOT NULL clause
--- @param column string
--- @return QueryBuilder
function QueryBuilder:whereNotNull(column)
    table.insert(self.whereConditions, {
        type = 'notNull',
        column = column,
        boolean = 'AND'
    })
    return self
end

--- Add ORDER BY clause
--- @param column string
--- @param direction string 'ASC' or 'DESC'
--- @return QueryBuilder
function QueryBuilder:orderBy(column, direction)
    direction = direction or 'ASC'
    table.insert(self.orderByList, {column = column, direction = direction:upper()})
    return self
end

--- Set LIMIT
--- @param limit number
--- @return QueryBuilder
function QueryBuilder:limit(limit)
    self.limitValue = limit
    return self
end

--- Set OFFSET
--- @param offset number
--- @return QueryBuilder
function QueryBuilder:offset(offset)
    self.offsetValue = offset
    return self
end

--- Add JOIN clause
--- @param tableName string
--- @param first string
--- @param operator string
--- @param second string
--- @param joinType string 'INNER', 'LEFT', 'RIGHT'
--- @return QueryBuilder
function QueryBuilder:join(tableName, first, operator, second, joinType)
    -- NB: the table/type parameters are named tableName/joinType so they don't
    -- shadow the global `table` library (which broke table.insert here) or the
    -- `type` builtin.
    joinType = joinType or 'INNER'
    table.insert(self.joins, {
        table = tableName,
        first = first,
        operator = operator,
        second = second,
        type = joinType
    })
    return self
end

--- Add LEFT JOIN
--- @param tableName string
--- @param first string
--- @param operator string
--- @param second string
--- @return QueryBuilder
function QueryBuilder:leftJoin(tableName, first, operator, second)
    return self:join(tableName, first, operator, second, 'LEFT')
end

--- Add GROUP BY
--- @param columns table|string
--- @return QueryBuilder
function QueryBuilder:groupBy(columns)
    if type(columns) == 'string' then
        table.insert(self.groupByColumns, columns)
    else
        for _, col in ipairs(columns) do
            table.insert(self.groupByColumns, col)
        end
    end
    return self
end

--- Build the WHERE clause SQL
--- @return string SQL fragment
function QueryBuilder:buildWhereClause()
    if #self.whereConditions == 0 then
        return ''
    end
    
    local clauses = {}
    
    for i, condition in ipairs(self.whereConditions) do
        local clause = ''
        
        if i > 1 then
            -- clauses are joined with a single space below, so only a trailing
            -- space is needed here (a leading one produced doubled spaces).
            clause = clause .. condition.boolean .. ' '
        end
        
        if condition.type == 'basic' then
            clause = clause .. QueryBuilder.quoteIdentifier(condition.column) .. ' ' ..
                     normalizeOperator(condition.operator) .. ' ?'
            table.insert(self.params, condition.value)
        elseif condition.type == 'in' then
            local placeholders = {}
            for _, val in ipairs(condition.values) do
                table.insert(placeholders, '?')
                table.insert(self.params, val)
            end
            clause = clause .. QueryBuilder.quoteIdentifier(condition.column) ..
                     ' IN (' .. table.concat(placeholders, ', ') .. ')'
        elseif condition.type == 'null' then
            clause = clause .. QueryBuilder.quoteIdentifier(condition.column) .. ' IS NULL'
        elseif condition.type == 'notNull' then
            clause = clause .. QueryBuilder.quoteIdentifier(condition.column) .. ' IS NOT NULL'
        end
        
        table.insert(clauses, clause)
    end
    
    return 'WHERE ' .. table.concat(clauses, ' ')
end

--- Build the ORDER BY clause
--- @return string
function QueryBuilder:buildOrderByClause()
    if #self.orderByList == 0 then
        return ''
    end
    
    local clauses = {}
    for _, order in ipairs(self.orderByList) do
        local direction = tostring(order.direction):upper()
        if direction ~= 'ASC' and direction ~= 'DESC' then
            error('QueryBuilder: illegal order direction "' .. tostring(order.direction) .. '"', 2)
        end
        table.insert(clauses, QueryBuilder.quoteIdentifier(order.column) .. ' ' .. direction)
    end

    return 'ORDER BY ' .. table.concat(clauses, ', ')
end

--- Build the LIMIT/OFFSET clause
--- @return string
function QueryBuilder:buildLimitClause()
    local clause = ''
    
    if self.limitValue ~= nil then
        local n = tonumber(self.limitValue)
        if not n then error('QueryBuilder: LIMIT must be numeric', 2) end
        clause = 'LIMIT ' .. math.floor(n)
    end

    if self.offsetValue ~= nil then
        local n = tonumber(self.offsetValue)
        if not n then error('QueryBuilder: OFFSET must be numeric', 2) end
        clause = clause .. ' OFFSET ' .. math.floor(n)
    end

    return clause
end

--- Build the JOIN clause
--- @return string
function QueryBuilder:buildJoinClause()
    if #self.joins == 0 then
        return ''
    end
    
    local clauses = {}
    for _, join in ipairs(self.joins) do
        local joinType = tostring(join.type):upper()
        if not ALLOWED_JOIN_TYPES[joinType] then
            error('QueryBuilder: illegal join type "' .. tostring(join.type) .. '"', 2)
        end
        local clause = joinType .. ' JOIN ' .. QueryBuilder.quoteIdentifier(join.table) .. ' ON ' ..
                      QueryBuilder.quoteIdentifier(join.first) .. ' ' .. normalizeOperator(join.operator) ..
                      ' ' .. QueryBuilder.quoteIdentifier(join.second)
        table.insert(clauses, clause)
    end
    
    return table.concat(clauses, ' ')
end

--- Build the SELECT column list.
--- A rawSelect expression (set via selectRaw, e.g. COUNT(*)) is emitted as-is;
--- otherwise every column is quoted/validated as an identifier.
--- @return string
function QueryBuilder:buildSelectClause()
    if self.rawSelect then
        return self.rawSelect
    end

    local columns = {}
    for _, col in ipairs(self.selectColumns) do
        table.insert(columns, QueryBuilder.quoteIdentifier(col))
    end
    return table.concat(columns, ', ')
end

--- Build complete SELECT query
--- @return string, table SQL and parameters
function QueryBuilder:toSql()
    self.params = {} -- Reset params

    local sql = 'SELECT ' .. self:buildSelectClause() ..
                ' FROM ' .. QueryBuilder.quoteIdentifier(self.tableName)

    local joinClause = self:buildJoinClause()
    if joinClause ~= '' then
        sql = sql .. ' ' .. joinClause
    end
    
    local whereClause = self:buildWhereClause()
    if whereClause ~= '' then
        sql = sql .. ' ' .. whereClause
    end
    
    if #self.groupByColumns > 0 then
        local grouped = {}
        for _, col in ipairs(self.groupByColumns) do
            table.insert(grouped, QueryBuilder.quoteIdentifier(col))
        end
        sql = sql .. ' GROUP BY ' .. table.concat(grouped, ', ')
    end
    
    local orderByClause = self:buildOrderByClause()
    if orderByClause ~= '' then
        sql = sql .. ' ' .. orderByClause
    end
    
    local limitClause = self:buildLimitClause()
    if limitClause ~= '' then
        sql = sql .. ' ' .. limitClause
    end
    
    return sql, self.params
end

--- Execute the query and return results (async)
--- @param callback function
function QueryBuilder:get(callback)
    local sql, params = self:toSql()
    Database.query(sql, params, callback)
end

--- Execute the query synchronously
--- @return table Results
function QueryBuilder:getSync()
    local sql, params = self:toSql()
    return Database.querySync(sql, params)
end

--- Get first result (async)
--- @param callback function
function QueryBuilder:first(callback)
    self:limit(1)
    self:get(function(results)
        callback(results[1])
    end)
end

--- Get first result synchronously
--- @return table|nil
function QueryBuilder:firstSync()
    self:limit(1)
    local results = self:getSync()
    return results[1]
end

--- Count results
--- @param callback function
function QueryBuilder:count(callback)
    local originalRaw = self.rawSelect
    self:selectRaw('COUNT(*) as count')

    self:first(function(result)
        self.rawSelect = originalRaw
        callback(result and result.count or 0)
    end)
end

--- Count synchronously
--- @return number
function QueryBuilder:countSync()
    local originalRaw = self.rawSelect
    self:selectRaw('COUNT(*) as count')

    local result = self:firstSync()
    self.rawSelect = originalRaw

    return result and result.count or 0
end

--- Insert data
--- @param data table Key-value pairs
--- @param callback function Receives insertId
function QueryBuilder:insert(data, callback)
    local columns = {}
    local placeholders = {}
    local values = {}
    
    for column, value in pairs(data) do
        table.insert(columns, QueryBuilder.quoteIdentifier(column))
        table.insert(placeholders, '?')
        table.insert(values, value)
    end

    local sql = 'INSERT INTO ' .. QueryBuilder.quoteIdentifier(self.tableName) ..
                ' (' .. table.concat(columns, ', ') .. ') VALUES (' ..
                table.concat(placeholders, ', ') .. ')' ..
                Database.dialect.insertReturningClause(self.primaryKey)

    if callback then
        Database.insert(sql, values, callback)
    else
        return Database.insertSync(sql, values)
    end
end

--- Update data
--- @param data table Key-value pairs
--- @param callback function Receives affectedRows
function QueryBuilder:update(data, callback)
    local setClauses = {}
    local values = {}
    
    for column, value in pairs(data) do
        table.insert(setClauses, QueryBuilder.quoteIdentifier(column) .. ' = ?')
        table.insert(values, value)
    end

    local sql = 'UPDATE ' .. QueryBuilder.quoteIdentifier(self.tableName) .. ' SET ' .. table.concat(setClauses, ', ')
    
    local whereClause = self:buildWhereClause()
    if whereClause ~= '' then
        sql = sql .. ' ' .. whereClause
        for _, param in ipairs(self.params) do
            table.insert(values, param)
        end
    end
    
    if callback then
        Database.update(sql, values, callback)
    else
        return Database.updateSync(sql, values)
    end
end

--- Delete records
--- @param callback function
function QueryBuilder:delete(callback)
    local sql = 'DELETE FROM ' .. QueryBuilder.quoteIdentifier(self.tableName)
    
    local whereClause = self:buildWhereClause()
    if whereClause ~= '' then
        sql = sql .. ' ' .. whereClause
    end
    
    if callback then
        Database.update(sql, self.params, callback)
    else
        return Database.updateSync(sql, self.params)
    end
end

--- Paginate results
--- @param page number
--- @param perPage number
--- @param callback function Receives {data, total, lastPage, currentPage}
function QueryBuilder:paginate(page, perPage, callback)
    page = page or 1
    perPage = perPage or 15
    
    -- First get total count
    self:count(function(total)
        local lastPage = math.ceil(total / perPage)
        local offset = (page - 1) * perPage
        
        -- Now get the actual data
        self:limit(perPage):offset(offset):get(function(data)
            callback({
                data = data,
                total = total,
                perPage = perPage,
                currentPage = page,
                lastPage = lastPage
            })
        end)
    end)
end

return QueryBuilder
