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

    local placedByCharacterId = nil
    if not locked then
        placedByCharacterId = characterId
    end

    local id = QueryBuilder.new('shell_objects'):insert({
        shell_id = shellId,
        item_key = itemKey,
        x = x,
        y = y,
        z = z,
        heading = heading or 0,
        floor_level = floorLevel or 0,
        -- Stored as 1/0, not a Lua boolean: the `locked` column is a MySQL
        -- TINYINT(1), and a row read back through QueryBuilder:firstSync
        -- carries `locked` as an integer, not a Lua boolean (0 is truthy in
        -- Lua). Inserting 1/0 keeps the write side and the read-side check
        -- below consistent regardless of how reliably the underlying
        -- connector round-trips Lua true/false.
        locked = (locked and 1 or 0),
        placed_by_character_id = placedByCharacterId,
        -- The ShellObject model declares casts.color_data = 'json', but
        -- this service calls QueryBuilder directly and bypasses the model,
        -- so that cast never runs - encode explicitly here instead.
        color_data = colorData and json.encode(colorData) or nil,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    EntityStreamerService.registerGroupEntity(
        'shellbuilder:shell:' .. shellId,
        'object',
        { id = id, x = x, y = y, z = z, heading = heading or 0, model = item.data and item.data.shell_model, networked = false },
        InstanceService.getPlayersIn('shellbuilder:shell:' .. shellId)
    )

    QueryBuilder.new('entities'):insert({
        entity_type = 'object',
        model = item.data and item.data.shell_model,
        x = x, y = y, z = z, heading = heading or 0,
        networked = false,
        enabled = true,
        owner_type = 'shellbuilder_shell_object',
        owner_id = id,
        data = json.encode({ shellId = shellId }),
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return true, QueryBuilder.new('shell_objects'):where('id', id):firstSync()
end

--- Deletes a placed object and, when the remover is the same character who
--- placed it, refunds the item it was placed from. The object is refused
--- when locked (a staff-placed structural/fixed piece).
--- @param source number the removing player
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
    -- `locked` round-trips from MySQL as the integer 0/1 (TINYINT(1)), not
    -- a Lua boolean - 0 is truthy in Lua, so a plain `if object.locked`
    -- check refused removal for every object, locked or not. Accept both
    -- the fake test QueryBuilder's raw Lua booleans and the real
    -- integer 0/1 the live driver returns.
    if object.locked == true or object.locked == 1 then
        return false, 'This piece is locked'
    end

    local item = ItemService.binding(object.item_key)
    QueryBuilder.new('shell_objects'):where('id', objectId):delete()

    EntityStreamerService.unregisterGroupEntity(
        'shellbuilder:shell:' .. shellId,
        'object',
        'object_' .. tostring(objectId),
        InstanceService.getPlayersIn('shellbuilder:shell:' .. shellId)
    )

    QueryBuilder.new('entities'):where('owner_type', 'shellbuilder_shell_object'):where('owner_id', objectId):delete()

    -- canManageShell (server/main.lua) grants remove access to any
    -- build-permission staff member, not just the shell's owner - refunding
    -- unconditionally to `source` would let staff pocket another
    -- character's placed item by deleting it. Only refund when the remover
    -- is the same character who originally placed it; a different
    -- character removing someone else's unlocked item gets no refund.
    -- Known limitation: if the placer isn't currently online as `source`,
    -- there's no way to credit their live inventory through
    -- ItemService.add's source-based API, so the item is simply not
    -- refunded to anyone in that case - crediting an offline character
    -- would need a different item-grant path, out of scope here.
    if item and object.placed_by_character_id then
        local removerCharacterId = CharacterService.getActiveCharacterId(source)
        if removerCharacterId and removerCharacterId == object.placed_by_character_id then
            ItemService.add(source, item, 1)
        end
    end

    return true
end

return ShellObjectService
