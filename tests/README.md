# Tests

Unit tests for the parts of Obelisk that are **pure Lua logic** and therefore
runnable without a FiveM server.

## Running

Requires a standalone Lua 5.4 interpreter:

```bash
# Debian/Ubuntu:  sudo apt-get install lua5.4
npm test          # -> lua5.4 tests/orm_spec.lua
# or directly:
lua5.4 tests/orm_spec.lua
```

The runner exits non-zero if any test fails, so it works in CI.

## What is covered

`tests/orm_spec.lua` exercises the ORM layer's string/logic code:

- `Database.escape` — value escaping
- `Database.prepareQuery` — placeholder substitution (incl. regression tests
  for the `%`-in-value and repeated-`?` substitution bugs)
- `QueryBuilder:toSql` / `insert` / `update` / `delete` — generated SQL + params
- `Schema.create` — generated `CREATE TABLE` DDL
- `BaseModel:createSync` — `created_at` / `updated_at` are written as
  `DATETIME`-formatted strings
- `Database.transaction` — statements are collected in order, a callback error
  aborts before commit, and the manual fallback wraps them in
  `START TRANSACTION` / `COMMIT` (or `ROLLBACK` on failure)

`tests/obelisk_spec.lua` exercises `core/shared/Obelisk.lua`'s side-detection
and error-throwing logic, ensuring it correctly routes events (emit/on/emitServer/
emitClient/onServer/onClient) and throws appropriate errors when methods are
called from the wrong side (client or server).

`tests/support/fivem_stubs.lua` stubs the handful of CitizenFX globals these
files reference (`Citizen`, `exports`, `GetResourceState`, `json`, …) so the
source can be loaded under vanilla Lua.

## What is NOT covered (and why)

Anything that only exists inside the CitizenFX runtime cannot be unit tested
here — it needs a live FiveM server (or heavy mocking that wouldn't prove much):

- Net events (`RegisterNetEvent` / `TriggerClientEvent`) and the client↔server flow
- NUI (`SendNUIMessage`, `SetNuiFocus`) and the Vue frontend
- Gameplay natives (`DrawText`, `GetEntityCoords`, keybinds, …)
- Real database I/O through a MySQL connector

For those, test manually against a running server.
