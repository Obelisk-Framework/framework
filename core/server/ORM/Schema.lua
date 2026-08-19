--- Schema Builder - Laravel-inspired database schema management
Schema = {}

--- Blueprint class for defining table structure
local Blueprint = {}
Blueprint.__index = Blueprint

function Blueprint.new(tableName)
    local self = setmetatable({}, Blueprint)
    self.tableName = tableName
    self.columns = {}
    self.indexes = {}
    self.foreignKeys = {}
    return self
end

--- Add an auto-incrementing integer primary key
function Blueprint:id(name)
    name = name or 'id'
    table.insert(self.columns, {
        name = name,
        kind = 'integer',
        opts = {},
        autoIncrement = true,
        primary = true,
        nullable = false
    })
    return self
end

--- Add a string column
function Blueprint:string(name, length)
    table.insert(self.columns, {
        name = name,
        kind = 'string',
        opts = { length = length or 255 },
        nullable = false
    })
    return self
end

--- Add a text column
function Blueprint:text(name)
    table.insert(self.columns, { name = name, kind = 'text', opts = {}, nullable = false })
    return self
end

--- Add a JSON column
function Blueprint:json(name)
    table.insert(self.columns, { name = name, kind = 'json', opts = {}, nullable = false })
    return self
end

--- Add an integer column
function Blueprint:integer(name)
    table.insert(self.columns, { name = name, kind = 'integer', opts = {}, nullable = false })
    return self
end

--- Add a big integer column
function Blueprint:bigInteger(name)
    table.insert(self.columns, { name = name, kind = 'bigInteger', opts = {}, nullable = false })
    return self
end

--- Add an unsigned integer column
function Blueprint:unsignedInteger(name)
    table.insert(self.columns, {
        name = name, kind = 'integer', opts = { unsigned = true }, nullable = false
    })
    return self
end

--- Add a float column
function Blueprint:float(name, precision, scale)
    table.insert(self.columns, {
        name = name, kind = 'float', opts = { precision = precision, scale = scale }, nullable = false
    })
    return self
end

--- Add a decimal column
function Blueprint:decimal(name, precision, scale)
    table.insert(self.columns, {
        name = name,
        kind = 'decimal',
        opts = { precision = precision or 8, scale = scale or 2 },
        nullable = false
    })
    return self
end

--- Add a boolean column
function Blueprint:boolean(name)
    table.insert(self.columns, {
        name = name, kind = 'boolean', opts = {}, nullable = false, default = 0
    })
    return self
end

--- Add a date column
function Blueprint:date(name)
    table.insert(self.columns, { name = name, kind = 'date', opts = {}, nullable = false })
    return self
end

--- Add a datetime column
function Blueprint:datetime(name)
    table.insert(self.columns, { name = name, kind = 'datetime', opts = {}, nullable = false })
    return self
end

--- Add a timestamp column
function Blueprint:timestamp(name)
    table.insert(self.columns, { name = name, kind = 'timestamp', opts = {}, nullable = false })
    return self
end

--- Add timestamps (created_at, updated_at). Both default to CURRENT_TIMESTAMP
--- at the DB level; updated_at is NOT auto-refreshed by the database (no
--- portable equivalent of MySQL's ON UPDATE CURRENT_TIMESTAMP in Postgres) —
--- BaseModel already sets it on every save via Database.now(), so no DB-level
--- trigger is needed.
function Blueprint:timestamps()
    table.insert(self.columns, {
        name = 'created_at', kind = 'timestamp', opts = {}, nullable = false, default = 'CURRENT_TIMESTAMP'
    })
    table.insert(self.columns, {
        name = 'updated_at', kind = 'timestamp', opts = {}, nullable = false, default = 'CURRENT_TIMESTAMP'
    })
    return self
end

--- Add an enum column
function Blueprint:enum(name, values)
    table.insert(self.columns, { name = name, kind = 'enum', opts = { values = values }, nullable = false })
    return self
end

--- Set the nullability of the last column. `value` defaults to `true`, so
--- `:nullable()` reads naturally for "this column is optional". Pass
--- `false` to require it: `:nullable(false)`.
function Blueprint:nullable(value)
    if value == nil then value = true end
    if #self.columns > 0 then
        self.columns[#self.columns].nullable = value
    end
    return self
end

--- Mark the last-defined column as an alteration of an existing column
--- rather than a new one, for use inside Schema.table(...). Only meaningful
--- there — Schema.create() ignores the flag since every column is new.
---
--- SCOPE, today: only NULLABILITY changes are fully wired end-to-end, i.e.
---     table:string('nickname'):nullable():change()
--- The dialects' alterModifyColumnStatements() also support changing a
--- column's type/default via the internal `_explicitType`/`_explicitDefault`
--- flags, but no Blueprint method sets those flags yet — that's a future
--- addition, not a current capability. Until it exists, a :change() column's
--- type and default are restated from the live column as introspected, and
--- :change() should be used for nullability changes only.
function Blueprint:change()
    if #self.columns > 0 then
        self.columns[#self.columns].change = true
    end
    return self
end

--- Set default value for last column
function Blueprint:default(value)
    if #self.columns > 0 then
        self.columns[#self.columns].default = value
    end
    return self
end

--- Make the last column unsigned (integer/bigInteger only; Postgres has no
--- unsigned integer types, so this is a no-op under that dialect).
function Blueprint:unsigned()
    if #self.columns > 0 then
        local col = self.columns[#self.columns]
        if col.kind == 'integer' or col.kind == 'bigInteger' then
            col.opts.unsigned = true
        end
    end
    return self
end

--- Add an index
function Blueprint:index(columns, name)
    -- If no columns specified, use the last column defined
    if columns == nil and #self.columns > 0 then
        columns = {self.columns[#self.columns].name}
    elseif type(columns) == 'string' then
        columns = {columns}
    end

    -- Ensure columns is a table before using table.concat
    if columns and type(columns) == 'table' then
        name = name or (self.tableName .. '_' .. table.concat(columns, '_') .. '_index')
        table.insert(self.indexes, {
            name = name,
            columns = columns,
            unique = false
        })
    end

    return self
end

--- Add a unique index
function Blueprint:unique(columns, name)
    -- If no columns specified, use the last column defined
    if columns == nil and #self.columns > 0 then
        columns = {self.columns[#self.columns].name}
    elseif type(columns) == 'string' then
        columns = {columns}
    end
    
    -- Ensure columns is a table before using table.concat
    if columns and type(columns) == 'table' then
        name = name or (self.tableName .. '_' .. table.concat(columns, '_') .. '_unique')
        table.insert(self.indexes, {
            name = name,
            columns = columns,
            unique = true
        })
    end
    
    return self
end

--- Add a foreign key.
---
--- Returns a chainable builder used as
--- `t:foreign('a_id'):references('id'):on('as'):onDelete('CASCADE')`. Every
--- link is defined with method (`:`) syntax because every call site in the
--- codebase chains with `:` — defining them as plain closures taking one
--- argument silently bound the chain table itself as the argument (a colon
--- call passes the receiver first), so `references`/`on` ended up holding a
--- table instead of a name and the emitted SQL was unusable.
function Blueprint:foreign(column)
    local blueprint = self
    local fk = {
        column = column,
        references = nil,
        on = nil,
        onDelete = 'RESTRICT',
        onUpdate = 'RESTRICT'
    }

    local registered = false
    --- Add the key to the blueprint exactly once, however many terminal
    --- methods the caller chains. Also makes it the target of the
    --- Blueprint-level `:onDelete()`/`:onUpdate()` setters, so
    --- `...:onDelete('CASCADE'):onUpdate('CASCADE')` works (the first call
    --- returns the blueprint, not this builder).
    local function register()
        if not registered then
            registered = true
            table.insert(blueprint.foreignKeys, fk)
        end
        blueprint._lastForeignKey = fk
        return blueprint
    end

    local terminal = {}

    --- Register the key with the default RESTRICT actions. Only needed when
    --- neither `:onDelete()` nor `:onUpdate()` is called, since those
    --- register it themselves.
    function terminal:getBlueprint()
        return register()
    end

    function terminal:onDelete(action)
        fk.onDelete = action
        return register()
    end

    function terminal:onUpdate(action)
        fk.onUpdate = action
        return register()
    end

    local onStep = {}
    function onStep:on(refTable)
        fk.on = refTable
        return terminal
    end

    local referencesStep = {}
    function referencesStep:references(refColumn)
        fk.references = refColumn
        return onStep
    end

    return referencesStep
end

--- Guess the referenced table name from a foreign key column by Laravel
--- convention: strip a trailing `_id`, then pluralize (`garage_id` ->
--- `garages`, `base_vehicle_id` -> `base_vehicles`).
local function guessForeignTable(column)
    local base = column:gsub('_id$', '')
    if base:match('[^aeiou]y$') then
        return base:sub(1, -2) .. 'ies'
    elseif base:match('s$') or base:match('x$') or base:match('ch$') or base:match('sh$') then
        return base .. 'es'
    end
    return base .. 's'
end

--- Add a foreign key column. Pair with `:constrained()` to also add the FK
--- constraint: `t:foreignId('garage_id'):constrained()`.
---
--- The emitted type MUST match exactly what `:id()` emits for the referenced
--- primary key — InnoDB rejects a foreign key whose column type or
--- signedness differs from the referenced column (MySQL error 3780).
--- `:id()` goes through `columnType('integer', opts, true)`, whose
--- auto-increment branch returns a plain `INT` and ignores `opts.unsigned`
--- entirely. So this must be `integer` with NO `unsigned` flag: `BIGINT
--- UNSIGNED` or even `INT UNSIGNED` referencing `INT` would fail to create.
function Blueprint:foreignId(name)
    table.insert(self.columns, {
        name = name, kind = 'integer', opts = {}, nullable = false
    })
    self._lastForeignIdColumn = name
    return self
end

--- Add a foreign key constraint for the column just added by `:foreignId()`.
--- @param refTable string|nil defaults to the pluralized column (minus `_id`)
--- @param refColumn string|nil defaults to `'id'`
function Blueprint:constrained(refTable, refColumn)
    local column = self._lastForeignIdColumn
    if not column then
        error('constrained() must immediately follow foreignId()')
    end

    local fk = {
        column = column,
        references = refColumn or 'id',
        on = refTable or guessForeignTable(column),
        onDelete = 'RESTRICT',
        onUpdate = 'RESTRICT'
    }
    table.insert(self.foreignKeys, fk)
    self._lastForeignKey = fk
    return self
end

--- Set the ON DELETE action of the foreign key just added by `:constrained()`
--- (or `:foreign():references():on()`, which already defaults to RESTRICT).
function Blueprint:onDelete(action)
    if self._lastForeignKey then
        self._lastForeignKey.onDelete = action
    end
    return self
end

--- Set the ON UPDATE action of the foreign key just added by `:constrained()`.
function Blueprint:onUpdate(action)
    if self._lastForeignKey then
        self._lastForeignKey.onUpdate = action
    end
    return self
end

--- Build the CREATE TABLE statement(s). Returns a list because Postgres
--- can't express non-unique indexes inline (see Dialects/Postgres.lua) — the
--- first element is always the CREATE TABLE itself; any further elements are
--- standalone CREATE INDEX statements that must run after it.
--- @return string[] statements
function Blueprint:toSql()
    local dialect = Database.dialect
    local q = dialect.quoteIdentifier

    local sql = 'CREATE TABLE IF NOT EXISTS ' .. q(self.tableName) .. ' (\n'

    local columnDefs = {}
    for _, col in ipairs(self.columns) do
        local typeStr = dialect.columnType(col.kind, col.opts, col.autoIncrement)
        local def = '  ' .. q(col.name) .. ' ' .. typeStr

        if not col.nullable then
            def = def .. ' NOT NULL'
        end

        if col.autoIncrement then
            def = def .. dialect.autoIncrementSuffix()
        end

        if col.default ~= nil then
            def = def .. ' DEFAULT ' .. dialect.formatDefault(col.kind, col.default)
        end

        table.insert(columnDefs, def)
    end

    sql = sql .. table.concat(columnDefs, ',\n')

    for _, col in ipairs(self.columns) do
        if col.primary then
            sql = sql .. ',\n  PRIMARY KEY (' .. q(col.name) .. ')'
            break
        end
    end

    for _, clause in ipairs(dialect.inlineConstraints(self.indexes, q)) do
        sql = sql .. ',\n  ' .. clause
    end

    for _, fk in ipairs(self.foreignKeys) do
        sql = sql .. ',\n  FOREIGN KEY (' .. q(fk.column) .. ') REFERENCES ' ..
              q(fk.on) .. '(' .. q(fk.references) .. ') ON DELETE ' .. fk.onDelete ..
              ' ON UPDATE ' .. fk.onUpdate
    end

    sql = sql .. '\n)' .. dialect.tableOptions() .. ';'

    local statements = { sql }
    for _, stmt in ipairs(dialect.standaloneIndexStatements(self.tableName, self.indexes, q)) do
        table.insert(statements, stmt)
    end

    return statements
end

--- Helper to build a quoted column list for indexes
function Blueprint:buildColumnList(columns)
    local dialect = Database.dialect
    local quoted = {}
    for _, col in ipairs(columns) do
        table.insert(quoted, dialect.quoteIdentifier(col))
    end
    return table.concat(quoted, ', ')
end

--- Schema static methods

--- Create a new table
function Schema.create(tableName, callback)
    local blueprint = Blueprint.new(tableName)
    callback(blueprint)
    local statements = blueprint:toSql()

    print('[Schema] Creating table: ' .. tableName)
    local result
    for _, sql in ipairs(statements) do
        print('[Schema] SQL: ' .. sql)
        result = Database.query(sql, {})
    end
    print('[Schema] Result: ' .. json.encode(result))
    return result
end

--- Drop a table
function Schema.drop(tableName)
    local sql = 'DROP TABLE IF EXISTS ' .. Database.dialect.quoteIdentifier(tableName)
    print('[Schema] Dropping table: ' .. tableName)
    return Database.query(sql, {})
end

--- Check if a table exists
function Schema.hasTable(tableName)
    local sql = 'SELECT COUNT(*) as count FROM information_schema.TABLES WHERE ' ..
                Database.dialect.tableExistsPredicate() .. ' AND TABLE_NAME = ?'
    local result = Database.query(sql, {tableName})
    return result and result[1] and (tonumber(result[1].count) or 0) > 0
end

--- Modify an existing table
function Schema.table(tableName, callback)
    local dialect = Database.dialect
    local q = dialect.quoteIdentifier
    local blueprint = Blueprint.new(tableName)
    blueprint.isAltering = true
    callback(blueprint)

    local statements = {}

    for _, col in ipairs(blueprint.columns) do
        if col.change then
            local currentInfo = dialect.introspectColumn(tableName, col.name)
            if not currentInfo then
                error('Schema.table: cannot :change() column "' .. col.name ..
                      '" on table "' .. tableName .. '" — it does not exist', 2)
            end
            for _, stmt in ipairs(dialect.alterModifyColumnStatements(tableName, col, currentInfo, q)) do
                table.insert(statements, stmt)
            end
        else
            local typeStr = dialect.columnType(col.kind, col.opts, col.autoIncrement)
            local def = q(col.name) .. ' ' .. typeStr

            if not col.nullable then
                def = def .. ' NOT NULL'
            end

            if col.default ~= nil then
                def = def .. ' DEFAULT ' .. dialect.formatDefault(col.kind, col.default)
            end

            table.insert(statements, 'ALTER TABLE ' .. q(tableName) .. ' ADD COLUMN ' .. def .. ';')
        end
    end

    for _, idx in ipairs(blueprint.indexes) do
        for _, stmt in ipairs(dialect.alterAddIndexStatements(tableName, idx, q)) do
            table.insert(statements, stmt)
        end
    end

    for _, fk in ipairs(blueprint.foreignKeys) do
        local constraintName = tableName .. '_' .. fk.column .. '_foreign'
        table.insert(statements,
            'ALTER TABLE ' .. q(tableName) .. ' ADD CONSTRAINT ' .. q(constraintName) ..
            ' FOREIGN KEY (' .. q(fk.column) .. ') REFERENCES ' .. q(fk.on) .. '(' .. q(fk.references) .. ')' ..
            ' ON DELETE ' .. fk.onDelete .. ' ON UPDATE ' .. fk.onUpdate .. ';')
    end

    for _, sql in ipairs(statements) do
        Database.query(sql, {})
    end
end

--- Check if a column exists
function Schema.hasColumn(tableName, columnName)
    local sql = 'SELECT COUNT(*) as count FROM information_schema.COLUMNS WHERE ' ..
                Database.dialect.tableExistsPredicate() .. ' AND TABLE_NAME = ? AND COLUMN_NAME = ?'
    local result = Database.query(sql, {tableName, columnName})
    return result and result[1] and (tonumber(result[1].count) or 0) > 0
end

--- Drop a column
function Schema.dropColumn(tableName, columnName)
    local q = Database.dialect.quoteIdentifier
    local sql = 'ALTER TABLE ' .. q(tableName) .. ' DROP COLUMN ' .. q(columnName)
    return Database.query(sql, {})
end

--- Drop a foreign key constraint (name derived by convention: table_column_foreign)
function Schema.dropForeign(tableName, columnName)
    local q = Database.dialect.quoteIdentifier
    local constraintName = tableName .. '_' .. columnName .. '_foreign'
    local sql = 'ALTER TABLE ' .. q(tableName) .. ' DROP FOREIGN KEY ' .. q(constraintName)
    return Database.query(sql, {})
end

--- Drop a unique index (name derived by convention: table_column_unique)
function Schema.dropUnique(tableName, columnName)
    local q = Database.dialect.quoteIdentifier
    local indexName = tableName .. '_' .. columnName .. '_unique'
    local sql = 'ALTER TABLE ' .. q(tableName) .. ' DROP INDEX ' .. q(indexName)
    return Database.query(sql, {})
end

--- Rename a column
function Schema.renameColumn(tableName, from, to)
    local sql = Database.dialect.renameColumnSQL(tableName, from, to)
    return Database.query(sql, {})
end

--- Rename a table
function Schema.renameTable(from, to)
    local sql = Database.dialect.renameTableSQL(from, to)
    return Database.query(sql, {})
end

-- Exposed for unit tests that need to construct/inspect a Blueprint directly
-- (e.g. verifying :change() without driving a full Schema.table() call).
Schema.Blueprint = Blueprint

return Schema
