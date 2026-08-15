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
    local existing = QueryBuilder.new('instance_buckets'):where('key', key):firstSync()
    if existing then
        return existing.bucket_id
    end

    local id = QueryBuilder.new('instance_buckets'):insert({
        key = key,
        bucket_id = 0, -- placeholder, corrected below once we know our own row id
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    local bucketId = id + OFFSET
    QueryBuilder.new('instance_buckets'):where('id', id):update({ bucket_id = bucketId })

    return bucketId
end

--- Moves `source` into `key`'s bucket, disabling ambient population/traffic
--- in it the first time this process resolves that key. Records membership
--- so getPlayersIn/leave/playerDropped cleanup can find this player again.
--- @param source number
--- @param key string
--- @return number bucketId
function InstanceService.enter(source, key)
    local bucketId = InstanceService.getOrCreateBucket(key)

    SetPlayerRoutingBucket(source, bucketId)
    SetRoutingBucketPopulationEnabled(bucketId, false)
    SetRoutingBucketEntityLockdownMode(bucketId, 'strict')

    InstanceService.leave(source) -- clear any previous membership first
    playerBucketKey[source] = key
    bucketMembers[key] = bucketMembers[key] or {}
    bucketMembers[key][source] = true

    return bucketId
end

--- Moves `source` back to the default overworld bucket (0) and clears their
--- membership from whatever key they were previously in, if any.
--- @param source number
function InstanceService.leave(source)
    local key = playerBucketKey[source]
    if key and bucketMembers[key] then
        bucketMembers[key][source] = nil
    end
    playerBucketKey[source] = nil

    SetPlayerRoutingBucket(source, 0)
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

AddEventHandler('playerDropped', function()
    InstanceService.leave(source)
end)

--- Test-only: resets module state between spec cases.
function InstanceService.resetForTests()
    playerBucketKey = {}
    bucketMembers = {}
end

return InstanceService
