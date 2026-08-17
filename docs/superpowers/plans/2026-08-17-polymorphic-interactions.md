# Polymorphic Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `interaction_id` FK columns on 16 plugin tables with `owner_type`/`owner_id` polymorphic columns on the `interactions` table, backed by new `morphOne`/`morphMany`/`morphTo` ORM relation types.

**Architecture:** Add three morph relation types to `BaseModel` (constructors + `load`/`loadAsync`/`eagerLoad` dispatch). Flip schema ownership: `interactions` grows `owner_type`+`owner_id`; each plugin table drops `interaction_id`. Every plugin model is rewritten to be fully declarative (fillable, relations, no raw QB), and service/seeder code is rewritten to use model syntax throughout.

**Tech Stack:** Lua 5.4, FiveM server environment, custom ORM (BaseModel/QueryBuilder), MySQL (oxmysql). Tests run with `lua5.4` from the repo root.

**Spec:** `docs/superpowers/specs/2026-08-17-polymorphic-interactions-design.md`

## Global Constraints

- `owner_type` value = exact Lua global name of the model class (e.g. `'ATMMachine'`, `'Garage'`)
- Migration timestamps follow `YYYY_MM_DD_HHMMSS` pattern; use sequential seconds to order them
- `Schema.dropColumn(tableName, col)` is used to drop columns; FK constraints must be dropped first via raw `Database.query`
- FK constraint name convention: `tableName_columnName_foreign` (matches Schema builder)
- `TunerShop.tablet_interaction_id` is **not** migrated — it stays as a regular FK (optional secondary interaction)
- Tests run: `lua5.4 tests/orm_spec.lua` (ORM), `lua5.4 plugins/<plugin>/tests/<spec>.lua` (plugins)
- Never add `Co-Authored-By: Claude` to commits

---

## Task 1: ORM — morphOne, morphMany, morphTo

**Files:**
- Modify: `core/server/ORM/BaseModel.lua` (relation constructors + load/loadAsync/eagerLoad dispatch)
- Modify: `tests/orm_spec.lua` (new tests after line 1356, before the runner section at line 1979)

**Interfaces:**
- Produces:
  - `BaseModel:morphOne(relatedModel, ownerIdKey, ownerTypeKey, ownerTypeValue) → relation`
  - `BaseModel:morphMany(relatedModel, ownerIdKey, ownerTypeKey, ownerTypeValue) → relation`
  - `BaseModel:morphTo(ownerTypeKey, ownerIdKey) → relation`
  - All three handled in `load()`, `loadAsync()`, `eagerLoad()`

- [ ] **Step 1: Write failing ORM tests**

Add these tests to `tests/orm_spec.lua` before the `-- Runner` block (line 1979):

```lua
--------------------------------------------------------------------------------
-- morphOne / morphMany / morphTo
--------------------------------------------------------------------------------
test('BaseModel load: morphOne returns the single related row for this owner', function()
    local ATMMachine = BaseModel:extend('atm_machines')
    ATMMachine.primaryKey = 'id'
    ATMMachine.timestamps = false

    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function ATMMachine:interaction()
        return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ATMMachine')
    end

    local queriedSql, queriedParams
    local original = Database.query
    Database.query = function(sql, params)
        queriedSql = sql
        queriedParams = params
        if sql:find('FROM `atm_machines`') then
            return {{ id = 5, name = 'Test ATM' }}
        elseif sql:find('FROM `interactions`') then
            return {{ id = 99, owner_type = 'ATMMachine', owner_id = 5, x = 1.0, label = 'Use ATM' }}
        end
        return {}
    end

    local atm = ATMMachine:find(5)
    local interaction = atm:load('interaction')
    Database.query = original

    truthy(interaction, 'morphOne: related row found')
    eq(interaction.id, 99, 'morphOne: correct row returned')
    eq(interaction.label, 'Use ATM', 'morphOne: correct field value')
    truthy(queriedSql:find('owner_type'), 'morphOne: query filters by owner_type')
    truthy(queriedSql:find('owner_id'), 'morphOne: query filters by owner_id')
end)

test('BaseModel load: morphOne returns nil when no matching row exists', function()
    local Widget = BaseModel:extend('widgets')
    Widget.primaryKey = 'id'
    Widget.timestamps = false

    local Tag = BaseModel:extend('tags')
    Tag.primaryKey = 'id'
    Tag.timestamps = false

    function Widget:tag() return self:morphOne(Tag, 'owner_id', 'owner_type', 'Widget') end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `widgets`') then return {{ id = 1 }} end
        return {}
    end

    local widget = Widget:find(1)
    local tag = widget:load('tag')
    Database.query = original

    falsy(tag, 'morphOne: nil returned when no related row exists')
end)

test('BaseModel load: morphMany returns all related rows for this owner', function()
    local Post = BaseModel:extend('posts')
    Post.primaryKey = 'id'
    Post.timestamps = false

    local Comment = BaseModel:extend('comments')
    Comment.primaryKey = 'id'
    Comment.timestamps = false

    function Post:comments()
        return self:morphMany(Comment, 'owner_id', 'owner_type', 'Post')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then return {{ id = 10 }} end
        if sql:find('FROM `comments`') then
            return {
                { id = 1, owner_type = 'Post', owner_id = 10, body = 'First' },
                { id = 2, owner_type = 'Post', owner_id = 10, body = 'Second' },
            }
        end
        return {}
    end

    local post = Post:find(10)
    local comments = post:load('comments')
    Database.query = original

    eq(#comments, 2, 'morphMany: both related rows returned')
    eq(comments[1].body, 'First', 'morphMany: first row body correct')
    eq(comments[2].body, 'Second', 'morphMany: second row body correct')
end)

test('BaseModel load: morphMany returns empty table when no related rows exist', function()
    local Post = BaseModel:extend('posts')
    Post.primaryKey = 'id'
    Post.timestamps = false

    local Comment = BaseModel:extend('comments')
    Comment.primaryKey = 'id'
    Comment.timestamps = false

    function Post:comments()
        return self:morphMany(Comment, 'owner_id', 'owner_type', 'Post')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then return {{ id = 10 }} end
        return {}
    end

    local post = Post:find(10)
    local comments = post:load('comments')
    Database.query = original

    truthy(comments, 'morphMany: non-nil result even when empty')
    eq(#comments, 0, 'morphMany: empty table returned when no related rows')
end)

test('BaseModel load: morphTo resolves owner via _G[owner_type]:find(owner_id)', function()
    local ATMMachine = BaseModel:extend('atm_machines')
    ATMMachine.primaryKey = 'id'
    ATMMachine.timestamps = false

    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function Interaction:owner()
        return self:morphTo('owner_type', 'owner_id')
    end

    _G['ATMMachine'] = ATMMachine

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `interactions`') then
            return {{ id = 99, owner_type = 'ATMMachine', owner_id = 5, label = 'Use ATM' }}
        elseif sql:find('FROM `atm_machines`') then
            return {{ id = 5, name = 'Main ATM' }}
        end
        return {}
    end

    local interaction = Interaction:find(99)
    local owner = interaction:load('owner')
    Database.query = original
    _G['ATMMachine'] = nil

    truthy(owner, 'morphTo: owner resolved')
    eq(owner.id, 5, 'morphTo: correct owner id')
    eq(owner.name, 'Main ATM', 'morphTo: correct owner field')
end)

test('BaseModel load: morphTo returns nil when owner_type resolves to nil global', function()
    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function Interaction:owner()
        return self:morphTo('owner_type', 'owner_id')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `interactions`') then
            return {{ id = 1, owner_type = 'NonExistentModel', owner_id = 42 }}
        end
        return {}
    end

    local interaction = Interaction:find(1)
    local owner = interaction:load('owner')
    Database.query = original

    falsy(owner, 'morphTo: nil returned when global model not found')
end)

test('BaseModel.with: morphOne batches one query for all instances with WHERE IN owner_id', function()
    local ATMMachine = BaseModel:extend('atm_machines')
    ATMMachine.primaryKey = 'id'
    ATMMachine.timestamps = false

    local Interaction = BaseModel:extend('interactions')
    Interaction.primaryKey = 'id'
    Interaction.timestamps = false

    function ATMMachine:interaction()
        return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ATMMachine')
    end

    local interactionParams
    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `atm_machines`') then
            return {{ id = 1, name = 'ATM A' }, { id = 2, name = 'ATM B' }}
        elseif sql:find('FROM `interactions`') then
            interactionParams = params
            return {
                { id = 10, owner_type = 'ATMMachine', owner_id = 1, label = 'ATM A' },
                { id = 11, owner_type = 'ATMMachine', owner_id = 2, label = 'ATM B' },
            }
        end
        return {}
    end

    local atms = ATMMachine:with('interaction'):get()
    Database.query = original

    eq(#atms, 2, 'morphOne eagerLoad: both base rows returned')
    truthy(atms[1].interaction, 'morphOne eagerLoad: first instance has interaction')
    truthy(atms[2].interaction, 'morphOne eagerLoad: second instance has interaction')
    eq(atms[1].interaction.label, 'ATM A', 'morphOne eagerLoad: correct interaction for first')
    eq(atms[2].interaction.label, 'ATM B', 'morphOne eagerLoad: correct interaction for second')
    eqList(interactionParams, {1, 2}, 'morphOne eagerLoad: batched owner_id IN query')
end)

test('BaseModel.with: morphMany distributes all related rows per instance', function()
    local Post = BaseModel:extend('posts')
    Post.primaryKey = 'id'
    Post.timestamps = false

    local Comment = BaseModel:extend('comments')
    Comment.primaryKey = 'id'
    Comment.timestamps = false

    function Post:comments()
        return self:morphMany(Comment, 'owner_id', 'owner_type', 'Post')
    end

    local original = Database.query
    Database.query = function(sql, params)
        if sql:find('FROM `posts`') then
            return {{ id = 1 }, { id = 2 }}
        elseif sql:find('FROM `comments`') then
            return {
                { id = 10, owner_type = 'Post', owner_id = 1, body = 'A' },
                { id = 11, owner_type = 'Post', owner_id = 1, body = 'B' },
                { id = 12, owner_type = 'Post', owner_id = 2, body = 'C' },
            }
        end
        return {}
    end

    local posts = Post:with('comments'):get()
    Database.query = original

    eq(#posts[1].comments, 2, 'morphMany eagerLoad: post 1 gets 2 comments')
    eq(#posts[2].comments, 1, 'morphMany eagerLoad: post 2 gets 1 comment')
    eq(posts[1].comments[1].body, 'A', 'morphMany eagerLoad: first comment body')
    eq(posts[2].comments[1].body, 'C', 'morphMany eagerLoad: only post2 comment')
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
lua5.4 tests/orm_spec.lua 2>&1 | tail -20
```

Expected: failures on all new morph tests (`morphOne`, `morphMany`, `morphTo` not defined)

- [ ] **Step 3: Add morphOne/morphMany/morphTo constructors to BaseModel**

In `core/server/ORM/BaseModel.lua`, after the `belongsToMany` constructor (around line 452), add:

```lua
--- Define a morphOne relationship (this model owns one related row via owner_type/owner_id)
--- owner_type value must equal the Lua global name of this model class.
function BaseModel:morphOne(relatedModel, ownerIdKey, ownerTypeKey, ownerTypeValue)
    return {
        type = 'morphOne',
        relatedModel = relatedModel,
        ownerIdKey = ownerIdKey,
        ownerTypeKey = ownerTypeKey,
        ownerTypeValue = ownerTypeValue,
        localKey = self.primaryKey,
    }
end

--- Define a morphMany relationship (this model owns many related rows via owner_type/owner_id)
function BaseModel:morphMany(relatedModel, ownerIdKey, ownerTypeKey, ownerTypeValue)
    return {
        type = 'morphMany',
        relatedModel = relatedModel,
        ownerIdKey = ownerIdKey,
        ownerTypeKey = ownerTypeKey,
        ownerTypeValue = ownerTypeValue,
        localKey = self.primaryKey,
    }
end

--- Define a morphTo relationship (resolve this row's polymorphic owner)
--- Reads self.attributes[ownerTypeKey] as a _G key to find the model class,
--- then calls :find(self.attributes[ownerIdKey]) on it.
function BaseModel:morphTo(ownerTypeKey, ownerIdKey)
    return {
        type = 'morphTo',
        ownerTypeKey = ownerTypeKey,
        ownerIdKey = ownerIdKey,
    }
end
```

- [ ] **Step 4: Add morph dispatch to load()**

In `BaseModel:load()`, after the `belongsToMany` branch (before the closing `end` at the return), add:

```lua
    elseif relation.type == 'morphOne' then
        local localValue = self.attributes[relation.localKey]
        local result = relation.relatedModel:newQuery()
            :where(relation.ownerTypeKey, relation.ownerTypeValue)
            :where(relation.ownerIdKey, localValue)
            :first()
        if result then
            self.relations[relationName] = result
        end
    elseif relation.type == 'morphMany' then
        local localValue = self.attributes[relation.localKey]
        self.relations[relationName] = relation.relatedModel:newQuery()
            :where(relation.ownerTypeKey, relation.ownerTypeValue)
            :where(relation.ownerIdKey, localValue)
            :get()
    elseif relation.type == 'morphTo' then
        local ownerType = self.attributes[relation.ownerTypeKey]
        local ownerId   = self.attributes[relation.ownerIdKey]
        local model = ownerType and _G[ownerType]
        if model and ownerId then
            self.relations[relationName] = model:find(ownerId)
        end
```

- [ ] **Step 5: Add morph dispatch to loadAsync()**

In `BaseModel:loadAsync()`, after the `belongsToMany` async branch, add:

```lua
    elseif relation.type == 'morphOne' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery()
            :where(relation.ownerTypeKey, relation.ownerTypeValue)
            :where(relation.ownerIdKey, localValue)
            :firstAsync(function(result)
                if result then self.relations[relationName] = result end
                callback(self.relations[relationName])
            end)
    elseif relation.type == 'morphMany' then
        local localValue = self.attributes[relation.localKey]
        relation.relatedModel:newQuery()
            :where(relation.ownerTypeKey, relation.ownerTypeValue)
            :where(relation.ownerIdKey, localValue)
            :getAsync(function(models)
                self.relations[relationName] = models
                callback(models)
            end)
    elseif relation.type == 'morphTo' then
        local ownerType = self.attributes[relation.ownerTypeKey]
        local ownerId   = self.attributes[relation.ownerIdKey]
        local model = ownerType and _G[ownerType]
        if model and ownerId then
            model:newQuery():where(model.primaryKey, ownerId):firstAsync(function(result)
                self.relations[relationName] = result
                callback(result)
            end)
        else
            callback(nil)
        end
```

- [ ] **Step 6: Add morph dispatch to eagerLoad()**

In `BaseModel:eagerLoad()`, after the `belongsToMany` branch (before the `if rest ~= ''` block), add:

```lua
    elseif relation.type == 'morphOne' then
        local localValues = {}
        for _, inst in ipairs(instances) do
            table.insert(localValues, inst.attributes[relation.localKey])
        end
        local rows = related:newQuery()
            :where(relation.ownerTypeKey, relation.ownerTypeValue)
            :whereIn(relation.ownerIdKey, localValues)
            :get()
        local byOwnerId = {}
        for _, row in ipairs(rows) do
            byOwnerId[row.attributes[relation.ownerIdKey]] = row
        end
        for _, inst in ipairs(instances) do
            inst.relations[segment] = byOwnerId[inst.attributes[relation.localKey]]
        end
    elseif relation.type == 'morphMany' then
        local localValues = {}
        for _, inst in ipairs(instances) do
            table.insert(localValues, inst.attributes[relation.localKey])
        end
        local rows = related:newQuery()
            :where(relation.ownerTypeKey, relation.ownerTypeValue)
            :whereIn(relation.ownerIdKey, localValues)
            :get()
        local byOwnerId = {}
        for _, inst in ipairs(instances) do
            inst.relations[segment] = {}
            byOwnerId[inst.attributes[relation.localKey]] = inst
        end
        for _, row in ipairs(rows) do
            local owner = byOwnerId[row.attributes[relation.ownerIdKey]]
            if owner then
                table.insert(owner.relations[segment], row)
            end
        end
    elseif relation.type == 'morphTo' then
        -- Group instances by owner_type; batch one query per distinct type.
        local byType = {}
        for _, inst in ipairs(instances) do
            local ownerType = inst.attributes[relation.ownerTypeKey]
            if ownerType then
                byType[ownerType] = byType[ownerType] or {}
                table.insert(byType[ownerType], inst)
            end
        end
        for ownerType, group in pairs(byType) do
            local model = _G[ownerType]
            if model then
                local ids = {}
                for _, inst in ipairs(group) do
                    table.insert(ids, inst.attributes[relation.ownerIdKey])
                end
                local rows = model:newQuery():whereIn(model.primaryKey, ids):get()
                local byId = {}
                for _, row in ipairs(rows) do
                    byId[row.attributes[model.primaryKey]] = row
                end
                for _, inst in ipairs(group) do
                    inst.relations[segment] = byId[inst.attributes[relation.ownerIdKey]]
                end
            end
        end
```

Note: `eagerLoad` reads `relation.relatedModel` from the first instance's relation call. For `morphTo` there is no single `relatedModel` — the `related` local will be nil. The code above does NOT use `related`; it uses `_G[ownerType]` directly. Make sure the `related` local is not dereferenced for the morphTo branch.

- [ ] **Step 7: Run tests to verify they pass**

```bash
lua5.4 tests/orm_spec.lua 2>&1 | tail -20
```

Expected: all tests pass, `0 failed`

- [ ] **Step 8: Commit**

```bash
git add core/server/ORM/BaseModel.lua tests/orm_spec.lua
git commit -m "feat(orm): add morphOne, morphMany, morphTo relation types"
```

---

## Task 2: Core — interactions owner columns + Interaction model

**Files:**
- Create: `core/server/database/migrations/2026_08_17_180000_add_owner_to_interactions_table.lua`
- Modify: `core/server/Models/Interaction.lua`

**Interfaces:**
- Consumes: `morphTo` from Task 1
- Produces:
  - `Interaction` model with full `fillable` including `owner_type`, `owner_id`
  - `Interaction:owner()` morphTo relation
  - Migration that adds `owner_type VARCHAR(50) nullable`, `owner_id INT nullable`, composite index

- [ ] **Step 1: Write the migration**

Create `core/server/database/migrations/2026_08_17_180000_add_owner_to_interactions_table.lua`:

```lua
return {
    up = function()
        Schema.table('interactions', function(table)
            table:string('owner_type', 50):nullable()
            table:integer('owner_id'):nullable()
            table:index({'owner_type', 'owner_id'})
        end)
        print('[Migration] Added owner_type/owner_id to interactions')
    end,

    down = function()
        Database.query('ALTER TABLE `interactions` DROP INDEX `interactions_owner_type_owner_id_index`', {})
        Schema.dropColumn('interactions', 'owner_id')
        Schema.dropColumn('interactions', 'owner_type')
        print('[Migration] Dropped owner_type/owner_id from interactions')
    end
}
```

- [ ] **Step 2: Rewrite Interaction model**

Replace the entire content of `core/server/Models/Interaction.lua`:

```lua
Interaction = BaseModel:extend('interactions')

Interaction.primaryKey = 'id'
Interaction.timestamps = true
Interaction.fillable = {
    'x', 'y', 'z', 'range', 'label', 'action_id', 'options', 'enabled',
    'owner_type', 'owner_id',
}

function Interaction:owner()
    return self:morphTo('owner_type', 'owner_id')
end

return Interaction
```

- [ ] **Step 3: Commit**

```bash
git add core/server/database/migrations/2026_08_17_180000_add_owner_to_interactions_table.lua
git add core/server/Models/Interaction.lua
git commit -m "feat(core): add owner_type/owner_id to interactions, update Interaction model"
```

---

## Task 3: oblsk_banking — ATMMachine model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_banking/server/migrations/2026_08_17_180001_drop_interaction_id_from_atm_machines_table.lua`
- Modify: `plugins/oblsk_banking/server/models/ATMMachine.lua`
- Modify: `plugins/oblsk_banking/server/services/AtmSeeder.lua`
- Modify: `plugins/oblsk_banking/server/main.lua` (interaction reads after ATM lookup)

**Interfaces:**
- Consumes: `morphOne` from Task 1, `Interaction` model from Task 2

- [ ] **Step 1: Write the migration**

Create `plugins/oblsk_banking/server/migrations/2026_08_17_180001_drop_interaction_id_from_atm_machines_table.lua`:

```lua
return {
    up = function()
        Database.query('ALTER TABLE `atm_machines` DROP FOREIGN KEY `atm_machines_interaction_id_foreign`', {})
        Schema.dropColumn('atm_machines', 'interaction_id')
        print('[Migration] Dropped interaction_id from atm_machines')
    end,

    down = function()
        Schema.table('atm_machines', function(table)
            table:integer('interaction_id')
        end)
        print('[Migration] Re-added interaction_id to atm_machines (FK not restored)')
    end
}
```

- [ ] **Step 2: Rewrite ATMMachine model**

Replace `plugins/oblsk_banking/server/models/ATMMachine.lua`:

```lua
ATMMachine = BaseModel:extend('atm_machines')

ATMMachine.primaryKey = 'id'
ATMMachine.timestamps = true
ATMMachine.fillable = { 'name', 'max_cash', 'cash_amount' }

function ATMMachine:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ATMMachine')
end

return ATMMachine
```

- [ ] **Step 3: Rewrite AtmSeeder.lua**

Replace `plugins/oblsk_banking/server/services/AtmSeeder.lua`:

```lua
-- plugins/oblsk_banking/server/services/AtmSeeder.lua
--- AtmSeeder - creates atm_machines + interactions rows from
--- BankingConfig.Atms at boot, idempotently. Never overwrites an existing
--- atm_machines row's cash_amount - config is the seed, the DB row is the
--- live authority after that (so a restart doesn't silently refill an ATM
--- that's since been drained).
AtmSeeder = {}

local function ensureAtm(atmConfig)
    local existing = ATMMachine:where('name', atmConfig.name):first()
    if existing then
        return existing.id
    end

    local maxCash = atmConfig.max_cash or 0
    local atm = ATMMachine:create({
        name = atmConfig.name,
        max_cash = maxCash,
        cash_amount = atmConfig.cash_amount or maxCash,
    })

    Interaction:create({
        x = atmConfig.x, y = atmConfig.y, z = atmConfig.z,
        range = atmConfig.range or 1.5,
        label = atmConfig.label or 'Use ATM',
        owner_type = 'ATMMachine',
        owner_id = atm.id,
    })

    print('[Banking] seeded ATM: ' .. atmConfig.name .. ' (#' .. tostring(atm.id) .. ')')
    return atm.id
end

function AtmSeeder.ensure()
    for _, atmConfig in ipairs(BankingConfig.Atms or {}) do
        ensureAtm(atmConfig)
    end
end

return AtmSeeder
```

- [ ] **Step 4: Update ATM interaction reads in main.lua**

In `plugins/oblsk_banking/server/main.lua`, find the two places that read ATM interaction and update them. The pattern `ATMMachine:find(atmId)` already returns an ATM; now load its interaction:

Replace both occurrences of:
```lua
local atm = atmId and ATMMachine:find(atmId) or nil
```
with:
```lua
local atm = atmId and ATMMachine:find(atmId) or nil
local atmInteraction = atm and atm:load('interaction') or nil
```

Then update the sync payload references from `atm.cash_amount` etc. (these stay on `atm`) and any coordinate references (those now come from `atmInteraction`).

Also update `registerAllAtms` to use the relation instead of raw QB:

Find:
```lua
local atms = ATMMachine:all()
for _, atm in ipairs(atms) do
    local interaction = QueryBuilder.new('interactions'):where('id', atm.interaction_id):firstSync()
```

Replace with:
```lua
local atms = ATMMachine:all()
for _, atm in ipairs(atms) do
    local interaction = atm:load('interaction')
```

- [ ] **Step 5: Update BankingService ATM lookup**

In `plugins/oblsk_banking/server/services/BankingService.lua`, line 189:

Find:
```lua
        atm = ATMMachine:find(atmId)
```

The `atm` variable here is already the ATMMachine row. If the service needs the interaction's coordinates (for InteractionService calls), load it:
```lua
        atm = ATMMachine:find(atmId)
        -- (load interaction only if needed downstream; atm.cash_amount etc. still on atm)
```

Check all downstream uses of `atm` in BankingService — if any reference `atm.interaction_id`, replace with `atm:load('interaction').id`.

- [ ] **Step 6: Commit**

```bash
git add plugins/oblsk_banking/server/migrations/2026_08_17_180001_drop_interaction_id_from_atm_machines_table.lua
git add plugins/oblsk_banking/server/models/ATMMachine.lua
git add plugins/oblsk_banking/server/services/AtmSeeder.lua
git add plugins/oblsk_banking/server/main.lua
git add plugins/oblsk_banking/server/services/BankingService.lua
git commit -m "refactor(banking): ATMMachine uses morphOne interaction"
```

---

## Task 4: oblsk_garage — Garage model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_garage/server/migrations/2026_08_17_180002_drop_interaction_id_from_garages_table.lua`
- Modify: `plugins/oblsk_garage/server/models/Garage.lua`
- Modify: `plugins/oblsk_garage/server/services/GarageService.lua`
- Modify: `plugins/oblsk_garage/tests/garage_model_spec.lua`

**Interfaces:**
- Consumes: `morphOne` from Task 1, `Interaction` from Task 2

- [ ] **Step 1: Write the migration**

```lua
-- plugins/oblsk_garage/server/migrations/2026_08_17_180002_drop_interaction_id_from_garages_table.lua
return {
    up = function()
        Database.query('ALTER TABLE `garages` DROP INDEX `garages_interaction_id_unique`', {})
        Database.query('ALTER TABLE `garages` DROP FOREIGN KEY `garages_interaction_id_foreign`', {})
        Schema.dropColumn('garages', 'interaction_id')
        print('[Migration] Dropped interaction_id from garages')
    end,

    down = function()
        Schema.table('garages', function(table)
            table:integer('interaction_id')
        end)
        print('[Migration] Re-added interaction_id to garages (FK/unique not restored)')
    end
}
```

- [ ] **Step 2: Rewrite Garage model**

Replace `plugins/oblsk_garage/server/models/Garage.lua`:

```lua
Garage = BaseModel:extend('garages')

Garage.primaryKey = 'id'
Garage.timestamps = true
Garage.fillable = { 'name', 'type' }

function Garage:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'Garage')
end

return Garage
```

- [ ] **Step 3: Update garage model test**

In `plugins/oblsk_garage/tests/garage_model_spec.lua`, replace the existing test with:

```lua
test('Garage fillable excludes interaction_id, includes name and type', function()
    local g = Garage.new({ name = 'Mission Row', type = 'public', interaction_id = 1 })
    eq(g.attributes.name, 'Mission Row')
    eq(g.attributes.type, 'public')
    -- interaction_id is not fillable — not stored on the garage row
    falsy(g.attributes.interaction_id, 'interaction_id must not be stored on Garage')
end)

test('Garage:interaction() returns a morphOne relation descriptor', function()
    local g = Garage.new({ name = 'Test' })
    local rel = g:interaction()
    eq(rel.type, 'morphOne', 'relation type is morphOne')
    eq(rel.ownerTypeValue, 'Garage', 'owner_type value is Garage')
end)
```

Run: `lua5.4 plugins/oblsk_garage/tests/garage_model_spec.lua`

- [ ] **Step 4: Rewrite GarageService.lua**

The key changes in `GarageService.lua`:

**createStation**: Flip order — create Garage first, then Interaction:
```lua
function GarageService.createStation(data)
    local garage = Garage:create({
        name = data.name,
        type = data.type or 'public',
    })
    local interaction = Interaction:create({
        x = data.x, y = data.y, z = data.z,
        range = data.range or 2.0,
        label = data.label or data.name,
        owner_type = 'Garage',
        owner_id = garage.id,
    })
    GarageService.registerStationLive(garage, interaction)
    return shapeStationForAdmin(garage)
end
```

**listStationsForAdmin** (reads interaction): replace QB interaction lookup:
```lua
local interaction = garage and garage:load('interaction') or nil
```

**updateStation**: replace QB reads/updates:
```lua
function GarageService.updateStation(garageId, data)
    local garage = Garage:find(garageId)
    if not garage then return false, 'Garage not found' end

    local stationPatch = {}
    if data.name ~= nil then stationPatch.name = data.name end
    if data.type ~= nil then stationPatch.type = data.type end
    if next(stationPatch) then garage:update(stationPatch) end

    local interactionPatch = {}
    for _, field in ipairs({ 'x', 'y', 'z', 'range', 'label' }) do
        if data[field] ~= nil then interactionPatch[field] = data[field] end
    end
    if next(interactionPatch) then
        local interaction = garage:load('interaction')
        interaction:update(interactionPatch)
        InteractionService.updateByDbId(interaction.id, interactionPatch)
    end

    local updated = Garage:find(garageId)
    return true, shapeStationForAdmin(updated)
end
```

**deleteStation**: replace QB delete:
```lua
function GarageService.deleteStation(garageId)
    local garage = Garage:find(garageId)
    if not garage then return false, 'Garage not found' end

    local interaction = garage:load('interaction')
    if interaction then
        InteractionService.unregisterByDbId(interaction.id)
        interaction:delete()
    end
    garage:delete()

    return true, nil
end
```

Replace all remaining `QueryBuilder.new('garages'):...` calls in `GarageService.lua` with equivalent `Garage:...` model calls (`Garage:all()`, `Garage:find(id)`, `Garage:where(...):get()`, etc.).

- [ ] **Step 5: Commit**

```bash
git add plugins/oblsk_garage/server/migrations/2026_08_17_180002_drop_interaction_id_from_garages_table.lua
git add plugins/oblsk_garage/server/models/Garage.lua
git add plugins/oblsk_garage/server/services/GarageService.lua
git add plugins/oblsk_garage/tests/garage_model_spec.lua
git commit -m "refactor(garage): Garage uses morphOne interaction"
```

---

## Task 5: oblsk_shop — Shop model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_shop/server/migrations/2026_08_17_180003_drop_interaction_id_from_shops_table.lua`
- Create: `plugins/oblsk_shop/server/models/Shop.lua`
- Modify: `plugins/oblsk_shop/server/services/ShopService.lua`
- Modify: `plugins/oblsk_shop/server/main.lua`

**Interfaces:**
- Consumes: `morphOne` from Task 1, `Interaction` from Task 2

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `shops` DROP FOREIGN KEY `shops_interaction_id_foreign`', {})
        Schema.dropColumn('shops', 'interaction_id')
        print('[Migration] Dropped interaction_id from shops')
    end,
    down = function()
        Schema.table('shops', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to shops (FK not restored)')
    end
}
```

- [ ] **Step 2: Create Shop model**

Create `plugins/oblsk_shop/server/models/Shop.lua`:

```lua
Shop = BaseModel:extend('shops')

Shop.primaryKey = 'id'
Shop.timestamps = true
Shop.fillable = { 'name' }

function Shop:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'Shop')
end

return Shop
```

- [ ] **Step 3: Rewrite ShopService.lua and main.lua**

Follow the same pattern as GarageService:

**Create**: `Shop:create({ name=... })` first, then `Interaction:create({ ..., owner_type='Shop', owner_id=shop.id })`.

**Read interaction**: `shop:load('interaction')` instead of QB lookup by `shop.interaction_id`.

**Update**: `interaction:update(patch)` + `InteractionService.updateByDbId(interaction.id, patch)`.

**Delete**: `interaction:delete()` + `shop:delete()`.

Replace all `QueryBuilder.new('shops'):...` with `Shop:...` model calls.

In `main.lua`, replace any `QueryBuilder.new('shops')` calls with Shop model calls.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_shop/server/migrations/2026_08_17_180003_drop_interaction_id_from_shops_table.lua
git add plugins/oblsk_shop/server/models/Shop.lua
git add plugins/oblsk_shop/server/services/ShopService.lua
git add plugins/oblsk_shop/server/main.lua
git commit -m "refactor(shop): Shop uses morphOne interaction"
```

---

## Task 6: oblsk_vendingmachine — VendingMachineShop model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_vendingmachine/server/migrations/2026_08_17_180004_drop_interaction_id_from_vendingmachine_shops_table.lua`
- Create: `plugins/oblsk_vendingmachine/server/models/VendingMachineShop.lua`
- Modify: `plugins/oblsk_vendingmachine/server/services/VendingMachineService.lua`
- Modify: `plugins/oblsk_vendingmachine/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `vendingmachine_shops` DROP FOREIGN KEY `vendingmachine_shops_interaction_id_foreign`', {})
        Schema.dropColumn('vendingmachine_shops', 'interaction_id')
        print('[Migration] Dropped interaction_id from vendingmachine_shops')
    end,
    down = function()
        Schema.table('vendingmachine_shops', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to vendingmachine_shops')
    end
}
```

- [ ] **Step 2: Create VendingMachineShop model**

```lua
VendingMachineShop = BaseModel:extend('vendingmachine_shops')

VendingMachineShop.primaryKey = 'id'
VendingMachineShop.timestamps = true
VendingMachineShop.fillable = { 'name' }

function VendingMachineShop:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'VendingMachineShop')
end

return VendingMachineShop
```

- [ ] **Step 3: Rewrite VendingMachineService + main.lua**

Same pattern: create VendingMachineShop first → create Interaction with owner_type='VendingMachineShop'. Read/update/delete via `shop:load('interaction')`. Replace all QB calls with model syntax.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_vendingmachine/server/migrations/2026_08_17_180004_drop_interaction_id_from_vendingmachine_shops_table.lua
git add plugins/oblsk_vendingmachine/server/models/VendingMachineShop.lua
git add plugins/oblsk_vendingmachine/server/services/VendingMachineService.lua
git add plugins/oblsk_vendingmachine/server/main.lua
git commit -m "refactor(vendingmachine): VendingMachineShop uses morphOne interaction"
```

---

## Task 7: oblsk_gasstation — GasstationStation model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_gasstation/server/migrations/2026_08_17_180005_drop_interaction_id_from_gasstation_stations_table.lua`
- Create: `plugins/oblsk_gasstation/server/models/GasstationStation.lua`
- Modify: `plugins/oblsk_gasstation/server/services/GasStationService.lua`
- Modify: `plugins/oblsk_gasstation/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `gasstation_stations` DROP INDEX `gasstation_stations_interaction_id_unique`', {})
        Database.query('ALTER TABLE `gasstation_stations` DROP FOREIGN KEY `gasstation_stations_interaction_id_foreign`', {})
        Schema.dropColumn('gasstation_stations', 'interaction_id')
        print('[Migration] Dropped interaction_id from gasstation_stations')
    end,
    down = function()
        Schema.table('gasstation_stations', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to gasstation_stations')
    end
}
```

- [ ] **Step 2: Create GasstationStation model**

```lua
GasstationStation = BaseModel:extend('gasstation_stations')

GasstationStation.primaryKey = 'id'
GasstationStation.timestamps = true
GasstationStation.fillable = { 'name', 'organization_id' }

function GasstationStation:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'GasstationStation')
end

return GasstationStation
```

- [ ] **Step 3: Rewrite GasStationService + main.lua**

Same pattern: create GasstationStation first → create Interaction with owner_type='GasstationStation'. Read/update/delete via relation. Replace all QB calls.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_gasstation/server/migrations/2026_08_17_180005_drop_interaction_id_from_gasstation_stations_table.lua
git add plugins/oblsk_gasstation/server/models/GasstationStation.lua
git add plugins/oblsk_gasstation/server/services/GasStationService.lua
git add plugins/oblsk_gasstation/server/main.lua
git commit -m "refactor(gasstation): GasstationStation uses morphOne interaction"
```

---

## Task 8: oblsk_mechanic — MechanicStation model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_mechanic/server/migrations/2026_08_17_180006_drop_interaction_id_from_mechanic_stations_table.lua`
- Create: `plugins/oblsk_mechanic/server/models/MechanicStation.lua`
- Modify: `plugins/oblsk_mechanic/server/services/MechanicService.lua`
- Modify: `plugins/oblsk_mechanic/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `mechanic_stations` DROP INDEX `mechanic_stations_interaction_id_unique`', {})
        Database.query('ALTER TABLE `mechanic_stations` DROP FOREIGN KEY `mechanic_stations_interaction_id_foreign`', {})
        Schema.dropColumn('mechanic_stations', 'interaction_id')
        print('[Migration] Dropped interaction_id from mechanic_stations')
    end,
    down = function()
        Schema.table('mechanic_stations', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to mechanic_stations')
    end
}
```

- [ ] **Step 2: Create MechanicStation model**

```lua
MechanicStation = BaseModel:extend('mechanic_stations')

MechanicStation.primaryKey = 'id'
MechanicStation.timestamps = true
MechanicStation.fillable = { 'name', 'organization_id' }

function MechanicStation:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'MechanicStation')
end

return MechanicStation
```

- [ ] **Step 3: Rewrite MechanicService + main.lua**

Same pattern: create MechanicStation → Interaction(owner_type='MechanicStation'). Read/update/delete via relation. Replace all QB calls.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_mechanic/server/migrations/2026_08_17_180006_drop_interaction_id_from_mechanic_stations_table.lua
git add plugins/oblsk_mechanic/server/models/MechanicStation.lua
git add plugins/oblsk_mechanic/server/services/MechanicService.lua
git add plugins/oblsk_mechanic/server/main.lua
git commit -m "refactor(mechanic): MechanicStation uses morphOne interaction"
```

---

## Task 9: oblsk_cardealer — CarDealerShop model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_cardealer/server/migrations/2026_08_17_180007_drop_interaction_id_from_cardealer_shops_table.lua`
- Create: `plugins/oblsk_cardealer/server/models/CarDealerShop.lua`
- Modify: `plugins/oblsk_cardealer/server/services/CarDealerService.lua`
- Modify: `plugins/oblsk_cardealer/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `cardealer_shops` DROP INDEX `cardealer_shops_interaction_id_unique`', {})
        Database.query('ALTER TABLE `cardealer_shops` DROP FOREIGN KEY `cardealer_shops_interaction_id_foreign`', {})
        Schema.dropColumn('cardealer_shops', 'interaction_id')
        print('[Migration] Dropped interaction_id from cardealer_shops')
    end,
    down = function()
        Schema.table('cardealer_shops', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to cardealer_shops')
    end
}
```

- [ ] **Step 2: Create CarDealerShop model**

```lua
CarDealerShop = BaseModel:extend('cardealer_shops')

CarDealerShop.primaryKey = 'id'
CarDealerShop.timestamps = true
CarDealerShop.fillable = { 'name', 'garage_id' }

function CarDealerShop:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'CarDealerShop')
end

return CarDealerShop
```

- [ ] **Step 3: Rewrite CarDealerService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_cardealer/server/migrations/2026_08_17_180007_drop_interaction_id_from_cardealer_shops_table.lua
git add plugins/oblsk_cardealer/server/models/CarDealerShop.lua
git add plugins/oblsk_cardealer/server/services/CarDealerService.lua
git add plugins/oblsk_cardealer/server/main.lua
git commit -m "refactor(cardealer): CarDealerShop uses morphOne interaction"
```

---

## Task 10: oblsk_clothesshop — ClothesShop model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_clothesshop/server/migrations/2026_08_17_180008_drop_interaction_id_from_clothes_shops_table.lua`
- Create: `plugins/oblsk_clothesshop/server/models/ClothesShop.lua`
- Modify: `plugins/oblsk_clothesshop/server/services/ClothesShopService.lua`
- Modify: `plugins/oblsk_clothesshop/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `clothes_shops` DROP FOREIGN KEY `clothes_shops_interaction_id_foreign`', {})
        Schema.dropColumn('clothes_shops', 'interaction_id')
        print('[Migration] Dropped interaction_id from clothes_shops')
    end,
    down = function()
        Schema.table('clothes_shops', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to clothes_shops')
    end
}
```

- [ ] **Step 2: Create ClothesShop model**

```lua
ClothesShop = BaseModel:extend('clothes_shops')

ClothesShop.primaryKey = 'id'
ClothesShop.timestamps = true
ClothesShop.fillable = { 'name' }

function ClothesShop:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ClothesShop')
end

return ClothesShop
```

- [ ] **Step 3: Rewrite ClothesShopService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_clothesshop/server/migrations/2026_08_17_180008_drop_interaction_id_from_clothes_shops_table.lua
git add plugins/oblsk_clothesshop/server/models/ClothesShop.lua
git add plugins/oblsk_clothesshop/server/services/ClothesShopService.lua
git add plugins/oblsk_clothesshop/server/main.lua
git commit -m "refactor(clothesshop): ClothesShop uses morphOne interaction"
```

---

## Task 11: oblsk_tattoo — TattooShop model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_tattoo/server/migrations/2026_08_17_180009_drop_interaction_id_from_tattoo_shops_table.lua`
- Create: `plugins/oblsk_tattoo/server/models/TattooShop.lua`
- Modify: `plugins/oblsk_tattoo/server/services/TattooService.lua`
- Modify: `plugins/oblsk_tattoo/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `tattoo_shops` DROP FOREIGN KEY `tattoo_shops_interaction_id_foreign`', {})
        Schema.dropColumn('tattoo_shops', 'interaction_id')
        print('[Migration] Dropped interaction_id from tattoo_shops')
    end,
    down = function()
        Schema.table('tattoo_shops', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to tattoo_shops')
    end
}
```

- [ ] **Step 2: Create TattooShop model**

```lua
TattooShop = BaseModel:extend('tattoo_shops')

TattooShop.primaryKey = 'id'
TattooShop.timestamps = true
TattooShop.fillable = { 'business_name', 'free_mode' }

function TattooShop:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'TattooShop')
end

return TattooShop
```

- [ ] **Step 3: Rewrite TattooService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_tattoo/server/migrations/2026_08_17_180009_drop_interaction_id_from_tattoo_shops_table.lua
git add plugins/oblsk_tattoo/server/models/TattooShop.lua
git add plugins/oblsk_tattoo/server/services/TattooService.lua
git add plugins/oblsk_tattoo/server/main.lua
git commit -m "refactor(tattoo): TattooShop uses morphOne interaction"
```

---

## Task 12: oblsk_terminal — Terminal model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_terminal/server/migrations/2026_08_17_180010_drop_interaction_id_from_terminals_table.lua`
- Create: `plugins/oblsk_terminal/server/models/Terminal.lua`
- Modify: `plugins/oblsk_terminal/server/services/TerminalService.lua`
- Modify: `plugins/oblsk_terminal/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `terminals` DROP FOREIGN KEY `terminals_interaction_id_foreign`', {})
        Schema.dropColumn('terminals', 'interaction_id')
        print('[Migration] Dropped interaction_id from terminals')
    end,
    down = function()
        Schema.table('terminals', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to terminals')
    end
}
```

- [ ] **Step 2: Create Terminal model**

```lua
Terminal = BaseModel:extend('terminals')

Terminal.primaryKey = 'id'
Terminal.timestamps = true
Terminal.fillable = { 'business_name' }

function Terminal:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'Terminal')
end

return Terminal
```

- [ ] **Step 3: Rewrite TerminalService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_terminal/server/migrations/2026_08_17_180010_drop_interaction_id_from_terminals_table.lua
git add plugins/oblsk_terminal/server/models/Terminal.lua
git add plugins/oblsk_terminal/server/services/TerminalService.lua
git add plugins/oblsk_terminal/server/main.lua
git commit -m "refactor(terminal): Terminal uses morphOne interaction"
```

---

## Task 13: oblsk_crafting — CraftingPoint model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_crafting/server/migrations/2026_08_17_180011_drop_interaction_id_from_crafting_points_table.lua`
- Create: `plugins/oblsk_crafting/server/models/CraftingPoint.lua`
- Modify: `plugins/oblsk_crafting/server/services/CraftingSeeder.lua`
- Modify: `plugins/oblsk_crafting/server/services/CraftingService.lua`
- Modify: `plugins/oblsk_crafting/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `crafting_points` DROP INDEX `crafting_points_interaction_id_unique`', {})
        Database.query('ALTER TABLE `crafting_points` DROP FOREIGN KEY `crafting_points_interaction_id_foreign`', {})
        Schema.dropColumn('crafting_points', 'interaction_id')
        print('[Migration] Dropped interaction_id from crafting_points')
    end,
    down = function()
        Schema.table('crafting_points', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to crafting_points')
    end
}
```

- [ ] **Step 2: Create CraftingPoint model**

```lua
CraftingPoint = BaseModel:extend('crafting_points')

CraftingPoint.primaryKey = 'id'
CraftingPoint.timestamps = true
CraftingPoint.fillable = { 'name' }

function CraftingPoint:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'CraftingPoint')
end

return CraftingPoint
```

- [ ] **Step 3: Rewrite CraftingSeeder + CraftingService + main.lua** (same pattern)

CraftingSeeder's create flow: `CraftingPoint:create({ name=... })` → `Interaction:create({ ..., owner_type='CraftingPoint', owner_id=point.id })`.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_crafting/server/migrations/2026_08_17_180011_drop_interaction_id_from_crafting_points_table.lua
git add plugins/oblsk_crafting/server/models/CraftingPoint.lua
git add plugins/oblsk_crafting/server/services/CraftingSeeder.lua
git add plugins/oblsk_crafting/server/services/CraftingService.lua
git add plugins/oblsk_crafting/server/main.lua
git commit -m "refactor(crafting): CraftingPoint uses morphOne interaction"
```

---

## Task 14: oblsk_safe — Safe model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_safe/server/migrations/2026_08_17_180012_drop_interaction_id_from_safes_table.lua`
- Create: `plugins/oblsk_safe/server/models/Safe.lua`
- Modify: `plugins/oblsk_safe/server/services/SafeService.lua`
- Modify: `plugins/oblsk_safe/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `safes` DROP INDEX `safes_interaction_id_unique`', {})
        Database.query('ALTER TABLE `safes` DROP FOREIGN KEY `safes_interaction_id_foreign`', {})
        Schema.dropColumn('safes', 'interaction_id')
        print('[Migration] Dropped interaction_id from safes')
    end,
    down = function()
        Schema.table('safes', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to safes')
    end
}
```

- [ ] **Step 2: Create Safe model**

```lua
Safe = BaseModel:extend('safes')

Safe.primaryKey = 'id'
Safe.timestamps = true
Safe.fillable = { 'name', 'cash_amount', 'max_cash', 'decay_amount', 'last_collected_at' }

function Safe:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'Safe')
end

return Safe
```

- [ ] **Step 3: Rewrite SafeService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_safe/server/migrations/2026_08_17_180012_drop_interaction_id_from_safes_table.lua
git add plugins/oblsk_safe/server/models/Safe.lua
git add plugins/oblsk_safe/server/services/SafeService.lua
git add plugins/oblsk_safe/server/main.lua
git commit -m "refactor(safe): Safe uses morphOne interaction"
```

---

## Task 15: oblsk_billard — BillardTable model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_billard/server/migrations/2026_08_17_180013_drop_interaction_id_from_billard_tables_table.lua`
- Create: `plugins/oblsk_billard/server/models/BillardTable.lua`
- Modify: `plugins/oblsk_billard/server/main.lua`
- Modify: `plugins/oblsk_billard/server/services/BillardTableService.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `billard_tables` DROP INDEX `billard_tables_interaction_id_unique`', {})
        Database.query('ALTER TABLE `billard_tables` DROP FOREIGN KEY `billard_tables_interaction_id_foreign`', {})
        Schema.dropColumn('billard_tables', 'interaction_id')
        print('[Migration] Dropped interaction_id from billard_tables')
    end,
    down = function()
        Schema.table('billard_tables', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to billard_tables')
    end
}
```

- [ ] **Step 2: Create BillardTable model**

```lua
BillardTable = BaseModel:extend('billard_tables')

BillardTable.primaryKey = 'id'
BillardTable.timestamps = true
BillardTable.fillable = { 'x', 'y', 'z', 'heading', 'status' }

function BillardTable:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'BillardTable')
end

return BillardTable
```

- [ ] **Step 3: Rewrite BillardTableService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_billard/server/migrations/2026_08_17_180013_drop_interaction_id_from_billard_tables_table.lua
git add plugins/oblsk_billard/server/models/BillardTable.lua
git add plugins/oblsk_billard/server/services/BillardTableService.lua
git add plugins/oblsk_billard/server/main.lua
git commit -m "refactor(billard): BillardTable uses morphOne interaction"
```

---

## Task 16: oblsk_tuner — TunerShop model + migration + service rewrite

> **Note:** `tuner_shops` has TWO interaction FKs: `interaction_id` (main shop prompt) and `tablet_interaction_id` (optional tablet prompt). Only `interaction_id` is migrated to polymorphic. `tablet_interaction_id` stays as a regular FK pointing to `interactions.id`.

**Files:**
- Create: `plugins/oblsk_tuner/server/migrations/2026_08_17_180014_drop_interaction_id_from_tuner_shops_table.lua`
- Create: `plugins/oblsk_tuner/server/models/TunerShop.lua`
- Modify: `plugins/oblsk_tuner/server/services/TunerService.lua`
- Modify: `plugins/oblsk_tuner/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `tuner_shops` DROP FOREIGN KEY `tuner_shops_interaction_id_foreign`', {})
        Schema.dropColumn('tuner_shops', 'interaction_id')
        print('[Migration] Dropped interaction_id from tuner_shops (tablet_interaction_id kept)')
    end,
    down = function()
        Schema.table('tuner_shops', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to tuner_shops')
    end
}
```

- [ ] **Step 2: Create TunerShop model**

```lua
TunerShop = BaseModel:extend('tuner_shops')

TunerShop.primaryKey = 'id'
TunerShop.timestamps = true
-- tablet_interaction_id stays as a regular FK column
TunerShop.fillable = { 'name', 'tablet_interaction_id', 'organization_id' }

function TunerShop:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'TunerShop')
end

return TunerShop
```

- [ ] **Step 3: Rewrite TunerService + main.lua**

For the main interaction: `TunerShop:create({...})` → `Interaction:create({owner_type='TunerShop', owner_id=shop.id, ...})`.

For the tablet interaction: keep as-is — it's still a regular `interactions` row referenced by `shop.tablet_interaction_id`.

Replace all `QueryBuilder.new('tuner_shops'):...` with `TunerShop:...` model calls.

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_tuner/server/migrations/2026_08_17_180014_drop_interaction_id_from_tuner_shops_table.lua
git add plugins/oblsk_tuner/server/models/TunerShop.lua
git add plugins/oblsk_tuner/server/services/TunerService.lua
git add plugins/oblsk_tuner/server/main.lua
git commit -m "refactor(tuner): TunerShop uses morphOne interaction (tablet_interaction_id unchanged)"
```

---

## Task 17: oblsk_globalmarket — GlobalMarketLocation model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_globalmarket/server/migrations/2026_08_17_180015_drop_interaction_id_from_globalmarket_locations_table.lua`
- Create: `plugins/oblsk_globalmarket/server/models/GlobalMarketLocation.lua`
- Modify: `plugins/oblsk_globalmarket/server/services/GlobalMarketService.lua`
- Modify: `plugins/oblsk_globalmarket/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `globalmarket_locations` DROP INDEX `globalmarket_locations_interaction_id_unique`', {})
        Database.query('ALTER TABLE `globalmarket_locations` DROP FOREIGN KEY `globalmarket_locations_interaction_id_foreign`', {})
        Schema.dropColumn('globalmarket_locations', 'interaction_id')
        print('[Migration] Dropped interaction_id from globalmarket_locations')
    end,
    down = function()
        Schema.table('globalmarket_locations', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to globalmarket_locations')
    end
}
```

- [ ] **Step 2: Create GlobalMarketLocation model**

```lua
GlobalMarketLocation = BaseModel:extend('globalmarket_locations')

GlobalMarketLocation.primaryKey = 'id'
GlobalMarketLocation.timestamps = true
GlobalMarketLocation.fillable = { 'name' }

function GlobalMarketLocation:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'GlobalMarketLocation')
end

return GlobalMarketLocation
```

- [ ] **Step 3: Rewrite GlobalMarketService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_globalmarket/server/migrations/2026_08_17_180015_drop_interaction_id_from_globalmarket_locations_table.lua
git add plugins/oblsk_globalmarket/server/models/GlobalMarketLocation.lua
git add plugins/oblsk_globalmarket/server/services/GlobalMarketService.lua
git add plugins/oblsk_globalmarket/server/main.lua
git commit -m "refactor(globalmarket): GlobalMarketLocation uses morphOne interaction"
```

---

## Task 18: oblsk_shellbuilder — ShellbuilderLocation model + migration + service rewrite

**Files:**
- Create: `plugins/oblsk_shellbuilder/server/migrations/2026_08_17_180016_drop_interaction_id_from_shellbuilder_locations_table.lua`
- Create: `plugins/oblsk_shellbuilder/server/models/ShellbuilderLocation.lua`
- Modify: `plugins/oblsk_shellbuilder/server/services/ShellService.lua`
- Modify: `plugins/oblsk_shellbuilder/server/main.lua`

- [ ] **Step 1: Write the migration**

```lua
return {
    up = function()
        Database.query('ALTER TABLE `shellbuilder_locations` DROP INDEX `shellbuilder_locations_interaction_id_unique`', {})
        Database.query('ALTER TABLE `shellbuilder_locations` DROP FOREIGN KEY `shellbuilder_locations_interaction_id_foreign`', {})
        Schema.dropColumn('shellbuilder_locations', 'interaction_id')
        print('[Migration] Dropped interaction_id from shellbuilder_locations')
    end,
    down = function()
        Schema.table('shellbuilder_locations', function(table) table:integer('interaction_id') end)
        print('[Migration] Re-added interaction_id to shellbuilder_locations')
    end
}
```

- [ ] **Step 2: Create ShellbuilderLocation model**

```lua
ShellbuilderLocation = BaseModel:extend('shellbuilder_locations')

ShellbuilderLocation.primaryKey = 'id'
ShellbuilderLocation.timestamps = true
ShellbuilderLocation.fillable = { 'name' }

function ShellbuilderLocation:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ShellbuilderLocation')
end

return ShellbuilderLocation
```

- [ ] **Step 3: Rewrite ShellService + main.lua** (same pattern)

- [ ] **Step 4: Commit**

```bash
git add plugins/oblsk_shellbuilder/server/migrations/2026_08_17_180016_drop_interaction_id_from_shellbuilder_locations_table.lua
git add plugins/oblsk_shellbuilder/server/models/ShellbuilderLocation.lua
git add plugins/oblsk_shellbuilder/server/services/ShellService.lua
git add plugins/oblsk_shellbuilder/server/main.lua
git commit -m "refactor(shellbuilder): ShellbuilderLocation uses morphOne interaction"
```

---

## Quick Reference: The Repeating Pattern

Every plugin task (3–18) follows this exact shape. Use this as a checklist:

**Migration:**
```lua
-- Drop unique index (if it had one): ALTER TABLE `X` DROP INDEX `X_interaction_id_unique`
-- Drop FK: ALTER TABLE `X` DROP FOREIGN KEY `X_interaction_id_foreign`
-- Drop column: Schema.dropColumn('X', 'interaction_id')
```

**Model:**
```lua
ModelName = BaseModel:extend('table_name')
ModelName.primaryKey = 'id'
ModelName.timestamps = true
ModelName.fillable = { -- all columns EXCEPT interaction_id }

function ModelName:interaction()
    return self:morphOne(Interaction, 'owner_id', 'owner_type', 'ModelName')
end
```

**Service create:**
```lua
local row = ModelName:create({ ... })              -- NO interaction_id field
Interaction:create({ x=..., label=..., owner_type='ModelName', owner_id=row.id })
```

**Service read interaction:**
```lua
local interaction = row:load('interaction')
```

**Service update:**
```lua
local interaction = row:load('interaction')
interaction:update(patch)
InteractionService.updateByDbId(interaction.id, patch)
```

**Service delete:**
```lua
local interaction = row:load('interaction')
if interaction then
    InteractionService.unregisterByDbId(interaction.id)
    interaction:delete()
end
row:delete()
```

**QB→Model replacements:**
| Old | New |
|-----|-----|
| `QueryBuilder.new('X'):where('id', id):firstSync()` | `ModelName:find(id)` |
| `QueryBuilder.new('X'):getSync()` | `ModelName:all()` |
| `QueryBuilder.new('X'):insert({...})` | `ModelName:create({...})` (returns model instance) |
| `QueryBuilder.new('X'):where('id', id):update({...})` | `model:update({...})` |
| `QueryBuilder.new('X'):where('id', id):delete()` | `model:delete()` |
| `QueryBuilder.new('X'):where(k, v):firstSync()` | `ModelName:where(k, v):first()` |
| `QueryBuilder.new('X'):where(k, v):getSync()` | `ModelName:where(k, v):get()` |
