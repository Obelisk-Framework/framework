--- Unit tests for InteractionTypeService: registry of plugin-declared
--- interaction types (gasstation, mechanic, ...) consumed by oblsk_admin's
--- generic Interactions tab.
--- Run from the repository root:  lua5.4 tests/interaction_type_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '..'

dofile(scriptDir .. 'support/fivem_stubs.lua')

dofile(ROOT .. '/core/server/Services/InteractionTypeService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

--- Resets InteractionTypeService's module-level state between tests (it's a
--- global singleton, so state would otherwise leak across test cases).
local function withFreshState(fn)
    InteractionTypeService.registry = {}
    fn()
end

local function noop() end

test('register + get: round-trips the full descriptor including function hooks', function()
    withFreshState(function()
        InteractionTypeService.register({
            typeKey = 'gasstation',
            label = 'Gas Station',
            fields = { { key = 'name', label = 'Name', type = 'text', required = true } },
            blipRequirement = 'optional',
            pedRequirement = 'none',
            markerRequirement = 'optional',
            list = noop,
            create = noop,
            update = noop,
            delete = noop,
        })

        local descriptor = InteractionTypeService.get('gasstation')
        eq(descriptor.typeKey, 'gasstation')
        eq(descriptor.label, 'Gas Station')
        eq(descriptor.blipRequirement, 'optional')
        eq(descriptor.pedRequirement, 'none')
        eq(descriptor.markerRequirement, 'optional')
        eq(type(descriptor.list), 'function')
        eq(type(descriptor.create), 'function')
        eq(type(descriptor.update), 'function')
        eq(type(descriptor.delete), 'function')
    end)
end)

test('get: returns nil for an unregistered typeKey', function()
    withFreshState(function()
        eq(InteractionTypeService.get('nope'), nil)
    end)
end)

test('listForAdmin: excludes function fields (list/create/update/delete)', function()
    withFreshState(function()
        InteractionTypeService.register({
            typeKey = 'mechanic',
            label = 'Mechanic Bay',
            fields = { { key = 'name', label = 'Name', type = 'text', required = true } },
            blipRequirement = 'optional',
            pedRequirement = 'optional',
            markerRequirement = 'none',
            list = noop,
            create = noop,
            update = noop,
            delete = noop,
        })

        local types = InteractionTypeService.listForAdmin()
        eq(#types, 1)
        local entry = types[1]
        eq(entry.typeKey, 'mechanic')
        eq(entry.label, 'Mechanic Bay')
        eq(entry.list, nil)
        eq(entry.create, nil)
        eq(entry.update, nil)
        eq(entry.delete, nil)
    end)
end)

test('listForAdmin: returns metadata for every registered type', function()
    withFreshState(function()
        InteractionTypeService.register({ typeKey = 'a', label = 'A', fields = {}, blipRequirement = 'none', pedRequirement = 'none', markerRequirement = 'none', list = noop, create = noop, update = noop, delete = noop })
        InteractionTypeService.register({ typeKey = 'b', label = 'B', fields = {}, blipRequirement = 'none', pedRequirement = 'none', markerRequirement = 'none', list = noop, create = noop, update = noop, delete = noop })

        local types = InteractionTypeService.listForAdmin()
        eq(#types, 2)
    end)
end)

test('register: registering the same typeKey twice overwrites (matches ActionService.register convention)', function()
    withFreshState(function()
        InteractionTypeService.register({ typeKey = 'gasstation', label = 'Gas Station v1', fields = {}, blipRequirement = 'none', pedRequirement = 'none', markerRequirement = 'none', list = noop, create = noop, update = noop, delete = noop })
        InteractionTypeService.register({ typeKey = 'gasstation', label = 'Gas Station v2', fields = {}, blipRequirement = 'none', pedRequirement = 'none', markerRequirement = 'none', list = noop, create = noop, update = noop, delete = noop })

        local types = InteractionTypeService.listForAdmin()
        eq(#types, 1)
        eq(InteractionTypeService.get('gasstation').label, 'Gas Station v2')
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
