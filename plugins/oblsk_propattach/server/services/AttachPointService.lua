--- AttachPointService - CRUD/lookup for named attach points (attach_points
--- table). A point is a (model, point_name, slot_index) triple resolving to
--- a bone index + offset + rotation. Uniqueness on that triple is enforced
--- here (check-then-insert), not at the DB layer, matching this repo's
--- existing convention (e.g. ShellObjectService).
AttachPointService = {}

--- @param model string
--- @param pointName string
--- @param slotIndex number
--- @return table|nil row
function AttachPointService.find(model, pointName, slotIndex)
    return QueryBuilder.new('attach_points')
        :where('model', model)
        :where('point_name', pointName)
        :where('slot_index', slotIndex)
        :firstSync()
end

--- @param model string
--- @return table[] every attach_points row for this model
function AttachPointService.listForModel(model)
    return QueryBuilder.new('attach_points'):where('model', model):getSync()
end

--- Insert a new point, or update the existing one for the same
--- (model, point_name, slot_index) triple.
--- @param model string
--- @param pointName string
--- @param slotIndex number
--- @param boneIndex number
--- @param offset table {x, y, z}
--- @param rotation table {x, y, z}
--- @return number id
function AttachPointService.upsert(model, pointName, slotIndex, boneIndex, offset, rotation)
    local existing = AttachPointService.find(model, pointName, slotIndex)

    local fields = {
        bone_index = boneIndex,
        offset_x = offset.x, offset_y = offset.y, offset_z = offset.z,
        rot_x = rotation.x, rot_y = rotation.y, rot_z = rotation.z,
        updated_at = Database.now(),
    }

    if existing then
        QueryBuilder.new('attach_points'):where('id', existing.id):update(fields)
        return existing.id
    end

    fields.model = model
    fields.point_name = pointName
    fields.slot_index = slotIndex
    fields.created_at = Database.now()

    return QueryBuilder.new('attach_points'):insert(fields)
end

return AttachPointService
