--- MySQL/MariaDB dialect. See core/server/ORM/Dialects/Init.lua for the
--- interface every dialect implements.
local MySQLDialect = {}

MySQLDialect.quoteIdentifier = Dialects.buildQuoter('`')

function MySQLDialect.columnType(kind, opts, isAutoIncrement)
    opts = opts or {}

    if kind == 'integer' then
        if isAutoIncrement then return 'INT' end
        return opts.unsigned and 'INT UNSIGNED' or 'INT'
    elseif kind == 'bigInteger' then
        return opts.unsigned and 'BIGINT UNSIGNED' or 'BIGINT'
    elseif kind == 'string' then
        return 'VARCHAR(' .. (opts.length or 255) .. ')'
    elseif kind == 'text' then
        return 'TEXT'
    elseif kind == 'json' then
        return 'JSON'
    elseif kind == 'float' then
        if opts.precision then
            return 'FLOAT(' .. opts.precision .. (opts.scale and ',' .. opts.scale or '') .. ')'
        end
        return 'FLOAT'
    elseif kind == 'decimal' then
        return 'DECIMAL(' .. (opts.precision or 8) .. ',' .. (opts.scale or 2) .. ')'
    elseif kind == 'boolean' then
        return 'TINYINT(1)'
    elseif kind == 'date' then
        return 'DATE'
    elseif kind == 'datetime' then
        return 'DATETIME'
    elseif kind == 'timestamp' then
        return 'TIMESTAMP'
    elseif kind == 'enum' then
        return "ENUM('" .. table.concat(opts.values, "','") .. "')"
    end

    error('MySQLDialect: unknown column kind "' .. tostring(kind) .. '"', 2)
end

function MySQLDialect.autoIncrementSuffix()
    return ' AUTO_INCREMENT'
end

function MySQLDialect.formatDefault(kind, value)
    if type(value) == 'string' and value:match('CURRENT_TIMESTAMP') then
        return value
    elseif type(value) == 'number' then
        return tostring(value)
    elseif type(value) == 'boolean' then
        return value and '1' or '0'
    end
    return "'" .. tostring(value) .. "'"
end

function MySQLDialect.tableOptions()
    return ' ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'
end

function MySQLDialect.currentDatabaseExpr()
    return 'DATABASE()'
end

--- WHERE-clause fragment (no leading AND, no trailing space) that scopes an
--- information_schema.TABLES/COLUMNS query to the current database. In
--- MySQL, TABLE_SCHEMA holds the database name.
function MySQLDialect.tableExistsPredicate()
    return 'TABLE_SCHEMA = ' .. MySQLDialect.currentDatabaseExpr()
end

local function quotedColumnList(columns, q)
    local quoted = {}
    for _, col in ipairs(columns) do
        quoted[#quoted + 1] = q(col)
    end
    return table.concat(quoted, ', ')
end

--- MySQL supports non-unique KEY clauses inline, so every index (unique or
--- not) is emitted inside CREATE TABLE; standaloneIndexStatements is always
--- empty.
function MySQLDialect.inlineConstraints(indexes, q)
    local clauses = {}
    for _, idx in ipairs(indexes) do
        local list = quotedColumnList(idx.columns, q)
        if idx.unique then
            clauses[#clauses + 1] = 'UNIQUE KEY ' .. q(idx.name) .. ' (' .. list .. ')'
        else
            clauses[#clauses + 1] = 'KEY ' .. q(idx.name) .. ' (' .. list .. ')'
        end
    end
    return clauses
end

function MySQLDialect.standaloneIndexStatements(_tableName, _indexes, _q)
    return {}
end

function MySQLDialect.alterAddIndexStatements(tableName, idx, q)
    local list = quotedColumnList(idx.columns, q)
    if idx.unique then
        return { 'ALTER TABLE ' .. q(tableName) .. ' ADD UNIQUE INDEX ' .. q(idx.name) .. ' (' .. list .. ');' }
    end
    return { 'ALTER TABLE ' .. q(tableName) .. ' ADD INDEX ' .. q(idx.name) .. ' (' .. list .. ');' }
end

--- Preserves the pre-existing behavior byte-for-byte: CHANGE always retypes
--- to VARCHAR(255) regardless of the column's real type. That's a known
--- limitation of the original implementation (see the comment that used to
--- live on Schema.renameColumn) — not introduced here, and out of scope to
--- fix as part of dialect abstraction.
function MySQLDialect.renameColumnSQL(tableName, from, to)
    local q = MySQLDialect.quoteIdentifier
    return 'ALTER TABLE ' .. q(tableName) .. ' CHANGE ' .. q(from) .. ' ' .. q(to) .. ' VARCHAR(255)'
end

--- MySQL connectors return connector-native insertId; no RETURNING needed.
function MySQLDialect.insertReturningClause(_primaryKey)
    return ''
end

--- Read the live definition of one column from information_schema. Returns
--- nil if the column doesn't exist (caller decides how to handle that).
--- @param tableName string
--- @param columnName string
--- @return table|nil { type, length, columnType, nullable, default }
function MySQLDialect.introspectColumn(tableName, columnName)
    local sql = 'SELECT DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT ' ..
                'FROM information_schema.COLUMNS WHERE ' ..
                MySQLDialect.tableExistsPredicate() ..
                ' AND TABLE_NAME = ? AND COLUMN_NAME = ?'
    local rows = Database.querySync(sql, {tableName, columnName})
    if not rows or not rows[1] then return nil end

    local row = rows[1]
    return {
        type = row.DATA_TYPE,
        length = row.CHARACTER_MAXIMUM_LENGTH and tonumber(row.CHARACTER_MAXIMUM_LENGTH) or nil,
        columnType = row.COLUMN_TYPE,
        nullable = row.IS_NULLABLE == 'YES',
        default = row.COLUMN_DEFAULT,
    }
end

--- Build a single MODIFY COLUMN statement that restates the column's FULL
--- definition — MySQL redefines the entire column in one MODIFY COLUMN, so
--- any attribute not restated here would silently revert to no default /
--- the new type's implicit default.
---
--- Nullability is ALWAYS taken from `col.nullable`: every Blueprint column
--- builder sets a boolean nullable (NOT NULL by default), so the migration
--- author's intent is always explicitly stated and is never inferred from
--- currentInfo. Type and default are different — they're only taken from
--- the column when the caller flagged them explicit (_explicitType /
--- _explicitDefault); otherwise they're restated from currentInfo (the
--- live column) so a migration that only calls :nullable(false):change()
--- doesn't accidentally drop the column's existing type/default.
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
function MySQLDialect.alterModifyColumnStatements(tableName, col, currentInfo, q)
    local typeStr
    if col._explicitType then
        typeStr = MySQLDialect.columnType(col.kind, col.opts, col.autoIncrement)
    else
        -- COLUMN_TYPE is MySQL's full type spec as it would appear in SHOW
        -- COLUMNS (e.g. "decimal(10,2)", "enum('a','b')", "int(10) unsigned"),
        -- complete for every column kind — not just strings. Use it verbatim;
        -- MySQL type keywords are case-insensitive so no case transform needed.
        typeStr = currentInfo.columnType
    end

    local def = q(col.name) .. ' ' .. typeStr
    if not col.nullable then
        def = def .. ' NOT NULL'
    end

    if col._explicitDefault then
        -- A raw Lua value straight from Blueprint:default(...) — needs
        -- dialect formatting (quoting/coercion) to become a SQL literal.
        if col.default ~= nil then
            def = def .. ' DEFAULT ' .. MySQLDialect.formatDefault(col.kind, col.default)
        end
    elseif currentInfo.default ~= nil then
        -- Restating the live column's default: COLUMN_DEFAULT is ALREADY a
        -- SQL literal/expression as the server reports it (an already-quoted
        -- string like 'abc', a bare number, or an expression like
        -- current_timestamp()). Running it back through formatDefault would
        -- double-process it (DEFAULT ''abc'', DEFAULT 'current_timestamp()'),
        -- so it is emitted verbatim.
        --
        -- MariaDB reports the 4-character string "NULL" for "this column has
        -- no default" (and also for an explicit DEFAULT NULL, which is
        -- semantically identical for a nullable column). Emit no DEFAULT
        -- clause at all in that case; a NOT NULL column must never get
        -- DEFAULT NULL, and for a nullable column the omission is equivalent.
        if currentInfo.default ~= 'NULL' then
            def = def .. ' DEFAULT ' .. tostring(currentInfo.default)
        end
    end

    return { 'ALTER TABLE ' .. q(tableName) .. ' MODIFY COLUMN ' .. def .. ';' }
end

Dialects.register('mysql', MySQLDialect)

return MySQLDialect
