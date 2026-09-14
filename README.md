<div align="center">
  <img alt="Obelisk Framework" src="assets/logo.png" width="180" height="180">

# Obelisk Framework

**A developer-first framework for building FiveM roleplay servers.**

Lua at the core. Vue 3 in the interface. MySQL/MariaDB and PostgreSQL behind one ORM.

[![CI](https://github.com/Obelisk-Framework/framework/actions/workflows/ci.yml/badge.svg)](https://github.com/Obelisk-Framework/framework/actions/workflows/ci.yml)
[![License: CC BY-NC 4.0](https://img.shields.io/badge/license-CC%20BY--NC%204.0-8b5cf6.svg)](https://github.com/Obelisk-Framework/framework/blob/main/LICENSE)
[![FiveM](https://img.shields.io/badge/platform-FiveM-f40552.svg)](https://fivem.net/)
[![Lua](https://img.shields.io/badge/core-Lua%205.4-2c2d72.svg?logo=lua&logoColor=white)](https://www.lua.org/)
[![Vue.js](https://img.shields.io/badge/NUI-Vue%203-42b883.svg?logo=vuedotjs&logoColor=white)](https://vuejs.org/)

[Get started](#quick-start) · [Documentation](https://obelisk-framework.github.io/docs/) · [Framework source](https://github.com/Obelisk-Framework/framework) · [Discussions](https://github.com/Obelisk-Framework/framework/discussions)
</div>

---

Obelisk gives FiveM developers a consistent foundation for data, game logic, UI, and extensions. Its conventions are shared by the framework itself, the CLI, first-party modules, and community plugins, so features remain familiar as a server grows.

## Why Obelisk?

- **One ORM, two SQL dialects** — use an Eloquent-inspired model and query API with either MySQL/MariaDB or PostgreSQL.
- **Composable modules and plugins** — keep first-party domains separate from optional or project-specific features without inventing a new structure for each resource.
- **Actions, interactions, and policies** — model player capabilities, world interaction points, and reusable authorization checks through focused interfaces.
- **A modern in-game UI** — build NUI experiences with Vue 3 and Vite, connected to Lua through Obelisk's WebView layer.
- **Convention-driven generators** — scaffold modules, plugins, models, migrations, seeders, actions, interactions, and policies from one CLI.
- **Repeatable local infrastructure** — run FXServer, the connector, and either MariaDB or PostgreSQL through Docker Compose.

## Architecture

```text
FiveM client                         FXServer
┌──────────────────┐                ┌─────────────────────────────┐
│ Vue 3 NUI        │◀── WebView ──▶│ Lua services               │
│ player interface │                │ actions · policies · ORM    │
└──────────────────┘                └──────────────┬──────────────┘
                                                   │ HTTP
                                    ┌──────────────▼──────────────┐
                                    │ oblsk_connector             │
                                    │ MySQL/MariaDB · PostgreSQL  │
                                    └─────────────────────────────┘
```

| Project | Purpose |
| --- | --- |
| [`framework`](https://github.com/Obelisk-Framework/framework) | Core Lua resource, ORM, services, Vue NUI, and CLI |
| [`infrastructure`](https://github.com/Obelisk-Framework/infrastructure) | Docker Compose stack, FXServer setup scripts, and server configuration |
| [`oblsk_connector`](https://github.com/Obelisk-Framework/oblsk_connector) | Database bridge between FXServer's Lua runtime and SQL backends |
| [`oblsk_items`](https://github.com/Obelisk-Framework/oblsk_items) | First-party item domain module |
| [`oblsk_vehicles`](https://github.com/Obelisk-Framework/oblsk_vehicles) | First-party vehicle domain module |
| [`docs`](https://github.com/Obelisk-Framework/docs) | Guides, concepts, examples, and API reference |

## Quick start

### Requirements

- [Git](https://git-scm.com/)
- [Docker](https://docs.docker.com/get-docker/) with Compose
- Node.js and npm for the connector
- A [FiveM server license key](https://keymaster.fivem.net/)

### Run a local server

The runtime stack lives in the [`infrastructure`](https://github.com/Obelisk-Framework/infrastructure) repository. Clone it, then add the framework and connector resources at the paths expected by Docker Compose:

```bash
git clone https://github.com/Obelisk-Framework/infrastructure.git
cd infrastructure

git clone https://github.com/Obelisk-Framework/framework.git core
git clone https://github.com/Obelisk-Framework/oblsk_connector.git oblsk_connector
npm ci --prefix oblsk_connector

cp server.cfg.example server.cfg
```

Add your `sv_licenseKey` to `server.cfg`, then start FXServer with MariaDB:

```bash
docker compose --profile mariadb up --build mariadb fxserver
```

To use PostgreSQL instead, set `db_driver "postgres"` and the PostgreSQL connection string in `server.cfg`, then run:

```bash
docker compose --profile postgres up --build postgres fxserver
```

For the current setup guidance, see the [installation guide](https://obelisk-framework.github.io/docs/guide/installation.html).

## Build with the CLI

Install the framework's development dependencies, then inspect the available generators:

```bash
npm install
npm run cli -- --help
```

Create a module using the framework's standard layout:

```bash
npm run cli -- make:module MyFeature
npm run cli -- registry:generate
```

Other generators include:

```text
make:plugin       make:model         make:migration
make:seeder       make:action        make:interaction
make:policy
```

Read the [quick-start guide](https://obelisk-framework.github.io/docs/guide/quick-start.html) for the generated structure and loading workflow.

## Core concepts

### ORM

Models, relationships, query building, schemas, migrations, and transactions share one Lua API. The configured `db_driver` selects the SQL dialect, while `oblsk_connector` performs the database I/O outside FXServer's Lua sandbox.

### Actions and interactions

An **action** can be invoked from UI, a keybind, or another script. An **interaction** associates behavior with a position or entity in the game world. Both use a small execution contract:

```lua
local function execute(player, subject, data)
    -- Perform the action or interaction.
end

return execute
```

### Policies

Policies are reusable checks evaluated before an action or interaction runs. They can enforce distance, permissions, cooldowns, inventory requirements, or project-specific rules.

```lua
local function check(player, data)
    return true
end

return check
```

If any attached policy returns `false`, execution is cancelled.

### Modules and plugins

Modules contain first-party domain behavior maintained with the framework. Plugins provide optional, third-party, or server-specific functionality. Both follow the same conventions and load as part of the core resource.

## Development

```bash
# Framework and Lua tests (requires Lua 5.4)
npm test

# Vue NUI
cd web
npm install
npm run dev
npm run build
```

Runtime behavior that depends on FiveM natives, network events, NUI, or real database I/O should also be verified on a running server.

## Contributing

Contributions are welcome. Before opening a pull request:

1. Fork [`Obelisk-Framework/framework`](https://github.com/Obelisk-Framework/framework) and branch from `main`.
2. Follow the existing module, plugin, and service conventions.
3. Add or update relevant tests.
4. Run `npm test` and verify runtime changes on FXServer where applicable.
5. Describe what changed, why it changed, and any environment requirements in the pull request.

See the framework's [contribution guide](https://github.com/Obelisk-Framework/framework/blob/main/CONTRIBUTING.md) for complete details. Bugs and feature requests can be submitted through [GitHub Issues](https://github.com/Obelisk-Framework/framework/issues).

## License

The framework is distributed under the [Creative Commons Attribution-NonCommercial 4.0 International license](https://github.com/Obelisk-Framework/framework/blob/main/LICENSE). You may share and adapt it with attribution for non-commercial purposes. Review the full license before redistributing or building on the project.

---

<div align="center">
  <strong>Build your world on a foundation made for developers.</strong>
</div>
