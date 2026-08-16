# Entity Streamer — Per-Player Budget Design

**Date:** 2026-08-17  
**Extends:** `2026-08-12-entity-streamer-design.md`

## Overview

Extends the entity streamer with per-player per-type load tracking and a
per-player gate in `selectTier`, so that a player's active chunk set is
bounded not only by the global spawned-entity budget but also by the
per-client handle limits (`perPlayerCaps`).

## New state

- `EntityStreamerService.playerLoad` — `{[source]={ped=N, object=N, pickup=N}}`
  Running sum of budget-countable entities across all chunks currently active
  for that player. Maintained by `updatePlayerChunks`; cleared by
  `handlePlayerDropped`.

- `EntityStreamerService.perPlayerCaps` — `{ped=256, object=2048, pickup=70}`
  Hard per-client limits derived from GTA V's entity handle budget.

## Changed functions

### `updatePlayerChunks`

On every chunk load, `playerLoad[source][type]` is incremented by
`countEntitiesInChunkByType`. On every chunk unload it is decremented
(floored at 0). `init()` resets the whole table; `handlePlayerDropped` nils
the player's entry.

### `selectTier`

A tier is rejected if, for ANY budget-countable type, either:
- `globalSpawnedCounts[type] + globalProjection[type] > globalBudgets[type]`, or
- `playerLoad[source][type] + playerProjection[type] > perPlayerCaps[type]`

where `globalProjection` skips chunks already referenced by any player
(`chunkPlayerRefs[chunk] > 0`) and `playerProjection` skips chunks already
in this player's own `activeChunks` set. The two projections differ: a chunk
held by another player is still a new cost for the current player.

Tier 3 (current chunk only) is never rejected by either gate.
