# Modules & Plugins

Obelisk splits everything that isn't the core framework into two directory trees: `modules/` and `plugins/`. Both hold ordinary FiveM resources — each with its own `fxmanifest.lua` — but they mean different things and are treated differently.

- `modules/` — first-party, framework-owned functionality. Code that ships as part of Obelisk itself (or is developed as if it were core code) lives here.
- `plugins/` — third-party or project-specific resources. This is where `oblsk_inventory` and anything you or the community build on top of Obelisk lives.

The distinction is about ownership and dependency direction, not capability: a module and a plugin can both define models, migrations, actions, interactions, and policies. The CLI's `make:*` commands (see [`/cli/index`](/cli/index)) even ask you to pick a location — `Core`, `Module`, or `Plugin` — for most generators, and scaffold into `modules/<Name>/` or `plugins/<Name>/` accordingly.

## `fxmanifest.lua` conventions

Every module and plugin is a real FiveM resource, so it needs a real `fxmanifest.lua`. The `dependencies {}` block is where core and plugins diverge.

### Core's own manifest

The root `fxmanifest.lua` (the core resource itself) declares its dependency on the FXServer build and OneSync, not on another resource by name:

```lua
-- Dependencies
dependencies {
    '/server:5848',
    '/onesync'
}
```

`make:module` reuses this exact pattern for generated modules, since a module is expected to load as part of core:

```lua
-- Module dependencies
dependencies {
    '/server:5848',
    '/onesync'
}
```

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

### Script globs

Both core and generated modules/plugins use FiveM's glob patterns to list scripts, e.g. core's:

```lua
server_scripts {
    'core/server/ORM/Dialects/Init.lua',
    -- ...
    'core/server/Services/*.lua',
    'core/server/Models/**/*.lua',
    'core/server/Policies/**/*.lua',
    'core/server/bootstrap.lua'
}
```

A generated module or plugin is simpler, typically just `server/**/*.lua`, `client/**/*.lua`, and `shared/**/*.lua` (see `make:module` and `make:plugin` in [`/cli/index`](/cli/index) for the exact generated content).

## The `web/*.vue` + `web/routes.js` convention

Plugins that ship a Vue UI don't declare their own `ui_page`. Instead they list their Vue files under `files {}` so the resource ships them, and core's build picks the routes up at build time via a glob over `plugins/*/web/routes.js`. `plugins/oblsk_inventory/fxmanifest.lua` documents this directly:

```lua
-- The Vue UI (web/*.vue, web/routes.js) is compiled into the core bundle at
-- build time via core's router glob (plugins/*/web/routes.js), so this plugin
-- does not declare its own ui_page. These files are listed only so they ship
-- with the resource.
files {
    'web/*.vue',
    'web/routes.js',
}
```

In practice this means: a plugin's Vue components and its `routes.js` route table live under `<plugin>/web/`, core's build tooling globs every `plugins/*/web/routes.js` to assemble the combined Vue Router config, and the plugin's `fxmanifest.lua` only needs `files {}` entries so FXServer actually ships those source files with the resource — there's no per-plugin `ui_page` or separate web server to run.

`make:plugin` reflects a lighter version of this when you opt into the "Vue UI Page" feature: it scaffolds a `web/` directory with a Vite + Vue 3 + Tailwind `package.json` and a starter `.vue` component, and (for that generator) sets `ui_page 'web/dist/index.html'` plus a `files { 'web/dist/**/*' }` block, since a standalone generated plugin doesn't yet participate in core's combined build glob the way `oblsk_inventory` does.

## Scaffolding with the CLI

You don't hand-write any of the above — `obelisk make:module` and `obelisk make:plugin` generate the directory structure, `fxmanifest.lua`, and optional feature files (models, migrations, seeders, actions, services, Vue UI, etc.) interactively. See [`/cli/index`](/cli/index) for the full command reference, including every prompt and generated file path.
