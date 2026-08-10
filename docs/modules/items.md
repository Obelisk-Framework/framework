# Items (`oblsk_items`)

An item catalog (`base_items`) and per-instance inventory items (`items`), plus a use pipeline built entirely on `ActionService`. Repository: [Obelisk-Framework/oblsk_items](https://github.com/Obelisk-Framework/oblsk_items).

See [Item module design](https://github.com/Obelisk-Framework/core/blob/main/docs/superpowers/specs/2026-08-10-item-module-design.md) for the full rationale behind every decision on this page.

## Schema

`base_items` is the catalog, one row per item type:

| Column | Type | Notes |
|---|---|---|
| `name` | string | |
| `description` | text | nullable |
| `icon` | string | nullable |
| `weight` | float | default `0` |
| `is_takeable` / `is_giveable` / `is_dropable` | boolean | default `1` |
| `is_container` / `is_useable` / `is_stackable` | boolean | default `0` |
| `step` | float | nullable, see [Depletion](#depletion) |
| `step_key` | string | nullable, see [Depletion](#depletion) |
| `max_stack_amount` | integer | nullable, only meaningful when `is_stackable` |
| `data` | json | template data, copied into each `Item.data` at creation |
| `actions` | json | the use pipeline, see [Use pipeline](#use-pipeline) |

`items` is a single owned instance (or stack) of a `base_item`:

| Column | Type | Notes |
|---|---|---|
| `base_item_id` | integer FK | `onDelete('RESTRICT')`, a type in active use can't be deleted |
| `owner_type` | string | open, not a fixed enum: `'character'`, `'item'` (a container item holding this one), `'vehicle_trunk'`, `'vehicle_glovebox'`, more later |
| `owner_id` | integer | no FK, since the target table depends on `owner_type` |
| `data` | json | mutable per-instance state, copied from `base_items.data` at creation |
| `amount` | integer | default `1`, the stack size |

## Models

`BaseItem` (`server/models/BaseItem.lua`) and `Item` (`server/models/Item.lua`), both `BaseModel:extend(...)`. `Item.casts = { data = 'json' }`, `BaseItem.casts = { data = 'json', actions = 'json' }`.

- **`Item:getWeight()`**: flat `baseItem.weight` unless `step_key` is set, in which case it scales by `data[step_key] / baseItem.data[step_key]` (see [Depletion](#depletion)). Assumes `self.baseItem` is already assigned directly; `:loadSync('baseItemRelation')` populates `self.relations.baseItemRelation`, not `self.baseItem`, so it does not satisfy this on its own.
- **`Item.isStackableWith(a, b)`**: `true` only when both instances share `base_item_id`, `owner_type`, `owner_id`, and byte-identical `data` (compared via `json.encode`). A partially-depleted item never merges with a full one. Doesn't check `is_stackable`/`max_stack_amount` itself, both need the `BaseItem`, not just the two `Item` instances.

## Stacking

Two `items` rows only merge (`amount` incremented) when `Item.isStackableWith` returns `true`. `base_items.max_stack_amount` caps a single row's `amount`; pushing past it (once an add-to-inventory operation exists, see [Known gaps](#known-gaps)) is meant to spill the overflow into a new row rather than fail outright.

## Depletion

`base_items.step` is a plain number: how much of `data[step_key]` one use consumes. `step_key` names which key in `data` that is (`fill_ml`, `charge`, `rounds`, anything the item type defines). Both capacity (`base_items.data[step_key]`) and current amount (`items.data[step_key]`) live inside `data` as an ordinary key, there's no fixed schema column for it beyond `step_key` itself, since not every item has this concept and the unit varies per item type.

## Use pipeline

`base_items.actions` is a JSON array of `{ action_id: <integer>, data: {...} }`, where `action_id` references `actions.id` (the same table `ActionService.register` upserts into for every action in the framework, not a second registry). `ItemService.use(source, item)` loads the `BaseItem`, checks `is_useable`, and runs each entry through the existing `ActionService.execute`, resolving the integer back to the registered string via `ActionService.resolveDbId` first. Each entry's `data` is merged with `item`/`baseItem` before the call, so an action handler always has both in hand.

Because this is just `ActionService.execute` in a loop, every existing action mechanism applies for free: the `action:before:<id>`/`action:after:<id>` hooks, and any `PolicyService` policy attached to that action id. The same `action_id` can appear more than once with different `data` (e.g. two `item:notify` entries with different text), since `ActionService.execute` already supports being called twice.

Two built-in actions, registered at module load (`server/actions/ItemActions.lua`):

- **`item:consume_step`**: calls `ItemService.consumeStep(item, baseItem)`, which subtracts `baseItem.step` from `item.data[baseItem.step_key]` (clamped to `>= 0`) and saves. Doesn't remove or destroy the item once depleted to `0`, that's left for a future action (e.g. `item:destroy_if_empty`).
- **`item:notify`**: calls `NotificationService.notify(source, { type = data.kind, title = data.title, description = data.text })`.

```json
[
  { "action_id": 12, "data": {} },
  { "action_id": 13, "data": { "text": "You drink some water.", "kind": "info" } }
]
```

## Known gaps

- No CLI generator for scaffolding new `base_items` content yet (`make:item`).
- No give/drop/pickup interaction wiring, no NUI inventory UI, no container capacity limits (slots/weight caps for `is_container` items). This module ships the data model and the use pipeline; the interaction/UI layer that actually calls `ItemService` is follow-up work.
- No needs/hunger/thirst system. The water-bottle example that motivates `step`/`step_key` assumes one exists eventually; adding a `restore_need` action later is just one more `ActionService.register` call once that system exists.
