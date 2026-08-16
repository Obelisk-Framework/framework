# ORM sync/async rename + Eloquent ergonomics

## Problem

The core ORM's naming is backwards from how it's actually used. FXServer
connector "Sync" exports (`oxmysql`-style, and this project's own
`oblsk_connector`, which polls via `Citizen.Wait` rather than blocking) yield
only the current coroutine — they don't block the server. Because of that,
the `Sync`-suffixed methods (`findSync`, `getSync`, `createSync`, ...) are
used almost everywhere in the codebase. The un-suffixed "async" callback
variants (`find`, `get`, `create`, ...) are the rare case — genuine
fire-and-forget writes where the caller doesn't need the result.

Two related ergonomics gaps compound the confusion:

- Model instances only expose attributes via `instance.attributes.field` —
  there's no direct `.field` access.
- `BaseModel:allSync()` is the only method that both queries and decodes
  JSON casts into real model instances. `Model:where(...):getSync()`
  (filtered) returns raw undecoded rows. This inconsistency caused two real
  bugs in the `base-item-category-fields` work (`ItemService.listCategories()`
  never decoding `fields`, `updateCategory()` never encoding it).
- The relation system (`hasOne`/`hasMany`/`belongsTo`/`belongsToMany` +
  `load`/`loadSync`) exists but is barely used — grepped to exactly one
  model file across the whole codebase. The "for each row, manually query the
  related row" pattern seen repeatedly elsewhere is N+1 done by hand, because
  there's no eager-loading entry point.

## Goals

1. Flip the naming convention so the common case reads naturally: bare name
   = sync (blocks the coroutine, returns a value). `...Async` suffix =
   true callback-based (fire-and-forget or explicit async use).
2. Give model instances direct `.field` attribute access.
3. Make `get()` model-aware so filtered and unfiltered queries decode/wrap
   consistently, and retire the `all()`/`allSync()` special case.
4. Make eager loading usable via `:with('relation.path')`, including nested
   dot-paths, so the N+1-by-hand pattern has a real alternative.

## Non-goals

- No temporary dual-naming/alias period. This is a full rename, not an
  additive change (unlike the earlier QueryBuilder→Model audit).
- No change to external connector export names (`exports.oxmysql:executeSync`,
  `exports.oblsk_connector:executeSync`, `exports.ghmattimysql:executeSync`)
  — those are third-party APIs we don't own and don't control the naming of.
- No change to `Schema.lua`'s migration-time DDL API in this pass beyond
  following its existing calls into the renamed `Database.*` methods.

## Naming convention

Bare name = sync (returns a value, no callback param). `Async` suffix =
callback-based.

### `Database` (core/server/ORM/Database.lua)

| Old bare (callback) | Old `Sync` suffix | New bare (sync, returns value) | New `Async` suffix (callback) |
|---|---|---|---|
| `query` | `querySync` | `query` | `queryAsync` |
| `insert` | `insertSync` | `insert` | `insertAsync` |
| `update` | `updateSync` | `update` | `updateAsync` |
| `delete` | `deleteSync` | `delete` | `deleteAsync` |
| `execute` | `executeSync` | `execute` | `executeAsync` |

Each pair keeps its current internal logic — only names swap. `execute`/
`query` remain aliases of each other, as today.

### `QueryBuilder` (core/server/ORM/QueryBuilder.lua)

| Old bare (callback, or callback-branch) | Old `Sync` suffix | New bare (sync) | New `Async` suffix (callback) |
|---|---|---|---|
| `get` | `getSync` | `get` | `getAsync` |
| `first` | `firstSync` | `first` | `firstAsync` |
| `count` | `countSync` | `count` | `countAsync` |
| `insert(data, callback?)` (branches on callback) | — | `insert(data)` (always sync, returns insertId) | `insertAsync(data, callback)` |
| `update(data, callback?)` (branches on callback) | — | `update(data)` (always sync, returns affectedRows) | `updateAsync(data, callback)` |
| `delete(callback?)` (branches on callback) | — | `delete()` (always sync, returns affectedRows) | `deleteAsync(callback)` |

`insert`/`update`/`delete` currently pick sync-vs-async by whether a callback
argument was passed. That's not preserved: the rename gives each verb an
unconditional-sync bare form and an explicit `...Async` callback form,
matching every other pair. Any call site relying on the callback-presence
branch must be updated to call the right one explicitly.

### `BaseModel` (core/server/ORM/BaseModel.lua)

| Old bare (callback) | Old `Sync` suffix | New bare (sync) | New `Async` suffix (callback) |
|---|---|---|---|
| `find` | `findSync` | `find` | `findAsync` |
| `create` | `createSync` | `create` | `createAsync` |
| `save` | `saveSync` | `save` | `saveAsync` |
| `delete` | `deleteSync` | `delete` | `deleteAsync` |
| `load` | `loadSync` | `load` | `loadAsync` |
| `all` / `allSync` | — | **removed** — use `get()` | **removed** — use `getAsync()` |

`BaseModel:get(key)` (today's attribute getter) is also removed — see
"Attribute access" below.

`QUERY_PROXY_METHODS` (the chainable starters BaseModel forwards to a fresh
`QueryBuilder`) are unaffected by this table since they're pass-through
(`where`, `orderBy`, etc. don't have Sync variants); only the terminal
methods (`get`/`first`/`count`) change.

## Attribute access

Model instances gain direct `.field` access. Implementation: give each
model class's instance metatable a *function* `__index` instead of today's
table-based `child.__index = child`:

```lua
child.__index = function(instance, key)
    if instance.attributes[key] ~= nil then
        return instance.attributes[key]
    end
    if instance.relations[key] ~= nil then
        return instance.relations[key]
    end
    return child[key] -- falls through to method table, preserving extend() inheritance
end
```

`instance.attributes.field` keeps working unchanged — `attributes` is a real
raw key on the instance table, so it never goes through `__index`.

`BaseModel:get(key)` (the old attribute getter) is removed as redundant with
`.field` access, freeing the name `get` for the query-fetch method below.
`BaseModel:set(key, value)` is unaffected — direct assignment
(`instance.field = value`) is not part of this design; `set()` and
`instance.attributes.field = value` remain the two ways to write an
attribute. (Read gets the ergonomic win; write keeps its explicit form,
since a blanket `__newindex` risks silently creating stray keys instead of
attributes on typos.)

## `get()` becomes model-aware

Today, `QUERY_PROXY_METHODS` opens a fresh `QueryBuilder` per call
(`self:newQuery()`) with no link back to the model. `newQuery()` will attach
a `.model` back-reference onto the `QueryBuilder` it creates:

```lua
function BaseModel:newQuery()
    local query = QueryBuilder.new(self.table, self.primaryKey)
    query.model = self
    return query
end
```

`QueryBuilder:get()` (renamed from `getSync`) checks `self.model`:

- Present (opened via `Model:where(...)`, `Model:get()`, etc.) → decode JSON
  casts and wrap every row into a model instance via `newFromQuery`, same as
  today's `allSync`.
- Absent (bare `QueryBuilder.new('table')` with no owning model) → return
  raw rows, same as today.

`getAsync()` gets the same model-aware branch in its callback.

`BaseModel:all()`/`allSync()` are deleted; `Model:get()` with no `where()`
call is the direct replacement (same as `Model:where(...):get()` is for the
filtered case — both go through the same model-aware `get()` now).

## Eager loading: `:with('a.b.c')`

New `BaseModel:with(path)` (sync) / `:withAsync(path, callback)`, called on
a model class before/alongside `get()`/`find()`, e.g.:

```lua
local orders = Order:with('customer.address'):get()
```

Design:

- `with()` records the requested paths on the query chain (parallel to how
  `QUERY_PROXY_METHODS` return `self` for chaining); it does not fetch
  anything itself.
- After the base `get()`/`find()` fetch returns instances, eager-loading
  post-processes them: for each requested path, split on `.` into segments.
- Segment 1 loads across *all* base instances in one batched query
  (`WHERE foreignKey IN (...)`, reusing the batching approach already
  described for single-level `with()`), and attaches each loaded related
  instance into `.relations[segment1]` on its owning base instance (same
  storage `load`/`loadAsync` already use, reachable via the new `.field`
  fallback in "Attribute access" above — e.g. `order.customer.name`).
- Segment 2 then batches across the *flattened set of segment-1 results*
  (all loaded `customer` instances across all orders, deduplicated by
  primary key so a shared customer isn't fetched twice), attaching into each
  customer's `.relations[segment2]`.
- This repeats per segment: each level is one batched query across the
  previous level's distinct related instances, not one query per path per
  base instance. A 3-segment path over 50 base rows is 3 queries total (plus
  the base fetch), not 150.
- Multiple `with()` calls (or a single call with multiple paths) run
  independently; shared prefixes are not deduplicated across different paths
  in this pass (e.g. `with('customer'):with('customer.address')` will fetch
  `customer` twice) — acceptable since callers control this by writing one
  path per relation chain they need.
- Only `hasOne`/`hasMany`/`belongsTo`/`belongsToMany` relation types are
  supported at each segment, matching what `load`/`loadAsync` already
  support.

## Rollout

Big-bang cutover, sequenced to avoid a half-migrated state breaking the
shared Lua VM (per the plugin loading architecture — every module/plugin
shares one Lua state via `core/fxmanifest.lua` globs, so there's no
per-plugin version pinning):

1. **Survey**: enumerate every call site of every renamed method, across
   core and all ~42 module/plugin repos. Verify against each repo's actual
   GitHub remote content (not local outer-checkout clones, which may carry
   unpushed WIP from other sessions) — same verification step used in the
   prior QueryBuilder-to-Model audit.
2. **Prepare in lockstep, merge core first**: (a) core ORM rename lands on a
   branch (not merged to core's `main` yet); (b) every dependent repo's PR
   is written against that branch's new names and reviewed/approved, but
   held unmerged; (c) once every dependent PR is ready, merge core's rename
   branch to `main` first, then merge all dependent PRs in immediate
   succession. The shared-VM window between core's merge and a given
   plugin's merge is the only breakage risk — minimize it by merging
   dependents as fast as possible right after core, batched rather than
   manual one-by-one.
3. **Verify**: after all merges, re-run the survey grep across all repos to
   confirm zero remaining old-name call sites (`Sync` suffix on any
   `Database`/`QueryBuilder`/`BaseModel` method, and zero bare calls to the
   old callback-branching `insert`/`update`/`delete` that relied on
   callback-presence).

Given the scale (85+ call sites in core alone per an initial grep, plus
module/plugin repos — comparable to or larger than the QueryBuilder-to-Model
audit, which needed a 53-agent workflow across 42 repos), implementation
should use a similar large multi-agent workflow sweep: survey/discover phase
across all repos, then a fix phase for verified candidates only, with
explicit user workflow opt-in per established pattern.

## Testing

- Core ORM unit/integration tests (wherever `BaseModel`/`QueryBuilder`/
  `Database` are currently tested) updated to call the new names and cover:
  - `.field` read access alongside `.attributes.field`.
  - `get()`/`getAsync()` decode+wrap consistently for both `Model:get()`
    (unfiltered) and `Model:where(...):get()` (filtered), replacing the
    `allSync` vs `getSync` inconsistency that caused the category-fields
    JSON-cast bugs.
  - `with('a.b')` nested eager load produces the right number of queries
    (batched, not N+1) and populates `.relations` at each segment.
  - `insert`/`update`/`delete` on `QueryBuilder` now split cleanly into
    sync-return and `...Async`-callback forms — no call site left relying on
    callback-presence branching.
- No behavioral regression test suite exists per-plugin in this repo
  structure (each plugin/module is its own repo) — dependent-repo migrations
  rely on each repo's own existing test suite (where present) plus the
  survey/verify step in Rollout.
