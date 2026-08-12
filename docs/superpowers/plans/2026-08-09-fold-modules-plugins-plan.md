# Fold Modules & Plugins into `core` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modules and plugins stop being independent FXServer resources; their scripts load as part of `core`, and their migrations run automatically via a generalized runner.

**Architecture:** Extend `core/fxmanifest.lua`'s script globs to also pick up `modules/*/...` and `plugins/*/...`; add `registry.json` files so Lua (which cannot list directories at runtime) knows which modules/plugins exist; generalize `bootstrap.lua`'s migration loop into a parameterized local function called once per core/module/plugin; update the CLI generators to stop writing a per-item `fxmanifest.lua` and instead register the new name; update docs that describe the old per-resource-mount workaround.

**Tech Stack:** Lua (FXServer resource scripts), Node.js CLI (`fs-extra`, `inquirer`, `chalk`), VitePress docs (Markdown).

**Repo layout note:** the outer `core/` directory is the FXServer resource root (mounted by `docker-compose.yml`); its `fxmanifest.lua` lives at `core/fxmanifest.lua`, and confusingly the actual Lua source tree is nested one level deeper at `core/core/{server,client,shared}/...`. `modules/` and `plugins/` are siblings of that inner `core/core/` directory, i.e. `core/modules/<Name>/` and `core/plugins/<Name>/` — already inside the resource root, which is exactly why the fold-in approach works without moving any files.

## Global Constraints

- No FXServer runtime exists in this repo's test environment — the mid-path wildcard glob assumption (`modules/*/server/**/*.lua`) cannot be automated-tested here; flag it for a real-server smoke test, per spec.
- `bootstrap.lua` has no existing automated test coverage (FXServer natives: `GetResourcePath`, `LoadResourceFile`, `Citizen.CreateThread`) — matches existing convention, don't introduce test infra for it now.
- CLI (`cli/commands/*.js`) has no existing JS test framework — verify manually, per spec, don't introduce one now.
- Docs prose style: minimize em/en dashes in new or edited prose (user preference stated 2026-08-09) — prefer commas, periods, or parentheses instead.
- Keep `core`'s own explicit script entries before any `modules/*`/`plugins/*` glob entries in `fxmanifest.lua` (ORM/Services must finish loading first).
- Each module/plugin lives in its own separate git repository (submodule-style), not tracked inside `core`'s repo. `core/.gitignore` already has `modules/*`/`plugins/*` (contents ignored) with `!modules/registry.json`/`!plugins/registry.json` negation exceptions so `core`'s own repo can still track the two registry files without tracking module/plugin source. `oblsk_inventory`/`oblsk_character-selection` are pre-existing tracked content from before this convention; leave them as-is (already-tracked files are unaffected by a later `.gitignore` addition), not in scope to convert to submodules here.

---

## Task 1: `fxmanifest.lua` script globs + empty registries

**Files:**
- Modify: `core/fxmanifest.lua` (shared_scripts/client_scripts/server_scripts blocks)
- Create: `core/modules/registry.json`
- Create: `core/plugins/registry.json`

**Interfaces:**
- Produces: `core/modules/registry.json` shape `{"modules": []}`, `core/plugins/registry.json` shape `{"plugins": []}` — consumed by Task 2's migration runner and Task 3/4's CLI registry-append logic.

- [ ] **Step 1: Add `modules/*`/`plugins/*` globs after core's own entries**

In `core/fxmanifest.lua`, change:

```lua
-- Shared scripts (load order matters)
shared_scripts {
    'core/shared/**/*.lua'
}
```

to:

```lua
-- Shared scripts (load order matters)
shared_scripts {
    'core/shared/**/*.lua',
    'modules/*/shared/**/*.lua',
    'plugins/*/shared/**/*.lua'
}
```

In the same file, append `'modules/*/server/**/*.lua', 'plugins/*/server/**/*.lua'` as the last two entries of `server_scripts` (after the existing `'core/server/bootstrap.lua'` entry — order the trailing comma accordingly), and append `'modules/*/client/**/*.lua', 'plugins/*/client/**/*.lua'` as the last two entries of `client_scripts` (after `'core/client/bootstrap.lua'`).

Leave the `ui_page 'core/html/index.html'` and `files { 'core/html/**/*' }` block untouched — unrelated to script loading.

- [ ] **Step 1b: Confirm `.gitignore` allows the registries through**

`core/.gitignore` must read exactly:

```
node_modules
modules/*
plugins/*
!modules/registry.json
!plugins/registry.json
```

(`modules/*`/`plugins/*`, not bare `modules`/`plugins` — git cannot re-include a file whose parent directory is itself excluded, only a file inside a directory whose *contents* are excluded via the trailing `/*` form.) If this file doesn't already match, update it as part of this task's commit.

- [ ] **Step 2: Create the two empty registries**

`core/modules/registry.json`:

```json
{
  "modules": []
}
```

`core/plugins/registry.json`:

```json
{
  "plugins": []
}
```

- [ ] **Step 3: Manual verification (no FXServer runtime available here)**

Run: `cat core/fxmanifest.lua` and confirm the three glob blocks each list `core/...` first, then `modules/*/...`, then `plugins/*/...`, with valid Lua table syntax (trailing commas between entries, none after the last).

Run: `node -e "require('./core/modules/registry.json'); require('./core/plugins/registry.json')"` from repo root — confirms both are valid JSON.

Run: `git -C core status --short modules/registry.json plugins/registry.json` — both must show as untracked/staged (`??`/`A`), not silently dropped by `.gitignore`; if either is missing from the output, the negation pattern in `.gitignore` isn't working (see Step 1b) and needs fixing before commit.

Note in the commit message that the mid-path wildcard (`modules/*/server/**/*.lua`) is unverified against real FXServer glob resolution and needs a smoke test before production use (per spec's flagged assumption and fallback: an explicit CLI-maintained script list generated from the registries, if the wildcard turns out unsupported).

- [ ] **Step 4: Commit**

```bash
cd core
git add fxmanifest.lua modules/registry.json plugins/registry.json
git commit -m "feat(core): load modules/plugins scripts via fxmanifest globs"
```

---

## Task 2: Generalized migration runner in `bootstrap.lua`

**Files:**
- Modify: `core/core/server/bootstrap.lua`

**Interfaces:**
- Consumes: `core/modules/registry.json` shape `{"modules": [...]}`, `core/plugins/registry.json` shape `{"plugins": [...]}` (Task 1).
- Produces: no new external interface — same `migrations` DB table, same `Schema`/`Database` calls, now also applied under `modules/<name>/server/` and `plugins/<name>/server/` prefixes.

- [ ] **Step 1: Extract the existing loop into a local parameterized function**

In `core/core/server/bootstrap.lua`, replace the current migration block (the `-- Run migrations` section through the end of the `for _, migration in ipairs(migrations) do ... end` loop) with:

```lua
-- Run migrations
print('[Obelisk] Running migrations...')

if not Schema.hasTable('migrations') then
    Schema.create('migrations', function(table)
        table:id()
        table:string('migration', 255):unique()
        table:integer('batch')
        table:timestamp('created_at')
    end)
end

local function runMigrationsAt(basePath, label)
    local migrationsJsonContent = LoadResourceFile(GetCurrentResourceName(), basePath .. 'migrations.json')
    local migrationsData = json.decode(migrationsJsonContent or '') or { migrations = {} }
    local migrations = migrationsData.migrations or {}

    for _, migration in ipairs(migrations) do
        local result = Database.querySync('SELECT * FROM migrations WHERE migration = ?', {migration})
        if not result or #result == 0 then
            print('[Obelisk] Running migration (' .. label .. '): ' .. migration)
            local migrationModule = LoadResourceFile(GetCurrentResourceName(), basePath .. 'migrations/' .. migration .. '.lua')
            if migrationModule then
                local migrationFunc = load(migrationModule)
                if migrationFunc then
                    local migrationTable = migrationFunc()
                    if migrationTable and migrationTable.up then
                        local success, err = pcall(migrationTable.up)
                        if success then
                            local res = Database.insertSync('INSERT INTO migrations (migration, batch, created_at) VALUES (?, ?, ?)',
                                              {migration, 1, Database.now()})
                            print("Result: " .. tostring(res))
                            print('[Obelisk] Migration completed (' .. label .. '): ' .. migration)
                        else
                            print('[Obelisk] Migration failed (' .. label .. '): ' .. migration .. ' - ' .. tostring(err))
                        end
                    end
                end
            end
        end
    end
end

local function loadRegistry(path, key)
    local content = LoadResourceFile(GetCurrentResourceName(), path)
    if not content then
        return {}
    end
    local decoded = json.decode(content)
    if not decoded then
        print('[Obelisk] WARNING: could not parse ' .. path)
        return {}
    end
    return decoded[key] or {}
end

runMigrationsAt('core/server/database/', 'core')

for _, name in ipairs(loadRegistry('modules/registry.json', 'modules')) do
    runMigrationsAt('modules/' .. name .. '/server/', name)
end

for _, name in ipairs(loadRegistry('plugins/registry.json', 'plugins')) do
    runMigrationsAt('plugins/' .. name .. '/server/', name)
end
```

Do not change the `local migrationsPath = GetResourcePath(...)` line above this block if it's used elsewhere in the file; if it was only used by the old inline loop, remove it (it's dead once `runMigrationsAt` takes over path construction via `LoadResourceFile`, which resolves relative to the resource root itself and doesn't need `GetResourcePath`).

- [ ] **Step 2: Manual verification (no automated test exists for this file, matches existing convention)**

Run: `luac5.3 -p core/core/server/bootstrap.lua` (or whichever Lua syntax checker is available, e.g. `lua -e "loadfile('core/core/server/bootstrap.lua')"`) — confirms the file still parses.

Read through the new code once and confirm: `runMigrationsAt('core/server/database/', 'core')` reproduces byte-for-byte the same table-check + query + print + insert sequence the old inline loop had for core (only the path prefix and log label changed), so core's existing migration behavior is unchanged.

Confirm a module/plugin with no `server/migrations.json` yet (registry lists it, file doesn't exist) is tolerated: `LoadResourceFile` returns `nil` for a missing file, `json.decode(nil or '')` decodes the empty string, which fails and falls through to the `{ migrations = {} }` default via `or` — loop body never executes, no error.

- [ ] **Step 3: Commit**

```bash
cd core
git add core/server/bootstrap.lua
git commit -m "feat(core): generalize migration runner to cover modules/plugins registries"
```

---

## Task 3: Shared registry-append helper + `make-module.js` update

**Files:**
- Create: `cli/lib/registry.js`
- Modify: `cli/commands/make-module.js`

**Interfaces:**
- Produces: `cli/lib/registry.js` exports `appendToRegistry(registryPath, name, key)` — async function; reads JSON at `registryPath` (creating `{ [key]: [] }` if the file doesn't exist), pushes `name` if not already present, writes it back with `{ spaces: 2 }`. Used by both `make-module.js` (Task 3) and `make-plugin.js` (Task 4).

- [ ] **Step 1: Create the shared helper**

`cli/lib/registry.js`:

```js
const fs = require('fs-extra');

async function appendToRegistry(registryPath, name, key) {
  let data = { [key]: [] };

  if (await fs.pathExists(registryPath)) {
    data = await fs.readJson(registryPath);
  }

  if (!data[key]) {
    data[key] = [];
  }

  if (!data[key].includes(name)) {
    data[key].push(name);
  }

  await fs.writeJson(registryPath, data, { spaces: 2 });
}

module.exports = { appendToRegistry };
```

- [ ] **Step 2: Update `make-module.js` — stop writing `fxmanifest.lua`, register the name, adjust the README**

In `cli/commands/make-module.js`:

1. Add near the top, alongside the other `require`s:

```js
const { appendToRegistry } = require('../lib/registry');
```

2. Remove the entire `// Create fxmanifest.lua` block (the `manifestContent` template literal and its `fs.writeFile(path.join(moduleDir, 'fxmanifest.lua'), manifestContent)` call).

3. Replace the `// Create README` block's `readmeContent` template literal's `## Installation` section — change:

```js
## Installation
This module is automatically loaded by the Obelisk framework.
```

to:

```js
## Installation
This module loads as part of the \`core\` resource. Restart \`core\` (or the whole server) to pick up this module.
```

4. Immediately after the existing `await fs.writeFile(path.join(moduleDir, 'README.md'), readmeContent);` line, add:

```js
  await appendToRegistry(
    path.join(process.cwd(), 'modules', 'registry.json'),
    moduleName,
    'modules'
  );
```

- [ ] **Step 3: Manual verification**

Run: `cd core && node cli/index.js make:module` (or the equivalent entry point — check `cli/index.js`/`package.json` `bin` field for the exact invocation), scaffold a throwaway module named `TmpVerify`, and confirm:
- `modules/TmpVerify/` was created with `server/`, `client/`, `shared/`, `README.md` — no `fxmanifest.lua`.
- `modules/registry.json` now contains `"TmpVerify"` in its `"modules"` array.
- Running the same command again with the same name is rejected by the existing "already exists" check (unchanged behavior).

Clean up: `rm -rf modules/TmpVerify` and remove `"TmpVerify"` from `modules/registry.json` afterward.

- [ ] **Step 4: Commit**

```bash
cd core
git add cli/lib/registry.js cli/commands/make-module.js
git commit -m "feat(cli): make:module registers name instead of scaffolding its own fxmanifest.lua"
```

---

## Task 4: `make-plugin.js` update

**Files:**
- Modify: `cli/commands/make-plugin.js`

**Interfaces:**
- Consumes: `appendToRegistry(registryPath, name, key)` from `cli/lib/registry.js` (Task 3).

- [ ] **Step 1: Stop writing `fxmanifest.lua`, register the name, adjust the README**

In `cli/commands/make-plugin.js`:

1. Add near the top, alongside the other `require`s:

```js
const { appendToRegistry } = require('../lib/registry');
```

2. Remove the entire `// Create fxmanifest.lua` block (the `manifestContent` template literal, including its conditional `ui_page`/`files{}` block for the `vue` feature, and its `fs.writeFile(path.join(pluginDir, 'fxmanifest.lua'), manifestContent)` call).

3. In the `readmeContent` template literal, change:

```js
## Installation
1. Ensure Obelisk framework is installed
2. Place this plugin in the \`plugins/\` directory
3. Add \`ensure ${pluginName}\` to your server.cfg
4. Restart your server
```

to:

```js
## Installation
This plugin loads as part of the \`core\` resource. Place it in the \`plugins/\` directory and restart \`core\` (or the whole server) to pick it up.
```

4. Immediately after the existing `await fs.writeFile(path.join(pluginDir, 'README.md'), readmeContent);` line, add:

```js
  await appendToRegistry(
    path.join(process.cwd(), 'plugins', 'registry.json'),
    pluginName,
    'plugins'
  );
```

5. The `vue` feature's Vite build path (`web/dist/**/*`, `web/routes.js`) is a separate build-time mechanism from FXServer resource boundaries (per spec, out of scope) — leave `generatePluginVue` and every `web/` file generator untouched. Only the manifest's now-removed `ui_page`/`files{}` block for `vue` is deleted, not the `web/` scaffolding itself.

- [ ] **Step 2: Manual verification**

Run: `cd core && node cli/index.js make:plugin` (check `cli/index.js` for the exact invocation), scaffold a throwaway plugin named `TmpPluginVerify` with the `vue` feature selected, and confirm:
- `plugins/TmpPluginVerify/` was created with `server/`, `client/`, `shared/`, `web/` — no `fxmanifest.lua`.
- `plugins/registry.json` now contains `"TmpPluginVerify"` in its `"plugins"` array.
- `web/` still contains the same Vue scaffolding as before this change (routes.js, component files) — only the manifest is gone.

Clean up: `rm -rf plugins/TmpPluginVerify` and remove `"TmpPluginVerify"` from `plugins/registry.json` afterward.

- [ ] **Step 3: Commit**

```bash
cd core
git add cli/commands/make-plugin.js
git commit -m "feat(cli): make:plugin registers name instead of scaffolding its own fxmanifest.lua"
```

---

## Task 5: Docs updates

**Files:**
- Modify: `docs/guide/quick-start.md`
- Modify: `docs/examples/building-a-plugin.md`
- Modify: `docs/concepts/modules-and-plugins.md`

**Interfaces:** none (prose-only changes).

- [ ] **Step 1: `docs/guide/quick-start.md` — replace the resource-mount warning**

Replace:

```markdown
::: warning `MyFeature` needs its own resource mount
Under the current Docker setup, only `core` and `oblsk_connector` are mounted as separate FXServer resources (see `docker-compose.yml` at the repo root). `MyFeature` was scaffolded under `core/modules/`, inside `core`'s own directory tree — and FXServer stops recursing into a directory once it finds an `fxmanifest.lua` there, so it finds `core`'s manifest first and never discovers `modules/MyFeature/fxmanifest.lua` as an independent resource. Until this is fixed, `ensure MyFeature` won't find anything unless you add its own mount to `docker-compose.yml`, e.g.:

```yaml
- ./core/modules/MyFeature:/fxserver/server/resources/local/MyFeature:ro
```
:::

Restart (or start) the server and the module's scripts will load alongside the rest of the framework.
```

with:

```markdown
`MyFeature` loads as part of `core`'s own resource (its scripts are picked up by `core/fxmanifest.lua`'s `modules/*/...` globs). There's nothing to `ensure` separately: restart `core` (or the whole server), and the module's scripts load alongside the rest of the framework.

```bash
docker compose restart fxserver
```
```

Also remove the earlier `ensure MyFeature` code block a few lines above this warning (the one right after "Generated modules aren't loaded automatically" text) and adjust that surrounding sentence so it no longer tells the reader to add an `ensure` line, since a folded-in module has nothing to independently `ensure`.

- [ ] **Step 2: `docs/examples/building-a-plugin.md` — replace both warnings**

Replace the `ensure TownHall` line inside the `server.cfg` code block (and the sentence introducing it) so it no longer lists `TownHall` as a separate `ensure` line — only `ensure oblsk_connector` and `ensure core` remain, since `TownHall` now loads inside `core`.

Replace:

```markdown
::: warning `TownHall` needs its own resource mount
Under the current Docker setup, only `core` and `oblsk_connector` are mounted as separate FXServer resources (see `docker-compose.yml` at the repo root). A plugin scaffolded under `core/plugins/` (like `TownHall`) lives inside `core`'s own directory tree, and FXServer stops recursing into a directory once it finds an `fxmanifest.lua` there — so it finds `core`'s manifest first and never discovers `plugins/TownHall/fxmanifest.lua` as an independent resource. Until this is fixed, `ensure TownHall` won't find anything unless you add its own mount to `docker-compose.yml`, e.g.:

```yaml
- ./core/plugins/TownHall:/fxserver/server/resources/local/TownHall:ro
```
:::
```

with:

```markdown
`TownHall` loads as part of `core`'s own resource (its scripts are picked up by `core/fxmanifest.lua`'s `plugins/*/...` globs), so there's no separate `ensure TownHall` line to add.
```

Replace:

```markdown
::: warning Plugin/module migrations are not auto-run
The only migration runner in the framework is `core/server/bootstrap.lua`, and it's hard-coded to `core/server/database/migrations/` + `core/server/database/migrations.json` inside the `core` resource itself. Nothing currently reads a plugin's or module's own `server/migrations.json` — that's the `-- Add migration runner here` TODO you saw in `server/main.lua` back in Step 1. The `create_town_halls_table` migration written in Step 3 is generated and ready, but it will **not** run automatically as part of `TownHall` loading. Until a plugin-level migration runner exists, run it manually — e.g. from a one-off script (`require`/`load` the migration file and call its exported `up()` function) or by calling `up()` from the plugin's own startup code in `server/main.lua`.
:::
```

with:

```markdown
`core/server/bootstrap.lua`'s migration runner also covers every plugin and module listed in `plugins/registry.json`/`modules/registry.json` (which `make:plugin`/`make:module` keep up to date automatically). The `create_town_halls_table` migration written in Step 3 runs the same way core's own migrations do, no manual step needed.
```

- [ ] **Step 3: `docs/concepts/modules-and-plugins.md` — rewrite the plugin-manifest section**

Replace:

```markdown
### Plugin manifests

Plugins instead depend on the `obelisk` resource by name, since they build on globals (`BaseModel`, services) that core provides and must be started first. `plugins/oblsk_inventory/fxmanifest.lua`:

```lua
-- Requires the Obelisk core resource: it provides the shared globals this
-- plugin builds on (BaseModel/ORM, services) and must load first.
dependencies {
    'obelisk'
}
```

`make:plugin` generates the same `dependencies { 'obelisk' }` block for every new plugin.

::: warning `obelisk` isn't an actual resource name
This dependency references a resource named `obelisk`, but that's not how the framework is actually deployed today — the core resource is mounted and `ensure`d as `core` (see every `server.cfg` example in these docs). No resource is ever literally named `obelisk`, so `dependencies { 'obelisk' }` doesn't currently resolve to anything. This is a known naming inconsistency in the framework, not something you need to work around yourself.
:::
```

with:

```markdown
### Plugin manifests

Plugins don't have their own `fxmanifest.lua`. `make:plugin` scaffolds a plugin's directory tree (`server/`, `client/`, `shared/`, and for Vue-enabled plugins `web/`) and registers its name in `plugins/registry.json`; its scripts load as part of `core`'s own resource via the `plugins/*/...` globs in `core/fxmanifest.lua`, so `core`'s ORM and services (which every plugin depends on) are always loaded first, by construction, before this plugin's scripts run.
```

- [ ] **Step 4: Manual verification**

Run: `cd core && npm run docs:build` (or the equivalent VitePress build script from `package.json`) and confirm it completes without broken-link or build errors.

Grep for leftover references: `grep -rn "add your own compose mount\|dependencies { 'obelisk' }\|is not auto-run" docs/` from `core/` — should return nothing (aside from this plan file itself, if searched from repo root).

- [ ] **Step 5: Commit**

```bash
cd core
git add docs/guide/quick-start.md docs/examples/building-a-plugin.md docs/concepts/modules-and-plugins.md
git commit -m "docs: update modules/plugins docs for fold-into-core change"
```
