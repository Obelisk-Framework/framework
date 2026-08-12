# Accounts Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `oblsk_accounts` module: an `Account`/`AccountIdentifier` catalog that resolves every connecting player to a stable account reachable through any identifier it has ever used, a `Ban` model that can target either an account or a bare identifier, and a `playerConnecting` hook that resolves identity and rejects banned/unresolvable connections before the player spawns.

**Architecture:** See `docs/superpowers/specs/2026-08-10-accounts-module-design.md` for full rationale. This module needs no core-side fixes, everything it depends on (`BaseModel`, `QueryBuilder`, `Schema`, `Database.now()`) already exists and is unmodified. Every task lives in the separate `oblsk_accounts` repository.

**Tech Stack:** Lua (FXServer `server_scripts` only, no client side), the existing ORM (`BaseModel`/`QueryBuilder`/`Schema`), `lua5.4` for the pure-logic unit tests.

## Global Constraints

- `oblsk_accounts` is a **separate git repository** (`core/modules/oblsk_accounts/`), freshly `git init`'d, no remote yet, no commits. Work directly on `master`, no worktree, same reasoning already used for `oblsk_items`/`oblsk_vehicles`: nothing exists yet to protect.
- No FXServer runtime exists in this repo's test environment. Anything touching real natives or FXServer-only globals (`GetPlayerIdentifiers`, `AddEventHandler('playerConnecting', ...)`, `deferrals`, `RegisterCommand`, `IsPlayerAceAllowed`, `DropPlayer`) gets manual verification only (syntax checks via `luac5.4 -p` or an equivalent parse check), matching the existing convention (see the Vehicle module plan's Global Constraints for precedent). Pure Lua logic (`AccountService`'s identifier parsing, account resolution, ban matching) gets real unit tests against a fake in-memory `QueryBuilder`, no live database needed.
- `license` is the one identifier every check treats as required and authoritative. A secondary identifier (discord, steam, ip, ...) already linked to a *different* account is logged as a conflict and never causes an account merge, anywhere in this module.
- Exactly one of `bans.account_id` or the `bans.identifier_type`/`identifier_value` pair is set per row; this is an application-level invariant (`AccountService.ban`'s two call shapes), not DB-enforced.
- No Claude co-authorship in any commit.
- Minimize em/en dashes in prose (project owner's stated preference); applies to commit messages and docs prose, not code/SQL.

---

## Task 1: Module scaffold and full schema

**Repository:** `oblsk_accounts`, working directly on `master`.

**Files:**
- Create: `README.md`
- Create: `server/migrations/2026_08_10_090621_create_accounts_table.lua`
- Create: `server/migrations/2026_08_10_090622_create_account_identifiers_table.lua`
- Create: `server/migrations/2026_08_10_090623_create_bans_table.lua`
- Create: `server/migrations.json`

**Interfaces:**
- Produces: the `accounts`, `account_identifiers`, `bans` tables. Every later task depends on these existing.

- [ ] **Step 1: Write the `accounts` migration**

```lua
--- Migration: Create accounts table
return {
    up = function()
        Schema.create('accounts', function(table)
            table:id()
            table:timestamps()
        end)

        print('[Migration] Created accounts table')
    end,

    down = function()
        Schema.drop('accounts')
        print('[Migration] Dropped accounts table')
    end
}
```

Save to `server/migrations/2026_08_10_090621_create_accounts_table.lua`.

- [ ] **Step 2: Write the `account_identifiers` migration**

```lua
--- Migration: Create account_identifiers table
return {
    up = function()
        Schema.create('account_identifiers', function(table)
            table:id()
            table:integer('account_id'):notNullable()
            table:string('type', 50):notNullable()
            table:string('value', 255):notNullable()
            table:timestamps()

            table:unique({'type', 'value'})
            table:index({'account_id'})
            table:foreign('account_id'):references('id'):on('accounts'):onDelete('CASCADE')
        end)

        print('[Migration] Created account_identifiers table')
    end,

    down = function()
        Schema.drop('account_identifiers')
        print('[Migration] Dropped account_identifiers table')
    end
}
```

Save to `server/migrations/2026_08_10_090622_create_account_identifiers_table.lua`.

`unique({'type', 'value'})` is the load-bearing constraint here: one identifier value can only ever belong to one account, this is what makes `AccountService.findOrCreateAccount`'s conflict detection meaningful rather than racy.

- [ ] **Step 3: Write the `bans` migration**

```lua
--- Migration: Create bans table
return {
    up = function()
        Schema.create('bans', function(table)
            table:id()
            table:integer('account_id')
            table:string('identifier_type', 50)
            table:string('identifier_value', 255)
            table:text('reason'):notNullable()
            table:string('issued_by', 255):notNullable()
            table:datetime('expires_at')
            table:datetime('revoked_at')
            table:timestamps()

            table:index({'account_id'})
            table:index({'identifier_type', 'identifier_value'})
            table:foreign('account_id'):references('id'):on('accounts'):onDelete('CASCADE')
        end)

        print('[Migration] Created bans table')
    end,

    down = function()
        Schema.drop('bans')
        print('[Migration] Dropped bans table')
    end
}
```

Save to `server/migrations/2026_08_10_090623_create_bans_table.lua`.

`account_id`, `identifier_type`, `identifier_value`, `expires_at`, `revoked_at` are all nullable (Schema's default for every column type except `id()`), matching the design's "exactly one of account_id or the identifier pair is set, never both" invariant, enforced in `AccountService.ban`, not here.

- [ ] **Step 4: Write `server/migrations.json`**

```json
{
  "migrations": [
    "2026_08_10_090621_create_accounts_table",
    "2026_08_10_090622_create_account_identifiers_table",
    "2026_08_10_090623_create_bans_table"
  ]
}
```

- [ ] **Step 5: Write `README.md`**

```markdown
# Oblsk_accounts Module

## Description
Resolves every connecting player to a stable Account reachable through any
identifier it has ever used (license, discord, steam, fivem, ip, ...), and
gates connections against active bans before the player spawns.

## Installation
This module loads as part of the `core` resource. After adding it under
`modules/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).

## Usage
Other modules read the current player's account via `AccountService.getAccountId(source)`.
```

- [ ] **Step 6: Verify all three migration files parse**

Run: `luac5.4 -p server/migrations/2026_08_10_090621_create_accounts_table.lua server/migrations/2026_08_10_090622_create_account_identifiers_table.lua server/migrations/2026_08_10_090623_create_bans_table.lua`

Expected: no output, exit code 0 (a Lua syntax check; it doesn't execute `Schema.create`, which needs the ORM loaded, but confirms the file itself is valid Lua).

- [ ] **Step 7: Commit**

```bash
git add README.md server/migrations server/migrations.json
git commit -m "feat: add accounts, account_identifiers, bans schema"
```

---

## Task 2: Models

**Files:**
- Create: `server/models/Account.lua`
- Create: `server/models/AccountIdentifier.lua`
- Create: `server/models/Ban.lua`

**Interfaces:**
- Consumes: `BaseModel:extend(tableName)` from core's ORM (already merged, unmodified).
- Produces: `Account`, `AccountIdentifier`, `Ban` globals. Task 3's `AccountService` and its tests load and use all three directly.

No dedicated test file for this task: these three files are declarations only (table name, fillable list, one `belongsTo` relation each), the same as `FuelType`/`BaseVehicle` in the Vehicle module, which also shipped without a model-specific spec file (a test that only asserts a model loaded without checking any behavior is a test that asserts nothing, see the Vehicle module plan's precedent). Task 3's spec file loads these three models directly and exercises them through `AccountService`, which is real coverage of their actual behavior (`createSync`, the `belongsTo` relation isn't exercised there but has no logic of its own beyond what `BaseModel:belongsTo` already provides and tests elsewhere in core).

- [ ] **Step 1: Write `Account.lua`**

```lua
--- Account Model - the stable identity every login identifier resolves to.
--- Deliberately bare: nothing identifying lives here directly, that's what
--- AccountIdentifier is for. See
--- docs/superpowers/specs/2026-08-10-accounts-module-design.md.
Account = BaseModel:extend('accounts')

Account.primaryKey = 'id'
Account.timestamps = true
Account.fillable = {}
Account.hidden = {}

return Account
```

- [ ] **Step 2: Write `AccountIdentifier.lua`**

```lua
--- AccountIdentifier Model - one login identifier (license, discord, steam,
--- ip, ...) linked to an Account. unique(type, value) at the DB level: one
--- identifier value can only ever belong to one account.
AccountIdentifier = BaseModel:extend('account_identifiers')

AccountIdentifier.primaryKey = 'id'
AccountIdentifier.timestamps = true
AccountIdentifier.fillable = { 'account_id', 'type', 'value' }
AccountIdentifier.hidden = {}

function AccountIdentifier:accountRelation()
    return self:belongsTo(Account, 'account_id', 'id')
end

return AccountIdentifier
```

- [ ] **Step 3: Write `Ban.lua`**

```lua
--- Ban Model - targets either an Account (account_id) or a bare identifier
--- (identifier_type/identifier_value), never both. See the design spec's
--- Schema section for the invariant; not DB-enforced.
Ban = BaseModel:extend('bans')

Ban.primaryKey = 'id'
Ban.timestamps = true
Ban.fillable = { 'account_id', 'identifier_type', 'identifier_value', 'reason', 'issued_by', 'expires_at', 'revoked_at' }
Ban.hidden = {}

function Ban:accountRelation()
    return self:belongsTo(Account, 'account_id', 'id')
end

return Ban
```

- [ ] **Step 4: Verify all three files parse**

Run: `luac5.4 -p server/models/Account.lua server/models/AccountIdentifier.lua server/models/Ban.lua`

Expected: no output, exit code 0. (`BaseModel` isn't defined in this check, since these files reference the global `BaseModel` set up by core at runtime; a pure syntax check doesn't need it. Task 3's spec file is what actually loads them against real `BaseModel`.)

- [ ] **Step 5: Commit**

```bash
git add server/models
git commit -m "feat: add Account, AccountIdentifier, Ban models"
```

---

## Task 3: AccountService

**Files:**
- Create: `server/services/AccountService.lua`
- Create: `tests/support/fake_query_builder.lua`
- Create: `tests/account_service_spec.lua`

**Interfaces:**
- Consumes: `Account`, `AccountIdentifier`, `Ban` (Task 2), `QueryBuilder.new(tableName)` and `Database.now()` from core's ORM.
- Produces: `AccountService.parseIdentifiers(rawIdentifiers)`, `AccountService.findOrCreateAccount(identifiers)` returning `(accountId, conflicts, err)`, `AccountService.checkBan(accountId, identifiers)` returning a ban row or `nil`, `AccountService.ban(target, reason, issuedBy, expiresAt)`, `AccountService.unban(banId)`, `AccountService.formatBanMessage(ban)`, `AccountService.sessionAccounts` (table, `source -> accountId`), `AccountService.getAccountId(source)`. Task 4 (the connect hook) and Task 5 (admin commands) call every one of these.

- [ ] **Step 1: Write the fake QueryBuilder test support**

`AccountService` and the models it drives only ever call `.new(tableName)`, `:where(column, value)`, `:whereNull(column)`, `:firstSync()`, `:getSync()`, `:insert(data)`, `:update(data)`. This fake implements exactly that surface against plain in-memory Lua tables, so the tests below never touch a real database or parse generated SQL (the real `QueryBuilder`'s SQL generation already has its own coverage elsewhere in core).

```lua
--- A fake QueryBuilder.new that operates on in-memory Lua tables instead of
--- real SQL. See tests/account_service_spec.lua for how this is swapped in
--- for the real global QueryBuilder around each test.
local FakeQueryBuilder = {}
FakeQueryBuilder.__index = FakeQueryBuilder

local function rowMatches(row, wheres, whereNulls)
    for _, w in ipairs(wheres) do
        if row[w.column] ~= w.value then return false end
    end
    for _, col in ipairs(whereNulls) do
        if row[col] ~= nil then return false end
    end
    return true
end

function FakeQueryBuilder:where(column, a, b)
    -- Real QueryBuilder:where supports (column, value) and (column, operator,
    -- value); AccountService only ever uses equality, so collapse both call
    -- shapes to that.
    local value = b ~= nil and b or a
    table.insert(self.wheres, { column = column, value = value })
    return self
end

function FakeQueryBuilder:whereNull(column)
    table.insert(self.whereNulls, column)
    return self
end

function FakeQueryBuilder:firstSync()
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            return row
        end
    end
    return nil
end

function FakeQueryBuilder:getSync()
    local results = {}
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            table.insert(results, row)
        end
    end
    return results
end

function FakeQueryBuilder:insert(data)
    self.nextIds[self.tableName] = (self.nextIds[self.tableName] or 0) + 1
    local id = self.nextIds[self.tableName]
    local row = { id = id }
    for k, v in pairs(data) do row[k] = v end
    table.insert(self.rows, row)
    return id
end

function FakeQueryBuilder:update(data)
    local affected = 0
    for _, row in ipairs(self.rows) do
        if rowMatches(row, self.wheres, self.whereNulls) then
            for k, v in pairs(data) do row[k] = v end
            affected = affected + 1
        end
    end
    return affected
end

--- @param tables table tableName -> array of row tables (shared, mutated in place across calls)
--- @return table a QueryBuilder-shaped module (has .new(tableName))
local function makeFakeQueryBuilderModule(tables)
    local nextIds = {}
    local Module = {}
    function Module.new(tableName)
        tables[tableName] = tables[tableName] or {}
        return setmetatable({
            tableName = tableName,
            rows = tables[tableName],
            nextIds = nextIds,
            wheres = {},
            whereNulls = {},
        }, FakeQueryBuilder)
    end
    return Module
end

return makeFakeQueryBuilderModule
```

Save to `tests/support/fake_query_builder.lua`.

- [ ] **Step 2: Write `AccountService.lua`**

```lua
--- AccountService (server) - resolves every connecting player to a stable
--- Account reachable through any identifier it has ever used, and checks
--- active bans before the player spawns. See
--- docs/superpowers/specs/2026-08-10-accounts-module-design.md.
AccountService = {}
AccountService.sessionAccounts = {} -- source -> account_id, runtime only, set in playerConnecting, cleared in playerDropped

local function findIdentifier(identifiers, targetType)
    for _, identifier in ipairs(identifiers) do
        if identifier.type == targetType then
            return identifier
        end
    end
    return nil
end

--- Parses FXServer's GetPlayerIdentifiers(source) output ("type:value"
--- strings) into { type, value } pairs. Splits on the FIRST ':' only, since
--- some identifier values can contain their own ':'.
--- @param rawIdentifiers table|nil
--- @return table[] entries shaped { type = string, value = string }
function AccountService.parseIdentifiers(rawIdentifiers)
    local identifiers = {}
    for _, raw in ipairs(rawIdentifiers or {}) do
        local sep = raw:find(':')
        if sep then
            table.insert(identifiers, { type = raw:sub(1, sep - 1), value = raw:sub(sep + 1) })
        end
    end
    return identifiers
end

--- Resolves the account for this connection's identifiers, creating one if
--- the license identifier has never been seen. Every other identifier gets
--- linked if new, touched (last-seen) if already linked to this same
--- account, or reported as a conflict (never merged) if linked to a
--- different account.
--- @param identifiers table[] from parseIdentifiers
--- @return number|nil accountId
--- @return table[]|nil conflicts entries shaped { type, value, expectedAccountId, actualAccountId }
--- @return string|nil err set only when accountId is nil
function AccountService.findOrCreateAccount(identifiers)
    local license = findIdentifier(identifiers, 'license')
    if not license then
        return nil, nil, 'missing license identifier'
    end

    local accountId
    local existing = QueryBuilder.new('account_identifiers')
        :where('type', 'license'):where('value', license.value):firstSync()

    if existing then
        accountId = existing.account_id
    else
        local account = Account:createSync({})
        accountId = account.attributes.id
        AccountIdentifier:createSync({ account_id = accountId, type = 'license', value = license.value })
    end

    local conflicts = {}
    for _, identifier in ipairs(identifiers) do
        if identifier.type ~= 'license' then
            local row = QueryBuilder.new('account_identifiers')
                :where('type', identifier.type):where('value', identifier.value):firstSync()

            if not row then
                AccountIdentifier:createSync({ account_id = accountId, type = identifier.type, value = identifier.value })
            elseif row.account_id == accountId then
                QueryBuilder.new('account_identifiers'):where('id', row.id):update({ updated_at = Database.now() })
            else
                table.insert(conflicts, {
                    type = identifier.type,
                    value = identifier.value,
                    expectedAccountId = accountId,
                    actualAccountId = row.account_id,
                })
            end
        end
    end

    return accountId, conflicts
end

--- Returns the first active (not revoked, not expired) ban matching either
--- accountId or any of the raw identifiers on this connection.
--- @param accountId number|nil
--- @param identifiers table[] from parseIdentifiers
--- @return table|nil ban row
function AccountService.checkBan(accountId, identifiers)
    local now = Database.now()

    local function isActive(ban)
        return ban ~= nil and (ban.expires_at == nil or ban.expires_at > now)
    end

    if accountId then
        local ban = QueryBuilder.new('bans')
            :where('account_id', accountId):whereNull('revoked_at'):firstSync()
        if isActive(ban) then
            return ban
        end
    end

    for _, identifier in ipairs(identifiers) do
        local ban = QueryBuilder.new('bans')
            :where('identifier_type', identifier.type)
            :where('identifier_value', identifier.value)
            :whereNull('revoked_at')
            :firstSync()
        if isActive(ban) then
            return ban
        end
    end

    return nil
end

--- @param target table either { accountId = number } or { type = string, value = string }
--- @param reason string
--- @param issuedBy string
--- @param expiresAt string|nil datetime string, nil = permanent
--- @return Ban
function AccountService.ban(target, reason, issuedBy, expiresAt)
    local attributes = { reason = reason, issued_by = issuedBy, expires_at = expiresAt }
    if target.accountId then
        attributes.account_id = target.accountId
    else
        attributes.identifier_type = target.type
        attributes.identifier_value = target.value
    end
    return Ban:createSync(attributes)
end

--- @param banId number
function AccountService.unban(banId)
    return QueryBuilder.new('bans'):where('id', banId):update({ revoked_at = Database.now() })
end

--- @param ban table a bans row (from checkBan)
--- @return string
function AccountService.formatBanMessage(ban)
    if ban.expires_at then
        return 'Banned: ' .. ban.reason .. ' (expires ' .. ban.expires_at .. ')'
    end
    return 'Banned: ' .. ban.reason .. ' (permanent)'
end

--- @param source number
--- @return number|nil
function AccountService.getAccountId(source)
    return AccountService.sessionAccounts[source]
end

return AccountService
```

Save to `server/services/AccountService.lua`.

- [ ] **Step 3: Write `tests/account_service_spec.lua`**

```lua
--- Unit tests for AccountService: identifier parsing, account resolution
--- (license-wins, conflict-not-merge), ban matching/creation/revocation.
--- Run from the repository root:  lua5.4 tests/account_service_spec.lua
---
--- CORE_ROOT is a relative walk-up from this file to the core repo root.
--- oblsk_accounts must live at <core-root>/modules/oblsk_accounts/ for
--- FXServer to load it as part of core at all, so this file is always
--- three levels below the core root (tests/ -> oblsk_accounts/ -> modules/
--- -> core-root).
local scriptDir = arg[0]:match('(.*/)') or './'
local CORE_ROOT = scriptDir .. '../../..'

dofile(CORE_ROOT .. '/tests/support/fivem_stubs.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Database.lua')
dofile(CORE_ROOT .. '/core/server/ORM/QueryBuilder.lua')
dofile(CORE_ROOT .. '/core/server/ORM/Schema.lua')
dofile(CORE_ROOT .. '/core/server/ORM/BaseModel.lua')
dofile(scriptDir .. '../server/models/Account.lua')
dofile(scriptDir .. '../server/models/AccountIdentifier.lua')
dofile(scriptDir .. '../server/models/Ban.lua')
dofile(scriptDir .. '../server/services/AccountService.lua')

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

--- Swaps the real global QueryBuilder for the fake for the duration of fn,
--- so AccountService (and the Account/AccountIdentifier/Ban models it
--- drives via BaseModel:newQuery, which reads the global QueryBuilder at
--- call time) operate on a fresh in-memory table set per test.
local function withFakeDb(fn)
    local tables = {}
    local original = QueryBuilder
    QueryBuilder = makeFakeQueryBuilderModule(tables)

    local ok, err = pcall(fn, tables)

    QueryBuilder = original
    if not ok then error(err, 2) end
end

--------------------------------------------------------------------------------
-- parseIdentifiers
--------------------------------------------------------------------------------

test('parseIdentifiers: splits type:value pairs', function()
    local identifiers = AccountService.parseIdentifiers({ 'license:abc123', 'discord:998877', 'ip:127.0.0.1' })
    eq(#identifiers, 3)
    eq(identifiers[1].type, 'license')
    eq(identifiers[1].value, 'abc123')
    eq(identifiers[3].type, 'ip')
    eq(identifiers[3].value, '127.0.0.1')
end)

test('parseIdentifiers: an empty or nil list returns an empty table', function()
    eq(#AccountService.parseIdentifiers({}), 0)
    eq(#AccountService.parseIdentifiers(nil), 0)
end)

test('parseIdentifiers: ignores malformed entries with no colon', function()
    local identifiers = AccountService.parseIdentifiers({ 'garbage', 'license:abc' })
    eq(#identifiers, 1)
    eq(identifiers[1].type, 'license')
end)

--------------------------------------------------------------------------------
-- findOrCreateAccount
--------------------------------------------------------------------------------

test('findOrCreateAccount: no license identifier returns nil with an error', function()
    withFakeDb(function()
        local accountId, conflicts, err = AccountService.findOrCreateAccount({ { type = 'discord', value = '123' } })
        eq(accountId, nil)
        truthy(err ~= nil, 'expected an error message')
    end)
end)

test('findOrCreateAccount: an unseen license creates a new account and links it', function()
    withFakeDb(function(tables)
        local accountId = AccountService.findOrCreateAccount({ { type = 'license', value = 'abc' } })
        truthy(type(accountId) == 'number', 'accountId is a number')
        eq(#tables.accounts, 1)
        eq(#tables.account_identifiers, 1)
        eq(tables.account_identifiers[1].type, 'license')
        eq(tables.account_identifiers[1].value, 'abc')
        eq(tables.account_identifiers[1].account_id, accountId)
    end)
end)

test('findOrCreateAccount: a known license resolves to the same existing account, no duplicate row', function()
    withFakeDb(function(tables)
        local firstId = AccountService.findOrCreateAccount({ { type = 'license', value = 'abc' } })
        local secondId = AccountService.findOrCreateAccount({ { type = 'license', value = 'abc' } })
        eq(secondId, firstId)
        eq(#tables.accounts, 1)
    end)
end)

test('findOrCreateAccount: a new secondary identifier on a known account gets linked', function()
    withFakeDb(function(tables)
        local accountId = AccountService.findOrCreateAccount({
            { type = 'license', value = 'abc' },
            { type = 'discord', value = 'd1' },
        })
        eq(#tables.account_identifiers, 2)

        local discordRow
        for _, row in ipairs(tables.account_identifiers) do
            if row.type == 'discord' then discordRow = row end
        end
        truthy(discordRow ~= nil, 'discord identifier was linked')
        eq(discordRow.account_id, accountId)
    end)
end)

test('findOrCreateAccount: a secondary identifier already linked to a different account is a conflict, never merged', function()
    withFakeDb(function(tables)
        local accountA = AccountService.findOrCreateAccount({
            { type = 'license', value = 'license-a' },
            { type = 'discord', value = 'shared-discord' },
        })
        local accountB, conflicts = AccountService.findOrCreateAccount({
            { type = 'license', value = 'license-b' },
            { type = 'discord', value = 'shared-discord' },
        })

        truthy(accountB ~= accountA, 'a different license always resolves to a different account')
        eq(#conflicts, 1)
        eq(conflicts[1].type, 'discord')
        eq(conflicts[1].expectedAccountId, accountB)
        eq(conflicts[1].actualAccountId, accountA)

        local discordLinks = 0
        for _, row in ipairs(tables.account_identifiers) do
            if row.type == 'discord' and row.value == 'shared-discord' then
                discordLinks = discordLinks + 1
            end
        end
        eq(discordLinks, 1, 'the conflicting identifier was never duplicated or reassigned')
    end)
end)

--------------------------------------------------------------------------------
-- checkBan / ban / unban
--------------------------------------------------------------------------------

test('checkBan: returns nil when there are no bans', function()
    withFakeDb(function()
        eq(AccountService.checkBan(1, {}), nil)
    end)
end)

test('checkBan: matches an active ban by account_id', function()
    withFakeDb(function()
        AccountService.ban({ accountId = 1 }, 'cheating', 'admin', nil)
        local ban = AccountService.checkBan(1, {})
        truthy(ban ~= nil, 'ban found')
        eq(ban.reason, 'cheating')
    end)
end)

test('checkBan: matches an active ban by raw identifier', function()
    withFakeDb(function()
        AccountService.ban({ type = 'ip', value = '1.2.3.4' }, 'evasion', 'admin', nil)
        local ban = AccountService.checkBan(nil, { { type = 'ip', value = '1.2.3.4' } })
        truthy(ban ~= nil, 'ban found')
    end)
end)

test('checkBan: ignores a revoked ban', function()
    withFakeDb(function()
        local ban = AccountService.ban({ accountId = 1 }, 'cheating', 'admin', nil)
        AccountService.unban(ban.attributes.id)
        eq(AccountService.checkBan(1, {}), nil)
    end)
end)

test('checkBan: ignores an expired ban', function()
    withFakeDb(function()
        AccountService.ban({ accountId = 1 }, 'cheating', 'admin', '2000-01-01 00:00:00')
        eq(AccountService.checkBan(1, {}), nil)
    end)
end)

test('checkBan: a permanent (nil expires_at) ban still matches', function()
    withFakeDb(function()
        AccountService.ban({ accountId = 1 }, 'cheating', 'admin', nil)
        truthy(AccountService.checkBan(1, {}) ~= nil, 'permanent ban matches')
    end)
end)

--------------------------------------------------------------------------------
-- formatBanMessage
--------------------------------------------------------------------------------

test('formatBanMessage: permanent ban', function()
    eq(AccountService.formatBanMessage({ reason = 'cheating', expires_at = nil }), 'Banned: cheating (permanent)')
end)

test('formatBanMessage: temporary ban includes the expiry', function()
    eq(AccountService.formatBanMessage({ reason = 'spam', expires_at = '2026-01-01 00:00:00' }),
        'Banned: spam (expires 2026-01-01 00:00:00)')
end)

--------------------------------------------------------------------------------
-- session map
--------------------------------------------------------------------------------

test('getAccountId: returns nil for an unresolved source', function()
    eq(AccountService.getAccountId(999), nil)
end)

test('getAccountId: returns the account id once set', function()
    AccountService.sessionAccounts[42] = 7
    eq(AccountService.getAccountId(42), 7)
    AccountService.sessionAccounts[42] = nil
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running AccountService unit tests\n')
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
```

Save to `tests/account_service_spec.lua`.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `lua5.4 tests/account_service_spec.lua`

Expected: `18 passed, 0 failed` (3 `parseIdentifiers` + 5 `findOrCreateAccount` + 6 `checkBan`/ban/unban + 2 `formatBanMessage` + 2 `getAccountId`). Every `test(...)` block in the file must report `ok`, none `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add server/services/AccountService.lua tests/support/fake_query_builder.lua tests/account_service_spec.lua
git commit -m "feat: add AccountService with identifier resolution and ban checking"
```

---

## Task 4: Connect hook

**Files:**
- Create: `server/main.lua`

**Interfaces:**
- Consumes: `AccountService.parseIdentifiers`, `AccountService.findOrCreateAccount`, `AccountService.checkBan`, `AccountService.formatBanMessage`, `AccountService.sessionAccounts` (all from Task 3).

This file touches FXServer-only globals (`AddEventHandler('playerConnecting', ...)`, `deferrals`, `GetPlayerIdentifiers`, `source`, `Citizen.Wait`) that don't exist outside a running FXServer, so this task gets a syntax check only, no unit test, matching the Global Constraints.

- [ ] **Step 1: Write `server/main.lua`**

```lua
--- oblsk_accounts - Server Main
--- Hooks playerConnecting to resolve the connecting player's Account and
--- reject banned/unresolvable connections before they spawn. See
--- docs/superpowers/specs/2026-08-10-accounts-module-design.md.
print('[oblsk_accounts] Loading...')

AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    local src = source
    deferrals.defer()
    Citizen.Wait(0)
    deferrals.update('Checking account...')

    local identifiers = AccountService.parseIdentifiers(GetPlayerIdentifiers(src))

    local ok, accountId, conflicts, err = pcall(AccountService.findOrCreateAccount, identifiers)
    if not ok then
        print('[oblsk_accounts] ERROR resolving account for ' .. name .. ': ' .. tostring(accountId))
        deferrals.done('Could not verify your account. Please try again.')
        return
    end

    if not accountId then
        deferrals.done(err or 'Could not verify your account.')
        return
    end

    if conflicts and #conflicts > 0 then
        for _, conflict in ipairs(conflicts) do
            print('[oblsk_accounts] identifier conflict: ' .. conflict.type .. ':' .. conflict.value ..
                ' expected on account ' .. conflict.expectedAccountId .. ' but already linked to account ' .. conflict.actualAccountId)
        end
    end

    local ban = AccountService.checkBan(accountId, identifiers)
    if ban then
        deferrals.done(AccountService.formatBanMessage(ban))
        return
    end

    AccountService.sessionAccounts[src] = accountId
    deferrals.done()
end)

AddEventHandler('playerDropped', function()
    AccountService.sessionAccounts[source] = nil
end)

print('[oblsk_accounts] Loaded successfully!')
```

- [ ] **Step 2: Verify the file parses**

Run: `luac5.4 -p server/main.lua`

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add server/main.lua
git commit -m "feat: hook playerConnecting for account resolution and ban rejection"
```

---

## Task 5: Admin commands

**Files:**
- Create: `server/commands/AccountCommands.lua`

**Interfaces:**
- Consumes: `AccountService.getAccountId`, `AccountService.ban`, `AccountService.unban` (Task 3).

This file touches FXServer-only globals (`RegisterCommand`, `IsPlayerAceAllowed`, `DropPlayer`), so this task also gets a syntax check only, no unit test, matching the Global Constraints. Gated by `IsPlayerAceAllowed(source, 'admin')`, the same ACE string the existing `IsAdminPolicy` already uses (`core/server/Policies/IsAdminPolicy.lua`), rather than inventing a new permission string with no permissions/roles system to register it against.

- [ ] **Step 1: Write `server/commands/AccountCommands.lua`**

```lua
--- oblsk_accounts - Admin Commands
--- Minimum viable surface for writing to the bans table: without these,
--- issuing or revoking a ban needs raw SQL. Not a moderation UI.
local function isAdmin(source)
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

RegisterCommand('ban', function(source, args)
    if not isAdmin(source) then return end

    local targetId = tonumber(args[1])
    local reason = table.concat(args, ' ', 2)
    if not targetId or reason == '' then
        print('Usage: /ban <serverId> <reason>')
        return
    end

    local accountId = AccountService.getAccountId(targetId)
    if not accountId then
        print('[oblsk_accounts] player ' .. targetId .. ' has no resolved account')
        return
    end

    AccountService.ban({ accountId = accountId }, reason, tostring(source), nil)
    DropPlayer(targetId, 'Banned: ' .. reason)
end, false)

RegisterCommand('tempban', function(source, args)
    if not isAdmin(source) then return end

    local targetId = tonumber(args[1])
    local minutes = tonumber(args[2])
    local reason = table.concat(args, ' ', 3)
    if not targetId or not minutes or reason == '' then
        print('Usage: /tempban <serverId> <minutes> <reason>')
        return
    end

    local accountId = AccountService.getAccountId(targetId)
    if not accountId then
        print('[oblsk_accounts] player ' .. targetId .. ' has no resolved account')
        return
    end

    local expiresAt = os.date('%Y-%m-%d %H:%M:%S', os.time() + minutes * 60)
    AccountService.ban({ accountId = accountId }, reason, tostring(source), expiresAt)
    DropPlayer(targetId, 'Banned: ' .. reason)
end, false)

RegisterCommand('banid', function(source, args)
    if not isAdmin(source) then return end

    local idType = args[1]
    local idValue = args[2]
    local reason = table.concat(args, ' ', 3)
    if not idType or not idValue or reason == '' then
        print('Usage: /banid <type> <value> <reason>')
        return
    end

    AccountService.ban({ type = idType, value = idValue }, reason, tostring(source), nil)
    print('[oblsk_accounts] banned ' .. idType .. ':' .. idValue)
end, false)

RegisterCommand('unban', function(source, args)
    if not isAdmin(source) then return end

    local banId = tonumber(args[1])
    if not banId then
        print('Usage: /unban <banId>')
        return
    end

    AccountService.unban(banId)
    print('[oblsk_accounts] revoked ban #' .. banId)
end, false)
```

- [ ] **Step 2: Verify the file parses**

Run: `luac5.4 -p server/commands/AccountCommands.lua`

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add server/commands/AccountCommands.lua
git commit -m "feat: add /ban /tempban /banid /unban admin commands"
```

---

## After all tasks: final review and handoff

Once Task 5 is complete: run `lua5.4 tests/account_service_spec.lua` one more time from the repo root to confirm the full suite is still green, then run a whole-branch review per the subagent-driven-development skill. After that review is clean:

- Run `obelisk registry:generate` from `core/` on the host so `modules/registry.json` picks up `oblsk_accounts` (needed before `core/server/bootstrap.lua` will run its migrations).
- Create the `oblsk_accounts` GitHub repo and push, same as `oblsk_items`/`oblsk_vehicles`, once the user confirms.
- This module is the prerequisite the Characters module (a separate, future spec) depends on via `AccountService.getAccountId(source)`; nothing here assumes what a Character looks like.
