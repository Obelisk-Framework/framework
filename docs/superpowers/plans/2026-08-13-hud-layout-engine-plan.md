# HUD Layout Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any `positionable` global element (starting with the `oblsk_hud` placeholder) be dragged, scaled, 3D-tilted and rotated by the player in-game, with the result persisted per account or per character, without any per-plugin editor code.

**Architecture:** Core's existing global-elements registry (`core/web/src/App.vue`) gains a generic positioning wrapper (`HudPositionFrame.vue`) driven by a new `layout` field on each registry entry. `oblsk_preferences` — which already persists a per-element `enabled` boolean the same generic way — is extended to also persist a per-element `layout` value (reusing its existing read/write event contract verbatim) and ships the one editor panel (`HudEditor.vue`) that edits any positionable element. The editor opens via an `ActionService` action, so any input surface (keybind, radial menu, chat command) can trigger it later with zero extra plumbing.

**Tech Stack:** Vue 3 (`<script setup>`, `provide`/`inject`, `reactive`), Tailwind (via CDN-free `@vitejs/plugin-vue` + `tailwindcss` already configured in `core/web`), Lua 5.4 (FXServer runtime, `Obelisk`/`ActionService`/`WebView` globals already established by core).

**Spec:** `core/docs/superpowers/specs/2026-08-13-hud-layout-engine-design.md` — read it alongside this plan; the plan argues from it and doesn't restate every rationale.

All file paths below are relative to the `core` repository root (`/home/andi/Projects/obelisk-framework/core`) unless a task explicitly names a different repository.

## Global Constraints

- No schema change to the `preferences` table. Reuse `PreferenceService.set`/`get`/`getMerged` and the existing `oblsk_preferences:client:set` / `oblsk_preferences:server:set` / `oblsk_preferences:client:request` / `oblsk_preferences:server:request` / `oblsk_preferences:client:hydrate` event names verbatim — no new preference event names.
- New key convention: `hud:<name>:layout` → JSON `{ x, y, scale, rx, ry, rot }`. `scale` range 50–180 (%, stored as 0.5–1.8). `rx`/`ry` range -60..60 (°). `rot` range -45..45 (°).
- Reference canvas: every positionable element is authored against a fixed 1920×1080 virtual canvas, uniformly scaled to fit the real viewport via `scale = min(viewportWidth / 1920, viewportHeight / 1080)`, centered (letterboxed on the tighter axis).
- Writes are debounced 400ms after the last change and flushed immediately on `pointerup` / slider release — never written on every drag frame.
- `ActionService.register` ids use the existing short-prefix convention (`keybinds:open`, `phone:toggle-dock`) — this plan's action is `preferences:hud-editor-toggle`.
- This editor exposes exactly five generic knobs (drag-to-move, scale, rx, ry, rot) and nothing plugin-specific (no speedometer dial style, no progress-bar style — those are each plugin's own future settings surface).
- Every plugin/module repository stays self-contained: no relative imports reaching into another plugin/module's directory (e.g. `oblsk_preferences` must not import anything from `oblsk_keybinds`). Use `@/...` only for paths inside `core/web/src`.
- Verify every Vue change by running `npm run build` inside `core/web` (this compiles `App.vue` plus every glob-imported `modules/*/web/globalElements.js` and `plugins/*/web/globalElements.js`, so it catches syntax/import errors in any touched file). Verify every Lua change with `luac5.4 -p <file>` (parse-only syntax check, matching the `luac5.4`/`lua5.4` binaries already present on this machine).

---

### Task 1: Pure layout-math helpers (`hudLayout.js`)

**Files:**
- Create: `web/src/lib/hudLayout.js`
- Create: `web/src/lib/hudLayout.test.js`

**Interfaces:**
- Produces: `computeCanvasFit(viewportWidth, viewportHeight) -> { scale, offsetX, offsetY }`, `layoutTransform(layout) -> string` (CSS `transform` value, `layout` has `scale`/`rx`/`ry`/`rot` number fields), `debounce(fn, waitMs) -> debounced` where `debounced(...args)` schedules a call, `debounced.flush(...args)` runs immediately and cancels the pending timer, `debounced.cancel()` cancels without calling. Tasks 3, 4 and 8 import all three.

- [ ] **Step 1: Write the failing test**

Create `web/src/lib/hudLayout.test.js`:

```js
import { computeCanvasFit, layoutTransform, debounce } from './hudLayout.js'

const tests = []
function test(name, fn) { tests.push({ name, fn }) }

function eq(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error(`${msg || 'assertion failed'}\n     expected: ${expected}\n     actual:   ${actual}`)
  }
}

test('computeCanvasFit: 1920x1080 viewport gives scale 1, no offset', () => {
  const fit = computeCanvasFit(1920, 1080)
  eq(fit.scale, 1, 'scale')
  eq(fit.offsetX, 0, 'offsetX')
  eq(fit.offsetY, 0, 'offsetY')
})

test('computeCanvasFit: wider-than-16:9 viewport letterboxes left/right', () => {
  const fit = computeCanvasFit(2560, 1080)
  eq(fit.scale, 1, 'scale')
  eq(fit.offsetX, 320, 'offsetX')
  eq(fit.offsetY, 0, 'offsetY')
})

test('computeCanvasFit: taller-than-16:9 viewport letterboxes top/bottom', () => {
  const fit = computeCanvasFit(1920, 1440)
  eq(fit.scale, 1, 'scale')
  eq(fit.offsetY, 180, 'offsetY')
})

test('computeCanvasFit: smaller viewport scales down uniformly, capped by the tighter axis', () => {
  const fit = computeCanvasFit(960, 540)
  eq(fit.scale, 0.5, 'scale')
})

test('layoutTransform: builds the expected CSS transform string', () => {
  const css = layoutTransform({ scale: 1.2, rx: 5, ry: -10, rot: 3 })
  eq(css, 'perspective(1100px) rotateY(-10deg) rotateX(5deg) rotate(3deg) scale(1.2)', 'transform string')
})

test('debounce: collapses rapid calls into one, using the last call\'s args', async () => {
  const calls = []
  const debounced = debounce((v) => calls.push(v), 30)
  debounced(1); debounced(2); debounced(3)
  await new Promise((resolve) => setTimeout(resolve, 60))
  eq(calls.length, 1, 'call count')
  eq(calls[0], 3, 'last value')
})

test('debounce: flush() runs immediately with the pending args and skips the wait', () => {
  const calls = []
  const debounced = debounce((v) => calls.push(v), 1000)
  debounced('a')
  debounced.flush('a')
  eq(calls.length, 1, 'call count')
})

let passed = 0
const failures = []

for (const t of tests) {
  try {
    await t.fn()
    passed++
    console.log('  ok   - ' + t.name)
  } catch (err) {
    failures.push(t.name)
    console.log('  FAIL - ' + t.name)
    console.log('         ' + String(err.message || err).replaceAll('\n', '\n         '))
  }
}

console.log(`\n${passed} passed, ${failures.length} failed`)
process.exit(failures.length === 0 ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node web/src/lib/hudLayout.test.js`
Expected: fails immediately with a module-not-found error for `./hudLayout.js` (the file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `web/src/lib/hudLayout.js`:

```js
export const HUD_REFERENCE_WIDTH = 1920
export const HUD_REFERENCE_HEIGHT = 1080

/**
 * Uniformly scales the 1920x1080 reference canvas to fit inside the real
 * viewport, capped by whichever axis is tighter, and centers the result
 * (letterboxing the other axis).
 */
export function computeCanvasFit(viewportWidth, viewportHeight) {
  const scale = Math.min(viewportWidth / HUD_REFERENCE_WIDTH, viewportHeight / HUD_REFERENCE_HEIGHT)
  const offsetX = (viewportWidth - HUD_REFERENCE_WIDTH * scale) / 2
  const offsetY = (viewportHeight - HUD_REFERENCE_HEIGHT * scale) / 2
  return { scale, offsetX, offsetY }
}

/** Builds the CSS transform for a positioned element's tilt/rotate/scale. */
export function layoutTransform(layout) {
  return `perspective(1100px) rotateY(${layout.ry}deg) rotateX(${layout.rx}deg) rotate(${layout.rot}deg) scale(${layout.scale})`
}

/**
 * Debounces fn: rapid calls collapse into one, `waitMs` after the last call.
 * `.flush(...args)` runs immediately and cancels the pending timer.
 * `.cancel()` cancels without calling.
 */
export function debounce(fn, waitMs) {
  let timer = null

  function debounced(...args) {
    clearTimeout(timer)
    timer = setTimeout(() => { timer = null; fn(...args) }, waitMs)
  }

  debounced.flush = (...args) => {
    clearTimeout(timer)
    timer = null
    fn(...args)
  }

  debounced.cancel = () => {
    clearTimeout(timer)
    timer = null
  }

  return debounced
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node web/src/lib/hudLayout.test.js`
Expected: `6 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/hudLayout.js web/src/lib/hudLayout.test.js
git commit -m "Add pure HUD layout-math helpers (canvas fit, transform, debounce)"
```

---

### Task 2: Strip self-positioning from `oblsk_hud`'s placeholder

**Repository:** `plugins/oblsk_hud` (separate git repo, checked out at `core/plugins/oblsk_hud`).

**Files:**
- Modify: `plugins/oblsk_hud/web/Hud.vue`
- Modify: `plugins/oblsk_hud/web/globalElements.js`

**Interfaces:**
- Consumes: nothing new.
- Produces: a `positionable: true` registry entry with `defaultLayout: { x: 34, y: 968, width: 360, align: 'left' }` that Task 4's `App.vue` change and Task 3's `HudPositionFrame.vue` render.

- [ ] **Step 1: Remove the component's own position classes**

`plugins/oblsk_hud/web/Hud.vue` currently is:

```vue
<template>
  <div class="fixed bottom-4 left-4 z-40 text-white text-sm bg-black/50 rounded px-3 py-2">
    HUD (placeholder)
  </div>
</template>

<script setup>
</script>
```

Replace with (drops `fixed bottom-4 left-4 z-40` — the wrapper built in Task 3 now owns position/z-index):

```vue
<template>
  <div class="text-white text-sm bg-black/50 rounded px-3 py-2">
    HUD (placeholder)
  </div>
</template>

<script setup>
</script>
```

- [ ] **Step 2: Declare it positionable**

`plugins/oblsk_hud/web/globalElements.js` currently is:

```js
import Hud from './Hud.vue'

export default [
  { name: 'hud', component: Hud, defaultVisible: true }
]
```

Replace with:

```js
import Hud from './Hud.vue'

export default [
  {
    name: 'hud',
    component: Hud,
    defaultVisible: true,
    positionable: true,
    defaultLayout: { x: 34, y: 968, width: 360, align: 'left' },
  }
]
```

- [ ] **Step 3: Verify (deferred build check)**

This repo alone has no build step (it's consumed by `core`'s Vite glob import). Nothing to run yet — Task 4's build check covers it. Just re-read both files and confirm they match exactly what's above.

- [ ] **Step 4: Commit**

```bash
git add web/Hud.vue web/globalElements.js
git commit -m "Stop self-positioning; declare hud as a positionable global element"
```

(Run from `plugins/oblsk_hud`'s own working directory — it's a separate repository.)

---

### Task 3: `HudPositionFrame.vue` — the generic positioning wrapper

**Files:**
- Create: `web/src/components/HudPositionFrame.vue`

**Interfaces:**
- Consumes: `computeCanvasFit`, `layoutTransform`, `debounce` from `@/lib/hudLayout.js` (Task 1); injects `obelisk:hudEditMode` (`Ref<boolean>`), `obelisk:hudEditSelection` (`Ref<string|null>`), `obelisk:hudEditScope` (`Ref<'account'|'character'>`), `obelisk:hudCanvasScale` (`ComputedRef<number>`) — all provided by Task 4's `App.vue`. Props: `name: String`, `entry: Object` where `entry.layout` is a `reactive({ x, y, width, align, scale, rx, ry, rot })` and `entry.visible` is a `boolean`.
- Produces: on-screen dragging that mutates `entry.layout.x`/`.y` directly (reactive, so `App.vue`'s registry updates immediately) and persists via `Obelisk.emit('oblsk_preferences:client:set', ...)`, debounced.

- [ ] **Step 1: Write the component**

```vue
<template>
  <div
    v-show="entry.visible"
    class="absolute"
    :style="frameStyle"
    @pointerdown="onPointerDown"
  >
    <component :is="entry.component" />
  </div>
</template>

<script setup>
import { computed, inject } from 'vue'
import Obelisk from '@/obelisk.js'
import { layoutTransform, debounce } from '@/lib/hudLayout.js'

const props = defineProps({
  name: { type: String, required: true },
  entry: { type: Object, required: true },
})

const editMode = inject('obelisk:hudEditMode')
const selection = inject('obelisk:hudEditSelection')
const editScope = inject('obelisk:hudEditScope')
const canvasScale = inject('obelisk:hudCanvasScale')

const selected = computed(() => editMode.value && selection.value === props.name)

const frameStyle = computed(() => ({
  left: props.entry.layout.x + 'px',
  top: props.entry.layout.y + 'px',
  width: props.entry.layout.width + 'px',
  textAlign: props.entry.layout.align || 'left',
  transformOrigin: 'top left',
  transform: layoutTransform(props.entry.layout),
  cursor: editMode.value ? 'move' : 'default',
  outline: !editMode.value
    ? 'none'
    : (selected.value ? '1px dashed color-mix(in oklab, var(--ob-accent) 70%, transparent)' : '1px dashed rgba(255,255,255,.18)'),
  outlineOffset: '6px',
  zIndex: selected.value ? 40 : undefined,
}))

const persistLayout = debounce(() => {
  const l = props.entry.layout
  Obelisk.emit('oblsk_preferences:client:set', {
    scope: editScope.value,
    key: `hud:${props.name}:layout`,
    value: { x: l.x, y: l.y, scale: l.scale, rx: l.rx, ry: l.ry, rot: l.rot },
  })
}, 400)

let drag = null

function onPointerDown(ev) {
  if (!editMode.value) return
  ev.stopPropagation()
  selection.value = props.name
  drag = { x0: props.entry.layout.x, y0: props.entry.layout.y, px: ev.clientX, py: ev.clientY }
  window.addEventListener('pointermove', onPointerMove)
  window.addEventListener('pointerup', onPointerUp)
}

function onPointerMove(ev) {
  if (!drag) return
  const k = canvasScale.value || 1
  props.entry.layout.x = Math.round(drag.x0 + (ev.clientX - drag.px) / k)
  props.entry.layout.y = Math.round(drag.y0 + (ev.clientY - drag.py) / k)
  persistLayout()
}

function onPointerUp() {
  if (!drag) return
  drag = null
  persistLayout.flush()
  window.removeEventListener('pointermove', onPointerMove)
  window.removeEventListener('pointerup', onPointerUp)
}
</script>
```

- [ ] **Step 2: Verify (deferred build check)**

This component isn't reachable from `App.vue` yet (Task 4 wires it in) so `npm run build` can't exercise it meaningfully in isolation. Re-read the file and confirm every `inject`ed key name (`obelisk:hudEditMode`, `obelisk:hudEditSelection`, `obelisk:hudEditScope`, `obelisk:hudCanvasScale`) exactly matches what Task 4 provides — a typo here silently yields `undefined` refs at runtime with no compile error.

- [ ] **Step 3: Commit**

```bash
git add web/src/components/HudPositionFrame.vue
git commit -m "Add HudPositionFrame: generic drag/scale/tilt/rotate wrapper for positionable elements"
```

---

### Task 4: Wire the registry, canvas, and edit-mode state into `App.vue`

**Files:**
- Modify: `web/src/App.vue`

**Interfaces:**
- Consumes: `HudPositionFrame.vue` (Task 3), `computeCanvasFit` from `@/lib/hudLayout.js` (Task 1).
- Produces: `provide('obelisk:hudEditMode', Ref<boolean>)`, `provide('obelisk:hudEditSelection', Ref<string|null>)`, `provide('obelisk:hudEditScope', Ref<'account'|'character'>)`, `provide('obelisk:hudCanvasScale', ComputedRef<number>)` — all consumed by Tasks 3 and 8. Every registry entry gains `positionable: boolean`, `defaultLayout: {x,y,width,align}`, `layout: reactive({x,y,width,align,scale,rx,ry,rot})` — consumed by Tasks 3, 5, 8.

- [ ] **Step 1: Replace `App.vue` in full**

Current file (for reference, `web/src/App.vue`):

```vue
<template>
  <div id="app" class="relative">
    <component
      v-for="[name, entry] in registry"
      :key="name"
      :is="entry.component"
      v-show="entry.visible"
    />
    <router-view />
  </div>
</template>

<script setup>
import { reactive, onMounted, provide } from 'vue'
import router from './router'
import Obelisk from './obelisk.js'
import coreGlobalElements from './globalElements.js'

const contributedGlobalElementModules = import.meta.glob(
  ['../../modules/*/web/globalElements.js', '../../plugins/*/web/globalElements.js'],
  { eager: true }
)

const contributedGlobalElements = []
for (const mod of Object.values(contributedGlobalElementModules)) {
  if (Array.isArray(mod.default)) {
    contributedGlobalElements.push(...mod.default)
  } else {
    console.warn('[Obelisk] a globalElements.js did not export a default array, skipping')
  }
}

const registry = reactive(new Map())
for (const entry of [...coreGlobalElements, ...contributedGlobalElements]) {
  if (!entry || !entry.name || !entry.component) {
    console.warn('[Obelisk] a global element entry is missing name/component, skipping', entry)
    continue
  }
  if (registry.has(entry.name)) {
    console.warn(`[Obelisk] duplicate global element name "${entry.name}", keeping the last one discovered`)
  }
  const defaultVisible = !!entry.defaultVisible
  registry.set(entry.name, { component: entry.component, defaultVisible, visible: defaultVisible })
}

provide('obelisk:globalElementsRegistry', registry)

const paymentApi = reactive({ requestPayment: null })
provide('obelisk:payment', paymentApi)

onMounted(() => {
  Obelisk.on('core:client:navigate', (route) => {
    router.push(route)
  })

  Obelisk.on('core:client:webview-openPage', (page) => {
    router.push(page)
  })

  Obelisk.on('core:client:webview-showGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = true
  })

  Obelisk.on('core:client:webview-hideGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = false
  })

  Obelisk.on('core:client:webview-toggleGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = !entry.visible
  })

  Obelisk.on('core:client:webview-destroy', () => {
    for (const entry of registry.values()) entry.visible = entry.defaultVisible
  })
})
</script>

<style>
/* Global styles */
#app {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
</style>
```

Replace it in full with:

```vue
<template>
  <div id="app" class="relative">
    <div class="absolute top-0 left-0" :style="canvasWrapperStyle">
      <HudPositionFrame
        v-for="[name, entry] in positionableEntries"
        :key="name"
        :name="name"
        :entry="entry"
      />
    </div>
    <component
      v-for="[name, entry] in nonPositionableEntries"
      :key="name"
      :is="entry.component"
      v-show="entry.visible"
    />
    <router-view />
  </div>
</template>

<script setup>
import { reactive, ref, computed, onMounted, onUnmounted, provide } from 'vue'
import router from './router'
import Obelisk from './obelisk.js'
import coreGlobalElements from './globalElements.js'
import HudPositionFrame from './components/HudPositionFrame.vue'
import { computeCanvasFit } from './lib/hudLayout.js'

const contributedGlobalElementModules = import.meta.glob(
  ['../../modules/*/web/globalElements.js', '../../plugins/*/web/globalElements.js'],
  { eager: true }
)

const contributedGlobalElements = []
for (const mod of Object.values(contributedGlobalElementModules)) {
  if (Array.isArray(mod.default)) {
    contributedGlobalElements.push(...mod.default)
  } else {
    console.warn('[Obelisk] a globalElements.js did not export a default array, skipping')
  }
}

const registry = reactive(new Map())
for (const entry of [...coreGlobalElements, ...contributedGlobalElements]) {
  if (!entry || !entry.name || !entry.component) {
    console.warn('[Obelisk] a global element entry is missing name/component, skipping', entry)
    continue
  }
  if (registry.has(entry.name)) {
    console.warn(`[Obelisk] duplicate global element name "${entry.name}", keeping the last one discovered`)
  }
  const defaultVisible = !!entry.defaultVisible
  const positionable = !!entry.positionable
  const defaultLayout = entry.defaultLayout || { x: 0, y: 0, width: 300, align: 'left' }
  registry.set(entry.name, {
    component: entry.component,
    defaultVisible,
    visible: defaultVisible,
    positionable,
    defaultLayout,
    layout: reactive({
      x: defaultLayout.x, y: defaultLayout.y, width: defaultLayout.width, align: defaultLayout.align,
      scale: 1, rx: 0, ry: 0, rot: 0,
    }),
  })
}

const positionableEntries = computed(() => [...registry].filter(([, entry]) => entry.positionable))
const nonPositionableEntries = computed(() => [...registry].filter(([, entry]) => !entry.positionable))

provide('obelisk:globalElementsRegistry', registry)

const paymentApi = reactive({ requestPayment: null })
provide('obelisk:payment', paymentApi)

const hudEditMode = ref(false)
const hudEditSelection = ref(null)
const hudEditScope = ref('account')
provide('obelisk:hudEditMode', hudEditMode)
provide('obelisk:hudEditSelection', hudEditSelection)
provide('obelisk:hudEditScope', hudEditScope)

const canvasFit = ref(computeCanvasFit(window.innerWidth, window.innerHeight))
const hudCanvasScale = computed(() => canvasFit.value.scale)
provide('obelisk:hudCanvasScale', hudCanvasScale)

function updateCanvasFit() {
  canvasFit.value = computeCanvasFit(window.innerWidth, window.innerHeight)
}

const canvasWrapperStyle = computed(() => ({
  transform: `translate(${canvasFit.value.offsetX}px, ${canvasFit.value.offsetY}px) scale(${canvasFit.value.scale})`,
  transformOrigin: 'top left',
  width: '1920px',
  height: '1080px',
}))

onMounted(() => {
  window.addEventListener('resize', updateCanvasFit)

  Obelisk.on('core:client:navigate', (route) => {
    router.push(route)
  })

  Obelisk.on('core:client:webview-openPage', (page) => {
    router.push(page)
  })

  Obelisk.on('core:client:webview-showGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = true
  })

  Obelisk.on('core:client:webview-hideGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = false
  })

  Obelisk.on('core:client:webview-toggleGlobalElement', (name) => {
    const entry = registry.get(name)
    if (entry) entry.visible = !entry.visible
  })

  Obelisk.on('core:client:webview-destroy', () => {
    for (const entry of registry.values()) entry.visible = entry.defaultVisible
    hudEditMode.value = false
  })

  Obelisk.on('core:client:webview-hide', () => {
    hudEditMode.value = false
  })

  Obelisk.on('oblsk_preferences:client:hud-edit-mode-toggled', () => {
    hudEditMode.value = !hudEditMode.value
  })
})

onUnmounted(() => {
  window.removeEventListener('resize', updateCanvasFit)
})
</script>

<style>
/* Global styles */
#app {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
</style>
```

- [ ] **Step 2: Build-verify**

Run: `cd web && npm install && npm run build`
Expected: build succeeds with no errors. (`npm install` only needed the first time in a fresh checkout — safe to run every time, it's a no-op if `node_modules` is current.)

- [ ] **Step 3: Manual smoke check**

Run: `cd web && npm run dev`, open the printed local URL in a browser.
Expected: page loads with no console errors; the `hud` placeholder (Task 2) renders near the bottom-left, roughly where `defaultLayout: { x: 34, y: 968 }` on a 1920×1080 canvas would put it (scaled to your window size) — since `hudEditMode` defaults to `false`, it should look identical to the pre-existing hardcoded `fixed bottom-4 left-4` placement, just resolution-independent now instead of CSS-fixed.

- [ ] **Step 4: Commit**

```bash
git add web/src/App.vue
git commit -m "App.vue: render positionable global elements through a resolution-independent canvas wrapper"
```

---

### Task 5: `PreferencesHydrator.vue` — also hydrate layout

**Repository:** `modules/oblsk_preferences`.

**Files:**
- Modify: `modules/oblsk_preferences/web/PreferencesHydrator.vue`

**Interfaces:**
- Consumes: `entry.positionable`, `entry.layout` (reactive object) from the registry entries Task 4's `App.vue` now produces.
- Produces: nothing new consumed elsewhere — this task only changes what gets written into `entry.layout` on hydration.

- [ ] **Step 1: Replace the hydration logic**

Current file:

```vue
<template></template>

<script setup>
import { inject, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const registry = inject('obelisk:globalElementsRegistry')

function requestHydration() {
  if (!registry) return
  const keys = [...registry.keys()]
    .filter(name => !name.startsWith('__'))
    .map(name => `hud:${name}:enabled`)
  Obelisk.emit('oblsk_preferences:client:request', { keys })
}

onMounted(() => {
  Obelisk.on('oblsk_preferences:client:hydrate', (merged) => {
    if (!registry) return
    for (const [name, entry] of registry) {
      const key = `hud:${name}:enabled`
      if (merged[key] !== undefined) entry.visible = merged[key]
    }
  })

  Obelisk.on('core:client:webview-destroy', requestHydration)

  requestHydration()
})
</script>
```

Replace with:

```vue
<template></template>

<script setup>
import { inject, onMounted } from 'vue'
import Obelisk from '@/obelisk.js'

const registry = inject('obelisk:globalElementsRegistry')

function requestHydration() {
  if (!registry) return
  const keys = []
  for (const [name, entry] of registry) {
    if (name.startsWith('__')) continue
    keys.push(`hud:${name}:enabled`)
    if (entry.positionable) keys.push(`hud:${name}:layout`)
  }
  Obelisk.emit('oblsk_preferences:client:request', { keys })
}

onMounted(() => {
  Obelisk.on('oblsk_preferences:client:hydrate', (merged) => {
    if (!registry) return
    for (const [name, entry] of registry) {
      const enabledKey = `hud:${name}:enabled`
      if (merged[enabledKey] !== undefined) entry.visible = merged[enabledKey]

      if (entry.positionable) {
        const layoutKey = `hud:${name}:layout`
        const saved = merged[layoutKey]
        if (saved && typeof saved === 'object') {
          Object.assign(entry.layout, saved)
        }
      }
    }
  })

  Obelisk.on('core:client:webview-destroy', requestHydration)

  requestHydration()
})
</script>
```

- [ ] **Step 2: Build-verify**

Run (from `core`): `cd web && npm run build`
Expected: succeeds. (This file is picked up by the same glob as before; no new import paths were introduced.)

- [ ] **Step 3: Commit**

```bash
git add web/PreferencesHydrator.vue
git commit -m "Hydrate hud:<name>:layout alongside hud:<name>:enabled for positionable elements"
```

(Run from `modules/oblsk_preferences`'s own working directory — it's a separate repository.)

---

### Task 6: Server — register the `preferences:hud-editor-toggle` action

**Repository:** `modules/oblsk_preferences`.

**Files:**
- Modify: `modules/oblsk_preferences/server/main.lua`

**Interfaces:**
- Consumes: `ActionService.register` (global, provided by `core`), `Obelisk.emitClient` (global).
- Produces: net event `preferences:client:hud-editor-toggle`, emitted to a single `source` — consumed by Task 7's client `main.lua`.

- [ ] **Step 1: Append the action registration**

At the end of `modules/oblsk_preferences/server/main.lua` (after the existing `Obelisk.onServer('oblsk_preferences:server:request', ...)` block), add:

```lua

--- Bindable from anywhere (keybind, radial menu, chat command, native menu)
--- via ActionService -- this handler itself only relays the toggle to the
--- SAME client that triggered it, same pattern as phone:toggle-dock.
ActionService.register('preferences:hud-editor-toggle', function(source)
    Obelisk.emitClient('preferences:client:hud-editor-toggle', source)
end, { label = 'Toggle HUD editor' })
```

- [ ] **Step 2: Syntax-verify**

Run (from `modules/oblsk_preferences`): `luac5.4 -p server/main.lua`
Expected: no output, exit code 0 (parses cleanly).

- [ ] **Step 3: Commit**

```bash
git add server/main.lua
git commit -m "Register the preferences:hud-editor-toggle action"
```

---

### Task 7: Client — handle the toggle, manage NUI focus

**Repository:** `modules/oblsk_preferences`.

**Files:**
- Modify: `modules/oblsk_preferences/client/main.lua`

**Interfaces:**
- Consumes: net event `preferences:client:hud-editor-toggle` (Task 6), `WebView.focus` (global, provided by `core`).
- Produces: NUI message `oblsk_preferences:client:hud-edit-mode-toggled` (no payload) — consumed by Task 4's `App.vue` listener, which toggles its own `hudEditMode` ref in place.

- [ ] **Step 1: Append the toggle handler**

`App.vue`'s `hudEditMode` ref (Task 4) is the single source of truth for whether the editor is open — it already flips back to `false` on `core:client:webview-hide` (i.e. ESC, or the editor's own × button calling `core:client:close`). So this handler doesn't need to track open/closed state itself: it always grabs NUI focus (dragging needs the mouse) and tells the NUI "the toggle fired", letting `App.vue` decide what that means.

At the end of `modules/oblsk_preferences/client/main.lua`, add:

```lua

--- Toggles the HUD layout editor. Always grabs NUI focus/cursor (dragging
--- elements needs the mouse). Releasing focus again happens the same way
--- ESC already does it (WebView.hide(), which App.vue listens for on
--- 'core:client:webview-hide' to flip its own hudEditMode back off) -- this
--- handler only ever needs to open, never to explicitly close.
Obelisk.onClient('preferences:client:hud-editor-toggle', function()
    WebView.focus()
    WebView.emit('oblsk_preferences:client:hud-edit-mode-toggled', {})
end)
```

- [ ] **Step 2: Syntax-verify**

Run (from `modules/oblsk_preferences`): `luac5.4 -p client/main.lua`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add client/main.lua
git commit -m "Handle preferences:hud-editor-toggle: grab NUI focus, tell the NUI to flip edit mode"
```

---

### Task 8: `HudEditor.vue` — the generic layout editor panel

**Repository:** `modules/oblsk_preferences`.

**Files:**
- Create: `modules/oblsk_preferences/web/HudEditor.vue`
- Modify: `modules/oblsk_preferences/web/globalElements.js`

**Interfaces:**
- Consumes: `obelisk:globalElementsRegistry`, `obelisk:hudEditMode`, `obelisk:hudEditSelection`, `obelisk:hudEditScope` (all from Task 4's `App.vue`); `debounce` from `@/lib/hudLayout.js` (Task 1).
- Produces: writes to `entry.visible` and `entry.layout` (same reactive objects `HudPositionFrame` reads), and persists both via `Obelisk.emit('oblsk_preferences:client:set', ...)` (existing contract, unchanged).

- [ ] **Step 1: Write the component**

```vue
<template>
  <div v-show="hudEditMode" class="absolute inset-0" style="z-index: 9990">
    <div class="absolute left-8 top-1/2 -translate-y-1/2 w-[330px] rounded-2xl border border-white/12 bg-[#0d1012] shadow-2xl text-white">
      <div class="flex items-center gap-2.5 px-4 py-3 border-b border-white/8">
        <div class="w-8 h-8 rounded-lg grid place-items-center" style="background: var(--ob-accent)">
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="#000" stroke-width="2.2" stroke-linecap="round">
            <path d="M4 7h16M4 12h10M4 17h13" />
          </svg>
        </div>
        <div class="flex-1">
          <div class="text-[13px] font-semibold leading-tight">HUD layout</div>
          <div class="font-mono text-[9px] text-white/35">POSITION · SCALE · TILT · ROTATE</div>
        </div>
        <button
          class="w-8 h-8 rounded-lg border border-white/12 hover:bg-white/8 grid place-items-center transition text-[13px] leading-none"
          @click="close">×</button>
      </div>

      <div class="p-3 max-h-[62vh] overflow-y-auto space-y-2">
        <div class="rounded-xl border border-white/10 overflow-hidden">
          <div v-for="[name, entry] in positionableEntries" :key="name"
            class="flex items-center gap-2 px-2.5 h-9 border-b border-white/6 last:border-0"
            :class="selection === name ? 'bg-white/8' : ''">
            <button class="flex-1 text-left text-[12px] truncate" :style="{ color: selection === name ? '#fff' : 'rgba(255,255,255,.6)' }"
              @click="selection = name">{{ name }}</button>
            <button class="w-7 h-6 rounded-md grid place-items-center hover:bg-white/10"
              :style="{ color: entry.visible ? 'var(--ob-accent)' : 'rgba(255,255,255,.28)' }"
              @click="toggleVisible(name, entry)">
              <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12z" /><circle cx="12" cy="12" r="2.6" />
                <path v-if="!entry.visible" d="M4 20 20 4" />
              </svg>
            </button>
          </div>
        </div>

        <template v-if="selectedEntry">
          <div class="font-mono text-[9px] tracking-[0.18em] text-white/30 pt-1">EDITING · {{ selection.toUpperCase() }}</div>
          <button class="w-full h-9 rounded-xl border border-white/10 bg-white/[0.03] text-[12px] text-white/70 hover:bg-white/8"
            @click="resetSelected">Reset position &amp; transform</button>

          <label class="block rounded-xl border border-white/10 bg-white/[0.03] px-3 py-2.5">
            <div class="flex items-center justify-between mb-1.5">
              <span class="text-[12px] text-white/70">Resize element</span>
              <span class="font-mono text-[10.5px] px-1.5 py-0.5 rounded bg-white/8">{{ Math.round(selectedEntry.layout.scale * 100) }}%</span>
            </div>
            <input type="range" min="50" max="180" step="1" :value="Math.round(selectedEntry.layout.scale * 100)"
              @input="setLayout('scale', Number($event.target.value) / 100)" class="w-full" style="accent-color: var(--ob-accent)" />
          </label>

          <label class="block rounded-xl border border-white/10 bg-white/[0.03] px-3 py-2.5">
            <div class="flex items-center justify-between mb-1.5">
              <span class="text-[12px] text-white/70">3D horizontal</span>
              <span class="font-mono text-[10.5px] px-1.5 py-0.5 rounded bg-white/8">{{ selectedEntry.layout.ry }}°</span>
            </div>
            <input type="range" min="-60" max="60" step="1" :value="selectedEntry.layout.ry"
              @input="setLayout('ry', Number($event.target.value))" class="w-full" style="accent-color: var(--ob-accent)" />
          </label>

          <label class="block rounded-xl border border-white/10 bg-white/[0.03] px-3 py-2.5">
            <div class="flex items-center justify-between mb-1.5">
              <span class="text-[12px] text-white/70">3D vertical</span>
              <span class="font-mono text-[10.5px] px-1.5 py-0.5 rounded bg-white/8">{{ selectedEntry.layout.rx }}°</span>
            </div>
            <input type="range" min="-60" max="60" step="1" :value="selectedEntry.layout.rx"
              @input="setLayout('rx', Number($event.target.value))" class="w-full" style="accent-color: var(--ob-accent)" />
          </label>

          <label class="block rounded-xl border border-white/10 bg-white/[0.03] px-3 py-2.5">
            <div class="flex items-center justify-between mb-1.5">
              <span class="text-[12px] text-white/70">Rotate element</span>
              <span class="font-mono text-[10.5px] px-1.5 py-0.5 rounded bg-white/8">{{ selectedEntry.layout.rot }}°</span>
            </div>
            <input type="range" min="-45" max="45" step="1" :value="selectedEntry.layout.rot"
              @input="setLayout('rot', Number($event.target.value))" class="w-full" style="accent-color: var(--ob-accent)" />
          </label>
        </template>

        <div class="font-mono text-[9px] tracking-[0.18em] text-white/30 pt-2">SAVE TO</div>
        <div class="flex gap-1 p-1 rounded-xl bg-white/[0.05] border border-white/10">
          <button v-for="opt in scopeOptions" :key="opt[0]"
            class="flex-1 h-7 rounded-lg text-[11.5px] transition"
            :class="hudEditScope === opt[0] ? 'text-black font-medium' : 'text-white/55 hover:text-white'"
            :style="hudEditScope === opt[0] ? { background: 'var(--ob-accent)' } : undefined"
            @click="hudEditScope = opt[0]">{{ opt[1] }}</button>
        </div>
        <p class="text-[11px] text-white/35 leading-relaxed px-0.5">Drag any element on screen to move it. Everything else lives here.</p>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, inject } from 'vue'
import Obelisk from '@/obelisk.js'
import { debounce } from '@/lib/hudLayout.js'

const scopeOptions = [['character', 'This character'], ['account', 'Account-wide']]

const registry = inject('obelisk:globalElementsRegistry')
const hudEditMode = inject('obelisk:hudEditMode')
const selection = inject('obelisk:hudEditSelection')
const hudEditScope = inject('obelisk:hudEditScope')

const positionableEntries = computed(() => registry ? [...registry].filter(([, entry]) => entry.positionable) : [])
const selectedEntry = computed(() => (selection.value && registry) ? registry.get(selection.value) : null)

function toggleVisible(name, entry) {
  entry.visible = !entry.visible
  Obelisk.emit('oblsk_preferences:client:set', { scope: hudEditScope.value, key: `hud:${name}:enabled`, value: entry.visible })
}

const persistSelectedLayout = debounce(() => {
  if (!selection.value || !selectedEntry.value) return
  const l = selectedEntry.value.layout
  Obelisk.emit('oblsk_preferences:client:set', {
    scope: hudEditScope.value,
    key: `hud:${selection.value}:layout`,
    value: { x: l.x, y: l.y, scale: l.scale, rx: l.rx, ry: l.ry, rot: l.rot },
  })
}, 400)

function setLayout(field, value) {
  if (!selectedEntry.value) return
  selectedEntry.value.layout[field] = value
  persistSelectedLayout()
}

function resetSelected() {
  if (!selectedEntry.value) return
  const d = selectedEntry.value.defaultLayout
  Object.assign(selectedEntry.value.layout, { x: d.x, y: d.y, width: d.width, align: d.align, scale: 1, rx: 0, ry: 0, rot: 0 })
  persistSelectedLayout.flush()
}

function close() {
  Obelisk.emit('core:client:close')
}
</script>
```

- [ ] **Step 2: Register it as a (non-positionable) global element**

Current `modules/oblsk_preferences/web/globalElements.js`:

```js
import PreferencesHydrator from './PreferencesHydrator.vue'

export default [
  { name: '__preferencesHydrator', component: PreferencesHydrator, defaultVisible: true }
]
```

Replace with:

```js
import PreferencesHydrator from './PreferencesHydrator.vue'
import HudEditor from './HudEditor.vue'

export default [
  { name: '__preferencesHydrator', component: PreferencesHydrator, defaultVisible: true },
  { name: '__hudEditor', component: HudEditor, defaultVisible: true },
]
```

(`defaultVisible: true` here means "always mounted", matching `PreferencesHydrator` — `HudEditor`'s own `v-show="hudEditMode"` is what actually gates whether the player sees it.)

- [ ] **Step 3: Build-verify**

Run (from `core`): `cd web && npm run build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add web/HudEditor.vue web/globalElements.js
git commit -m "Add HudEditor: the generic show/hide + position/scale/tilt/rotate panel"
```

(Run from `modules/oblsk_preferences`'s own working directory.)

---

### Task 9: End-to-end manual QA

**Files:** none (verification only).

**Interfaces:** exercises the full chain built in Tasks 1–8.

- [ ] **Step 1: Start the dev server**

Run: `cd web && npm run dev`, open the printed local URL.

- [ ] **Step 2: Confirm baseline (edit mode off)**

Expected: the `hud` placeholder renders near the bottom-left as in Task 4's smoke check; no editor panel visible; no console errors.

- [ ] **Step 3: Simulate the toggle**

The real toggle round-trips through FXServer (`ActionService` → net event → `WebView.focus()` → NUI message), which isn't reachable from a plain browser dev server. Simulate it from the browser devtools console instead:

```js
window.postMessage({ eventname: 'oblsk_preferences:client:hud-edit-mode-toggled', args: [] }, '*')
```

Expected: the `HudEditor` panel appears on the left; the `hud` placeholder gets a dashed outline and `cursor: move` on hover.

- [ ] **Step 4: Drag, resize, tilt, rotate**

Drag the `hud` placeholder to a new spot — expected: it follows the cursor smoothly, no lag or snap-back. Click it in the editor's element list to select it if not already selected, then move each of the four sliders (resize, 3D horizontal, 3D vertical, rotate) — expected: the placeholder visibly scales/tilts/rotates live as each slider moves.

- [ ] **Step 5: Confirm debounced persistence**

Open the Network tab (or add a temporary `console.log` inside `HudPositionFrame`'s `persistLayout`/`HudEditor`'s `persistSelectedLayout`), drag the element around continuously for 2+ seconds, then stop.
Expected: no `oblsk_preferences:client:set` NUI emit fires *during* continuous dragging faster than every 400ms; exactly one final emit fires ~400ms after the drag stops (or immediately on `pointerup`, per the debounce implementation — `Obelisk.emit` itself will just log to the dev console since there's no real NUI host, per `obelisk.js`'s `if (!window.invokeNative)` branch).

- [ ] **Step 6: Confirm reset**

Click "Reset position & transform" — expected: the element snaps back to `defaultLayout` position with `scale: 1, rx: 0, ry: 0, rot: 0`.

- [ ] **Step 7: Confirm show/hide still works**

Click the eye icon next to `hud` in the editor's list — expected: the placeholder disappears/reappears immediately, and a `hud:hud:enabled` set call is logged.

- [ ] **Step 8: Close and confirm baseline restored**

Click the × in the editor panel header — expected: `Obelisk.emit('core:client:close')` logs; in a real FXServer session this reaches `WebView.on('core:client:close', WebView.hide)`, which sends `core:client:webview-hide`, which `App.vue` listens for to set `hudEditMode` back to `false`. Simulate that last leg too from the console:

```js
window.postMessage({ eventname: 'core:client:webview-hide', args: [] }, '*')
```

Expected: editor panel disappears, placeholder's dashed outline goes away.

- [ ] **Step 9: Final commit**

No code changes in this task — if Steps 2–8 all passed, there's nothing to commit. If any step surfaced a bug, fix it in the relevant task's files, re-run that task's build/syntax verification, and commit the fix with a message describing what was wrong (e.g. `git commit -m "Fix: HudPositionFrame drag used stale canvas scale after window resize"`).
