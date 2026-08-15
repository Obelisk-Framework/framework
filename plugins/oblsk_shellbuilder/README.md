# oblsk_shellbuilder

## Description
Staff-built, character-owned enterable interiors ("shells") — houses,
hideouts, workshops. A shell can come fully furnished (staff place and lock
every piece, an owner can't remove any of it) or empty (an owner furnishes
it themselves via the Decorate tool). Every shell lives in its own FiveM
routing bucket (see `core/server/Services/InstanceService.lua`), so
multiple shells share one fixed underground anchor coordinate without
occupants of different shells ever seeing or colliding with each other.
Multiple characters can own the same shell.

See `docs/superpowers/specs/2026-08-15-shell-builder-plugin-design.md` for
the full design.

## Access
A single world interaction (`Config.EntryPoint` in `shared/config.lua`)
opens the shell browser. Owners (rows in `shell_owners`) see **Enter**.
Anyone with the ACE `admin` permission, or a character explicitly granted
`shellbuilder.build` via `PermissionService`, also sees **Edit** and
**Create new shell**.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).

## Placeable catalog
Placeable objects are `oblsk_items` bindings whose key is prefixed
`shellbuilder.` (e.g. `shellbuilder.floor_wood`, `shellbuilder.sofa_basic`).
Each bound base item's `data` column needs `shell_tool` (`build` | `style` |
`decor`), `shell_category`, and `shell_model` set for it to appear in the
editor's catalog — see `ShellObjectService.catalog` in
`server/services/ShellObjectService.lua`.
