# oblsk_barber

Barber-chair shop plugin: hair/hair color/highlight/beard/beard
color/eyebrows/eyebrow color/chest hair/chest hair color/makeup/blush/
lipstick, paid cash or card, gated behind a clipper-precision minigame.

Hair style data (83 male / 81 female GTA V drawables, with thumbnails) is
owned by `oblsk_character-selection` (`shared/appearance.lua`'s
`Appearance.HAIR_STYLES`) and consumed here via its `getHairStyles`/
`applyAppearance` exports — this plugin depends on
`oblsk_character-selection` (see `fxmanifest.lua`) and does not keep its
own copy of the hair catalog.

See `docs/superpowers/specs/2026-08-15-barber-plugin-design.md` for the
full design.

## Placing a chair

Insert an `interactions` row at the desired coords, then a `barber_chairs`
row referencing it via `interaction_id` (see `server/migrations/
2026_08_15_150000_create_barber_chairs_table.lua`). Chairs register their
world prompt on server boot (`registerAllChairs()` in `server/main.lua`).
