# Quick Start

This walks through the shortest real path from a fresh clone to a generated, loadable module, using only commands that actually exist in this repository.

## 1. Install dependencies

From the `core` directory:

```bash
cd core
npm install
```

## 2. Generate a module

Run the `make:module` generator through the `cli` npm script, passing the module name as an argument:

```bash
npm run cli -- make:module MyFeature
```

This is equivalent to running `node cli/index.js make:module MyFeature` directly — `cli` is just the `"cli": "node cli/index.js"` script defined in `core/package.json`. (If you passed no name, the CLI would prompt for one interactively instead.)

### The feature checklist

Next, `make:module` asks which features to scaffold with an interactive checkbox prompt, `Select features to include:`, offering exactly these choices (checked ones are pre-selected):

- Database Model *(checked)*
- Database Migration *(checked)*
- Database Seeder
- Actions *(checked)*
- Interactions
- Keybinds
- Policies
- Vue Component
- Client Services *(checked)*
- Server Services *(checked)*

Press `space` to toggle a choice and `enter` to confirm. For this walkthrough, accept the defaults.

## 3. What gets generated

Every run creates the module directory itself, `modules/MyFeature/`, along with a `README.md` that lists the features you selected. Beyond that, each selected feature currently adds one generated file:

| Feature | File |
| --- | --- |
| Database Model | `modules/MyFeature/server/models/MyFeature.lua` |
| Database Migration | `modules/MyFeature/server/migrations/<timestamp>_create_myfeatures_table.lua` |
| Database Seeder | `modules/MyFeature/server/seeders/MyFeatureSeeder.lua` |
| Actions | `modules/MyFeature/server/actions/Example.lua` |
| Server Services | `modules/MyFeature/server/services/MyFeatureService.lua` |
| Client Services | `modules/MyFeature/client/services/MyFeatureService.lua` |

With the default selections, running the command above produces:

```
modules/MyFeature/
├── README.md
├── server/
│   ├── models/MyFeature.lua
│   ├── migrations/<timestamp>_create_myfeatures_table.lua
│   ├── actions/Example.lua
│   └── services/MyFeatureService.lua
└── client/
    └── services/MyFeatureService.lua
```

## 4. Load the module

`MyFeature` loads as part of `core`'s own resource (its scripts are picked up by `core/fxmanifest.lua`'s `modules/*/...` globs). There's nothing to `ensure` separately, but `core/server/bootstrap.lua` only runs a module's migrations if its name appears in `modules/registry.json`, and that file isn't hand-maintained: run `obelisk registry:generate` from `core/` on the host to regenerate it from what's actually on disk (the Docker container mounts `core/` read-only, so this step can't run inside it). Then restart `core` (or the whole server), and the module's scripts and migrations load alongside the rest of the framework.

```bash
obelisk registry:generate
docker compose restart fxserver
```

## Next steps

- [Modules & Plugins](/concepts/modules-and-plugins) — how modules and plugins fit into the framework architecture.
- [Building a Plugin](/examples/building-a-plugin) — a full worked example that goes further than the default scaffold.
