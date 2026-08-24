# oblsk_auditlog

Configurable audit trail for ORM model writes. Watch specific models and
fields, get one `audit_logs` row per changed field (insert/update/delete),
with old/new value and actor, browsable in a new "Audit log" tab in the
admin panel. Loads as part of `core`; restart `core` (or the whole server)
to pick up changes.

## Installation

Add `"oblsk_auditlog"` to the `plugins` array in `plugins/registry.json`
(core repo) and restart `core`.

## Setup

Auditing is opt-in per model, configured in `shared/config.lua`:

```lua
AuditLogConfig.Watch = {
  BankAccount = { fields = { 'balance', 'owner_id' } },
  BankTransaction = { fields = '*' }, -- every fillable field, minus `hidden` ones
}
```

Key is the model's global name (e.g. `BankAccount`, matching the Lua
global the model file assigns to, not the table name). `fields` is either
an explicit list of column names, or `'*'` for every field in the model's
`fillable` list — `'*'` automatically excludes anything also listed in the
model's `hidden` (e.g. `BankCard.pin_hash` never gets logged even under
`'*'`, since it's `hidden` there). Models not listed here cost nothing —
no hook gets registered for them, and their writes are never audited.

## How it works

- `core/server/ORM/BaseModel.lua` exposes generic `afterSave`/`afterDelete`
  lifecycle hooks (`Model.hooks:afterSave(fn)` / `:afterDelete(fn)`,
  registered the same way `Model.relations:name()` registers a relation) —
  not audit-specific, any future consumer can use them.
- At boot (`server/main.lua`, once `Database.isReady()`), `AuditLogService`
  reads `AuditLogConfig.Watch` and registers a hook per configured model.
- On every save/delete of a watched model, the hook diffs the configured
  fields against the pre-write snapshot and writes one `audit_logs` row per
  *changed* field only (unchanged fields produce no row) — `insert` rows
  have no old value, `delete` rows have no new value.
- **Actor attribution:** `AuditLogService.withActor(source, fn)` marks any
  writes made synchronously inside `fn()` as `actor_type='player',
  actor_id=source`; writes outside any `withActor` scope attribute to
  `actor_type='system'`. No call sites use this yet — adopting it in a
  service means wrapping the model write, e.g.
  `AuditLogService.withActor(source, function() bankAccount:save() end)`.
  **Known limitation:** this only reliably attributes actor for the
  `Sync`-suffixed writes (`saveSync()`/`deleteSync()`). This branch's
  default `save()`/`delete()` are async — the hook fires from inside a
  later-tick DB callback, after `withActor`'s scope has already restored
  the previous actor, so an async write inside `withActor` currently
  attributes to `system` instead of the intended player. Use the `Sync`
  variants inside `withActor` until this is fixed.
- The admin panel's "Audit log" tab (`plugins/oblsk_admin`) queries
  `admin:server:audit-log-query` (filters: table, action, actor type/id,
  date range; paginated, 50 rows/page) — read-only, no write/delete
  endpoints exist for the log itself.

Not built: raw `Database.query`/`QueryBuilder` writes bypass auditing
entirely (only ORM writes are tracked, by design); there's no retention or
rotation policy, so `audit_logs` grows unbounded (indexed on `table_name`
and `created_at` to keep admin queries fast, but nothing prunes old rows).
