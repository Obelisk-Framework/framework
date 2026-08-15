--- AttachmentService - live attach instances (attachments table). Owns the
--- mechanism only: point lookup + row lifecycle. Policy (slot limits, what
--- happens when a parent despawns) is the calling plugin's responsibility.
AttachmentService = {}

--- @param row table raw attachments row (data may be a JSON string)
--- @return table
local function decodeRow(row)
    if row and type(row.data) == 'string' then
        local ok, parsed = pcall(json.decode, row.data)
        row.data = (ok and type(parsed) == 'table') and parsed or nil
    end
    return row
end

--- @param parentEntityType string 'vehicle'|'ped'|'player'|'object'
--- @param parentNetId number
--- @param parentModel string the model name to look up the attach point against
--- @param propModel string
--- @param pointName string
--- @param slotIndex number
--- @param opts table|nil { ownerType, ownerId, data }
--- @return table|nil row
--- @return string|nil error
function AttachmentService.attach(parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex, opts)
    opts = opts or {}

    local point = AttachPointService.find(parentModel, pointName, slotIndex)
    if not point then
        return nil, 'unknown attach point'
    end

    local id = QueryBuilder.new('attachments'):insert({
        prop_model = propModel,
        parent_entity_type = parentEntityType,
        parent_net_id = parentNetId,
        point_name = pointName,
        slot_index = slotIndex,
        owner_type = opts.ownerType,
        owner_id = opts.ownerId,
        data = opts.data and json.encode(opts.data) or nil,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return decodeRow(QueryBuilder.new('attachments'):where('id', id):firstSync()), nil
end

--- @param attachmentId number
--- @return boolean ok
function AttachmentService.detach(attachmentId)
    local row = QueryBuilder.new('attachments'):where('id', attachmentId):firstSync()
    if not row then return false end

    QueryBuilder.new('attachments'):where('id', attachmentId):delete()
    return true
end

--- @param parentEntityType string
--- @param parentNetId number
--- @return table[] rows
function AttachmentService.getAttachments(parentEntityType, parentNetId)
    local rows = QueryBuilder.new('attachments')
        :where('parent_entity_type', parentEntityType)
        :where('parent_net_id', parentNetId)
        :getSync()
    for _, row in ipairs(rows) do decodeRow(row) end
    return rows
end

--- @return table[] every live attachment row, used to snapshot late joiners.
function AttachmentService.all()
    local rows = QueryBuilder.new('attachments'):getSync()
    for _, row in ipairs(rows) do decodeRow(row) end
    return rows
end

return AttachmentService
