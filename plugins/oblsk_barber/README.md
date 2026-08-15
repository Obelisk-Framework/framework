# oblsk_barber

Barber-chair shop plugin: hair/hair color/highlight/beard/beard
color/eyebrows/eyebrow color/chest hair/chest hair color/makeup/blush/
lipstick, paid cash or card, gated behind a clipper-precision minigame.

Hair style data (83 male / 81 female GTA V drawables, with thumbnails) is
owned by `oblsk_character-selection` (`shared/appearance.lua`'s
`Appearance.HAIR_STYLES`) and read here directly — this plugin does not
keep its own copy of the hair catalog.

No cross-resource `exports` are involved: plugins are not separate FiveM
resources (`AGENTS.md`), `core/fxmanifest.lua` globs every plugin's Lua
into one state per side, so `Appearance` and `CharacterAppearanceService`
are already plain globals `client/main.lua` can call. This plugin
therefore ships no `fxmanifest.lua` of its own; it is registered in
`plugins/registry.json`.

The hair thumbnails live in the repo's single shared Vite public dir,
`web/public/assets/hair/{male,female}/<drawable>.jpg` — the only path
`web/vite.config.js` copies into the served bundle.

`shared/config.lua` names its table `BarberConfig`, not `Config`: a bare
`Config` global would collide with other plugins' in the shared Lua state.
It also declares the `currency.cash` item binding this plugin needs
(`BarberConfig.Requires.bindings`), so an unbound key is warned about at
boot.

See `docs/superpowers/specs/2026-08-15-barber-plugin-design.md` for the
full design.

## Placing a chair

Insert an `interactions` row at the desired coords, then a `barber_chairs`
row referencing it via `interaction_id` (see `server/migrations/
2026_08_15_150000_create_barber_chairs_table.lua`). Chairs register their
world prompt on server boot (`registerAllChairs()` in `server/main.lua`).
