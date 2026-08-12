# Characters Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `oblsk_characters` module: `Character`/`CharacterAppearance` models, a slot-limited character-select data layer (`CharacterService.list`/`create`/`delete`), and a per-session active-character map. No gameplay state (position/health/money) and no UI wiring, both explicitly out of scope per the design spec.

**Architecture:** See `docs/superpowers/specs/2026-08-10-characters-module-design.md` for full rationale. This module needs no core-side fixes; every task lives in the separate `oblsk_characters` repository. It has a real dependency on `oblsk_accounts` (a foreign key from `characters.account_id` to `accounts.id`), but no code-level dependency, nothing here calls into `AccountService`.

**Tech Stack:** Lua (FXServer `server_scripts` only, no client side), the existing ORM (`BaseModel`/`QueryBuilder`/`Schema`), `lua5.4` for the pure-logic unit tests.

## Global Constraints

- `oblsk_characters` is a **separate git repository** (`core/modules/oblsk_characters/`), freshly `git init`'d, no remote yet, no commits. Work directly on `master`, no worktree, same reasoning already used for `oblsk_accounts`/`oblsk_items`/`oblsk_vehicles`: nothing exists yet to protect.
- `characters.account_id` has a real foreign key to `accounts.id` (from `oblsk_accounts`). `core/server/bootstrap.lua` runs each module's migrations in `modules/registry.json`'s array order, which `obelisk registry:generate` always writes alphabetically, so `oblsk_accounts` (before `oblsk_characters` alphabetically) migrates first automatically. This is implicit, not enforced by code, don't rename either module in a way that would break the ordering.
- No FXServer runtime exists in this repo's test environment. This module has no event handlers and no native calls at all (unlike `oblsk_accounts`), so every file in this plan gets a real unit test, not a syntax-check-only file.
- Slot uniqueness (`characters.slot` per `account_id`) and the one-appearance-per-character invariant are enforced in `CharacterService`, not by a DB constraint that excludes soft-deleted rows (see the design spec's Schema section for why). `character_appearances.character_id` DOES get a DB-level `unique()`, since that invariant never needs to tolerate a "soft-deleted" exception, one live character never has more than one appearance row, period.
- No Claude co-authorship in any commit.
- Minimize em/en dashes in prose (project owner's stated preference); applies to commit messages and docs prose, not code/SQL.

---

## Task 1: Module scaffold and full schema

**Repository:** `oblsk_characters`, working directly on `master`.

**Files:**
- Create: `README.md`
- Create: `server/migrations/2026_08_10_095223_create_characters_table.lua`
- Create: `server/migrations/2026_08_10_095224_create_character_appearances_table.lua`
- Create: `server/migrations.json`

**Interfaces:**
- Produces: the `characters` and `character_appearances` tables. Every later task depends on these existing.

- [ ] **Step 1: Write the `characters` migration**

```lua
--- Migration: Create characters table
return {
    up = function()
        Schema.create('characters', function(table)
            table:id()
            table:integer('account_id'):notNullable()
            table:integer('slot'):notNullable()
            table:string('first_name', 100):notNullable()
            table:string('last_name', 100):notNullable()
            table:string('gender', 20)
            table:date('dob')
            table:text('bio')
            table:datetime('last_played_at')
            table:datetime('deleted_at')
            table:timestamps()

            table:index({'account_id'})
            table:foreign('account_id'):references('id'):on('accounts'):onDelete('CASCADE')
        end)

        print('[Migration] Created characters table')
    end,

    down = function()
        Schema.drop('characters')
        print('[Migration] Dropped characters table')
    end
}
```

Save to `server/migrations/2026_08_10_095223_create_characters_table.lua`.

- [ ] **Step 2: Write the `character_appearances` migration**

```lua
--- Migration: Create character_appearances table
return {
    up = function()
        Schema.create('character_appearances', function(table)
            table:id()
            table:integer('character_id'):notNullable():unique()
            table:string('ped_model', 100)
            table:json('data')
            table:timestamps()

            table:foreign('character_id'):references('id'):on('characters'):onDelete('CASCADE')
        end)

        print('[Migration] Created character_appearances table')
    end,

    down = function()
        Schema.drop('character_appearances')
        print('[Migration] Dropped character_appearances table')
    end
}
```

Save to `server/migrations/2026_08_10_095224_create_character_appearances_table.lua`.

- [ ] **Step 3: Write `server/migrations.json`**

```json
{
  "migrations": [
    "2026_08_10_095223_create_characters_table",
    "2026_08_10_095224_create_character_appearances_table"
  ]
}
```

- [ ] **Step 4: Write `README.md`**

```markdown
# Oblsk_characters Module

## Description
Character/CharacterAppearance identity-and-looks data layer on top of
oblsk_accounts: a slot-limited character-select system (create, list,
soft-delete) and a per-session active-character map. No gameplay state
(position, health, money) and no UI wiring, both are separate future work.

## Installation
This module loads as part of the `core` resource. After adding it under
`modules/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server). Requires oblsk_accounts to already be
installed (characters.account_id is a foreign key to accounts.id).

## Usage
`CharacterService.list(accountId)`, `CharacterService.create(accountId, attributes)`,
`CharacterService.delete(characterId)`, `CharacterService.setActiveCharacterId(source, characterId)`,
`CharacterService.getActiveCharacterId(source)`.
```

- [ ] **Step 5: Verify both migration files parse**

Run: `luac5.4 -p server/migrations/2026_08_10_095223_create_characters_table.lua server/migrations/2026_08_10_095224_create_character_appearances_table.lua`

Expected: no output, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add README.md server/migrations server/migrations.json
git commit -m "feat: add characters, character_appearances schema"
```

---

## Task 2: Models

**Files:**
- Create: `server/models/Character.lua`
- Create: `server/models/CharacterAppearance.lua`

**Interfaces:**
- Consumes: `BaseModel:extend(tableName)` from core's ORM (already merged, unmodified). `Account` is referenced by name in `Character:accountRelation()` but never loaded or required by this module, if `oblsk_accounts` isn't installed, calling that one relation method would fail (a documented dependency, not a bug this module needs to guard against).
- Produces: `Character`, `CharacterAppearance` globals. Task 3's `CharacterService` and its tests load and use both directly.

- [ ] **Step 1: Write `Character.lua`**

```lua
--- Character Model - one character slot on an Account. Soft-deleted
--- (deleted_at) rather than hard-deleted, since Item/Vehicle rows may
--- already reference a character via owner_id and this module has no way
--- to know what else points at a characters.id. See
--- docs/superpowers/specs/2026-08-10-characters-module-design.md.
Character = BaseModel:extend('characters')

Character.primaryKey = 'id'
Character.timestamps = true
Character.fillable = { 'account_id', 'slot', 'first_name', 'last_name', 'gender', 'dob', 'bio', 'last_played_at', 'deleted_at' }
Character.hidden = {}

function Character:accountRelation()
    return self:belongsTo(Account, 'account_id', 'id')
end

function Character:appearanceRelation()
    return self:hasOne(CharacterAppearance, 'character_id', 'id')
end

return Character
```

- [ ] **Step 2: Write `CharacterAppearance.lua`**

```lua
--- CharacterAppearance Model - ped customization for one Character.
--- ped_model is its own column since it determines which base model to
--- spawn; everything else (head blend, overlays, components, props,
--- hair/eye color) lives in data as the long tail, same convention as
--- Vehicle.body_damage.
CharacterAppearance = BaseModel:extend('character_appearances')

CharacterAppearance.primaryKey = 'id'
CharacterAppearance.timestamps = true
CharacterAppearance.fillable = { 'character_id', 'ped_model', 'data' }
CharacterAppearance.hidden = {}

CharacterAppearance.casts = {
    data = 'json',
}

function CharacterAppearance:characterRelation()
    return self:belongsTo(Character, 'character_id', 'id')
end

return CharacterAppearance
```

- [ ] **Step 3: Verify both files parse**

Run: `luac5.4 -p server/models/Character.lua server/models/CharacterAppearance.lua`

Expected: no output, exit code 0. (`BaseModel`/`Account` aren't defined in this check, since these files reference globals set up by core/`oblsk_accounts` at runtime; a pure syntax check doesn't need them. Task 3's spec file is what actually loads `Character.lua`/`CharacterAppearance.lua` against real `BaseModel`.)

- [ ] **Step 4: Commit**

```bash
git add server/models
git commit -m "feat: add Character, CharacterAppearance models"
```

---

## Task 3: CharacterService

**Files:**
- Create: `server/services/CharacterService.lua`
- Create: `tests/support/fake_query_builder.lua`
- Create: `tests/character_service_spec.lua`

**Interfaces:**
- Consumes: `Character`, `CharacterAppearance` (Task 2), `QueryBuilder.new(tableName)` and `Database.now()` from core's ORM.
- Produces: `CharacterService.CHARACTER_SLOT_LIMIT` (constant, default `3`), `CharacterService.list(accountId)`, `CharacterService.create(accountId, attributes)` returning `(character, err)`, `CharacterService.delete(characterId)`, `CharacterService.setActiveCharacterId(source, characterId)`, `CharacterService.getActiveCharacterId(source)`.

- [ ] **Step 1: Write the fake QueryBuilder test support**

Identical in shape to `oblsk_accounts/tests/support/fake_query_builder.lua` (this repo has no code dependency on that one, a plain copy, same as how `oblsk_items` and `oblsk_vehicles` each have their own independent test doubles rather than sharing one across repos).

```lua
--- A fake QueryBuilder.new that operates on in-memory Lua tables instead of
--- real SQL. See tests/character_service_spec.lua for how this is swapped
--- in for the real global QueryBuilder around each test.
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
    local value = b ~= nil and b or a
    table.insert(self.wheres, { column = column, value = value })
    return self
end

function FakeQueryBuilder:whereNull(column)
    table.insert(self.whereNulls, column)
    return self
end

function FakeQueryBuilder:orderBy(column, direction)
    self.orderByColumn = column
    self.orderByDirection = direction or 'asc'
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
    if self.orderByColumn then
        local column, descending = self.orderByColumn, self.orderByDirection == 'desc'
        table.sort(results, function(a, b)
            if descending then return a[column] > b[column] end
            return a[column] < b[column]
        end)
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

Save to `tests/support/fake_query_builder.lua`. (This version adds `:orderBy()`, which `oblsk_accounts`'s copy doesn't need, `CharacterService.list` orders by slot.)

- [ ] **Step 2: Write `CharacterService.lua`**

```lua
--- CharacterService (server) - a slot-limited character-select data layer
--- on top of Account. Identity and looks only: no position/health/money,
--- no event handlers, no native calls. See
--- docs/superpowers/specs/2026-08-10-characters-module-design.md.
CharacterService = {}
CharacterService.CHARACTER_SLOT_LIMIT = 3
CharacterService.sessionCharacters = {} -- source -> character_id, runtime only, set by a future UI-wiring pass

--- @param accountId number
--- @return table[] non-deleted characters, ordered by slot
function CharacterService.list(accountId)
    return QueryBuilder.new('characters')
        :where('account_id', accountId)
        :whereNull('deleted_at')
        :orderBy('slot', 'asc')
        :getSync()
end

local function findFreeSlot(accountId)
    local taken = {}
    for _, character in ipairs(CharacterService.list(accountId)) do
        taken[character.slot] = true
    end
    for slot = 0, CharacterService.CHARACTER_SLOT_LIMIT - 1 do
        if not taken[slot] then
            return slot
        end
    end
    return nil
end

--- Creates a Character in the lowest free slot for this account, plus a
--- blank CharacterAppearance linked to it. Returns an error instead of
--- creating anything once CHARACTER_SLOT_LIMIT non-deleted characters
--- already exist for this account.
--- @param accountId number
--- @param attributes table { first_name, last_name, gender, dob, bio }
--- @return Character|nil
--- @return string|nil err set only when the return is nil
function CharacterService.create(accountId, attributes)
    local slot = findFreeSlot(accountId)
    if not slot then
        return nil, 'no free character slots'
    end

    local character = Character:createSync({
        account_id = accountId,
        slot = slot,
        first_name = attributes.first_name,
        last_name = attributes.last_name,
        gender = attributes.gender,
        dob = attributes.dob,
        bio = attributes.bio,
    })

    CharacterAppearance:createSync({
        character_id = character.attributes.id,
        ped_model = attributes.ped_model or 'mp_m_freemode_01',
        data = {},
    })

    return character
end

--- @param characterId number
function CharacterService.delete(characterId)
    return QueryBuilder.new('characters'):where('id', characterId):update({ deleted_at = Database.now() })
end

--- @param source number
--- @param characterId number
function CharacterService.setActiveCharacterId(source, characterId)
    CharacterService.sessionCharacters[source] = characterId
end

--- @param source number
--- @return number|nil
function CharacterService.getActiveCharacterId(source)
    return CharacterService.sessionCharacters[source]
end

return CharacterService
```

Save to `server/services/CharacterService.lua`.

- [ ] **Step 3: Write `tests/character_service_spec.lua`**

```lua
--- Unit tests for CharacterService: slot assignment, soft-delete/slot
--- reuse, the slot limit, and the session map.
--- Run from the repository root:  lua5.4 tests/character_service_spec.lua
---
--- CORE_ROOT is a relative walk-up from this file to the core repo root.
--- oblsk_characters must live at <core-root>/modules/oblsk_characters/ for
--- FXServer to load it as part of core at all, so this file is always
--- three levels below the core root (tests/ -> oblsk_characters/ ->
--- modules/ -> core-root).
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

-- Character:accountRelation() references the global Account, from the
-- separate oblsk_accounts module, never loaded here. That reference is
-- inside the relation function's body, not evaluated at file-load time, so
-- Character.lua loads fine without Account existing; these tests never call
-- accountRelation() anyway.
dofile(scriptDir .. '../server/models/Character.lua')
dofile(scriptDir .. '../server/models/CharacterAppearance.lua')
dofile(scriptDir .. '../server/services/CharacterService.lua')

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
--- so CharacterService (and the Character/CharacterAppearance models it
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
-- create / slot assignment
--------------------------------------------------------------------------------

test('create: the first character on an account gets slot 0', function()
    withFakeDb(function()
        local character = CharacterService.create(1, { first_name = 'John', last_name = 'Doe' })
        eq(character.attributes.slot, 0)
    end)
end)

test('create: a second character on the same account gets the next free slot', function()
    withFakeDb(function()
        CharacterService.create(1, { first_name = 'John', last_name = 'Doe' })
        local second = CharacterService.create(1, { first_name = 'Jane', last_name = 'Doe' })
        eq(second.attributes.slot, 1)
    end)
end)

test('create: also creates a blank CharacterAppearance linked to the new character', function()
    withFakeDb(function(tables)
        local character = CharacterService.create(1, { first_name = 'John', last_name = 'Doe' })
        eq(#tables.character_appearances, 1)
        eq(tables.character_appearances[1].character_id, character.attributes.id)
    end)
end)

test('create: different accounts do not share slot assignment', function()
    withFakeDb(function()
        local charA = CharacterService.create(1, { first_name = 'John', last_name = 'Doe' })
        local charB = CharacterService.create(2, { first_name = 'Jane', last_name = 'Doe' })
        eq(charA.attributes.slot, 0)
        eq(charB.attributes.slot, 0)
    end)
end)

test('create: returns an error once CHARACTER_SLOT_LIMIT characters already exist', function()
    withFakeDb(function()
        for i = 1, CharacterService.CHARACTER_SLOT_LIMIT do
            CharacterService.create(1, { first_name = 'Char', last_name = tostring(i) })
        end
        local character, err = CharacterService.create(1, { first_name = 'One', last_name = 'Too Many' })
        eq(character, nil)
        truthy(err ~= nil, 'expected an error message')
    end)
end)

--------------------------------------------------------------------------------
-- delete / slot reuse
--------------------------------------------------------------------------------

test('delete: sets deleted_at', function()
    withFakeDb(function(tables)
        local character = CharacterService.create(1, { first_name = 'John', last_name = 'Doe' })
        CharacterService.delete(character.attributes.id)
        eq(tables.characters[1].deleted_at ~= nil, true)
    end)
end)

test('delete: frees the slot for a new character on the same account', function()
    withFakeDb(function()
        local first = CharacterService.create(1, { first_name = 'John', last_name = 'Doe' })
        CharacterService.create(1, { first_name = 'Jane', last_name = 'Doe' })
        CharacterService.delete(first.attributes.id)

        local third = CharacterService.create(1, { first_name = 'Jack', last_name = 'Doe' })
        eq(third.attributes.slot, 0)
    end)
end)

--------------------------------------------------------------------------------
-- list
--------------------------------------------------------------------------------

test('list: returns only non-deleted characters, ordered by slot', function()
    withFakeDb(function()
        CharacterService.create(1, { first_name = 'John', last_name = 'Doe' })
        CharacterService.create(1, { first_name = 'Jane', last_name = 'Doe' })
        local third = CharacterService.create(1, { first_name = 'Jack', last_name = 'Doe' })
        CharacterService.delete(third.attributes.id)

        local characters = CharacterService.list(1)
        eq(#characters, 2)
        eq(characters[1].slot, 0)
        eq(characters[1].first_name, 'John')
        eq(characters[2].slot, 1)
        eq(characters[2].first_name, 'Jane')
    end)
end)

--------------------------------------------------------------------------------
-- session map
--------------------------------------------------------------------------------

test('getActiveCharacterId: returns nil before setActiveCharacterId is called', function()
    eq(CharacterService.getActiveCharacterId(999), nil)
end)

test('getActiveCharacterId: returns the value set by setActiveCharacterId', function()
    CharacterService.setActiveCharacterId(42, 7)
    eq(CharacterService.getActiveCharacterId(42), 7)
    CharacterService.sessionCharacters[42] = nil
end)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------
print('Running CharacterService unit tests\n')
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

Save to `tests/character_service_spec.lua`.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `lua5.4 tests/character_service_spec.lua`

Expected: `10 passed, 0 failed` (5 create/slot-assignment + 2 delete/slot-reuse + 1 list + 2 session map; every `test(...)` block in the file must report `ok`, none `FAIL`).

- [ ] **Step 5: Commit**

```bash
git add server/services/CharacterService.lua tests/support/fake_query_builder.lua tests/character_service_spec.lua
git commit -m "feat: add CharacterService with slot-limited character creation"
```

---

## After all tasks: final review and handoff

Once Task 3 is complete: run `lua5.4 tests/character_service_spec.lua` one more time from the repo root to confirm the full suite is still green, then run a whole-branch review per the subagent-driven-development skill. After that review is clean:

- Run `obelisk registry:generate` from `core/` on the host so `modules/registry.json` picks up `oblsk_characters` (needed before `core/server/bootstrap.lua` will run its migrations, and note the ordering constraint in Global Constraints, `oblsk_accounts` must run first).
- Create the `oblsk_characters` GitHub repo and push, same as `oblsk_accounts`/`oblsk_items`/`oblsk_vehicles`, once the user confirms.
- Wiring `oblsk_character-selection`'s existing Vue UI to `CharacterService` is a separate, future pass, not part of this plan.
