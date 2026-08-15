-- core/plugins/oblsk_shellbuilder/server/main.lua
print('[ShellBuilder] Loading...')

--- @param source number
--- @return table { canBuild: boolean, ownedShellIds: number[] }
local function permissionsFor(source)
    local characterId = CharacterService.getActiveCharacterId(source)
    local canBuild = IsPlayerAceAllowed(source, 'admin')
        or (characterId and PermissionService.can('character', characterId, 'shellbuilder.build'))

    local ownedShellIds = {}
    if characterId then
        for _, shell in ipairs(ShellService.list()) do
            if ShellService.isOwner(shell.id, characterId) then
                table.insert(ownedShellIds, shell.id)
            end
        end
    end

    return { canBuild = canBuild and true or false, ownedShellIds = ownedShellIds }
end

--- Whether `source` may furnish/edit unlocked objects in `shellId`: either an
--- owner managing their own shell, or a builder with `shellbuilder:edit`
--- policy access (e.g. staff placing/removing unlocked decor as part of a
--- "comes with interior but not locked" shell).
--- @param source number
--- @param shellId number
--- @return boolean ok
--- @return string|nil reason
local function canManageShell(source, shellId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if characterId and ShellService.isOwner(shellId, characterId) then
        return true
    end

    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if ok then
        return true
    end

    return false, reason or 'You do not have access to this shell'
end

local function openBrowser(source)
    WebView.openPage(source, '/ShellBrowser')
    WebView.focus(source)
    Obelisk.emitClient('shellbuilder:server:sync', source, {
        shells = ShellService.list(),
        permissions = permissionsFor(source),
    })
end

ActionService.register('shellbuilder:open', function(source, data)
    openBrowser(source)
end, { label = 'Access shells' })

PolicyService.attach('action', 'shellbuilder:create', 'shellbuilder:canBuild')
PolicyService.attach('action', 'shellbuilder:edit', 'shellbuilder:canBuild')

Obelisk.onServer('shellbuilder:client:create', function(name)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:create')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end

    local characterId = CharacterService.getActiveCharacterId(source)
    local shell = ShellService.create(characterId, name)
    ShellService.addOwner(shell.id, characterId)
    Obelisk.emitClient('shellbuilder:server:sync', source, {
        shells = ShellService.list(),
        permissions = permissionsFor(source),
    })
end)

Obelisk.onServer('shellbuilder:client:enter', function(shellId)
    local source = source
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId or not ShellService.isOwner(shellId, characterId) then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = 'You do not own this shell' })
        return
    end

    local shell = ShellService.get(shellId)
    if not shell then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = 'Unknown shell' })
        return
    end

    InstanceService.enter(source, 'shellbuilder:shell:' .. shellId)
    SetEntityCoords(GetPlayerPed(source), Config.Anchor.x, Config.Anchor.y, Config.Anchor.z, false, false, false, false)
    SetEntityHeading(GetPlayerPed(source), shell.interior_heading)
    WebView.openPage(source, '/ShellEditor')
    WebView.focus(source)
    Obelisk.emitClient('shellbuilder:server:entered', source, { shellId = shellId, mode = 'edit' })
    Obelisk.emitClient('shellbuilder:server:editSync', source, {
        shell = shell,
        objects = ShellObjectService.list(shellId),
        catalogBuild = ShellObjectService.catalog('build'),
        catalogStyle = ShellObjectService.catalog('style'),
        catalogDecor = ShellObjectService.catalog('decor'),
        canBuild = false,
    })
end)

Obelisk.onServer('shellbuilder:client:edit', function(shellId)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end

    local shell = ShellService.get(shellId)
    if not shell then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = 'Unknown shell' })
        return
    end

    InstanceService.enter(source, 'shellbuilder:shell:' .. shellId)
    SetEntityCoords(GetPlayerPed(source), Config.Anchor.x, Config.Anchor.y, Config.Anchor.z, false, false, false, false)
    SetEntityHeading(GetPlayerPed(source), shell.interior_heading)
    WebView.openPage(source, '/ShellEditor')
    WebView.focus(source)
    Obelisk.emitClient('shellbuilder:server:entered', source, { shellId = shellId, mode = 'edit' })
    Obelisk.emitClient('shellbuilder:server:editSync', source, {
        shell = shell,
        objects = ShellObjectService.list(shellId),
        catalogBuild = ShellObjectService.catalog('build'),
        catalogStyle = ShellObjectService.catalog('style'),
        catalogDecor = ShellObjectService.catalog('decor'),
        canBuild = true,
    })
end)

Obelisk.onServer('shellbuilder:client:exit', function(shellId)
    local source = source
    local shell = ShellService.get(shellId)
    InstanceService.leave(source)
    if shell then
        SetEntityCoords(GetPlayerPed(source), shell.entry_x, shell.entry_y, shell.entry_z, false, false, false, false)
        SetEntityHeading(GetPlayerPed(source), shell.entry_heading)
    end
    WebView.hide(source)
    Obelisk.emitClient('shellbuilder:server:exited', source, {})
end)

Obelisk.onServer('shellbuilder:client:place', function(shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked)
    local source = source
    if locked then
        local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
        if not ok then
            NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
            return
        end
    else
        local ok, reason = canManageShell(source, shellId)
        if not ok then
            NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
            return
        end
    end

    local ok, objectOrReason = ShellObjectService.place(source, shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked)
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Could not place', description = objectOrReason })
        return
    end

    Obelisk.emitClient('shellbuilder:server:objectPlaced', source, objectOrReason)
end)

Obelisk.onServer('shellbuilder:client:removeObject', function(shellId, objectId)
    local source = source
    local accessOk, accessReason = canManageShell(source, shellId)
    if not accessOk then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = accessReason })
        return
    end

    local ok, reason = ShellObjectService.remove(source, shellId, objectId)
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Could not remove', description = reason })
        return
    end

    Obelisk.emitClient('shellbuilder:server:objectRemoved', source, { objectId = objectId })
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end

    InteractionService.register({
        x = Config.EntryPoint.x, y = Config.EntryPoint.y, z = Config.EntryPoint.z,
        range = Config.EntryPoint.range, label = Config.EntryPoint.label,
        action = 'shellbuilder:open',
    })

    print('[ShellBuilder] Loaded successfully!')
end)
