-- plugins/oblsk_propattach/server/seeders/PropAttachPermissionSeeder.lua
--- PropAttachPermissionSeeder - documents this plugin's permission key, same
--- shape as LicensesPermissionSeeder.lua. Grant with e.g.
--- `/org-grant character <characterId> propattach_edit`.
PropAttachPermissionSeeder = {}

PropAttachPermissionSeeder.PERMISSION_KEYS = { PropAttachConfig.EditPermission }

function PropAttachPermissionSeeder.ensure()
    print('[PropAttach] permission keys available: ' .. table.concat(PropAttachPermissionSeeder.PERMISSION_KEYS, ', '))
end

return PropAttachPermissionSeeder
