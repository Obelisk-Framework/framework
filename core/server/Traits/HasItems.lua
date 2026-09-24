--- HasItems defines the explicit identity used when this model owns item rows.
--- Apply it to each supported model with the stable owner_type persisted in
--- items.owner_type; do not infer that value from a table name.
HasItems = {}

--- @param Model table BaseModel subclass
--- @param ownerType string stable value stored in items.owner_type
function HasItems.apply(Model, ownerType)
    assert(type(Model) == 'table', 'HasItems.apply expects a model class')
    assert(type(ownerType) == 'string' and ownerType ~= '', 'HasItems.apply expects a non-empty owner type')

    Model.itemOwnerType = ownerType
    local primaryKey = Model.primaryKey or 'id'

    --- Return this persisted model's polymorphic owner identity.
    --- @return table|nil identity { type = string, id = any }
    --- @return string|nil reason
    function Model:itemOwner()
        if self.exists ~= true then
            return nil, 'Item owner must be persisted'
        end

        local id = self[primaryKey]
        if id == nil then
            return nil, 'Item owner has no primary key'
        end

        return { type = ownerType, id = id }, nil
    end
end

return HasItems
