# Character Selection & Creator Plugin

## Summary

Rebuild `oblsk_character-selection` (currently placeholder scaffolding — generic AI mockup Vue files, empty client/server) into a working character select + creator screen, ported from the Claude Design prototype at `pages/character.html` / `src/proto/character.jsx` in the Obelisk UI Prototypes project. Adds a minimal `SpawnManagerService` to `core/core` to own the join → select → spawn lifecycle, since nothing in the framework currently freezes the player, hides HUD, or shows any screen on connect.

Source design reference: `claude.ai/design/p/019de78f-9966-77d9-90c0-73b12ead46cd`, files `index.html` (catalog) and `src/proto/character.jsx` (the actual component — select screen + 4-step creator: Identity, Heritage, Appearance, Wardrobe).

## Scope

In scope:
- `SpawnManagerService` (core, server+client): join hook, freeze/unfreeze, HUD visibility toggle, stage state machine.
- Character select screen: roster list, W/S navigation, camera framing (head/torso/full), spawn point + play button.
- Character creator: 4-step flow (Identity, Heritage, Appearance, Wardrobe) with live-applied ped appearance natives and rotating camera preview.
- Real native appearance application: `SetPedHeadBlendData`, `SetPedFaceFeature`, `SetPedComponentVariation`, `SetPedPropIndex`, `SetPedHairColor`, `SetPedEyeColor`.
- Curated starter wardrobe/color config tables (approximate drawable/texture/color IDs — tunable later, not a researched final catalog).
- Server actions: list / create / delete / select characters, thin wrappers over the existing `CharacterService`.
- Vue port of the UI (`CharacterSelect.vue`, `CharacterCreator.vue` + shared controls), dev-mirror mock for browser preview, matching the `useInventory.js`-style composable pattern.

Out of scope (explicitly deferred, same as the design prototype itself defers tattoos/makeup to "after creation"):
- Build/Height sliders have no vanilla native effect — stored in appearance data for future use, UI-only.
- Tattoos and makeup tabs — stubbed as "unlocks after creation," matching the prototype.
- Anything beyond `SpawnManagerService`'s minimal stage hooks (e.g. a real loading screen) — future plugins can hook the same stage events.

## Architecture

### 1. `core/core` — `SpawnManagerService`

New, minimal, server + client service. This is the one piece of scope that belongs to core rather than the plugin, because "what happens when a player connects, before they're playable" is a cross-cutting concern, not something the character-selection plugin should silently own.

**Server side:**
- Hooks the FiveM player-connecting/joining flow, calls `SpawnManagerService.markConnecting(source)`.
- Exposes `SpawnManagerService.readyToSpawn(source, characterId)` — called by the character plugin once the player has confirmed a character and appearance has been applied client-side. Marks the stage `spawned`.

**Client side:**
- `SpawnManagerService.FreezePlayer(bool)` — wraps `FreezeEntityPosition` on the local ped.
- `SpawnManagerService.SetHudVisible(bool)` — fires an event other HUD-owning plugins can listen for (no HUD plugin listens yet; this just defines the contract).
- Stage state machine: `connecting → selecting → creating → spawning → spawned`, broadcast as an event other plugins can hook. The character plugin drives these transitions; `SpawnManagerService` just holds and broadcasts the current stage.

Kept intentionally thin — no loading-screen UI, no server-side spawn-position logic beyond what `CharacterService.getVitals`/`saveVitals` already provide.

### 2. Appearance data shape (documented convention, not schema-enforced)

`CharacterAppearance.data` (already a JSON column) gets a defined shape used by this plugin:

```lua
{
  headBlend = {
    shapeFirst, shapeSecond, shapeThird,   -- integer, parent head IDs
    skinFirst, skinSecond, skinThird,      -- integer, parent skin IDs
    shapeMix, skinMix, thirdMix,           -- 0.0–1.0
  },
  faceFeatures = { [0] = -1.0, [1] = 0.4, ... },  -- indices 0–19, values -1..1
  hairStyle = 2,          -- drawable index for component 2
  hairColor = 3,          -- SetPedHairColor color id
  hairHighlight = 0,      -- SetPedHairColor highlight id
  eyeColor = 1,           -- SetPedEyeColor index
  components = { [componentId] = { drawable, texture } },
  props = { [propId] = { drawable, texture } },  -- -1 drawable = no prop
}
```

The 8 face sliders in the design (nose width/height, cheekbones, jaw, chin, brow, eye size, lips) map to specific `faceFeatures` indices via a fixed lookup table in the plugin — this is a well-known, stable GTA native (`SetPedFaceFeature`, indices 0–19), not something we're inventing.

The 8-swatch skin tone and eye/hair color pickers in the design are **not** raw RGB in GTA — skin tone is controlled by `headBlend` skin IDs + mix, and hair/eye colors are native color-table indices. So each swatch in the UI maps to a curated preset (a specific `skinFirst/skinSecond/skinMix` combo, or a specific native color index) chosen to visually approximate that swatch, not a literal color value. This is called out in the wardrobe config as approximate/tunable.

Heritage step (mother/father blend, resemblance) drives `headBlend` directly and for real — this replaces the JS prototype's placeholder wiring, which sloppily reused the `cheek`/`jaw` face-shape sliders for the heritage sliders since it had no real backing. Real implementation: two selectors (mother head ID, father head ID) each with a skin-tone sub-picker, plus `shapeMix`/`skinMix` sliders ("Mother ← → Father") and a `thirdMix` slider ("Resemblance", if a third/child blend is desired) feeding `SetPedHeadBlendData(ped, shapeFirst, shapeSecond, shapeThird, skinFirst, skinSecond, skinThird, shapeMix, skinMix, thirdMix, isParent=false)`.

### 3. Wardrobe/appearance config — `shared/appearance.lua` (new, in the plugin)

Curated tables, keyed by gender (`male`/`female`), for:
- Tops (6 options), Outerwear/jackets (5, incl. "None"), Legwear (5), Footwear (4), Headwear (3, incl. "None"), Accessory (3, incl. "None") — each entry is `{label, component, drawable, texture}`.
- Skin tone presets (8) — each `{label, color (for the UI swatch), skinFirst, skinSecond, skinMix}`.
- Eye color presets (8) — each `{label, color, index}`.
- Hair color presets (8) — each `{label, color, colorId, highlightId}`.
- Hair styles (6) — each `{drawable}` (component 2).

This is a hand-picked starting catalog, not a researched final art-directed one — flagged in the file header comment so it's clearly understood as tunable.

### 4. Client (plugin)

**Select screen** (`SpawnManagerService` stage `selecting`):
- Fetch character list + appearances via `characters:list` action.
- Spawn a preview ped (`CreatePed`) at a fixed interior coordinate (matching the design's "apartment" scene), apply each selected character's appearance.
- `RenderScriptCam` framing toggles (head/torso/full) via camera offset + FOV lerp between 3 presets, matching the design's camera control.
- W/S cycles selection (updates preview ped), N opens creator, Enter/Play confirms.

**Creator screen** (`SpawnManagerService` stage `creating`):
- Same preview ped, appearance natives applied live on every slider/swatch/wardrobe change (no debounce needed — these are cheap client-side calls).
- F cycles camera between 4 fixed angles around the ped (Front/¾/Side/Back), matching the design.
- Identity step: first/last name, sex, DOB (year/month/day steppers) — client-side only until confirm.
- Confirm on last step (Wardrobe): sends `{first_name, last_name, gender, dob, bio, appearance}` to `characters:create`.

**Confirm/spawn (both screens' "Play"):**
- Sends `characters:select` with the character ID.
- Server returns vitals (position/dimension) via `CharacterService.getVitals`, defaulting to a spawn point if never played.
- Client applies final ped model + full appearance to the actual player ped (not the preview), sets position, calls `SpawnManagerService.readyToSpawn`, which unfreezes and shows HUD.

### 5. Server (plugin) — actions via `ActionService`

Thin wrappers, no new business logic — `CharacterService` already has everything needed:
- `characters:list` → `CharacterService.list(accountId)` + joined appearance data.
- `characters:create` → `CharacterService.create(accountId, attributes)`, attributes now including the appearance blob (stored directly on the `CharacterAppearance.data` created alongside).
- `characters:delete` → `CharacterService.delete(characterId)`.
- `characters:select` → `CharacterService.setActiveCharacterId` + returns vitals for spawn.

`accountId` is resolved from the existing session/account lookup pattern used elsewhere in the framework (not re-derived here — same convention as other plugins calling into `oblsk_accounts`).

### 6. Web (Vue) — replaces the placeholder files entirely

The existing `CharacterSelector.vue` / `CharacterSelection.vue` / `CharacterCreationForm.vue` are generic, unrelated AI-mockup placeholders (teal buttons, `placehold.co` images) — not a partial implementation of this design. They're deleted and replaced, not extended.

New structure, mirroring the `oblsk_inventory` port pattern (`useInventory.js` composable, dev-mirror mock data):
- `CharacterSelect.vue` — roster list, camera controls, selected-character detail panel, spawn/play panel, keybind rail.
- `CharacterCreator.vue` — step rail (Identity/Heritage/Appearance/Wardrobe), per-step sub-panels, preview camera controls.
- Shared small controls: slider, swatch grid, stepper, text field (ported from the prototype's `Sld`/`Swatches`/`Stepper`/`TxtField` helpers).
- `useCharacterCreator.js` — NUI bridge composable (list/create/select/delete calls, live appearance-update messages to the client Lua), plus a dev-mirror mock character set for browser-only preview, same convention as `useInventory.js`.

## Testing

- `CharacterService` already has coverage in `core/modules/oblsk_characters/tests/`; extend if `create`/`list` behavior changes shape (e.g. appearance blob on create).
- New `SpawnManagerService` gets a focused spec covering stage transitions and freeze/unfreeze calls (client-side natives mocked, same convention as other client service tests in this repo).
- Face-feature / wardrobe lookup tables get a lightweight spec asserting every design-listed option resolves to a table entry (catches typos/missing entries, not visual correctness — that needs in-game verification).

## Known limitations (explicit, not silent gaps)

- Wardrobe/color/skin ID tables are a curated starting point, not verified against the actual GTA prop/drawable catalog in-game — expect some options to look off until play-tested and tuned.
- Build/Height sliders have no native effect in vanilla GTA — stored for future use only.
- Tattoos/makeup tabs are non-functional placeholders, matching the source design's own "unlocks after creation" framing.
- `SpawnManagerService` is intentionally minimal — no loading screen, no death/respawn integration — just enough for this plugin to own its own lifecycle correctly.
