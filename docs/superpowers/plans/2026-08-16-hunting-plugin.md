# oblsk_hunting + oblsk_crafting queueing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working `oblsk_hunting` plugin (zones → spawn → kill → skin → carry → butcher → sell) plus the `oblsk_crafting` queueing/pickup-policy enhancement its butcher step depends on.

**Architecture:** Part 1 extends the existing `oblsk_crafting` plugin in place (additive migrations + `CraftingService` changes) so `crafting_points` can run in `shared`/`per_character` queue modes with a `starter_only`/`anyone`/`org` collect policy. Part 2 adds a new `oblsk_hunting` plugin (own nested git repo under `plugins/oblsk_hunting`) that spawns roaming animal peds via the existing `EntityStreamerService`, tracks kill health in memory, represents carcasses purely as `oblsk_propattach` attachments (never `ItemService` items), and reuses the butcher-enhanced `oblsk_crafting` as its processing step.

**Tech Stack:** Lua 5.4 (FiveM server), the project's ORM (`QueryBuilder`/`Schema`/migrations), Vue 3 (admin/NUI web tabs), the project's `lua5.4 <spec>.lua` test runner convention (`tests/support/fake_query_builder.lua`, `tests/support/fivem_stubs.lua`).

**Spec:** `core/docs/superpowers/specs/2026-08-16-hunting-plugin-design.md`

## Global Constraints

- Server is authoritative for everything: health, kill detection, capacity, ownership. Client only reports raw events (hit reports, button presses) — never a claimed result.
- Every DB read in a service goes through `QueryBuilder`, never raw SQL, except `CraftingService.advance()`'s existing single bulk `Database.updateSync` decrement (unchanged pattern, do not add more raw SQL).
- No `ItemService`-backed inventory item ever represents a carcass — carcasses exist only as rows in `oblsk_propattach`'s `attachments` table (`owner_type = 'plugin:oblsk_hunting'`).
- No per-species weapon tiers, no stalking/tracking mechanic, no water/terrain gating beyond zone radius, no multi-output crafting recipes (species → one sellable item, or two recipes) — v1 scope per spec's Non-goals.
- Every new plugin (`oblsk_hunting`) and any plugin missing from `core/plugins/registry.json` must be present in that file for the loader to pick it up (see Task 9 — `oblsk_crafting` itself is currently absent and must be added too).
- All admin-placed world data (zones, sell points) has zero hardcoded seed rows — same posture as `oblsk_fishing`.
- Test files run via `lua5.4 <path-to-spec>.lua` from repo root, following the exact bootstrap sequence in `plugins/oblsk_crafting/tests/crafting_service_spec.lua` (dofile the ORM/dialects, `fake_query_builder.lua`, stub `CharacterService`/`ItemService`, dofile the service under test last).

---

## Part 1: oblsk_crafting queueing + pickup policy

### Task 1: crafting_points migration — queue_mode, pickup_policy, org_id

**Files:**
- Create: `plugins/oblsk_crafting/server/migrations/2026_08_16_100004_add_queue_pickup_to_crafting_points_table.lua`

**Interfaces:**
- Produces: `crafting_points.queue_mode` (`'per_character'|'shared'`, default `'per_character'`), `crafting_points.pickup_policy` (`'starter_only'|'anyone'|'org'`, default `'starter_only'`), `crafting_points.org_id` (nullable FK `organizations`).

- [ ] **Step 1: Write the migration**

```lua
-- plugins/oblsk_crafting/server/migrations/2026_08_16_100004_add_queue_pickup_to_crafting_points_table.lua
--- Migration: Add queue_mode/pickup_policy/org_id to crafting_points
--- queue_mode/pickup_policy default to the values that match today's actual
--- behavior (one job per character, auto-granted to whoever started it), so
--- every existing point keeps working unchanged after this migration runs.
--- org_id is required by CraftingService.collect() only when
--- pickup_policy = 'org'; unused (nullable) otherwise.
return {
    up = function()
        Schema.table('crafting_points', function(table)
            table:enum('queue_mode', {'per_character', 'shared'}):default('per_character')
            table:enum('pickup_policy', {'starter_only', 'anyone', 'org'}):default('starter_only')
            table:foreignId('org_id'):nullable():constrained('organizations'):onDelete('SET NULL')
        end)

        print('[Migration] Added queue_mode/pickup_policy/org_id to crafting_points table')
    end,

    down = function()
        Schema.dropColumn('crafting_points', 'queue_mode')
        Schema.dropColumn('crafting_points', 'pickup_policy')
        Schema.dropColumn('crafting_points', 'org_id')
        print('[Migration] Dropped queue_mode/pickup_policy/org_id from crafting_points table')
    end
}
```

- [ ] **Step 2: Commit**

```bash
git -C plugins/oblsk_crafting add server/migrations/2026_08_16_100004_add_queue_pickup_to_crafting_points_table.lua
git -C plugins/oblsk_crafting commit -m "feat(crafting): add queue_mode/pickup_policy/org_id to crafting_points"
```

### Task 2: crafting_jobs migration — status

**Files:**
- Create: `plugins/oblsk_crafting/server/migrations/2026_08_16_100005_add_status_to_crafting_jobs_table.lua`

**Interfaces:**
- Produces: `crafting_jobs.status` (`'queued'|'active'|'ready'`, default `'active'`).

- [ ] **Step 1: Write the migration**

```lua
-- plugins/oblsk_crafting/server/migrations/2026_08_16_100005_add_status_to_crafting_jobs_table.lua
--- Migration: Add status to crafting_jobs
--- Defaults to 'active' so any pre-existing row (none in practice today)
--- keeps ticking exactly as before. See CraftingService.start/advance for
--- how 'queued' and 'ready' get set.
return {
    up = function()
        Schema.table('crafting_jobs', function(table)
            table:enum('status', {'queued', 'active', 'ready'}):default('active')
        end)

        print('[Migration] Added status to crafting_jobs table')
    end,

    down = function()
        Schema.dropColumn('crafting_jobs', 'status')
        print('[Migration] Dropped status from crafting_jobs table')
    end
}
```

- [ ] **Step 2: Commit**

```bash
git -C plugins/oblsk_crafting add server/migrations/2026_08_16_100005_add_status_to_crafting_jobs_table.lua
git -C plugins/oblsk_crafting commit -m "feat(crafting): add status to crafting_jobs"
```

### Task 3: CraftingService.start() — queue_mode-aware active/queued insert

**Files:**
- Modify: `plugins/oblsk_crafting/server/services/CraftingService.lua:136-182` (`CraftingService.start`)
- Test: `plugins/oblsk_crafting/tests/crafting_service_spec.lua`

**Interfaces:**
- Consumes: existing `resolveRecipe(craftingPointId, recipeId)`, `grantToCharacter(characterId, baseItem, amount)`, `CraftingService.maxRuns(source, recipe)`.
- Produces: `CraftingService.start(source, craftingPointId, recipeId, batch)` unchanged signature/return shape (`ok, job-or-reason`); inserted `crafting_jobs` row now always carries a `status` field (`'active'` or `'queued'`).

The fake `crafting_points` fixture rows in the test file need `queue_mode`/`pickup_policy` columns from here on (Task 1's migration adds them in production; the test fixture is hand-authored data, so it needs the same columns added by hand). Default the fixture's point to `queue_mode = 'per_character'` unless a test explicitly overrides it.

- [ ] **Step 1: Write the failing tests**

Add to `plugins/oblsk_crafting/tests/crafting_service_spec.lua`, in `withFreshState`'s fixture, change the `crafting_points` row to:

```lua
        crafting_points = { { id = 1, name = 'Workbench', interaction_id = 1, queue_mode = 'per_character', pickup_policy = 'starter_only', org_id = nil } },
```

Then append these tests (before the final `for _, t in ipairs(tests) do` loop):

```lua
test('start marks the first job at a point active, per_character', function()
    withFreshState(function()
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        eq(job.status, 'active')
    end)
end)

test('start queues a second per_character job by the same character at the same point', function()
    withFreshState(function()
        CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        -- second job needs its own materials: top up stock first
        QueryBuilder.new('items'):insert({ id = 10, owner_type = 'character', owner_id = 100, base_item_id = SPRAY_ID, amount = 1 })
        QueryBuilder.new('items'):insert({ id = 11, owner_type = 'character', owner_id = 100, base_item_id = SHIRT_ID, amount = 1 })
        local _, job2 = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        eq(job2.status, 'queued')
    end)
end)

test('start does not queue a per_character job for a different character at the same point', function()
    withFreshState(function()
        CraftingService.start(1, POINT_ID, RECIPE_ID, 1) -- character 100
        QueryBuilder.new('items'):insert({ id = 10, owner_type = 'character', owner_id = 200, base_item_id = SPRAY_ID, amount = 1 })
        QueryBuilder.new('items'):insert({ id = 11, owner_type = 'character', owner_id = 200, base_item_id = SHIRT_ID, amount = 1 })
        local _, job2 = CraftingService.start(2, POINT_ID, RECIPE_ID, 1) -- character 200
        eq(job2.status, 'active')
    end)
end)

test('start queues behind any active job at a shared-queue point, regardless of who started it', function()
    withFreshState(function()
        QueryBuilder.new('crafting_points'):where('id', POINT_ID):update({ queue_mode = 'shared' })
        CraftingService.start(1, POINT_ID, RECIPE_ID, 1) -- character 100, becomes active
        QueryBuilder.new('items'):insert({ id = 10, owner_type = 'character', owner_id = 200, base_item_id = SPRAY_ID, amount = 1 })
        QueryBuilder.new('items'):insert({ id = 11, owner_type = 'character', owner_id = 200, base_item_id = SHIRT_ID, amount = 1 })
        local _, job2 = CraftingService.start(2, POINT_ID, RECIPE_ID, 1) -- character 200, must queue
        eq(job2.status, 'queued')
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: FAIL — `job.status` is `nil` (column doesn't exist yet in the insert).

- [ ] **Step 3: Implement queue_mode-aware status in start()**

Replace the job-insert block in `CraftingService.start` (`plugins/oblsk_crafting/server/services/CraftingService.lua:170-181`) with:

```lua
    local point = QueryBuilder.new('crafting_points'):where('id', craftingPointId):firstSync()
    local queueMode = point and point.queue_mode or 'per_character'

    local status
    if queueMode == 'shared' then
        local activeAtPoint = QueryBuilder.new('crafting_jobs')
            :where('crafting_point_id', craftingPointId)
            :where('status', 'active')
            :firstSync()
        status = activeAtPoint and 'queued' or 'active'
    else
        local activeForCharacter = QueryBuilder.new('crafting_jobs')
            :where('crafting_point_id', craftingPointId)
            :where('character_id', characterId)
            :where('status', 'active')
            :firstSync()
        status = activeForCharacter and 'queued' or 'active'
    end

    local jobId = QueryBuilder.new('crafting_jobs'):insert({
        character_id = characterId,
        crafting_point_id = craftingPointId,
        recipe_id = recipeId,
        runs_remaining = batch,
        started_at = Database.now(),
        remaining_seconds = recipe.craftSeconds,
        status = status,
        created_at = Database.now(),
        updated_at = Database.now(),
    })

    return true, QueryBuilder.new('crafting_jobs'):where('id', jobId):firstSync()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: PASS (all tests, including the 4 new ones).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_crafting add server/services/CraftingService.lua tests/crafting_service_spec.lua
git -C plugins/oblsk_crafting commit -m "feat(crafting): start() inserts active/queued jobs per point queue_mode"
```

### Task 4: CraftingService.advance() — active-only ticking, ready-not-granted, promotion on completion

**Files:**
- Modify: `plugins/oblsk_crafting/server/services/CraftingService.lua:278-333` (`CraftingService.advance`)
- Test: `plugins/oblsk_crafting/tests/crafting_service_spec.lua`

**Interfaces:**
- Consumes: `resolveRecipe`, `grantToCharacter`.
- Produces: `CraftingService.advance(deltaSeconds)` — same signature; a completing job now flips to `status = 'ready'` instead of being deleted+paid, and promotes the next `'queued'` job (scoped by `character_id` for `per_character`, point-wide for `shared`) to `'active'`.

Existing tests `'advance pays out and deletes the job when the last run completes'` and `'advance skips payout for a job concurrently cancelled during resolveRecipe'` must be updated: output is no longer granted at completion (only on `collect()`, added in Task 6), and the job row is no longer deleted at completion (it becomes `'ready'`).

- [ ] **Step 1: Update existing tests + write new failing tests**

Replace the existing `'advance pays out and deletes the job when the last run completes'` test with:

```lua
test('advance flips the job to ready and does not grant output on completion', function()
    withFreshState(function()
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        CraftingService.advance(6)
        local row = QueryBuilder.new('crafting_jobs'):where('id', job.id):firstSync()
        eq(row.status, 'ready')
        eq(ItemService.has(1, { id = BANDAGE_ID }, 2), false) -- not granted until collect()
    end)
end)
```

Replace `'advance skips payout for a job concurrently cancelled during resolveRecipe'` with:

```lua
test('advance skips flipping to ready for a job concurrently cancelled during resolveRecipe', function()
    withFreshState(function()
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)

        local realResolveRecipe = CraftingService._resolveRecipe
        CraftingService._resolveRecipe = function(craftingPointId, recipeId)
            QueryBuilder.new('crafting_jobs'):where('id', job.id):delete()
            return realResolveRecipe(craftingPointId, recipeId)
        end

        CraftingService.advance(6)
        CraftingService._resolveRecipe = realResolveRecipe

        eq(QueryBuilder.new('crafting_jobs'):where('id', job.id):firstSync(), nil)
    end)
end)
```

Then append:

```lua
test('advance does not tick a queued job', function()
    withFreshState(function()
        CraftingService.start(1, POINT_ID, RECIPE_ID, 1) -- active
        QueryBuilder.new('items'):insert({ id = 10, owner_type = 'character', owner_id = 100, base_item_id = SPRAY_ID, amount = 1 })
        QueryBuilder.new('items'):insert({ id = 11, owner_type = 'character', owner_id = 100, base_item_id = SHIRT_ID, amount = 1 })
        local _, job2 = CraftingService.start(1, POINT_ID, RECIPE_ID, 1) -- queued
        CraftingService.advance(6)
        local row = QueryBuilder.new('crafting_jobs'):where('id', job2.id):firstSync()
        eq(row.status, 'queued')
        eq(row.remaining_seconds, 6) -- untouched
    end)
end)

test('advance promotes the next per_character queued job to active on completion', function()
    withFreshState(function()
        local _, job1 = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        QueryBuilder.new('items'):insert({ id = 10, owner_type = 'character', owner_id = 100, base_item_id = SPRAY_ID, amount = 1 })
        QueryBuilder.new('items'):insert({ id = 11, owner_type = 'character', owner_id = 100, base_item_id = SHIRT_ID, amount = 1 })
        local _, job2 = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        eq(job2.status, 'queued')

        CraftingService.advance(6) -- job1 completes -> ready, job2 should promote
        local row1 = QueryBuilder.new('crafting_jobs'):where('id', job1.id):firstSync()
        local row2 = QueryBuilder.new('crafting_jobs'):where('id', job2.id):firstSync()
        eq(row1.status, 'ready')
        eq(row2.status, 'active')
        eq(row2.remaining_seconds, 6)
    end)
end)

test('advance promotes the next shared-queue job regardless of character on completion', function()
    withFreshState(function()
        QueryBuilder.new('crafting_points'):where('id', POINT_ID):update({ queue_mode = 'shared' })
        local _, job1 = CraftingService.start(1, POINT_ID, RECIPE_ID, 1) -- character 100, active
        QueryBuilder.new('items'):insert({ id = 10, owner_type = 'character', owner_id = 200, base_item_id = SPRAY_ID, amount = 1 })
        QueryBuilder.new('items'):insert({ id = 11, owner_type = 'character', owner_id = 200, base_item_id = SHIRT_ID, amount = 1 })
        local _, job2 = CraftingService.start(2, POINT_ID, RECIPE_ID, 1) -- character 200, queued

        CraftingService.advance(6)
        local row2 = QueryBuilder.new('crafting_jobs'):where('id', job2.id):firstSync()
        eq(row2.status, 'active')
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: FAIL — jobs still get deleted+paid at completion, no promotion happens, no `status` column tracked.

- [ ] **Step 3: Implement**

Add a private promotion helper above `CraftingService.advance` (after `grantToCharacter`, before `resolveRecipe`), and rewrite the completion branch of `advance`:

```lua
--- Promotes the oldest queued job at a completed job's point to 'active'.
--- Scoped to the same character under per_character queueing, or point-wide
--- under shared queueing, so promotion never jumps a per-character queue's
--- ordering across different characters.
--- @param completedJob table the crafting_jobs row that just went 'ready'
local function promoteNextQueued(completedJob)
    local point = QueryBuilder.new('crafting_points'):where('id', completedJob.crafting_point_id):firstSync()
    local queueMode = point and point.queue_mode or 'per_character'

    local query = QueryBuilder.new('crafting_jobs')
        :where('crafting_point_id', completedJob.crafting_point_id)
        :where('status', 'queued')
    if queueMode ~= 'shared' then
        query = query:where('character_id', completedJob.character_id)
    end
    local next = query:orderBy('id', 'asc'):firstSync()
    if not next then return end

    local recipe = resolveRecipe(next.crafting_point_id, next.recipe_id)
    QueryBuilder.new('crafting_jobs'):where('id', next.id):update({
        status = 'active',
        started_at = Database.now(),
        remaining_seconds = recipe and recipe.craftSeconds or next.remaining_seconds,
        updated_at = Database.now(),
    })
end
CraftingService._promoteNextQueued = promoteNextQueued -- exposed for Task 5's cancel()
```

Replace `CraftingService.advance`'s job loop (lines 279-332) so it only reads/ticks `status = 'active'` rows and flips to `'ready'` instead of deleting+paying:

```lua
function CraftingService.advance(deltaSeconds)
    local jobs = QueryBuilder.new('crafting_jobs'):where('status', 'active'):getSync()

    local newRemainingById = {}
    for _, job in ipairs(jobs) do
        newRemainingById[job.id] = job.remaining_seconds - deltaSeconds
    end

    Database.updateSync(
        'UPDATE crafting_jobs SET remaining_seconds = remaining_seconds - ?, updated_at = ? WHERE status = \'active\' AND remaining_seconds > ?',
        { deltaSeconds, Database.now(), deltaSeconds }
    )

    for _, job in ipairs(jobs) do
        local newRemaining = newRemainingById[job.id]

        if newRemaining <= 0 then
            local recipe = CraftingService._resolveRecipe(job.crafting_point_id, job.recipe_id)
            local stillExists = QueryBuilder.new('crafting_jobs'):where('id', job.id):where('status', 'active'):firstSync()

            if stillExists then
                local runsLeft = job.runs_remaining - 1
                if runsLeft <= 0 then
                    QueryBuilder.new('crafting_jobs'):where('id', job.id):update({
                        status = 'ready',
                        runs_remaining = 0,
                        remaining_seconds = 0,
                        updated_at = Database.now(),
                    })
                    promoteNextQueued(job)
                else
                    local craftSeconds = recipe and recipe.craftSeconds or 1
                    QueryBuilder.new('crafting_jobs'):where('id', job.id):update({
                        runs_remaining = runsLeft,
                        remaining_seconds = craftSeconds + newRemaining,
                        started_at = Database.now(),
                        updated_at = Database.now(),
                    })
                end
            end
        end
    end
end
```

Note: the test fake `Database.updateSync` in the spec file matches on `query:match('^UPDATE crafting_jobs SET remaining_seconds')`, which still matches the new WHERE clause unchanged — no test-support edit needed. The fake only mutates rows with `remaining_seconds > delta`, so it must also be updated to skip non-`'active'` rows (queued jobs are otherwise still touched by the fake):

Update the `Database.updateSync` stub near the top of `crafting_service_spec.lua`:

```lua
function Database.updateSync(query, params)
    if query:match('^UPDATE crafting_jobs SET remaining_seconds') then
        local delta = params[1]
        for _, row in ipairs(QueryBuilder.new('crafting_jobs'):getSync()) do
            if row.status == 'active' and row.remaining_seconds > delta then
                row.remaining_seconds = row.remaining_seconds - delta
                row.updated_at = Database.now()
            end
        end
        return 0
    end
    error('unexpected Database.updateSync call in tests: ' .. tostring(query))
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_crafting add server/services/CraftingService.lua tests/crafting_service_spec.lua
git -C plugins/oblsk_crafting commit -m "feat(crafting): advance() ticks active jobs only, flips to ready, promotes queue"
```

### Task 5: CraftingService.cancel() — promote next queued job

**Files:**
- Modify: `plugins/oblsk_crafting/server/services/CraftingService.lua:188-208` (`CraftingService.cancel`)
- Test: `plugins/oblsk_crafting/tests/crafting_service_spec.lua`

**Interfaces:**
- Consumes: `CraftingService._promoteNextQueued(job)` from Task 4.
- Produces: `CraftingService.cancel(source, jobId)` — unchanged signature/return; now also promotes the next queued job when cancelling an `'active'` one so a shared/per-character queue never stalls.
- Also: cancelling a `'ready'` job (output unclaimed but not yet collected) must still be rejected — a ready job has no `runs_remaining` left to refund and represents completed, waiting output, not a cancellable in-progress job.

- [ ] **Step 1: Write the failing tests**

Append to `crafting_service_spec.lua`:

```lua
test('cancel promotes the next queued job at the same point', function()
    withFreshState(function()
        local _, job1 = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        QueryBuilder.new('items'):insert({ id = 10, owner_type = 'character', owner_id = 100, base_item_id = SPRAY_ID, amount = 1 })
        QueryBuilder.new('items'):insert({ id = 11, owner_type = 'character', owner_id = 100, base_item_id = SHIRT_ID, amount = 1 })
        local _, job2 = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)

        CraftingService.cancel(1, job1.id)
        local row2 = QueryBuilder.new('crafting_jobs'):where('id', job2.id):firstSync()
        eq(row2.status, 'active')
    end)
end)

test('cancel rejects a ready (already-completed, uncollected) job', function()
    withFreshState(function()
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        CraftingService.advance(6) -- job goes ready
        local ok, reason = CraftingService.cancel(1, job.id)
        eq(ok, false)
        eq(reason, 'Cannot cancel a completed job')
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: FAIL — queued job stays queued after cancel; ready job gets cancelled/refunded instead of rejected.

- [ ] **Step 3: Implement**

Replace `CraftingService.cancel` (lines 188-208):

```lua
function CraftingService.cancel(source, jobId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'No active character'
    end

    local job = QueryBuilder.new('crafting_jobs'):where('id', jobId):firstSync()
    if not job or job.character_id ~= characterId then
        return false, 'Not your job'
    end

    if job.status == 'ready' then
        return false, 'Cannot cancel a completed job'
    end

    local recipe = resolveRecipe(job.crafting_point_id, job.recipe_id)
    if recipe then
        for _, input in ipairs(recipe.inputs) do
            grantToCharacter(characterId, input.baseItem, input.qty * job.runs_remaining)
        end
    end

    QueryBuilder.new('crafting_jobs'):where('id', jobId):delete()

    if job.status == 'active' then
        promoteNextQueued(job)
    end

    return true
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_crafting add server/services/CraftingService.lua tests/crafting_service_spec.lua
git -C plugins/oblsk_crafting commit -m "feat(crafting): cancel() promotes next queued job, rejects cancelling ready jobs"
```

### Task 6: CraftingService.collect() — pickup policy enforcement

**Files:**
- Modify: `plugins/oblsk_crafting/server/services/CraftingService.lua` (new function, add after `cancel`)
- Test: `plugins/oblsk_crafting/tests/crafting_service_spec.lua`

**Interfaces:**
- Consumes: `resolveRecipe`, `grantToCharacter`, `CharacterService.getActiveCharacterId`, `OrganizationService.getMembership(characterId, orgId)` (stub this in the test file the same way `CharacterService`/`ItemService` are stubbed).
- Produces: `CraftingService.collect(source, jobId)` → `boolean ok, string|nil reason`. On success grants `recipe.outputBaseItem × recipe.outputQty` to the caller's active character and deletes the job row.

- [ ] **Step 1: Write the failing tests**

Add an `OrganizationService` stub near the top of `crafting_service_spec.lua`, after the `ItemService` stub block:

```lua
-- OrganizationService stub: characterId 300 is a member of org 1, no one else.
OrganizationService = {}
function OrganizationService.getMembership(characterId, orgId)
    if characterId == 300 and orgId == 1 then return { organization_id = 1 } end
    return nil
end
```

Extend `CharacterService.getActiveCharacterId` in the same file to also map `source == 3` to `characterId 300`:

```lua
function CharacterService.getActiveCharacterId(source)
    if source == 1 then return 100 end
    if source == 2 then return 200 end
    if source == 3 then return 300 end
    return nil
end
```

Append tests:

```lua
test('collect fails on a job that is not ready', function()
    withFreshState(function()
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        local ok, reason = CraftingService.collect(1, job.id)
        eq(ok, false)
        eq(reason, 'Not ready yet')
    end)
end)

test('collect grants output and deletes the job when ready, starter_only allows the starter', function()
    withFreshState(function()
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        CraftingService.advance(6)
        local ok = CraftingService.collect(1, job.id)
        eq(ok, true)
        eq(ItemService.has(1, { id = BANDAGE_ID }, 2), true)
        eq(QueryBuilder.new('crafting_jobs'):where('id', job.id):firstSync(), nil)
    end)
end)

test('collect rejects a non-starter under starter_only', function()
    withFreshState(function()
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        CraftingService.advance(6)
        local ok, reason = CraftingService.collect(2, job.id)
        eq(ok, false)
        eq(reason, 'Not yours to collect')
    end)
end)

test('collect allows any caller under anyone policy', function()
    withFreshState(function()
        QueryBuilder.new('crafting_points'):where('id', POINT_ID):update({ pickup_policy = 'anyone' })
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        CraftingService.advance(6)
        local ok = CraftingService.collect(2, job.id)
        eq(ok, true)
        eq(ItemService.has(2, { id = BANDAGE_ID }, 2), true)
    end)
end)

test('collect checks org membership under org policy', function()
    withFreshState(function()
        QueryBuilder.new('crafting_points'):where('id', POINT_ID):update({ pickup_policy = 'org', org_id = 1 })
        local _, job = CraftingService.start(1, POINT_ID, RECIPE_ID, 1)
        CraftingService.advance(6)

        local okNonMember, reason = CraftingService.collect(2, job.id) -- character 200, not org member
        eq(okNonMember, false)
        eq(reason, 'Not yours to collect')

        local okMember = CraftingService.collect(3, job.id) -- character 300, org member
        eq(okMember, true)
    end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: FAIL — `CraftingService.collect` doesn't exist yet.

- [ ] **Step 3: Implement**

Add after `CraftingService.cancel`:

```lua
--- @param source number
--- @param jobId number
--- @return boolean ok
--- @return string|nil reason on failure
function CraftingService.collect(source, jobId)
    local characterId = CharacterService.getActiveCharacterId(source)
    if not characterId then
        return false, 'No active character'
    end

    local job = QueryBuilder.new('crafting_jobs'):where('id', jobId):firstSync()
    if not job then
        return false, 'Unknown job'
    end
    if job.status ~= 'ready' then
        return false, 'Not ready yet'
    end

    local point = QueryBuilder.new('crafting_points'):where('id', job.crafting_point_id):firstSync()
    local policy = point and point.pickup_policy or 'starter_only'

    local allowed
    if policy == 'anyone' then
        allowed = true
    elseif policy == 'org' then
        allowed = point.org_id ~= nil and OrganizationService.getMembership(characterId, point.org_id) ~= nil
    else -- starter_only
        allowed = job.character_id == characterId
    end

    if not allowed then
        return false, 'Not yours to collect'
    end

    local recipe = resolveRecipe(job.crafting_point_id, job.recipe_id)
    if recipe then
        grantToCharacter(characterId, recipe.outputBaseItem, recipe.outputQty)
    end

    QueryBuilder.new('crafting_jobs'):where('id', jobId):delete()
    return true
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_crafting add server/services/CraftingService.lua tests/crafting_service_spec.lua
git -C plugins/oblsk_crafting commit -m "feat(crafting): add collect() with per-point pickup policy enforcement"
```

### Task 7: main.lua wiring — collect net event + ready-state sync

**Files:**
- Modify: `plugins/oblsk_crafting/server/main.lua`

**Interfaces:**
- Consumes: `CraftingService.collect(source, jobId)` from Task 6.
- Produces: `crafting:client:collect` handler emitting `crafting:server:collectResult`; `CraftingService.listJobs` output already includes `status`/`id` fields the client needs (no change needed there — the raw job row's `status` isn't currently surfaced by `listJobs`, add it).

`CraftingService.listJobs` (lines 213-237) builds its own row shape and drops `status` — add it so the client can render a "ready, collect" button per job.

- [ ] **Step 1: Add `status` to listJobs' row shape**

In `plugins/oblsk_crafting/server/services/CraftingService.lua`, inside `CraftingService.listJobs`'s `table.insert(rows, { ... })` (around line 226), add `status = job.status,`:

```lua
        table.insert(rows, {
            id = job.id,
            recipeId = job.recipe_id,
            outputItemName = (recipe and recipe.outputBaseItem and recipe.outputBaseItem.name) or 'Unknown item',
            runsRemaining = job.runs_remaining,
            craftSeconds = craftSeconds,
            remainingSeconds = job.remaining_seconds,
            pct = craftSeconds > 0 and (100 - (job.remaining_seconds / craftSeconds * 100)) or 0,
            status = job.status,
        })
```

- [ ] **Step 2: Add the collect net event**

In `plugins/oblsk_crafting/server/main.lua`, after the existing `crafting:client:cancel` handler (after line 63):

```lua
Obelisk.onClient('crafting:client:collect', function(player, jobId)
    local source = player:getSource()
    local ok, reason = CraftingService.collect(source, jobId)
    Obelisk.emitClient('crafting:server:collectResult', player, { ok = ok, reason = reason })
end)
```

- [ ] **Step 3: Run the crafting test suite to confirm no regression**

Run: `lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua`
Expected: PASS (all tests, `listJobs` row-shape addition is additive).

- [ ] **Step 4: Commit**

```bash
git -C plugins/oblsk_crafting add server/main.lua server/services/CraftingService.lua
git -C plugins/oblsk_crafting commit -m "feat(crafting): wire collect() net event, surface job status to the client"
```

### Task 8: Crafting.vue — ready/collect UI

**Files:**
- Modify: `plugins/oblsk_crafting/web/Crafting.vue`

**Interfaces:**
- Consumes: `crafting:server:sync`/`crafting:server:jobsSync`/`crafting:server:craftResult` payloads (`jobs[].status`, from Task 7), emits `crafting:client:collect` (from Task 7).

- [ ] **Step 1: Read the current job-list rendering block**

Find the template section in `plugins/oblsk_crafting/web/Crafting.vue` that lists `jobs` (each with `outputItemName`, `pct`, `runsRemaining`, and a Cancel button wired to a `cancelJob(job.id)` method that emits `crafting:client:cancel`).

- [ ] **Step 2: Add a ready state + collect button**

In the per-job template block, gate the existing progress bar/Cancel button on `job.status !== 'ready'`, and add a sibling branch for `job.status === 'ready'`:

```html
<div v-if="job.status === 'ready'" class="job-ready">
  <span>{{ job.outputItemName }} ready to collect</span>
  <button @click="collectJob(job.id)">Collect</button>
</div>
<div v-else class="job-progress">
  <!-- existing progress bar / Cancel button, unchanged -->
</div>
```

Add a `collectJob` method alongside the existing `cancelJob` method:

```js
collectJob(jobId) {
  Obelisk.emit('crafting:client:collect', jobId)
}
```

- [ ] **Step 3: Manually verify in a running FiveM/dev session**

Start a job, let `remaining_seconds` reach 0 (or lower `craft_seconds` on a test recipe), confirm the UI shows "ready to collect" instead of looping, click Collect, confirm the item is granted and the job disappears from the list.

- [ ] **Step 4: Commit**

```bash
git -C plugins/oblsk_crafting add web/Crafting.vue
git -C plugins/oblsk_crafting commit -m "feat(crafting): show ready/collect state in Crafting.vue"
```

---

## Part 2: oblsk_hunting plugin

### Task 9: Scaffold plugin repo, config, registry

**Files:**
- Create: `plugins/oblsk_hunting/fxmanifest.lua`
- Create: `plugins/oblsk_hunting/shared/config.lua`
- Modify: `core/plugins/registry.json`

**Interfaces:**
- Produces: `HuntingConfig` global (`SkinSeconds`, `MaxCarried`, `MaxPerVehicle`, `MaxDamagePerHit`, `Requires.bindings['hunting.weapon']`) — read by every hunting service task below.

`oblsk_hunting` is its own nested git repo, same convention as `oblsk_fishing`/`oblsk_propattach` (see project's plugin repo isolation approach — do not attempt to make `plugins/oblsk_hunting` part of the `core` repo's own git history).

Also note: `core/plugins/registry.json` is currently missing `oblsk_crafting` (confirm with `grep oblsk_crafting core/plugins/registry.json` — as of this plan's writing it is absent), so this task fixes that alongside adding `oblsk_hunting`.

- [ ] **Step 1: Initialize the plugin repo**

```bash
mkdir -p plugins/oblsk_hunting/shared plugins/oblsk_hunting/server/migrations plugins/oblsk_hunting/server/services plugins/oblsk_hunting/client plugins/oblsk_hunting/web plugins/oblsk_hunting/tests
cd plugins/oblsk_hunting && git init -q && cd -
```

- [ ] **Step 2: Write fxmanifest.lua**

```lua
fx_version 'cerulean'
games { 'gta5' }

name 'Hunting'
author ''
version '1.0.0'

dependencies {
    'obelisk'
}

shared_scripts {
    'shared/**/*.lua'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
    'web/routes.js',
}
```

- [ ] **Step 3: Write shared/config.lua**

```lua
-- plugins/oblsk_hunting/shared/config.lua
HuntingConfig = {}

HuntingConfig.Debug = false

-- Timed skin action duration (seconds), client-side progress bar,
-- server-confirmed completion attaches the carcass.
HuntingConfig.SkinSeconds = 8

-- Flat capacity constants (v1: no per-character/per-vehicle-model variance).
HuntingConfig.MaxCarried = 1
HuntingConfig.MaxPerVehicle = 4

-- A single client-reported hit's damage is clamped to this before being
-- applied to a tracked animal's health, so an inflated client value can't
-- one-shot an animal regardless of the weapon actually used.
HuntingConfig.MaxDamagePerHit = 50

HuntingConfig.Requires = {
    bindings = {
        ['hunting.weapon'] = {
            live = true,
            description = 'The item required to land a kill on hunting-spawned animals',
            hint = 'Any base item — mark is_useable false, it is checked on hit-report, not used directly',
        },
    },
}

return HuntingConfig
```

- [ ] **Step 4: Add oblsk_crafting and oblsk_hunting to registry.json**

Edit `core/plugins/registry.json`, inserting `"oblsk_crafting"` (alphabetically before `"oblsk_deathscreen"`) and `"oblsk_hunting"` (alphabetically before `"oblsk_inventory"`) into the `plugins` array.

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_hunting add fxmanifest.lua shared/config.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): scaffold plugin repo, fxmanifest, config"
git add core/plugins/registry.json
git commit -m "chore(registry): register oblsk_crafting and oblsk_hunting plugins"
```

### Task 10: Migrations — hunting_zones, hunting_zone_species, hunting_sell_points, hunting_sell_point_items

**Files:**
- Create: `plugins/oblsk_hunting/server/migrations/2026_08_16_150000_create_hunting_zones_table.lua`
- Create: `plugins/oblsk_hunting/server/migrations/2026_08_16_150001_create_hunting_zone_species_table.lua`
- Create: `plugins/oblsk_hunting/server/migrations/2026_08_16_150002_create_hunting_sell_points_table.lua`
- Create: `plugins/oblsk_hunting/server/migrations/2026_08_16_150003_create_hunting_sell_point_items_table.lua`

**Interfaces:**
- Produces: the four tables read/written by every hunting service task below.

- [ ] **Step 1: hunting_zones**

```lua
-- plugins/oblsk_hunting/server/migrations/2026_08_16_150000_create_hunting_zones_table.lua
--- Migration: Create hunting_zones table
--- Admin-placed roaming-spawn zone, same posture as fishing_spots — no
--- seeded rows, every row created through the Hunting admin tab.
return {
    up = function()
        Schema.create('hunting_zones', function(table)
            table:id()
            table:string('label', 100)
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('radius'):default(50.0)
            table:integer('max_concurrent'):default(3)
            table:boolean('enabled'):default(1)
            table:timestamps()
        end)

        print('[Migration] Created hunting_zones table')
    end,

    down = function()
        Schema.drop('hunting_zones')
        print('[Migration] Dropped hunting_zones table')
    end
}
```

- [ ] **Step 2: hunting_zone_species**

```lua
-- plugins/oblsk_hunting/server/migrations/2026_08_16_150001_create_hunting_zone_species_table.lua
--- Migration: Create hunting_zone_species table
--- Which species can spawn in a zone, their relative spawn weight, and the
--- carcass prop model that species produces when skinned.
return {
    up = function()
        Schema.create('hunting_zone_species', function(table)
            table:id()
            table:foreignId('zone_id'):constrained('hunting_zones'):onDelete('CASCADE')
            table:string('species_label', 60)
            table:string('carcass_prop_model', 100)
            table:float('weight'):default(1.0)
            table:integer('base_health'):default(100)
            table:timestamps()
        end)

        print('[Migration] Created hunting_zone_species table')
    end,

    down = function()
        Schema.drop('hunting_zone_species')
        print('[Migration] Dropped hunting_zone_species table')
    end
}
```

- [ ] **Step 3: hunting_sell_points**

```lua
-- plugins/oblsk_hunting/server/migrations/2026_08_16_150002_create_hunting_sell_points_table.lua
--- Migration: Create hunting_sell_points table
--- Separate admin-placed interaction, hunting-owned (not routed through
--- oblsk_shop) — same "plugin owns its own simple mechanism" posture as
--- oblsk_fishing owning its spots.
return {
    up = function()
        Schema.create('hunting_sell_points', function(table)
            table:id()
            table:string('label', 100)
            table:float('x')
            table:float('y')
            table:float('z')
            table:float('range'):default(2.0)
            table:boolean('enabled'):default(1)
            table:timestamps()
        end)

        print('[Migration] Created hunting_sell_points table')
    end,

    down = function()
        Schema.drop('hunting_sell_points')
        print('[Migration] Dropped hunting_sell_points table')
    end
}
```

- [ ] **Step 4: hunting_sell_point_items**

```lua
-- plugins/oblsk_hunting/server/migrations/2026_08_16_150003_create_hunting_sell_point_items_table.lua
--- Migration: Create hunting_sell_point_items table
--- Which processed items are sellable at a sell point and at what price.
return {
    up = function()
        Schema.create('hunting_sell_point_items', function(table)
            table:id()
            table:foreignId('sell_point_id'):constrained('hunting_sell_points'):onDelete('CASCADE')
            table:foreignId('base_item_id'):constrained('base_items'):onDelete('CASCADE')
            table:integer('cash_per_unit')
            table:timestamps()

            table:unique({'sell_point_id', 'base_item_id'})
        end)

        print('[Migration] Created hunting_sell_point_items table')
    end,

    down = function()
        Schema.drop('hunting_sell_point_items')
        print('[Migration] Dropped hunting_sell_point_items table')
    end
}
```

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_hunting add server/migrations
git -C plugins/oblsk_hunting commit -m "feat(hunting): migrations for zones, zone species, sell points, sell point items"
```

### Task 11: HuntingZoneService — zone/species CRUD

**Files:**
- Create: `plugins/oblsk_hunting/server/services/HuntingZoneService.lua`
- Test: `plugins/oblsk_hunting/tests/hunting_zone_service_spec.lua`

**Interfaces:**
- Produces: `HuntingZoneService.listZones()`, `.createZone(attrs)`, `.deleteZone(id)`, `.listSpecies(zoneId)`, `.createSpecies(zoneId, attrs)`, `.deleteSpecies(id)` — mirrors `FishingSpotService`'s shape exactly.

- [ ] **Step 1: Write the failing test file**

```lua
-- plugins/oblsk_hunting/tests/hunting_zone_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_hunting/tests/hunting_zone_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')
dofile(scriptDir .. '../server/services/HuntingZoneService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        hunting_zones = {},
        hunting_zone_species = {},
    })
    QueryBuilder = fake
    fn(fake)
end

test('createZone inserts a row with defaults', function()
    withFreshState(function()
        local id = HuntingZoneService.createZone({ label = 'Forest', x = 1, y = 2, z = 3 })
        local zones = HuntingZoneService.listZones()
        eq(#zones, 1)
        eq(zones[1].id, id)
        eq(zones[1].radius, 50.0)
        eq(zones[1].max_concurrent, 3)
        eq(zones[1].enabled, 1)
    end)
end)

test('createZone honors explicit radius/max_concurrent/enabled', function()
    withFreshState(function()
        HuntingZoneService.createZone({ label = 'Plains', x = 0, y = 0, z = 0, radius = 100, max_concurrent = 8, enabled = false })
        local zones = HuntingZoneService.listZones()
        eq(zones[1].radius, 100)
        eq(zones[1].max_concurrent, 8)
        eq(zones[1].enabled, false)
    end)
end)

test('deleteZone removes the row', function()
    withFreshState(function()
        local id = HuntingZoneService.createZone({ label = 'Forest', x = 1, y = 2, z = 3 })
        HuntingZoneService.deleteZone(id)
        eq(#HuntingZoneService.listZones(), 0)
    end)
end)

test('createSpecies inserts a row scoped to its zone with defaults', function()
    withFreshState(function()
        local zoneId = HuntingZoneService.createZone({ label = 'Forest', x = 1, y = 2, z = 3 })
        HuntingZoneService.createSpecies(zoneId, { species_label = 'Deer', carcass_prop_model = 'prop_deer_carc_01' })
        local species = HuntingZoneService.listSpecies(zoneId)
        eq(#species, 1)
        eq(species[1].species_label, 'Deer')
        eq(species[1].weight, 1.0)
        eq(species[1].base_health, 100)
    end)
end)

test('listSpecies only returns rows for the requested zone', function()
    withFreshState(function()
        local zoneA = HuntingZoneService.createZone({ label = 'A', x = 0, y = 0, z = 0 })
        local zoneB = HuntingZoneService.createZone({ label = 'B', x = 0, y = 0, z = 0 })
        HuntingZoneService.createSpecies(zoneA, { species_label = 'Deer', carcass_prop_model = 'prop_deer_carc_01' })
        HuntingZoneService.createSpecies(zoneB, { species_label = 'Boar', carcass_prop_model = 'prop_boar_carc_01' })
        eq(#HuntingZoneService.listSpecies(zoneA), 1)
        eq(#HuntingZoneService.listSpecies(zoneB), 1)
    end)
end)

test('deleteSpecies removes the row', function()
    withFreshState(function()
        local zoneId = HuntingZoneService.createZone({ label = 'Forest', x = 1, y = 2, z = 3 })
        local speciesId = HuntingZoneService.createSpecies(zoneId, { species_label = 'Deer', carcass_prop_model = 'prop_deer_carc_01' })
        HuntingZoneService.deleteSpecies(speciesId)
        eq(#HuntingZoneService.listSpecies(zoneId), 0)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_zone_service_spec.lua`
Expected: FAIL — `HuntingZoneService` is nil (file doesn't exist yet).

- [ ] **Step 3: Implement HuntingZoneService.lua**

```lua
-- plugins/oblsk_hunting/server/services/HuntingZoneService.lua
--- HuntingZoneService - admin-panel CRUD for hunting zones and their
--- per-zone species pools. No seeding — every row here is created through
--- the Hunting admin tab. Mirrors FishingSpotService's shape.
HuntingZoneService = {}

--- @return table[] every hunting_zones row
function HuntingZoneService.listZones()
    return QueryBuilder.new('hunting_zones'):getSync()
end

--- @param attrs table label, x, y, z, radius (default 50.0),
---   max_concurrent (default 3), enabled (default true)
--- @return number id
function HuntingZoneService.createZone(attrs)
    return QueryBuilder.new('hunting_zones'):insert({
        label = attrs.label,
        x = attrs.x,
        y = attrs.y,
        z = attrs.z,
        radius = attrs.radius or 50.0,
        max_concurrent = attrs.max_concurrent or 3,
        enabled = attrs.enabled == nil and 1 or attrs.enabled,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @return boolean
function HuntingZoneService.deleteZone(id)
    QueryBuilder.new('hunting_zones'):where('id', id):delete()
    return true
end

--- @param zoneId number
--- @return table[]
function HuntingZoneService.listSpecies(zoneId)
    return QueryBuilder.new('hunting_zone_species'):where('zone_id', zoneId):getSync()
end

--- @param zoneId number
--- @param attrs table species_label, carcass_prop_model, weight (default 1.0),
---   base_health (default 100)
--- @return number id
function HuntingZoneService.createSpecies(zoneId, attrs)
    return QueryBuilder.new('hunting_zone_species'):insert({
        zone_id = zoneId,
        species_label = attrs.species_label,
        carcass_prop_model = attrs.carcass_prop_model,
        weight = attrs.weight or 1.0,
        base_health = attrs.base_health or 100,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @return boolean
function HuntingZoneService.deleteSpecies(id)
    QueryBuilder.new('hunting_zone_species'):where('id', id):delete()
    return true
end

return HuntingZoneService
```

- [ ] **Step 4: Run to verify it passes**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_zone_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_hunting add server/services/HuntingZoneService.lua tests/hunting_zone_service_spec.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): HuntingZoneService zone/species CRUD"
```

### Task 12: HuntingSpawnerService — weighted spawn, per-zone cap, health tracking

**Files:**
- Create: `plugins/oblsk_hunting/server/services/HuntingSpawnerService.lua`
- Test: `plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua`

**Interfaces:**
- Consumes: `HuntingZoneService.listZones()`, `HuntingZoneService.listSpecies(zoneId)` (Task 11); `EntityStreamerService.register('ped', entityData)` / `.unregister('ped', entityId)` (real signature confirmed at `core/core/server/Services/EntityStreamerService.lua:272,322` — stub in tests).
- Produces: `HuntingSpawnerService.tick()` (spawns up to each enabled zone's `max_concurrent`), `HuntingSpawnerService.getHealth(entityId)`, `HuntingSpawnerService.applyDamage(entityId, damage)` → `number newHealth`, `HuntingSpawnerService.despawn(entityId)`, `HuntingSpawnerService.getTracked(entityId)` → `{ zoneId, species, carcassPropModel }|nil`, `HuntingSpawnerService.resetForTests()`.

Deterministic-random override for the weighted pick, same technique the spec calls out (`VENDING_RANDOM_OVERRIDE`) — check that exact pattern first:

- [ ] **Step 1: Confirm the deterministic-random override pattern**

```bash
grep -n "VENDING_RANDOM_OVERRIDE" -r plugins/oblsk_vendingmachine/server/services/VendingMachineService.lua plugins/oblsk_vendingmachine/tests/*.lua
```

Use whatever module-level override variable name and check shape that search reveals (e.g. `local rand = HuntingSpawnerService._randomOverride or math.random`) for `HuntingSpawnerService._spawnRandomOverride`, consumed inside the weighted-species-pick and inside-radius-point-pick logic below.

- [ ] **Step 2: Write the failing test file**

```lua
-- plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- EntityStreamerService stub: register returns a deterministic incrementing
-- id, unregister just records the call. Test-only in-memory tracking, no
-- real chunking/budget logic needed here — HuntingSpawnerService owns its
-- own health map independently of this stub.
local nextEntityId = 1
local registeredCalls, unregisteredCalls = {}, {}
EntityStreamerService = {}
function EntityStreamerService.register(entityType, entityData)
    local id = entityType .. '_test_' .. nextEntityId
    nextEntityId = nextEntityId + 1
    table.insert(registeredCalls, { entityType = entityType, entityData = entityData, id = id })
    return id
end
function EntityStreamerService.unregister(entityType, entityId)
    table.insert(unregisteredCalls, { entityType = entityType, entityId = entityId })
end

dofile(scriptDir .. '../server/services/HuntingZoneService.lua')
dofile(scriptDir .. '../server/services/HuntingSpawnerService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local ZONE_ID

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        hunting_zones = { { id = 1, label = 'Forest', x = 0, y = 0, z = 0, radius = 50, max_concurrent = 2, enabled = 1 } },
        hunting_zone_species = {
            { id = 1, zone_id = 1, species_label = 'Deer', carcass_prop_model = 'prop_deer_carc_01', weight = 1.0, base_health = 100 },
        },
    })
    QueryBuilder = fake
    ZONE_ID = 1
    registeredCalls, unregisteredCalls, nextEntityId = {}, {}, 1
    HuntingSpawnerService.resetForTests()
    fn(fake)
end

test('tick spawns up to a zone\'s max_concurrent and no further', function()
    withFreshState(function()
        HuntingSpawnerService.tick()
        eq(#registeredCalls, 2) -- max_concurrent = 2
        HuntingSpawnerService.tick()
        eq(#registeredCalls, 2) -- already at cap, no more spawns
    end)
end)

test('spawned entity is tracked with base_health and species', function()
    withFreshState(function()
        HuntingSpawnerService.tick()
        local entityId = registeredCalls[1].id
        eq(HuntingSpawnerService.getHealth(entityId), 100)
        local tracked = HuntingSpawnerService.getTracked(entityId)
        eq(tracked.species, 'Deer')
        eq(tracked.carcassPropModel, 'prop_deer_carc_01')
        eq(tracked.zoneId, ZONE_ID)
    end)
end)

test('applyDamage decrements tracked health and does not go below 0', function()
    withFreshState(function()
        HuntingSpawnerService.tick()
        local entityId = registeredCalls[1].id
        local h1 = HuntingSpawnerService.applyDamage(entityId, 40)
        eq(h1, 60)
        local h2 = HuntingSpawnerService.applyDamage(entityId, 1000)
        eq(h2, 0)
    end)
end)

test('despawn unregisters the entity and clears tracking', function()
    withFreshState(function()
        HuntingSpawnerService.tick()
        local entityId = registeredCalls[1].id
        HuntingSpawnerService.despawn(entityId)
        eq(#unregisteredCalls, 1)
        eq(unregisteredCalls[1].entityId, entityId)
        eq(HuntingSpawnerService.getTracked(entityId), nil)
    end)
end)

test('a disabled zone is never spawned into', function()
    withFreshState(function()
        QueryBuilder.new('hunting_zones'):where('id', ZONE_ID):update({ enabled = 0 })
        HuntingSpawnerService.tick()
        eq(#registeredCalls, 0)
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 3: Run to verify it fails**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua`
Expected: FAIL — `HuntingSpawnerService` is nil.

- [ ] **Step 4: Implement HuntingSpawnerService.lua**

```lua
-- plugins/oblsk_hunting/server/services/HuntingSpawnerService.lua
--- HuntingSpawnerService - ticks enabled hunting_zones up to their
--- max_concurrent live-animal count, picking a weighted species and a
--- random point inside the zone radius each spawn. Tracks
--- { entityId -> { zoneId, species, carcassPropModel, health } } in memory,
--- mirroring VendingMachineService.credits' in-memory session-state posture
--- (this data does not need to survive a restart — a restart simply
--- despawns and re-ticks fresh).
HuntingSpawnerService = {}

local tracked = {} -- entityId -> { zoneId, species, carcassPropModel, health }
local liveCountByZone = {} -- zoneId -> number

--- Test-only override so spawn-position/species-pick randomness is
--- deterministic in specs. Production leaves this nil and falls back to
--- math.random.
HuntingSpawnerService._randomOverride = nil

local function rand(min, max)
    if HuntingSpawnerService._randomOverride then
        return HuntingSpawnerService._randomOverride(min, max)
    end
    return min + math.random() * (max - min)
end

--- @param speciesList table[] hunting_zone_species rows
--- @return table|nil the weighted-picked row
local function pickWeightedSpecies(speciesList)
    local totalWeight = 0
    for _, s in ipairs(speciesList) do totalWeight = totalWeight + s.weight end
    if totalWeight <= 0 then return nil end

    local roll = rand(0, totalWeight)
    local acc = 0
    for _, s in ipairs(speciesList) do
        acc = acc + s.weight
        if roll <= acc then return s end
    end
    return speciesList[#speciesList]
end

--- Spawns into every enabled zone below its max_concurrent live-animal
--- count. Call once per spawner tick from server/main.lua's CreateThread
--- loop (same pattern as CraftingService.advance()).
function HuntingSpawnerService.tick()
    for _, zone in ipairs(HuntingZoneService.listZones()) do
        if zone.enabled ~= 0 and zone.enabled ~= false then
            local live = liveCountByZone[zone.id] or 0
            while live < zone.max_concurrent do
                local species = pickWeightedSpecies(HuntingZoneService.listSpecies(zone.id))
                if not species then break end

                local angle = rand(0, 2 * math.pi)
                local dist = rand(0, zone.radius)
                local x = zone.x + math.cos(angle) * dist
                local y = zone.y + math.sin(angle) * dist

                local entityId = EntityStreamerService.register('ped', {
                    x = x, y = y, z = zone.z,
                    model = species.species_label,
                    networked = true,
                    data = { huntingZoneId = zone.id, species = species.species_label },
                })
                if entityId then
                    tracked[entityId] = {
                        zoneId = zone.id,
                        species = species.species_label,
                        carcassPropModel = species.carcass_prop_model,
                        health = species.base_health,
                    }
                    live = live + 1
                    liveCountByZone[zone.id] = live
                else
                    break
                end
            end
        end
    end
end

--- @param entityId string
--- @return number|nil
function HuntingSpawnerService.getHealth(entityId)
    local t = tracked[entityId]
    return t and t.health
end

--- @param entityId string
--- @return table|nil { zoneId, species, carcassPropModel }
function HuntingSpawnerService.getTracked(entityId)
    return tracked[entityId]
end

--- @param entityId string
--- @param damage number already clamped by the caller (see HuntingKillService)
--- @return number|nil newHealth, nil if entityId isn't tracked
function HuntingSpawnerService.applyDamage(entityId, damage)
    local t = tracked[entityId]
    if not t then return nil end
    t.health = math.max(0, t.health - damage)
    return t.health
end

--- @param entityId string
function HuntingSpawnerService.despawn(entityId)
    local t = tracked[entityId]
    if not t then return end
    EntityStreamerService.unregister('ped', entityId)
    liveCountByZone[t.zoneId] = math.max(0, (liveCountByZone[t.zoneId] or 1) - 1)
    tracked[entityId] = nil
end

function HuntingSpawnerService.resetForTests()
    tracked = {}
    liveCountByZone = {}
end

return HuntingSpawnerService
```

- [ ] **Step 5: Run to verify it passes**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 6: Commit**

```bash
git -C plugins/oblsk_hunting add server/services/HuntingSpawnerService.lua tests/hunting_spawner_service_spec.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): HuntingSpawnerService weighted roaming spawn + health tracking"
```

### Task 13: HuntingKillService — hit-report validation, death → skin interaction

**Files:**
- Create: `plugins/oblsk_hunting/server/services/HuntingKillService.lua`
- Test: `plugins/oblsk_hunting/tests/hunting_kill_service_spec.lua`

**Interfaces:**
- Consumes: `HuntingSpawnerService.getHealth/applyDamage/getTracked/despawn` (Task 12); `ItemService.binding('hunting.weapon')`, `ItemService.has(source, baseItem, 1)`; `InteractionService.register({...})` (real signature confirmed via `oblsk_fishing/server/main.lua:25-30`).
- Produces: `HuntingKillService.reportHit(source, entityId, weaponHash, damage)` → `boolean handled, string|nil reason` — `handled=false` means the report was rejected outright (unknown entity, no bound weapon, player doesn't hold it); on a kill (health reaches 0) registers a skin interaction and calls `HuntingSpawnerService.despawn(entityId)`. `HuntingKillService._skinInteractionOptions(entityId)` exposed for Task 14 to read back what got registered, `HuntingKillService.resetForTests()`.

- [ ] **Step 1: Write the failing test file**

```lua
-- plugins/oblsk_hunting/tests/hunting_kill_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_hunting/tests/hunting_kill_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(scriptDir .. '../shared/config.lua')

-- HuntingSpawnerService stub: one tracked ped, 'ped_1', 30 health.
local health = 30
local despawnCalls = {}
HuntingSpawnerService = {}
function HuntingSpawnerService.getHealth(entityId)
    if entityId ~= 'ped_1' then return nil end
    return health
end
function HuntingSpawnerService.getTracked(entityId)
    if entityId ~= 'ped_1' then return nil end
    return { zoneId = 1, species = 'Deer', carcassPropModel = 'prop_deer_carc_01' }
end
function HuntingSpawnerService.applyDamage(entityId, damage)
    if entityId ~= 'ped_1' then return nil end
    health = math.max(0, health - damage)
    return health
end
function HuntingSpawnerService.despawn(entityId)
    table.insert(despawnCalls, entityId)
end

-- ItemService stub: source 1 holds the bound weapon item, source 2 does not.
local BOUND_WEAPON = { id = 99, name = 'Hunting Rifle' }
ItemService = {}
function ItemService.binding(key)
    if key == 'hunting.weapon' then return BOUND_WEAPON end
    return nil
end
function ItemService.has(source, baseItem, amount)
    return source == 1 and baseItem.id == BOUND_WEAPON.id
end

-- InteractionService stub: register just records the call and returns an id.
local registeredInteractions = {}
local nextInteractionId = 1
InteractionService = {}
function InteractionService.register(opts)
    local id = nextInteractionId
    nextInteractionId = nextInteractionId + 1
    table.insert(registeredInteractions, { id = id, opts = opts })
    return id
end

dofile(scriptDir .. '../server/services/HuntingKillService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    health = 30
    despawnCalls = {}
    registeredInteractions = {}
    nextInteractionId = 1
    HuntingKillService.resetForTests()
    fn()
end

test('reportHit rejects an unknown entityId', function()
    withFreshState(function()
        local handled, reason = HuntingKillService.reportHit(1, 'ped_unknown', 12345, 20)
        eq(handled, false)
        eq(reason, 'Unknown or already-dead animal')
    end)
end)

test('reportHit rejects a player not holding the bound weapon', function()
    withFreshState(function()
        local handled, reason = HuntingKillService.reportHit(2, 'ped_1', 12345, 20)
        eq(handled, false)
        eq(reason, 'Bound weapon required')
        eq(HuntingSpawnerService.getHealth('ped_1'), 30) -- untouched
    end)
end)

test('reportHit applies clamped damage below max-damage-per-hit', function()
    withFreshState(function()
        local handled = HuntingKillService.reportHit(1, 'ped_1', 12345, 10)
        eq(handled, true)
        eq(HuntingSpawnerService.getHealth('ped_1'), 20)
    end)
end)

test('reportHit clamps a client-reported damage value above MaxDamagePerHit', function()
    withFreshState(function()
        -- HuntingConfig.MaxDamagePerHit = 50 (shared/config.lua)
        local handled = HuntingKillService.reportHit(1, 'ped_1', 12345, 9999)
        eq(handled, true)
        eq(HuntingSpawnerService.getHealth('ped_1'), 0) -- 30 health, clamped 50 dmg -> 0, not negative
    end)
end)

test('reportHit reaching zero health despawns and registers a skin interaction', function()
    withFreshState(function()
        HuntingKillService.reportHit(1, 'ped_1', 12345, 30) -- exact kill
        eq(#despawnCalls, 1)
        eq(despawnCalls[1], 'ped_1')
        eq(#registeredInteractions, 1)
        eq(registeredInteractions[1].opts.action, 'hunting:skin')
        eq(registeredInteractions[1].opts.options.species, 'Deer')
        eq(registeredInteractions[1].opts.options.carcassPropModel, 'prop_deer_carc_01')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_kill_service_spec.lua`
Expected: FAIL — `HuntingKillService` is nil.

- [ ] **Step 3: Implement HuntingKillService.lua**

```lua
-- plugins/oblsk_hunting/server/services/HuntingKillService.lua
--- HuntingKillService - validates raw client hit-reports against
--- server-tracked animal health. The client never claims a kill; it only
--- reports (entityId, weaponHash, damage) at the moment of impact. Health
--- reaching zero server-side is the only kill condition.
HuntingKillService = {}

--- entityId -> registered skin InteractionService id, so a re-report (or
--- future unregister-on-collect flow) can look the interaction back up.
local skinInteractionByEntity = {}

--- @param source number
--- @param entityId string
--- @param weaponHash number unused today (reserved for a future
---   per-species weapon-tier check, see design spec's Non-goals)
--- @param damage number raw client-reported damage, clamped below
--- @return boolean handled
--- @return string|nil reason when handled is false
function HuntingKillService.reportHit(source, entityId, weaponHash, damage)
    local currentHealth = HuntingSpawnerService.getHealth(entityId)
    if currentHealth == nil then
        return false, 'Unknown or already-dead animal'
    end

    local weapon = ItemService.binding('hunting.weapon')
    if not weapon or not ItemService.has(source, weapon, 1) then
        return false, 'Bound weapon required'
    end

    local clampedDamage = math.min(damage, HuntingConfig.MaxDamagePerHit)
    local newHealth = HuntingSpawnerService.applyDamage(entityId, clampedDamage)

    if newHealth <= 0 then
        local tracked = HuntingSpawnerService.getTracked(entityId)
        HuntingSpawnerService.despawn(entityId)

        if tracked then
            local interactionId = InteractionService.register({
                x = tracked.x, y = tracked.y, z = tracked.z,
                range = 2.0, label = 'Skin animal',
                action = 'hunting:skin',
                options = {
                    huntingZoneId = tracked.zoneId,
                    species = tracked.species,
                    carcassPropModel = tracked.carcassPropModel,
                },
            })
            skinInteractionByEntity[entityId] = interactionId
        end
    end

    return true
end

--- @param entityId string
--- @return number|nil the registered skin InteractionService id, if any
function HuntingKillService.getSkinInteractionId(entityId)
    return skinInteractionByEntity[entityId]
end

function HuntingKillService.resetForTests()
    skinInteractionByEntity = {}
end

return HuntingKillService
```

Note: the test's `HuntingSpawnerService.getTracked` stub doesn't return `x`/`y`/`z`, so `tracked.x/y/z` resolve to `nil` in the test — `InteractionService.register` in the real service is called with `x=nil` there, which is fine for this unit test (it only asserts `opts.action`/`opts.options.*`); production's real `HuntingSpawnerService.getTracked` (Task 12) does not currently return `x`/`y`/`z` either — that gap is closed in Task 12's revisit below.

- [ ] **Step 4: Extend HuntingSpawnerService.getTracked to include last-known position**

Go back to `plugins/oblsk_hunting/server/services/HuntingSpawnerService.lua` (Task 12): the `tracked[entityId]` table currently stores `{ zoneId, species, carcassPropModel, health }` — add `x, y, z` (the spawn position computed in `tick()`) so `HuntingKillService.reportHit` can register the skin interaction at the animal's last known position:

In `HuntingSpawnerService.tick()`, change the `tracked[entityId] = {...}` assignment to also store position:

```lua
                    tracked[entityId] = {
                        zoneId = zone.id,
                        species = species.species_label,
                        carcassPropModel = species.carcass_prop_model,
                        health = species.base_health,
                        x = x, y = y, z = zone.z,
                    }
```

Re-run `lua5.4 plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua` to confirm this addition doesn't break Task 12's tests (it's purely additive to the tracked table).

- [ ] **Step 5: Run the kill-service tests to verify they pass**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_kill_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 6: Commit**

```bash
git -C plugins/oblsk_hunting add server/services/HuntingKillService.lua server/services/HuntingSpawnerService.lua tests/hunting_kill_service_spec.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): HuntingKillService hit validation, despawn-on-death, skin interaction"
```

### Task 14: HuntingCarryService — skin completion → attach, carry cap, load onto vehicle

**Files:**
- Create: `plugins/oblsk_hunting/server/services/HuntingCarryService.lua`
- Test: `plugins/oblsk_hunting/tests/hunting_carry_service_spec.lua`

**Interfaces:**
- Consumes: `AttachmentService.attach(parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex, opts)`, `.detach(attachmentId)`, `.getAttachments(parentEntityType, parentNetId)` (real signatures confirmed at `plugins/oblsk_propattach/server/services/AttachmentService.lua:25,51,62`).
- Produces: `HuntingCarryService.canCarryMore(playerNetId)` → `boolean`, `HuntingCarryService.completeSkin(playerNetId, playerModel, species, carcassPropModel)` → `boolean ok, table|string attachmentRow-or-reason`, `HuntingCarryService.loadOntoVehicle(playerNetId, attachmentId, vehicleNetId, vehicleModel)` → `boolean ok, table|string attachmentRow-or-reason`.

- [ ] **Step 1: Write the failing test file**

```lua
-- plugins/oblsk_hunting/tests/hunting_carry_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_hunting/tests/hunting_carry_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(scriptDir .. '../shared/config.lua')

-- AttachmentService stub: in-memory rows, same shape as the real one.
local rows, nextId = {}, 1
AttachmentService = {}
function AttachmentService.attach(parentEntityType, parentNetId, parentModel, propModel, pointName, slotIndex, opts)
    opts = opts or {}
    local row = {
        id = nextId, prop_model = propModel, parent_entity_type = parentEntityType,
        parent_net_id = parentNetId, point_name = pointName, slot_index = slotIndex,
        owner_type = opts.ownerType, data = opts.data,
    }
    nextId = nextId + 1
    table.insert(rows, row)
    return row, nil
end
function AttachmentService.detach(attachmentId)
    for i, row in ipairs(rows) do
        if row.id == attachmentId then table.remove(rows, i); return true end
    end
    return false
end
function AttachmentService.getAttachments(parentEntityType, parentNetId)
    local result = {}
    for _, row in ipairs(rows) do
        if row.parent_entity_type == parentEntityType and row.parent_net_id == parentNetId then
            table.insert(result, row)
        end
    end
    return result
end

dofile(scriptDir .. '../server/services/HuntingCarryService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    rows, nextId = {}, 1
    fn()
end

test('canCarryMore is true below MaxCarried', function()
    withFreshState(function()
        eq(HuntingCarryService.canCarryMore(1), true) -- HuntingConfig.MaxCarried = 1, 0 carried
    end)
end)

test('completeSkin attaches the carcass to the player', function()
    withFreshState(function()
        local ok, row = HuntingCarryService.completeSkin(1, 'mp_m_freemode_01', 'Deer', 'prop_deer_carc_01')
        eq(ok, true)
        eq(row.parent_entity_type, 'ped')
        eq(row.parent_net_id, 1)
        eq(row.point_name, 'carry_point')
        eq(row.owner_type, 'plugin:oblsk_hunting')
        eq(row.data.species, 'Deer')
    end)
end)

test('completeSkin refuses at carry capacity', function()
    withFreshState(function()
        HuntingCarryService.completeSkin(1, 'mp_m_freemode_01', 'Deer', 'prop_deer_carc_01')
        local ok, reason = HuntingCarryService.completeSkin(1, 'mp_m_freemode_01', 'Deer', 'prop_deer_carc_01')
        eq(ok, false)
        eq(reason, 'You can\'t carry any more')
    end)
end)

test('canCarryMore is false at capacity', function()
    withFreshState(function()
        HuntingCarryService.completeSkin(1, 'mp_m_freemode_01', 'Deer', 'prop_deer_carc_01')
        eq(HuntingCarryService.canCarryMore(1), false)
    end)
end)

test('loadOntoVehicle detaches from the player and reattaches to the vehicle', function()
    withFreshState(function()
        local _, carried = HuntingCarryService.completeSkin(1, 'mp_m_freemode_01', 'Deer', 'prop_deer_carc_01')
        local ok, loaded = HuntingCarryService.loadOntoVehicle(1, carried.id, 50, 'pounder')
        eq(ok, true)
        eq(loaded.parent_entity_type, 'vehicle')
        eq(loaded.parent_net_id, 50)
        eq(loaded.point_name, 'trunk_slot')
        eq(#AttachmentService.getAttachments('ped', 1), 0) -- detached from player
        eq(#AttachmentService.getAttachments('vehicle', 50), 1)
    end)
end)

test('loadOntoVehicle refuses at Config.MaxPerVehicle', function()
    withFreshState(function()
        -- fill the vehicle to MaxPerVehicle (4) directly via the stub
        for i = 1, 4 do
            AttachmentService.attach('vehicle', 50, 'pounder', 'prop_deer_carc_01', 'trunk_slot', i - 1, { ownerType = 'plugin:oblsk_hunting' })
        end
        local _, carried = HuntingCarryService.completeSkin(1, 'mp_m_freemode_01', 'Deer', 'prop_deer_carc_01')
        local ok, reason = HuntingCarryService.loadOntoVehicle(1, carried.id, 50, 'pounder')
        eq(ok, false)
        eq(reason, 'Vehicle is full')
        eq(#AttachmentService.getAttachments('ped', 1), 1) -- left on the player, not detached
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_carry_service_spec.lua`
Expected: FAIL — `HuntingCarryService` is nil.

- [ ] **Step 3: Implement HuntingCarryService.lua**

```lua
-- plugins/oblsk_hunting/server/services/HuntingCarryService.lua
--- HuntingCarryService - carcasses are attachment-only (never an
--- ItemService item). Skinning attaches to the player at a pre-placed
--- 'carry_point' attach point; loading onto a vehicle detaches from the
--- player and reattaches to the vehicle's 'trunk_slot'. Capacity is a flat
--- config constant, not per-character/per-vehicle-model (v1, see design
--- spec's Non-goals).
local OWNER_TYPE = 'plugin:oblsk_hunting'

HuntingCarryService = {}

local function huntingAttachments(parentEntityType, parentNetId)
    local all = AttachmentService.getAttachments(parentEntityType, parentNetId)
    local mine = {}
    for _, row in ipairs(all) do
        if row.owner_type == OWNER_TYPE then table.insert(mine, row) end
    end
    return mine
end

--- @param playerNetId number
--- @return boolean
function HuntingCarryService.canCarryMore(playerNetId)
    return #huntingAttachments('ped', playerNetId) < HuntingConfig.MaxCarried
end

--- @param playerNetId number
--- @param playerModel string
--- @param species string
--- @param carcassPropModel string
--- @return boolean ok
--- @return table|string attachmentRow on success, reason on failure
function HuntingCarryService.completeSkin(playerNetId, playerModel, species, carcassPropModel)
    if not HuntingCarryService.canCarryMore(playerNetId) then
        return false, 'You can\'t carry any more'
    end

    local row, err = AttachmentService.attach(
        'ped', playerNetId, playerModel, carcassPropModel, 'carry_point', 0,
        { ownerType = OWNER_TYPE, data = { species = species } }
    )
    if not row then
        return false, err or 'Could not attach carcass'
    end
    return true, row
end

--- @param playerNetId number
--- @param attachmentId number the carried carcass's attachment id
--- @param vehicleNetId number
--- @param vehicleModel string
--- @return boolean ok
--- @return table|string attachmentRow on success, reason on failure
function HuntingCarryService.loadOntoVehicle(playerNetId, attachmentId, vehicleNetId, vehicleModel)
    local existing = huntingAttachments('vehicle', vehicleNetId)
    if #existing >= HuntingConfig.MaxPerVehicle then
        return false, 'Vehicle is full'
    end

    local carried
    for _, row in ipairs(huntingAttachments('ped', playerNetId)) do
        if row.id == attachmentId then carried = row break end
    end
    if not carried then
        return false, 'Not carrying that carcass'
    end

    AttachmentService.detach(attachmentId)

    local nextSlot = #existing
    local row, err = AttachmentService.attach(
        'vehicle', vehicleNetId, vehicleModel, carried.prop_model, 'trunk_slot', nextSlot,
        { ownerType = OWNER_TYPE, data = carried.data }
    )
    if not row then
        return false, err or 'Could not load carcass onto vehicle'
    end
    return true, row
end

return HuntingCarryService
```

- [ ] **Step 4: Run to verify it passes**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_carry_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_hunting add server/services/HuntingCarryService.lua tests/hunting_carry_service_spec.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): HuntingCarryService skin-to-attach, carry cap, load onto vehicle"
```

### Task 15: HuntingButcherService — hand-over: detach + tally + CraftingService.start

**Files:**
- Create: `plugins/oblsk_hunting/server/services/HuntingButcherService.lua`
- Test: `plugins/oblsk_hunting/tests/hunting_butcher_service_spec.lua`

**Interfaces:**
- Consumes: `AttachmentService.getAttachments('vehicle', vehicleNetId)`, `.detach(attachmentId)`; `CraftingService.start(source, craftingPointId, recipeId, batch)` (Task 3's queue-aware version — from the butcher's perspective this is just an ordinary call, queueing is transparent); a recipe lookup keyed by species — expose via a `speciesRecipeId` lookup table passed in by the caller (`server/main.lua`, Task 17), since `HuntingButcherService` has no admin UI of its own for recipe-to-species mapping (the spec's design: butcher recipes are named `"Process <Species> Carcass"`, matched by exact species-label-in-recipe-name convention read from `oblsk_crafting`'s existing recipe rows).
- Produces: `HuntingButcherService.handOver(source, craftingPointId, vehicleNetId)` → `table { started: {species,batch}[], skipped: string[] }`.

- [ ] **Step 1: Write the failing test file**

```lua
-- plugins/oblsk_hunting/tests/hunting_butcher_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_hunting/tests/hunting_butcher_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- AttachmentService stub: vehicle 50 carries 2 Deer + 1 Boar (all
-- owner_type = 'plugin:oblsk_hunting').
local rows = {}
local detachCalls = {}
AttachmentService = {}
function AttachmentService.getAttachments(parentEntityType, parentNetId)
    local result = {}
    for _, row in ipairs(rows) do
        if row.parent_entity_type == parentEntityType and row.parent_net_id == parentNetId then
            table.insert(result, row)
        end
    end
    return result
end
function AttachmentService.detach(attachmentId)
    table.insert(detachCalls, attachmentId)
    for i, row in ipairs(rows) do
        if row.id == attachmentId then table.remove(rows, i) end
    end
    return true
end

-- CraftingService stub: records every start() call, always succeeds.
local startCalls = {}
CraftingService = {}
function CraftingService.start(source, craftingPointId, recipeId, batch)
    table.insert(startCalls, { source = source, craftingPointId = craftingPointId, recipeId = recipeId, batch = batch })
    return true, { id = #startCalls }
end

dofile(scriptDir .. '../server/services/HuntingButcherService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        crafting_recipes = {
            { id = 10, crafting_point_id = 1, name = 'Process Deer Carcass' },
        },
    })
    QueryBuilder = fake
    rows = {
        { id = 1, parent_entity_type = 'vehicle', parent_net_id = 50, owner_type = 'plugin:oblsk_hunting', prop_model = 'prop_deer_carc_01', data = { species = 'Deer' } },
        { id = 2, parent_entity_type = 'vehicle', parent_net_id = 50, owner_type = 'plugin:oblsk_hunting', prop_model = 'prop_deer_carc_01', data = { species = 'Deer' } },
        { id = 3, parent_entity_type = 'vehicle', parent_net_id = 50, owner_type = 'plugin:oblsk_hunting', prop_model = 'prop_boar_carc_01', data = { species = 'Boar' } },
    }
    detachCalls, startCalls = {}, {}
    fn()
end

test('handOver tallies by species and starts one job per matched species', function()
    withFreshState(function()
        local result = HuntingButcherService.handOver(1, 1, 50)
        eq(#startCalls, 1) -- only Deer has a matching recipe
        eq(startCalls[1].craftingPointId, 1)
        eq(startCalls[1].recipeId, 10)
        eq(startCalls[1].batch, 2) -- 2 Deer carcasses
        eq(#result.started, 1)
        eq(result.started[1].species, 'Deer')
        eq(result.started[1].batch, 2)
    end)
end)

test('handOver detaches every tallied carcass with a matching recipe', function()
    withFreshState(function()
        HuntingButcherService.handOver(1, 1, 50)
        eq(#detachCalls, 2) -- both Deer attachments detached
    end)
end)

test('handOver leaves unmatched-species carcasses attached and reports them skipped', function()
    withFreshState(function()
        local result = HuntingButcherService.handOver(1, 1, 50)
        eq(#result.skipped, 1)
        eq(result.skipped[1], 'Boar')
        eq(#AttachmentService.getAttachments('vehicle', 50), 1) -- Boar still attached
        eq(AttachmentService.getAttachments('vehicle', 50)[1].data.species, 'Boar')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_butcher_service_spec.lua`
Expected: FAIL — `HuntingButcherService` is nil.

- [ ] **Step 3: Implement HuntingButcherService.lua**

```lua
-- plugins/oblsk_hunting/server/services/HuntingButcherService.lua
--- HuntingButcherService - hand-over: reads every oblsk_hunting-owned
--- carcass attachment on a vehicle, tallies by species, detaches each one,
--- and starts one CraftingService job per species that has a matching
--- recipe at the given butcher point. A butcher recipe is matched to a
--- species by the exact convention "Process <Species> Carcass" in the
--- recipe's name column - avoids a bespoke species<->recipe mapping table,
--- reusing oblsk_crafting's existing recipe rows directly (see design
--- spec's "butcher is an ordinary crafting point" decision).
local OWNER_TYPE = 'plugin:oblsk_hunting'

HuntingButcherService = {}

--- @param craftingPointId number
--- @param species string
--- @return table|nil crafting_recipes row
local function findRecipeForSpecies(craftingPointId, species)
    local expectedName = 'Process ' .. species .. ' Carcass'
    return QueryBuilder.new('crafting_recipes')
        :where('crafting_point_id', craftingPointId)
        :where('name', expectedName)
        :firstSync()
end

--- @param source number
--- @param craftingPointId number
--- @param vehicleNetId number
--- @return table { started: {species, batch}[], skipped: string[] }
function HuntingButcherService.handOver(source, craftingPointId, vehicleNetId)
    local attachments = AttachmentService.getAttachments('vehicle', vehicleNetId)

    local tallyBySpecies = {}
    local rowsBySpecies = {}
    for _, row in ipairs(attachments) do
        if row.owner_type == OWNER_TYPE then
            local species = row.data and row.data.species
            if species then
                tallyBySpecies[species] = (tallyBySpecies[species] or 0) + 1
                rowsBySpecies[species] = rowsBySpecies[species] or {}
                table.insert(rowsBySpecies[species], row.id)
            end
        end
    end

    local result = { started = {}, skipped = {} }
    for species, batch in pairs(tallyBySpecies) do
        local recipe = findRecipeForSpecies(craftingPointId, species)
        if recipe then
            for _, attachmentId in ipairs(rowsBySpecies[species]) do
                AttachmentService.detach(attachmentId)
            end
            CraftingService.start(source, craftingPointId, recipe.id, batch)
            table.insert(result.started, { species = species, batch = batch })
        else
            table.insert(result.skipped, species)
        end
    end

    return result
end

return HuntingButcherService
```

- [ ] **Step 4: Run to verify it passes**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_butcher_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_hunting add server/services/HuntingButcherService.lua tests/hunting_butcher_service_spec.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): HuntingButcherService species tally, detach, CraftingService hand-off"
```

Note for Task 18 (admin UI): the butcher recipe-naming convention (`"Process <Species> Carcass"`) must be documented on `HuntingTab.vue`'s recipe-creation helper so an admin creating a butcher recipe through the crafting admin UI names it correctly — a recipe named anything else silently shows up in `result.skipped` instead of processing.

### Task 16: HuntingSellService — sell-point CRUD + sell transaction

**Files:**
- Create: `plugins/oblsk_hunting/server/services/HuntingSellService.lua`
- Test: `plugins/oblsk_hunting/tests/hunting_sell_service_spec.lua`

**Interfaces:**
- Consumes: `ItemService.binding('currency.cash')`, `ItemService.has(source, baseItem, amount)`, `ItemService.remove(source, baseItem, amount)`, `ItemService.add(source, baseItem, amount)` (real signature confirmed at `core/modules/oblsk_items/server/services/ItemService.lua:109`).
- Produces: `HuntingSellService.listSellPoints()`, `.createSellPoint(attrs)`, `.deleteSellPoint(id)`, `.listSellableItems(sellPointId)`, `.addSellableItem(sellPointId, baseItemId, cashPerUnit)`, `.removeSellableItem(id)`, `.sell(source, sellPointId, baseItemId, amount)` → `boolean ok, string|nil reason`.

- [ ] **Step 1: Write the failing test file**

```lua
-- plugins/oblsk_hunting/tests/hunting_sell_service_spec.lua
-- Run from the repository root:  lua5.4 plugins/oblsk_hunting/tests/hunting_sell_service_spec.lua
local scriptDir = arg[0]:match('(.*/)') or './'
local ROOT = scriptDir .. '../../..'

dofile(ROOT .. '/tests/support/fivem_stubs.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Init.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/MySQL.lua')
dofile(ROOT .. '/core/server/ORM/Dialects/Postgres.lua')
dofile(ROOT .. '/core/server/ORM/Database.lua')
dofile(ROOT .. '/core/server/ORM/QueryBuilder.lua')

local makeFakeQueryBuilderModule = dofile(ROOT .. '/tests/support/fake_query_builder.lua')

dofile(scriptDir .. '../shared/config.lua')

-- ItemService stub: source 1 owns 5 units of base_item_id 1 (Meat), cash is
-- base_item_id 2. has/remove/add operate against the fake `items` table.
local CASH_ITEM = { id = 2, name = 'Cash' }
ItemService = {}
function ItemService.binding(key)
    if key == 'currency.cash' then return CASH_ITEM end
    return nil
end
function ItemService.has(source, baseItem, amount)
    local rows = QueryBuilder.new('items'):where('owner_id', source):where('base_item_id', baseItem.id):getSync()
    local total = 0
    for _, row in ipairs(rows) do total = total + row.amount end
    return total >= amount
end
function ItemService.remove(source, baseItem, amount)
    if not ItemService.has(source, baseItem, amount) then return false, 'Not enough items' end
    local rows = QueryBuilder.new('items'):where('owner_id', source):where('base_item_id', baseItem.id):getSync()
    local remaining = amount
    for _, row in ipairs(rows) do
        if remaining <= 0 then break end
        local take = math.min(remaining, row.amount)
        remaining = remaining - take
        QueryBuilder.new('items'):where('id', row.id):update({ amount = row.amount - take })
    end
    return true
end
function ItemService.add(source, baseItem, amount)
    local existing = QueryBuilder.new('items'):where('owner_id', source):where('base_item_id', baseItem.id):firstSync()
    if existing then
        QueryBuilder.new('items'):where('id', existing.id):update({ amount = existing.amount + amount })
    else
        QueryBuilder.new('items'):insert({ owner_id = source, base_item_id = baseItem.id, amount = amount })
    end
    return true
end

dofile(scriptDir .. '../server/services/HuntingSellService.lua')

local tests, failures, passed = {}, {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or 'assertion failed') .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual), 2)
    end
end

local SELL_POINT_ID, MEAT_ID = 1, 1

local function withFreshState(fn)
    local fake = makeFakeQueryBuilderModule({
        hunting_sell_points = { { id = 1, label = 'Butcher Stand', x = 0, y = 0, z = 0, range = 2.0, enabled = 1 } },
        hunting_sell_point_items = { { id = 1, sell_point_id = 1, base_item_id = 1, cash_per_unit = 15 } },
        items = { { id = 1, owner_id = 1, base_item_id = 1, amount = 5 } },
    })
    QueryBuilder = fake
    SELL_POINT_ID, MEAT_ID = 1, 1
    fn()
end

test('listSellableItems returns configured items for a sell point', function()
    withFreshState(function()
        local items = HuntingSellService.listSellableItems(SELL_POINT_ID)
        eq(#items, 1)
        eq(items[1].base_item_id, MEAT_ID)
        eq(items[1].cash_per_unit, 15)
    end)
end)

test('sell removes the item and grants the correct cash total', function()
    withFreshState(function()
        local ok = HuntingSellService.sell(1, SELL_POINT_ID, MEAT_ID, 3)
        eq(ok, true)
        eq(ItemService.has(1, { id = MEAT_ID }, 2), true) -- 5 - 3 = 2 left
        eq(ItemService.has(1, CASH_ITEM, 45), true) -- 3 * 15
    end)
end)

test('sell rejects selling more than owned', function()
    withFreshState(function()
        local ok, reason = HuntingSellService.sell(1, SELL_POINT_ID, MEAT_ID, 10)
        eq(ok, false)
        eq(reason, 'Not enough items')
    end)
end)

test('sell rejects an item not configured as sellable at this point', function()
    withFreshState(function()
        local ok, reason = HuntingSellService.sell(1, SELL_POINT_ID, 999, 1)
        eq(ok, false)
        eq(reason, 'Not sellable here')
    end)
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        print('  PASS  ' .. t.name)
    else
        table.insert(failures, { name = t.name, err = err })
        print('  FAIL  ' .. t.name .. '\n        ' .. tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, #failures))
os.exit(#failures > 0 and 1 or 0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_sell_service_spec.lua`
Expected: FAIL — `HuntingSellService` is nil.

- [ ] **Step 3: Implement HuntingSellService.lua**

```lua
-- plugins/oblsk_hunting/server/services/HuntingSellService.lua
--- HuntingSellService - sell-point CRUD plus the sell transaction itself.
--- Server resolves ownership and price; client never computes either,
--- mirroring CraftingService.ownedCounts' posture.
HuntingSellService = {}

--- @return table[]
function HuntingSellService.listSellPoints()
    return QueryBuilder.new('hunting_sell_points'):getSync()
end

--- @param attrs table label, x, y, z, range (default 2.0), enabled (default true)
--- @return number id
function HuntingSellService.createSellPoint(attrs)
    return QueryBuilder.new('hunting_sell_points'):insert({
        label = attrs.label,
        x = attrs.x,
        y = attrs.y,
        z = attrs.z,
        range = attrs.range or 2.0,
        enabled = attrs.enabled == nil and 1 or attrs.enabled,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @return boolean
function HuntingSellService.deleteSellPoint(id)
    QueryBuilder.new('hunting_sell_points'):where('id', id):delete()
    return true
end

--- @param sellPointId number
--- @return table[]
function HuntingSellService.listSellableItems(sellPointId)
    return QueryBuilder.new('hunting_sell_point_items'):where('sell_point_id', sellPointId):getSync()
end

--- @param sellPointId number
--- @param baseItemId number
--- @param cashPerUnit number
--- @return number id
function HuntingSellService.addSellableItem(sellPointId, baseItemId, cashPerUnit)
    return QueryBuilder.new('hunting_sell_point_items'):insert({
        sell_point_id = sellPointId,
        base_item_id = baseItemId,
        cash_per_unit = cashPerUnit,
        created_at = Database.now(),
        updated_at = Database.now(),
    })
end

--- @param id number
--- @return boolean
function HuntingSellService.removeSellableItem(id)
    QueryBuilder.new('hunting_sell_point_items'):where('id', id):delete()
    return true
end

--- @param source number
--- @param sellPointId number
--- @param baseItemId number
--- @param amount number
--- @return boolean ok
--- @return string|nil reason on failure
function HuntingSellService.sell(source, sellPointId, baseItemId, amount)
    local sellable = QueryBuilder.new('hunting_sell_point_items')
        :where('sell_point_id', sellPointId)
        :where('base_item_id', baseItemId)
        :firstSync()
    if not sellable then
        return false, 'Not sellable here'
    end

    local baseItem = { id = baseItemId }
    if not ItemService.has(source, baseItem, amount) then
        return false, 'Not enough items'
    end

    local cash = ItemService.binding('currency.cash')
    if not cash then
        return false, 'Cash sales are not available on this server'
    end

    local removed, reason = ItemService.remove(source, baseItem, amount)
    if not removed then
        return false, reason
    end

    ItemService.add(source, cash, amount * sellable.cash_per_unit)
    return true
end

return HuntingSellService
```

- [ ] **Step 4: Run to verify it passes**

Run: `lua5.4 plugins/oblsk_hunting/tests/hunting_sell_service_spec.lua`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git -C plugins/oblsk_hunting add server/services/HuntingSellService.lua tests/hunting_sell_service_spec.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): HuntingSellService sell-point CRUD + sell transaction"
```

### Task 17: server/main.lua — boot wiring, spawner tick loop, admin/action net events

**Files:**
- Create: `plugins/oblsk_hunting/server/main.lua`
- Create: `plugins/oblsk_hunting/client/main.lua`

**Interfaces:**
- Consumes: every service from Tasks 11-16, plus `ActionService.register`, `InteractionService.register/unregister`, `Obelisk.onClient`/`Obelisk.emitClient`, `WebView.openPage`/`.focus`, `CharacterService.getActiveCharacterId` (for `NetworkGetNetworkIdFromEntity`-style player/vehicle net-id resolution — client supplies its own net id the same way `oblsk_propattach`'s placement tool does; server never trusts a client-claimed species/entity beyond what `HuntingKillService`/`HuntingCarryService`/`HuntingButcherService` independently validate).
- Produces: boot sequence registering zones' spawner tick and sell points' interactions (`HuntingConfig.Requires.bindings` picked up automatically by `core/server/bootstrap.lua`'s existing per-plugin `ItemService.registerRequirements` call — same as `oblsk_fishing`, no explicit call needed in this plugin's own `main.lua`).

This task is direct wiring (no new business logic to unit-test — every function it calls is already covered by Tasks 11-16's specs), so it is not itself TDD-cyclce, but every event handler must call through to an already-tested service function, never re-implement logic inline.

- [ ] **Step 1: Write server/main.lua**

```lua
-- plugins/oblsk_hunting/server/main.lua
print('[Hunting] Loading...')

local TICK_SECONDS = 5 -- spawner tick cadence; slower than crafting's 1s advance() since spawn/despawn is comparatively rare

local function isAdmin(player)
    local source = player:getSource()
    return source == 0 or IsPlayerAceAllowed(source, 'admin')
end

--------------------------------------------------------------------------------
-- Sell point registration
--------------------------------------------------------------------------------

local sellPointInteractionIds = {}

local function registerAllSellPoints()
    for _, point in ipairs(HuntingSellService.listSellPoints()) do
        if point.enabled ~= 0 and point.enabled ~= false then
            local interactionId = InteractionService.register({
                x = point.x, y = point.y, z = point.z,
                range = point.range, label = point.label or 'Sell to butcher',
                action = 'hunting:sell',
                options = { sellPointId = point.id },
            })
            sellPointInteractionIds[point.id] = interactionId
        end
    end
end

ActionService.register('hunting:sell', function(player, data)
    local sellPointId = data and data.interaction and data.interaction.options and data.interaction.options.sellPointId
    if not sellPointId then return end
    local source = player:getSource()

    local items = HuntingSellService.listSellableItems(sellPointId)
    WebView.openPage(player, '/Hunting/Sell')
    WebView.focus(player)
    Obelisk.emitClient('hunting:server:sellSync', player, { sellPointId = sellPointId, items = items })
end, { label = 'Sell to butcher' })

Obelisk.onClient('hunting:client:sell', function(player, sellPointId, baseItemId, amount)
    local source = player:getSource()
    local ok, reason = HuntingSellService.sell(source, sellPointId, baseItemId, amount)
    Obelisk.emitClient('hunting:server:sellResult', player, { ok = ok, reason = reason })
end)

--------------------------------------------------------------------------------
-- Kill / skin / carry
--------------------------------------------------------------------------------

Obelisk.onClient('hunting:client:reportHit', function(player, entityId, weaponHash, damage)
    local source = player:getSource()
    HuntingKillService.reportHit(source, entityId, weaponHash, damage)
end)

ActionService.register('hunting:skin', function(player, data)
    local options = data and data.interaction and data.interaction.options
    if not options then return end
    Obelisk.emitClient('hunting:server:startSkin', player, options)
end, { label = 'Skin animal' })

Obelisk.onClient('hunting:client:skinComplete', function(player, playerNetId, playerModel, species, carcassPropModel)
    local ok, result = HuntingCarryService.completeSkin(playerNetId, playerModel, species, carcassPropModel)
    if not ok then
        NotificationService.error(player, 'Hunting', result)
        return
    end
    Obelisk.emitClient('hunting:server:skinResult', player, { ok = true, attachment = result })
end)

Obelisk.onClient('hunting:client:loadOntoVehicle', function(player, playerNetId, attachmentId, vehicleNetId, vehicleModel)
    local ok, result = HuntingCarryService.loadOntoVehicle(playerNetId, attachmentId, vehicleNetId, vehicleModel)
    if not ok then
        NotificationService.error(player, 'Hunting', result)
        return
    end
    Obelisk.emitClient('hunting:server:loadResult', player, { ok = true, attachment = result })
end)

--------------------------------------------------------------------------------
-- Butcher hand-over
--------------------------------------------------------------------------------

Obelisk.onClient('hunting:client:handOver', function(player, craftingPointId, vehicleNetId)
    local source = player:getSource()
    local result = HuntingButcherService.handOver(source, craftingPointId, vehicleNetId)
    Obelisk.emitClient('hunting:server:handOverResult', player, result)
end)

--------------------------------------------------------------------------------
-- Admin CRUD net events (used by HuntingTab.vue, imported into oblsk_admin's
-- AdminPanel.vue — same posture as oblsk_fishing's admin handlers)
--------------------------------------------------------------------------------

local function replyAdminState(player)
    local zones = HuntingZoneService.listZones()
    for _, zone in ipairs(zones) do
        zone.species = HuntingZoneService.listSpecies(zone.id)
    end
    local sellPoints = HuntingSellService.listSellPoints()
    for _, point in ipairs(sellPoints) do
        point.items = HuntingSellService.listSellableItems(point.id)
    end
    player:emit('hunting:server:admin-state', { zones = zones, sellPoints = sellPoints, items = ItemService.listBaseItems() })
end

Obelisk.onClient('hunting:server:admin-list', function(player)
    if not isAdmin(player) then return end
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-capture-position', function(player)
    if not isAdmin(player) then return end
    Obelisk.emitClient('hunting:server:capture-position', player, {})
end)

Obelisk.onClient('hunting:server:admin-create-zone', function(player, data)
    if not isAdmin(player) then return end
    HuntingZoneService.createZone(data)
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-delete-zone', function(player, data)
    if not isAdmin(player) then return end
    HuntingZoneService.deleteZone(data.id)
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-create-species', function(player, data)
    if not isAdmin(player) then return end
    HuntingZoneService.createSpecies(data.zoneId, data.attrs or {})
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-delete-species', function(player, data)
    if not isAdmin(player) then return end
    HuntingZoneService.deleteSpecies(data.id)
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-create-sell-point', function(player, data)
    if not isAdmin(player) then return end
    local id = HuntingSellService.createSellPoint(data)
    if id and (data.enabled == nil or (data.enabled ~= 0 and data.enabled ~= false)) then
        local interactionId = InteractionService.register({
            x = data.x, y = data.y, z = data.z,
            range = data.range or 2.0, label = data.label or 'Sell to butcher',
            action = 'hunting:sell',
            options = { sellPointId = id },
        })
        sellPointInteractionIds[id] = interactionId
    end
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-delete-sell-point', function(player, data)
    if not isAdmin(player) then return end
    local interactionId = sellPointInteractionIds[data.id]
    if interactionId then
        InteractionService.unregister(interactionId)
        sellPointInteractionIds[data.id] = nil
    end
    HuntingSellService.deleteSellPoint(data.id)
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-add-sellable-item', function(player, data)
    if not isAdmin(player) then return end
    HuntingSellService.addSellableItem(data.sellPointId, data.baseItemId, data.cashPerUnit)
    replyAdminState(player)
end)

Obelisk.onClient('hunting:server:admin-remove-sellable-item', function(player, data)
    if not isAdmin(player) then return end
    HuntingSellService.removeSellableItem(data.id)
    replyAdminState(player)
end)

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

Citizen.CreateThread(function()
    while not Database.isReady() do Citizen.Wait(200) end
    registerAllSellPoints()
    print('[Hunting] Loaded successfully!')

    while true do
        Citizen.Wait(TICK_SECONDS * 1000)
        HuntingSpawnerService.tick()
    end
end)
```

- [ ] **Step 2: Write client/main.lua**

```lua
-- plugins/oblsk_hunting/client/main.lua
--- Client-side: reports raw hit events only, drives the timed skin action's
--- progress bar (via oblsk_progressbar, same pattern as every other timed
--- action in this codebase), and relays player/vehicle net ids the server
--- needs for attach/detach calls. Never claims a kill or a completed skin -
--- every one of those is a server decision (see HuntingKillService /
--- HuntingCarryService).

AddEventHandler('CEventNetworkEntityDamage', function(victim, attacker, victimNetId, damage, weaponHash)
    if not IsEntityAPed(victim) then return end
    if GetPedType(victim) == 4 then return end -- player ped, not a hunting spawn
    local entityId = 'ped_' .. victimNetId
    TriggerServerEvent('hunting:client:reportHit', entityId, weaponHash, damage)
end)

Obelisk.onServer('hunting:server:startSkin', function(options)
    local playerPed = PlayerPedId()
    ProgressBarService.start(HuntingConfig.SkinSeconds, 'Skinning...', function(completed)
        if not completed then return end
        local playerNetId = NetworkGetNetworkIdFromEntity(playerPed)
        local playerModel = GetEntityModel(playerPed)
        TriggerServerEvent('hunting:client:skinComplete', playerNetId, playerModel, options.species, options.carcassPropModel)
    end)
end)
```

- [ ] **Step 3: Run the full hunting test suite**

Run:
```bash
lua5.4 plugins/oblsk_hunting/tests/hunting_zone_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_kill_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_carry_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_butcher_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_sell_service_spec.lua
```
Expected: PASS on all six (main.lua/client's own logic is wiring only, already exercised transitively by every service's own suite; no new spec file is added for it).

- [ ] **Step 4: Commit**

```bash
git -C plugins/oblsk_hunting add server/main.lua client/main.lua
git -C plugins/oblsk_hunting commit -m "feat(hunting): server/client main.lua wiring — boot, spawner loop, action/admin net events"
```

### Task 18: HuntingTab.vue admin UI + routes.js

**Files:**
- Create: `plugins/oblsk_hunting/web/HuntingTab.vue`
- Create: `plugins/oblsk_hunting/web/routes.js`
- Modify: `plugins/oblsk_admin/web/AdminPanel.vue` (or wherever `FishingTab.vue` is imported — follow that exact import site)

**Interfaces:**
- Consumes: `hunting:server:admin-state` / `hunting:server:admin-create-zone` / etc. (Task 17); links out to `oblsk_crafting`'s existing point/recipe CRUD for the butcher (no new crafting-admin UI needed per spec).

- [ ] **Step 1: Find FishingTab.vue's admin-panel import site**

```bash
grep -rn "FishingTab" plugins/oblsk_admin/web/*.vue
```

Use that exact import + tab-registration pattern for `HuntingTab.vue` (mirrors how `oblsk_fishing`'s admin tab gets pulled into `oblsk_admin`, per the plugin-loading architecture's shared-Lua-state / imported-Vue-component convention).

- [ ] **Step 2: Write web/routes.js**

```js
// plugins/oblsk_hunting/web/routes.js
export default [
  { path: '/Hunting/Sell', component: () => import('./HuntingSell.vue') },
]
```

- [ ] **Step 3: Write web/HuntingTab.vue**

Follow `FishingTab.vue`'s structure exactly (zone/species list+create+delete forms mirroring spot/rod-pool/pool-entry forms; sell-point/sellable-item list+create+delete forms mirroring the same shape a second time), wired to the `hunting:server:admin-*` events from Task 17. Sections:
1. Zones: list with label/x/y/z/radius/max_concurrent/enabled, a "Capture position" button (emits `hunting:server:admin-capture-position`, listens for `hunting:server:capture-position` to fill x/y/z), create/delete.
2. Species per zone: species_label/carcass_prop_model/weight/base_health, create/delete.
3. Sell points: label/x/y/z/range/enabled, create/delete, capture-position reused.
4. Sellable items per sell point: base_item_id (dropdown from `items`)/cash_per_unit, create/delete.
5. A static help note: "Butcher points are ordinary Crafting points — create them in the Crafting admin tab. Name each recipe exactly `Process <Species> Carcass` (e.g. `Process Deer Carcass`) so hand-over matches it to the species." (documents the Task 15 naming convention for the admin operator.)

- [ ] **Step 4: Write web/HuntingSell.vue**

A minimal NUI page (opened via `WebView.openPage(player, '/Hunting/Sell')` in Task 17's `hunting:server:sell` handler): lists `hunting:server:sellSync`'s `items` (base item name, owned amount if resolvable, `cash_per_unit`), a quantity input and Sell button per row emitting `hunting:client:sell`, listens for `hunting:server:sellResult` to show success/failure.

- [ ] **Step 5: Wire HuntingTab.vue into oblsk_admin's AdminPanel.vue**

Add the import + tab entry alongside the existing `FishingTab` one found in Step 1.

- [ ] **Step 6: Manually verify in a running FiveM/dev session**

Open the admin panel's Hunting tab, create a zone with one species, confirm an animal spawns within the zone after the spawner tick; create a sell point with a sellable item; walk through kill → skin → carry → (optionally load onto a vehicle) → hand over at a butcher point named per the Task 15 convention → collect from `oblsk_crafting`'s UI → sell at the sell point.

- [ ] **Step 7: Commit**

```bash
git -C plugins/oblsk_hunting add web/HuntingTab.vue web/HuntingSell.vue web/routes.js
git -C plugins/oblsk_hunting commit -m "feat(hunting): admin tab (zones/species/sell points) + sell NUI page"
git -C plugins/oblsk_admin add web/AdminPanel.vue
git -C plugins/oblsk_admin commit -m "feat(admin): register Hunting tab"
```

### Task 19: Content prerequisite check + full integration pass

**Files:**
- No code changes — verification-only task.

**Interfaces:** none new.

`oblsk_propattach` needs a `carry_point` attach point defined (via its existing in-game placement tool) on every player ped model in use (`mp_m_freemode_01`, `mp_f_freemode_01`), and a `trunk_slot` attach point on every vehicle model an admin wants carcasses loadable into. This is admin/content work, not code — confirm it's been done before calling the feature complete.

- [ ] **Step 1: Run every crafting + hunting test file and confirm all pass**

```bash
lua5.4 plugins/oblsk_crafting/tests/crafting_service_spec.lua
lua5.4 plugins/oblsk_crafting/tests/crafting_seeder_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_zone_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_spawner_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_kill_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_carry_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_butcher_service_spec.lua
lua5.4 plugins/oblsk_hunting/tests/hunting_sell_service_spec.lua
```
Expected: PASS on all eight.

- [ ] **Step 2: Confirm the propattach content prerequisite via the admin's placement tool**

Using `oblsk_propattach`'s existing placement UI (no code change), place a `carry_point` on `mp_m_freemode_01`/`mp_f_freemode_01` and a `trunk_slot` on at least one vehicle model intended for carcass transport. Without this, `HuntingCarryService.completeSkin`/`.loadOntoVehicle` will fail every call with `AttachmentService.attach`'s `'unknown attach point'` error — this is expected, not a bug, until the content step is done.

- [ ] **Step 3: End-to-end manual walkthrough in a running FiveM/dev session**

Create a zone+species+bound `hunting.weapon` item via the admin tabs (Hunting + Items), wait for a spawn, kill it, skin it, carry it (optionally load onto a vehicle and drive to the butcher), hand over at a `"Process <Species> Carcass"`-named crafting point, wait for it to go ready, collect via `Crafting.vue`, sell the collected item at a hunting sell point. Confirm cash balance increases by the configured `cash_per_unit × amount`.

- [ ] **Step 4: Push both repos**

```bash
git -C plugins/oblsk_hunting push -u origin main
git -C plugins/oblsk_crafting push
git push
```
