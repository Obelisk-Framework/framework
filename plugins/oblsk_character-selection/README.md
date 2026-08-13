# oblsk_character-selection

Character select + creator screen, shown on connect via core's `SpawnManagerService`.

## Features
- Roster list with camera framing (head/torso/full), keyboard navigation
- 4-step creator: Identity, Heritage (real `SetPedHeadBlendData` parent blend), Appearance (face features, skin/eye/hair, body), Wardrobe (curated component/drawable presets)
- Live-applied ped appearance natives during creation, rotating preview camera

## Configuration
Edit `shared/config.lua` for the preview scene coordinate. Edit `shared/appearance.lua` for wardrobe/color presets.

## Usage

### Automated tests
Run these from the repo root (`lua5.4` required):

```bash
lua5.4 tests/spawn_manager_service_spec.lua
lua5.4 plugins/oblsk_character-selection/tests/appearance_spec.lua
lua5.4 plugins/oblsk_character-selection/tests/character_selection_service_spec.lua
lua5.4 tests/action_service_spec.lua
lua5.4 modules/oblsk_characters/tests/character_service_spec.lua
```

Each should print `N passed, 0 failed` and exit 0. (As of the last verification pass, `character_service_spec.lua` has 11 pre-existing failures unrelated to this plugin — `attempt to index a nil value (global 'Obelisk')` in `CharacterService.lua`, caused by an in-progress `Obelisk.emit` change on a separate branch. This is a known, out-of-scope issue, not something this plugin introduced.)

### Building the web bundle

```bash
cd web
npm run build
```

This compiles the Vue app, including this plugin's `web/globalElements.js` and `web/routes.js`, into `core/html/`. A successful build with no glob/import errors confirms the plugin's web files are picked up by the app's plugin-discovery glob.

### In-game manual verification

There is no automated coverage for the native/client-side runtime behavior (freezing the player, hiding/showing the HUD, live ped appearance application, camera framing, keyboard shortcuts). To verify those, start an `fxserver` per `docker-compose.yml`/`server.cfg`, connect a client, and walk through the manual checklist in
`.superpowers/sdd/2026-08-13-character-selection-plugin/task-15-brief.md` (Step 3). That checklist has not been executed against a live server as part of this repo's automated verification — it requires a human with a running FiveM server.

See `docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md` for the full design.
