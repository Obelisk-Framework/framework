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
- No cross-resource `exports` are involved. Per `AGENTS.md`, plugins are
  **not** separate FiveM resources — `core/fxmanifest.lua` globs every
  plugin's `shared/**`, `client/**` and `server/**` Lua into ONE Lua state
  per side. `Appearance` (from `oblsk_character-selection/shared/
  appearance.lua`) and `CharacterAppearanceService` (its client service)
  are therefore already plain globals in the same state that
  `oblsk_barber`'s client code runs in.
- `oblsk_barber/client/main.lua` reads `Appearance.HAIR_STYLES[gender]`
  and calls `CharacterAppearanceService.apply(ped, appearance, gender)`
  directly, instead of owning its own hair data or ped-native calls. It
  declares no fxmanifest dependency (it has no fxmanifest at all — plugins
  are registered in `plugins/registry.json`).

163 other `HAIR_STYLES` call sites (character creator's Wardrobe/hair
step) keep working unchanged since the shape per entry
(`{label, drawable}`) is unchanged, only wrapped in gender keys and given
an extra `thumb` field they can ignore.

## Assets

164 thumbnails (83 male + 81 female, 240x240 JPEG, ~3.2MB total) already
downloaded from wiki.rage.mp and verified. They land at
`web/public/assets/hair/{male,female}/<drawable>.jpg` — the repo's single
shared Vite `public/` dir, which `web/vite.config.js` copies verbatim into
the served `core/html` bundle. (Per-plugin `web/assets/` directories are
copied by nothing and are unreachable from the NUI.) They are bundled
locally (not hotlinked) so the NUI has no runtime dependency on an
external site. `thumb` values stay `assets/hair/<gender>/<n>.jpg`, which is
already correct relative to the served document root.

## Plugin layout (matches `oblsk_terminal`'s shape)

```
oblsk_barber/
  (no fxmanifest.lua -- plugins are globbed by core/fxmanifest.lua and
   listed in plugins/registry.json)
  shared/config.lua        -- BarberConfig: section prices, non-hair counts (beard/brows/etc, unchanged from design)
  server/
    migrations/            -- barber_chairs table (or reuse a static config list if no admin placement UI needed)
    services/BarberService.lua   -- purchase/charge logic (cash + card via oblsk_payment pattern), section pricing, receipt
    main.lua                -- interaction registration, event wiring
  client/
    main.lua                -- opens NUI, reads Appearance.HAIR_STYLES / calls CharacterAppearanceService.apply (shared globals) for catalog + live preview
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
2. Client opens NUI, reads `hair = Appearance.HAIR_STYLES[gender]`
   for the player's character gender, plus the plugin's own static section
   config (beard/brows/makeup/etc counts+prices from `shared/config.lua`,
   unchanged from the design prototype since no external data source was
   given for those).
3. Selecting a style previews live via
   `CharacterAppearanceService.apply(ped, previewAppearance, gender)`
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

## Implementation deviations (discovered during the build, `barber-plugin` branch)

- **The branch's early history carries unrelated foreign content that
  must be rebased out before merge.** The `oblsk_character-selection`
  working tree at the time this branch's worktree was created had another
  session's uncommitted, unrelated in-progress work (an overlay-picker
  feature: `Appearance.OVERLAYS`/`PARENTS`/`MAKEUP_COLORS`, a restructured
  `FACE_FEATURE_INDEX`, `CharacterCreator.vue` changes, etc). That state
  was deliberately copied into this branch's worktree as a necessary
  baseline (the hair-catalog work touches the same file), and by the time
  a commit-split was attempted to separate it out, the original had
  already been committed/reverted elsewhere on `main` by that other
  session, making a clean split impossible without guesswork. The
  branch's first `oblsk_character-selection` commit is honestly disclosed
  (see its commit message) but still bundles that foreign content. Before
  merging this branch: rebase to drop the bundled overlay/parents/makeup
  content once that feature has landed properly through its own process,
  keeping only this branch's actual hair-catalog and barber-plugin
  commits.
- **Non-hair colour swatches (hair color/highlight, beard/eyebrow/chest
  color, makeup/blush/lipstick) send a raw 0-based swatch index as the
  native colour ID**, not a curated mapping through
  `Appearance.HAIR_COLORS`/`MAKEUP_COLORS` (which only have 8 entries
  each, vs. these sections' 12-24 count from the design prototype). No
  external data source was given for a real 24-entry native colour table
  for these sections (only hair *style* had a wiki source). This is the
  same "curated, not exhaustively researched" posture
  `shared/appearance.lua` already documents for its other catalogs.
- **`BarberService.applyAndPersist`'s merge is shallow at the top level.**
  A charge whose `appearanceChanges` includes a nested `overlays`
  sub-table touching only some categories (e.g. `{facial_hair = {...}}`)
  replaces `data.overlays` wholesale rather than deep-merging, which could
  clobber previously-set overlay categories from an earlier barber visit.
  Deliberately not fixed on this branch — the overlay subsystem itself
  belongs to another session's in-progress feature, not this branch's
  scope.
- **The clipper minigame's quality discount is clamped server-side to
  `[0.45, 1]`** (`bbGrade`'s only possible multiplier values) since it's
  a client-reported gameplay result the server must not trust blindly,
  not an exact pass-through of whatever a client sends.
- **No real FXServer/browser manual playtest was possible during
  implementation** (this environment has no running dev server). All
  verification was Lua unit tests (37 passing across 4 spec files), Lua
  syntax checks (`luac5.4 -p`), and Vue SFC compiler checks
  (`@vue/compiler-sfc`'s `compileScript`/`compileTemplate`) on every
  changed/created file. A real playtest (hair grid renders for both
  genders with correct 83/81 counts, live preview, cash/card checkout,
  clipper minigame, receipt, persistence across a relog) per this spec's
  own Testing section is still outstanding before this plugin ships.
