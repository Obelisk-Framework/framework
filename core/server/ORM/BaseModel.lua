--- BaseModel - Active Record pattern with relationships
--- Inspired by Laravel's Eloquent ORM
BaseModel = {}
BaseModel.__index = BaseModel

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

--- Create a new query builder for this model
--- @return QueryBuilder
function BaseModel:newQuery()
    return QueryBuilder.new(self.table)
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
    if self.timestamps then
        if not self.exists then
            self.attributes.created_at = Database.now()
        end
        self.attributes.updated_at = Database.now()
    end
    
    if self.exists then
        -- Update existing
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(self.attributes, function(affected)
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    else
        -- Insert new
        self:newQuery():insert(self.attributes, function(insertId)
            self.attributes[self.primaryKey] = insertId
            self.exists = true
            self.original = self:copyTable(self.attributes)
            if callback then callback(self) end
        end)
    end
end

--- Save synchronously
--- @return BaseModel
function BaseModel:saveSync()
    if self.timestamps then
        if not self.exists then
            self.attributes.created_at = Database.now()
        end
        self.attributes.updated_at = Database.now()
    end
    
    if self.exists then
        local pk = self.attributes[self.primaryKey]
        self:newQuery():where(self.primaryKey, pk):update(self.attributes)
        self.original = self:copyTable(self.attributes)
    else
        local insertId = self:newQuery():insert(self.attributes)
        self.attributes[self.primaryKey] = insertId
        self.exists = true
        self.original = self:copyTable(self.attributes)
    end
    
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
    self:newQuery():where(self.primaryKey, pk):delete(function(affected)
        self.exists = false
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
    self:newQuery():where(self.primaryKey, pk):delete()
    self.exists = false
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

return BaseModel