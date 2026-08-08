# Modules & Plugins

Obelisk splits everything that isn't the core framework into two directory trees: `modules/` and `plugins/`. Neither has its own `fxmanifest.lua` (see the conventions below), but they mean different things and are treated differently.

- `modules/` — first-party, framework-owned functionality. Code that ships as part of Obelisk itself (or is developed as if it were core code) lives here.
- `plugins/` — third-party or project-specific resources. This is where `oblsk_inventory` and anything you or the community build on top of Obelisk lives.

The distinction is about ownership and dependency direction, not capability: a module and a plugin can both define models, migrations, actions, interactions, and policies. The CLI's `make:*` commands (see [`/cli/index`](/cli/index)) even ask you to pick a location — `Core`, `Module`, or `Plugin` — for most generators, and scaffold into `modules/<Name>/` or `plugins/<Name>/` accordingly.

## `fxmanifest.lua` conventions

Only `core` has a real `fxmanifest.lua`. Modules and plugins don't: their scripts get folded into `core`'s own resource through glob patterns in that one manifest, rather than declaring resources of their own.

### Core's own manifest

The root `fxmanifest.lua` (the core resource itself) declares its dependency on the FXServer build and OneSync, not on another resource by name:

```lua
-- Dependencies
dependencies {
    '/server:5848',
    '/onesync'
}
```

### Module manifests

Modules don't have their own `fxmanifest.lua`. `make:module` scaffolds a module's directory tree (`server/`, `client/`, `shared/`) and registers its name in `modules/registry.json`; its scripts load as part of `core`'s own resource via the `modules/*/...` globs in `core/fxmanifest.lua`.

### Plugin manifests

Plugins don't have their own `fxmanifest.lua` either. `make:plugin` scaffolds a plugin's directory tree (`server/`, `client/`, `shared/`, and for Vue-enabled plugins `web/`) and registers its name in `plugins/registry.json`; its scripts load as part of `core`'s own resource via the `plugins/*/...` globs in `core/fxmanifest.lua`, so `core`'s ORM and services (which every plugin depends on) are always loaded first, by construction, before this plugin's scripts run.

### Script globs

Core's `fxmanifest.lua` uses FiveM's glob patterns to list its own scripts, then reaches into every module and plugin with a second set of globs appended to the same list:

```lua
server_scripts {
    'core/server/ORM/Dialects/Init.lua',
    -- ...
    'core/server/Services/*.lua',
    'core/server/Models/**/*.lua',
    'core/server/Policies/**/*.lua',
    'core/server/bootstrap.lua',
    'modules/*/server/**/*.lua',
    'plugins/*/server/**/*.lua'
}
```

`shared_scripts` and `client_scripts` follow the same shape: core's own entries first, then `modules/*/...` and `plugins/*/...` globs. Core's own entries always come first so the ORM and services finish loading before any module or plugin script runs. Since modules and plugins have no `fxmanifest.lua` of their own, they have no glob patterns to declare either. It's purely a `core/fxmanifest.lua` concern.

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

`make:plugin` reflects a lighter version of this when you opt into the "Vue UI Page" feature: it scaffolds a `web/` directory with a Vite + Vue 3 + Tailwind `package.json` and a starter `.vue` component under `web/src/components/`. Since a generated plugin has no `fxmanifest.lua` of its own, there's no `ui_page` or `files {}` block to set either.

## Scaffolding with the CLI

You don't hand-write any of the above — `obelisk make:module` and `obelisk make:plugin` generate the directory structure, the `README.md`, the registry entry, and optional feature files (models, migrations, seeders, actions, services, Vue UI, etc.) interactively. See [`/cli/index`](/cli/index) for the full command reference, including every prompt and generated file path.
