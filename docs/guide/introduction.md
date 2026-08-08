# Introduction

Obelisk is a framework for building [FiveM](https://fivem.net) (GTA V multiplayer) roleplay servers. The framework core is written in Lua, ships a Vue 3-based NUI for in-game UI, and persists data through a Node.js companion connector backed by either MySQL/MariaDB or PostgreSQL.

## Why Obelisk

FXServer's Lua sandbox has no real database driver, so Obelisk pairs its Lua ORM with a small Node.js HTTP sidecar (`oblsk_connector`) that actually talks to the database. The ORM itself supports both MySQL and PostgreSQL dialects behind one API — see [ORM](/concepts/orm) for how dialect selection works.

On top of that, the framework ships a CLI for scaffolding new code — models, migrations, actions, policies, and more — so new modules and plugins follow consistent conventions instead of being hand-rolled each time. See the [CLI Command Reference](/cli/index) for the full list of generators.

## The pieces

Obelisk is split across several resources and directories, each with a distinct role:

- **`core`** (this repository) — the main framework resource: the ORM, core services (hooks, actions, interactions, policies, notifications, progress, keybinds), and the CLI.
- **`oblsk_connector`** — a companion FiveM resource paired with a Node.js HTTP sidecar. It's the piece that actually issues queries against MySQL/MariaDB or PostgreSQL, since FXServer's Lua runtime can't load a native DB driver directly.
- **`modules/`** — first-party framework modules maintained alongside core, such as `oblsk_items` and `oblsk_vehicles`.
- **`plugins/`** — third-party or project-specific plugins that build on the framework, such as `oblsk_inventory` and `oblsk_character-selection`.
- **`core/web`** — the Vue 3 + Vite NUI application. It's built and its output is served in-game as the player-facing UI.

## Next steps

Continue to [Installation](/guide/installation) to set up a framework development environment or run an actual FiveM server.
