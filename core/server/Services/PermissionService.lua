--- PermissionService (core) - a generic polymorphic permission-grant store,
--- reusable by any entity type any module registers. Mirrors PolicyService's
--- registry + polymorphic-pivot-table idiom, except one fixed table
--- (`permissions`) instead of a table-per-resource-type, since a grant is
--- just "does this row exist", nothing configurable to store alongside it.
--- See docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
PermissionService = {}

--- typeName -> Model, populated by each entity type's owning module calling
--- registerType once at boot. grant/revoke/has/list reject an unregistered
--- type instead of silently writing garbage.
PermissionService.registeredTypes = {}

--- typeName -> array of resolver functions, populated by a DIFFERENT module
--- than the one that owns typeName (see addDelegate, Task 2).
PermissionService.delegates = {}

--- @param typeName string
--- @param Model table the model class this type corresponds to (kept for
---   future admin tooling; not required for grant/revoke/has/list to work)
function PermissionService.registerType(typeName, Model)
    PermissionService.registeredTypes[typeName] = Model
end

local function assertRegistered(ownerType)
    if not PermissionService.registeredTypes[ownerType] then
        error('PermissionService: "' .. tostring(ownerType) .. '" is not a registered entity type', 3)
    end
end

--- @param ownerType string
--- @param ownerId number
--- @param key string
function PermissionService.grant(ownerType, ownerId, key)
    assertRegistered(ownerType)

    local existing = QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('permission_key', key):firstSync()
    if existing then
        return
    end

    QueryBuilder.new('permissions'):insert({
        owner_type = ownerType,
        owner_id = ownerId,
        permission_key = key,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param ownerType string
--- @param ownerId number
--- @param key string
function PermissionService.revoke(ownerType, ownerId, key)
    assertRegistered(ownerType)

    QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('permission_key', key):delete()
end

--- Direct grant lookup only. No unregistered-type check: a lookup for an
--- owner type nobody ever registered is simply always false, same as one
--- that was registered but never granted anything.
--- @param ownerType string
--- @param ownerId number
--- @param key string
--- @return boolean
function PermissionService.has(ownerType, ownerId, key)
    local row = QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):where('permission_key', key):firstSync()
    return row ~= nil
end

--- @param ownerType string
--- @param ownerId number
--- @return string[] every granted permission_key for this owner
function PermissionService.list(ownerType, ownerId)
    local rows = QueryBuilder.new('permissions')
        :where('owner_type', ownerType):where('owner_id', ownerId):getSync()

    local keys = {}
    for _, row in ipairs(rows) do
        table.insert(keys, row.permission_key)
    end
    return keys
end

--- Registers a resolver that extends what "can <typeName> #id do X" means,
--- on behalf of a DIFFERENT module than the one owning typeName. Multiple
--- delegates for the same typeName may be registered; all run. Does not
--- validate typeName against registeredTypes, a delegate may be added
--- before or after its target type is registered.
--- @param typeName string
--- @param resolverFn function(ownerId) -> table[] of { type = string, id = number }
function PermissionService.addDelegate(typeName, resolverFn)
    PermissionService.delegates[typeName] = PermissionService.delegates[typeName] or {}
    table.insert(PermissionService.delegates[typeName], resolverFn)
end

--- @param ownerType string
--- @param ownerId number
--- @param key string
--- @return boolean true if directly granted, or granted to any ref any delegate resolves to
function PermissionService.can(ownerType, ownerId, key)
    if PermissionService.has(ownerType, ownerId, key) then
        return true
    end

    for _, resolver in ipairs(PermissionService.delegates[ownerType] or {}) do
        for _, ref in ipairs(resolver(ownerId) or {}) do
            if PermissionService.has(ref.type, ref.id, key) then
                return true
            end
        end
    end

    return false
end

return PermissionService
