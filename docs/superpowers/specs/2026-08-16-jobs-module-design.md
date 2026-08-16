# oblsk_jobs module — design spec

Date: 2026-08-16
Status: approved for implementation planning

## Context

Multiple job types are planned (bus driver, money, delivery, petrol delivery,
pizza delivery, garbage, gardener, cleaner, electrician). Rather than each
job plugin reinventing on-duty state, XP/leveling, and payout, a shared
`oblsk_jobs` **core module** owns that machinery. Individual jobs are thin
plugins (`oblsk_busdriver`, `oblsk_moneyjob`, ...) that register a job
definition and call the module's API to pay out completed tasks.

This is slice 1 of a larger decomposition:
1. `oblsk_jobs` module (this spec)
2. `oblsk_scheduler` core service (auto-refill of 24/7/ATM/clothes shops)
3. World economy state model (24/7 register cash, clothes stock, petrol
   station fuel per FuelType, NPC-owned vs server-owned)
4. `oblsk_trashbins` plugin (garbage bin interaction, capacity/slots)
5. Individual job plugins built on `oblsk_jobs`, each their own slice

This spec covers **slice 1 only**: the framework — job definitions, XP/level
tracking, on-duty state, admin CRUD. No gameplay logic for any specific job.

## Scope decisions

- Per-job XP/level (not a global job level). Bus driver level and gardener
  level are tracked independently per character.
- Walk-up job engagement: no assignment/hiring step. Any character can go
  on-duty for any active job by calling `Jobs.goOnDuty`.
- Only one active job per character at a time. Going on-duty for a
  different job while already on-duty is rejected — must go off-duty first.
- Active job persists across reconnect/relog (restored on character load).
- The module owns pay + XP. Job plugins call
  `Jobs.completeTask(player, jobKey, taskKey)`; the module looks up the
  admin-configured pay/XP for that task, credits money via `oblsk_banking`,
  updates XP/level, and fires an event. Job plugins only implement
  gameplay — where to go, what minigame/action to perform, which task key
  to report.

## Data model

- `jobs` — id, key (unique), name, icon, description, active (bool)
- `job_levels` — job_id, level, xp_required, label
- `job_tasks` — job_id, task_key (unique per job), pay_amount, xp_amount
- `bus_routes` — job_id, name, min_level, stops (json, ordered)
- `character_job_progress` — character_id, job_id, xp, level
- `character_active_job` — character_id, job_id (nullable)

`bus_routes` lives in this module (not `oblsk_busdriver`) because route
data is admin-managed job configuration, same category as `job_tasks` — the
busdriver plugin only reads it.

## Server API (module globals, same pattern as `oblsk_items`)

- `Jobs.goOnDuty(player, jobKey)` — rejects if character already has a
  different active job; sets `character_active_job`
- `Jobs.goOffDuty(player)` — clears `character_active_job`
- `Jobs.getActiveJob(charId)` — returns job key or nil
- `Jobs.completeTask(player, jobKey, taskKey)` — validates player is
  on-duty for `jobKey`, looks up `job_tasks` pay/xp, credits via
  `oblsk_banking`, updates `character_job_progress`, handles level-up
  against `job_levels`, fires `oblsk_jobs:server:task_completed`
- `Jobs.getProgress(charId, jobKey)` — returns `{xp, level}`
- `Jobs.getRoutes(jobKey)` — returns `bus_routes` rows for a job, used by
  `oblsk_busdriver` to filter by the character's current level

Admin CRUD API (backing `JobsTab.vue`):
- `Jobs.admin.listJobs()`, `createJob`, `updateJob`, `deleteJob`
- `Jobs.admin.listLevels(jobId)`, `upsertLevel`, `deleteLevel`
- `Jobs.admin.listTasks(jobId)`, `upsertTask`, `deleteTask`
- `Jobs.admin.listRoutes(jobId)`, `upsertRoute`, `deleteRoute`

## Admin UI

`JobsTab.vue` added to `oblsk_admin` (per the imported design). List of
jobs on the left, detail panel on the right with three editable tables:
Levels, Tasks, and (only when the job has routes) Routes. Follows the
existing `ItemsTab.vue`/`PrintersTab.vue` list+detail pattern.

## Testing

TDD, per usual:
- `JobService` CRUD spec (jobs/levels/tasks/routes)
- On-duty spec: go on-duty, reject switching without going off-duty first,
  go off-duty clears active job
- Reconnect spec: active job restored on character load
- `completeTask` spec: rejects when not on-duty for that job, correct
  pay/xp lookup, banking credit called, XP accumulation, level-up crossing
  `job_levels` thresholds
- Admin CRUD spec for levels/tasks/routes tables
