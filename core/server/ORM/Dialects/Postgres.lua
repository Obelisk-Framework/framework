--- PostgreSQL dialect. See core/server/ORM/Dialects/Init.lua for the
--- interface every dialect implements.
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
        if opts.precision then
            if opts.scale then
                -- Postgres FLOAT takes no scale argument; a scale means the
                -- caller wants fixed-point behavior, so map to NUMERIC.
                return 'NUMERIC(' .. opts.precision .. ',' .. opts.scale .. ')'
            end
            return 'FLOAT(' .. opts.precision .. ')'
        end
        return 'DOUBLE PRECISION'
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
        -- No inline enum type in Postgres (would need CREATE TYPE); values
        -- are not DB-enforced under this dialect.
        return 'VARCHAR(255)'
    end

    error('PostgresDialect: unknown column kind "' .. tostring(kind) .. '"', 2)
end

function PostgresDialect.autoIncrementSuffix()
    -- SERIAL/BIGSERIAL already imply auto-increment; no separate keyword.
    return ''
end

function PostgresDialect.formatDefault(kind, value)
    if type(value) == 'string' and value:match('CURRENT_TIMESTAMP') then
        return value
    elseif kind == 'boolean' then
        return (value == 1 or value == true) and 'TRUE' or 'FALSE'
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
    return 'current_database()'
end

--- WHERE-clause fragment (no leading AND, no trailing space) that scopes an
--- information_schema.tables/columns query to the current database. In
--- Postgres, table_schema is the namespace (typically 'public'), NOT the
--- database name — the database lives in table_catalog, so both must be
--- checked.
function PostgresDialect.tableExistsPredicate()
    return 'table_catalog = current_database() AND table_schema = current_schema()'
end

local function quotedColumnList(columns, q)
    local quoted = {}
    for _, col in ipairs(columns) do
        quoted[#quoted + 1] = q(col)
    end
    return table.concat(quoted, ', ')
end

--- Only UNIQUE constraints can be inline in Postgres' CREATE TABLE; plain
--- indexes must be separate CREATE INDEX statements (see
--- standaloneIndexStatements).
function PostgresDialect.inlineConstraints(indexes, q)
    local clauses = {}
    for _, idx in ipairs(indexes) do
        if idx.unique then
            clauses[#clauses + 1] = 'CONSTRAINT ' .. q(idx.name) .. ' UNIQUE (' ..
                quotedColumnList(idx.columns, q) .. ')'
        end
    end
    return clauses
end

function PostgresDialect.standaloneIndexStatements(tableName, indexes, q)
    local statements = {}
    for _, idx in ipairs(indexes) do
        if not idx.unique then
            statements[#statements + 1] = 'CREATE INDEX IF NOT EXISTS ' .. q(idx.name) .. ' ON ' .. q(tableName) ..
                ' (' .. quotedColumnList(idx.columns, q) .. ');'
        end
    end
    return statements
end

function PostgresDialect.alterAddIndexStatements(tableName, idx, q)
    local list = quotedColumnList(idx.columns, q)
    if idx.unique then
        return { 'ALTER TABLE ' .. q(tableName) .. ' ADD CONSTRAINT ' .. q(idx.name) .. ' UNIQUE (' .. list .. ');' }
    end
    return { 'CREATE INDEX IF NOT EXISTS ' .. q(idx.name) .. ' ON ' .. q(tableName) .. ' (' .. list .. ');' }
end

function PostgresDialect.renameColumnSQL(tableName, from, to)
    local q = PostgresDialect.quoteIdentifier
    return 'ALTER TABLE ' .. q(tableName) .. ' RENAME COLUMN ' .. q(from) .. ' TO ' .. q(to)
end

--- Postgres connectors have no connector-native insertId; RETURNING the
--- primary key is how oblsk_connector's Postgres path recovers it (see
--- oblsk_connector/index.js).
function PostgresDialect.insertReturningClause(primaryKey)
    return ' RETURNING ' .. PostgresDialect.quoteIdentifier(primaryKey)
end

--- Introspect an existing column's current type/nullability/default so
--- Schema.table()'s :change() path can diff against it. Implemented in a
--- later task; calling it before then is a programming error, not a
--- reachable runtime state (nothing wires :change() into a real dialect
--- call yet).
function PostgresDialect.introspectColumn(_tableName, _columnName)
    error('PostgresDialect.introspectColumn: not implemented', 2)
end

--- Build the ALTER TABLE ... TYPE/SET NOT NULL/SET DEFAULT statement(s) for a
--- :change()-marked column. Implemented in a later task.
function PostgresDialect.alterModifyColumnStatements(_tableName, _col, _currentInfo, _q)
    error('PostgresDialect.alterModifyColumnStatements: not implemented', 2)
end

Dialects.register('postgres', PostgresDialect)

return PostgresDialect
