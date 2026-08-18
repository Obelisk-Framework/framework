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

--- @param from string
--- @param to string
--- @return string
function PostgresDialect.renameTableSQL(from, to)
    local q = PostgresDialect.quoteIdentifier
    return 'ALTER TABLE ' .. q(from) .. ' RENAME TO ' .. q(to)
end

--- Postgres connectors have no connector-native insertId; RETURNING the
--- primary key is how oblsk_connector's Postgres path recovers it (see
--- oblsk_connector/index.js).
function PostgresDialect.insertReturningClause(primaryKey)
    return ' RETURNING ' .. PostgresDialect.quoteIdentifier(primaryKey)
end

--- Read the live definition of one column from information_schema. Returns
--- nil if the column doesn't exist.
--- @param tableName string
--- @param columnName string
--- @return table|nil { type, length, nullable, default }
function PostgresDialect.introspectColumn(tableName, columnName)
    local sql = 'SELECT data_type, character_maximum_length, is_nullable, column_default ' ..
                'FROM information_schema.columns WHERE ' ..
                PostgresDialect.tableExistsPredicate() ..
                ' AND table_name = $1 AND column_name = $2'
    local rows = Database.query(sql, {tableName, columnName})
    if not rows or not rows[1] then return nil end

    local row = rows[1]
    return {
        type = row.data_type,
        length = row.character_maximum_length and tonumber(row.character_maximum_length) or nil,
        nullable = row.is_nullable == 'YES',
        default = row.column_default,
    }
end

--- Build one ALTER TABLE statement containing one ALTER COLUMN clause per
--- attribute that actually changed. Unlike MySQL, Postgres's ALTER COLUMN
--- clauses are independent — nothing needs to be restated, so this only
--- touches what the migration actually changed.
---
--- Nullability is ALWAYS taken from `col.nullable`: every Blueprint column
--- builder sets a boolean nullable (NOT NULL by default), so the migration
--- author's intent is always explicitly stated and is never inferred from
--- currentInfo — currentInfo.nullable is only consulted to skip emitting a
--- clause when nothing actually changed.
---
--- SCOPE, today: only nullability changes are fully wired end-to-end via
--- Blueprint:change(). The _explicitType/_explicitDefault paths below are
--- supported here, but NO Blueprint method currently sets those flags — a
--- future addition, not a current capability. Use :change() for
--- nullability changes only.
--- @param tableName string
--- @param col table the Blueprint column entry, with .change == true
--- @param currentInfo table introspectColumn()'s return for this column
--- @param q function quoteIdentifier
--- @return string[]
function PostgresDialect.alterModifyColumnStatements(tableName, col, currentInfo, q)
    local clauses = {}
    local prefix = 'ALTER TABLE ' .. q(tableName) .. ' ALTER COLUMN ' .. q(col.name) .. ' '

    if col._explicitType then
        local typeStr = PostgresDialect.columnType(col.kind, col.opts, col.autoIncrement)
        table.insert(clauses, prefix .. 'TYPE ' .. typeStr .. ';')
    end

    -- col.nullable is always a boolean here (every Blueprint column builder
    -- sets it), so there is no nil case to fall back on from currentInfo.
    if col.nullable ~= currentInfo.nullable then
        table.insert(clauses, prefix .. (col.nullable and 'DROP NOT NULL' or 'SET NOT NULL') .. ';')
    end

    if col._explicitDefault then
        if col.default == nil then
            table.insert(clauses, prefix .. 'DROP DEFAULT;')
        else
            table.insert(clauses, prefix .. 'SET DEFAULT ' .. PostgresDialect.formatDefault(col.kind, col.default) .. ';')
        end
    end

    return clauses
end

Dialects.register('postgres', PostgresDialect)

return PostgresDialect
