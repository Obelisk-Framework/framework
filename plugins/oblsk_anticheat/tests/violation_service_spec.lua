-- plugins/oblsk_anticheat/tests/violation_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')
Database.ready = true

dofile(ROOT .. '/plugins/oblsk_anticheat/shared/config.lua')

-- Fakes for everything ViolationService calls but doesn't own.
local notifications, kicks, bans, inserted = {}, {}, {}, {}
_G.NotificationService = {
    error = function(player, title, desc) notifications[#notifications + 1] = {player = player, title = title, desc = desc} end,
}
_G.AccountService = {
    logKick = function(accountId, reason, by) kicks[#kicks + 1] = {accountId = accountId, reason = reason} end,
    ban = function(target, reason, by, expiresAt) bans[#bans + 1] = {accountId = target.accountId, reason = reason} end,
    getAccountId = function(source) return 1000 + source end,
}
-- Player 2 is the one online admin for every test; player 1 (the
-- violating player in every test below) is never an admin.
_G.GetPlayers = function() return {'1', '2'} end
_G.DropPlayer = function() end
_G.IsPlayerAceAllowed = function(source, ace) return ace == 'admin' and source == 2 end
_G.PlayerService = {
    get = function(source)
        local p = {source = source}
        function p:getSource() return self.source end
        return p
    end,
}

Database.executeQuery = function(query, params)
    if query:find('INSERT INTO', 1, true) then
        inserted[#inserted + 1] = params
        return {insertId = #inserted}
    elseif query:find('SELECT', 1, true) and query:find('FROM `anticheat_violations`', 1, true) then
        -- Return every previously inserted row that matches player_id
        -- (params[1] in the caller's COUNT-style query).
        local rows = {}
        for _, p in ipairs(inserted) do
            rows[#rows + 1] = {player_id = p[1]}
        end
        return rows
    end
    return {}
end

local function fakePlayer(source)
    local p = {source = source}
    function p:getSource() return self.source end
    return p
end

dofile(ROOT .. '/plugins/oblsk_anticheat/server/ViolationService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s\n     expected: %s\n     actual:   %s',
            msg or 'assertion failed', tostring(expected), tostring(actual)), 2)
    end
end

test('record() inserts a row and notifies admins on a soft violation', function()
    inserted, notifications, kicks, bans = {}, {}, {}, {}
    local player = fakePlayer(1)

    ViolationService.record(player, 'movement', 'speed 3x max', 'soft')

    eq(#inserted, 1)
    eq(#notifications, 1)
    eq(#kicks, 0)
    eq(#bans, 0)
end)

test('record() kicks immediately on a hard violation', function()
    inserted, notifications, kicks, bans = {}, {}, {}, {}
    local player = fakePlayer(1)

    ViolationService.record(player, 'movement', 'noclip', 'hard')

    eq(#kicks, 1)
    eq(#bans, 0)
end)

test('record() bans once violationsBeforeBan is reached in-window', function()
    inserted, notifications, kicks, bans = {}, {}, {}, {}
    local player = fakePlayer(1)
    Config.Anticheat.violationsBeforeBan = 3

    ViolationService.record(player, 'movement', 'a', 'soft')
    ViolationService.record(player, 'movement', 'b', 'soft')
    ViolationService.record(player, 'movement', 'c', 'soft')

    eq(#bans, 1)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = {name = t.name, err = err} end
end
print(string.format('%d/%d passed', passed, #tests))
for _, f in ipairs(failures) do print('FAIL: ' .. f.name); print('  ' .. tostring(f.err)) end
os.exit(#failures == 0 and 0 or 1)
