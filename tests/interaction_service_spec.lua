--- Unit tests for InteractionService's DB-id tracking additions:
--- registerFromDb / unregisterById / updateByDbId / setEnabledByDbId, plus
--- unregister()'s byDbId bookkeeping cleanup.
--- Run from the repository root:  lua5.4 tests/interaction_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

-- InteractionService only needs Obelisk.emitClient (broadcast on
-- register/unregister/update) to load and run -- no ORM/DB dependency in
-- this file at all, so no need to load the ORM stack here.
_G.Obelisk = _G.Obelisk or {}
_G.Obelisk.emitClient = function() end
_G.Obelisk.onClient = function() end

dofile(ROOT .. '/core/server/Services/InteractionService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

--- Resets InteractionService's module-level state between tests (it's a
--- global singleton, so state would otherwise leak across test cases).
local function withFreshState(fn)
    InteractionService.registry = {}
    InteractionService.byDbId = {}
    InteractionService.nextId = 1
    fn()
end

test('registerFromDb: tracks the mapping and tags the registry entry', function()
    withFreshState(function()
        local liveId = InteractionService.registerFromDb(42, { x = 1, y = 2, z = 3, label = 'Pump' })
        eq(InteractionService.registry[liveId].dbInteractionId, 42)
        eq(#InteractionService.byDbId[42], 1)
        eq(InteractionService.byDbId[42][1], liveId)
    end)
end)

test('registerFromDb: one dbId can back multiple live registrations (oblsk_shop case)', function()
    withFreshState(function()
        local liveId1 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1, action = 'shop:open' })
        local liveId2 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1, action = 'shop:crackSafe' })
        eq(#InteractionService.byDbId[7], 2)
        eq(InteractionService.byDbId[7][1], liveId1)
        eq(InteractionService.byDbId[7][2], liveId2)
        eq(InteractionService.registry[liveId1].action, 'shop:open')
        eq(InteractionService.registry[liveId2].action, 'shop:crackSafe')
    end)
end)

test('unregisterById: removes all live registrations tied to dbId', function()
    withFreshState(function()
        local liveId1 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1 })
        local liveId2 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1 })
        InteractionService.unregisterById(7)
        eq(InteractionService.registry[liveId1], nil)
        eq(InteractionService.registry[liveId2], nil)
        eq(InteractionService.byDbId[7], nil)
    end)
end)

test('unregisterById: no-op for an unknown dbId (no crash)', function()
    withFreshState(function()
        InteractionService.unregisterById(999)
        eq(true, true)
    end)
end)

test('updateByDbId: patches every live registration tied to dbId', function()
    withFreshState(function()
        local liveId1 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1, range = 2.0 })
        local liveId2 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1, range = 2.0 })
        InteractionService.updateByDbId(7, { x = 10, y = 20, z = 30, range = 5.0 })
        eq(InteractionService.registry[liveId1].x, 10)
        eq(InteractionService.registry[liveId1].range, 5.0)
        eq(InteractionService.registry[liveId2].x, 10)
        eq(InteractionService.registry[liveId2].range, 5.0)
    end)
end)

test('setEnabledByDbId: fans out enabled/disabled to every tied live registration', function()
    withFreshState(function()
        local liveId1 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1 })
        local liveId2 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1 })
        InteractionService.setEnabledByDbId(7, false)
        eq(InteractionService.registry[liveId1].enabled, false)
        eq(InteractionService.registry[liveId2].enabled, false)
    end)
end)

test('unregistering one of several live ids individually does not break a later unregisterById call', function()
    withFreshState(function()
        local liveId1 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1 })
        local liveId2 = InteractionService.registerFromDb(7, { x = 1, y = 1, z = 1 })

        -- Direct unregister() on just one of the two, bypassing unregisterById.
        InteractionService.unregister(liveId1)
        eq(InteractionService.registry[liveId1], nil)
        eq(#InteractionService.byDbId[7], 1)
        eq(InteractionService.byDbId[7][1], liveId2)

        -- A later unregisterById call must not double-free or crash on the
        -- already-removed liveId1, and must still clean up liveId2.
        local ok = pcall(InteractionService.unregisterById, 7)
        eq(ok, true)
        eq(InteractionService.registry[liveId2], nil)
        eq(InteractionService.byDbId[7], nil)
    end)
end)

test('unregister: plain (non-DB) registrations are unaffected by byDbId bookkeeping', function()
    withFreshState(function()
        local liveId = InteractionService.register({ x = 1, y = 1, z = 1 })
        InteractionService.unregister(liveId)
        eq(InteractionService.registry[liveId], nil)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
