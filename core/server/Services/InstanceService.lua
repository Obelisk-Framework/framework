--- InstanceService - generic dimension allocation via FiveM routing buckets.
--- A "key" (any stable string, e.g. "shellbuilder:shell:42") maps
--- deterministically to a bucket id, so every consumer that later resolves
--- the same key lands in the same bucket - no pooled/ephemeral allocation,
--- no free-list bookkeeping. bucket_id is simply the instance_buckets row's
--- own id + OFFSET, kept clear of FiveM's default bucket 0.
InstanceService = {}

local OFFSET = 1000

-- source -> key, so leave() and playerDropped cleanup know which bucket's
-- membership set to remove a player from without the caller repeating it.
local playerBucketKey = {}

-- key -> { [source] = true }, membership per bucket key.
local bucketMembers = {}

--- @param key string
--- @return number bucketId
function InstanceService.getOrCreateBucket(key)
    local existing = InstanceBucket:where('key', key):first()
    if existing then
        return existing.bucket_id
    end

    -- placeholder bucket_id, corrected below once we know our own row id
    local created = InstanceBucket:create({ key = key, bucket_id = 0 })

    local bucketId = created.id + OFFSET
    created:set('bucket_id', bucketId)
    created:save()

    return bucketId
end

--- Private: clears stale membership bookkeeping without resetting the bucket native.
--- Used by enter() before assigning the player to a new bucket.
--- @param player Player
local function clearStaleMembership(player)
    local source = player:getSource()
    local key = playerBucketKey[source]
    if key and bucketMembers[key] then
        bucketMembers[key][source] = nil
    end
    playerBucketKey[source] = nil
end

--- Moves `player` into `key`'s bucket, disabling ambient population/traffic
--- in it the first time this process resolves that key. Records membership
--- so getPlayersIn/leave/playerDropped cleanup can find this player again.
--- @param player Player
--- @param key string
--- @return number bucketId
function InstanceService.enter(player, key)
    local source = player:getSource()
    local bucketId = InstanceService.getOrCreateBucket(key)

    -- Clear any previous membership first, but do NOT call the bucket native yet.
    clearStaleMembership(player)

    -- Set the bucket as the final native call so the player ends up in it.
    SetPlayerRoutingBucket(source, bucketId)
    SetRoutingBucketPopulationEnabled(bucketId, false)
    SetRoutingBucketEntityLockdownMode(bucketId, 'strict')

    -- Now update membership to reflect the new bucket.
    playerBucketKey[source] = key
    bucketMembers[key] = bucketMembers[key] or {}
    bucketMembers[key][source] = true

    return bucketId
end

--- Moves `player` back to the default overworld bucket (0) and clears their
--- membership from whatever key they were previously in, if any.
--- @param player Player
function InstanceService.leave(player)
    clearStaleMembership(player)
    SetPlayerRoutingBucket(player:getSource(), 0)
end

--- @param player Player
--- @return number the bucket id this player is currently tracked in, or 0
function InstanceService.getCurrentBucket(player)
    local key = playerBucketKey[player:getSource()]
    if not key then return 0 end
    return InstanceService.getOrCreateBucket(key)
end

--- @param player Player
--- @return string|nil the key this player is currently tracked as inside
---   (e.g. "shellbuilder:shell:42"), or nil if they're not in any bucket
function InstanceService.getCurrentKey(player)
    return playerBucketKey[player:getSource()]
end

--- @param key string
--- @return number[] every player source currently tracked as inside this key's bucket
function InstanceService.getPlayersIn(key)
    local sources = {}
    for source in pairs(bucketMembers[key] or {}) do
        table.insert(sources, source)
    end
    return sources
end

Obelisk.on('playerDropped', function()
    local player = PlayerService.get(source)
    if player then InstanceService.leave(player) end
end)

--- Test-only: resets module state between spec cases.
function InstanceService.resetForTests()
    playerBucketKey = {}
    bucketMembers = {}
end

return InstanceService
