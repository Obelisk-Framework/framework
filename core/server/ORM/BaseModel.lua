--- BaseModel - Active Record pattern with relationships
--- Inspired by Laravel's Eloquent ORM
BaseModel = {}
BaseModel.__index = function(instance, key)
    local attrs = rawget(instance, 'attributes')
    if attrs and attrs[key] ~= nil then
        return attrs[key]
    end
    local rels = rawget(instance, 'relations')
    if rels and rels[key] ~= nil then
        return rels[key]
    end
    return BaseModel[key]
end

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
    child.__index = function(instance, key)
        local attrs = rawget(instance, 'attributes')
        if attrs and attrs[key] ~= nil then
            return attrs[key]
        end
        local rels = rawget(instance, 'relations')
        if rels and rels[key] ~= nil then
            return rels[key]
        end
        return child[key]
    end
    setmetatable(child, { __index = self })

    if tableName then
        child.table = tableName
    end

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
    local query = QueryBuilder.new(self.table, self.primaryKey)
    query.model = self
    return query
end

--- Proxy the chainable QueryBuilder starter methods (and the `get` terminal)
--- onto the model itself, so `Inventory:where('owner', id):get()` works
--- without an explicit `Inventory:newQuery():where(...)` call, and so does an
--- unfiltered `Inventory:get()` (the direct replacement for the old
--- `all()`/`allSync()`). Each just opens a new query and forwards to the
--- same-named QueryBuilder method.
local QUERY_PROXY_METHODS = {
    'select', 'selectRaw', 'where', 'orWhere', 'whereIn', 'whereNull', 'whereNotNull',
    'orderBy', 'limit', 'offset', 'join', 'leftJoin', 'groupBy', 'get'
}

for _, methodName in ipairs(QUERY_PROXY_METHODS) do
    BaseModel[methodName] = function(self, ...)
        local query = self:newQuery()
        return query[methodName](query, ...)
    end
end

--- Record a relation path (single-level or dot-separated) to eager-load
--- after the terminal fetch resolves. Returns a QueryBuilder so further
--- `:with(...)` calls chain (each accumulates its own independent path)
--- ahead of either `get()` or `getAsync()`.
--- @param path string
--- @return QueryBuilder
function BaseModel:with(path)
    return self:newQuery():with(path)
end

--- Find synchronously
--- @param id any
--- @return BaseModel|nil
function BaseModel:find(id)
    local result = self:newQuery():where(self.primaryKey, id):first()
    if result then
        return self:newFromQuery(result)
    end
    return nil
end

--- Find a model by primary key (async)
--- @param id any
--- @param callback function
function BaseModel:findAsync(id, callback)
    self:newQuery():where(self.primaryKey, id):firstAsync(function(result)
        if result then
            local instance = self:newFromQuery(result)
            callback(instance)
        else
            callback(nil)
        end
    end)
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

--- Create synchronously
--- @param attributes table
--- @return BaseModel
function BaseModel:create(attributes)
    local instance = self.new(attributes)
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    instance:save()
    return instance
end

--- Create and save a new model (async)
--- @param attributes table
--- @param callback function
function BaseModel:createAsync(attributes, callback)
    local instance = self.new(attributes)
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    instance:saveAsync(callback)
end

--- Save synchronously
--- @return BaseModel
function BaseModel:save()
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

    return self
end

--- Save the model (async)
--- @param callback function
function BaseModel:saveAsync(callback)
    if self.timestamps then
        if not self.exists then
            self.attributes.created_at = Database.now()
        end
        self.attributes.updated_at = Database.now()
    end

    local writeAttributes = self:encodeJsonCasts(self.attributes)

    if self.exists then
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):updateAsync(writeAttributes, function(affected)
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    else
        self:newQuery():insertAsync(writeAttributes, function(insertId)
            self.attributes[self.primaryKey] = insertId
            self.exists = true
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    end
end

--- Delete synchronously
--- @return boolean
function BaseModel:delete()
    if not self.exists then
        return false
    end

    local pk = self.attributes[self.primaryKey]
    self:newQuery():where(self.primaryKey, pk):delete()
    self.exists = false
    return true
end

--- Delete the model (async)
--- @param callback function
function BaseModel:deleteAsync(callback)
    if not self.exists then
        if callback then callback(false) end
        return
    end

    local pk = self.attributes[self.primaryKey]
    self:newQuery():where(self.primaryKey, pk):deleteAsync(function(affected)
        self.exists = false
        if callback then callback(true) end
    end)
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

--- Load relationship synchronously
--- @param relationName string
--- @return any
function BaseModel:load(relationName)
    if self.relations[relationName] then
        return self.relations[relationName]
    end

    local relation = self[relationName](self)

    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        local result = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):first()
        if result then
            self.relations[relationName] = relation.relatedModel:newFromQuery(result)
        end
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        local results = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):get()
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, relation.relatedModel:newFromQuery(result))
        end
        self.relations[relationName] = models
    elseif relation.type == 'belongsTo' then
        local foreignValue = self.attributes[relation.foreignKey]
        self.relations[relationName] = relation.relatedModel:find(foreignValue)
    elseif relation.type == 'belongsToMany' then
        local localId = self.attributes[self.primaryKey]
        local query = relation.relatedModel:newQuery()
            :join(relation.pivotTable,
                  relation.relatedModel.table .. '.' .. relation.relatedModel.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :where(relation.pivotTable .. '.' .. relation.foreignPivotKey, localId)

        local results = query:get()
        local models = {}
        for _, result in ipairs(results) do
            table.insert(models, relation.relatedModel:newFromQuery(result))
        end
        self.relations[relationName] = models
    end

    return self.relations[relationName]
end

--- Load a relationship (lazy loading, async)
--- @param relationName string
--- @param callback function
function BaseModel:loadAsync(relationName, callback)
    if self.relations[relationName] then
        callback(self.relations[relationName])
        return
    end

    local relation = self[relationName](self)

    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):firstAsync(function(result)
            if result then
                self.relations[relationName] = relation.relatedModel:newFromQuery(result)
            end
            callback(self.relations[relationName])
        end)
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):getAsync(function(results)
            local models = {}
            for _, result in ipairs(results) do
                table.insert(models, relation.relatedModel:newFromQuery(result))
            end
            self.relations[relationName] = models
            callback(models)
        end)
    elseif relation.type == 'belongsTo' then
        local foreignValue = self.attributes[relation.foreignKey]
        relation.relatedModel:findAsync(foreignValue, function(model)
            self.relations[relationName] = model
            callback(model)
        end)
    elseif relation.type == 'belongsToMany' then
        local localId = self.attributes[self.primaryKey]

        local query = relation.relatedModel:newQuery()
            :join(relation.pivotTable,
                  relation.relatedModel.table .. '.' .. relation.relatedModel.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :where(relation.pivotTable .. '.' .. relation.foreignPivotKey, localId)

        query:getAsync(function(results)
            local models = {}
            for _, result in ipairs(results) do
                table.insert(models, relation.relatedModel:newFromQuery(result))
            end
            self.relations[relationName] = models
            callback(models)
        end)
    end
end

--- Eager-load a (possibly dot-separated) relation path across a batch of
--- already-fetched model instances, one batched query per path segment.
--- @param instances table Array of model instances sharing this model's relations
--- @param path string e.g. 'customer' or 'customer.address'
function BaseModel:eagerLoad(instances, path)
    local segment, rest = path:match('^([^.]+)%.?(.*)$')
    if #instances == 0 then
        return
    end

    local relation = instances[1][segment](instances[1])
    local related = relation.relatedModel

    if relation.type == 'hasOne' or relation.type == 'hasMany' then
        local localValues = {}
        for _, inst in ipairs(instances) do
            table.insert(localValues, inst.attributes[relation.localKey])
        end
        local rows = related:newQuery():whereIn(relation.foreignKey, localValues):get()
        local byForeign = {}
        for _, row in ipairs(rows) do
            local fk = row.attributes[relation.foreignKey]
            byForeign[fk] = byForeign[fk] or {}
            table.insert(byForeign[fk], row)
        end
        for _, inst in ipairs(instances) do
            local matches = byForeign[inst.attributes[relation.localKey]] or {}
            inst.relations[segment] = (relation.type == 'hasOne') and matches[1] or matches
        end
    elseif relation.type == 'belongsTo' then
        local foreignValues = {}
        for _, inst in ipairs(instances) do
            table.insert(foreignValues, inst.attributes[relation.foreignKey])
        end
        local rows = related:newQuery():whereIn(relation.ownerKey, foreignValues):get()
        local byOwner = {}
        for _, row in ipairs(rows) do
            byOwner[row.attributes[relation.ownerKey]] = row
        end
        for _, inst in ipairs(instances) do
            inst.relations[segment] = byOwner[inst.attributes[relation.foreignKey]]
        end
    elseif relation.type == 'belongsToMany' then
        local localIds = {}
        for _, inst in ipairs(instances) do
            table.insert(localIds, inst.attributes[inst.primaryKey])
        end
        -- Grouping by owning instance requires the pivot's foreign key in the
        -- selected columns; select it explicitly alongside the related row so
        -- each returned row can be attributed back to the right instance(s)
        -- instead of being handed to every instance indiscriminately.
        local pivotFkColumn = relation.pivotTable .. '.' .. relation.foreignPivotKey
        local rows = related:newQuery()
            :select({related.table .. '.*', pivotFkColumn})
            :join(relation.pivotTable,
                  related.table .. '.' .. related.primaryKey,
                  '=',
                  relation.pivotTable .. '.' .. relation.relatedPivotKey)
            :whereIn(pivotFkColumn, localIds)
            :get()
        local byOwner = {}
        for _, inst in ipairs(instances) do
            inst.relations[segment] = {}
            byOwner[inst.attributes[inst.primaryKey]] = inst
        end
        -- Intern one shared model instance per unique related primary key.
        -- Each joined pivot row otherwise produces its OWN distinct instance
        -- even when it's the same related row shared by multiple owners
        -- (e.g. one tag on two posts), which breaks the seenIds dedup below
        -- (and any downstream `rest ~= ''` segment) since it keys on primary
        -- key expecting one shared object per row, like hasOne/hasMany/
        -- belongsTo already provide via their byForeign/byOwner tables.
        local byRelatedId = {}
        for _, row in ipairs(rows) do
            local owner = byOwner[row.attributes[relation.foreignPivotKey]]
            if owner then
                local relatedId = row.attributes[row.primaryKey]
                local shared = byRelatedId[relatedId]
                if not shared then
                    shared = row
                    byRelatedId[relatedId] = shared
                end
                table.insert(owner.relations[segment], shared)
            end
        end
    end

    if rest ~= '' then
        local nextLevelInstances = {}
        local seenIds = {}
        for _, inst in ipairs(instances) do
            local rel = inst.relations[segment]
            local relList = (relation.type == 'hasMany' or relation.type == 'belongsToMany') and rel or {rel}
            for _, relInst in ipairs(relList) do
                if relInst then
                    local id = relInst.attributes[relInst.primaryKey]
                    if not seenIds[id] then
                        seenIds[id] = true
                        table.insert(nextLevelInstances, relInst)
                    end
                end
            end
        end
        related:eagerLoad(nextLevelInstances, rest)
    end
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
    
    QueryBuilder.new(relation.pivotTable):insertAsync(data, callback)
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
    
    query:deleteAsync(callback)
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