--- BaseModel - Active Record pattern with relationships
--- Inspired by Laravel's Eloquent ORM
BaseModel = {}
BaseModel.__index = BaseModel

--- Valid hook names for lifecycle callbacks
local HOOK_NAMES = { afterSave = true, afterDelete = true }

--- Model configuration (override in child classes)
BaseModel.table = nil
BaseModel.primaryKey = 'id'
BaseModel.timestamps = true
BaseModel.fillable = {}
BaseModel.hidden = {}
BaseModel.casts = {}

--- Create a new model instance
--- @param attributes table
--- @return BaseModel
function BaseModel.new(attributes)
    local instance = setmetatable({}, BaseModel)
    instance.attributes = attributes or {}
    instance.original = {}
    instance.relations = {}
    instance.exists = false

    return instance
end

--- Create a subclass of this model (Active Record class inheritance)
--- Class-level lookups fall back to the parent, and instances use the child
--- as their metatable so custom methods and relationships resolve on instances.
--- @param tableName string|nil Optional table name for the new model
--- @return table The new model class
function BaseModel:extend(tableName)
    local child = {}
    child.__index = child
    setmetatable(child, { __index = self })

    if tableName then
        child.table = tableName
    end

    child.__hookDefs = { afterSave = {}, afterDelete = {} }
    child.hooks = setmetatable({}, {
        __index = function(_, key)
            assert(HOOK_NAMES[key], ("unknown hook %q"):format(key))
            return function(_, fn)
                assert(type(fn) == 'function', ("hook %q must be a function"):format(key))
                table.insert(child.__hookDefs[key], fn)
            end
        end,
    })

    --- Create a new instance of the child model
    --- @param attributes table
    --- @return table
    function child.new(attributes)
        local instance = setmetatable({}, child)
        instance.attributes = attributes or {}
        instance.original = {}
        instance.relations = {}
        instance.exists = false

        instance.table = child.table
        instance.primaryKey = child.primaryKey
        instance.timestamps = child.timestamps
        instance.fillable = child.fillable
        instance.hidden = child.hidden
        instance.casts = child.casts

        return instance
    end

    return child
end

--- Create a new query builder for this model
--- @return QueryBuilder
function BaseModel:newQuery()
    return QueryBuilder.new(self.table, self.primaryKey)
end

--- Proxy the chainable QueryBuilder starter methods onto the model itself, so
--- `Inventory:where('owner', id):getSync()` works without an explicit
--- `Inventory:newQuery():where(...)` call. Each just opens a new query and
--- forwards to the same-named QueryBuilder method.
local QUERY_PROXY_METHODS = {
    'select', 'selectRaw', 'where', 'orWhere', 'whereIn', 'whereNull', 'whereNotNull',
    'orderBy', 'limit', 'offset', 'join', 'leftJoin', 'groupBy'
}

for _, methodName in ipairs(QUERY_PROXY_METHODS) do
    BaseModel[methodName] = function(self, ...)
        local query = self:newQuery()
        return query[methodName](query, ...)
    end
end

--- Lifecycle hook lists for THIS class only (afterSave/afterDelete),
--- populated via `class.hooks` below. Each `extend()`'d child gets its
--- own fresh lists (see extend()) -- hooks registered on one model never
--- fire for another, unlike relations there's no inheritance story here.
BaseModel.__hookDefs = { afterSave = {}, afterDelete = {} }

--- `Model.hooks:afterSave(fn)` / `Model.hooks:afterDelete(fn)` register a
--- lifecycle callback, mirroring the `Model.relations:name()` registration
--- surface. Colon-call `hooks:afterSave(fn)` desugars to
--- `hooks.afterSave(hooks, fn)`; since no `afterSave`/`afterDelete` key is
--- ever set directly, `__index` synthesizes a registrar closure per key
--- rather than declaring two near-identical named functions.
BaseModel.hooks = setmetatable({}, {
    __index = function(_, key)
        assert(HOOK_NAMES[key], ("unknown hook %q"):format(key))
        return function(_, fn)
            assert(type(fn) == 'function', ("hook %q must be a function"):format(key))
            table.insert(BaseModel.__hookDefs[key], fn)
        end
    end,
})

--- Run every hook registered for `event` on this instance's class, in
--- registration order. Hook errors are caught and logged, never
--- propagated -- a broken listener (e.g. a misconfigured audit rule)
--- must not fail the write it's observing.
--- @param event string 'afterSave'|'afterDelete'
--- @param ctx table
function BaseModel:dispatchHooks(event, ctx)
    local defs = rawget(self, '__hookDefs') or getmetatable(self).__hookDefs
    if not defs then return end
    for _, fn in ipairs(defs[event]) do
        local ok, err = pcall(fn, self, ctx)
        if not ok then
            print(('[ORM] hook %q on %s raised: %s'):format(event, tostring(self.table), tostring(err)))
        end
    end
end

--- Find a model by primary key (async)
--- @param id any
--- @param callback function
function BaseModel:find(id, callback)
    self:newQuery():where(self.primaryKey, id):first(function(result)
        if result then
            local instance = self:newFromQuery(result)
            callback(instance)
        else
            callback(nil)
        end
    end)
end

--- Find synchronously
--- @param id any
--- @return BaseModel|nil
function BaseModel:findSync(id)
    local result = self:newQuery():where(self.primaryKey, id):firstSync()
    if result then
        return self:newFromQuery(result)
    end
    return nil
end

--- Get all records (async)
--- @param callback function
function BaseModel:all(callback)
    self:newQuery():get(function(results)
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, self:newFromQuery(result))
        end
        callback(models)
    end)
end

--- Get all synchronously
--- @return table
function BaseModel:allSync()
    local results = self:newQuery():getSync()
    local models = {}
    for _, result in ipairs(results) do
        table.insert(models, self:newFromQuery(result))
    end
    return models
end

--- Create a new model instance from query result
--- @param attributes table
--- @return BaseModel
function BaseModel:newFromQuery(attributes)
    attributes = self:decodeJsonCasts(attributes)
    local instance = self.new(attributes)
    instance.exists = true
    instance.original = self:copyTable(attributes)
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    instance.fillable = self.fillable
    instance.hidden = self.hidden
    instance.casts = self.casts
    return instance
end

--- Create and save a new model (async)
--- @param attributes table
--- @param callback function
function BaseModel:create(attributes, callback)
    local instance = self.new(attributes)
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    instance:save(callback)
end

--- Create synchronously
--- @param attributes table
--- @return BaseModel
function BaseModel:createSync(attributes)
    local instance = self.new(attributes)
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    instance:saveSync()
    return instance
end

--- Save the model (async)
--- @param callback function
function BaseModel:save(callback)
    local wasExisting = self.exists
    local before = wasExisting and self:copyTable(self.original) or nil

    if self.timestamps then
        if not self.exists then
            self.attributes.created_at = Database.now()
        end
        self.attributes.updated_at = Database.now()
    end

    local writeAttributes = self:encodeJsonCasts(self.attributes)

    if self.exists then
        -- Update existing
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(writeAttributes, function(affected)
            self.original = self:copyTable(self.attributes)
            self:dispatchHooks('afterSave', { action = 'update', before = before, after = self:copyTable(self.attributes) })
            if callback then callback(self) end
        end)
    else
        -- Insert new
        self:newQuery():insert(writeAttributes, function(insertId)
            self.attributes[self.primaryKey] = insertId
            self.exists = true
            self.original = self:copyTable(self.attributes)
            self:dispatchHooks('afterSave', { action = 'insert', before = nil, after = self:copyTable(self.attributes) })
            if callback then callback(self) end
        end)
    end
end

--- Save synchronously
--- @return BaseModel
function BaseModel:saveSync()
    local wasExisting = self.exists
    local before = wasExisting and self:copyTable(self.original) or nil

    if self.timestamps then
        if not self.exists then
            self.attributes.created_at = Database.now()
        end
        self.attributes.updated_at = Database.now()
    end

    local writeAttributes = self:encodeJsonCasts(self.attributes)

    if self.exists then
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(writeAttributes)
        self.original = self:copyTable(self.attributes)
    else
        local insertId = self:newQuery():insert(writeAttributes)
        self.attributes[self.primaryKey] = insertId
        self.exists = true
        self.original = self:copyTable(self.attributes)
    end

    self:dispatchHooks('afterSave', {
        action = wasExisting and 'update' or 'insert',
        before = before,
        after = self:copyTable(self.attributes),
    })

    return self
end

--- Delete the model (async)
--- @param callback function
function BaseModel:delete(callback)
    if not self.exists then
        if callback then callback(false) end
        return
    end

    local pk = self.attributes[self.primaryKey]
    local before = self:copyTable(self.attributes)
    self:newQuery():where(self.primaryKey, pk):delete(function(affected)
        self.exists = false
        self:dispatchHooks('afterDelete', { before = before })
        if callback then callback(true) end
    end)
end

--- Delete synchronously
--- @return boolean
function BaseModel:deleteSync()
    if not self.exists then
        return false
    end

    local pk = self.attributes[self.primaryKey]
    local before = self:copyTable(self.attributes)
    self:newQuery():where(self.primaryKey, pk):delete()
    self.exists = false
    self:dispatchHooks('afterDelete', { before = before })
    return true
end

--- Get attribute value
--- @param key string
--- @return any
function BaseModel:get(key)
    return self.attributes[key]
end

--- Set attribute value
--- @param key string
--- @param value any
function BaseModel:set(key, value)
    self.attributes[key] = value
end

--- Check if attribute has changed
--- @param key string
--- @return boolean
function BaseModel:isDirty(key)
    if key then
        return self.attributes[key] ~= self.original[key]
    end
    
    for k, v in pairs(self.attributes) do
        if v ~= self.original[k] then
            return true
        end
    end
    return false
end

--- Define a hasOne relationship
--- @param relatedModel BaseModel
--- @param foreignKey string
--- @param localKey string
--- @return table
function BaseModel:hasOne(relatedModel, foreignKey, localKey)
    localKey = localKey or self.primaryKey
    return {
        type = 'hasOne',
        relatedModel = relatedModel,
        foreignKey = foreignKey,
        localKey = localKey
    }
end

--- Define a hasMany relationship
--- @param relatedModel BaseModel
--- @param foreignKey string
--- @param localKey string
--- @return table
function BaseModel:hasMany(relatedModel, foreignKey, localKey)
    localKey = localKey or self.primaryKey
    return {
        type = 'hasMany',
        relatedModel = relatedModel,
        foreignKey = foreignKey,
        localKey = localKey
    }
end

--- Define a belongsTo relationship
--- @param relatedModel BaseModel
--- @param foreignKey string
--- @param ownerKey string
--- @return table
function BaseModel:belongsTo(relatedModel, foreignKey, ownerKey)
    ownerKey = ownerKey or relatedModel.primaryKey
    return {
        type = 'belongsTo',
        relatedModel = relatedModel,
        foreignKey = foreignKey,
        ownerKey = ownerKey
    }
end

--- Define a manyToMany relationship
--- @param relatedModel BaseModel
--- @param pivotTable string
--- @param foreignPivotKey string
--- @param relatedPivotKey string
--- @return table
function BaseModel:belongsToMany(relatedModel, pivotTable, foreignPivotKey, relatedPivotKey)
    return {
        type = 'belongsToMany',
        relatedModel = relatedModel,
        pivotTable = pivotTable,
        foreignPivotKey = foreignPivotKey,
        relatedPivotKey = relatedPivotKey
    }
end

--- Load a relationship (lazy loading)
--- @param relationName string
--- @param callback function
function BaseModel:load(relationName, callback)
    if self.relations[relationName] then
        callback(self.relations[relationName])
        return
    end
    
    local relation = self[relationName](self)
    
    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):first(function(result)
            if result then
                self.relations[relationName] = relation.relatedModel:newFromQuery(result)
            end
            callback(self.relations[relationName])
        end)
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):get(function(results)
            local models = {}
            for _, result in ipairs(results) do
                table.insert(models, relation.relatedModel:newFromQuery(result))
            end
            self.relations[relationName] = models
            callback(models)
        end)
    elseif relation.type == 'belongsTo' then
        local foreignValue = self.attributes[relation.foreignKey]
        relation.relatedModel:find(foreignValue, function(model)
            self.relations[relationName] = model
            callback(model)
        end)
    elseif relation.type == 'belongsToMany' then
        local localId = self.attributes[self.primaryKey]
        
        -- Query pivot table and join with related table
        local query = relation.relatedModel:newQuery()
            :join(relation.pivotTable, 
                  relation.relatedModel.table .. '.' .. relation.relatedModel.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :where(relation.pivotTable .. '.' .. relation.foreignPivotKey, localId)
        
        query:get(function(results)
            local models = {}
            for _, result in ipairs(results) do
                table.insert(models, relation.relatedModel:newFromQuery(result))
            end
            self.relations[relationName] = models
            callback(models)
        end)
    end
end

--- Load relationship synchronously
--- @param relationName string
--- @return any
function BaseModel:loadSync(relationName)
    if self.relations[relationName] then
        return self.relations[relationName]
    end
    
    local relation = self[relationName](self)
    
    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        local result = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):firstSync()
        if result then
            self.relations[relationName] = relation.relatedModel:newFromQuery(result)
        end
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        local results = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):getSync()
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, relation.relatedModel:newFromQuery(result))
        end
        self.relations[relationName] = models
    elseif relation.type == 'belongsTo' then
        local foreignValue = self.attributes[relation.foreignKey]
        self.relations[relationName] = relation.relatedModel:findSync(foreignValue)
    elseif relation.type == 'belongsToMany' then
        local localId = self.attributes[self.primaryKey]
        local query = relation.relatedModel:newQuery()
            :join(relation.pivotTable,
                  relation.relatedModel.table .. '.' .. relation.relatedModel.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :where(relation.pivotTable .. '.' .. relation.foreignPivotKey, localId)
        
        local results = query:getSync()
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, relation.relatedModel:newFromQuery(result))
        end
        self.relations[relationName] = models
    end
    
    return self.relations[relationName]
end

--- Attach a many-to-many relationship
--- @param relationName string
--- @param id any
--- @param pivotData table Optional pivot attributes
--- @param callback function
function BaseModel:attach(relationName, id, pivotData, callback)
    local relation = self[relationName](self)
    
    if relation.type ~= 'belongsToMany' then
        error('attach() only works with belongsToMany relationships')
    end
    
    local data = {
        [relation.foreignPivotKey] = self.attributes[self.primaryKey],
        [relation.relatedPivotKey] = id
    }
    
    if pivotData then
        for k, v in pairs(pivotData) do
            data[k] = v
        end
    end
    
    QueryBuilder.new(relation.pivotTable):insert(data, callback)
end

--- Detach a many-to-many relationship
--- @param relationName string
--- @param id any Optional, detaches all if nil
--- @param callback function
function BaseModel:detach(relationName, id, callback)
    local relation = self[relationName](self)
    
    if relation.type ~= 'belongsToMany' then
        error('detach() only works with belongsToMany relationships')
    end
    
    local query = QueryBuilder.new(relation.pivotTable)
        :where(relation.foreignPivotKey, self.attributes[self.primaryKey])
    
    if id then
        query:where(relation.relatedPivotKey, id)
    end
    
    query:delete(callback)
end

--- Convert model to table (for JSON serialization)
--- @return table
function BaseModel:toTable()
    local result = self:copyTable(self.attributes)
    
    -- Add loaded relations
    for name, relation in pairs(self.relations) do
        if type(relation) == 'table' and relation.toTable then
            result[name] = relation:toTable()
        elseif type(relation) == 'table' then
            -- Array of models
            result[name] = {}
            for _, model in ipairs(relation) do
                if model.toTable then
                    table.insert(result[name], model:toTable())
                end
            end
        end
    end
    
    -- Remove hidden attributes
    for _, hidden in ipairs(self.hidden) do
        result[hidden] = nil
    end
    
    return result
end

--- Helper: Deep copy table
--- @param t table
--- @return table
function BaseModel:copyTable(t)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == 'table' then
            copy[k] = self:copyTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

--- Encode any `casts[key] == 'json'` table attributes to JSON strings for
--- writing to the database. Returns a copy; never mutates `attributes`.
--- @param attributes table
--- @return table
function BaseModel:encodeJsonCasts(attributes)
    local encoded = self:copyTable(attributes)
    for key, castType in pairs(self.casts or {}) do
        if castType == 'json' and type(encoded[key]) == 'table' then
            encoded[key] = json.encode(encoded[key])
        end
    end
    return encoded
end

--- Decode any `casts[key] == 'json'` string attributes into tables after
--- reading from the database. Mutates and returns `attributes`. A malformed
--- JSON string decodes to an empty table rather than erroring, matching how
--- the rest of the codebase tolerates unparseable JSON (see
--- core/server/bootstrap.lua's migration runner).
--- @param attributes table
--- @return table
function BaseModel:decodeJsonCasts(attributes)
    for key, castType in pairs(self.casts or {}) do
        if castType == 'json' and type(attributes[key]) == 'string' then
            local ok, decoded = pcall(json.decode, attributes[key])
            attributes[key] = (ok and decoded) or {}
        end
    end
    return attributes
end

return BaseModel