# Obelisk Docs Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A VitePress documentation site at `core/docs/` covering features, installation, core concepts, CLI reference, and one full example walkthrough, deployed to GitHub Pages via Actions.

**Architecture:** VitePress (markdown-in, static-site-out), content hand-written, deployed from a new path-filtered GitHub Actions workflow separate from the existing ORM-test CI.

**Tech Stack:** VitePress ^1.5.0, Node.js (already present in the repo's toolchain), GitHub Actions (`actions/upload-pages-artifact`, `actions/deploy-pages`).

## Global Constraints

- Site lives at `core/docs/` — a new, self-contained npm project (its own `package.json`), not merged into the root `core/package.json` or `core/web/package.json`.
- `core/web/` (the Vue 3 NUI app) is unrelated and must not be touched by this plan.
- VitePress `base` must be `'/core/'` (GitHub Pages serves this repo at `https://obelisk-framework.github.io/core/`, confirmed from the repo's `origin` remote `git@github.com:Obelisk-Framework/core.git`).
- `ignoreDeadLinks: false` must be set explicitly in `.vitepress/config.ts` so a broken internal link fails the build (and CI) rather than shipping silently.
- The deploy workflow must be path-filtered to `core/docs/**` (plus itself) so it doesn't retrigger on unrelated ORM/framework changes, and must NOT be merged into or replace the existing `.github/workflows/ci.yml`.
- **Known inventory of "existing plugins/modules" for reference content (verified by reading the actual repo, not assumed):** `oblsk_character-selection` (CLI-scaffolded: client/server/actions/web, real files) and `oblsk_inventory` (real `Inventory` model with fillable/casts/relationship-comments) both have real content and are the only two suitable as worked examples. `oblsk_banking`, `oblsk_garage`, `oblsk_items`, and `oblsk_vehicles` are currently **empty placeholder repos/directories** (no fxmanifest, no source files) — document them honestly as reserved/not-yet-implemented, do not invent content for them.
- Every content page must build cleanly: `npm run build` inside `core/docs/` exits 0 with no dead-link errors.

---

### Task 1: Scaffold the VitePress project

**Files:**
- Create: `core/docs/package.json`
- Create: `core/docs/.vitepress/config.ts`
- Create: `core/docs/index.md`
- Create: `core/docs/.gitignore`

**Interfaces:**
- Produces: a working `npm run dev` / `npm run build` / `npm run preview` in `core/docs/`. Later tasks add content files under the paths declared in this task's sidebar config — those paths are the contract later tasks must match exactly: `/guide/introduction`, `/guide/installation`, `/guide/quick-start`, `/concepts/orm`, `/concepts/services`, `/concepts/modules-and-plugins`, `/cli/index`, `/examples/building-a-plugin`, `/reference/existing-plugins`, `/plugin-hub`.

- [ ] **Step 1: Write `core/docs/package.json`**

```json
{
  "name": "obelisk-docs",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vitepress dev .",
    "build": "vitepress build .",
    "preview": "vitepress preview ."
  },
  "devDependencies": {
    "vitepress": "^1.5.0"
  }
}
```

- [ ] **Step 2: Write `core/docs/.gitignore`**

```
node_modules
.vitepress/dist
.vitepress/cache
```

- [ ] **Step 3: Write `core/docs/.vitepress/config.ts`**

```ts
import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Obelisk Framework',
  description: 'A modern FiveM framework with Lua, Vue 3, and MariaDB/PostgreSQL',
  base: '/core/',
  ignoreDeadLinks: false,

  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/introduction' },
      { text: 'Concepts', link: '/concepts/orm' },
      { text: 'CLI', link: '/cli/index' },
      { text: 'Examples', link: '/examples/building-a-plugin' },
      { text: 'Reference', link: '/reference/existing-plugins' },
      { text: 'Plugin Hub', link: '/plugin-hub' }
    ],

    sidebar: {
      '/guide/': [
        {
          text: 'Guide',
          items: [
            { text: 'Introduction', link: '/guide/introduction' },
            { text: 'Installation', link: '/guide/installation' },
            { text: 'Quick Start', link: '/guide/quick-start' }
          ]
        }
      ],
      '/concepts/': [
        {
          text: 'Concepts',
          items: [
            { text: 'ORM', link: '/concepts/orm' },
            { text: 'Services', link: '/concepts/services' },
            { text: 'Modules & Plugins', link: '/concepts/modules-and-plugins' }
          ]
        }
      ],
      '/cli/': [
        {
          text: 'CLI',
          items: [
            { text: 'Command Reference', link: '/cli/index' }
          ]
        }
      ],
      '/examples/': [
        {
          text: 'Examples',
          items: [
            { text: 'Building a Plugin', link: '/examples/building-a-plugin' }
          ]
        }
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'Existing Plugins', link: '/reference/existing-plugins' }
          ]
        }
      ]
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/Obelisk-Framework/core' }
    ]
  }
})
```

- [ ] **Step 4: Write `core/docs/index.md`**

```md
---
layout: home

hero:
  name: Obelisk Framework
  text: A modern FiveM framework
  tagline: Lua ORM with MySQL/PostgreSQL support, a module & plugin system, a Vue 3 NUI, and a CLI that scaffolds all of it.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/introduction
    - theme: alt
      text: View on GitHub
      link: https://github.com/Obelisk-Framework/core

features:
  - title: Dual-dialect ORM
    details: An Eloquent-inspired ORM (models, query builder, migrations) that generates correct SQL for both MySQL/MariaDB and PostgreSQL, switchable via a single convar.
  - title: Modules & Plugins
    details: A clear split between core-owned modules and third-party plugins, both scaffolded by the CLI with fxmanifest conventions baked in.
  - title: CLI generators
    details: 'obelisk make:module, make:plugin, make:model, make:migration, make:action, make:policy, and more — scaffolding that matches the framework''s own conventions.'
  - title: Docker-ready
    details: A docker-compose setup for FXServer plus MariaDB or PostgreSQL, with update scripts that pull the latest FXServer build for you.
---
```

- [ ] **Step 5: Install and verify the build**

Run from `core/docs/`:
```bash
npm install
npm run build
```
Expected: exits 0. The build will show a warning or error about missing pages referenced in the nav/sidebar (`/guide/introduction`, etc., don't exist yet) — that's expected at this step since no content pages exist yet. If VitePress errors (not just warns) on the missing pages due to `ignoreDeadLinks: false`, that's also expected here; subsequent tasks resolve it. Confirm the *only* build failures are "file does not exist" for the pages this plan's later tasks create — not a config/syntax error in `config.ts` itself. If the build reports a config or syntax problem unrelated to missing pages, fix it before proceeding.

- [ ] **Step 6: Commit**

```bash
cd core
git add docs/package.json docs/.gitignore docs/.vitepress/config.ts docs/index.md
git commit -m "docs(site): scaffold VitePress project"
```

---

### Task 2: GitHub Actions deploy workflow

**Files:**
- Create: `core/.github/workflows/docs.yml`

**Interfaces:**
- Consumes: `core/docs/package.json`'s `build` script (Task 1).
- Produces: nothing consumed by later tasks — this is a leaf, verifiable only by GitHub Actions syntax validity (no live deploy target exists yet, that's expected).

- [ ] **Step 1: Write `core/.github/workflows/docs.yml`**

```yaml
name: Deploy Docs

on:
  push:
    branches: [main]
    paths:
      - 'docs/**'
      - '.github/workflows/docs.yml'

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: docs
    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: docs/package-lock.json

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: docs/.vitepress/dist

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

Note: `npm ci` requires a committed `package-lock.json` — Task 1's `npm install` (run from `core/docs/`) generates one; confirm it was included in Task 1's commit (if it wasn't, add it now with `git add docs/package-lock.json` before continuing — don't regenerate it, use the one `npm install` already produced).

- [ ] **Step 2: Validate the workflow YAML**

Run from `core` (repo root):
```bash
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/docs.yml'))" && echo "valid YAML"
```
Expected: prints `valid YAML`, no exceptions. (This only checks YAML syntax, not GitHub Actions semantics — that's confirmed the first time this workflow actually runs on a push, which is outside this plan's scope to trigger.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/docs.yml docs/package-lock.json
git commit -m "docs(site): add GitHub Pages deploy workflow"
```

---

### Task 3: Guide — Introduction & Installation

**Files:**
- Create: `core/docs/guide/introduction.md`
- Create: `core/docs/guide/installation.md`

**Interfaces:**
- Consumes: nothing from earlier tasks except the VitePress scaffold (Task 1).
- Produces: the `/guide/introduction` and `/guide/installation` routes the nav (Task 1) already links to.

- [ ] **Step 1: Write `core/docs/guide/introduction.md`**

Must cover, accurately reflecting the actual repo (verified facts to include, not invented):
- What Obelisk is: a FiveM (GTA V multiplayer) framework built in Lua, with a Vue 3-based NUI and a Node.js/MySQL or Node.js/Postgres companion connector.
- The high-level pieces, each named exactly as they exist in the repo, with a one-sentence role for each:
  - `core` — the main framework resource (this repo): ORM, services, CLI.
  - `oblsk_connector` — a companion FiveM resource + Node.js HTTP sidecar that actually talks to the database (MySQL or Postgres), since FXServer's Lua sandbox can't use a real DB driver directly.
  - `modules/` — first-party framework modules (e.g. `oblsk_items`, `oblsk_vehicles`).
  - `plugins/` — third-party/project-specific plugins (e.g. `oblsk_inventory`, `oblsk_character-selection`).
  - `core/web` — the Vue 3 + Vite NUI app, compiled into `core/html` and served as the in-game UI.
- A short "why" paragraph: the ORM's dual MySQL/Postgres support (link forward to `/concepts/orm`), the CLI's scaffolding (link forward to `/cli/index`).
- End with a "Next steps" section linking to `/guide/installation`.

- [ ] **Step 2: Write `core/docs/guide/installation.md`**

Must cover two real, verified installation paths — do not invent commands, use exactly what exists in the repo:

**Path A — Framework development (npm + CLI):**
```bash
cd core
npm install
node cli/index.js --help
```
Mention the global-link option:
```bash
chmod +x cli/index.js
npm link
obelisk --help
```
Note that CLI-generated files are written relative to the current working directory, so `obelisk make:module`/`make:plugin` must be run from inside `core/`.

**Path B — Running an actual FiveM server (Docker):**
Reference the real files at the repository root (one level above `core/`): `docker-compose.yml`, `docker/fivem/Dockerfile`, `docker/fivem/entrypoint.sh`, `scripts/update-fivem-server.sh` / `.bat`, `server-data/server.cfg`. Document the real sequence:
```bash
# from the repo root (one level above core/)
scripts/update-fivem-server.sh        # or scripts\update-fivem-server.bat on Windows
docker compose up --build
```
Note: `server-data/server.cfg` needs a real `sv_licenseKey` (from https://keymaster.fivem.net) before the server will run, and that MariaDB is the default DB backend — switching to Postgres means setting `db_driver "postgres"` in `server.cfg` and starting the `postgres` compose service instead (`docker compose --profile postgres up postgres fxserver`) — do not start both `mariadb` and `postgres` at once. Link to `/concepts/orm#dialects` (a heading Task 5 will add — use that anchor exactly, do not invent a different one) for detail on `db_driver`.

Read `/home/andi/Projects/obelisk-framework/docker-compose.yml`, `/home/andi/Projects/obelisk-framework/docker/fivem/entrypoint.sh`, and `/home/andi/Projects/obelisk-framework/server-data/server.cfg` directly before writing this page, so the documented commands/flags match what's actually there (these files live outside this git repo, at the workspace root, but you have filesystem access to read them for accuracy).

- [ ] **Step 3: Build check**

Run from `core/docs/`: `npm run build`. Expected: no dead-link errors for `/guide/introduction` or `/guide/installation` specifically (other pages may still be missing — that's fine at this step, VitePress reports each broken link individually, only fix ones pointing at pages this task created; broken links to not-yet-created pages from other tasks are still expected to fail here — that's fine, don't chase them).

- [ ] **Step 4: Commit**

```bash
git add docs/guide/introduction.md docs/guide/installation.md
git commit -m "docs(site): add introduction and installation guides"
```

---

### Task 4: Guide — Quick Start

**Files:**
- Create: `core/docs/guide/quick-start.md`

**Interfaces:**
- Consumes: the CLI commands documented in Task 3's installation page (same commands, don't redefine them differently).
- Produces: the `/guide/quick-start` route.

- [ ] **Step 1: Write `core/docs/guide/quick-start.md`**

The shortest real path from zero to a visible result, using only commands verified to exist:
```bash
cd core
npm install
npm run cli -- make:module MyFeature
```
(Note: `npm run cli` is the `package.json` script `"cli": "node cli/index.js"` already present in `core/package.json` — confirm this by reading `core/package.json` before writing the page; use whichever of `npm run cli -- make:module` or `node cli/index.js make:module` you confirm actually works, don't guess.)

Walk through: the interactive prompts `make:module` asks (module name if not passed, then a checkbox feature list: Database Model, Database Migration, Database Seeder, Actions, Interactions, Keybinds, Policies, Vue Component, Client Services, Server Services — read `core/cli/commands/make-module.js` to confirm this exact list before writing it), what gets generated (`modules/MyFeature/fxmanifest.lua`, `README.md`, and one file per selected feature), and where to add `ensure MyFeature` in `server.cfg` to load it. End with links to `/concepts/modules-and-plugins` and `/examples/building-a-plugin` for more depth.

- [ ] **Step 2: Build check**

Run from `core/docs/`: `npm run build`. Confirm no dead-link error for `/guide/quick-start`.

- [ ] **Step 3: Commit**

```bash
git add docs/guide/quick-start.md
git commit -m "docs(site): add quick start guide"
```

---

### Task 5: Concepts — ORM & Services

**Files:**
- Create: `core/docs/concepts/orm.md`
- Create: `core/docs/concepts/services.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the `/concepts/orm` route, including a `## Dialects` heading with the exact anchor `dialects` (i.e. the heading text must be literally `Dialects` so VitePress generates `#dialects`) — Task 3's installation page already links to `/concepts/orm#dialects` and depends on this exact anchor existing. Also produces `/concepts/services`.

- [ ] **Step 1: Write `core/docs/concepts/orm.md`**

Cover, with real code snippets pulled from the actual source (read `core/server/ORM/BaseModel.lua`, `core/server/ORM/QueryBuilder.lua`, `core/server/ORM/Schema.lua`, `core/server/ORM/Database.lua` directly before writing — don't reconstruct from memory, the exact method names/signatures matter):

- **Models** (`BaseModel`): defining a model (`Model = BaseModel:extend('table_name')`), `primaryKey`, `timestamps`, `fillable`, `hidden`, `casts` (mention `'json'` cast, matching the real `Inventory` model's `metadata = 'json'` pattern — read `plugins/oblsk_inventory/server/models/Inventory.lua` for a real, working example to quote). Cover `find`/`findSync`, `save`/`saveSync` (create vs update), `delete`/`deleteSync`. Cover relationship helpers (`belongsTo` at minimum — check `BaseModel.lua` for what's actually implemented and only document what exists).
- **Query Builder** (`QueryBuilder`): the fluent API — `where`, `orWhere`, `whereIn`, `whereNull`, `orderBy`, `limit`, `join`, `selectRaw`, `insert`, `update`, `delete`, `count`/`countSync`. One realistic snippet combining several (e.g. a `where` + `orderBy` + `limit` chain).
- **Schema & Migrations** (`Schema`, `Blueprint`): `Schema.create(tableName, callback)` with a `Blueprint` example showing `id()`, `string()`, `integer()`, `boolean()`, `timestamps()`, `index()`/`unique()`, matching the actual method names in `core/server/ORM/Schema.lua`. Mention migrations live under a module/plugin's `server/migrations/` directory (matching the CLI generator's output path).
- **## Dialects** (exact heading, see Interfaces above): MySQL/MariaDB is the default; PostgreSQL is supported via the `db_driver` convar (`"mysql"` or `"postgres"`, default `"mysql"`), which must be set explicitly — it is not inferred from the connection string. Note `db_driver postgres` requires `oblsk_connector` as the active connector (fails fast otherwise). Keep this section short — it's a pointer, not a re-explanation of the whole dialect-abstraction internals.

- [ ] **Step 2: Write `core/docs/concepts/services.md`**

Read `core/fxmanifest.lua`'s `server_scripts` section first to confirm the exact list and order of core services (`Hooks.lua`, `ActionService.lua`, `InteractionService.lua`, `PolicyService.lua`, `NotificationService.lua`, `ProgressService.lua`, `KeybindService.lua`), then read each corresponding file under `core/server/Services/` for its real public API before writing its section — do not invent method names.

Cover, one subsection per service:
- **ActionService** — `ActionService.register(actionId, handler, options)`, `ActionService.execute(source, actionId, data)`.
- **InteractionService** — read `core/server/Services/InteractionService.lua` for its real registration/trigger API and document that.
- **PolicyService** — composable authorization; mention it's backed by `action_policy`/`interaction_policy` pivot tables, read the file for its real registration/check API.
- **NotificationService** — read the file; document at minimum the pattern already visible in `plugins/oblsk_character-selection/server/actions/ExampleAction.lua` (`NotificationService.success(source, title, message)`), confirm the exact signature against the service source.
- **ProgressService**, **KeybindService** — read each file, document its real public API.

End with a brief note: additional services (`BlipService`, `DeathService`, `EntityStreamerService`, `MarkerService`, `PedService`) exist under `core/server/Services/` and load automatically via the fxmanifest's wildcard — not detailed here, mentioned so readers know they exist.

- [ ] **Step 3: Build check**

Run from `core/docs/`: `npm run build`. Confirm no dead-link errors for `/concepts/orm` or `/concepts/services`, and confirm the `#dialects` anchor exists (VitePress will only flag this if something links to a wrong anchor — Task 3 already links to `/concepts/orm#dialects`, so a passing build here confirms the anchor matches).

- [ ] **Step 4: Commit**

```bash
git add docs/concepts/orm.md docs/concepts/services.md
git commit -m "docs(site): add ORM and Services concept pages"
```

---

### Task 6: Concepts — Modules & Plugins, and CLI Reference

**Files:**
- Create: `core/docs/concepts/modules-and-plugins.md`
- Create: `core/docs/cli/index.md`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `/concepts/modules-and-plugins` and `/cli/index` routes.

- [ ] **Step 1: Write `core/docs/concepts/modules-and-plugins.md`**

Cover:
- The directory split: `modules/` (first-party, framework-owned) vs `plugins/` (third-party/project-specific) — both are FiveM resources with their own `fxmanifest.lua`.
- `fxmanifest.lua` conventions: `dependencies { 'obelisk' }` (or `/server:5848`, `/onesync` for core itself — check `core/fxmanifest.lua` and `plugins/oblsk_inventory/fxmanifest.lua` for the real, current pattern each uses and document both, since they differ — `oblsk_inventory`'s manifest depends on `'obelisk'` by name, not the FXServer build/onesync pair core itself declares), `server_scripts`/`client_scripts` glob patterns, and the `web/*.vue` + `web/routes.js` convention for plugins with a Vue UI (read `plugins/oblsk_inventory/fxmanifest.lua`'s comment about this — it explains the build-time glob core uses to pick up plugin routes, quote it accurately).
- How the CLI scaffolds both (cross-reference `/cli/index`, don't duplicate the full command reference here).

- [ ] **Step 2: Write `core/docs/cli/index.md`**

Read `core/cli/index.js` for the full, real command list (currently: `make:module`, `make:plugin`, `make:model`, `make:migration`, `make:seeder`, `make:action`, `make:interaction`, `make:policy`) and read each corresponding file in `core/cli/commands/` for what it actually prompts for and generates — do not guess prompts, quote the real `inquirer` prompt messages/choices.

Structure: one `##` heading per command, each with:
- Usage: `` obelisk make:module [name] `` (or the real signature from `index.js`)
- What it prompts for if `name` is omitted
- What it generates (file paths, relative to where the command is run)
- A short example invocation and its output tree

Also document, near the top of the page: the two ways to run the CLI —
```bash
node cli/index.js make:module MyModule
```
or, after `npm link` (see `/guide/installation`):
```bash
obelisk make:module MyModule
```
— and the fact that generated paths are relative to the current working directory, so these must be run from inside `core/`.

- [ ] **Step 3: Build check**

Run from `core/docs/`: `npm run build`. Confirm no dead-link errors for `/concepts/modules-and-plugins` or `/cli/index`.

- [ ] **Step 4: Commit**

```bash
git add docs/concepts/modules-and-plugins.md docs/cli/index.md
git commit -m "docs(site): add modules/plugins concept page and CLI reference"
```

---

### Task 7: Examples — Building a Plugin (full walkthrough)

**Files:**
- Create: `core/docs/examples/building-a-plugin.md`

**Interfaces:**
- Consumes: commands and concepts documented in Tasks 3-6 — cross-link to them (`/guide/installation`, `/concepts/orm`, `/concepts/services`, `/cli/index`) rather than re-explaining, but the commands shown here must be consistent with those pages (same CLI invocation style, same terminology).
- Produces: the `/examples/building-a-plugin` route.

- [ ] **Step 1: Write `core/docs/examples/building-a-plugin.md`**

An end-to-end tutorial, each step runnable and consistent with the CLI's real behavior (verify against `core/cli/commands/make-plugin.js` and `core/cli/commands/make-model.js`/`make-migration.js`/`make-action.js`/`make-policy.js` before writing each step — quote real prompts, real generated file paths):

1. **Scaffold the plugin**: `obelisk make:plugin TownHall` (or `node cli/index.js make:plugin TownHall`), walk through its prompts (read `make-plugin.js` for the real ones — it asks for a description at minimum, confirm what else).
2. **Add a model**: `obelisk make:model TownHall` or however `make-model.js` actually names/places it — read the file, don't assume it matches `make-module.js`'s embedded generator. Show the generated model file's real shape.
3. **Write a migration**: via `obelisk make:migration`, show a realistic `Schema.create` blueprint for a `town_halls` table (columns: `id`, a `name` string, a `mayor` string, `timestamps()`), consistent with the `Schema`/`Blueprint` API documented in `/concepts/orm`.
4. **Add an action**: via `obelisk make:action`, show `ActionService.register(...)` wiring consistent with `/concepts/services`.
5. **Add a policy**: via `obelisk make:policy`, show a minimal authorization check consistent with `/concepts/services`'s PolicyService section.
6. **Load it**: add `ensure TownHall` to `server.cfg` (cross-reference the real `server-data/server.cfg` structure from `/guide/installation`), restart, confirm the plugin's startup print statement appears in the server console (matching the real generated boilerplate's `print('[...] Loading...')`/`print('[...] Loaded successfully!')` pattern seen in `plugins/oblsk_character-selection/server/main.lua` — read that file as a reference for what CLI-generated server/main.lua boilerplate actually prints).

End with a "What's next" section linking to `/reference/existing-plugins` for two real, more fleshed-out examples.

- [ ] **Step 2: Build check**

Run from `core/docs/`: `npm run build`. Confirm no dead-link errors for `/examples/building-a-plugin`.

- [ ] **Step 3: Commit**

```bash
git add docs/examples/building-a-plugin.md
git commit -m "docs(site): add building-a-plugin walkthrough"
```

---

### Task 8: Reference — Existing Plugins, Plugin Hub stub, and final verification

**Files:**
- Create: `core/docs/reference/existing-plugins.md`
- Create: `core/docs/plugin-hub.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: `/reference/existing-plugins` and `/plugin-hub` routes — the last two routes the Task 1 nav/sidebar links to, so after this task every nav link resolves to a real page.

- [ ] **Step 1: Write `core/docs/reference/existing-plugins.md`**

Per the Global Constraints' verified inventory — do NOT invent content for the empty ones:

- **`oblsk_character-selection`** (real content — read `plugins/oblsk_character-selection/fxmanifest.lua`, `server/main.lua`, `server/actions/ExampleAction.lua`, `shared/config.lua`, and the `web/*.vue` file list before writing): describe it as a CLI-scaffolded plugin demonstrating the actions + Vue-UI feature combo, quote its real action registration and the `NotificationService.success(...)` call from `ExampleAction.lua`, link to its source path.
- **`oblsk_inventory`** (real content — read `plugins/oblsk_inventory/fxmanifest.lua` and `server/models/Inventory.lua` before writing): describe it as demonstrating a real `BaseModel` with `fillable`/`casts`/commented-out relationship examples, quote the model's `fillable` list and its `isEmpty()` method, link to its source path.
- **Reserved/not-yet-implemented**: list `oblsk_banking`, `oblsk_garage`, `modules/oblsk_items`, `modules/oblsk_vehicles` as reserved names with no implementation yet — one line each, honest about their empty state, no invented feature descriptions. Do not present these as usable examples.

- [ ] **Step 2: Write `core/docs/plugin-hub.md`**

A short "coming soon" stub page — one or two paragraphs: a plugin hub (a registry/directory for browsing and publishing community plugins) is planned as a separate project, not yet built. No fabricated feature list or timeline — just an honest placeholder. Link back to `/reference/existing-plugins` for what's available today.

- [ ] **Step 3: Full build and preview verification**

Run from `core/docs/`:
```bash
npm run build
```
Expected: exits 0, **zero** dead-link errors (every route the Task 1 nav/sidebar config references now has a real page — this is the first task where the build should be fully clean end-to-end).

Then run:
```bash
npm run preview
```
and manually click through the nav (Guide, Concepts, CLI, Examples, Reference, Plugin Hub) plus every sidebar entry, confirming each page renders (headings present, no obviously broken markdown, code blocks render as code blocks not raw text). Stop the preview server when done.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/existing-plugins.md docs/plugin-hub.md
git commit -m "docs(site): add existing-plugins reference and plugin-hub stub; site content complete"
```
