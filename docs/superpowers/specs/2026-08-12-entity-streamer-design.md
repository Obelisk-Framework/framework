# Entity Streamer: budgeted chunk streaming with facing-direction precache

**Goal:** Extend the existing (currently unused/dead) chunk-based `EntityStreamerService` with a global entity-count budget, three-tier degradation (full surrounding-chunk radius → current+facing chunk → current chunk only), anti-thrash hysteresis, and a facing-direction look-ahead cache so entities in the chunk a player is about to enter spawn instantly instead of waiting on a model-load stall.

**Source:** `core/core/server/Services/EntityStreamerService.lua` and its client counterpart already implement 100-unit chunking, a fixed 3×3 (radius-1) surrounding-chunk set, and diff-based per-player load/unload — but nothing in the framework ever calls `EntityStreamerService.register(...)`, so no entity has ever actually flowed through it. This design extends that dead prototype rather than replacing it.

## Architecture

- Persistence: a new `entities` table (see Data Model below), with a matching `Entity` model at `core/core/server/Models/Entity.lua` (`Entity = BaseModel:extend('entities')`), following this repo's exact `Organization`/`Interaction` model convention (`primaryKey = 'id'`, `timestamps = true`, `fillable = {...}`). `EntityStreamerService.init()` loads enabled rows via the model rather than raw `QueryBuilder`, matching how other services in this framework already consume their models.
- Tiers, evaluated top-down against a global entity-count budget (peds/objects/pickups only — markers and blips never consume an entity slot, so they're always free and excluded from the budget check):
  1. **Tier 1 (full)**: player's chunk + 8 neighbors (9 chunks total), the existing `getSurroundingChunks(chunk, 1)` math, unchanged.
  2. **Tier 2 (degraded)**: player's chunk + facing chunk (2 chunks).
  3. **Tier 3 (minimal)**: player's chunk only (1 chunk).
  For each player, sum the candidate tier's entity count against `EntityStreamerService.globalSpawnedCount` (server-wide, incremented/decremented as any player's active-chunk union changes — a chunk shared by two nearby players counts once, not twice) and take the highest tier that fits under `EntityStreamerService.entityBudget` (a module-level constant, default `300`, server-owner-editable; not a convar for v1 — add one later only if a server owner actually asks).
- **Hysteresis**, two independent margins guarding two different flicker sources:
  - Chunk-boundary: a chunk only unloads once the player is 15 units past the boundary (checked against raw `x, y`, not just chunk-key membership), not the instant they cross it.
  - Tier: a tier downgrade/upgrade only takes effect after 2 consecutive position-update ticks (the existing 500ms interval, so 1 second) stay over/under the threshold — a single-tick spike doesn't flip it.
- **Facing chunk**: derived from `GetGameplayCamRelativeHeading() + GetEntityHeading(ped)` client-side, recomputed only when it's changed more than 20° from the value last used to pick a facing chunk — prevents the facing chunk flapping every tick from ordinary camera movement.
- **Look-ahead precache**: the chunk one further past the facing chunk in the same direction (`p → c1 (facing) → c2 (lookahead)`). The server pre-sends `c1`+`c2`'s entity data to the client ahead of the player's own chunk becoming `c1` (skips the round-trip), and the client calls `RequestModel` for those entities' models without spawning them yet (skips the up-to-5-second model-streaming wait already present in `spawnPed`/`spawnObject`). Actual spawning still only happens once the player's real active-chunk set includes that chunk — this is a priming step, not an early spawn.
- **Per-entity `networked` flag** (new `entities.networked` column, default `false`): local-only entities (ambient dressing — decorative peds, props) are spawned independently and privately by every client that has the owning chunk active, no coordination needed. Networked entities (anything another player must see/interact with identically, e.g. a billiards-table prop) are spawned exactly once, by whichever client's active-chunk set first includes them (`EntityStreamerService.networkedOwners[entityId]`, set on first load, cleared on that owner's `playerDropped`) — FiveM's OneSync then handles visibility culling and entity-ownership migration to every other nearby client automatically, the same as any other networked game entity; no hand-rolled ownership-handoff protocol is built.

## Data Model

`entities` table:

```lua
return {
    up = function()
        Schema.create('entities', function(table)
            table:id()
            table:enum('entity_type', {'ped', 'object', 'pickup', 'marker', 'blip'})
            table:string('model', 100):nullable()
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('heading'):nullable()
            table:boolean('networked')
            table:boolean('enabled')
            table:string('owner_type', 30):nullable()
            table:integer('owner_id'):nullable()
            table:json('data'):nullable()
            table:timestamps()

            table:index({'x', 'y'})
        end)
    end,
    down = function()
        Schema.drop('entities')
    end
}
```

(Written against the ORM's post-flip semantics: every column above except `model`/`heading`/`owner_type`/`owner_id`/`data` is required by default, matching the earlier `2026-08-12-orm-nullable-default-and-column-alter-design.md` change already shipped.)

`entity_type`/`model`/`x,y,z`/`heading` and type-specific fields (`scenario`/`freeze`/`invincible` for peds; `pickupType`/`amount` for pickups; `sprite`/`color`/`scale`/`label`/`shortRange` for blips; `markerType`/`scaleX,Y,Z`/`r,g,b,a`/`bobUpAndDown`/`rotate` for markers) split the same way the existing `interactions` table splits common vs. type-specific data — common columns as real columns, the rest in `data` (json), rather than one column per entity-type field. `owner_type`/`owner_id` are a nullable polymorphic owner (e.g. a garage's ambient mechanic ped could reference `'plugin:oblsk_garage'`/that garage's id), mirroring `interactions.action_id`'s FK-to-owner precedent, generalized since a streamer entity's owner isn't always a core action. `enabled` is a server-owner kill switch (matches `phone_apps.server_enabled`'s precedent) rather than requiring a hard delete. Index on `(x, y)` rather than a stored `chunk_key` column, since chunk size (`EntityStreamerService.chunkSize`) is a runtime constant that could be tuned later — deriving chunk membership at query time keeps the schema decoupled from that config value.

## Components & File Structure

```
core/core/
  server/
    database/migrations/
      2026_08_12_XXXXXX_create_entities_table.lua   -- new
    Models/
      Entity.lua                                      -- new, BaseModel:extend('entities')
    Services/
      EntityStreamerService.lua                        -- extended:
                                                          + budget/tier logic, hysteresis,
                                                          facing-chunk tracking, precache push,
                                                          networked-entity spawn-once gating
  client/
    Services/
      EntityStreamerService.lua                        -- extended:
                                                          + facing-chunk computation (camera
                                                          heading, debounced), model-precache
                                                          (RequestModel without spawning),
                                                          tier-aware despawn on downgrade
```

No new files beyond the migration and model — everything else is additive to the two existing `EntityStreamerService.lua` files. Event names (`core:server:streamer-entityAdd/-entityRemove`, `core:client:streamer-updatePosition`) and the client's spawn/despawn plumbing for peds/objects/pickups/blips/markers are unchanged.

## Data Flow

- **Position tick** (existing 500ms client thread): sends `(x, y, heading, camRelativeHeading)` — heading fields added to the existing payload, only updated when the facing-relevant heading has moved >20° since last sent.
- **Server, on each update** (`updatePlayerChunks`, extended):
  1. Compute `currentChunk` (unchanged), `facingChunk` (one chunk offset from `currentChunk` in the heading's direction), `lookaheadChunk` (one further chunk past `facingChunk`, same direction).
  2. Determine tier: try Tier 1's 9-chunk set against `globalSpawnedCount` + budget headroom; else Tier 2's 2 chunks; else Tier 3's 1 chunk. A tier change requires 2 consecutive ticks past threshold before taking effect.
  3. Diff the active-chunk set against the player's previous one (existing load/unload diffing), with unload gated by the 15-unit boundary-hysteresis margin.
  4. Push `lookaheadChunk`'s entity data + a model-precache instruction as a separate signal from the load/unload diff — doesn't touch `activeChunks`, purely primes the client.

## Error Handling

- `RequestModel` timeouts (existing 5-second cap) are unchanged — a failed model load skips only that entity, never blocks the rest of the chunk.
- A malformed `entities` row (an `entity_type` outside the enum, or similarly invalid) is skipped at `init()` load time with a `print` warning, not a hard crash — matches this framework's existing "don't let one bad row take down boot" convention.

## Testing

- Server-side unit tests (`core/tests/entity_streamer_service_spec.lua`, plain `lua5.4`, fake QueryBuilder): tier selection at each budget threshold boundary; hysteresis (single-tick spike doesn't flip a tier, two consecutive do); boundary hysteresis (a position just past a chunk edge doesn't unload until the 15-unit margin is crossed); facing/lookahead chunk math for representative headings; networked-entity single-owner assignment (first loader becomes owner, cleared on disconnect, a second loader doesn't get a duplicate spawn instruction). `getChunkKey`/`getSurroundingChunks`'s existing coverage carries forward unchanged.
- No client-side test file — natives (`CreatePed`, `RequestModel`, camera heading, etc.) aren't unit-testable outside FiveM, matching every other plugin's client code in this repo. Correctness there is structural (matches the server's event contract) plus manual verification.
- Manual verification (an implementation-plan step, not a test file): place test entities via `Entity:create(...)` spanning >9 chunks; confirm tier degradation by temporarily lowering `entityBudget`; confirm boundary hysteresis by walking back and forth across a chunk edge and watching for spawn/despawn flicker; confirm the lookahead chunk's models are pre-requested (log-visible) before the player actually enters it.

## Out of Scope

- A server-owner-facing convar for `entityBudget` (YAGNI for v1 — a module-level constant is enough until a real server owner asks for runtime tuning).
- Priority-fill budget allocation across chunks (ranking individual entities by distance rather than whole-chunk tiers) — considered and explicitly deferred as a future optimization during brainstorming; the tiered approach matches what was actually asked for.
- Hand-rolled networked-entity ownership handoff protocol — relies entirely on FiveM/OneSync's existing built-in entity visibility culling and ownership migration.
