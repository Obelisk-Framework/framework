# oblsk_character-selection

Character select + creator screen, shown on connect via core's `SpawnManagerService`.

## Features
- Roster list with camera framing (head/torso/full), keyboard navigation
- 4-step creator: Identity, Heritage (real `SetPedHeadBlendData` parent blend), Appearance (face features, skin/eye/hair, body), Wardrobe (curated component/drawable presets)
- Live-applied ped appearance natives during creation, rotating preview camera

## Configuration
Edit `shared/config.lua` for the preview scene coordinate. Edit `shared/appearance.lua` for wardrobe/color presets.

See `docs/superpowers/specs/2026-08-13-character-selection-plugin-design.md` for the full design.
