--- Dialect registry. Each dialect (MySQL.lua, Postgres.lua, ...) implements:
---   quoteIdentifier(identifier) -> string
---   columnType(kind, opts, isAutoIncrement) -> string
---   autoIncrementSuffix() -> string
---   formatDefault(kind, value) -> string
---   tableOptions() -> string
---   currentDatabaseExpr() -> string
---   tableExistsPredicate() -> string (WHERE-clause fragment scoping an
---     information_schema.TABLES/COLUMNS query to the current database)
---   inlineConstraints(indexes, q) -> string[]
---   standaloneIndexStatements(tableName, indexes, q) -> string[]
---   alterAddIndexStatements(tableName, idx, q) -> string[]
---   renameColumnSQL(tableName, from, to) -> string
---   insertReturningClause(primaryKey) -> string
--- `q` passed into the index helpers is always that dialect's own quoteIdentifier.
Dialects = {}

local registry = {}

--- Register a dialect under a driver name (e.g. 'mysql', 'postgres').
function Dialects.register(name, dialect)
    registry[name] = dialect
end

--- Resolve a driver name to its dialect table. Errors on unknown drivers —
--- there is no silent fallback, matching Database.lua's fail-fast philosophy.
--- @param name string
--- @return table dialect
function Dialects.resolve(name)
    local dialect = registry[name]
    if not dialect then
        local known = {}
        for k in pairs(registry) do known[#known + 1] = k end
        error('Dialects: unknown driver "' .. tostring(name) .. '" (known: ' ..
            table.concat(known, ', ') .. ')', 2)
    end
    return dialect
end

--- Shared identifier quoting: splits on '.', validates each segment against
--- [A-Za-z0-9_$]+ (or '*'), wraps each in the given quote character. This is
--- the sole defense against identifier-based SQL injection, so every dialect
--- routes quoteIdentifier through this rather than rolling its own check.
--- @param quoteChar string single character used to wrap each segment
--- @return fun(identifier: string): string
function Dialects.buildQuoter(quoteChar)
    return function(identifier)
        if type(identifier) ~= 'string' or identifier == '' then
            error('Dialect: invalid identifier: ' .. tostring(identifier), 2)
        end

        if identifier == '*' then
            return '*'
        end

        local parts = {}
        for part in (identifier .. '.'):gmatch('([^%.]*)%.') do
            if part == '*' then
                table.insert(parts, '*')
            elseif part:match('^[%w_$]+$') then
                table.insert(parts, quoteChar .. part .. quoteChar)
            else
                error('Dialect: illegal identifier "' .. identifier .. '"', 2)
            end
        end

        return table.concat(parts, '.')
    end
end

return Dialects
