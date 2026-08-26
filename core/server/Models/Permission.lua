--- Permission - a polymorphic permission grant ("owner_type #owner_id has
--- permission_key"). owner_type/owner_id point at whatever entity type each
--- module registers with PermissionService.registerType; no morphTo here
--- since a grant is just "does this row exist", nothing to load off it.
Permission = BaseModel:extend('permissions')

Permission.primaryKey = 'id'
Permission.timestamps = true
Permission.fillable = { 'owner_type', 'owner_id', 'permission_key' }

return Permission
