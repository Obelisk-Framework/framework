# HUD Layout Engine Design

**Repositories:** `core` (registry render mechanism), `modules/oblsk_preferences` (layout read/write contract + editor UI). No plugin repo changes required by this sub-project — `oblsk_hud`/`oblsk_speedometer`/`oblsk_progressbar` opt in later, each its own future pass.

**Goal:** Let any global element (HUD, speedometer, progress bar, hotbar, future ones) be moved, scaled, tilted in 3D and rotated by the player in-game, with the result persisted per account or per character. This is sub-project 1 of the full HUD parity effort (see `2026-08-13-preferences-and-hud-elements-design.md`'s "Known gaps" and the design-prototype reference at claude.ai/design project "FiveM", `src/proto/hud-editor.jsx`). It ships the mechanism only — no HUD content (vitals, compass, speedo styles, etc.) is built here.

## Why this exists

`oblsk_preferences` already persists one bit per element (`hud:<name>:enabled`), generically, with no per-plugin code. Position/scale/rotation is the same shape of problem — a per-element, per-owner value that any plugin's element should get for free by being a normal registry entry — so it extends the same mechanism rather than inventing a parallel one. The design-prototype's `hud-editor.jsx` already proves out the UX (drag to move, sliders for scale/tilt/rotate, live preview) against a throwaway `localStorage`-backed `HudEditor`; this spec is that same UX wired to the real framework's registry, actions, and preferences store.

## Data model

No schema change. Reuses the existing `preferences` table (`owner_type`, `owner_id`, `key`, `value` json) and `PreferenceService.set`/`get`/`getMerged` unchanged. New key convention, parallel to `hud:<name>:enabled`:

`hud:<name>:layout` → JSON `{ x, y, scale, rx, ry, rot }`

- `x`, `y`: pixels, authored against a fixed 1920×1080 reference canvas (see "Reference canvas" below).
- `scale`: 0.5–1.8, matches the prototype's resize slider range.
- `rx`, `ry`: -60°..60°, the two 3D tilt axes (`rotateX`/`rotateY`).
- `rot`: -45°..45°, in-plane rotation.

A `name` with no `hud:<name>:layout` row falls back to the registry entry's `defaultLayout`. `getMerged` already gives character-overrides-account precedence for free — nothing new needed there.

## Registry entry contract change

`globalElements.js` entries gain two optional fields:

```js
{ name: 'hud', component: Hud, defaultVisible: true,
  positionable: true,
  defaultLayout: { x: 34, y: 968, width: 360, align: 'left' } }
```

`positionable` defaults to `false` (an entry that omits it renders exactly as today, unwrapped — e.g. `oblsk_preferences`'s own invisible `PreferencesHydrator`). `defaultLayout.width`/`align` are layout hints the wrapper needs to size/anchor the element (the component itself no longer sets its own `fixed …` position classes — see below).

**Component contract:** a `positionable: true` element's `.vue` file stops self-positioning (no more `fixed bottom-4 left-4` on its root). It renders only its content; the wrapper (next section) owns position, size anchor, transform, and z-index. This is a breaking change to `Hud.vue`'s current placeholder markup — trivial today since it's a one-line stub, called out explicitly so it isn't missed when `oblsk_hud`'s real content pass begins.

## Core: the positioning wrapper

Everything here lives in `core/web/src/App.vue` (already the sole owner of the registry) plus one new component, `core/web/src/components/HudPositionFrame.vue`.

**Reference canvas.** The whole positionable layer renders inside a fixed `1920×1080` container, CSS-scaled to fit the actual viewport: `transform: scale(min(vw/1920, vh/1080))`, centered. Element coordinates are authored once against that canvas and are therefore resolution-independent — same trick the prototype's `host.width / 1920` drag-math factor implies, made explicit as a real container instead of an inferred ratio.

**`HudPositionFrame`** wraps each `positionable` entry:

```html
<div class="absolute" :style="frameStyle" @pointerdown="onPointerDown">
  <component :is="entry.component" />
</div>
```

`frameStyle` computes `left/top` from `layout.x/y`, `width` from `layout.width`, `text-align` from `layout.align`, and `transform: perspective(1100px) rotateY(ry) rotateX(rx) rotate(rot) scale(scale)` — identical formula to the prototype's `HudEl`. `onPointerDown` only does anything when a global reactive `editMode` flag (see below) is true: it captures the pointer and streams `pointermove` deltas into a **local** reactive copy of `layout` (immediate visual feedback, nothing written to the server per-frame).

**Edit mode.** A new provided/injected ref, `obelisk:hudEditMode` (boolean) plus `obelisk:hudEditSelection` (the currently-selected element `name`), both provided by `App.vue` next to the existing `obelisk:globalElementsRegistry`. Any plugin could theoretically drive these, but in practice only the editor UI (next section) does.

## `oblsk_preferences`: layout read/write + the editor UI

**Read path (hydration).** `PreferencesHydrator.vue` already requests `hud:<name>:enabled` for every registry key on mount; it's extended to also request `hud:<name>:layout` for every entry where `positionable` is true, and merge results into each entry's reactive `layout` ref (initialized from `defaultLayout`). Same single `oblsk_preferences:client:hydrate` round trip, more keys in the same request — no new event names.

**Write path.** Reuses `oblsk_preferences:client:set` / the existing `oblsk_preferences:server:set` handler verbatim — it already takes `(scope, key, value)` and already resolves the real owner server-side. The editor calls it with `key = 'hud:' + name + ':layout'` and whatever `scope` the player picked in the panel. Writes are **debounced 400ms** after the last change (drag delta or slider input) and also flushed immediately on `pointerup` / slider release — continuous per-frame drag deltas stay local-only until the debounce fires, so dragging doesn't spam the server.

**The editor panel** (`oblsk_preferences`'s second global element, alongside the existing invisible `PreferencesHydrator`): a new `HudEditor.vue`, `positionable: false`, `defaultVisible: false`, whose visibility is toggled by `obelisk:hudEditMode` rather than the normal enabled/disabled preference (it's a tool, not a HUD element a player permanently keeps on). Content, scoped down from the prototype's `hud-editor.jsx` to the generic layout concern only (no speedo-style/progress-style tabs — those are each plugin's own future settings surface):

- List of every `positionable` registry entry: label, show/hide toggle (writes `hud:<name>:enabled`, already-existing mechanism), select-to-edit.
- For the selected element: resize (scale), 3D horizontal (ry), 3D vertical (rx), rotate (rot) sliders, and a "reset position & transform" button (reverts to `defaultLayout`).
- Scope toggle: "this character" / "account-wide" — sets which `scope` the debounced writes use.
- Drag-to-move happens directly on the HUD element itself (via `HudPositionFrame`'s `onPointerDown`), not inside the panel — same as the prototype.

## Opening the editor: an Action, not a hardcoded key

`oblsk_preferences` registers an action through the existing `ActionService` (the same mechanism `oblsk_radialmenu`/`oblsk_keybinds` already dispatch through) that flips `obelisk:hudEditMode`. Registering it as an action rather than binding a raw key directly means any input surface — a keybind (via `oblsk_keybinds`), a radial menu entry, a native-menu item, or a chat command — can trigger it with zero additional plumbing; which surfaces actually wire it up is a follow-up (e.g. `oblsk_keybinds` shipping a default binding), not part of this sub-project's build.

## Data flow summary

```
Player enters edit mode (Action → obelisk:hudEditMode = true)
  → HudEditor panel becomes visible, HudPositionFrame wrappers become draggable/outlined
Player drags an element / moves a slider
  → local layout ref updates immediately (live preview)
  → 400ms after the last change (or on release): oblsk_preferences:client:set(scope, 'hud:<name>:layout', {x,y,scale,rx,ry,rot})
  → server resolves owner_id from session, PreferenceService.set upserts
Player relogs / reconnects
  → PreferencesHydrator requests all hud:*:layout + hud:*:enabled keys
  → server PreferenceService.getMerged (character overrides account)
  → each registry entry's layout ref is patched, HudPositionFrame renders from it
```

## Testing

- Any pure-JS helper extracted for the reference-canvas scale math (`min(vw/1920, vh/1080)`) and the transform-string builder: real unit tests (no FXServer/Vue runtime dependency), same bar as any other pure function in this codebase.
- `PreferencesHydrator`'s extended key list, `HudPositionFrame`'s pointer drag math, `HudEditor`'s debounce/flush timing, and the `ActionService` registration all touch FXServer-only globals or the Vue runtime — manual verification only (syntax checks, matching the convention `2026-08-11-preferences-and-hud-elements-design.md` already established for this class of code).
- Manual QA pass: enter edit mode, drag/resize/tilt/rotate an element, confirm live preview, confirm relog restores the saved layout, confirm "this character" vs "account-wide" scope actually isolates.

## Known gaps (deferred)

- No collision/snapping between elements while dragging.
- No per-plugin custom style tabs (speedometer dial style, progress-bar style, hotbar orientation) — each plugin owns its own settings surface; this editor only ever exposes the five generic layout knobs (position via drag, scale, rx, ry, rot).
- No default keybind/radial/menu entry wired to the new action yet — the action exists and is callable, but nothing calls it out of the box until a follow-up pass picks a surface.
- Ultrawide/non-16:9 viewports letterbox (scale-to-fit) rather than filling the extra space — acceptable for a first pass, revisit if it looks wrong in practice.
- `Hud.vue`'s placeholder content is untouched by this sub-project; it just stops self-positioning so the wrapper can take over. Real HUD content is sub-project 2.
