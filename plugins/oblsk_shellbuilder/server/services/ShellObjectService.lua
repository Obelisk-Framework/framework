--- ShellObjectService - the placeable catalog (drawn from oblsk_items
--- bindings prefixed "shellbuilder.") plus placement/removal, budget
--- enforcement, and the locked/unlocked split that makes "comes with
--- interior, not removable" vs "empty, owner furnishes it" possible without
--- a separate shell "kind": staff-placed structural/decor pieces are
--- inserted with locked = true; an owner's own placements are always
--- locked = false, and remove() refuses to touch a locked row.
ShellObjectService = {}

local PREFIX = 'shellbuilder.'

--- @param key string
--- @return boolean
local function hasPrefix(key)
    return key:sub(1, #PREFIX) == PREFIX
end

--- Every "shellbuilder.*" item binding whose bound item's data.shell_tool
--- matches `tool`. A binding that's required but not yet bound (or bound to
--- an item missing shell_tool/shell_category/shell_model) is skipped rather
--- than surfaced as a broken catalog entry.
--- @param tool string 'build' | 'style' | 'decor'
--- @return table[] { key, name, category, model, tool }
function ShellObjectService.catalog(tool)
    local entries = {}
    for _, key in ipairs(ItemService.getRequiredBindingKeys()) do
        if hasPrefix(key) then
            local item = ItemService.binding(key)
            if item and item.data and item.data.shell_tool == tool then
                table.insert(entries, {
                    key = key,
                    name = item.name,
                    category = item.data.shell_category,
                    model = item.data.shell_model,
                    tool = tool,
                })
            end
        end
    end
    return entries
end

--- @param shellId number
--- @return table[] every shell_objects row for this shell
function ShellObjectService.list(shellId)
    return QueryBuilder.new('shell_objects'):where('shell_id', shellId):getSync()
end

--- @param shellId number
--- @return number
function ShellObjectService.count(shellId)
    return #ShellObjectService.list(shellId)
end

--- @param source number the placing player
--- @param shellId number
--- @param itemKey string a "shellbuilder.*" binding key
--- @param x number
--- @param y number
--- @param z number
--- @param heading number
--- @param floorLevel number
--- @param colorData table|nil
--- @param locked boolean true for a staff-placed, owner-immutable piece
--- @return boolean ok
--- @return table|string objectOrReason the inserted row on success, a reason string on failure
function ShellObjectService.place(source, shellId, itemKey, x, y, z, heading, floorLevel, colorData, locked)
    local shell = QueryBuilder.new('shells'):where('id', shellId):firstSync()
    if not shell then
        return false, 'Unknown shell'
    end

    local item = ItemService.binding(itemKey)
    if not item then
        return false, 'Unknown item'
    end

    if ShellObjectService.count(shellId) >= shell.object_budget then
        return false, 'Shell has reached its object budget'
    end

    local removed, reason = ItemService.remove(source, item, 1)
    if not removed then
        return false, reason or 'Not enough items'
    end

    local characterId = CharacterService.getActiveCharacterId(source)

    local id = QueryBuilder.new('shell_objects'):insert({
        shell_id = shellId,
        item_key = itemKey,
        x = x,
        y = y,
        z = z,
        heading = heading or 0,
        floor_level = floorLevel or 0,
        locked = locked and true or false,
        placed_by_character_id = locked and nil or characterId,
        color_data = colorData or {},
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return true, QueryBuilder.new('shell_objects'):where('id', id):firstSync()
end

--- Deletes a placed object and refunds the item it was placed from, unless
--- the object is locked (a staff-placed structural/fixed piece).
--- @param source number the removing player, credited the refund
--- @param shellId number
--- @param objectId number
--- @return boolean ok
--- @return string|nil reason
function ShellObjectService.remove(source, shellId, objectId)
    local object = QueryBuilder.new('shell_objects')
        :where('id', objectId):where('shell_id', shellId):firstSync()
    if not object then
        return false, 'Unknown object'
    end
    if object.locked then
        return false, 'This piece is locked'
    end

    local item = ItemService.binding(object.item_key)
    QueryBuilder.new('shell_objects'):where('id', objectId):delete()

    if item then
        ItemService.add(source, item, 1)
    end

    return true
end

return ShellObjectService
