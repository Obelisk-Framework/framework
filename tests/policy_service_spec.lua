--- Unit tests for PolicyService: policy registration and the
--- attach/detach/getPolicies pivot-model CRUD (ActionPolicy/InteractionPolicy).
--- Run from the repository root: lua5.4 tests/policy_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(ROOT .. '/core/server/Models/ActionPolicy.lua')
dofile(ROOT .. '/core/server/Models/InteractionPolicy.lua')
dofile(ROOT .. '/core/server/Services/PolicyService.lua')

local makeFakeQueryBuilderModule = dofile(scriptDir .. 'support/fake_query_builder.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, msg)
    if not v then error(msg or 'expected a truthy value', 2) end
end

local function falsy(v, msg)
    if v then error(msg or 'expected a falsy value', 2) end
end

local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local originalRegistry = PolicyService.registry
    PolicyService.registry = {}

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    PolicyService.registry = originalRegistry
    if not ok then error(err, 2) end
end

test('attach: fails when the policy was never registered', function()
    withFakeDb(function(tables)
        local ok = PolicyService.attach('action', 'refill_shops', 'nope', {})
        eq(ok, false)
        eq(tables.action_policy, nil)
    end)
end)

test('attach: inserts one action_policy row on first attach', function()
    withFakeDb(function(tables)
        PolicyService.register('is_admin', function() return true end)
        local ok = PolicyService.attach('action', 'refill_shops', 'is_admin', { level = 2 })
        truthy(ok)
        eq(#tables.action_policy, 1)
        eq(tables.action_policy[1].action_id, 'refill_shops')
        eq(tables.action_policy[1].policy_id, 'is_admin')
    end)
end)

test('attach: attaching the same policy twice updates the existing row, not a new one', function()
    withFakeDb(function(tables)
        PolicyService.register('is_admin', function() return true end)
        PolicyService.attach('action', 'refill_shops', 'is_admin', { level = 1 })
        PolicyService.attach('action', 'refill_shops', 'is_admin', { level = 5 })
        eq(#tables.action_policy, 1)

        local policies = PolicyService.getPolicies('action', 'refill_shops')
        eq(#policies, 1)
        eq(policies[1].config.level, 5)
    end)
end)

test('attach: interaction resource type writes to interaction_policy, not action_policy', function()
    withFakeDb(function(tables)
        PolicyService.register('within_distance', function() return true end)
        PolicyService.attach('interaction', 42, 'within_distance', { range = 3 })
        eq(tables.action_policy, nil)
        eq(#tables.interaction_policy, 1)
        eq(tables.interaction_policy[1].interaction_id, 42)
    end)
end)

test('attach: an unknown resource type raises', function()
    withFakeDb(function()
        PolicyService.register('is_admin', function() return true end)
        local ok, err = pcall(function()
            PolicyService.attach('bogus', 1, 'is_admin', {})
        end)
        falsy(ok)
        truthy(tostring(err):find('invalid resource type'))
    end)
end)

test('getPolicies: returns policyId + decoded config for every attached policy', function()
    withFakeDb(function()
        PolicyService.register('is_admin', function() return true end)
        PolicyService.register('cooldown', function() return true end)
        PolicyService.attach('action', 'refill_shops', 'is_admin', { level = 2 })
        PolicyService.attach('action', 'refill_shops', 'cooldown', { seconds = 30 })

        local policies = PolicyService.getPolicies('action', 'refill_shops')
        eq(#policies, 2)

        local byId = {}
        for _, p in ipairs(policies) do byId[p.policyId] = p.config end
        eq(byId.is_admin.level, 2)
        eq(byId.cooldown.seconds, 30)
    end)
end)

test('getPolicies: returns an empty table when nothing is attached', function()
    withFakeDb(function()
        eq(#PolicyService.getPolicies('action', 'no_policies_here'), 0)
    end)
end)

test('detach: a specific policyId removes only that row', function()
    withFakeDb(function(tables)
        PolicyService.register('is_admin', function() return true end)
        PolicyService.register('cooldown', function() return true end)
        PolicyService.attach('action', 'refill_shops', 'is_admin', {})
        PolicyService.attach('action', 'refill_shops', 'cooldown', {})

        PolicyService.detach('action', 'refill_shops', 'is_admin')

        eq(#tables.action_policy, 1)
        eq(tables.action_policy[1].policy_id, 'cooldown')
    end)
end)

test('detach: no policyId removes every attachment for that resource', function()
    withFakeDb(function(tables)
        PolicyService.register('is_admin', function() return true end)
        PolicyService.register('cooldown', function() return true end)
        PolicyService.attach('action', 'refill_shops', 'is_admin', {})
        PolicyService.attach('action', 'refill_shops', 'cooldown', {})
        PolicyService.attach('action', 'other_action', 'is_admin', {})

        PolicyService.detach('action', 'refill_shops')

        eq(#tables.action_policy, 1)
        eq(tables.action_policy[1].action_id, 'other_action')
    end)
end)

test('check: allows by default when no policies are attached', function()
    withFakeDb(function()
        local called, allowed = false, nil
        PolicyService.check({ getSource = function() return 1 end }, 'action', 'refill_shops', function(ok)
            called, allowed = true, ok
        end)
        truthy(called)
        eq(allowed, true)
    end)
end)

test('check: denies when an attached policy validator returns false', function()
    withFakeDb(function()
        PolicyService.register('always_deny', function() return false, 'nope' end)
        PolicyService.attach('action', 'refill_shops', 'always_deny', {})

        local allowed, reason
        PolicyService.check({ getSource = function() return 1 end }, 'action', 'refill_shops', function(ok, r)
            allowed, reason = ok, r
        end)
        eq(allowed, false)
        eq(reason, 'nope')
    end)
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running PolicyService unit tests\n')
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  ok   - ' .. t.name)
    else
        failures[#failures + 1] = t.name
        print('  FAIL - ' .. t.name)
        print('         ' .. tostring(err):gsub('\n', '\n         '))
    end
end

print(string.format('\n%d passed, %d failed', passed, #failures))
os.exit(#failures == 0 and 0 or 1)
