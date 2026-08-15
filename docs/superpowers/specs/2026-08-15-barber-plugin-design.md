# Barber Shop Plugin Design

Date: 2026-08-15

## Summary

New `oblsk_barber` plugin: a barber-chair interaction that lets a player
restyle hair/hair color/highlight/beard/eyebrows/chest hair/makeup/blush/
lipstick, paid via cash or bank card, with a clipper-precision minigame.
Ported from the Claude Design prototype (`pages/barber.html`,
`src/proto/barber.jsx`, `src/proto/barber-game.jsx`).

Real GTA V hair data replaces the placeholder catalog: 83 male drawables
(0-82) and 81 female drawables (0-80), sourced from
wiki.rage.mp's Male/Female Hair Styles pages, with a real thumbnail image
per style.

## Where the hair catalog lives

`oblsk_character-selection/shared/appearance.lua` already owns
`Appearance.HAIR_STYLES` and is explicitly flagged in its header comment as
a placeholder ("curated STARTING catalog... expect entries to look off").
It's the same table the character creator and `CharacterAppearanceService`
already consume. The barber shop reuses it rather than forking a second
copy that could drift:

- `Appearance.HAIR_STYLES` becomes gender-keyed:
  `Appearance.HAIR_STYLES.male` (83 entries) / `.female` (81 entries),
  each `{ label, drawable, thumb }`. `thumb` is a path under
  `web/assets/hair/<gender>/<drawable>.jpg`.
- `Appearance.DEFAULT_APPEARANCE(gender)` and
  `Appearance.resolvePresetAppearance(gender, raw)` change their one
  lookup site (`Appearance.HAIR_STYLES[1]` → `Appearance.HAIR_STYLES[gender][1]`,
  `Appearance.HAIR_STYLES[raw.hairStyleIndex + 1]` → gender-scoped) — no
  other call site changes.
- Two new exports on `oblsk_character-selection` (FiveM resources don't
  share Lua globals, so cross-plugin reuse needs `exports`, the same
  pattern `oblsk_licenses` already uses for `hasValidLicense`):
  - server or shared: `getHairStyles(gender)` → returns
    `Appearance.HAIR_STYLES[gender]`
  - client: `applyAppearance(ped, appearance, gender)` → wraps the
    existing `CharacterAppearanceService.apply`
- `oblsk_barber` adds `oblsk_character-selection` to its fxmanifest
  `dependencies` and calls those exports instead of owning its own hair
  data or ped-native calls.

163 other `HAIR_STYLES` call sites (character creator's Wardrobe/hair
step) keep working unchanged since the shape per entry
(`{label, drawable}`) is unchanged, only wrapped in gender keys and given
an extra `thumb` field they can ignore.

## Assets

164 thumbnails (83 male + 81 female, 240x240 JPEG, ~3.2MB total) already
downloaded from wiki.rage.mp and verified. They land at
`oblsk_character-selection/web/assets/hair/{male,female}/<drawable>.jpg`
— bundled locally (not hotlinked) so the NUI has no runtime dependency on
an external site.

## Plugin layout (matches `oblsk_terminal`'s shape)

```
oblsk_barber/
  fxmanifest.lua          -- dependencies: obelisk, oblsk_character-selection
  shared/config.lua        -- section prices, non-hair counts (beard/brows/etc, unchanged from design)
  server/
    migrations/            -- barber_chairs table (or reuse a static config list if no admin placement UI needed)
    services/BarberService.lua   -- purchase/charge logic (cash + card via oblsk_payment pattern), section pricing, receipt
    main.lua                -- interaction registration, event wiring
  client/
    main.lua                -- opens NUI, calls oblsk_character-selection exports for catalog + live preview apply
  web/
    Barber.vue               -- ported BarberUI (rail, sections, footer)
    BarberClipperGame.vue    -- ported BbClipperGame minigame
    routes.js, globalElements.js
  tests/
    barber_service_spec.lua
  README.md
```

## Data flow

1. Player interacts with a registered barber chair (core InteractionService,
   same convention every world-object plugin uses — no custom proximity
   code).
2. Client opens NUI, fetches `hair = exports['oblsk_character-selection']:getHairStyles(gender)`
   for the player's character gender, plus the plugin's own static section
   config (beard/brows/makeup/etc counts+prices from `shared/config.lua`,
   unchanged from the design prototype since no external data source was
   given for those).
3. Selecting a style previews live via
   `exports['oblsk_character-selection']:applyAppearance(ped, previewAppearance, gender)`
   on the client ped — same call the character creator's live preview uses.
4. On "Cut it" (owned/no-charge) or paying (cash/card, ported from
   `barber.jsx`'s payment sheet, same pattern as `oblsk_terminal`/
   `oblsk_cardealer`), the clipper minigame (`BbClipperGame` ported 1:1)
   runs per touched section; a poor result discounts the price rather than
   blocking the cut.
5. On completion: `BarberService` charges the player (cash deduction or
   card charge via the existing payment plugin pattern), then updates the
   character's `character_appearances.data` row (merge changed keys —
   hairStyle/hairColor/hairHighlight/overlays — via the existing
   `CharacterAppearance` model) so the look persists across sessions.

## Testing

- `barber_service_spec.lua`: pricing/total calculation, cash vs card
  charge paths, appearance-row merge-and-persist, insufficient-funds
  rejection — same shape as `terminal_service_spec.lua`.
- `oblsk_character-selection`'s existing `appearance_spec.lua` gets cases
  added for the gender-keyed `HAIR_STYLES` lookup and the two new exports.
- Manual: open the barber NUI in a running server, confirm real hair
  thumbnails render for both genders, confirm a purchased style survives
  a relog.

## Known limitations (carried from the design + this task's stated scope)

- Only hair (style) uses real wiki-sourced data/images. Beard, eyebrows,
  hair/beard/eyebrow colors, chest hair, makeup, blush, and lipstick keep
  the design prototype's existing counts/abstract tile art — no wiki
  source was given for those catalogs.
- Barber chair placement is static config (like other interaction-based
  shops), not an in-game placement tool.
