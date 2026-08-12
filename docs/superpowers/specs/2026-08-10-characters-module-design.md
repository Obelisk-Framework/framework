# Characters Module Design

**Repository:** `modules/oblsk_characters` (own git repo, folded into `core` via the `modules/*/...` globs in `core/fxmanifest.lua`, same pattern as `oblsk_accounts`, `oblsk_items`, `oblsk_vehicles`).

**Goal:** Give every `Account` (from `oblsk_accounts`) a small set of character slots, each holding a `Character` (identity, plus vitals/position: health, armor, air, x/y/z, dimension, food/drink/stamina) and its `CharacterAppearance` (looks). No cash/bank balance and no UI wiring; both are explicitly out of scope here.

## Why this exists

`Item.owner_type`/`Vehicle.owner_type` already anticipate a `'character'` owner type with an integer `owner_id`. This module is what makes that a real row rather than a placeholder. `oblsk_character-selection` already ships a UI stub (a character-select screen and a creation form collecting gender, first/last name, bio, date of birth) with nothing behind it; this module is the backend those screens will eventually call into, though wiring them up is explicitly a follow-up (see [Known gaps](#known-gaps)).

## Scope boundary

This module persists vitals and position (`health`, `armor`, `air`, `x`/`y`/`z`, `dimension`, all required with GTA-native defaults; `food`/`drink`/`stamina`, nullable, since no hunger/thirst system exists yet to define what they mean) via `CharacterService.getVitals`/`saveVitals`. It still does **not** persist cash/bank balance, that's a future module's job (an Economy-shaped module, not yet designed). Nothing in this module syncs vitals to or from a live ped yet, `getVitals`/`saveVitals` are a data layer only; that's a future pass once there's an actual spawn/damage-event loop to hook into.

## Schema

### `characters`

| Column | Type | Notes |
|---|---|---|
| `account_id` | integer FK | `references('id').on('accounts').onDelete('CASCADE')` |
| `slot` | integer | which of the account's limited character slots this occupies (`0`..`accounts.max_characters - 1`) |
| `first_name` | string(100) | not nullable |
| `last_name` | string(100) | not nullable |
| `gender` | string(20) | open, not a fixed enum |
| `dob` | date | |
| `bio` | text | nullable |
| `last_played_at` | datetime | nullable |
| `deleted_at` | datetime | nullable, soft delete |
| `health` / `armor` / `air` | float | not nullable, GTA-native defaults `200`/`0`/`100` |
| `x` / `y` / `z` | float | not nullable, default `0`/`0`/`72` |
| `dimension` | integer | not nullable, default `0` |
| `food` / `drink` / `stamina` | float | nullable, no default, no hunger/thirst system exists yet to define what they mean |
| (timestamps) | | |

Added by a later migration (`2026_08_10_220102_add_vitals_to_characters_table`), not the original one, since vitals/position were out of scope for the module's first pass. See [Scope boundary](#scope-boundary).

### `accounts` (altered)

| Column | Type | Notes |
|---|---|---|
| `max_characters` | integer | not nullable, default `3` |

Added by this module's own migration (`2026_08_10_220535_add_max_characters_to_accounts_table`), even though the column lives on `accounts` (from `oblsk_accounts`), not `characters`. The slot limit is a characters-module concept, and `oblsk_characters` already depends on `oblsk_accounts` (`characters.account_id` is a foreign key to `accounts.id`), so altering `accounts` here doesn't add a new dependency, it uses the one that already exists. Migration ordering already requires `oblsk_accounts` to run first (alphabetically, see the implementation plan's Global Constraints), so `accounts` is guaranteed to exist by the time this migration runs.

**Slot uniqueness is an application-level invariant, not a DB constraint.** `CharacterService.create` is the only place a `characters` row is ever inserted, and it always picks the lowest slot not already occupied by a non-deleted character for that account. A DB-level `unique(account_id, slot)` constraint would need to exclude soft-deleted rows (a partial/filtered unique index) to allow a freed slot to be reused, and that syntax isn't portable across this codebase's MySQL/Postgres dialect split the way `Schema.create` currently works. Same convention already used for the polymorphic ownership columns in the Item/Vehicle modules and for `bans`' account-vs-identifier invariant: enforced once, in the one function that writes the row, not at the schema layer.

**Soft delete, not hard delete.** `Item`/`Vehicle` rows may already reference a character via `owner_id` (no FK, since `owner_type` varies), and this module has no way to know what else outside its own tables points at a `characters.id`. Hard-deleting would either orphan those references or require this module to know about every other module's ownership columns. `deleted_at` frees the slot for reuse without destroying the row or anything that points at it.

### `character_appearances`

| Column | Type | Notes |
|---|---|---|
| `character_id` | integer FK, unique | `references('id').on('characters').onDelete('CASCADE')`, one appearance per character |
| `ped_model` | string(100) | e.g. `'mp_m_freemode_01'`; its own column since it determines which base model to spawn, a structural fact the rest of the appearance data depends on |
| `data` | json | head blend, face features, overlays, component variations, props, hair/eye color, the long tail; same convention as `Vehicle.body_damage` |
| (timestamps) | | |

`CharacterService.create` always creates a blank `character_appearances` row (`ped_model` defaulted, `data = {}`) alongside the `Character` it creates, so every character has an appearance row from the moment it exists, nothing downstream needs to handle "character with no appearance yet."

## Models

`Character` and `CharacterAppearance` (`server/models/*.lua`), both `BaseModel:extend(...)`. `CharacterAppearance.casts = { data = 'json' }`.

- `Character:accountRelation()`: `belongsTo(Account, 'account_id', 'id')`.
- `Character:appearanceRelation()`: `hasOne(CharacterAppearance, 'character_id', 'id')`.
- `CharacterAppearance:characterRelation()`: `belongsTo(Character, 'character_id', 'id')`.

## `CharacterService`

- **`CharacterService.list(accountId)`**: non-deleted characters for an account (`deleted_at IS NULL`), ordered by `slot`.
- **`CharacterService.create(accountId, attributes)`**: finds the lowest slot in `0..accounts.max_characters - 1` not occupied by a non-deleted character for this account (`max_characters` lives on `accounts`, added by this module's own migration, not a local constant, so one account's limit can be raised or lowered without a code change; default `3`, applied at the DB level). Returns an error if every slot is full, or if the account doesn't exist. Creates the `Character` row with that slot, then a blank `CharacterAppearance` linked to it. `attributes` is `{ first_name, last_name, gender, dob, bio }`.
- **`CharacterService.delete(characterId)`**: sets `deleted_at = Database.now()`, freeing the slot.
- **`CharacterService.setActiveCharacterId(source, characterId)`** / **`CharacterService.getActiveCharacterId(source)`**: a session map (`source -> characterId`), same shape as `AccountService.sessionAccounts`. Nothing in this module ever calls `setActiveCharacterId` itself, that's the future UI-wiring pass's job once a player actually picks a character on a select screen.
- **`CharacterService.getVitals(characterId)`** / **`CharacterService.saveVitals(characterId, vitals)`**: reads/writes `health`, `armor`, `air`, `x`/`y`/`z`, `dimension`, `food`/`drink`/`stamina` as one flat table. `saveVitals` is a partial update, only the keys present in `vitals` are written. Nothing calls either yet, no spawn/damage-event loop exists to drive them.

## Testing

Unit tests mirror the `oblsk_accounts`/Items/Vehicles pattern (fake in-memory `QueryBuilder`, no live database):

- `list`: returns only non-deleted characters, ordered by slot.
- `create`: assigns slot `0` to the first character on an account; assigns the next free slot when some exist; reuses a freed slot after a soft-delete; returns an error once `accounts.max_characters` non-deleted characters already exist, or when the account doesn't exist; a raised `max_characters` on one account doesn't affect another's limit; always creates a paired blank `CharacterAppearance` row.
- `delete`: sets `deleted_at`, and a subsequent `create` on the same account reuses that freed slot.
- session map: `getActiveCharacterId` returns `nil` before `setActiveCharacterId` is called, and the set value afterward.

## Known gaps (deferred)

- No UI wiring. `oblsk_character-selection`'s Vue components (`CharacterSelection.vue`, `CharacterCreationForm.vue`, `CharacterSelector.vue`) exist but call nothing; wiring them to `CharacterService` via WebView/NUI events is a separate future pass.
- No `playerConnecting`/`playerDropped` hooks of any kind, unlike `oblsk_accounts`. This module has no event handlers at all; the future UI-wiring pass owns when `setActiveCharacterId` gets called and when the session map gets cleared.
- No cash/bank balance. See [Scope boundary](#scope-boundary).
- No sync between `CharacterService.getVitals`/`saveVitals` and a live ped entity (spawning, damage events, drowning, etc.); the data layer exists, nothing calls it yet.
- No CLI generator for scaffolding appearance presets.
- No admin commands (e.g. force-deleting another account's character); `CharacterService.delete` exists as a function only.
- **`CharacterService.create`'s slot assignment is not atomic.** It reads the current slot set (`list`) and inserts the new row as two separate round trips; two overlapping calls for the same account can both observe the same free slot and either collide or together exceed `accounts.max_characters`. Latent today, nothing calls `create` yet, but a spammed/double-clicked "create character" click in the future UI-wiring pass is exactly the realistic trigger. That pass must close this (a per-account in-flight guard, or re-read-after-insert with rollback on collision) before wiring a real UI to it, not leave it implicit.
- **Every function in this module currently trusts its caller.** `create` does no input validation (a caller omitting `first_name`/`last_name` hits a raw SQL error rather than the `(nil, err)` contract the slot-full case already uses), and `delete` does no existence or ownership check (deleting a nonexistent id silently no-ops, and nothing stops one account's session from deleting another account's character by id). Fine for a pure data layer with no caller yet; the UI-wiring pass is what makes the caller untrusted, and must add both checks before forwarding any NUI-supplied id or attribute table into these functions.
- Before treating this module as live: run `obelisk registry:generate` from `core/` and confirm `oblsk_characters` appears in `modules/registry.json` (after `oblsk_accounts`), otherwise `bootstrap.lua` never runs its migrations.
