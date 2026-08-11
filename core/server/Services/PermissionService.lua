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

return PermissionService
