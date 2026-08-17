# Polymorphic Interactions Design

**Date:** 2026-08-17  
**Branch:** refactor/atm-machine-model (ORM work), then a new branch for the full migration

---

## Problem

Every plugin that places a world interaction currently stores `interaction_id` (FK → interactions.id) on its own table. This means:

- The plugin row "owns" the interaction, but the interaction has no self-knowledge of what it belongs to.
- Reading the interaction from a plugin model requires a raw `QueryBuilder.new('interactions'):where('id', model.interaction_id):first()` — no ORM relation.
- `interaction.owner` is impossible to resolve without the caller already knowing the plugin type.

## Goal

Flip ownership onto the `interactions` table via `owner_type` / `owner_id` polymorphic columns. Add `morphOne`, `morphMany`, and `morphTo` to the ORM. Rewrite all 16 affected plugins to use model relations and model syntax throughout.

---

## 1. ORM — BaseModel.lua

### New relation constructors

```lua
-- "I own one related row" — e.g. ATMMachine:interaction()
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

-- "I own many related rows" — same as morphOne but returns a collection
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

-- "I belong to a polymorphic owner" — e.g. Interaction:owner()
-- Resolves via _G[self.attributes[ownerTypeKey]]:find(self.attributes[ownerIdKey])
function BaseModel:morphTo(ownerTypeKey, ownerIdKey)
    return {
        type = 'morphTo',
        ownerTypeKey = ownerTypeKey,
        ownerIdKey = ownerIdKey,
    }
end
```

### load() additions

```lua
elseif relation.type == 'morphOne' then
    local localValue = self.attributes[relation.localKey]
    local result = relation.relatedModel:newQuery()
        :where(relation.ownerTypeKey, relation.ownerTypeValue)
        :where(relation.ownerIdKey, localValue)
        :first()
    if result then self.relations[relationName] = result end

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

Same additions mirrored in `loadAsync()` and `eagerLoad()`.

### eagerLoad() for morphOne / morphMany

Batch query per call: collect all localValues → WHERE owner_type='X' AND owner_id IN (...) → distribute back. Same shape as existing hasOne/hasMany eagerLoad.

### eagerLoad() for morphTo

Group instances by owner_type value → for each distinct type, batch query that model's IDs → distribute back. One DB query per distinct owner_type in the batch.

---

## 2. Schema

### Core migration (interactions table)

New migration in `core/server/database/migrations/`:

```lua
-- 2026_08_17_XXXXXX_add_owner_to_interactions_table.lua
Schema.table('interactions', function(table)
    table:string('owner_type', 50):nullable()
    table:integer('owner_id'):nullable()
    table:index({'owner_type', 'owner_id'})
end)
```

### Per-plugin migrations (drop interaction_id)

One new migration per plugin:

```lua
Schema.table('atm_machines', function(table)
    table:dropForeign('interaction_id')
    table:dropColumn('interaction_id')
end)
```

No cascade behavior is lost — services already delete both sides manually.

**Affected plugins (16):**
oblsk_banking, oblsk_billard, oblsk_cardealer, oblsk_clothesshop, oblsk_crafting,
oblsk_garage, oblsk_gasstation, oblsk_globalmarket, oblsk_mechanic, oblsk_safe,
oblsk_shellbuilder, oblsk_shop, oblsk_tattoo, oblsk_terminal, oblsk_tuner, oblsk_vendingmachine

---

## 3. Interaction Model (core)

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

---

## 4. Plugin Models

Every plugin model gets the full treatment:

- `table`, `primaryKey`, `timestamps`, complete `fillable` (no `interaction_id`)
- All existing relations expressed as ORM relations (replacing any raw QB)
- New `interaction()` morphOne relation

**Convention:** `owner_type` value = the model's Lua global name exactly (e.g. `'ATMMachine'`, `'Garage'`, `'GasstationStation'`). This lets `_G[owner_type]` resolve directly in `morphTo`.

Example (ATMMachine):

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

Plugins that had no model file get one created with full field coverage from their migration schema.

---

## 5. Service & Seeder Rewrites

### Create flow (order flips)

The plugin row must exist before the interaction can reference it via `owner_id`.

```lua
-- Before
local interactionId = QueryBuilder.new('interactions'):insert({ x=..., label=... })
local station = GasstationStation:create({ ..., interaction_id = interactionId })
InteractionService.registerFromDb(interactionId, { ... })

-- After
local station = GasstationStation:create({ ... })
local interaction = Interaction:create({
    x = ..., label = ...,
    owner_type = 'GasstationStation',
    owner_id = station.id,
})
InteractionService.registerFromDb(interaction.id, { ... })
```

### Read / Update / Delete

```lua
-- Before
local interaction = QueryBuilder.new('interactions'):where('id', station.interaction_id):first()
InteractionService.updateByDbId(station.interaction_id, patch)
QueryBuilder.new('interactions'):where('id', station.interaction_id):delete()

-- After
local interaction = station:load('interaction')
InteractionService.updateByDbId(interaction.id, patch)
interaction:update(patch)
-- or for delete:
interaction:delete()
station:delete()
```

All raw `QueryBuilder.new('plugin_table'):...` calls across all service and seeder files are replaced with model-syntax equivalents (`Model:find()`, `Model:create()`, `Model:all()`, `model:update()`, `model:delete()`, etc.).

**InteractionService is unchanged** — it still indexes by `interactions.id` internally; plugins now obtain that id via the relation instead of a stored FK column.

---

## Affected Files Summary

| Area | Files |
|------|-------|
| ORM | `core/server/ORM/BaseModel.lua` |
| Interaction model | `core/server/Models/Interaction.lua` |
| Core migration | 1 new file in `core/server/database/migrations/` |
| Per-plugin migration | 16 new files (one per plugin) |
| Per-plugin model | 16 files created or updated |
| Per-plugin service/seeder | ~32 files updated |

Total: ~66 files touched.
