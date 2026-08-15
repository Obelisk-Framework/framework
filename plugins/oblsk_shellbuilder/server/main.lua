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
        ownedShellIds = ShellService.listOwnedShellIds(characterId)
    end

    return { canBuild = canBuild and true or false, ownedShellIds = ownedShellIds }
end

--- The shell list a given player is allowed to see: staff with build access
--- see every shell (they need to manage all of them); everyone else only
--- sees shells they own. Avoids leaking every shell's id/name/budget to
--- players with no stake in them.
--- @param source number
--- @param permissions table result of permissionsFor(source)
--- @return table[]
local function visibleShellsFor(source, permissions)
    if permissions.canBuild then
        return ShellService.list()
    end

    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return {}
    end

    local ownedIds = {}
    for _, id in ipairs(ShellService.listOwnedShellIds(characterId)) do
        ownedIds[id] = true
    end

    local shells = {}
    for _, shell in ipairs(ShellService.list()) do
        if ownedIds[shell.id] then
            table.insert(shells, shell)
        end
    end
    return shells
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
    local permissions = permissionsFor(source)
    Obelisk.emitClient('shellbuilder:server:sync', source, {
        shells = visibleShellsFor(source, permissions),
        permissions = permissions,
    })
end

ActionService.register('shellbuilder:open', function(source, data)
    openBrowser(source)
end, { label = 'Access shells' })

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
    local permissions = permissionsFor(source)
    Obelisk.emitClient('shellbuilder:server:sync', source, {
        shells = visibleShellsFor(source, permissions),
        permissions = permissions,
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
    EntityStreamerService.sendGroupEntitiesTo(source, 'shellbuilder:shell:' .. shellId)
    SetEntityCoords(GetPlayerPed(source), ShellBuilderConfig.Anchor.x, ShellBuilderConfig.Anchor.y, ShellBuilderConfig.Anchor.z, false, false, false, false)
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
    EntityStreamerService.sendGroupEntitiesTo(source, 'shellbuilder:shell:' .. shellId)
    SetEntityCoords(GetPlayerPed(source), ShellBuilderConfig.Anchor.x, ShellBuilderConfig.Anchor.y, ShellBuilderConfig.Anchor.z, false, false, false, false)
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

-- A player should always be able to leave, but the caller-supplied shellId
-- isn't trusted as a teleport target: only honor its stored entry
-- coordinates when the caller actually manages that shell (owner, or
-- build-permission staff). Otherwise still leave the instance, just land at
-- the plugin's safe, always-valid EntryPoint instead of a possibly
-- manipulated shellId's coordinates.
Obelisk.onServer('shellbuilder:client:exit', function(shellId)
    local source = source
    local shell = ShellService.get(shellId)
    local allowed = shell ~= nil and select(1, canManageShell(source, shellId))

    -- Furniture is spawned client-LOCAL (CreateObject's networked flag is
    -- false), so routing buckets don't despawn it on their own -- without
    -- this, a player who exits shell A and enters shell B would see BOTH
    -- shells' furniture at once, at the shared anchor coordinate.
    EntityStreamerService.despawnGroupEntitiesFor(source, 'shellbuilder:shell:' .. shellId)
    InstanceService.leave(source)
    if shell and allowed then
        SetEntityCoords(GetPlayerPed(source), shell.entry_x, shell.entry_y, shell.entry_z, false, false, false, false)
        SetEntityHeading(GetPlayerPed(source), shell.entry_heading)
    else
        SetEntityCoords(GetPlayerPed(source), ShellBuilderConfig.EntryPoint.x, ShellBuilderConfig.EntryPoint.y, ShellBuilderConfig.EntryPoint.z, false, false, false, false)
    end
    WebView.hide(source)
    Obelisk.emitClient('shellbuilder:server:exited', source, {})
end)

-- Safety-net command: force-exits the caller from whatever instance/routing
-- bucket they're in and drops them at the plugin's fixed entry point,
-- regardless of NUI state. Pressing ESC only hides the NUI dock, it doesn't
-- emit shellbuilder:client:exit, so a player without the editor UI open has
-- no other way back to the overworld from inside a shell's bucket. This is
-- a pragmatic safety net, not a full fix - a proper on-disconnect/on-join
-- position guard is still a follow-up item.
RegisterCommand('leaveshell', function(source)
    if source == 0 then return end
    -- No shellId is supplied to this command -- resolve whatever key the
    -- player's currently tracked as being inside so their client-local
    -- furniture is despawned too, the same as the ordinary exit handler.
    local currentKey = InstanceService.getCurrentKey(source)
    if currentKey then
        EntityStreamerService.despawnGroupEntitiesFor(source, currentKey)
    end
    InstanceService.leave(source)
    SetEntityCoords(GetPlayerPed(source), ShellBuilderConfig.EntryPoint.x, ShellBuilderConfig.EntryPoint.y, ShellBuilderConfig.EntryPoint.z, false, false, false, false)
    WebView.hide(source)
end, false)

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

Obelisk.onServer('shellbuilder:client:searchCharacters', function(query)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end
    Obelisk.emitClient('shellbuilder:server:characterSearchResults', source, ShellService.searchCharactersByName(query or ''))
end)

Obelisk.onServer('shellbuilder:client:addOwner', function(shellId, characterId)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end
    ShellService.addOwner(shellId, characterId)
    Obelisk.emitClient('shellbuilder:server:ownersUpdated', source, { shellId = shellId, owners = ShellService.listOwnersWithNames(shellId) })
end)

Obelisk.onServer('shellbuilder:client:removeOwner', function(shellId, characterId)
    local source = source
    local ok, reason = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then
        NotificationService.notify(source, { type = 'error', title = 'Access denied', description = reason })
        return
    end
    ShellService.removeOwner(shellId, characterId)
    Obelisk.emitClient('shellbuilder:server:ownersUpdated', source, { shellId = shellId, owners = ShellService.listOwnersWithNames(shellId) })
end)

-- Staff open a shell they didn't just add/remove an owner on and previously
-- saw an empty owner panel forever -- the sync payload never carried
-- owners, and nothing fetched them on selection. Reuses the SAME
-- ownersUpdated event/shape the add/remove handlers above emit, so the Vue
-- side needs no new listener.
-- Passive background fetch (fires on shell selection, not a user-initiated
-- action), so a denial fails silently rather than notifying -- unlike
-- addOwner/removeOwner above, which are explicit user actions.
Obelisk.onServer('shellbuilder:client:listOwners', function(shellId)
    local source = source
    local ok = PolicyService.checkSync(source, 'action', 'shellbuilder:edit')
    if not ok then return end
    Obelisk.emitClient('shellbuilder:server:ownersUpdated', source, { shellId = shellId, owners = ShellService.listOwnersWithNames(shellId) })
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end

    -- PolicyService.attach issues DB queries immediately, so it can't run
    -- at top-level script load - Database.init() only finishes inside this
    -- background thread. CanBuildShellsPolicy.lua registers
    -- 'shellbuilder:canBuild' unconditionally at its own top-level load
    -- (independent of DB readiness), so by the time this thread runs the
    -- policy is guaranteed to already be registered regardless of file
    -- load order.
    PolicyService.attach('action', 'shellbuilder:create', 'shellbuilder:canBuild')
    PolicyService.attach('action', 'shellbuilder:edit', 'shellbuilder:canBuild')

    InteractionService.register({
        x = ShellBuilderConfig.EntryPoint.x, y = ShellBuilderConfig.EntryPoint.y, z = ShellBuilderConfig.EntryPoint.z,
        range = ShellBuilderConfig.EntryPoint.range, label = ShellBuilderConfig.EntryPoint.label,
        action = 'shellbuilder:open',
    })

    print('[ShellBuilder] Loaded successfully!')
end)
