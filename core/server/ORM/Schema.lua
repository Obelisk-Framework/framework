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
        type = 'INT',
        autoIncrement = true,
        primary = true,
        nullable = false
    })
    return self
end

--- Add a string column
function Blueprint:string(name, length)
    length = length or 255
    table.insert(self.columns, {
        name = name,
        type = 'VARCHAR(' .. length .. ')',
        nullable = true
    })
    return self
end

--- Add a text column
function Blueprint:text(name)
    table.insert(self.columns, {
        name = name,
        type = 'TEXT',
        nullable = true
    })
    return self
end

--- Add a JSON column
function Blueprint:json(name)
    table.insert(self.columns, {
        name = name,
        type = 'JSON',
        nullable = true
    })
    return self
end

--- Add an integer column
function Blueprint:integer(name)
    table.insert(self.columns, {
        name = name,
        type = 'INT',
        nullable = true
    })
    return self
end

--- Add a big integer column
function Blueprint:bigInteger(name)
    table.insert(self.columns, {
        name = name,
        type = 'BIGINT',
        nullable = true
    })
    return self
end

--- Add an unsigned integer column
function Blueprint:unsignedInteger(name)
    table.insert(self.columns, {
        name = name,
        type = 'INT UNSIGNED',
        nullable = true
    })
    return self
end

--- Add a float column
function Blueprint:float(name, precision, scale)
    local typeDef = 'FLOAT'
    if precision then
        typeDef = 'FLOAT(' .. precision .. (scale and ',' .. scale or '') .. ')'
    end
    table.insert(self.columns, {
        name = name,
        type = typeDef,
        nullable = true
    })
    return self
end

--- Add a decimal column
function Blueprint:decimal(name, precision, scale)
    precision = precision or 8
    scale = scale or 2
    table.insert(self.columns, {
        name = name,
        type = 'DECIMAL(' .. precision .. ',' .. scale .. ')',
        nullable = true
    })
    return self
end

--- Add a boolean column
function Blueprint:boolean(name)
    table.insert(self.columns, {
        name = name,
        type = 'TINYINT(1)',
        nullable = true,
        default = 0
    })
    return self
end

--- Add a date column
function Blueprint:date(name)
    table.insert(self.columns, {
        name = name,
        type = 'DATE',
        nullable = true
    })
    return self
end

--- Add a datetime column
function Blueprint:datetime(name)
    table.insert(self.columns, {
        name = name,
        type = 'DATETIME',
        nullable = true
    })
    return self
end

--- Add a timestamp column
function Blueprint:timestamp(name)
    table.insert(self.columns, {
        name = name,
        type = 'TIMESTAMP',
        nullable = true
    })
    return self
end

--- Add timestamps (created_at, updated_at)
function Blueprint:timestamps()
    table.insert(self.columns, {
        name = 'created_at',
        type = 'TIMESTAMP',
        nullable = true,
        default = 'CURRENT_TIMESTAMP'
    })
    table.insert(self.columns, {
        name = 'updated_at',
        type = 'TIMESTAMP',
        nullable = true,
        default = 'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'
    })
    return self
end

--- Add an enum column
function Blueprint:enum(name, values)
    local valueStr = "'" .. table.concat(values, "','") .. "'"
    table.insert(self.columns, {
        name = name,
        type = 'ENUM(' .. valueStr .. ')',
        nullable = true
    })
    return self
end

--- Make the last column nullable
function Blueprint:nullable()
    if #self.columns > 0 then
        self.columns[#self.columns].nullable = true
    end
    return self
end

--- Make the last column not nullable
function Blueprint:notNullable()
    if #self.columns > 0 then
        self.columns[#self.columns].nullable = false
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

--- Make the last column unsigned
function Blueprint:unsigned()
    if #self.columns > 0 then
        local col = self.columns[#self.columns]
        if col.type:match('INT') then
            col.type = col.type .. ' UNSIGNED'
        end
    end
    return self
end

--- Add an index
function Blueprint:index(columns, name)
    if type(columns) == 'string' then
        columns = {columns}
    end
    name = name or (self.tableName .. '_' .. table.concat(columns, '_') .. '_index')
    table.insert(self.indexes, {
        name = name,
        columns = columns,
        unique = false
    })
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

--- Add a foreign key
function Blueprint:foreign(column)
    local fk = {
        column = column,
        references = nil,
        on = nil,
        onDelete = 'RESTRICT',
        onUpdate = 'RESTRICT'
    }
    
    -- Return a chainable foreign key builder
    return {
        references = function(refColumn)
            fk.references = refColumn
            return {
                on = function(refTable)
                    fk.on = refTable
                    
                    return {
                        onDelete = function(action)
                            fk.onDelete = action
                            table.insert(self.foreignKeys, fk)
                            return self
                        end,
                        onUpdate = function(action)
                            fk.onUpdate = action
                            table.insert(self.foreignKeys, fk)
                            return self
                        end,
                        getBlueprint = function()
                            table.insert(self.foreignKeys, fk)
                            return self
                        end
                    }
                end
            }
        end
    }
end

--- Build the CREATE TABLE SQL
function Blueprint:toSql()
    local sql = 'CREATE TABLE IF NOT EXISTS `' .. self.tableName .. '` (\n'
    
    -- Add columns
    local columnDefs = {}
    for _, col in ipairs(self.columns) do
        local def = '  `' .. col.name .. '` ' .. col.type
        
        if not col.nullable then
            def = def .. ' NOT NULL'
        end
        
        if col.autoIncrement then
            def = def .. ' AUTO_INCREMENT'
        end
        
        if col.default ~= nil then
            if type(col.default) == 'string' and col.default:match('CURRENT_TIMESTAMP') then
                def = def .. ' DEFAULT ' .. col.default
            elseif type(col.default) == 'number' then
                def = def .. ' DEFAULT ' .. col.default
            else
                def = def .. ' DEFAULT \'' .. tostring(col.default) .. '\''
            end
        end
        
        table.insert(columnDefs, def)
    end
    
    sql = sql .. table.concat(columnDefs, ',\n')
    
    -- Add primary key
    for _, col in ipairs(self.columns) do
        if col.primary then
            sql = sql .. ',\n  PRIMARY KEY (`' .. col.name .. '`)'
            break
        end
    end
    
    -- Add indexes
    for _, idx in ipairs(self.indexes) do
        if idx.unique then
            sql = sql .. ',\n  UNIQUE KEY `' .. idx.name .. '` (' .. 
                  self:buildColumnList(idx.columns) .. ')'
        else
            sql = sql .. ',\n  KEY `' .. idx.name .. '` (' .. 
                  self:buildColumnList(idx.columns) .. ')'
        end
    end
    
    -- Add foreign keys
    for _, fk in ipairs(self.foreignKeys) do
        sql = sql .. ',\n  FOREIGN KEY (`' .. fk.column .. '`) REFERENCES `' .. 
              fk.on .. '`(`' .. fk.references .. '`) ON DELETE ' .. fk.onDelete .. 
              ' ON UPDATE ' .. fk.onUpdate
    end
    
    sql = sql .. '\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;'
    
    return sql
end

--- Helper to build column list for indexes
function Blueprint:buildColumnList(columns)
    local quoted = {}
    for _, col in ipairs(columns) do
        table.insert(quoted, '`' .. col .. '`')
    end
    return table.concat(quoted, ', ')
end

--- Schema static methods

--- Create a new table
function Schema.create(tableName, callback)
    local blueprint = Blueprint.new(tableName)
    callback(blueprint)
    local sql = blueprint:toSql()
    
    print('[Schema] Creating table: ' .. tableName)
    print('[Schema] SQL: ' .. sql)
    local result = Database.querySync(sql, {})
    print('[Schema] Result: ' .. json.encode(result))
    return result
end

--- Drop a table
function Schema.drop(tableName)
    local sql = 'DROP TABLE IF EXISTS `' .. tableName .. '`'
    print('[Schema] Dropping table: ' .. tableName)
    return Database.querySync(sql, {})
end

--- Check if a table exists
function Schema.hasTable(tableName)
    local sql = [[SELECT COUNT(*) as count FROM information_schema.TABLES 
                  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?]]
    local result = Database.querySync(sql, {tableName})
    return result and result[1] and result[1].count > 0
end

--- Modify an existing table
function Schema.table(tableName, callback)
    local blueprint = Blueprint.new(tableName)
    blueprint.isAltering = true
    callback(blueprint)
    
    -- Build ALTER TABLE statements
    local statements = {}
    
    for _, col in ipairs(blueprint.columns) do
        local def = '`' .. col.name .. '` ' .. col.type
        
        if not col.nullable then
            def = def .. ' NOT NULL'
        end
        
        if col.default ~= nil then
            if type(col.default) == 'string' and col.default:match('CURRENT_TIMESTAMP') then
                def = def .. ' DEFAULT ' .. col.default
            else
                def = def .. ' DEFAULT \'' .. tostring(col.default) .. '\''
            end
        end
        
        table.insert(statements, 'ALTER TABLE `' .. tableName .. '` ADD COLUMN ' .. def .. ';')
    end
    
    for _, idx in ipairs(blueprint.indexes) do
        if idx.unique then
            table.insert(statements, 'ALTER TABLE `' .. tableName .. '` ADD UNIQUE INDEX `' .. 
                        idx.name .. '` (' .. blueprint:buildColumnList(idx.columns) .. ');')
        else
            table.insert(statements, 'ALTER TABLE `' .. tableName .. '` ADD INDEX `' .. 
                        idx.name .. '` (' .. blueprint:buildColumnList(idx.columns) .. ');')
        end
    end
    
    for _, sql in ipairs(statements) do
        Database.querySync(sql, {})
    end
end

--- Check if a column exists
function Schema.hasColumn(tableName, columnName)
    local sql = [[SELECT COUNT(*) as count FROM information_schema.COLUMNS 
                  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?]]
    local result = Database.querySync(sql, {tableName, columnName})
    return result and result[1] and result[1].count > 0
end

--- Drop a column
function Schema.dropColumn(tableName, columnName)
    local sql = 'ALTER TABLE `' .. tableName .. '` DROP COLUMN `' .. columnName .. '`'
    return Database.querySync(sql, {})
end

--- Rename a column
function Schema.renameColumn(tableName, from, to)
    -- Note: This is simplified, in production you'd need to get the column type first
    local sql = 'ALTER TABLE `' .. tableName .. '` CHANGE `' .. from .. '` `' .. to .. '` VARCHAR(255)'
    return Database.querySync(sql, {})
end

return Schema
