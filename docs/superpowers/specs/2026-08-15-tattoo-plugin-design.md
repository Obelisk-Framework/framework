# oblsk_tattoo plugin — design spec

Ported from Claude Design project "FiveM" (`pages/tattoo.html`, `src/proto/tattoo.jsx`,
`src/proto/tattoo-game.jsx`). New nested repo `Obelisk-Framework/oblsk_tattoo` at
`core/plugins/oblsk_tattoo`, mirroring the file layout of `oblsk_terminal` /
`oblsk_cardealer` / `oblsk_tuner`.

## Scope

A tattoo shop where a player browses a book of designs by body zone, previews
several against their skin at once, inks one via a trace-the-stencil minigame,
and can later laser one off via a heat-management minigame. Shops price per
design; a per-shop flag makes ink free (staff/self-serve booths).

## Architecture

```
fxmanifest.lua
client/main.lua              -- opens NUI on interaction, forwards Obelisk events
server/main.lua               -- ActionService + Obelisk.onServer wiring, boot seeding
server/services/TattooService.lua   -- purchase/apply/remove logic, session state
server/seeders/TattooDesignSeeder.lua
server/migrations/*.lua       -- tattoo_shops, tattoo_designs, tattoo_applied
shared/config.lua
tests/tattoo_service_spec.lua
web/Tattoo.vue                -- port of TattooUI
web/tattoo/TtMark.vue         -- port of TtMark/TtMarkShape (procedural SVG art)
web/tattoo/TtNeedleGame.vue   -- port of TtNeedleGame
web/tattoo/TtLaserGame.vue    -- port of TtLaserGame
web/routes.js
```

## Data model

- `tattoo_shops` — id, business_name, interaction_id, free_mode (bool)
- `tattoo_designs` — id, name, zone, price, shop_id (nullable = global book)
- `tattoo_applied` — id, character_id, zone (unique per character+zone), design_name,
  ink_hex, quality, price_paid, grade

`tattoo_applied` persists what the prototype held in React state (`applied`), so ink
survives relog. One row per zone per character — a new piece on an occupied zone
replaces the row, matching the prototype's "apply overwrites" behavior.

Design catalog is DB-backed (seeded once from the prototype's 23-entry `TT_BOOK`)
rather than hardcoded in the client, matching `TunerCatalogService`.

## Data flow

1. Player interacts with a tattoo shop → `ActionService` action `tattoo:open` →
   server looks up shop + its designs + the character's `tattoo_applied` rows →
   `WebView.openPage` + `tattoo:server:sync` with `{ shop, designs, applied }`.
2. Client browses/searches/previews client-side only (no server round-trip) —
   preview state (`previews`, `mode`) is pure UI, same as the prototype.
3. "Ink" or "Laser" starts the matching minigame client-side. On minigame
   completion the client has `{ quality, grade, mult }` and emits
   `tattoo:client:purchase` (or `tattoo:client:remove`) with zone/design/ink/quality.
4. Server (`TattooService.apply` / `.remove`) recomputes price from quality/mult
   server-side (never trusts a client-sent price), charges cash instantly or
   invokes the injected `obelisk:payment` card flow (same as `CarDealer.vue`'s
   `buyCash`/`buyCard`), writes/deletes the `tattoo_applied` row, and replies
   with `tattoo:server:result`.
5. Client updates local `applied` map from the server's authoritative row on
   success; on failure it stays on the minigame's result screen so the player
   can retry payment.

## Error handling

- Insufficient cash/card balance → `TattooService.apply` returns `false, reason`;
  client shows the existing payment-declined notify, minigame result stays open.
- Shop's `free_mode` is a shop-table flag, not a client toggle — the client never
  gets to declare "no charge" the way the prototype's `owned` button did.
- Minigame results below the prototype's 95% coverage / 95% steady-hand gate are
  rejected client-side before an event is even sent (ported as-is).

## Testing

`tests/tattoo_service_spec.lua`: purchase success, insufficient funds (cash and
card), free_mode shop charges nothing, apply replaces existing zone row, remove
deletes the row and refunds nothing (removal is its own paid action).

## Out of scope

- No character-appearance/ped integration beyond what `Appearance.lua` already
  exposes (memory: overlays/parents/makeup colors already extended) — applying a
  tattoo writes the DB row; wiring it into the actual ped overlay draw call is a
  follow-up once the barber/appearance plugin lands, since both plugins will
  share that pipeline.
