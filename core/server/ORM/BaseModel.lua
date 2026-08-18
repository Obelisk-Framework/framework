--- BaseModel - Active Record pattern with relationships
--- Inspired by Laravel's Eloquent ORM
--- Per-relation lazy-load counters, for the N+1 warning in resolveRelation
--- below. Dev-only signal, not enforcement -- reset per process, not per
--- request, so it's a "this relation gets loaded a lot, consider :with()"
--- nudge rather than a hard limit.
local LAZY_LOAD_WARN_THRESHOLD = 10
local lazyLoadCounts = {}

--- Declare `key` as a relation on `class` (backing store for the
--- `class.relations` __newindex below) and resolve+cache it for `instance`
--- if not already loaded. Shared by both BaseModel's own instances and
--- every extend()'d child's instances.
--- @param class table
--- @param instance table
--- @param key string
--- @return any|nil the resolved (and now cached) relation value, or nil if
---   `key` isn't a declared relation
local function resolveRelation(class, instance, key)
    local def = class.__relationDefs[key]
    if not def then
        return nil
    end
    local countKey = class.table .. '.' .. key
    lazyLoadCounts[countKey] = (lazyLoadCounts[countKey] or 0) + 1
    if lazyLoadCounts[countKey] == LAZY_LOAD_WARN_THRESHOLD then
        print(("[ORM] relation '%s' lazy-loaded %d+ times -- consider :with('%s')")
            :format(countKey, LAZY_LOAD_WARN_THRESHOLD, key))
    end
    class:eagerLoad({ instance }, key)
    return rawget(instance, 'relations')[key]
end

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
    local loaded = rawget(instance, '__loaded')
    if loaded and loaded[key] then
        return nil
    end
    if BaseModel.__relationDefs[key] then
        return resolveRelation(BaseModel, instance, key)
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

--- Relation definers, keyed by name -- populated only via `class.relations`
--- (see below), never written to directly.
BaseModel.__relationDefs = {}

--- `Model.relations` is the registration surface for lazily-loaded
--- relations, e.g. `function Character.relations:shellOwners() return
--- self:hasMany(ShellOwner, 'character_id') end`. Assigning a function
--- here (not on the model table itself) makes `key` resolve, on instance
--- property access, as a lazily-fetched-and-cached relation instead of a
--- plain method -- so relation methods and regular methods never collide,
--- and nothing needs to inspect or speculatively call anything.
BaseModel.relations = setmetatable({}, {
    __newindex = function(_, key, fn)
        assert(type(fn) == 'function', ("relation %q must be a function"):format(key))
        rawset(BaseModel.__relationDefs, key, fn)
    end,
    __index = BaseModel.__relationDefs,
})

--- Explicit accessor for the relation *definer* (the query descriptor
--- itself, e.g. to build on `hasMany`/`hasOne`/etc's own attributes) --
--- for when you want that instead of the resolved-and-cached value that
--- bare `instance.relationName` property access gives you. Lazy property
--- access and this accessor can't both use the same `instance:relationName()`
--- call syntax (once `.relationName` resolves to data, colon-calling it
--- calls the data, not the definer) so this is the escape hatch.
--- @param key string
--- @return table relation descriptor, e.g. `{type='hasMany', ...}`
function BaseModel:relation(key)
    -- `self` may be a class (called as `Customer:relation(...)`, which
    -- holds __relationDefs directly) or an instance (`customer:relation(...)`,
    -- which only has it via its metatable).
    local relationDefs = rawget(self, '__relationDefs') or getmetatable(self).__relationDefs
    local def = relationDefs[key]
    assert(def, ("no relation %q"):format(key))
    return def(self)
end

--- Create a new model instance
--- @param attributes table
--- @return BaseModel
function BaseModel.new(attributes)
    local instance = setmetatable({}, BaseModel)
    instance.attributes = attributes or {}
    instance.original = {}
    instance.relations = {}
    instance.__loaded = {}
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
    child.__relationDefs = setmetatable({}, { __index = self.__relationDefs })
    child.relations = setmetatable({}, {
        __newindex = function(_, key, fn)
            assert(type(fn) == 'function', ("relation %q must be a function"):format(key))
            rawset(child.__relationDefs, key, fn)
        end,
        __index = child.__relationDefs,
    })

    child.__index = function(instance, key)
        local attrs = rawget(instance, 'attributes')
        if attrs and attrs[key] ~= nil then
            return attrs[key]
        end
        local rels = rawget(instance, 'relations')
        if rels and rels[key] ~= nil then
            return rels[key]
        end
        local loaded = rawget(instance, '__loaded')
        if loaded and loaded[key] then
            return nil
        end
        if child.__relationDefs[key] then
            return resolveRelation(child, instance, key)
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
        instance.__loaded = {}
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
--- `all()`/`allSync()` — bare `get()` is sync, and there's a `getAsync()` variant).
--- Each just opens a new query and forwards to the same-named QueryBuilder method.
local QUERY_PROXY_METHODS = {
    'select', 'selectRaw', 'where', 'orWhere', 'whereIn', 'whereNull', 'whereNotNull',
    'orderBy', 'limit', 'offset', 'join', 'leftJoin', 'groupBy', 'get', 'firstOr'
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
    -- newQuery() attaches `.model`, so `first()` already decodes JSON casts
    -- and returns a wrapped model instance (or nil) -- do not re-wrap it.
    return self:newQuery():where(self.primaryKey, id):first()
end

--- Find a model by primary key (async)
--- @param id any
--- @param callback function
function BaseModel:findAsync(id, callback)
    -- See find(): firstAsync() is already model-aware, result is pre-wrapped.
    self:newQuery():where(self.primaryKey, id):firstAsync(callback)
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

--- Apply each key/value pair in `attributes` as an AND'd WHERE clause on
--- `query`. Shared by firstOrNew/firstOrCreate/updateOrCreate's lookup.
--- @param query QueryBuilder
--- @param attributes table
--- @return QueryBuilder
local function applyAttributeWhere(query, attributes)
    for key, value in pairs(attributes) do
        query:where(key, value)
    end
    return query
end

--- Shallow-merge two attribute tables; `values`' keys win over `attributes`'.
--- @param attributes table
--- @param values table|nil
--- @return table
local function mergeAttributes(attributes, values)
    local merged = {}
    for k, v in pairs(attributes) do merged[k] = v end
    if values then
        for k, v in pairs(values) do merged[k] = v end
    end
    return merged
end

--- Find the first model matching `attributes`, or build (without saving) a
--- new unsaved instance from `attributes` merged with `values`. Mirrors
--- Laravel's `firstOrNew` -- the caller must call `:save()` themselves on
--- the not-found path. Lookup is the only I/O, so there is no async form.
--- @param attributes table Lookup criteria, AND'd together
--- @param values table|nil Additional attributes to set only if not found
--- @return BaseModel
function BaseModel:firstOrNew(attributes, values)
    local found = applyAttributeWhere(self:newQuery(), attributes):first()
    if found then
        return found
    end

    local instance = self.new(mergeAttributes(attributes, values))
    instance.table = self.table
    instance.primaryKey = self.primaryKey
    instance.timestamps = self.timestamps
    return instance
end

--- Find the first model matching `attributes`, or create and save one from
--- `attributes` merged with `values`. Mirrors Laravel's `firstOrCreate`.
--- @param attributes table Lookup criteria, AND'd together
--- @param values table|nil Additional attributes to set only if not found
--- @return BaseModel
function BaseModel:firstOrCreate(attributes, values)
    local found = applyAttributeWhere(self:newQuery(), attributes):first()
    if found then
        return found
    end
    return self:create(mergeAttributes(attributes, values))
end

--- Async form of firstOrCreate.
--- @param attributes table
--- @param values table|nil
--- @param callback function
function BaseModel:firstOrCreateAsync(attributes, values, callback)
    applyAttributeWhere(self:newQuery(), attributes):firstAsync(function(found)
        if found then
            callback(found)
            return
        end
        self:createAsync(mergeAttributes(attributes, values), callback)
    end)
end

--- Find the first model matching `attributes`; if found, apply `values` and
--- save it; if not found, create one from `attributes` merged with `values`.
--- Mirrors Laravel's `updateOrCreate`.
--- @param attributes table Lookup criteria, AND'd together
--- @param values table|nil Attributes to apply on the found row, or fold into a new one
--- @return BaseModel
function BaseModel:updateOrCreate(attributes, values)
    local found = applyAttributeWhere(self:newQuery(), attributes):first()
    if found then
        if values then
            for key, value in pairs(values) do
                found:set(key, value)
            end
        end
        found:save()
        return found
    end
    return self:create(mergeAttributes(attributes, values))
end

--- Async form of updateOrCreate.
--- @param attributes table
--- @param values table|nil
--- @param callback function
function BaseModel:updateOrCreateAsync(attributes, values, callback)
    applyAttributeWhere(self:newQuery(), attributes):firstAsync(function(found)
        if found then
            if values then
                for key, value in pairs(values) do
                    found:set(key, value)
                end
            end
            found:saveAsync(callback)
            return
        end
        self:createAsync(mergeAttributes(attributes, values), callback)
    end)
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

    -- getmetatable(self).__relationDefs, not self[relationName] -- an
    -- instance property lookup for relationName would re-enter the lazy-
    -- relation __index hook and recurse; the class registry is unaffected.
    local class = getmetatable(self)
    local relation = (class.__relationDefs[relationName] or class[relationName])(self)

    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        -- newQuery() attaches `.model`, so `first()` already returns a
        -- wrapped model instance (or nil) -- do not re-wrap it.
        local result = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):first()
        if result then
            self.relations[relationName] = result
        end
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        -- `get()` is model-aware and already returns wrapped model instances.
        self.relations[relationName] = relation.relatedModel:newQuery():where(relation.foreignKey, localValue):get()
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

        -- `get()` is model-aware and already returns wrapped model instances.
        self.relations[relationName] = query:get()
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

    -- getmetatable(self).__relationDefs, not self[relationName] -- an
    -- instance property lookup for relationName would re-enter the lazy-
    -- relation __index hook and recurse; the class registry is unaffected.
    local class = getmetatable(self)
    local relation = (class.__relationDefs[relationName] or class[relationName])(self)

    if relation.type == 'hasOne' then
        local localValue = self.attributes[relation.localKey]
        -- firstAsync() is model-aware and already returns a wrapped model
        -- instance (or nil) -- do not re-wrap it.
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):firstAsync(function(result)
            if result then
                self.relations[relationName] = result
            end
            callback(self.relations[relationName])
        end)
    elseif relation.type == 'hasMany' then
        local localValue = self.attributes[relation.localKey]
        -- getAsync() is model-aware and already returns wrapped model instances.
        relation.relatedModel:newQuery():where(relation.foreignKey, localValue):getAsync(function(models)
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

        -- getAsync() is model-aware and already returns wrapped model instances.
        query:getAsync(function(models)
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

    -- self.__relationDefs, not instances[1][segment] -- reading it off an
    -- instance would re-enter the lazy-relation __index hook for `segment`
    -- and recurse; the class's registry is unaffected by instance state.
    local relation = (self.__relationDefs[segment] or self[segment])(instances[1])
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
            inst.__loaded[segment] = true
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
            inst.__loaded[segment] = true
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
            inst.__loaded[segment] = true
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
    -- getmetatable(self).__relationDefs, not self[relationName] -- an
    -- instance property lookup for relationName would re-enter the lazy-
    -- relation __index hook and recurse; the class registry is unaffected.
    local class = getmetatable(self)
    local relation = (class.__relationDefs[relationName] or class[relationName])(self)
    
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
    -- getmetatable(self).__relationDefs, not self[relationName] -- an
    -- instance property lookup for relationName would re-enter the lazy-
    -- relation __index hook and recurse; the class registry is unaffected.
    local class = getmetatable(self)
    local relation = (class.__relationDefs[relationName] or class[relationName])(self)
    
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