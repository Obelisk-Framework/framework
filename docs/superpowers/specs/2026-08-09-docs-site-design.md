# Obelisk Docs Site

## Goal

A documentation site for Obelisk Framework covering what it offers,
installation (both npm/CLI and the Docker-based FiveM server setup),
core concepts, CLI reference, and a full worked example — so newcomers
have somewhere to land besides reading source. Built with VitePress,
living at `core/docs/`, deployed to GitHub Pages via GitHub Actions.

## Background

The framework currently has no docs beyond scattered `README.md` files
(`web/README.md` is Vite boilerplate; `tests/README.md` covers the test
runner; `plugins/oblsk_character-selection/README.md` is plugin-specific).
There's a working `obelisk` CLI (`core/cli/`) with generators for
modules, plugins, models, migrations, seeders, actions, interactions,
and policies, and four real plugins (`oblsk_banking`, `oblsk_garage`,
`oblsk_inventory`, `oblsk_character-selection`) plus two modules
(`oblsk_items`, `oblsk_vehicles`) that can serve as real-world examples.
The ORM supports MySQL/MariaDB and PostgreSQL via a dialect abstraction
(`core/server/ORM/Dialects/`), and there's a Docker-based FiveM server
setup (root `docker-compose.yml`, `scripts/update-fivem-server.*`) — both
need to be documented as installation paths.

`core/web/` is a separate Vue 3 + Vite app that builds the in-game NUI
(`core/html/`) — unrelated to this docs site, not reused, not touched.

## Architecture

VitePress, chosen because the repo already uses Vue/Vite elsewhere, the
content is markdown (low-maintenance), and VitePress ships nav/sidebar/
local search out of the box — no hand-rolled site chrome needed.

### Directory layout

```
core/docs/
  package.json            -- vitepress dependency, dev/build/preview scripts
  .vitepress/
    config.ts              -- site title/description, nav, sidebar, base path
  index.md                 -- landing page: hero + feature grid
  guide/
    introduction.md        -- what Obelisk is, high-level architecture
    installation.md        -- npm/CLI setup AND Docker setup (compose, update scripts)
    quick-start.md         -- fastest path: install -> scaffold a module -> run it
  concepts/
    orm.md                 -- BaseModel, QueryBuilder, Schema/migrations, MySQL/Postgres dialects
    services.md             -- Actions, Interactions, Policies, Notifications, Progress, Keybinds
    modules-and-plugins.md  -- module vs plugin distinction, fxmanifest conventions
  cli/
    index.md                -- obelisk CLI reference: every make:* command, flags, prompts
  examples/
    building-a-plugin.md    -- full walkthrough: scaffold -> model -> migration -> action -> policy -> test
  reference/
    existing-plugins.md     -- tour of the four real plugins as worked examples
```

### Content sourcing

Hand-written Markdown for this version. No auto-generated API reference
from the Lua doc comments already present in the ORM source (`--- @param`
style annotations exist and could feed a generator later) — that's a
real, separate feature, explicitly deferred, not built here.

### Nav

Top nav: **Guide** / **Concepts** / **CLI** / **Examples** / **Reference**,
plus a **Plugin Hub** entry linking to a static "coming soon" page. The
actual plugin hub is a separate spec/build; this just reserves its spot
in the nav so the site doesn't need restructuring when that lands.

### Deployment

New `.github/workflows/docs.yml`:
- Triggers on push to `main`, path-filtered to `core/docs/**` (and the
  workflow file itself) so unrelated ORM/framework changes don't
  retrigger a docs deploy.
- Builds with `npm ci && npm run build` inside `core/docs/`.
- Deploys the built `core/docs/.vitepress/dist` via
  `actions/upload-pages-artifact` + `actions/deploy-pages`.
- VitePress `base` in `.vitepress/config.ts` set to match the Pages URL
  path (`/core/` if served from `<org>.github.io/core/`, adjusted once
  the actual Pages URL is confirmed).

This is a second, independent workflow from the existing
`.github/workflows/ci.yml` (ORM unit tests) — they don't share triggers
or steps.

## Content Plan (what each page covers)

- **index.md** — hero section (name, one-line pitch), feature grid
  (ORM w/ dual-dialect support, module/plugin system, CLI generators,
  Vue 3 NUI tooling, Docker-based server setup), links into the guide.
- **guide/introduction.md** — what Obelisk is (a FiveM framework), why
  it exists, high-level architecture diagram-in-prose (core resource,
  oblsk_connector, modules, plugins, web/NUI).
- **guide/installation.md** — two paths: (a) `npm install` + `obelisk`
  CLI for framework development, (b) the Docker setup (root
  `docker-compose.yml`, `scripts/update-fivem-server.sh`/`.bat`) for
  running an actual FiveM server. Cross-links to `cli/index.md` and to
  the Docker files' existing inline comments rather than duplicating
  every detail.
- **guide/quick-start.md** — shortest path from zero to a running,
  visible change: install, `obelisk make:module`, start the server,
  see it load.
- **concepts/orm.md** — `BaseModel` (fillable, casts, timestamps,
  relations), `QueryBuilder` (fluent API, `where`/`orderBy`/`limit`/
  `insert`/`update`/`delete`), `Schema`/migrations (Blueprint column
  types, indexes), the MySQL/Postgres dialect split and `db_driver`
  convar. Code snippets throughout, pulled from real patterns already
  used in `oblsk_banking`/`oblsk_inventory`.
- **concepts/services.md** — the Services layer (`ActionService`,
  `InteractionService`, `PolicyService`, `NotificationService`,
  `ProgressService`, `KeybindService`), what each is for, a snippet per
  service.
- **concepts/modules-and-plugins.md** — the distinction the CLI already
  encodes (modules vs plugins directories), `fxmanifest.lua`
  conventions, dependency declarations.
- **cli/index.md** — every `obelisk make:*` command: what it prompts
  for, what it generates, where output lands. Documents the `npm link`
  path for a global `obelisk` command.
- **examples/building-a-plugin.md** — the one full tutorial: scaffold a
  plugin via the CLI, add a model, write a migration, add an action, add
  a policy, verify it loads. Ties every concept page together.
- **reference/existing-plugins.md** — short tour of each real plugin
  (`oblsk_banking`, `oblsk_garage`, `oblsk_inventory`,
  `oblsk_character-selection`) — what it does, which framework features
  it demonstrates, pointer to its source.

## Error Handling / Edge Cases

Not much applies to a static docs site. The one operational concern:
the Actions workflow's path filter must include the workflow file
itself (standard GitHub Actions gotcha — editing the workflow doesn't
trigger itself otherwise when you also change the filter).

## Testing

No automated tests for content. Verification is: `npm run build` inside
`core/docs/` succeeds (VitePress fails the build on broken internal
links via `ignoreDeadLinks: false`, which should be enabled explicitly
in `.vitepress/config.ts` so a broken cross-reference fails CI rather
than shipping silently), and a manual pass through the built site
(`npm run preview`) before considering it done.

## Out of Scope

- Plugin hub (separate spec).
- Auto-generated API reference from Lua doc comments.
- Versioned docs / multiple framework versions.
- Search beyond VitePress's built-in local search.
- i18n / translations.
