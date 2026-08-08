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
    details: A clear split between core-owned modules and third-party plugins, both scaffolded by the CLI and registered automatically so they load as part of core.
  - title: CLI generators
    details: 'obelisk make:module, make:plugin, make:model, make:migration, make:action, make:policy, and more — scaffolding that matches the framework''s own conventions.'
  - title: Docker-ready
    details: A docker-compose setup for FXServer plus MariaDB or PostgreSQL, with update scripts that pull the latest FXServer build for you.
---
