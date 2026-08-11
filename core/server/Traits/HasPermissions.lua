--- HasPermissions (core trait) - one mixin, not a general trait system.
--- HasPermissions.apply(Character, 'character') registers Character with
--- PermissionService under the 'character' type and adds :can/:grant/
--- :revoke/:permissionList instance methods backed by it. See
--- docs/superpowers/specs/2026-08-11-organizations-and-permissions-design.md.
HasPermissions = {}

--- @param Model table a BaseModel subclass (the result of BaseModel:extend(...))
--- @param typeName string the PermissionService entity type this model is registered as
function HasPermissions.apply(Model, typeName)
    Model.permissionType = typeName
    PermissionService.registerType(typeName, Model)

    function Model:can(key)
        return PermissionService.can(self.permissionType, self:get(self.primaryKey), key)
    end

    function Model:grant(key)
        return PermissionService.grant(self.permissionType, self:get(self.primaryKey), key)
    end

    function Model:revoke(key)
        return PermissionService.revoke(self.permissionType, self:get(self.primaryKey), key)
    end

    function Model:permissionList()
        return PermissionService.list(self.permissionType, self:get(self.primaryKey))
    end
end

return HasPermissions
