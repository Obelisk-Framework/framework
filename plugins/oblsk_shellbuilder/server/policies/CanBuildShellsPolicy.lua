--- CanBuildShellsPolicy - gates shell creation/edit-mode entry to admins
--- (FiveM ACE 'admin', same check IsAdminPolicy uses) or any character
--- explicitly granted the 'shellbuilder.build' permission via
--- PermissionService. Attached to the shellbuilder:create and
--- shellbuilder:edit actions in server/main.lua (Task 5).
local function canBuildShellsValidator(source, resource, config)
    if IsPlayerAceAllowed(source, 'admin') then
        return true
    end

    local characterId = CharacterService.getActiveCharacterId(source)
    if characterId and PermissionService.can('character', characterId, 'shellbuilder.build') then
        return true
    end

    return false, 'You do not have permission to build shells'
end

PolicyService.register('shellbuilder:canBuild', canBuildShellsValidator, {
    description = 'Checks admin ACE or a granted shellbuilder.build permission',
})

print('[Policy] Registered shellbuilder:canBuild policy')
