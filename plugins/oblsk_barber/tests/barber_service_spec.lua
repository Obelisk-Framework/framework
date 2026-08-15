-- plugins/oblsk_barber/tests/barber_service_spec.lua
-- Run from the repository root: lua5.4 plugins/oblsk_barber/tests/barber_service_spec.lua

local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'
local CHAR_MODULE = scriptDir .. '../../../modules/oblsk_characters'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/shared/Obelisk.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(ROOT .. '/core/server/ORM/Schema.lua')
dofile(ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(ROOT .. '/core/server/Services/PermissionService.lua')
dofile(ROOT .. '/core/server/Traits/HasPermissions.lua')
dofile(CHAR_MODULE .. '/server/models/Character.lua')
dofile(CHAR_MODULE .. '/server/models/CharacterAppearance.lua')

local makeFakeQueryBuilderModule = dofile(CHAR_MODULE .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- ItemService/BankingService/CharacterService stubs, same shape
-- terminal_service_spec.lua uses.
ITEM_HAS_CASH = true
ItemService = {}
function ItemService.binding(key)
    if key == 'currency.cash' then return { id = 1 } end
    return nil
end
LAST_CASH_REMOVED = nil
function ItemService.has(source, item, amount) return ITEM_HAS_CASH end
function ItemService.remove(source, item, amount)
    LAST_CASH_REMOVED = amount
    return ITEM_HAS_CASH, ITEM_HAS_CASH and nil or 'Not enough cash'
end

BANKING_CHARGE_RESULT = { ok = true }
BankingService = {}
function BankingService.charge(source, cardId, amount, description)
    return BANKING_CHARGE_RESULT.ok, BANKING_CHARGE_RESULT.reason
end

CharacterService = {}
function CharacterService.getActiveCharacterId(source)
    if source == 1 then return 100 end
    return nil
end

dofile(scriptDir .. '../server/services/BarberService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s', msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end
local function truthy(v, msg) if not v then error(msg or 'expected a truthy value', 2) end end

local function withFakeDb(fn)
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule({
        character_appearances = { { id = 1, character_id = 100, ped_model = 'mp_m_freemode_01', data = json.encode({ hairStyle = 0 }) } },
    })
    ITEM_HAS_CASH = true
    BANKING_CHARGE_RESULT = { ok = true }
    local ok, err = pcall(fn)
    QueryBuilder = original
    if not ok then error(err, 2) end
end

test('priceFor returns the configured price for hair and for a non-hair section', function()
    eq(BarberService.priceFor('hair'), Config.HairPrice)
    eq(BarberService.priceFor('beard'), 70)
end)

test('priceFor returns nil for an unknown section id', function()
    eq(BarberService.priceFor('not-a-section'), nil)
end)

test('total sums only the touched sections, ignoring unknown ids', function()
    local total = BarberService.total({ 'hair', 'beard', 'not-a-section' })
    eq(total, Config.HairPrice + 70)
end)

test('total is 0 for an empty selection', function()
    eq(BarberService.total({}), 0)
end)

test('charge rejects an empty selection', function()
    withFakeDb(function()
        local ok, reason = BarberService.charge(1, {}, 'cash', nil)
        eq(ok, false)
        eq(reason, 'Nothing to charge')
    end)
end)

test('charge succeeds via cash and removes the right amount', function()
    withFakeDb(function()
        local ok, total = BarberService.charge(1, { 'hair', 'beard' }, 'cash', nil)
        eq(ok, true)
        eq(total, Config.HairPrice + 70)
    end)
end)

test('charge fails via cash when the player does not have enough', function()
    withFakeDb(function()
        ITEM_HAS_CASH = false
        local ok, reason = BarberService.charge(1, { 'hair' }, 'cash', nil)
        eq(ok, false)
        eq(reason, 'Not enough cash')
    end)
end)

test('charge succeeds via card', function()
    withFakeDb(function()
        local ok, total = BarberService.charge(1, { 'hair' }, 'card', 42)
        eq(ok, true)
        eq(total, Config.HairPrice)
    end)
end)

test('charge fails via card when BankingService.charge declines', function()
    withFakeDb(function()
        BANKING_CHARGE_RESULT = { ok = false, reason = 'Card declined' }
        local ok, reason = BarberService.charge(1, { 'hair' }, 'card', 42)
        eq(ok, false)
        eq(reason, 'Card declined')
    end)
end)

test('charge rejects an unknown payment method', function()
    withFakeDb(function()
        local ok, reason = BarberService.charge(1, { 'hair' }, 'crypto', nil)
        eq(ok, false)
        eq(reason, 'Unknown payment method')
    end)
end)

test('charge applies the clipper minigame quality multiplier to the total charged', function()
    withFakeDb(function()
        local ok = BarberService.charge(1, { 'hair' }, 'cash', nil, 0.7)
        eq(ok, true)
        eq(LAST_CASH_REMOVED, math.floor(Config.HairPrice * 0.7 + 0.5), 'the discounted amount should be removed, not the full price')
    end)
end)

test('charge clamps an out-of-range multiplier to the valid floor (0.45)', function()
    withFakeDb(function()
        local ok = BarberService.charge(1, { 'hair' }, 'cash', nil, 0.1)
        eq(ok, true)
        eq(LAST_CASH_REMOVED, math.floor(Config.HairPrice * 0.45 + 0.5), 'a below-floor multiplier should clamp to 0.45, not pass through as 0.1')
    end)
end)

test('applyAndPersist merges the given keys into the existing appearance row', function()
    withFakeDb(function()
        local ok, resolved = BarberService.applyAndPersist(1, 'male', { hairStyle = 12, hairColor = 3 })
        eq(ok, true)
        eq(resolved.hairStyle, 12)
        eq(resolved.hairColor, 3)
    end)
end)

test('applyAndPersist fails when the source has no active character', function()
    withFakeDb(function()
        local ok, reason = BarberService.applyAndPersist(999, 'male', { hairStyle = 12 })
        eq(ok, false)
        eq(reason, 'No active character')
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
