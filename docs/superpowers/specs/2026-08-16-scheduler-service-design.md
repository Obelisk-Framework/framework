# Core Scheduler service — design spec

Date: 2026-08-16
Status: approved for implementation planning

## Context

Every plugin that needs periodic work today hand-rolls its own
`Citizen.CreateThread` + `Citizen.Wait` loop (crafting's tick, banking's
ATM logic, etc. — no shared abstraction exists). Slice 1 of the jobs
decomposition (`oblsk_jobs`, done) needs a scheduler for slice 2: a job
that checks 24/7 registers, ATMs, and clothes shops for staleness and
refills them if no one has done the delivery job. This spec covers the
**generic core Scheduler service only** — the concrete refill job is
built later, once the world-economy state model (24/7 cash, clothes
stock) exists; this service just needs to be ready to run it.

## Scope decisions

- Scheduled jobs are DB rows (`scheduled_jobs`), admin-creatable/editable
  (interval/cron, enabled, action to run) — not purely code-registered.
- A scheduled job's actual work is an existing `ActionService`-registered
  action. No new handler-registration API: `scheduled_jobs.action_id`
  references `actions.action_id`. The admin UI only lets you attach a
  schedule to an action that's already registered in code — it can't
  invent new job behavior.
- Two schedule types, both on the same table, both referencing the same
  `action_id`: `interval` (run every N seconds) and `cron` (a standard
  5-field cron expression: minute hour day month weekday). Support for
  `*`, single numbers, comma-lists, ranges (`a-b`), and steps (`*/n`,
  `a-b/n`) in each cron field. No timezone handling — cron fields are
  evaluated against the server process's local wall clock.
- Interval jobs self-heal after downtime (next tick after boot just runs
  them, since `now - last_run_at` will already exceed the interval). Cron
  jobs do NOT catch up missed fires — if the server was down across a
  cron fire time, that occurrence is simply skipped; the next matching
  time still fires normally.
- Runs on a single ticking thread, so no concurrent/overlapping job runs
  are possible by construction (one full pass over all rows, then sleep).

## Data model

- `scheduled_jobs` (core migration, `core/server/database/`) — id,
  `action_id` (string, references `actions.action_id`), `schedule_type`
  ('interval'|'cron'), `interval_seconds` (nullable), `cron_expression`
  (nullable), `enabled` (bool, default 1), `last_run_at` (nullable
  timestamp)

No model class — raw `QueryBuilder`, matching `ActionService.lua`'s own
style for the `actions` table (core services use raw QueryBuilder for
their own tables; the `BaseModel:extend` convention is a module-repo
pattern for module-owned entities, not something core's own services
follow for infra tables like `actions`/`interactions`/`scheduled_jobs`).

## Server API

`core/core/server/Services/SchedulerService.lua`:
- `SchedulerService.create(actionId, scheduleType, config)` — `config` is
  `{intervalSeconds = N}` or `{cronExpression = '...'}` depending on
  `scheduleType` → returns `id`
- `SchedulerService.update(id, attrs)`
- `SchedulerService.delete(id)`
- `SchedulerService.list()` — all rows
- `SchedulerService.isDue(row, now)` — pure function (no I/O), the
  decision logic:
  - `interval`: due if `row.last_run_at == nil` or
    `now - row.last_run_at >= row.interval_seconds`
  - `cron`: due if `CronExpression.matches(row.cron_expression, now)` AND
    (`row.last_run_at == nil` or `row.last_run_at` falls before the start
    of the current matching minute) — the second half prevents re-firing
    on every 30s tick within the same matching minute
- `SchedulerService.tick(now)` — fetches all `enabled` rows, runs
  `isDue` on each, calls `ActionService.execute(nil, row.action_id, {})`
  for due rows, updates `last_run_at = now`

`core/core/server/Services/CronExpression.lua`:
- `CronExpression.matches(expression, timestamp)` — parses the 5-field
  expression and checks it against `os.date('*t', timestamp)`'s
  min/hour/day/month/wday fields

Boot (added to `SchedulerService.lua` or `core/server/bootstrap.lua`,
following existing boot-thread convention): wait for `Database.isReady()`,
then loop `SchedulerService.tick(os.time())` + `Citizen.Wait(30000)`.

## Admin UI

`SchedulerTab.vue` in `oblsk_admin` (+ `server/scheduler.lua` NUI relay,
same thin admin-gate → delegate → reply pattern as `jobs.lua`, plus the
matching `client/main.lua` `TAB_RELAYS`/`TAB_REPLIES` entries — this
project's final review on the jobs module caught exactly this omission
once already, so it's called out explicitly here). List of scheduled
jobs (joined with `actions` for a human label, schedule description,
last-run, enabled toggle); create/edit form: dropdown of known
`actions.action_id` rows, schedule-type toggle, interval-seconds or
cron-expression input, save/delete.

## Testing

- `CronExpression.matches` spec: each field type individually (`*`,
  single number, list, range, step) and combinations; a full standard
  expression like `*/15 9-17 * * 1-5`
- `SchedulerService.isDue` spec: interval due/not-due (including
  never-run), cron due/not-due, no-double-fire-within-the-same-minute
- `SchedulerService` CRUD spec (create/update/delete/list)
- `SchedulerService.tick` spec: only due+enabled rows call
  `ActionService.execute`, `last_run_at` gets stamped, disabled/not-due
  rows are skipped
