local HasItems = dofile('core/server/Traits/HasItems.lua')

local Widget = { table = 'renamed_widgets', primaryKey = 'uuid' }
HasItems.apply(Widget, 'widget')
local function instance(attributes)
    return setmetatable(attributes, { __index = Widget })
end

local owner, reason = instance({ uuid = 'w-42', exists = true, itemOwnerType = 'spoofed' }):itemOwner()
assert(reason == nil)
assert(owner.type == 'widget')
assert(owner.id == 'w-42')

local unsaved, unsavedReason = instance({ uuid = 'w-new', exists = false }):itemOwner()
assert(unsaved == nil)
assert(unsavedReason == 'Item owner must be persisted')

local missingId, missingIdReason = instance({ exists = true }):itemOwner()
assert(missingId == nil)
assert(missingIdReason == 'Item owner has no primary key')

print('HasItems contract: 3/3 passed')
