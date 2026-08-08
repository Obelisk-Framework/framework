--- Postgres dialect. See core/server/ORM/Dialects/Init.lua for the interface
--- every dialect implements.
---
--- PLACEHOLDER: this is a minimal stub, not the full Postgres implementation.
--- `tests/orm_spec.lua` (committed in Task 1) unconditionally dofiles this
--- path and Task 2's dialect-wiring test needs `Dialects.resolve('postgres')`
--- to work, so a stub is required to unblock the suite before Task 2 is
--- done. Only `quoteIdentifier` is exercised/verified before Task 4, which
--- is responsible for fleshing this out into a fully correct, tested
--- Postgres dialect (column types, index DDL, RETURNING, etc).
local PostgresDialect = {}

PostgresDialect.quoteIdentifier = Dialects.buildQuoter('"')

function PostgresDialect.columnType(kind, opts, isAutoIncrement)
    opts = opts or {}

    if kind == 'integer' then
        if isAutoIncrement then return 'SERIAL' end
        return 'INTEGER'
    elseif kind == 'bigInteger' then
        if isAutoIncrement then return 'BIGSERIAL' end
        return 'BIGINT'
    elseif kind == 'string' then
        return 'VARCHAR(' .. (opts.length or 255) .. ')'
    elseif kind == 'text' then
        return 'TEXT'
    elseif kind == 'json' then
        return 'JSONB'
    elseif kind == 'float' then
        return 'REAL'
    elseif kind == 'decimal' then
        return 'NUMERIC(' .. (opts.precision or 8) .. ',' .. (opts.scale or 2) .. ')'
    elseif kind == 'boolean' then
        return 'BOOLEAN'
    elseif kind == 'date' then
        return 'DATE'
    elseif kind == 'datetime' then
        return 'TIMESTAMP'
    elseif kind == 'timestamp' then
        return 'TIMESTAMP'
    elseif kind == 'enum' then
        return 'TEXT'
    end

    error('PostgresDialect: unknown column kind "' .. tostring(kind) .. '"', 2)
end

function PostgresDialect.autoIncrementSuffix()
    return ''
end

function PostgresDialect.formatDefault(kind, value)
    if type(value) == 'string' and value:match('CURRENT_TIMESTAMP') then
        return value
    elseif type(value) == 'number' then
        return tostring(value)
    elseif type(value) == 'boolean' then
        return value and 'TRUE' or 'FALSE'
    end
    return "'" .. tostring(value) .. "'"
end

function PostgresDialect.tableOptions()
    return ''
end

function PostgresDialect.currentDatabaseExpr()
    return 'CURRENT_DATABASE()'
end

local function quotedColumnList(columns, q)
    local quoted = {}
    for _, col in ipairs(columns) do
        quoted[#quoted + 1] = q(col)
    end
    return table.concat(quoted, ', ')
end

--- Postgres has no inline non-unique KEY syntax; unique constraints are
--- emitted inline, everything else goes through standaloneIndexStatements.
function PostgresDialect.inlineConstraints(indexes, q)
    local clauses = {}
    for _, idx in ipairs(indexes) do
        if idx.unique then
            local list = quotedColumnList(idx.columns, q)
            clauses[#clauses + 1] = 'CONSTRAINT ' .. q(idx.name) .. ' UNIQUE (' .. list .. ')'
        end
    end
    return clauses
end

function PostgresDialect.standaloneIndexStatements(tableName, indexes, q)
    local statements = {}
    for _, idx in ipairs(indexes) do
        if not idx.unique then
            local list = quotedColumnList(idx.columns, q)
            statements[#statements + 1] = 'CREATE INDEX ' .. q(idx.name) .. ' ON ' .. q(tableName) .. ' (' .. list .. ');'
        end
    end
    return statements
end

function PostgresDialect.alterAddIndexStatements(tableName, idx, q)
    local list = quotedColumnList(idx.columns, q)
    if idx.unique then
        return { 'ALTER TABLE ' .. q(tableName) .. ' ADD CONSTRAINT ' .. q(idx.name) .. ' UNIQUE (' .. list .. ');' }
    end
    return { 'CREATE INDEX ' .. q(idx.name) .. ' ON ' .. q(tableName) .. ' (' .. list .. ');' }
end

function PostgresDialect.renameColumnSQL(tableName, from, to)
    local q = PostgresDialect.quoteIdentifier
    return 'ALTER TABLE ' .. q(tableName) .. ' RENAME COLUMN ' .. q(from) .. ' TO ' .. q(to)
end

--- Postgres connectors don't return a connector-native insertId; RETURNING
--- is required to recover it.
function PostgresDialect.insertReturningClause(primaryKey)
    return ' RETURNING ' .. PostgresDialect.quoteIdentifier(primaryKey)
end

Dialects.register('postgres', PostgresDialect)

return PostgresDialect
