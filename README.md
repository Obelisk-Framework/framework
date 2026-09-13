# Obelisk Framework

[![CI](https://github.com/Obelisk-Framework/framework/actions/workflows/ci.yml/badge.svg)](https://github.com/Obelisk-Framework/framework/actions/workflows/ci.yml)
[![License: CC BY-NC 4.0](https://img.shields.io/badge/License-CC%20BY--NC%204.0-lightgrey.svg)](LICENSE)

A developer-first FiveM framework, built for the developer writing the plugin, not just the server owner running it. A dual-dialect Lua ORM, a module and plugin system, a Vue 3 NUI, and one CLI that scaffolds all of it to the same conventions core itself follows.

**[Read the docs →](https://obelisk-framework.github.io/docs/)**

## Features

- **Dual-dialect ORM** — an Eloquent-inspired ORM (models, query builder, migrations) that generates correct SQL for both MySQL/MariaDB and PostgreSQL, switchable via a single convar.
- **Modules & Plugins** — a clear split between core-owned modules and third-party plugins, both scaffolded by the CLI and registered automatically so they load as part of core.
- **CLI generators** — `obelisk make:module`, `make:plugin`, `make:model`, `make:migration`, `make:action`, `make:policy`, and more, all scaffolding to the framework's own conventions.
- **Docker-ready** — the infrastructure repo provides a `docker-compose` setup for MariaDB/PostgreSQL, with update scripts that pull the latest FXServer build for you.

## Key Concepts

### Interactions

Every position (`x`, `y`, `z`) on the map can be an interaction point. Each interaction has a polymorphic relationship, so it can belong to any entity — a garage, a shop, a storage container, anything.

Calling an interaction runs the following interface:

```lua
local function execute(player, interaction, data)

end

return execute
```

The database's `owner_type` column must match the Lua file's name — for garages that's `garage`, since the code that runs a garage interaction lives at `server/interactions/garage.lua`.

### Actions

Actions share the same interface as interactions:

```lua
local function execute(player, action, data)

end

return execute
```

The difference is that actions have no position and no data attached directly to them. An action can be called from anywhere in the UI, via a keybind, or from anywhere else in the script — the requestor is responsible for providing whatever data the `execute` interface needs.

### Policies

Zero or more policies can run before an interaction or action executes. A policy checks things like whether a player is in the right position, holds the right permission, or has an item in their inventory — the possibilities are open-ended.

To define a policy, add a file to `server/policies/` with the following interface:

```lua
local function check(player, data)
    return true
end

return check
```

If any policy returns `false`, the interaction or action is cancelled.

## Getting Started

```bash
git clone git@github.com:Obelisk-Framework/framework.git
cd framework
npm install
```

Full setup, module/plugin authoring, and CLI reference live in the **[documentation site](https://obelisk-framework.github.io/docs/)**.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for how to get set up, the coding conventions the CLI generators follow, and how to submit a pull request.

## Credits

- [screencapture](https://github.com/itschip/screencapture) by [itschip](https://github.com/itschip) — an inspiration for core's storage service and screenshot/video upload flow.

## Sponsoring

If Obelisk saves you time on your own server, consider supporting its development:

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=github-sponsors)](https://github.com/sponsors/Obelisk-Framework)

## License

This project is licensed under [CC BY-NC 4.0](LICENSE).

This license lets you distribute, remix, adapt, and build upon the material in any medium or format for **non-commercial purposes only**, provided you give appropriate credit:

- **BY** — credit must be given to the creator.
- **NC** — only non-commercial uses of the work are permitted.
