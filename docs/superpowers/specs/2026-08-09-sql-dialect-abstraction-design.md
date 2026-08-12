# SQL Dialect Abstraction (MySQL + Postgres)

## Goal

Let the ORM (QueryBuilder, Schema, BaseModel) run unmodified against either
MySQL/MariaDB or PostgreSQL. The database driver is a configurable choice
(`db_driver` convar, or scheme in the connection string) — one backend runs
at a time, chosen by the server operator. MariaDB remains the default.

Mongo support is explicitly out of scope — it is not a SQL dialect, and gets
its own design (see follow-up spec).

## Background

The current ORM (`core/server/ORM/`) is hard-wired to MySQL:

- `QueryBuilder.lua` quotes identifiers with backticks and builds SQL with a
  MySQL grammar.
- `Schema.lua` generates `CREATE TABLE` / `ALTER TABLE` DDL with MySQL-only
  syntax: backtick quoting, `AUTO_INCREMENT`, `ENGINE=InnoDB DEFAULT
  CHARSET=...`, and the MySQL-only single-statement `CHANGE column` rename.
- `Database.lua` dispatches queries to one of four MySQL-flavored connectors
  (`oblsk_connector`, `oxmysql`, `ghmattimysql`, `mysql-async`), all speaking
  the same `?`-placeholder / escape-and-interpolate style.
- `oblsk_connector` (a companion FiveM resource + Node HTTP sidecar) escapes
  and interpolates parameters into the query string itself before handing it
  to `mysql2`.

`BaseModel.lua` already sets `created_at`/`updated_at` at the application
layer via `Database.now()` on every save — there is no reliance on
database-level `ON UPDATE CURRENT_TIMESTAMP` triggers. This matters because
Postgres has no equivalent syntax, and it means none is needed.

## Architecture

### Dialect modules

New directory: `core/server/ORM/Dialects/`

```
Dialects/
  Init.lua      -- Dialect.resolve(name) -> dialect table; errors on unknown name
  MySQL.lua
  Postgres.lua
```

Each dialect module exports:

- `quoteIdentifier(name)` — backtick-quote (MySQL) or double-quote (Postgres).
  Same identifier-safety rules as today's `QueryBuilder.quoteIdentifier`
  (only `[A-Za-z0-9_$]+` segments allowed; anything else throws).
- `columnSQL(kind, opts)` — canonical column `kind` (e.g. `'pk_int'`,
  `'string'`, `'boolean'`, `'timestamp'`) plus `opts` (e.g. `{length = 255}`)
  → the dialect's real SQL type string. Example: `columnSQL('pk_int')`
  returns `'INT AUTO_INCREMENT PRIMARY KEY'` for MySQL, `'SERIAL PRIMARY
  KEY'` for Postgres.
- `tableOptions()` — trailing `CREATE TABLE` clause: `' ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci'` for MySQL, `''` for
  Postgres.
- `renameColumnSQL(table, from, to)` / `retypeColumnSQL(table, column,
  kind, opts)` — MySQL's single `CHANGE` statement splits into Postgres's
  separate `RENAME COLUMN` / `ALTER COLUMN ... TYPE` statements.

### Schema.lua

Column builder functions (`integer()`, `string(length)`, `boolean()`,
`timestamp()`, `timestamps()`, etc.) stop baking a raw MySQL type string at
call time. Instead they record a canonical `{kind = ..., opts = {...}}`
descriptor. `Blueprint:toSQL()` (and the `ALTER TABLE` statement builders)
resolve the actual type string by calling the active dialect's `columnSQL`
at generation time. All inline backtick-quoting in `Schema.lua` is replaced
with calls to the same `Dialect.quoteIdentifier` used by `QueryBuilder`
(today `Schema.lua` and `QueryBuilder.lua` duplicate this logic — this
refactor also de-duplicates it).

### QueryBuilder.lua

`QueryBuilder.quoteIdentifier` delegates to `Database.dialect.quoteIdentifier`
instead of its own hardcoded backtick logic. Everything else is unchanged —
placeholders stay `?` throughout the builder; dialect-specific placeholder
syntax (Postgres's `$1, $2, ...`) is handled below, at the connector, not
here. This keeps the query-building layer dialect-agnostic for the 95% of
logic (WHERE, JOIN, ORDER BY, LIMIT, etc.) that doesn't differ between the
two databases.

### Database.lua

- `Database.config.driver` is resolved in `Database.init()`: from a new
  `db_driver` convar if set, else inferred from the connection string scheme
  (`mysql://` vs `postgres://`), defaulting to `'mysql'`.
- `Database.dialect = Dialects.resolve(Database.config.driver)`.
- `Database.parseConnectionString` accepts both schemes.
- `Database.detectConnector()` / `Database.executeQuery()` gain a Postgres
  branch. Since `oxmysql`/`ghmattimysql`/`mysql-async` are MySQL-only by
  definition, the Postgres branch only applies when `oblsk_connector` is the
  active connector — attempting `db_driver postgres` with e.g. `oxmysql`
  running is a startup-time fatal error (mirrors the existing "no connector
  found" fail-fast behavior), not a silent fallback.

### oblsk_connector

- `server.lua`: branches on `Database.config.driver` (passed through from
  core, or read from the same convar directly). MySQL path is **unchanged**
  — existing escape-and-interpolate `executeSync`/`transactionSync`. New
  Postgres path sends the raw query (still with `?` placeholders) plus the
  **unescaped** params array — no Lua-side string escaping for Postgres.
- `index.js`: add `pg` as a dependency alongside `mysql2`. Pool selection
  (`getPool`) branches on a `driver` field in the request payload. For
  Postgres requests, translate `?` → `$1, $2, ...` positionally, then call
  `pool.query(text, params)` — real parameterized execution via `pg`'s
  binding, not string interpolation. This is a net safety improvement for
  the Postgres path (true bound params instead of hand-rolled escaping).

## Data Flow

```
BaseModel / QueryBuilder (dialect-agnostic, '?' placeholders)
        |
        v
Database.lua (resolves driver + dialect, dispatches to connector)
        |
        +-- MySQL driver ---> oblsk_connector/mysql2, oxmysql, ghmattimysql, mysql-async
        |                      (unchanged: escape + interpolate)
        |
        +-- Postgres driver -> oblsk_connector only
                               server.lua forwards raw query + params
                               index.js translates '?'->'$n', pg binds params
```

## Error Handling

- Unknown `db_driver` value → `Dialects.resolve` throws at `Database.init()`,
  framework fails fast (consistent with existing "no connector" fatal path).
- `db_driver postgres` with a MySQL-only connector (`oxmysql` /
  `ghmattimysql` / `mysql-async`) running → fatal at init, clear log message
  naming the mismatch. No silent fallback to MySQL behavior.
- Postgres query errors surface the same shape as MySQL ones today
  (`{error = ...}` from the connector) so `BaseModel`/`QueryBuilder` callers
  don't need driver-specific error handling.

## Testing

`tests/orm_spec.lua` gains a dialect-parity pass: the same `Schema`/
`QueryBuilder` calls are run once per dialect, asserting the generated SQL
is identical except at the documented divergence points (identifier quote
character, primary-key clause, table options, rename/retype statement
shape). This catches accidental MySQL-isms leaking back into shared code.

## Docker

Root `docker-compose.yml` gains an optional `postgres` service (image
`postgres:16`, same credential pattern as the existing `mariadb` service).
It is not started by default — MariaDB remains the default backend. An
operator who wants Postgres sets `db_driver postgres` in `server.cfg`,
points `mysql_connection_string`/`db_connection_string` at the `postgres`
service, and starts that compose service instead of (or alongside) mariadb.

## Out of Scope

- MongoDB support (separate spec — not a SQL dialect, needs its own
  query-translation approach).
- Migrating `oxmysql`/`ghmattimysql`/`mysql-async` to real bound parameters
  for MySQL. Unrelated hardening; not required for Postgres support.
