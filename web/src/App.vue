<template>
  <!-- Dev-only dark backdrop (matches the design reference's body{background:#07090a}):
       translucent panels like bg-black/60 need something dark behind them to render
       richly dark instead of washing out gray. Left unset in production — the real
       NUI webview must stay transparent so the game world shows through behind it. -->
  <div id="app" class="relative" :style="devBackdropStyle">
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

// A flat near-black page (matching the design reference's body background
// exactly) makes bg-black/60 panels merge into it and lose all contrast —
// the reference relies on a lit backdrop image (src/backdrop.jsx) sitting
// behind them, which in production is the actual 3D game world. This
// gradient is a lightweight stand-in with enough tonal range for panels to
// still read as a distinct floating surface, without porting that whole
// decorative scene generator into the framework.
const devBackdropStyle = import.meta.env.DEV
  ? { background: 'radial-gradient(ellipse 1400px 700px at 50% -10%, #2a2118 0%, #14181c 45%, #08090b 100%)', minHeight: '100vh' }
  : undefined

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
