-- plugins/oblsk_propattach/server/main.lua
--- Net wiring for the attach mechanism. `attach`/`detach` broadcast to every
--- connected player (attachment counts are expected to stay small, unlike
--- EntityStreamerService's chunk-scoped entities, so no spatial filtering).
--- @param player Player NOTE: takes the resolved Player, not a raw source
--- number -- NotificationService.notify calls player:emit(...) internally,
--- which requires the Player object (see core/server/Services/PlayerService.lua).
local function notifyFailure(player, title, reason)
    NotificationService.notify(player, { type = 'error', title = title, description = reason })
end

--- Broadcast helper for same-VM callers: any other plugin calls
--- AttachmentService.attach/detach directly (shared global, no resource
--- export needed per this framework's single-Lua-state convention -- see
--- README's "Usage (from another plugin)" section) and then calls this to
--- notify clients. Kept as a named function (not inlined into
--- AttachmentService) so AttachmentService stays pure data-layer and net
--- broadcasting stays here with the rest of this plugin's event wiring.
--- @param row table attachments row
--- @param target Player|number|nil
function PropAttachBroadcast(row, target)
    local point = AttachPointService.find(
        -- The row itself doesn't carry the parent model (only net id), so a
        -- caller wanting a correct bone_index in the broadcast must resolve
        -- the point once at attach time and pass it through `row.data`
        -- internally -- simplest correct approach for v1: re-resolve isn't
        -- possible without the model, so the client instead looks up the
        -- point itself using the propModel/pointName/slotIndex it already
        -- has plus a model string sent alongside (see Step 2's payload).
        row.parent_model or '', row.point_name, row.slot_index)

    Obelisk.emitClient('core:server:propattach-create', target or -1, {
        attachmentId = row.id,
        propModel = row.prop_model,
        parentEntityType = row.parent_entity_type,
        parentNetId = row.parent_net_id,
        pointName = row.point_name,
        slotIndex = row.slot_index,
        boneIndex = point and point.bone_index,
        offset = point and { x = point.offset_x, y = point.offset_y, z = point.offset_z },
        rotation = point and { x = point.rot_x, y = point.rot_y, z = point.rot_z },
    })
end

--- Detach + broadcast in one call -- the pairing every real caller wants.
--- Plugins that only need the row deleted without a client-visible removal
--- (rare) can still call AttachmentService.detach directly.
--- @param attachmentId number
--- @return boolean ok
function PropAttachDetach(attachmentId)
    local ok = AttachmentService.detach(attachmentId)
    if ok then
        Obelisk.emitClient('core:server:propattach-remove', -1, { attachmentId = attachmentId })
    end
    return ok
end

Obelisk.onClient('propattach:server:savePoint', function(player, model, pointName, slotIndex, boneIndex, offset, rotation)
    local characterId = CharacterService and CharacterService.getActiveCharacterId(player:getSource())
    local character = characterId and Character:findSync(characterId)
    if not character or not character:can(PropAttachConfig.EditPermission) then
        notifyFailure(player, 'Cannot save attach point', 'You do not have permission to do that.')
        return
    end

    local id = AttachPointService.upsert(model, pointName, slotIndex or 0, boneIndex, offset, rotation)
    NotificationService.notify(player, {
        type = 'success', title = 'Attach point saved',
        description = model .. ' / ' .. pointName .. ' (#' .. tostring(id) .. ')',
    })
end)

--- Late-joiner snapshot: every currently-live attachment, sent as
--- individual propattach-create events. Attachment count is small, so a
--- flat push (not chunk-scoped like EntityStreamerService) is fine.
---
--- Fired off `core:client:ready` (client emits this from
--- core/client/bootstrap.lua once its resource has actually started and
--- registered its `core:server:propattach-create` handler), not
--- `playerJoining` -- PlayerService creates its Player synchronously during
--- playerJoining, so a poll there resolves immediately, well before the
--- client is actually listening. Obelisk.onClient already resolves the
--- Player for us and drops the event if none exists yet, so no polling is
--- needed here either.
Obelisk.onClient('core:client:ready', function(player)
    for _, row in ipairs(AttachmentService.all()) do
        -- The attachments table has no parent_model column (see README's
        -- "Known limitations" section), so row.parent_model is never set
        -- here -- PropAttachBroadcast already falls back to '' internally.
        PropAttachBroadcast(row, player)
    end
end)

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    PropAttachPermissionSeeder.ensure()
    print('[PropAttach] Loaded successfully!')
end)
