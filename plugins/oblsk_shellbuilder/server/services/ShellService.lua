--- ShellService - shell CRUD and ownership. Kept free of any native/source
--- coupling so it's headless-testable; server/main.lua (Task 5) is the only
--- place that touches players/teleports directly.
ShellService = {}

--- @param createdByCharacterId number
--- @param name string
--- @return table shell row
function ShellService.create(createdByCharacterId, name)
    local id = QueryBuilder.new('shells'):insert({
        name = name,
        entry_x = Config.EntryPoint.x,
        entry_y = Config.EntryPoint.y,
        entry_z = Config.EntryPoint.z,
        entry_heading = 0,
        interior_heading = 0,
        object_budget = Config.DefaultObjectBudget,
        timecycle = 'Neutral',
        created_by_character_id = createdByCharacterId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return ShellService.get(id)
end

--- @return table[] every shell
function ShellService.list()
    return QueryBuilder.new('shells'):getSync()
end

--- @param shellId number
--- @return table|nil
function ShellService.get(shellId)
    return QueryBuilder.new('shells'):where('id', shellId):firstSync()
end

--- @param shellId number
function ShellService.delete(shellId)
    QueryBuilder.new('shell_owners'):where('shell_id', shellId):delete()
    QueryBuilder.new('shell_objects'):where('shell_id', shellId):delete()
    QueryBuilder.new('shells'):where('id', shellId):delete()
end

--- @param shellId number
--- @param name string
function ShellService.rename(shellId, name)
    QueryBuilder.new('shells'):where('id', shellId):update({
        name = name,
        updated_at = Database.now(),
    })
end

--- @param shellId number
--- @param x number
--- @param y number
--- @param z number
--- @param heading number
function ShellService.setEntryCoords(shellId, x, y, z, heading)
    QueryBuilder.new('shells'):where('id', shellId):update({
        entry_x = x,
        entry_y = y,
        entry_z = z,
        entry_heading = heading,
        updated_at = Database.now(),
    })
end

--- @param shellId number
--- @param characterId number
function ShellService.addOwner(shellId, characterId)
    if ShellService.isOwner(shellId, characterId) then return end

    QueryBuilder.new('shell_owners'):insert({
        shell_id = shellId,
        character_id = characterId,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param shellId number
--- @param characterId number
function ShellService.removeOwner(shellId, characterId)
    QueryBuilder.new('shell_owners')
        :where('shell_id', shellId):where('character_id', characterId):delete()
end

--- @param shellId number
--- @param characterId number
--- @return boolean
function ShellService.isOwner(shellId, characterId)
    return QueryBuilder.new('shell_owners')
        :where('shell_id', shellId):where('character_id', characterId):firstSync() ~= nil
end

--- @param shellId number
--- @return number[] every owning character_id
function ShellService.listOwners(shellId)
    local rows = QueryBuilder.new('shell_owners'):where('shell_id', shellId):getSync()
    local ids = {}
    for _, row in ipairs(rows) do
        table.insert(ids, row.character_id)
    end
    return ids
end

return ShellService
