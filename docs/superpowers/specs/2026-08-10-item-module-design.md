# Item Module (`oblsk_items`) Design

## Goal

Build the `oblsk_items` module: a `BaseItem`/`Item` catalog-and-instance pattern with polymorphic ownership, a generic per-instance depletion mechanic (for consumables like a partially-drunk water bottle), and an item-use pipeline that reuses the existing `ActionService` as its single source of truth for actions, rather than introducing a second registry.

This work also fixes two pre-existing gaps in core that the item-use pipeline depends on being correct:
- `ActionService.register` never persisted anything to the `actions` table, even though that table (with a real integer `id`) already exists via migration and is already referenced elsewhere.
- `KeybindService`'s `keybinds.action_id` is `VARCHAR(100)` storing the string actionId, while `loadPlayerKeybinds`'s query joins `ON k.action_id = a.id` (the integer PK), a join that has never matched anything.

The Vehicle module (`oblsk_vehicles`) is a separate, later spec; nothing here depends on it.

## Background

Obelisk positions itself as developer-first: consistent conventions, one CLI, predictable ORM behavior. An item system is the first real "content" module built on top of the ORM/Services layer established so far, and it's the first place two existing services (`ActionService`, `PolicyService`, `NotificationService`) get reused by module-level code rather than just core's own services.

The design goal throughout: no second parallel mechanism where an existing one already does the job. Item actions run through `ActionService`, not a new item-specific action registry. Item ownership is a plain polymorphic `owner_type`/`owner_id` pair, extensible by just adding a new string value, not a fixed enum or a table per owner kind.

## Architecture

### 1. `ActionService` becomes DB-backed (core fix)

`core/server/Services/ActionService.lua`'s `register` currently only writes to an in-memory `ActionService.registry` table. It now also upserts a row into the existing `actions` table (`id`, `action_id` varchar, `label`, `description`, `options`, `enabled`; no migration change needed, this table's columns already support this), matching on the unique `action_id` varchar column:

```lua
function ActionService.register(actionId, handler, options)
    options = options or {}
    if ActionService.registry[actionId] then
        print('[ActionService] Warning: Overwriting existing action: ' .. actionId)
    end

    local existing = QueryBuilder.new('actions'):where('action_id', actionId):firstSync()
    local dbId
    if existing then
        dbId = existing.id
        QueryBuilder.new('actions'):where('id', dbId):update({
            label = options.label,
            description = options.description,
            options = json.encode(options)
        })
    else
        dbId = QueryBuilder.new('actions'):insert({
            action_id = actionId,
            label = options.label,
            description = options.description,
            options = json.encode(options)
        })
    end

    ActionService.registry[actionId] = { id = actionId, dbId = dbId, handler = handler, options = options }
    ActionService.idToActionId[dbId] = actionId

    print('[ActionService] Registered action: ' .. actionId .. ' (db id ' .. dbId .. ')')
end

--- @param actionId string
--- @return number|nil
function ActionService.getDbId(actionId)
    local entry = ActionService.registry[actionId]
    return entry and entry.dbId
end

--- @param dbId number
--- @return string|nil
function ActionService.resolveDbId(dbId)
    return ActionService.idToActionId[dbId]
end
```

Matching on the unique `action_id` varchar column before inserting means re-registering the same actionId on every server restart always resolves to the same row and the same integer id, never a new row. The table only ever grows when a genuinely new actionId is registered for the first time.

`ActionService.idToActionId = {}` is a new module-level table, initialized alongside the existing `ActionService.registry = {}`.

### 2. `keybinds.action_id` becomes the integer it always claimed to be (core fix)

New migration, `core/server/database/migrations/<timestamp>_fix_keybinds_action_id_type.lua`:

```lua
return {
    up = function()
        Schema.table('keybinds', function(table)
            table:integer('action_id_int')
        end)

        local rows = Database.querySync('SELECT id, action_id FROM keybinds', {})
        for _, row in ipairs(rows or {}) do
            local action = Database.querySync('SELECT id FROM actions WHERE action_id = ?', {row.action_id})
            if action and action[1] then
                Database.updateSync('UPDATE keybinds SET action_id_int = ? WHERE id = ?', {action[1].id, row.id})
            else
                print('[Migration] WARNING: keybind #' .. row.id .. ' references unknown action_id "' .. tostring(row.action_id) .. '", leaving action_id_int NULL')
            end
        end

        Schema.dropColumn('keybinds', 'action_id')
        Schema.renameColumn('keybinds', 'action_id_int', 'action_id')

        print('[Migration] Converted keybinds.action_id to an integer FK against actions.id')
    end,

    down = function()
        error('This migration is not reversible: the original varchar action_id values are not recoverable once dropped.')
    end
}
```

`Blueprint` has no "alter column type" primitive (only add/drop/rename column, see `Schema.lua`), so the type change goes through add-new-column, backfill, drop-old-column, rename-new-column-back, entirely through existing `Schema` methods, no raw `ALTER COLUMN TYPE` needed. A keybind whose stored string doesn't resolve to any registered action is left with `action_id = NULL` rather than aborting the migration; that keybind effectively becomes orphaned data, matching how the rest of the codebase treats unresolvable references (loud warning, not a hard failure).

`core/server/Services/KeybindService.lua`'s two queries keep their join condition as `LEFT JOIN actions a ON k.action_id = a.id` (unchanged, this is now correct), no other change needed there, since the column now genuinely holds `actions.id` values. `registerGlobal(key, actionId, data)`/`registerPlayer(source, key, actionId, data)` still take the string actionId as their public parameter (unchanged signature, since keybinds are registered by module/plugin code the same way actions themselves are), but now resolve it via `ActionService.getDbId(actionId)` before the `INSERT`:

```lua
local dbId = ActionService.getDbId(actionId)
if not dbId then
    print('[KeybindService] Error: action "' .. actionId .. '" is not registered')
    return nil
end
local keybindId = Database.insertSync(sql, {key, dbId, jsonData})
```

### 3. `base_items` / `items` schema

New migrations under `modules/oblsk_items/server/migrations/`, tracked in `modules/oblsk_items/server/migrations.json`:

```lua
Schema.create('base_items', function(table)
    table:id()
    table:string('name', 255):notNullable()
    table:text('description')
    table:string('icon', 255)
    table:float('weight'):notNullable():default(0)
    table:boolean('is_takeable'):default(1)
    table:boolean('is_giveable'):default(1)
    table:boolean('is_dropable'):default(1)
    table:boolean('is_container'):default(0)
    table:boolean('is_useable'):default(0)
    table:boolean('is_stackable'):default(0)
    table:float('step')
    table:string('step_key', 100)
    table:integer('max_stack_amount')
    table:json('data')
    table:json('actions')
    table:timestamps()
end)
```

```lua
Schema.create('items', function(table)
    table:id()
    table:integer('base_item_id'):notNullable()
    table:string('owner_type', 50):notNullable()
    table:integer('owner_id'):notNullable()
    table:json('data')
    table:integer('amount'):default(1)
    table:timestamps()

    table:index({'owner_type', 'owner_id'})
    table:foreign('base_item_id'):references('id'):on('base_items'):onDelete('RESTRICT')
end)
```

`onDelete('RESTRICT')` on `base_item_id` means deleting a `base_items` row is blocked while any `items` row still references it, so removing an item *type* can never silently orphan or cascade-delete a player's actual inventory.

`owner_type` is a plain string, not a fixed enum: `character`, `item` (a container item holding this one), `vehicle_trunk`, `vehicle_glovebox` today, more later (storages, etc.) without a schema change, just a new string value and whatever code creates/queries items with it. No FK constraint on `owner_id` since the target table depends on `owner_type`.

### 4. Stacking

Two `items` rows are eligible to merge into one (`amount` incremented) only when they share the same `base_item_id`, `owner_type`, `owner_id`, **and** byte-identical `data`, compared via `json.encode(a.data) == json.encode(b.data)` (or a normalized-key comparison if key order in the JSON blob isn't guaranteed stable; verify this against how `data` gets written elsewhere before relying on raw string equality). A half-full water bottle never merges with a full one, since their `data.fill_ml` differs.

`base_items.max_stack_amount` (nullable, only meaningful when `is_stackable = true`) caps a single row's `amount`. Adding to a stack that would push `amount` past the cap splits the overflow into a new `items` row instead of failing the operation, e.g. adding 30 of a stackable item capped at 20 to an empty slot produces one row with `amount = 20` and a second with `amount = 10`.

### 5. The depletion mechanic (`step`, `step_key`)

`base_items.step` is a plain number: how much of `data[step_key]` one use consumes. `base_items.step_key` names which key in `data` that is (`fill_ml`, `charge`, `rounds`, anything the item type defines). Both are fixed properties of the item *type*, not something a specific use-pipeline entry configures, so nothing in `base_items.actions`' `data` needs to repeat it. There is no fixed `capacity`/`amount` schema column beyond `step_key` itself, since not every item has this concept and the unit varies per item type; the *capacity* value lives inside `data` as an ordinary key (named by `step_key`), same as the current amount.

- `base_items.data` holds the template's starting value, e.g. `{ "fill_ml": 1000 }` for a 1L water bottle (`step_key = 'fill_ml'`, `step = 100`).
- `items.data` is copied from `base_items.data` at creation (per-instance, mutable from then on).
- Weight for a given `items` row, wherever it's needed (inventory weight totals, drop-on-ground physics, etc.), is computed on read, never cached:

```lua
function Item:getWeight()
    local key = self.baseItem.step_key
    if key and self.baseItem.step and self.data[key] and self.baseItem.data[key] then
        return self.baseItem.weight * (self.data[key] / self.baseItem.data[key])
    end
    return self.baseItem.weight
end
```

### 6. Use pipeline: `base_items.actions`, entirely through `ActionService`

`base_items.actions` is a JSON array of `{ action_id: <integer>, data: {...} }`, referencing `actions.id` (the same integer `ActionService.register` now returns), not a bare string, and not a second registry:

```json
[
  { "action_id": 12, "data": {} },
  { "action_id": 13, "data": { "text": "You drink some water.", "kind": "info" } }
]
```

`ItemService.use(source, item)` loads the item's `BaseItem`, checks `is_useable` (returns early, doing nothing, if false), then runs each entry through the existing `ActionService.execute`, resolving the integer back to the registered string first. Each entry's `data` is merged with `item`/`baseItem` before the call, since `entry.data` only carries the per-step config (like `item:notify`'s text), not which `Item` the pipeline is currently operating on:

```lua
function ItemService.use(source, item)
    local baseItem = BaseItem:findSync(item.base_item_id)
    if not baseItem or not baseItem.is_useable then return end

    for _, entry in ipairs(baseItem.actions or {}) do
        local actionId = ActionService.resolveDbId(entry.action_id)
        if actionId then
            local data = baseItem:copyTable(entry.data or {})
            data.item = item
            data.baseItem = baseItem
            ActionService.execute(source, actionId, data)
        else
            print('[ItemService] WARNING: base_item #' .. baseItem.id .. ' references unknown action db id ' .. tostring(entry.action_id) .. ', skipping')
        end
    end
end
```

Because this is just `ActionService.execute` called in a loop, every existing mechanism already built around actions applies for free: `action:before:<actionId>`/`action:after:<actionId>` hooks (a plugin can hook `action:before:item:consume_step` to intercept a *specific* consumption step generically, without touching `oblsk_items` at all), and `PolicyService` checks (an item action could have a policy attached, gating its use the same way an interaction or keybind action would). The same `action_id` can appear more than once in the array with different `data`. Two `item:notify` entries with different text is just two array entries, no special-casing needed, since `ActionService.execute` already supports being called twice with the same actionId.

Two built-in actions, registered once at module load (`modules/oblsk_items/server/bootstrap.lua` or a dedicated `ItemActions.lua`, loaded via the existing `modules/*/server/**/*.lua` fxmanifest glob):

```lua
ActionService.register('item:consume_step', function(source, data)
    local item, baseItem = data.item, data.baseItem
    if not (item and baseItem and baseItem.step_key and baseItem.step) then return end

    local key = baseItem.step_key
    local current = item.data[key] or 0
    item.data[key] = math.max(0, current - baseItem.step)
    item:saveSync()
end, { label = 'Consume one step of a depletable item' })

ActionService.register('item:notify', function(source, data)
    NotificationService.notify(source, {
        type = data.kind or 'info',
        title = data.title,
        description = data.text
    })
end, { label = 'Send a notification as an item-use side effect' })
```

`item:consume_step` deliberately doesn't remove or destroy the `Item` row once its `data[step_key]` reaches `0`. That's a separate concern (whether an emptied item stays as an inspectable "empty bottle" or disappears), left for a future action type (e.g. `item:destroy_if_empty`) rather than baked into `consume_step` itself, matching the same "everything is one more registered action" philosophy.

## Error Handling

- `base_items.actions` referencing an `action_id` integer with no matching registered action (e.g. the actions table row was deleted, or a module that registered it was removed): `ItemService.use` prints a warning and skips that one entry, continuing the rest of the pipeline, rather than aborting the whole use.
- The keybinds migration's backfill: a keybind whose old string `action_id` doesn't resolve against `actions.action_id` is left with `action_id = NULL` and a printed warning, not a migration failure.
- Stacking overflow past `max_stack_amount`: splits into a new row, never rejected outright.
- `consume_step` reducing `data[key]` below zero: clamp to `0`, don't go negative.
- `ActionService.register` re-registering an existing `action_id`: unchanged existing behavior (prints an overwrite warning, replaces the in-memory handler), now additionally updates (not duplicates) the matching `actions` row.

## Testing

- The weight-ratio formula (`getWeight()`) and the stack-eligibility comparison (identical-`data` check) are pure functions with no DB/native dependency. Real unit tests belong in a new `tests/item_spec.lua`, following the existing `tests/orm_spec.lua`/`tests/obelisk_spec.lua` pattern (self-contained tiny test framework, `lua5.4` runnable).
- `ActionService.register`'s new upsert-into-`actions` behavior is also testable this way: stub `Database`/`QueryBuilder` (or reuse the real `QueryBuilder` against the existing `Database.executeQuery` capture pattern already used in `orm_spec.lua`) and assert that registering the same `actionId` twice performs exactly one insert and one update, never two inserts.
- The keybinds migration's backfill loop, `ItemService.use`'s action-pipeline execution, and anything touching real FXServer natives have no automated test, matching the existing repo convention (no FXServer runtime in this test environment). Manual verification only.

## Out of Scope

- A needs/hunger/thirst system. The water-bottle example motivates the mechanic but no `restore_need` action exists yet; adding one later (once such a system exists) is just one more `ActionService.register` call, no changes to anything built here.
- The Vehicle module (`oblsk_vehicles`), a separate spec that shares only the base/instance and polymorphic-ownership *patterns*, not any code.
- A CLI generator for scaffolding new `base_items`/items-module content (e.g. `make:item`), not requested, can be added later following the existing generator conventions.
- Give/drop/pickup interaction wiring, NUI inventory UI, and container capacity limits (slots/weight caps for `is_container` items). This spec covers the data model and the use pipeline only; the interaction/UI layer that calls into `ItemService` is follow-up work.
