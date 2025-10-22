--- QueryBuilder - Fluent interface for building SQL queries
--- Inspired by Laravel's Eloquent Query Builder
QueryBuilder = {}
QueryBuilder.__index = QueryBuilder

--- Create a new QueryBuilder instance
--- @param tableName string
--- @return QueryBuilder
function QueryBuilder.new(tableName)
    local self = setmetatable({}, QueryBuilder)
    self.tableName = tableName
    self.selectColumns = {'*'}
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
--- @param table string
--- @param first string
--- @param operator string
--- @param second string
--- @param type string 'INNER', 'LEFT', 'RIGHT'
--- @return QueryBuilder
function QueryBuilder:join(table, first, operator, second, type)
    type = type or 'INNER'
    table.insert(self.joins, {
        table = table,
        first = first,
        operator = operator,
        second = second,
        type = type
    })
    return self
end

--- Add LEFT JOIN
--- @param table string
--- @param first string
--- @param operator string
--- @param second string
--- @return QueryBuilder
function QueryBuilder:leftJoin(table, first, operator, second)
    return self:join(table, first, operator, second, 'LEFT')
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
            clause = clause .. ' ' .. condition.boolean .. ' '
        end
        
        if condition.type == 'basic' then
            clause = clause .. condition.column .. ' ' .. condition.operator .. ' ?'
            table.insert(self.params, condition.value)
        elseif condition.type == 'in' then
            local placeholders = {}
            for _, val in ipairs(condition.values) do
                table.insert(placeholders, '?')
                table.insert(self.params, val)
            end
            clause = clause .. condition.column .. ' IN (' .. table.concat(placeholders, ', ') .. ')'
        elseif condition.type == 'null' then
            clause = clause .. condition.column .. ' IS NULL'
        elseif condition.type == 'notNull' then
            clause = clause .. condition.column .. ' IS NOT NULL'
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
        table.insert(clauses, order.column .. ' ' .. order.direction)
    end
    
    return 'ORDER BY ' .. table.concat(clauses, ', ')
end

--- Build the LIMIT/OFFSET clause
--- @return string
function QueryBuilder:buildLimitClause()
    local clause = ''
    
    if self.limitValue then
        clause = 'LIMIT ' .. self.limitValue
    end
    
    if self.offsetValue then
        clause = clause .. ' OFFSET ' .. self.offsetValue
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
        local clause = join.type .. ' JOIN ' .. join.table .. ' ON ' .. 
                      join.first .. ' ' .. join.operator .. ' ' .. join.second
        table.insert(clauses, clause)
    end
    
    return table.concat(clauses, ' ')
end

--- Build complete SELECT query
--- @return string, table SQL and parameters
function QueryBuilder:toSql()
    self.params = {} -- Reset params
    
    local sql = 'SELECT ' .. table.concat(self.selectColumns, ', ') .. 
                ' FROM ' .. self.tableName
    
    local joinClause = self:buildJoinClause()
    if joinClause ~= '' then
        sql = sql .. ' ' .. joinClause
    end
    
    local whereClause = self:buildWhereClause()
    if whereClause ~= '' then
        sql = sql .. ' ' .. whereClause
    end
    
    if #self.groupByColumns > 0 then
        sql = sql .. ' GROUP BY ' .. table.concat(self.groupByColumns, ', ')
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
    local originalSelect = self.selectColumns
    self.selectColumns = {'COUNT(*) as count'}
    
    self:first(function(result)
        self.selectColumns = originalSelect
        callback(result and result.count or 0)
    end)
end

--- Count synchronously
--- @return number
function QueryBuilder:countSync()
    local originalSelect = self.selectColumns
    self.selectColumns = {'COUNT(*) as count'}
    
    local result = self:firstSync()
    self.selectColumns = originalSelect
    
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
        table.insert(columns, column)
        table.insert(placeholders, '?')
        table.insert(values, value)
    end
    
    local sql = 'INSERT INTO ' .. self.tableName .. 
                ' (' .. table.concat(columns, ', ') .. ') VALUES (' .. 
                table.concat(placeholders, ', ') .. ')'
    
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
        table.insert(setClauses, column .. ' = ?')
        table.insert(values, value)
    end
    
    local sql = 'UPDATE ' .. self.tableName .. ' SET ' .. table.concat(setClauses, ', ')
    
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
    local sql = 'DELETE FROM ' .. self.tableName
    
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
