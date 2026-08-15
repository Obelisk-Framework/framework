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
A single world interaction (`ShellBuilderConfig.EntryPoint` in
`shared/config.lua`) opens the shell browser. Owners (rows in
`shell_owners`) see **Enter**. Anyone with the ACE `admin` permission, or a
character explicitly granted `shellbuilder.build` via `PermissionService`,
also sees **Edit** and **Create new shell**.

## Installation
This plugin loads as part of the `core` resource. After adding it under
`plugins/`, run `obelisk registry:generate` from `core/` on the host, then
restart `core` (or the whole server).

## Dependencies
This plugin has undeclared hard dependencies beyond `core` (its
`fxmanifest.lua` only lists `dependencies { 'obelisk' }`): it requires
`oblsk_items` to be installed and loaded for `ItemService`/item bindings
(the placeable catalog and place/remove item accounting), and it requires
core's `CharacterService` for character-scoped shell ownership. Neither is
enforced defensively in code — `server/main.lua` and
`server/services/ShellObjectService.lua` call into both unguarded.

## Object rendering and placement

Objects placed in a shell are streamed to all players currently inside that
shell via `EntityStreamerService` (see `core/server/Services/EntityStreamerService.lua`).
Each shell registers its objects in a bucket-isolated group keyed by shell ID,
so occupants of different shells never see or collide with each other's
furnishings — the same routing-bucket isolation that keeps shells' anchors
apart.

**Placement and removal** happen via camera-raycast aim mode. When an owner or
staff member with `shellbuilder.build` selects a placeable item and clicks
**Place (aim)**, the camera releases and enters aim mode. Left-click confirms
placement; right-click or ESC cancels. The item's heading can be rotated while
aiming using Q and E. Once placed, the object appears immediately for the
placing player and is broadcast to all other occupants of that shell.

**Removal** uses the same aim-mode flow: toggle wreck mode (if applicable), aim
at an unlocked object, and left-click to remove it. Locked objects cannot be
removed via wreck mode — `ShellObjectService.remove`'s server-side locked check
prevents deletion (see `server/services/ShellObjectService.lua`).

## Ownership management

Within a shell's detail pane in the shell browser, staff and players with
`shellbuilder.build` permission can search for and grant ownership. The
**Management** section allows:

- Searching for characters by partial name
- Adding a character as a shell owner
- Removing existing owners

Ownership is stored in the `shell_owners` table, keyed by shell ID and character ID.
Owners see an **Enter** button in the shell browser for shells they own; staff and
`shellbuilder.build` players can enter any shell to edit it.

## Placeable catalog
Placeable objects are `oblsk_items` bindings whose key is prefixed
`shellbuilder.` (e.g. `shellbuilder.floor_wood`, `shellbuilder.sofa_basic`).
Each bound base item's `data` column needs `shell_tool` (`build` | `style` |
`decor`), `shell_category`, and `shell_model` set for it to appear in the
editor's catalog — see `ShellObjectService.catalog` in
`server/services/ShellObjectService.lua`. Declaring a key in
`ShellBuilderConfig.Requires.bindings` (`shared/config.lua`) only makes it
known to `ItemService.getRequiredBindingKeys()` — a server operator still
needs to create matching `base_items`/`item_bindings` rows before the
catalog is actually populated.
