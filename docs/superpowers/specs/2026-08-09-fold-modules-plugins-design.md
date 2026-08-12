# Fold Modules & Plugins into the `core` Resource

## Goal

Modules and plugins stop being separate FXServer resources. Their scripts
load as part of `core`'s own resource, so there is nothing to `ensure` or
`restart` independently — restarting `core` (or the whole server) is the
only way to pick up a module/plugin change, by design. Migration auto-run
for modules/plugins is fixed as part of the same change, since it's the
same "wire modules/plugins in properly" gap.

## Background

Today, `obelisk make:module`/`make:plugin` scaffold `core/modules/<Name>/`
or `core/plugins/<Name>/` with their own `fxmanifest.lua` declaring
`dependencies { 'obelisk' }` (or similar), `server_scripts`/
`client_scripts`, and for plugins a `files { 'web/*.vue', 'web/routes.js' }`
block. This assumes each module/plugin is its own independently
`ensure`-able FXServer resource. It never has been, in this repo's actual
Docker setup: `docker-compose.yml` mounts only `./core` and
`./oblsk_connector` as separate resources; `core/modules/*` and
`core/plugins/*` live inside the `core` mount, and FXServer stops
recursing into a directory the moment it finds an `fxmanifest.lua`
there — so it finds `core`'s own manifest and never descends into a
nested `core/modules/TownHall/fxmanifest.lua` as a separate resource.
`ensure TownHall` has never actually worked under this Docker setup.

The docs site (already shipped) documents this as a limitation with a
manual workaround (add your own compose mount per module/plugin). This
spec replaces that workaround with the real fix: modules/plugins aren't
meant to be independent resources at all.

Separately, `core/server/bootstrap.lua` only runs `core/server/database/
migrations/*.lua` (tracked via `core/server/database/migrations.json`,
maintained by `make:migration`). `make:migration` already maintains an
equivalent `modules/<Name>/server/migrations.json` /
`plugins/<Name>/server/migrations.json` when scaffolding a
module/plugin migration — nothing ever reads those. Module/plugin
migrations are generated but never run.

## Architecture

### 1. `core/fxmanifest.lua` — script globs

Append to the existing `shared_scripts`/`client_scripts`/`server_scripts`
blocks, **after** `core`'s own explicit entries (core's ORM/Services must
finish loading before anything that depends on them):

```lua
shared_scripts {
    'core/shared/**/*.lua',
    'modules/*/shared/**/*.lua',
    'plugins/*/shared/**/*.lua',
}
```

(and equivalently for `client_scripts`/`server_scripts`, each keeping
`core/...` entries first, then `modules/*/...`, then `plugins/*/...`).

**Unverified assumption, flagged for a real-server smoke test:** FXServer's
manifest glob resolution supporting a wildcard *directory segment*
(`modules/*/server/**/*.lua`, not just a trailing `**`) can't be confirmed
in this environment — there's no FXServer runtime here, only the
Lua-only unit test harness. If this turns out unsupported, the fallback is
an explicit list per module/plugin (see Testing).

`core`'s existing `files { 'core/html/**/*' }` / `ui_page` block is
untouched — the Vue NUI build glob (`web/src/router/index.js`'s
`import.meta.glob('../../../plugins/*/web/routes.js', ...)`) is a
Vite build-time mechanism, entirely separate from FXServer resource
boundaries, and is unaffected by this change either way.

### 2. Registry files

Lua can't list directory contents at runtime, so something has to tell
`bootstrap.lua` which modules/plugins exist (needed for the migration
runner, see below — script *loading* doesn't need this, FXServer resolves
its own glob against the filesystem at resource-start time).

New: `core/modules/registry.json`, `core/plugins/registry.json`:

```json
{ "modules": ["oblsk_items", "oblsk_vehicles"] }
```

`make:module`/`make:plugin` append the new name on scaffold (idempotent —
skip if already present).

### 3. CLI generators stop emitting a per-item `fxmanifest.lua`

`cli/commands/make-module.js` and `make-plugin.js` no longer write
`fxmanifest.lua` for the scaffolded module/plugin — it's not a resource,
so `dependencies{}`/`ui_page`/`files{}` there was never meaningful
(and `dependencies { 'obelisk' }` never resolved to anything real, since
no resource is named `obelisk` — this retires that inconsistency
entirely, it simply stops existing). They still scaffold the same
directory tree (`server/`, `client/`, `shared/`, and for plugins `web/`)
and the same per-feature files (models, migrations, actions, services,
Vue components). They additionally:
- append the new name to the relevant `registry.json` (creating it if
  needed, with `{"modules": []}`/`{"plugins": []}` as the empty shape).
- write a short `README.md` noting the module/plugin loads as part of
  `core` and requires restarting `core`/the server to pick up changes.

### 4. `bootstrap.lua` — generalized migration runner

Extract the existing migration-running loop (table-exists check, read
`migrations.json`, run each unlisted migration's `up()`, record it in the
`migrations` table) into a local function parameterized by:
- a base path prefix (`'core/server/database/'`, `'modules/<name>/server/'`,
  `'plugins/<name>/server/'`)
- the `migrations.json` path under that prefix

Call it once for core (unchanged behavior, same paths as today), then once
per entry in `modules/registry.json` and `plugins/registry.json`. A
module/plugin with no `server/migrations.json` yet (nothing generated) is
skipped gracefully — `LoadResourceFile` returns `nil`, matching how the
existing core path already tolerates an empty/missing file.

Everything is one resource now, so `LoadResourceFile(GetCurrentResourceName(), ...)`
works uniformly across core/module/plugin paths — no cross-resource file
access complexity.

### 5. Docs updates

The docs site (shipped, needs a follow-up edit once this lands):
- `docs/examples/building-a-plugin.md` and `docs/guide/quick-start.md` —
  remove the "add your own compose mount" `::: warning` callouts; `ensure`
  is simply wrong now (there's nothing to ensure) — the section becomes
  "restart `core`" instead.
- `docs/concepts/orm.md` / `docs/examples/building-a-plugin.md` — the
  "migration ran" caveat flips back to true (it now does run).
- `docs/concepts/modules-and-plugins.md` — remove the `dependencies {
  'obelisk' }` naming-inconsistency callout; that section is rewritten
  since modules/plugins no longer have their own `fxmanifest.lua` at all.

This spec's plan should include these doc edits as tasks so the site
doesn't regress into describing the *old* limitation as current.

## Error Handling

- A module/plugin registered in `registry.json` but whose directory was
  deleted: `LoadResourceFile` for its `migrations.json` returns `nil`,
  the runner skips it silently (same tolerance as a module with no
  migrations yet — indistinguishable from "nothing to run", which is
  the correct behavior either way).
- A malformed `registry.json` (bad JSON): `json.decode` returns `nil`;
  treat as an empty registry (`{}`) rather than erroring startup, printing
  a `[Obelisk] WARNING: could not parse modules/registry.json` message —
  consistent with `bootstrap.lua`'s existing style of loud-but-non-fatal
  warnings for non-critical subsystems (matches `commitTransactionFallback`'s
  existing warning pattern).

## Testing

No FXServer runtime exists in this repo's test environment, so:
- The `bootstrap.lua` migration-runner generalization has no automated
  test — matches the existing convention (`bootstrap.lua` isn't covered
  by `tests/orm_spec.lua` today either; it's inherently FXServer-native-
  coupled: `GetResourcePath`, `LoadResourceFile`, `Citizen.CreateThread`).
- The CLI registry-writing logic (`make-module.js`/`make-plugin.js`) has
  no existing JS test framework in this repo; not introducing one now is
  consistent with existing convention — verify manually (scaffold a
  module, confirm `registry.json` gets the right entry, confirm no
  `fxmanifest.lua` is written).
- The fxmanifest glob-resolution assumption (mid-path `*` wildcard) needs
  a real-server smoke test before trusting it in production — flagged
  above, not verifiable here. If it fails, fall back to an explicit,
  CLI-maintained list of script paths in `core/fxmanifest.lua` itself
  (the registry.json names are already available to generate such a list
  from, so this fallback doesn't require new infrastructure, just a
  different consumer of the same registry).

## Out of Scope

- Seeder auto-discovery for modules/plugins. No manifest mechanism exists
  for seeders at all today, even for core (bootstrap.lua hardcodes a Lua
  array of seeder names) — a separate, unrequested concern.
- Any change to how the Vue NUI (`core/web`) builds or how
  `plugins/*/web/routes.js` gets bundled — untouched, unaffected by this
  change.
- Runtime namespace-collision protection between modules/plugins sharing
  one Lua VM (e.g. two modules both defining a global `Service` table).
  This is a new risk introduced by folding resources together (previously
  each module/plugin ran in its own resource VM); not mitigated in this
  spec — out of scope, flagged here for awareness rather than solved.
