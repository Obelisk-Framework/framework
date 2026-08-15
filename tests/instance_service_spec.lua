-- Run from the repository root:  lua5.4 tests/instance_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

-- Native stubs: fivem_stubs.lua doesn't know about routing-bucket natives.
local bucketCalls = {}
local lastBucketPerSource = {} -- Track the final bucket for each source
function SetPlayerRoutingBucket(source, bucket)
    bucketCalls[#bucketCalls + 1] = { source = source, bucket = bucket }
    lastBucketPerSource[source] = bucket
end
function SetRoutingBucketPopulationEnabled(bucket, enabled) end
function SetRoutingBucketEntityLockdownMode(bucket, mode) end

dofile(ROOT .. '/core/server/Services/InstanceService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    QueryBuilder = makeFakeQueryBuilderModule({})
    bucketCalls = {}
    lastBucketPerSource = {}
    InstanceService.resetForTests()
    fn()
end

test('getOrCreateBucket allocates a new deterministic bucket for a new key', function()
    withFreshState(function()
        local bucketId = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        eq(bucketId, 1001) -- row id 1 + 1000 offset
    end)
end)

test('getOrCreateBucket returns the same bucket for the same key on repeat calls', function()
    withFreshState(function()
        local first = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        local second = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        eq(first, second)
    end)
end)

test('getOrCreateBucket allocates different buckets for different keys', function()
    withFreshState(function()
        local a = InstanceService.getOrCreateBucket('shellbuilder:shell:1')
        local b = InstanceService.getOrCreateBucket('shellbuilder:shell:2')
        eq(a == b, false)
    end)
end)

test('enter moves the player into the key\'s bucket and tracks membership', function()
    withFreshState(function()
        local bucketId = InstanceService.enter(7, 'shellbuilder:shell:1')
        eq(bucketId, 1001)
        -- Verify the player's final bucket is the target bucket (not reset to 0)
        eq(lastBucketPerSource[7], 1001, 'player final bucket should be 1001')

        local players = InstanceService.getPlayersIn('shellbuilder:shell:1')
        eq(#players, 1)
        eq(players[1], 7)
    end)
end)

test('leave moves the player back to bucket 0 and clears membership', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        InstanceService.leave(7)

        -- Verify the player's final bucket is 0 (default overworld bucket)
        eq(lastBucketPerSource[7], 0, 'player final bucket should be 0 after leave')
        eq(#InstanceService.getPlayersIn('shellbuilder:shell:1'), 0)
    end)
end)

test('getPlayersIn reflects multiple players sharing one shell\'s bucket', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        InstanceService.enter(9, 'shellbuilder:shell:1')

        local players = InstanceService.getPlayersIn('shellbuilder:shell:1')
        eq(#players, 2)
    end)
end)

test('getCurrentBucket returns 0 for a source with no active bucket', function()
    withFreshState(function()
        eq(InstanceService.getCurrentBucket(7), 0)
    end)
end)

test('getCurrentBucket returns the active bucket after enter', function()
    withFreshState(function()
        local bucketId = InstanceService.enter(7, 'shellbuilder:shell:1')
        eq(InstanceService.getCurrentBucket(7), bucketId)
    end)
end)

test('getCurrentBucket returns 0 again after leave', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        InstanceService.leave(7)
        eq(InstanceService.getCurrentBucket(7), 0)
    end)
end)

test('getCurrentKey returns nil for a source with no active bucket', function()
    withFreshState(function()
        eq(InstanceService.getCurrentKey(7), nil)
    end)
end)

test('getCurrentKey returns the key a player entered', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        eq(InstanceService.getCurrentKey(7), 'shellbuilder:shell:1')
    end)
end)

test('getCurrentKey returns nil again after leave', function()
    withFreshState(function()
        InstanceService.enter(7, 'shellbuilder:shell:1')
        InstanceService.leave(7)
        eq(InstanceService.getCurrentKey(7), nil)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        failures[#failures + 1] = { name = t.name, err = err }
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures > 0 and 1 or 0)
